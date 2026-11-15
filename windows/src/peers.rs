//! Listen-mode admission control (defense in depth on top of the v2 key pinning).
//!
//! In `--listen` mode anyone who can reach the port can start a handshake. Before a single
//! handshake byte is exchanged the viewer:
//! - drops peers not in `allowed_peers` (IPs or CIDRs) when that list is non-empty, except that
//!   a TOFU-pinned single address may *roam* (see `admit`);
//! - drops peers that are in a failed-handshake backoff window (1 s doubling to 60 s per IP).
//!
//! With an empty list the IP of the first host that completes an authenticated session is
//! pinned (trust on first use). The host's *key* is what authenticates it (config
//! `pinned_hosts`); the IP list only limits who may start a handshake. Pure Rust; unit-tested.
//!
//! What counts as a failed attempt (`classify`): everything except outcomes that say nothing bad
//! about the peer — the host's authenticated "unknown viewer" / "pairing closed" / "busy"
//! answers, this viewer declining to pair because a pairing window is closed, and a connection
//! closed before the host sent a single byte (one the Mac gave up on in the listen backlog).
//! Counting those blocked the real Mac exactly when the user opened its pairing window.

use crate::net::{Auth, ConnectError, Connection};
use crate::protocol::ClientMsg;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// An IP network: address + prefix length.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Net {
    pub addr: IpAddr,
    pub prefix: u8,
}

/// IPv4-mapped IPv6 (`::ffff:a.b.c.d`) → IPv4, so one rule covers both forms.
pub fn canonical(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    }
}

/// Parse `192.168.50.4`, `192.168.50.0/24`, `fe80::1`, `fd00::/8`.
pub fn parse_net(s: &str) -> Result<Net, String> {
    let s = s.trim();
    let (a, p) = match s.split_once('/') {
        Some((a, p)) => (a, Some(p)),
        None => (s, None),
    };
    let addr = canonical(a.trim().parse::<IpAddr>().map_err(|_| format!("bad IP address {a:?}"))?);
    let max = if addr.is_ipv4() { 32 } else { 128 };
    let prefix = match p {
        None => max,
        Some(p) => p.trim().parse::<u8>().ok().filter(|&n| n <= max).ok_or_else(|| format!("bad prefix length in {s:?}"))?,
    };
    Ok(Net { addr, prefix })
}

impl Net {
    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.addr, canonical(ip)) {
            (IpAddr::V4(n), IpAddr::V4(i)) => {
                let mask = if self.prefix == 0 { 0 } else { u32::MAX << (32 - self.prefix) };
                (u32::from(n) & mask) == (u32::from(i) & mask)
            }
            (IpAddr::V6(n), IpAddr::V6(i)) => {
                let mask = if self.prefix == 0 { 0 } else { u128::MAX << (128 - self.prefix) };
                (u128::from(n) & mask) == (u128::from(i) & mask)
            }
            _ => false,
        }
    }
}

/// Whether `ip` may start a handshake. An empty list allows everyone (TOFU not yet pinned).
/// Invalid entries never match; if every entry is invalid, nobody is allowed (fail closed).
pub fn is_allowed(allowed: &[String], ip: IpAddr) -> bool {
    if allowed.is_empty() {
        return true;
    }
    allowed.iter().filter_map(|s| parse_net(s).ok()).any(|n| n.contains(ip))
}

/// Entries of `allowed` that don't parse (to warn about).
pub fn invalid_entries(allowed: &[String]) -> Vec<String> {
    allowed.iter().filter(|s| parse_net(s).is_err()).cloned().collect()
}

/// Trust on first use: if nothing is pinned yet, pin `ip`. Returns true if it was pinned.
pub fn pin_first(allowed: &mut Vec<String>, ip: IpAddr) -> bool {
    if !allowed.is_empty() {
        return false;
    }
    allowed.push(canonical(ip).to_string());
    true
}

/// `allowed` has the shape trust on first use writes: exactly one plain address (no `/prefix`).
/// Only such a list may roam to a new address of the paired Mac. A hand-written CIDR (even
/// `192.168.50.4/32`) or several entries keep refusing every other address before the handshake.
pub fn is_roamable(allowed: &[String]) -> bool {
    matches!(allowed, [one] if !one.contains('/') && parse_net(one).is_ok())
}

/// How `allowed_peers` changed after an authenticated inbound session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PinChange {
    Unchanged,
    /// Trust on first use pinned this address.
    Pinned,
    /// The paired Mac (its pinned key checked out) connected from a new address: the TOFU pin
    /// moved there from `from`.
    Moved { from: String },
}

/// After an authenticated inbound session from `ip`: pin it if nothing is pinned, or move a
/// TOFU pin there when the Mac's address changed (it was admitted by `Admission::Roaming`).
pub fn pin_after_session(allowed: &mut Vec<String>, ip: IpAddr) -> PinChange {
    if pin_first(allowed, ip) {
        return PinChange::Pinned;
    }
    if is_allowed(allowed, ip) || !is_roamable(allowed) {
        return PinChange::Unchanged;
    }
    let from = std::mem::replace(&mut allowed[0], canonical(ip).to_string());
    PinChange::Moved { from }
}

/// What admission control decided for a new connection, before any handshake byte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Admission {
    /// Allowlisted (or nothing is pinned yet): run the handshake.
    Admit,
    /// Not the TOFU-pinned address, but a host key is pinned: the paired Mac may have a new
    /// address (DHCP). Run the handshake, which must present the pinned key before this viewer
    /// sends anything about itself (a different key is refused before msg3, and a new key can
    /// never pair this way). Treated like an unpinned peer: global budget, harsher backoff.
    Roaming,
    Refuse(Refusal),
}

/// Why a connection was dropped before the handshake.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    NotAllowed,
    Backoff(Duration),
    Global(Duration),
}

impl Refusal {
    /// One line for the log and the status line.
    pub fn describe(&self, ip: IpAddr) -> String {
        let secs = |d: &Duration| d.as_secs_f64().ceil() as u64;
        match self {
            Refusal::NotAllowed => format!("Refused a connection from {ip}: not in allowed_peers (config file)"),
            Refusal::Backoff(d) => format!("Ignored a connection from {ip} after failed attempts (blocked for {} s more)", secs(d)),
            Refusal::Global(d) => format!("Ignored a connection from {ip}: too many failed attempts recently ({} s left)", secs(d)),
        }
    }
}

/// Admission decision for a connection from `ip`. `host_key_pinned`: a host key is pinned for
/// this target (the handshake will require it).
pub fn admit(allowed: &[String], ip: IpAddr, host_key_pinned: bool, backoff: &Backoff, now: Instant) -> Admission {
    let listed = is_allowed(allowed, ip);
    let roaming = !listed && host_key_pinned && is_roamable(allowed);
    if !listed && !roaming {
        return Admission::Refuse(Refusal::NotAllowed);
    }
    if allowed.is_empty() || roaming {
        if let Some(rem) = backoff.global_blocked(now) {
            return Admission::Refuse(Refusal::Global(rem));
        }
    }
    if let Some(rem) = backoff.blocked(ip, now) {
        return Admission::Refuse(Refusal::Backoff(rem));
    }
    if roaming {
        Admission::Roaming
    } else {
        Admission::Admit
    }
}

/// Whether a failed inbound handshake counts toward the peer's backoff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Says nothing bad about the peer: not counted.
    Neutral,
    Failure,
}

/// Classify a failed inbound handshake (`roaming`: admitted by `Admission::Roaming`).
/// Neutral:
/// - AuthResult 1 / 2 / 5 (unknown viewer, pairing window closed, busy): authenticated host
///   answers about its own state. The real Mac sends them while the user hasn't opened its
///   pairing window yet; blocking it for up to 60 s then ate the window when it did open.
/// - `HostPairingClosed` / `InboundPairingClosed`: this viewer chose not to ask to pair.
/// - `HostIsV1`: closed before sending a single byte (a connection the Mac abandoned in the
///   listen backlog), or a v1 host — except from a roaming peer, which must prove the pinned key.
///
/// Everything else (timeouts, bad handshakes, a key mismatch, a declined or broken pairing — the
/// prompt is the thing worth rate-limiting) is a failure.
pub fn classify(e: &ConnectError, roaming: bool) -> Outcome {
    use crate::protocol::{AUTH_BUSY, AUTH_PAIRING_CLOSED, AUTH_UNKNOWN_VIEWER};
    match e {
        ConnectError::Rejected(AUTH_UNKNOWN_VIEWER | AUTH_PAIRING_CLOSED | AUTH_BUSY) => Outcome::Neutral,
        ConnectError::HostPairingClosed | ConnectError::InboundPairingClosed { .. } => Outcome::Neutral,
        ConnectError::HostIsV1 if !roaming => Outcome::Neutral,
        _ => Outcome::Failure,
    }
}

/// Backoff weight of a failure from a roaming peer: its first failure blocks it for 4 s, the
/// second for 32 s, then 60 s (instead of 1, 2, 4 …).
pub const ROAMING_FAILURE_WEIGHT: u32 = 3;

/// How long an unpaired viewer accepts pairing from a Mac that connects to it (`net::pairing_gate`),
/// counted from startup (which includes the setup dialog's Connect, which restarts the viewer),
/// opening *Set up…*, or the tray's *Allow the Mac to pair*. Long enough to walk to the Mac and
/// open *Pair New Viewer…* there; outside it, a LAN host can't raise the pairing prompt at will.
pub const INBOUND_PAIRING_WINDOW: Duration = Duration::from_secs(15 * 60);

/// This PC's inbound pairing window.
#[derive(Debug, Clone, Copy)]
pub struct PairingWindow {
    until: Instant,
}

impl PairingWindow {
    /// Open for `INBOUND_PAIRING_WINDOW` from `now`.
    pub fn opened_at(now: Instant) -> PairingWindow {
        PairingWindow { until: now + INBOUND_PAIRING_WINDOW }
    }

    /// (Re)open for `INBOUND_PAIRING_WINDOW` from `now` (never shortens it).
    pub fn open(&mut self, now: Instant) {
        self.until = self.until.max(now + INBOUND_PAIRING_WINDOW);
    }

    /// Close it (a pairing succeeded).
    pub fn close(&mut self, now: Instant) {
        self.until = self.until.min(now);
    }

    pub fn remaining(&self, now: Instant) -> Option<Duration> {
        (now < self.until).then(|| self.until - now)
    }

    pub fn is_open(&self, now: Instant) -> bool {
        self.remaining(now).is_some()
    }
}

pub const BACKOFF_START: Duration = Duration::from_secs(1);
pub const BACKOFF_MAX: Duration = Duration::from_secs(60);

/// While the allowlist is unpinned: more than this many failed handshakes (all peers) within
/// `GLOBAL_WINDOW` refuses every unpinned peer for `GLOBAL_LOCKOUT`.
pub const GLOBAL_FAILURES: usize = 10;
pub const GLOBAL_WINDOW: Duration = Duration::from_secs(60);
pub const GLOBAL_LOCKOUT: Duration = Duration::from_secs(60);

/// Backoff bucket for an address: IPv4 per address, IPv6 per /64 (a peer can rotate freely
/// within its /64), IPv4-mapped IPv6 as its IPv4.
pub fn backoff_key(ip: IpAddr) -> IpAddr {
    match canonical(ip) {
        IpAddr::V6(v6) => IpAddr::V6(std::net::Ipv6Addr::from(u128::from(v6) & (u128::MAX << 64))),
        v4 => v4,
    }
}

/// Exponential backoff after failed handshakes, per IPv4 address / IPv6 /64, plus a global
/// failure budget that applies while no host is pinned.
#[derive(Debug, Default)]
pub struct Backoff {
    /// key → (consecutive failures, blocked until)
    state: HashMap<IpAddr, (u32, Instant)>,
    /// Times of recent failed handshakes (any peer), for the global budget.
    recent: std::collections::VecDeque<Instant>,
    global_until: Option<Instant>,
}

impl Backoff {
    /// Some(remaining) if connections from `ip` must be dropped right now.
    pub fn blocked(&self, ip: IpAddr, now: Instant) -> Option<Duration> {
        let (_, until) = self.state.get(&backoff_key(ip))?;
        (now < *until).then(|| *until - now)
    }

    /// Some(remaining) while the global budget is exhausted. Only enforced for *unpinned*
    /// peers (empty allowlist); an allowlisted host is never affected.
    pub fn global_blocked(&self, now: Instant) -> Option<Duration> {
        let until = self.global_until?;
        (now < until).then(|| until - now)
    }

    /// Record a failed handshake; returns the new block duration (1 s, 2 s, 4 s … 60 s).
    pub fn failed(&mut self, ip: IpAddr, now: Instant) -> Duration {
        self.failed_weighted(ip, now, 1)
    }

    /// `failed`, counting as `weight` consecutive failures (`ROAMING_FAILURE_WEIGHT`).
    pub fn failed_weighted(&mut self, ip: IpAddr, now: Instant, weight: u32) -> Duration {
        let e = self.state.entry(backoff_key(ip)).or_insert((0, now));
        e.0 = e.0.saturating_add(weight.max(1));
        let d = BACKOFF_START.saturating_mul(1u32 << (e.0 - 1).min(16)).min(BACKOFF_MAX);
        e.1 = now + d;
        // Bound memory: forget long-expired entries.
        if self.state.len() > 1024 {
            self.state.retain(|_, (_, until)| now < *until + BACKOFF_MAX);
        }
        // Global budget.
        self.recent.push_back(now);
        while self.recent.front().is_some_and(|t| now.duration_since(*t) > GLOBAL_WINDOW) {
            self.recent.pop_front();
        }
        if self.recent.len() > GLOBAL_FAILURES {
            self.global_until = Some(now + GLOBAL_LOCKOUT);
            self.recent.clear();
        }
        d
    }

    /// A successful authenticated session clears the peer's record.
    pub fn succeeded(&mut self, ip: IpAddr) {
        self.state.remove(&backoff_key(ip));
    }
}

/// Listen mode: accept the next *admitted* peer and run the handshake with it.
/// - Peers refused by `admit` (not in `allowed_peers` and not a roaming paired Mac, in a backoff
///   window, or over the global budget) are dropped right after accept(), before any handshake
///   byte is sent or read; `refused` gets a line saying so (the GUI's status line).
/// - A peer that doesn't complete the handshake within `deadline` is cut off (and backed off).
/// - A failed handshake that `classify` counts starts/extends that IP's (IPv6: /64's) backoff; a
///   successful one clears it.
/// - While nothing is pinned (empty allowlist), and for roaming peers, a global failure budget
///   applies too.
///
/// Ok(None) = interrupted by quit/pause.
pub fn accept_admitted(
    listener: &std::net::TcpListener,
    auth: &Auth,
    hello: &ClientMsg,
    abort: &AtomicBool,
    allowed_peers: &dyn Fn() -> Vec<String>,
    backoff: &mut Backoff,
    deadline: Duration,
) -> Result<Option<(Connection, IpAddr)>, ConnectError> {
    accept_admitted_within(listener, auth, hello, abort, allowed_peers, backoff, deadline, None, &|_| {})
}

/// `accept_admitted`, giving up with Ok(None) when no admitted peer has connected within `wait`
/// (both mode alternates between dialing and accepting). `Some(Duration::ZERO)` only takes a
/// connection that is already waiting in the backlog.
pub fn accept_admitted_within(
    listener: &std::net::TcpListener,
    auth: &Auth,
    hello: &ClientMsg,
    abort: &AtomicBool,
    allowed_peers: &dyn Fn() -> Vec<String>,
    backoff: &mut Backoff,
    deadline: Duration,
    wait: Option<Duration>,
    refused: &dyn Fn(String),
) -> Result<Option<(Connection, IpAddr)>, ConnectError> {
    listener.set_nonblocking(true).map_err(ConnectError::Io)?;
    let give_up = wait.map(|w| Instant::now() + w);
    loop {
        if abort.load(Ordering::Relaxed) {
            return Ok(None);
        }
        let (stream, peer) = match listener.accept() {
            Ok(x) => x,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if give_up.is_some_and(|t| Instant::now() >= t) {
                    return Ok(None);
                }
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            Err(e) => return Err(ConnectError::Io(e)),
        };
        let ip = canonical(peer.ip());
        let allowed = allowed_peers();
        let roaming = match admit(&allowed, ip, auth.pinned.is_some(), backoff, Instant::now()) {
            Admission::Admit => false,
            Admission::Roaming => {
                eprintln!("{peer} is not in allowed_peers {allowed:?}, but a host key is pinned: admitting it to prove it is the paired Mac (new address?)");
                true
            }
            Admission::Refuse(r) => {
                let line = r.describe(ip);
                eprintln!("{line} (allowed_peers {allowed:?})");
                refused(line);
                continue; // dropping the stream closes it
            }
        };
        let weight = if roaming { ROAMING_FAILURE_WEIGHT } else { 1 };
        // Accepted sockets inherit non-blocking mode on Windows.
        stream.set_nonblocking(false).map_err(ConnectError::Io)?;
        eprintln!("host connected from {peer}");
        let timer = PreAuthDeadline::arm(&stream, deadline);
        // Pairing (authenticated, waits for the user) lifts the pre-auth deadline.
        let res = Connection::from_stream_timeout(
            stream,
            auth,
            hello,
            deadline,
            &|| {
                timer.disarm();
            },
            Some(ip),
        );
        let timed_out = timer.disarm();
        match res {
            Ok(c) if !timed_out => {
                backoff.succeeded(ip);
                return Ok(Some((c, ip)));
            }
            Ok(c) => {
                c.stop();
                let d = backoff.failed_weighted(ip, Instant::now(), weight);
                eprintln!("handshake from {peer} exceeded {deadline:?}; refusing {ip} for {d:?}");
                return Err(ConnectError::Protocol("handshake timed out".into()));
            }
            Err(e) => {
                let e = match e {
                    // The deadline fired and shut the socket down: whatever the read reports (a
                    // timeout on macOS/Windows, end of file on Linux, which would read as "v1
                    // host"), the peer was too slow. Always a failed attempt.
                    _ if timed_out => ConnectError::Protocol(format!("handshake timed out after {deadline:?}")),
                    // Not the address pinned for the Mac and not its key: just some other host,
                    // not a reason for a "HOST KEY CHANGED" alarm.
                    ConnectError::HostKeyChanged { presented, .. } if roaming => ConnectError::Protocol(format!(
                        "{ip} is not in allowed_peers and is not the paired Mac (key {})",
                        crate::handshake::fingerprint(&presented)
                    )),
                    e => e,
                };
                match classify(&e, roaming) {
                    Outcome::Neutral => eprintln!("handshake from {peer} ended: {e} (not counted as a failed attempt)"),
                    Outcome::Failure => {
                        let d = backoff.failed_weighted(ip, Instant::now(), weight);
                        eprintln!("handshake from {peer} failed: {e}; refusing {ip} for {d:?}");
                    }
                }
                return Err(e);
            }
        }
    }
}

/// Closes a socket if the handshake hasn't finished by the deadline (a slow-drip peer could
/// otherwise stretch the per-read timeout indefinitely while blocking the listener).
struct PreAuthDeadline {
    state: Arc<Mutex<(bool, bool)>>, // (done, fired)
}

impl PreAuthDeadline {
    fn arm(stream: &std::net::TcpStream, after: Duration) -> PreAuthDeadline {
        let state = Arc::new(Mutex::new((false, false)));
        if let Ok(s) = stream.try_clone() {
            let st = state.clone();
            let end = Instant::now() + after;
            std::thread::spawn(move || {
                while Instant::now() < end {
                    if st.lock().unwrap().0 {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
                let mut g = st.lock().unwrap();
                if !g.0 {
                    g.1 = true;
                    let _ = s.shutdown(std::net::Shutdown::Both);
                }
            });
        }
        PreAuthDeadline { state }
    }

    /// Stop the timer; returns true if it already fired (the socket was shut down).
    fn disarm(&self) -> bool {
        let mut g = self.state.lock().unwrap();
        g.0 = true;
        g.1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn parse_and_match() {
        let n = parse_net("192.168.50.0/24").unwrap();
        assert!(n.contains(ip("192.168.50.4")));
        assert!(!n.contains(ip("192.168.10.4")));
        assert!(n.contains(ip("::ffff:192.168.50.200")), "v4-mapped v6 matches v4 rules");
        let host = parse_net(" 192.168.50.4 ").unwrap();
        assert_eq!(host.prefix, 32);
        assert!(host.contains(ip("192.168.50.4")) && !host.contains(ip("192.168.50.5")));
        assert!(parse_net("0.0.0.0/0").unwrap().contains(ip("1.2.3.4")));
        let v6 = parse_net("fd00::/8").unwrap();
        assert!(v6.contains(ip("fd12::1")) && !v6.contains(ip("fe80::1")) && !v6.contains(ip("10.0.0.1")));
        assert!(parse_net("::/0").unwrap().contains(ip("::1")));
        assert_eq!(parse_net("::ffff:10.0.0.1").unwrap().addr, ip("10.0.0.1"));
        for bad in ["", "10.0.0", "10.0.0.1/33", "fd00::/129", "10.0.0.1/x", "host.local"] {
            assert!(parse_net(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn allowlist() {
        assert!(is_allowed(&[], ip("1.2.3.4")), "empty = not pinned yet");
        let l = vec!["192.168.50.4".to_string(), "192.168.1.0/24".to_string()];
        assert!(is_allowed(&l, ip("192.168.50.4")));
        assert!(is_allowed(&l, ip("192.168.1.77")));
        assert!(!is_allowed(&l, ip("192.168.50.5")));
        let junk = vec!["not-an-ip".to_string()];
        assert!(!is_allowed(&junk, ip("192.168.50.4")), "fail closed on a list of only bad entries");
        assert_eq!(invalid_entries(&junk), junk);
        assert!(invalid_entries(&l).is_empty());
    }

    #[test]
    fn tofu_pins_once() {
        let mut l = Vec::new();
        assert!(pin_first(&mut l, ip("::ffff:192.168.50.4")));
        assert_eq!(l, vec!["192.168.50.4"]);
        assert!(!pin_first(&mut l, ip("192.168.10.9")), "already pinned");
        assert_eq!(l.len(), 1);
        assert!(is_allowed(&l, ip("192.168.50.4")) && !is_allowed(&l, ip("192.168.10.9")));
    }

    #[test]
    fn ipv6_backoff_is_per_64() {
        let mut b = Backoff::default();
        let t0 = Instant::now();
        b.failed(ip("2001:db8:1:2::1"), t0);
        assert!(b.blocked(ip("2001:db8:1:2:ffff:1234:5678:9abc"), t0).is_some(), "same /64");
        assert!(b.blocked(ip("2001:db8:1:3::1"), t0).is_none(), "other /64");
        assert_eq!(b.failed(ip("2001:db8:1:2::77"), t0), Duration::from_secs(2), "rotation keeps doubling");
        assert_eq!(backoff_key(ip("::ffff:10.0.0.9")), ip("10.0.0.9"));
        assert_eq!(backoff_key(ip("10.0.0.9")), ip("10.0.0.9"), "IPv4 stays per address");
        b.failed(ip("10.0.0.9"), t0);
        assert!(b.blocked(ip("10.0.0.10"), t0).is_none());
    }

    #[test]
    fn global_budget() {
        let mut b = Backoff::default();
        let t0 = Instant::now();
        // failures spread over time don't trip it
        for i in 0..30u64 {
            b.failed(ip(&format!("10.1.0.{i}")), t0 + Duration::from_secs(i * 7));
        }
        assert!(b.global_blocked(t0 + Duration::from_secs(211)).is_none());
        // > 10 within 60 s from distinct peers does
        let t1 = t0 + Duration::from_secs(1000);
        for i in 0..GLOBAL_FAILURES {
            b.failed(ip(&format!("10.2.0.{i}")), t1);
            assert!(b.global_blocked(t1).is_none(), "{i}");
        }
        b.failed(ip("10.2.0.99"), t1);
        assert_eq!(b.global_blocked(t1), Some(GLOBAL_LOCKOUT));
        assert!(b.global_blocked(t1 + GLOBAL_LOCKOUT).is_none(), "expires");
    }

    #[test]
    fn what_counts_as_a_failed_attempt() {
        use crate::protocol::*;
        use Outcome::*;
        let cases: Vec<(ConnectError, Outcome, Outcome)> = vec![
            // (error, from an allowlisted/unpinned peer, from a roaming peer)
            (ConnectError::Rejected(AUTH_UNKNOWN_VIEWER), Neutral, Neutral),
            (ConnectError::Rejected(AUTH_PAIRING_CLOSED), Neutral, Neutral),
            (ConnectError::Rejected(AUTH_BUSY), Neutral, Neutral),
            (ConnectError::HostPairingClosed, Neutral, Neutral),
            (ConnectError::InboundPairingClosed { peer: "192.168.50.9".into() }, Neutral, Neutral),
            (ConnectError::HostIsV1, Neutral, Failure),
            (ConnectError::Rejected(AUTH_DECLINED), Failure, Failure),
            (ConnectError::Rejected(AUTH_TIMEOUT), Failure, Failure),
            (ConnectError::Rejected(77), Failure, Failure),
            (ConnectError::PairingCancelled, Failure, Failure),
            (ConnectError::PairingFailed("x".into()), Failure, Failure),
            (ConnectError::HostKeyChanged { pinned: [1; 32], presented: [2; 32] }, Failure, Failure),
            (ConnectError::Refused { status: 3, version: 2 }, Failure, Failure),
            (ConnectError::Protocol("handshake timed out".into()), Failure, Failure),
            (ConnectError::Io(std::io::Error::new(std::io::ErrorKind::TimedOut, "t")), Failure, Failure),
        ];
        for (e, normal, roaming) in cases {
            assert_eq!(classify(&e, false), normal, "{e:?}");
            assert_eq!(classify(&e, true), roaming, "{e:?} (roaming)");
        }
    }

    #[test]
    fn admission_lets_the_paired_mac_roam() {
        let b = Backoff::default();
        let t = Instant::now();
        let tofu = vec!["192.168.50.4".to_string()];
        let new = ip("192.168.50.77");
        assert_eq!(admit(&tofu, ip("192.168.50.4"), true, &b, t), Admission::Admit);
        assert_eq!(admit(&tofu, new, true, &b, t), Admission::Roaming, "pinned key: may prove it is the Mac");
        assert_eq!(admit(&tofu, new, false, &b, t), Admission::Refuse(Refusal::NotAllowed), "no pinned key: nothing to prove");
        assert_eq!(admit(&[], new, false, &b, t), Admission::Admit, "nothing pinned yet");
        // hand-written lists don't roam
        for strict in [vec!["192.168.50.4/32".to_string()], vec!["192.168.50.4".into(), "192.168.50.5".into()], vec!["junk".into()]] {
            assert!(!is_roamable(&strict), "{strict:?}");
            assert_eq!(admit(&strict, new, true, &b, t), Admission::Refuse(Refusal::NotAllowed), "{strict:?}");
        }
        assert!(is_roamable(&tofu) && is_roamable(&["fd00::4".to_string()]) && !is_roamable(&[]));
        // a roaming peer is subject to the global budget, the allowlisted Mac isn't
        let mut b = Backoff::default();
        for i in 0..=GLOBAL_FAILURES {
            b.failed(ip(&format!("10.4.0.{i}")), t);
        }
        assert!(matches!(admit(&tofu, new, true, &b, t), Admission::Refuse(Refusal::Global(_))));
        assert_eq!(admit(&tofu, ip("192.168.50.4"), true, &b, t), Admission::Admit);
        // and to its own backoff, which starts harsher
        let mut b = Backoff::default();
        assert_eq!(b.failed_weighted(new, t, ROAMING_FAILURE_WEIGHT), Duration::from_secs(4));
        assert_eq!(admit(&tofu, new, true, &b, t), Admission::Refuse(Refusal::Backoff(Duration::from_secs(4))));
        assert_eq!(b.failed_weighted(new, t, ROAMING_FAILURE_WEIGHT), Duration::from_secs(32));
        assert_eq!(b.failed_weighted(new, t, ROAMING_FAILURE_WEIGHT), BACKOFF_MAX);
        let line = Refusal::Backoff(Duration::from_millis(3200)).describe(new);
        assert!(line.contains("192.168.50.77") && line.contains("4 s"), "{line}");
        assert!(Refusal::NotAllowed.describe(new).contains("allowed_peers"));
    }

    #[test]
    fn pin_follows_the_paired_mac() {
        let mut l = Vec::new();
        assert_eq!(pin_after_session(&mut l, ip("::ffff:192.168.50.4")), PinChange::Pinned);
        assert_eq!(l, vec!["192.168.50.4"]);
        assert_eq!(pin_after_session(&mut l, ip("192.168.50.4")), PinChange::Unchanged);
        assert_eq!(pin_after_session(&mut l, ip("192.168.50.77")), PinChange::Moved { from: "192.168.50.4".into() });
        assert_eq!(l, vec!["192.168.50.77"], "replaced, not appended (no growing list of old leases)");
        let mut strict = vec!["192.168.50.0/24".to_string()];
        assert_eq!(pin_after_session(&mut strict, ip("10.0.0.9")), PinChange::Unchanged);
        assert_eq!(strict, vec!["192.168.50.0/24"]);
    }

    #[test]
    fn inbound_pairing_window() {
        let t = Instant::now();
        let mut w = PairingWindow::opened_at(t);
        assert!(w.is_open(t + INBOUND_PAIRING_WINDOW - Duration::from_secs(1)));
        assert!(!w.is_open(t + INBOUND_PAIRING_WINDOW));
        let later = t + Duration::from_secs(3600);
        w.open(later);
        assert_eq!(w.remaining(later), Some(INBOUND_PAIRING_WINDOW));
        w.open(t); // never shortens
        assert_eq!(w.remaining(later), Some(INBOUND_PAIRING_WINDOW));
        w.close(later + Duration::from_secs(5));
        assert!(!w.is_open(later + Duration::from_secs(5)));
    }

    #[test]
    fn backoff_doubles_to_a_minute() {
        let mut b = Backoff::default();
        let t0 = Instant::now();
        let a = ip("192.168.10.9");
        assert_eq!(b.blocked(a, t0), None);
        let ds: Vec<u64> = (0..9).map(|_| b.failed(a, t0).as_secs()).collect();
        assert_eq!(ds, vec![1, 2, 4, 8, 16, 32, 60, 60, 60]);
        assert_eq!(b.blocked(a, t0 + Duration::from_secs(59)), Some(Duration::from_secs(1)));
        assert_eq!(b.blocked(a, t0 + Duration::from_secs(60)), None);
        // other IPs unaffected; success resets
        assert_eq!(b.blocked(ip("192.168.50.4"), t0), None);
        b.succeeded(a);
        assert_eq!(b.blocked(a, t0), None);
        assert_eq!(b.failed(a, t0), Duration::from_secs(1));
        // v4-mapped form shares the record
        assert!(b.blocked(ip("::ffff:192.168.10.9"), t0).is_some());
        // many failures never overflow
        for _ in 0..100 {
            b.failed(a, t0);
        }
        assert_eq!(b.failed(a, t0), BACKOFF_MAX);
    }
}

#[cfg(test)]
mod accept_tests {
    use super::*;
    use crate::identity::Identity;
    use crate::net::tests::{auth, hello, TestUi};
    use crate::testhost::{serve, HostCfg, Outcome};
    use std::io::Read;
    use std::net::{TcpListener, TcpStream};

    /// Run accept_admitted on a loopback listener in a thread; return (bytes the peer received
    /// before the viewer closed, backoff after).
    fn probe(allowed: Vec<String>, mut backoff: Backoff, deadline: Duration) -> (usize, Backoff, String) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = Arc::new(AtomicBool::new(false));
        let ab = abort.clone();
        let t = std::thread::spawn(move || {
            let allowed_fn = move || allowed.clone();
            let a = auth(&Identity::generate(), None, TestUi::new(true));
            let r = accept_admitted(&l, &a, &hello(), &ab, &allowed_fn, &mut backoff, deadline);
            let what = match r {
                Ok(Some(_)) => "connected".to_string(),
                Ok(None) => "aborted".to_string(),
                Err(e) => format!("err: {e}"),
            };
            (backoff, what)
        });
        let mut c = TcpStream::connect(addr).unwrap();
        c.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut got = Vec::new();
        let _ = c.read_to_end(&mut got); // EOF when the viewer drops/shuts the socket
        std::thread::sleep(Duration::from_millis(100));
        abort.store(true, Ordering::Relaxed);
        let (b, what) = t.join().unwrap();
        (got.len(), b, what)
    }

    /// The viewer's first flight: ClientPreamble + framed msg1.
    const FIRST_FLIGHT: usize = crate::handshake::CLIENT_PREAMBLE_LEN + 2 + 32;

    #[test]
    fn not_allowlisted_is_dropped_before_handshake() {
        let (n, b, what) = probe(vec!["10.9.9.9".into()], Backoff::default(), Duration::from_secs(5));
        assert_eq!(n, 0, "no handshake byte may be sent to a non-allowlisted peer");
        assert_eq!(what, "aborted");
        assert!(b.blocked("127.0.0.1".parse().unwrap(), Instant::now()).is_none(), "refusals don't count as failures");
    }

    #[test]
    fn backed_off_peer_is_dropped_before_handshake() {
        let mut b = Backoff::default();
        b.failed("127.0.0.1".parse().unwrap(), Instant::now());
        let (n, _, what) = probe(vec![], b, Duration::from_secs(5));
        assert_eq!(n, 0);
        assert_eq!(what, "aborted");
    }

    #[test]
    fn idle_preauth_peer_is_cut_off_and_backed_off() {
        let t0 = Instant::now();
        let (n, b, what) = probe(vec!["127.0.0.0/8".into()], Backoff::default(), Duration::from_millis(300));
        assert_eq!(n, FIRST_FLIGHT, "allowed peer gets the first flight, then is cut off");
        assert!(what.starts_with("err"), "{what}");
        assert!(t0.elapsed() < Duration::from_secs(3), "deadline, not the 5 s read timeout");
        assert!(b.blocked("127.0.0.1".parse().unwrap(), Instant::now()).is_some());
    }

    /// The fake host dials the listening viewer (like `glide-host --connect`).
    fn dial(addr: std::net::SocketAddr, cfg: HostCfg) -> std::thread::JoinHandle<Outcome> {
        std::thread::spawn(move || serve(TcpStream::connect(addr).unwrap(), &cfg))
    }

    #[test]
    fn failed_handshake_backs_off_and_success_clears_it() {
        let lo: IpAddr = "127.0.0.1".parse().unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = AtomicBool::new(false);
        let none = || Vec::<String>::new();
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let a = auth(&viewer, Some(host.public()), TestUi::new(true));
        let mut b = Backoff::default();
        // impostor host (different key) → key mismatch, IP backed off
        let h = dial(addr, HostCfg::new(Identity::generate()));
        let r = accept_admitted(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5));
        assert!(matches!(r, Err(ConnectError::HostKeyChanged { .. })), "{:?}", r.as_ref().err());
        assert!(matches!(h.join().unwrap(), Outcome::Closed(_)));
        assert!(b.blocked(lo, Instant::now()).is_some());
        // after the window expires, the real host connects and clears the record
        let mut b = Backoff::default();
        b.failed(lo, Instant::now() - Duration::from_secs(2));
        let mut cfg = HostCfg::new(host.clone());
        cfg.paired = vec![viewer.public()];
        let h = dial(addr, cfg);
        let r = accept_admitted(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5));
        let (conn, ip) = r.unwrap().unwrap();
        assert!(matches!(h.join().unwrap(), Outcome::Streaming { .. }));
        assert_eq!((conn.host_name.as_str(), ip), ("fake", lo));
        assert_eq!(b.failed(lo, Instant::now()), BACKOFF_START, "success reset the doubling");
        // TOFU pin of the authenticated peer's IP
        let mut allowed = Vec::new();
        assert!(pin_first(&mut allowed, ip));
        assert_eq!(allowed, vec!["127.0.0.1"]);
    }

    #[test]
    fn bounded_accept_gives_up_and_takes_the_backlog() {
        // Both mode: no host dialing in → Ok(None) after the wait; a host that connected while
        // the viewer was busy dialing waits in the backlog and is taken even with a zero wait.
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = AtomicBool::new(false);
        let none = || Vec::<String>::new();
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let a = auth(&viewer, Some(host.public()), TestUi::new(true));
        let mut b = Backoff::default();
        let t0 = Instant::now();
        let r = accept_admitted_within(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5), Some(Duration::from_millis(150)), &|_| {});
        assert!(matches!(r, Ok(None)));
        assert!(t0.elapsed() >= Duration::from_millis(150) && t0.elapsed() < Duration::from_secs(3));
        let mut cfg = HostCfg::new(host.clone());
        cfg.paired = vec![viewer.public()];
        let h = dial(addr, cfg);
        std::thread::sleep(Duration::from_millis(100)); // the connect completes into the backlog
        let r = accept_admitted_within(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5), Some(Duration::ZERO), &|_| {});
        let (conn, _) = r.unwrap().unwrap();
        assert_eq!(conn.host_key, host.public());
        assert!(matches!(h.join().unwrap(), Outcome::Streaming { .. }));
    }

    #[test]
    fn pairing_outlives_the_preauth_deadline() {
        // Listen mode, unpaired: the user takes longer than the 300 ms pre-auth deadline to compare
        // codes; the pairing phase must not be cut off.
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = AtomicBool::new(false);
        let none = || Vec::<String>::new();
        let host = Identity::generate();
        let ui = Arc::new(TestUi { delay: Duration::from_millis(800), ..Arc::try_unwrap(TestUi::new(true)).ok().unwrap() });
        let a = auth(&Identity::generate(), None, ui);
        let mut cfg = HostCfg::new(host.clone());
        cfg.pairing_open = true;
        let h = dial(addr, cfg);
        let mut b = Backoff::default();
        let (conn, _) = accept_admitted(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_millis(300)).unwrap().unwrap();
        assert!(conn.paired && conn.host_key == host.public());
        assert!(matches!(h.join().unwrap(), Outcome::Streaming { paired_now: true, .. }));
    }

    /// Finding: an unpaired PC counted the real Mac's "pairing closed" answers as failures and then
    /// silently dropped the Mac's immediate redial when the user opened its pairing window.
    #[test]
    fn pairing_closed_does_not_block_the_redial() {
        let lo: IpAddr = "127.0.0.1".parse().unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = AtomicBool::new(false);
        let none = || Vec::<String>::new();
        let host = Identity::generate();
        let ui = TestUi::new(true);
        let a = auth(&Identity::generate(), None, ui.clone());
        let mut b = Backoff::default();
        // the Mac dials while its pairing window is closed, several times
        for _ in 0..3 {
            let h = dial(addr, HostCfg::new(host.clone()));
            let r = accept_admitted(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5));
            assert!(matches!(r, Err(ConnectError::HostPairingClosed)), "{:?}", r.err());
            assert!(matches!(h.join().unwrap(), Outcome::Closed(_)));
            assert!(b.blocked(lo, Instant::now()).is_none(), "not counted");
        }
        assert!(ui.shown.lock().unwrap().is_empty());
        // the user opens Pair New Viewer…: the redial is taken at once and pairs
        let mut cfg = HostCfg::new(host.clone());
        cfg.pairing_open = true;
        let h = dial(addr, cfg);
        let (conn, _) = accept_admitted(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5)).unwrap().unwrap();
        assert!(conn.paired);
        assert!(matches!(h.join().unwrap(), Outcome::Streaming { paired_now: true, .. }));
        let shown = ui.shown.lock().unwrap();
        assert_eq!((shown[0].peer.as_str(), shown[0].inbound), ("127.0.0.1", true), "the prompt names the peer that connected");
    }

    #[test]
    fn abandoned_backlog_connection_is_not_a_failure() {
        // The Mac gave up on a connection while it waited in the backlog: EOF before any host byte.
        let lo: IpAddr = "127.0.0.1".parse().unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        drop(TcpStream::connect(l.local_addr().unwrap()).unwrap());
        std::thread::sleep(Duration::from_millis(50));
        let abort = AtomicBool::new(false);
        let none = || Vec::<String>::new();
        let a = auth(&Identity::generate(), None, TestUi::new(true));
        let mut b = Backoff::default();
        let r = accept_admitted_within(&l, &a, &hello(), &abort, &none, &mut b, Duration::from_secs(5), Some(Duration::ZERO), &|_| {});
        assert!(matches!(r, Err(ConnectError::HostIsV1)), "{:?}", r.as_ref().err());
        assert!(b.blocked(lo, Instant::now()).is_none());
    }

    #[test]
    fn the_paired_mac_may_come_back_from_a_new_address() {
        // TOFU pinned the Mac's old DHCP lease; it now connects from 127.0.0.1.
        let lo: IpAddr = "127.0.0.1".parse().unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = AtomicBool::new(false);
        let old = || vec!["192.168.50.4".to_string()];
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let a = auth(&viewer, Some(host.public()), TestUi::new(true));
        let mut b = Backoff::default();
        // a different host from the new address: refused before msg3, no key-change alarm, 4 s
        let h = dial(addr, HostCfg::new(Identity::generate()));
        let r = accept_admitted(&l, &a, &hello(), &abort, &old, &mut b, Duration::from_secs(5));
        assert!(matches!(r, Err(ConnectError::Protocol(ref s)) if s.contains("not the paired Mac")), "{:?}", r.as_ref().err());
        assert!(matches!(h.join().unwrap(), Outcome::Closed(ref s) if s.contains("before msg3")));
        let left = b.blocked(lo, Instant::now()).unwrap();
        assert!(left > Duration::from_secs(3), "roaming failures back off harder ({left:?})");
        // the real Mac (pinned key) connects from the new address and the pin follows it
        let mut b = Backoff::default();
        let mut cfg = HostCfg::new(host.clone());
        cfg.paired = vec![viewer.public()];
        let h = dial(addr, cfg);
        let (conn, ip) = accept_admitted(&l, &a, &hello(), &abort, &old, &mut b, Duration::from_secs(5)).unwrap().unwrap();
        assert_eq!(conn.host_key, host.public());
        assert!(matches!(h.join().unwrap(), Outcome::Streaming { .. }));
        let mut allowed = old();
        assert_eq!(pin_after_session(&mut allowed, ip), PinChange::Moved { from: "192.168.50.4".into() });
        assert_eq!(allowed, vec!["127.0.0.1"]);
    }

    #[test]
    fn refusals_are_reported() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let _c = TcpStream::connect(l.local_addr().unwrap()).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let abort = AtomicBool::new(false);
        let other = || vec!["192.168.50.0/24".to_string()];
        let a = auth(&Identity::generate(), Some([9; 32]), TestUi::new(true));
        let mut b = Backoff::default();
        let lines = Mutex::new(Vec::new());
        let r = accept_admitted_within(&l, &a, &hello(), &abort, &other, &mut b, Duration::from_secs(5), Some(Duration::from_millis(100)), &|s| {
            lines.lock().unwrap().push(s)
        });
        assert!(matches!(r, Ok(None)));
        let lines = lines.into_inner().unwrap();
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(lines[0].contains("127.0.0.1") && lines[0].contains("allowed_peers"), "{lines:?}");
    }

    #[test]
    fn global_lockout_spares_pinned_hosts() {
        let mut b = Backoff::default();
        let t = Instant::now();
        for i in 0..=GLOBAL_FAILURES {
            b.failed(format!("10.3.0.{i}").parse().unwrap(), t);
        }
        assert!(b.global_blocked(Instant::now()).is_some());
        // unpinned: everyone refused before the handshake
        let (n, b, what) = probe(vec![], b, Duration::from_millis(300));
        assert_eq!((n, what.as_str()), (0, "aborted"));
        // pinned + allowlisted: still gets the handshake
        let (n, _, _) = probe(vec!["127.0.0.1".into()], b, Duration::from_millis(300));
        assert_eq!(n, FIRST_FLIGHT);
    }
}
