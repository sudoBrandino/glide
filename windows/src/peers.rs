//! Listen-mode admission control (defense in depth until the protocol gets a PAKE, security v2).
//!
//! In `--listen` mode anyone who can reach the port can start a handshake. Before a single
//! handshake byte is exchanged the viewer:
//! - drops peers not in `allowed_peers` (IPs or CIDRs) when that list is non-empty;
//! - drops peers that are in a failed-handshake backoff window (1 s doubling to 60 s per IP).
//!
//! With an empty list the first peer that completes an authenticated session is pinned
//! (trust on first use). Pure Rust; unit-tested.

use crate::net::{ConnectError, Connection};
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

pub const BACKOFF_START: Duration = Duration::from_secs(1);
pub const BACKOFF_MAX: Duration = Duration::from_secs(60);

/// Per-IP exponential backoff after failed handshakes.
#[derive(Debug, Default)]
pub struct Backoff {
    /// ip → (consecutive failures, blocked until)
    state: HashMap<IpAddr, (u32, Instant)>,
}

impl Backoff {
    /// Some(remaining) if connections from `ip` must be dropped right now.
    pub fn blocked(&self, ip: IpAddr, now: Instant) -> Option<Duration> {
        let (_, until) = self.state.get(&canonical(ip))?;
        (now < *until).then(|| *until - now)
    }

    /// Record a failed handshake; returns the new block duration (1 s, 2 s, 4 s … 60 s).
    pub fn failed(&mut self, ip: IpAddr, now: Instant) -> Duration {
        let e = self.state.entry(canonical(ip)).or_insert((0, now));
        e.0 = e.0.saturating_add(1);
        let d = BACKOFF_START.saturating_mul(1u32 << (e.0 - 1).min(16)).min(BACKOFF_MAX);
        e.1 = now + d;
        // Bound memory: forget long-expired entries.
        if self.state.len() > 1024 {
            self.state.retain(|_, (_, until)| now < *until + BACKOFF_MAX);
        }
        d
    }

    /// A successful authenticated session clears the IP's record.
    pub fn succeeded(&mut self, ip: IpAddr) {
        self.state.remove(&canonical(ip));
    }
}

/// Listen mode: accept the next *admitted* peer and run the handshake with it.
/// - Peers not in `allowed_peers` (when non-empty) and peers in a failed-handshake backoff window
///   are dropped right after accept(), before any handshake byte is sent or read.
/// - A peer that doesn't complete the handshake within `deadline` is cut off (and backed off).
/// - Any failed handshake starts/extends that IP's backoff; a successful one clears it.
///
/// Ok(None) = interrupted by quit/pause.
pub fn accept_admitted(
    listener: &std::net::TcpListener,
    password: &str,
    hello: &ClientMsg,
    abort: &AtomicBool,
    allowed_peers: &dyn Fn() -> Vec<String>,
    backoff: &mut Backoff,
    deadline: Duration,
) -> Result<Option<(Connection, IpAddr)>, ConnectError> {
    listener.set_nonblocking(true).map_err(ConnectError::Io)?;
    loop {
        if abort.load(Ordering::Relaxed) {
            return Ok(None);
        }
        let (stream, peer) = match listener.accept() {
            Ok(x) => x,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            Err(e) => return Err(ConnectError::Io(e)),
        };
        let ip = canonical(peer.ip());
        let allowed = allowed_peers();
        if !is_allowed(&allowed, ip) {
            eprintln!("refused connection from {peer}: not in allowed_peers {allowed:?}");
            continue; // dropping the stream closes it
        }
        if let Some(rem) = backoff.blocked(ip, Instant::now()) {
            eprintln!("refused connection from {peer}: backing off after failed handshakes ({:.0} s left)", rem.as_secs_f64().ceil());
            continue;
        }
        // Accepted sockets inherit non-blocking mode on Windows.
        stream.set_nonblocking(false).map_err(ConnectError::Io)?;
        eprintln!("host connected from {peer}");
        let timer = PreAuthDeadline::arm(&stream, deadline);
        let res = Connection::from_stream(stream, password, hello);
        let timed_out = timer.disarm();
        match res {
            Ok(c) if !timed_out => {
                backoff.succeeded(ip);
                return Ok(Some((c, ip)));
            }
            Ok(c) => {
                c.stop();
                let d = backoff.failed(ip, Instant::now());
                eprintln!("handshake from {peer} exceeded {deadline:?}; refusing {ip} for {d:?}");
                return Err(ConnectError::Protocol("handshake timed out".into()));
            }
            Err(e) => {
                let d = backoff.failed(ip, Instant::now());
                eprintln!("handshake from {peer} failed: {e}; refusing {ip} for {d:?}");
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
    fn disarm(self) -> bool {
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
    use std::io::Read;
    use std::net::{TcpListener, TcpStream};

    fn hello() -> ClientMsg {
        ClientMsg::ClientHello { version: 1, codec_caps: 1, view_w: 1, view_h: 1, mode: 0, max_fps: 60, client_name: "t".into() }
    }

    /// Run accept_admitted on a loopback listener in a thread; return (bytes the peer received
    /// before the viewer closed, backoff after).
    fn probe(allowed: Vec<String>, mut backoff: Backoff, deadline: Duration) -> (usize, Backoff, String) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = Arc::new(AtomicBool::new(false));
        let ab = abort.clone();
        let t = std::thread::spawn(move || {
            let allowed_fn = move || allowed.clone();
            let r = accept_admitted(&l, "pw", &hello(), &ab, &allowed_fn, &mut backoff, deadline);
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
        assert_eq!(n, crate::crypto::CLIENT_HS_LEN, "allowed peer gets the ClientHandshake, then is cut off");
        assert!(what.starts_with("err"), "{what}");
        assert!(t0.elapsed() < Duration::from_secs(3), "deadline, not the 5 s read timeout");
        assert!(b.blocked("127.0.0.1".parse().unwrap(), Instant::now()).is_some());
    }

    /// Minimal host side of the v1 handshake (docs/PROTOCOL.md §1–2). Returns true if the
    /// viewer's ClientHello decrypted (i.e. the passwords matched) and ServerHello was sent.
    fn fake_host(addr: std::net::SocketAddr, password: &str) -> bool {
        use crate::crypto::{derive_keys, pw_key, Opener, Sealer, CLIENT_HS_LEN, HOST_HS_LEN, MAGIC};
        use crate::protocol::{Codec, HostMsg, VideoConfig};
        use std::io::Write;
        use x25519_dalek::{PublicKey, StaticSecret};
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut chs = [0u8; CLIENT_HS_LEN];
        if s.read_exact(&mut chs).is_err() {
            return false;
        }
        let secret = StaticSecret::random_from_rng(rand_core::OsRng);
        let mut hhs = Vec::with_capacity(HOST_HS_LEN);
        hhs.extend_from_slice(MAGIC);
        hhs.extend_from_slice(&1u16.to_le_bytes());
        hhs.extend_from_slice(PublicKey::from(&secret).as_bytes());
        hhs.extend_from_slice(&[7u8; 16]); // nonce
        let salt = [9u8; 16];
        hhs.extend_from_slice(&salt);
        s.write_all(&hhs).unwrap();
        let peer: [u8; 32] = chs[6..38].try_into().unwrap();
        let shared = secret.diffie_hellman(&PublicKey::from(peer));
        let keys = derive_keys(shared.as_bytes(), &pw_key(password, &salt), &chs, &hhs);
        let mut buf = Vec::new();
        if Opener::new(&keys.c2s).read_record(&mut s, &mut buf).is_err() {
            return false; // wrong password: a real host just closes
        }
        let cfg = VideoConfig { width: 64, height: 64, codec: Codec::Hevc, chroma: 0, color: 0, scale: 1.0 };
        let hello = HostMsg::ServerHello { version: 1, host_name: "fake".into(), config: cfg }.encode();
        s.write_all(&Sealer::new(&keys.s2c).seal(&hello)).unwrap();
        true
    }

    #[test]
    fn failed_handshake_backs_off_and_success_clears_it() {
        let lo: IpAddr = "127.0.0.1".parse().unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let abort = AtomicBool::new(false);
        let none = || Vec::<String>::new();
        let mut b = Backoff::default();
        // wrong password → auth failure, IP backed off
        let h = std::thread::spawn(move || fake_host(addr, "not-pw"));
        let r = accept_admitted(&l, "pw", &hello(), &abort, &none, &mut b, Duration::from_secs(5));
        assert!(matches!(r, Err(ref e) if e.is_auth_failure()), "{:?}", r.as_ref().err());
        assert!(!h.join().unwrap());
        assert!(b.blocked(lo, Instant::now()).is_some());
        // after the window expires, the right password connects and clears the record
        let mut b = Backoff::default();
        b.failed(lo, Instant::now() - Duration::from_secs(2));
        let h = std::thread::spawn(move || fake_host(addr, "pw"));
        let r = accept_admitted(&l, "pw", &hello(), &abort, &none, &mut b, Duration::from_secs(5));
        let (conn, ip) = r.unwrap().unwrap();
        assert!(h.join().unwrap());
        assert_eq!((conn.host_name.as_str(), ip), ("fake", lo));
        assert_eq!(b.failed(lo, Instant::now()), BACKOFF_START, "success reset the doubling");
        // TOFU pin of the authenticated peer
        let mut allowed = Vec::new();
        assert!(pin_first(&mut allowed, ip));
        assert_eq!(allowed, vec!["127.0.0.1"]);
    }
}
