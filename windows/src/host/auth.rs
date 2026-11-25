//! Host side of the Glide v2 handshake and auth phase (docs/PROTOCOL.md §1–§2.5) over a blocking
//! TCP stream: ClientPreamble + msg1 → admission (rate limit, version) → HostPreamble + msg2 →
//! msg3 → transport keys → paired key (ClientHello) or pairing (PairReveal, both users confirm,
//! AuthResult 0) or rejection (AuthResult 1–5). Platform independent; the PC-side confirmation is
//! behind `LocalConfirm` (a dialog on Windows, a script in tests).

use super::trust::{display_name, Claim, PairingVote, PairingWindow, TrustStore, VoteOutcome, CONFIRM_TIMEOUT};
use crate::cloud::grants::{Grant, GrantStore};
use crate::crypto::{CryptoError, Opener, Sealer};
use crate::handshake::*;
use crate::identity::Identity;
use crate::peers::{canonical, Backoff};
use crate::protocol::{ClientMsg, HostMsg, AUTH_BUSY, AUTH_DECLINED, AUTH_OK, AUTH_PAIRING_CLOSED, AUTH_TIMEOUT, AUTH_UNKNOWN_VIEWER};
use std::io::{Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Pre-auth deadline: everything up to ClientHello (outside the user part of a pairing), total.
pub const PREAUTH_TIMEOUT: Duration = Duration::from_secs(5);
/// Largest record body before authentication (§2.4).
pub const PREAUTH_MAX_RECORD: usize = 64 * 1024;
/// Most handshakes in progress at once; more connections are closed right after accept().
pub const MAX_PREAUTH_CONNECTIONS: usize = 16;

/// What the PC user is asked while pairing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairRequest {
    /// "123 456"
    pub code: String,
    pub viewer_name: String,
    pub viewer_fingerprint: String,
    pub host_fingerprint: String,
    /// The address the connection came from.
    pub peer: String,
}

/// Asks the PC user to compare the pairing code (dialog on Windows).
pub trait LocalConfirm: Send + Sync {
    /// Show `req` and block until the user answers (true = the codes match). Must return
    /// (false) soon after `cancel` becomes true: the viewer declined, left or the time ran out.
    fn confirm(&self, req: &PairRequest, cancel: Arc<AtomicBool>) -> bool;
}

/// Shared host state for all connections.
pub struct HostCtx {
    pub identity: Identity,
    pub trust: TrustStore,
    pub window: PairingWindow,
    pub backoff: Mutex<Backoff>,
    pub confirm: Arc<dyn LocalConfirm>,
    pub preauth_timeout: Duration,
    pub confirm_timeout: Duration,
    next_id: AtomicU64,
    /// Managed mode: viewer keys the cloud granted for one session each (docs/ENTERPRISE.md §6.3).
    /// In memory only; never written to host.json.
    pub grants: Arc<GrantStore>,
    /// Org setting `allow_local_pairing` (and LAN mode): false = the pairing window can't open.
    local_pairing: AtomicBool,
    /// Org setting `lan_mode` / `DisableLANMode`: false = LAN connections are refused.
    lan: AtomicBool,
}

impl HostCtx {
    pub fn new(identity: Identity, trust: TrustStore, confirm: Arc<dyn LocalConfirm>) -> HostCtx {
        HostCtx {
            identity,
            trust,
            window: PairingWindow::default(),
            backoff: Mutex::new(Backoff::default()),
            confirm,
            preauth_timeout: PREAUTH_TIMEOUT,
            confirm_timeout: CONFIRM_TIMEOUT,
            next_id: AtomicU64::new(1),
            grants: Arc::new(GrantStore::default()),
            local_pairing: AtomicBool::new(true),
            lan: AtomicBool::new(true),
        }
    }

    /// Opens the pairing window ("Pair New Mac…", `--pair`) and forgets all rate limiting: the
    /// viewer about to pair may have been refused a moment ago (§2.5). Returns false (and opens
    /// nothing) when the organization turned local pairing off.
    pub fn open_pairing(&self, duration: Duration) -> bool {
        if !self.local_pairing_allowed() {
            super::log("pairing is turned off by your organization (Glide Cloud setting allow_local_pairing)");
            return false;
        }
        self.window.open(Instant::now(), duration);
        *self.backoff.lock().unwrap() = Backoff::default();
        true
    }

    pub fn local_pairing_allowed(&self) -> bool {
        self.local_pairing.load(Ordering::SeqCst) && self.lan_allowed()
    }

    pub fn lan_allowed(&self) -> bool {
        self.lan.load(Ordering::SeqCst)
    }

    /// Applies org settings (managed mode). Turning pairing off closes an open window.
    pub fn set_policy(&self, lan: bool, local_pairing: bool) {
        self.lan.store(lan, Ordering::SeqCst);
        self.local_pairing.store(local_pairing, Ordering::SeqCst);
        if !self.local_pairing_allowed() {
            self.window.close();
        }
    }

    pub fn next_conn_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::SeqCst)
    }
}

/// The viewer's ClientHello.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub version: u16,
    pub codec_caps: u32,
    pub view_w: u16,
    pub view_h: u16,
    pub mode: u8,
    pub max_fps: u8,
    pub client_name: String,
}

/// An authenticated viewer that sent ClientHello; the caller answers with ServerHello.
pub struct Authed {
    pub stream: TcpStream,
    pub sealer: Sealer,
    pub opener: Opener,
    pub peer: IpAddr,
    pub viewer_key: [u8; 32],
    /// Sanitized (`display_name`).
    pub viewer_name: String,
    pub hello: Hello,
    /// This connection paired the viewer.
    pub paired_now: bool,
    pub conn_id: u64,
    /// Managed session: the grant this viewer was admitted with (permissions, user).
    pub grant: Option<Grant>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// A Glide v1 viewer; it got the v1-style "unsupported version 2" answer.
    V1Viewer,
    /// HostPreamble status != 0 was sent (1 version, 3 rate limited).
    Refused(u16),
    /// AuthResult(code != 0) was sent.
    Rejected(u8),
    /// The viewer's user declined the pairing.
    ViewerDeclined,
    /// Handshake error, timeout, protocol violation, disconnect.
    Error(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::V1Viewer => write!(f, "Glide v1 viewer (told to update)"),
            Failure::Refused(s) => write!(f, "refused with HostPreamble status {s}"),
            Failure::Rejected(c) => write!(f, "rejected with AuthResult {c}"),
            Failure::ViewerDeclined => write!(f, "pairing declined on the viewer"),
            Failure::Error(e) => write!(f, "{e}"),
        }
    }
}

impl Failure {
    /// Counted by the rate limiter (§2.5): everything except our own refusals and a viewer
    /// that declined a pairing.
    pub fn charged(&self) -> bool {
        !matches!(self, Failure::Refused(_) | Failure::ViewerDeclined)
    }
}

fn err(e: impl std::fmt::Display) -> Failure {
    Failure::Error(e.to_string())
}

/// Reads with a wall-clock deadline: each read() gets only the time left, so a peer that drips
/// bytes can't stretch the phase.
struct Deadline<'a> {
    s: &'a TcpStream,
    until: Instant,
}

impl Read for Deadline<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let left = self.until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "deadline exceeded"));
        }
        self.s.set_read_timeout(Some(left.max(Duration::from_millis(1))))?;
        let mut s = self.s;
        s.read(buf)
    }
}

fn read_exact(s: &TcpStream, until: Instant, buf: &mut [u8]) -> Result<(), Failure> {
    Deadline { s, until }.read_exact(buf).map_err(|e| err(format!("read: {e}")))
}

fn read_frame(s: &TcpStream, until: Instant) -> Result<Vec<u8>, Failure> {
    let mut l = [0u8; 2];
    read_exact(s, until, &mut l)?;
    let n = u16::from_le_bytes(l) as usize;
    if n > MAX_HANDSHAKE_MSG {
        return Err(err(format!("handshake message too large ({n} bytes)")));
    }
    let mut m = vec![0u8; n];
    read_exact(s, until, &mut m)?;
    Ok(m)
}

fn read_record(s: &TcpStream, opener: &mut Opener, until: Instant) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    opener.read_record_max(&mut Deadline { s, until }, &mut buf, PREAUTH_MAX_RECORD).map_err(|e| match e {
        CryptoError::Io(e) => format!("read: {e}"),
        e => e.to_string(),
    })
}

fn write_all(s: &TcpStream, b: &[u8]) -> Result<(), Failure> {
    let mut w = s;
    w.write_all(b).map_err(|e| err(format!("write: {e}")))
}

fn send(s: &TcpStream, sealer: &mut Sealer, m: &HostMsg) -> Result<(), Failure> {
    write_all(s, &sealer.seal(&m.encode()))
}

/// Half-close and drain briefly, so data still unread on our side doesn't turn the close into a
/// reset that could destroy the answer we just sent (Windows does that).
pub fn close_gracefully(s: &TcpStream) {
    let _ = s.shutdown(Shutdown::Write);
    let until = Instant::now() + Duration::from_millis(500);
    let mut sink = [0u8; 1024];
    while let Ok(n) = (Deadline { s, until }).read(&mut sink) {
        if n == 0 {
            break;
        }
    }
    let _ = s.shutdown(Shutdown::Both);
}

/// v1 viewer: answer `"GLD1"`, `u16 2`, 64 zero bytes (it reports "unsupported version 2").
pub fn v1_rejection() -> [u8; V1_HOST_HS_LEN] {
    let mut b = [0u8; V1_HOST_HS_LEN];
    b[..4].copy_from_slice(MAGIC_V1);
    b[4..6].copy_from_slice(&VERSION.to_le_bytes());
    b
}

/// Runs the host side of one connection up to (and including) the viewer's ClientHello and
/// updates the rate limiter. The caller sends ServerHello next.
pub fn accept(stream: TcpStream, peer: IpAddr, ctx: &HostCtx) -> Result<Authed, Failure> {
    let id = ctx.next_conn_id();
    let peer = canonical(peer);
    let _ = stream.set_nodelay(true);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let r = accept_inner(&stream, peer, ctx, id, None);
    match r {
        Ok((sealer, opener, viewer_key, viewer_name, hello, paired_now, grant)) => {
            ctx.backoff.lock().unwrap().succeeded(peer);
            let _ = stream.set_read_timeout(None);
            Ok(Authed { stream, sealer, opener, peer, viewer_key, viewer_name, hello, paired_now, conn_id: id, grant })
        }
        Err(f) => {
            if f.charged() {
                let d = ctx.backoff.lock().unwrap().failed(peer, Instant::now());
                super::log(&format!("conn {id}: {peer}: {f} (next attempt from it refused for {} s)", d.as_secs()));
            } else {
                super::log(&format!("conn {id}: {peer}: {f}"));
            }
            close_gracefully(&stream);
            Err(f)
        }
    }
}

/// Managed session (docs/ENTERPRISE.md §6.3, §6.6): runs the host side on the loopback end of the
/// relay bridge for `session_id`. Only the viewer key granted for that session is accepted (the
/// grant is used up), never a pairing and never a key from host.json. A connection the host
/// dialed out: nothing is charged to the inbound rate limiter (PROTOCOL.md §2.5).
pub fn accept_relay(stream: TcpStream, session_id: &str, ctx: &HostCtx) -> Result<Authed, Failure> {
    let id = ctx.next_conn_id();
    let peer = IpAddr::from([127, 0, 0, 1]);
    let _ = stream.set_nodelay(true);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    match accept_inner(&stream, peer, ctx, id, Some(session_id)) {
        Ok((sealer, opener, viewer_key, viewer_name, hello, paired_now, grant)) => {
            let _ = stream.set_read_timeout(None);
            Ok(Authed { stream, sealer, opener, peer, viewer_key, viewer_name, hello, paired_now, conn_id: id, grant })
        }
        Err(f) => {
            super::log(&format!("conn {id}: managed session {session_id}: {f}"));
            ctx.grants.cancel(session_id);
            close_gracefully(&stream);
            Err(f)
        }
    }
}

type Accepted = (Sealer, Opener, [u8; 32], String, Hello, bool, Option<Grant>);

fn accept_inner(s: &TcpStream, peer: IpAddr, ctx: &HostCtx, id: u64, relay: Option<&str>) -> Result<Accepted, Failure> {
    let until = Instant::now() + ctx.preauth_timeout;
    let blocked = || ctx.backoff.lock().unwrap().blocked(peer, Instant::now());
    let mut pre = [0u8; CLIENT_PREAMBLE_LEN];
    read_exact(s, until, &mut pre[..4])?;
    if &pre[..4] == MAGIC_V1 {
        let mut rest = [0u8; V1_CLIENT_HS_LEN - 4];
        read_exact(s, until, &mut rest)?;
        if blocked().is_some() {
            return Err(Failure::Refused(ST_RATE_LIMITED));
        }
        write_all(s, &v1_rejection())?;
        return Err(Failure::V1Viewer);
    }
    if &pre[..4] != MAGIC_V2 {
        return Err(err("not a Glide viewer (bad magic)"));
    }
    read_exact(s, until, &mut pre[4..])?;
    let msg1 = read_frame(s, until)?;
    // Admission, before any DH.
    if let Some(left) = blocked() {
        super::log(&format!("conn {id}: {peer} is rate-limited ({} s left); refusing", left.as_secs_f32().ceil()));
        write_all(s, &host_preamble(VERSION, ST_RATE_LIMITED))?;
        return Err(Failure::Refused(ST_RATE_LIMITED));
    }
    let mut hs = match HostHandshake::read_first(ctx.identity.secret(), &pre, &msg1, None, None) {
        Ok(h) => h,
        Err(HsError::Status { status, .. }) => {
            write_all(s, &host_preamble(VERSION, status))?;
            return Err(Failure::Refused(status));
        }
        Err(e) => return Err(err(format!("handshake: {e}"))),
    };
    let n_h = hs.nonce;
    // A relay connection never pairs: its msg2 says the window is closed.
    let open = relay.is_none() && ctx.local_pairing_allowed() && ctx.window.is_open(Instant::now());
    write_all(s, &hs.write_msg2(if open { HOST_FLAG_PAIRING_OPEN } else { 0 }))?;
    // EOF here = the viewer has another key pinned for this address (or its pairing gate said no).
    let msg3 = read_frame(s, until).map_err(|e| err(format!("viewer left after msg2 ({e})")))?;
    let (vkey, info) = hs.read_msg3(&msg3).map_err(|e| err(format!("handshake: {e}")))?;
    let est = hs.finish();
    let mut sealer = Sealer::new(&est.send_key());
    let mut opener = Opener::new(&est.recv_key());
    let name = display_name(&info.name);
    let fp = fingerprint(&vkey);
    let reject = |sealer: &mut Sealer, code: u8| -> Failure {
        let _ = send(s, sealer, &HostMsg::AuthResult { code });
        Failure::Rejected(code)
    };
    let mut paired_now = false;
    let mut hello_until = until;
    let mut grant = None;
    if let Some(sid) = relay {
        if info.pair_request() {
            super::log(&format!("conn {id}: managed session {sid}: viewer “{name}” ({fp}) asked to pair; refused"));
            return Err(reject(&mut sealer, AUTH_PAIRING_CLOSED));
        }
        match ctx.grants.take(sid, &vkey, Instant::now()) {
            Ok(g) => {
                super::log(&format!("conn {id}: managed session {sid}: “{name}” ({fp}) admitted by grant for {}", g.user.label()));
                grant = Some(g);
            }
            Err(e) => {
                super::log(&format!("conn {id}: managed session {sid}: rejected viewer “{name}” ({fp}): {e}"));
                return Err(reject(&mut sealer, AUTH_UNKNOWN_VIEWER));
            }
        }
    } else if info.pair_request() {
        match ctx.window.claim(id, Instant::now()) {
            Claim::Closed => {
                super::log(&format!("conn {id}: viewer “{name}” ({fp}) at {peer} asked to pair, but pairing isn't open (glide-host --pair)"));
                return Err(reject(&mut sealer, AUTH_PAIRING_CLOSED));
            }
            Claim::Busy => {
                super::log(&format!("conn {id}: viewer “{name}” asked to pair while another pairing is in progress"));
                return Err(reject(&mut sealer, AUTH_BUSY));
            }
            Claim::Granted => {}
        }
        // Frees the pairing slot on every exit from here on (errors, `?`, panics).
        let mut slot = PairingSlotGuard { window: &ctx.window, id, paired: false };
        let code = sas_text(sas_code(&est.handshake_hash, &info.nonce, &n_h));
        super::log(&format!("conn {id}: pairing with “{name}” ({fp}) at {peer}; code {code}"));
        let req = PairRequest {
            code,
            viewer_name: name.clone(),
            viewer_fingerprint: fp.clone(),
            host_fingerprint: ctx.identity.fingerprint(),
            peer: peer.to_string(),
        };
        // The slot guard releases the claim if this (or anything below) fails.
        opener = pairing(s, ctx, id, req, &mut sealer, opener, n_h)?;
        if let Err(e) = ctx.trust.add(&name, &vkey) {
            super::log(&format!("conn {id}: cannot save host.json, so “{name}” is not paired: {e}"));
            return Err(reject(&mut sealer, AUTH_DECLINED));
        }
        slot.paired = true;
        drop(slot);
        super::log(&format!("conn {id}: paired viewer “{name}” ({fp})"));
        send(s, &mut sealer, &HostMsg::AuthResult { code: AUTH_OK })?;
        paired_now = true;
        hello_until = Instant::now() + ctx.preauth_timeout;
    } else if !ctx.trust.is_paired(&vkey) {
        super::log(&format!("conn {id}: rejected unknown viewer “{name}” ({fp}) from {peer}"));
        return Err(reject(&mut sealer, AUTH_UNKNOWN_VIEWER));
    }
    let pt = read_record(s, &mut opener, hello_until).map_err(|e| err(format!("waiting for ClientHello: {e}")))?;
    match ClientMsg::decode(&pt) {
        Ok(ClientMsg::ClientHello { version, codec_caps, view_w, view_h, mode, max_fps, client_name }) => {
            let hello = Hello { version, codec_caps, view_w, view_h, mode, max_fps, client_name };
            Ok((sealer, opener, vkey, name, hello, paired_now, grant))
        }
        Ok(m) => Err(err(format!("expected ClientHello, got {}", short(&m)))),
        Err(e) => Err(err(format!("bad message instead of ClientHello: {e}"))),
    }
}

/// Releases connection `id`'s claim on the pairing window when dropped; `paired` closes the window.
struct PairingSlotGuard<'a> {
    window: &'a PairingWindow,
    id: u64,
    paired: bool,
}

impl Drop for PairingSlotGuard<'_> {
    fn drop(&mut self) {
        self.window.release(self.id, self.paired);
    }
}

fn short(m: &ClientMsg) -> String {
    let s = format!("{m:?}");
    s.chars().take(60).collect()
}

enum Event {
    Local(bool),
    Viewer(Result<Vec<u8>, String>, Opener),
}

/// The pairing state (§2.4): PairReveal, then both confirmations within `confirm_timeout`.
/// Ok(opener) = both users said yes (the caller pins the viewer and sends AuthResult 0).
fn pairing(s: &TcpStream, ctx: &HostCtx, id: u64, req: PairRequest, sealer: &mut Sealer, opener: Opener, n_h: [u8; 32]) -> Result<Opener, Failure> {
    let until = Instant::now() + ctx.confirm_timeout;
    send(s, sealer, &HostMsg::PairReveal { nonce: n_h })?;
    let cancel = Arc::new(AtomicBool::new(false));
    let (tx, rx) = mpsc::channel::<Event>();
    {
        let (tx, cancel, confirm) = (tx.clone(), cancel.clone(), ctx.confirm.clone());
        thread::spawn(move || {
            let ok = confirm.confirm(&req, cancel);
            let _ = tx.send(Event::Local(ok));
        });
    }
    {
        let s2 = s.try_clone().map_err(err)?;
        thread::spawn(move || {
            let mut opener = opener;
            let r = read_record(&s2, &mut opener, until);
            let _ = tx.send(Event::Viewer(r, opener));
        });
    }
    let mut vote = PairingVote::default();
    let mut opener = None;
    let result = loop {
        match vote.outcome() {
            VoteOutcome::Paired => break Ok(()),
            VoteOutcome::DeclinedHere => {
                super::log(&format!("conn {id}: pairing declined on this PC"));
                let _ = send(s, sealer, &HostMsg::AuthResult { code: AUTH_DECLINED });
                break Err(Failure::Rejected(AUTH_DECLINED));
            }
            VoteOutcome::DeclinedByViewer => break Err(Failure::ViewerDeclined),
            VoteOutcome::Pending => {}
        }
        let left = until.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(Event::Local(ok)) => vote.local = Some(ok),
            Ok(Event::Viewer(r, o)) => {
                opener = Some(o);
                match r.as_deref().map(ClientMsg::decode) {
                    Ok(Ok(ClientMsg::PairConfirm { matched })) => vote.viewer = Some(matched),
                    Ok(Ok(m)) => break Err(err(format!("expected PairConfirm, got {}", short(&m)))),
                    Ok(Err(e)) => break Err(err(format!("bad message instead of PairConfirm: {e}"))),
                    Err(e) => break Err(err(format!("viewer left during pairing: {e}"))),
                }
            }
            Err(_) => {
                super::log(&format!("conn {id}: pairing timed out"));
                let _ = send(s, sealer, &HostMsg::AuthResult { code: AUTH_TIMEOUT });
                break Err(Failure::Rejected(AUTH_TIMEOUT));
            }
        }
    };
    cancel.store(true, Ordering::SeqCst); // closes the dialog if it is still open
    result.and_then(|()| opener.ok_or_else(|| err("internal: no opener")))
}

/// Accept loop: one thread per connection (at most `MAX_PREAUTH_CONNECTIONS` handshakes at a
/// time); each authenticated viewer goes to `on_authed` on its connection's thread.
pub fn serve(listener: TcpListener, ctx: Arc<HostCtx>, on_authed: Arc<dyn Fn(Authed) + Send + Sync>) -> std::io::Result<()> {
    let active = Arc::new(AtomicUsize::new(0));
    loop {
        let (stream, addr) = match listener.accept() {
            Ok(x) => x,
            Err(e) => {
                super::log(&format!("accept failed: {e}"));
                thread::sleep(Duration::from_millis(100));
                continue;
            }
        };
        if !ctx.lan_allowed() {
            // LAN mode turned off (managed mode): stop listening. The caller woke us up.
            drop(stream);
            super::log("LAN connections are turned off by your organization; not listening");
            return Ok(());
        }
        if active.load(Ordering::SeqCst) >= MAX_PREAUTH_CONNECTIONS {
            super::log(&format!("{}: too many handshakes in progress; closing", addr.ip()));
            drop(stream);
            continue;
        }
        active.fetch_add(1, Ordering::SeqCst);
        let (ctx, on_authed, active) = (ctx.clone(), on_authed.clone(), active.clone());
        thread::spawn(move || {
            let r = accept(stream, addr.ip(), &ctx);
            active.fetch_sub(1, Ordering::SeqCst);
            if let Ok(a) = r {
                super::log(&format!(
                    "conn {}: “{}” ({}) authenticated from {} (caps {:#x}, view {}x{}, mode {}, fps {})",
                    a.conn_id,
                    a.viewer_name,
                    fingerprint(&a.viewer_key),
                    a.peer,
                    a.hello.codec_caps,
                    a.hello.view_w,
                    a.hello.view_h,
                    a.hello.mode,
                    a.hello.max_fps
                ));
                on_authed(a);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::trust::HostConfig;
    use crate::net::tests::{auth as viewer_auth, hello, TestUi};
    use crate::net::{ConnectError, Connection};

    /// Scripted PC user.
    struct Script {
        answer: Option<bool>,
        delay: Duration,
        asked: Mutex<Vec<PairRequest>>,
    }
    impl LocalConfirm for Script {
        fn confirm(&self, req: &PairRequest, cancel: Arc<AtomicBool>) -> bool {
            self.asked.lock().unwrap().push(req.clone());
            let end = Instant::now() + self.delay;
            while Instant::now() < end || self.answer.is_none() {
                if cancel.load(Ordering::SeqCst) {
                    return false;
                }
                thread::sleep(Duration::from_millis(5));
            }
            self.answer.unwrap()
        }
    }

    fn ctx(answer: Option<bool>) -> (Arc<HostCtx>, Arc<Script>) {
        let s = Arc::new(Script { answer, delay: Duration::from_millis(50), asked: Mutex::new(vec![]) });
        let c = HostCtx::new(Identity::generate(), TrustStore::new(None, HostConfig::default()), s.clone());
        (Arc::new(c), s)
    }

    /// One connection of the real Rust viewer (`net::Connection`) against `accept`; the host
    /// answers ServerHello like the real host does and returns the outcome.
    fn run(ctx: &Arc<HostCtx>, a: &crate::net::Auth) -> (Result<Connection, ConnectError>, Result<(String, bool), Failure>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let c2 = ctx.clone();
        let h = thread::spawn(move || {
            let (s, peer) = l.accept().unwrap();
            accept(s, peer.ip(), &c2).map(|mut au| {
                let cfg =
                    crate::protocol::VideoConfig { width: 1920, height: 1080, codec: crate::protocol::Codec::H264, chroma: 0, color: 0, scale: 1.5 };
                let m = HostMsg::ServerHello { version: 2, host_name: "WIN-PC".into(), config: cfg };
                (&au.stream).write_all(&au.sealer.seal(&m.encode())).unwrap();
                // Keep the socket open until the viewer has read it.
                let _ = au.opener.read_record(&mut au.stream, &mut Vec::new());
                (au.viewer_name, au.paired_now)
            })
        });
        let r = Connection::connect(&addr.to_string(), a, &hello());
        if let Ok(c) = &r {
            c.stop();
        }
        (r, h.join().unwrap())
    }

    #[test]
    fn pairing_then_pinned_reconnect() {
        let (ctx, script) = ctx(Some(true));
        let viewer = Identity::generate();
        ctx.open_pairing(Duration::from_secs(120));
        let ui = TestUi::new(true);
        let (r, out) = run(&ctx, &viewer_auth(&viewer, None, ui.clone()));
        let c = r.unwrap();
        assert!(c.paired);
        assert_eq!(c.host_key, ctx.identity.public());
        assert_eq!((c.host_name.as_str(), c.config.width, c.config.scale), ("WIN-PC", 1920, 1.5));
        assert_eq!(out.unwrap(), ("test-pc".to_string(), true));
        // Both sides showed the same code and fingerprints.
        let asked = script.asked.lock().unwrap().clone();
        let shown = ui.shown.lock().unwrap().clone();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].code, shown[0].code);
        assert_eq!(asked[0].viewer_fingerprint, viewer.fingerprint());
        assert_eq!(asked[0].host_fingerprint, shown[0].host_fingerprint);
        assert_eq!(asked[0].peer, "127.0.0.1");
        assert!(ctx.trust.is_paired(&viewer.public()));
        assert!(!ctx.window.is_open(Instant::now()), "a successful pairing closes the window");
        // Pinned reconnect: no prompt on either side, ClientHello pipelined after msg3.
        let ui2 = TestUi::new(true);
        let (r, out) = run(&ctx, &viewer_auth(&viewer, Some(ctx.identity.public()), ui2.clone()));
        assert!(!r.unwrap().paired);
        assert_eq!(out.unwrap(), ("test-pc".to_string(), false));
        assert!(ui2.shown.lock().unwrap().is_empty());
        assert_eq!(script.asked.lock().unwrap().len(), 1);
    }

    #[test]
    fn unknown_viewer_gets_auth_result_1_and_is_rate_limited() {
        let (ctx, _) = ctx(Some(true));
        let viewer = Identity::generate();
        let a = viewer_auth(&viewer, Some(ctx.identity.public()), TestUi::new(true));
        let (r, out) = run(&ctx, &a);
        assert!(r.err().unwrap().is_unknown_viewer());
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_UNKNOWN_VIEWER)));
        // Next attempt within the backoff: HostPreamble status 3 before any DH.
        let (r, out) = run(&ctx, &a);
        assert!(matches!(r.err(), Some(ConnectError::Refused { status: 3, .. })));
        assert_eq!(out.err(), Some(Failure::Refused(ST_RATE_LIMITED)));
        // Opening the pairing window clears the limiter.
        ctx.open_pairing(Duration::from_secs(1));
        ctx.window.close();
        let (_, out) = run(&ctx, &a);
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_UNKNOWN_VIEWER)));
    }

    #[test]
    fn pair_request_with_window_closed_gets_2() {
        let (ctx, _) = ctx(Some(true));
        let viewer = Identity::generate();
        // The real viewer doesn't even send the pair request when msg2 says closed; force it.
        let mut a = viewer_auth(&viewer, Some(ctx.identity.public()), TestUi::new(true));
        a.request_pairing = true;
        let (r, out) = run(&ctx, &a);
        assert!(matches!(r.err(), Some(ConnectError::HostPairingClosed)));
        // The viewer closed after msg2 without sending msg3: a charged failure on the host.
        assert!(matches!(out.err(), Some(Failure::Error(_))));
        // Raw: msg3 with the pair bit while the window is closed → AuthResult 2.
        let (ctx, _) = self::ctx(Some(true));
        assert_eq!(raw_pair_attempt(&ctx, viewer.clone()), Some(AUTH_PAIRING_CLOSED));
    }

    /// A hand-driven viewer that always sends the pair request and returns the first AuthResult.
    fn raw_pair_attempt(ctx: &Arc<HostCtx>, viewer: Identity) -> Option<u8> {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let c2 = ctx.clone();
        let h = thread::spawn(move || {
            let (s, p) = l.accept().unwrap();
            accept(s, p.ip(), &c2).err()
        });
        let mut s = TcpStream::connect(addr).unwrap();
        let mut v = ViewerHandshake::new(viewer.secret(), "raw", None, None);
        s.write_all(&v.first_flight()).unwrap();
        let mut pre = [0u8; HOST_PREAMBLE_LEN];
        s.read_exact(&mut pre).unwrap();
        let ver = parse_host_preamble(&pre).unwrap();
        let mut l2 = [0u8; 2];
        s.read_exact(&mut l2).unwrap();
        let mut m2 = vec![0u8; u16::from_le_bytes(l2) as usize];
        s.read_exact(&mut m2).unwrap();
        v.read_msg2(&m2, ver).unwrap();
        s.write_all(&v.write_msg3(VIEWER_FLAG_PAIR_REQUEST)).unwrap();
        let est = v.finish();
        let mut o = Opener::new(&est.recv_key());
        let pt = o.read_record(&mut s, &mut Vec::new()).ok()?;
        let _ = h.join();
        match HostMsg::decode(pt).ok()? {
            HostMsg::AuthResult { code } => Some(code),
            _ => None,
        }
    }

    #[test]
    fn busy_while_another_pairing_runs() {
        let (ctx, _) = ctx(Some(true));
        ctx.open_pairing(Duration::from_secs(120));
        assert_eq!(ctx.window.claim(999, Instant::now()), Claim::Granted);
        assert_eq!(raw_pair_attempt(&ctx, Identity::generate()), Some(AUTH_BUSY));
    }

    #[test]
    fn declined_on_this_pc_gets_3() {
        let (ctx, _) = ctx(Some(false));
        ctx.open_pairing(Duration::from_secs(120));
        let viewer = Identity::generate();
        let ui = TestUi::new(true);
        let (r, out) = run(&ctx, &viewer_auth(&viewer, None, ui.clone()));
        assert!(r.is_err());
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_DECLINED)));
        assert!(!ctx.trust.is_paired(&viewer.public()));
        assert!(ctx.window.is_open(Instant::now()), "a failed pairing leaves the window open");
    }

    /// host.json can't be saved: the viewer is told no, and the pairing slot is freed (the next
    /// pairing attempt is not answered with AUTH_BUSY).
    #[test]
    fn save_failure_frees_the_pairing_slot() {
        let blocker = std::env::temp_dir().join(format!("glide-host-savefail-{}-{:?}", std::process::id(), thread::current().id()));
        std::fs::write(&blocker, b"a file, not a folder").unwrap();
        let s = Arc::new(Script { answer: Some(true), delay: Duration::from_millis(50), asked: Mutex::new(vec![]) });
        let trust = TrustStore::new(Some(blocker.join("host.json")), HostConfig::default());
        let ctx = Arc::new(HostCtx::new(Identity::generate(), trust, s.clone()));
        ctx.open_pairing(Duration::from_secs(120));
        let viewer = Identity::generate();
        let (r, out) = run(&ctx, &viewer_auth(&viewer, None, TestUi::new(true)));
        assert!(r.is_err());
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_DECLINED)));
        assert_eq!(ctx.window.claim(12345, Instant::now()), Claim::Granted, "the pairing slot stayed held");
        ctx.window.release(12345, false);
        // A second attempt (past the failure backoff) reaches the PC prompt again, not AUTH_BUSY.
        *ctx.backoff.lock().unwrap() = Backoff::default();
        let (_, out) = run(&ctx, &viewer_auth(&Identity::generate(), None, TestUi::new(true)));
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_DECLINED)));
        assert_eq!(s.asked.lock().unwrap().len(), 2);
        let _ = std::fs::remove_file(&blocker);
    }

    #[test]
    fn declined_on_viewer_closes_dialog() {
        let (ctx, script) = ctx(None); // the PC user never answers
        ctx.open_pairing(Duration::from_secs(120));
        let viewer = Identity::generate();
        let (r, out) = run(&ctx, &viewer_auth(&viewer, None, TestUi::new(false)));
        assert!(r.is_err());
        assert_eq!(out.err(), Some(Failure::ViewerDeclined));
        assert_eq!(script.asked.lock().unwrap().len(), 1);
        assert!(!ctx.trust.is_paired(&viewer.public()));
    }

    #[test]
    fn pairing_times_out_with_4() {
        let s = Arc::new(Script { answer: None, delay: Duration::ZERO, asked: Mutex::new(vec![]) });
        let mut c = HostCtx::new(Identity::generate(), TrustStore::new(None, HostConfig::default()), s);
        c.confirm_timeout = Duration::from_millis(400);
        let ctx = Arc::new(c);
        ctx.open_pairing(Duration::from_secs(120));
        let (r, out) = run(&ctx, &viewer_auth(&Identity::generate(), None, TestUi::new(true)));
        assert!(r.is_err());
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_TIMEOUT)));
    }

    #[test]
    fn preauth_deadline_and_bad_peers() {
        let (c, _) = ctx(Some(true));
        let mut c = Arc::try_unwrap(c).ok().unwrap();
        c.preauth_timeout = Duration::from_millis(300);
        let ctx = Arc::new(c);
        let attempt = |bytes: &[u8]| -> (Failure, Vec<u8>) {
            let l = TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = l.local_addr().unwrap();
            let c2 = ctx.clone();
            let h = thread::spawn(move || {
                let (s, p) = l.accept().unwrap();
                accept(s, p.ip(), &c2).err().unwrap()
            });
            let mut s = TcpStream::connect(addr).unwrap();
            s.write_all(bytes).unwrap();
            let f = h.join().unwrap();
            let mut got = vec![];
            let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
            let _ = s.read_to_end(&mut got);
            *ctx.backoff.lock().unwrap() = Backoff::default();
            (f, got)
        };
        // Silent peer: closed at the deadline.
        let t = Instant::now();
        let (f, _) = attempt(b"GLD2");
        assert!(matches!(f, Failure::Error(_)), "{f:?}");
        assert!(t.elapsed() < Duration::from_secs(2));
        // Not Glide.
        let (f, _) = attempt(b"GET / HTTP/1.1\r\n\r\n");
        assert!(matches!(f, Failure::Error(ref e) if e.contains("bad magic")), "{f:?}");
        // v1 viewer gets the 70-byte v1 answer.
        let mut v1 = b"GLD1".to_vec();
        v1.resize(V1_CLIENT_HS_LEN, 0);
        let (f, got) = attempt(&v1);
        assert_eq!(f, Failure::V1Viewer);
        assert_eq!(got, v1_rejection().to_vec());
        // Oversized handshake frame.
        let mut big = client_preamble().to_vec();
        big.extend_from_slice(&2000u16.to_le_bytes());
        let (f, _) = attempt(&big);
        assert!(matches!(f, Failure::Error(ref e) if e.contains("too large")), "{f:?}");
        // Unsupported version range → status 1.
        let mut p = client_preamble();
        p[4..6].copy_from_slice(&3u16.to_le_bytes());
        p[6..8].copy_from_slice(&3u16.to_le_bytes());
        let mut v = ViewerHandshake::new(Identity::generate().secret(), "x", None, None);
        let ff = v.first_flight();
        let mut flight = p.to_vec();
        flight.extend_from_slice(&ff[CLIENT_PREAMBLE_LEN..]);
        let (f, got) = attempt(&flight);
        assert_eq!(f, Failure::Refused(ST_UNSUPPORTED_VERSION));
        assert_eq!(&got[..], &host_preamble(VERSION, ST_UNSUPPORTED_VERSION));
    }

    /// The host side reproduces the Python reference transcript (docs/test-vectors.json): with
    /// the transcript's fixed keys and nonces, `HostHandshake` (which `accept` drives) writes
    /// exactly the host flights, and the auth-phase records `accept` writes match byte for byte.
    #[test]
    fn host_flights_match_reference_transcript() {
        use crate::util::{hex, unhex};
        use x25519_dalek::StaticSecret;
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/test-vectors.json");
        let doc: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let sk = |h: &str| StaticSecret::from(<[u8; 32]>::try_from(unhex(h)).unwrap());
        for s in doc["sessions"].as_array().unwrap() {
            let g = |k: &str| s[k].as_str().unwrap().to_string();
            let flights = s["flights"].as_array().unwrap();
            let f1 = unhex(flights[0]["bytes"].as_str().unwrap());
            let n_h: [u8; 32] = unhex(&g("host_nonce")).try_into().unwrap();
            let mut h = HostHandshake::read_first(
                sk(doc["host_static"].as_str().unwrap()),
                &f1[..CLIENT_PREAMBLE_LEN],
                &f1[CLIENT_PREAMBLE_LEN + 2..],
                Some(sk(&g("host_ephemeral"))),
                Some(n_h),
            )
            .unwrap();
            let f2 = h.write_msg2(s["host_flags"].as_u64().unwrap() as u8);
            assert_eq!(hex(&f2), flights[1]["bytes"].as_str().unwrap());
            let f3 = unhex(flights[2]["bytes"].as_str().unwrap());
            let n = u16::from_le_bytes([f3[0], f3[1]]) as usize;
            let (_, info) = h.read_msg3(&f3[2..2 + n]).unwrap();
            assert_eq!(info.name, g("viewer_name"));
            let est = h.finish();
            assert_eq!(hex(&est.send_key()), g("s2c_key"));
            let mut sealer = Sealer::new(&est.send_key());
            // Host records in order: what our encoders produce for the decoded plaintexts.
            for r in s["records"].as_array().unwrap().iter().filter(|r| r["dir"] == "s2c") {
                let pt = unhex(r["plaintext"].as_str().unwrap());
                let m = HostMsg::decode(pt.clone()).unwrap();
                assert_eq!(m.encode(), pt, "host encoder");
                assert_eq!(hex(&sealer.seal(&pt)), r["record"].as_str().unwrap());
            }
            if info.pair_request() {
                assert_eq!(g("sas"), sas_text(sas_code(&est.handshake_hash, &info.nonce, &n_h)));
            }
        }
    }

    // ---------------------------------------------------------------- managed sessions (grants)

    fn grant_for(session_id: &str, key: [u8; 32]) -> Grant {
        Grant {
            session_id: session_id.into(),
            viewer_key: key,
            viewer_name: "Viewer PC".into(),
            user: crate::cloud::api::User { id: "usr_1".into(), email: "ada@example.com".into(), name: "Ada".into(), groups: None },
            permissions: crate::cloud::Permissions { control: false, ..Default::default() },
            expires: Instant::now() + Duration::from_secs(60),
        }
    }

    /// The real viewer through two relay bridges (fake relay in between) against `accept_relay`.
    fn run_relay(ctx: &Arc<HostCtx>, session_id: &str, a: &crate::net::Auth) -> (Result<Connection, ConnectError>, Result<Option<Grant>, Failure>) {
        use crate::cloud::bridge;
        use crate::cloud::transport::{fake::pair, WebSocket, WsMsg};
        let (viewer_ws, host_ws) = pair();
        host_ws.send(WsMsg::Text(r#"{"type":"peer_joined"}"#.into())).unwrap(); // to the viewer
        viewer_ws.send(WsMsg::Text(r#"{"type":"peer_joined"}"#.into())).unwrap(); // to the host
        let (c2, sid) = (ctx.clone(), session_id.to_string());
        let h = thread::spawn(move || {
            let (stream, b) = bridge::open(host_ws, &|| {}).unwrap();
            let r = accept_relay(stream, &sid, &c2).map(|mut au| {
                let cfg = crate::protocol::VideoConfig { width: 1280, height: 720, codec: crate::protocol::Codec::H264, chroma: 0, color: 0, scale: 1.0 };
                let m = HostMsg::ServerHello { version: 2, host_name: "WIN-PC".into(), config: cfg };
                (&au.stream).write_all(&au.sealer.seal(&m.encode())).unwrap();
                let _ = au.opener.read_record(&mut au.stream, &mut Vec::new());
                au.grant
            });
            b.close();
            r
        });
        let (stream, b) = bridge::open(viewer_ws, &|| {}).unwrap();
        let r = Connection::from_stream(stream, a, &hello());
        if let Ok(c) = &r {
            c.stop();
        }
        let out = h.join().unwrap();
        b.close();
        (r, out)
    }

    #[test]
    fn granted_viewer_is_accepted_once_without_pairing_and_never_persisted() {
        let (ctx, script) = ctx(Some(true));
        let viewer = Identity::generate();
        ctx.grants.insert(grant_for("ses_1", viewer.public()), Instant::now());
        let mut a = viewer_auth(&viewer, Some(ctx.identity.public()), TestUi::new(true));
        a.target = crate::cloud::relay_target("ses_1");
        let (r, out) = run_relay(&ctx, "ses_1", &a);
        let c = r.unwrap();
        assert!(!c.paired, "no pairing");
        assert_eq!(c.host_key, ctx.identity.public());
        let g = out.unwrap().expect("admitted by grant");
        assert_eq!((g.user.email.as_str(), g.permissions.control), ("ada@example.com", false));
        assert!(script.asked.lock().unwrap().is_empty(), "nobody was asked");
        assert!(!ctx.trust.is_paired(&viewer.public()), "never written to the paired viewers");
        assert!(ctx.trust.list().is_empty());
        assert!(ctx.grants.is_empty(), "the grant is used up");
        // Single use: the same session again is refused as an unknown viewer.
        let (r, out) = run_relay(&ctx, "ses_1", &a);
        assert!(r.err().unwrap().is_unknown_viewer());
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_UNKNOWN_VIEWER)));
        // Relay failures are not charged to the inbound rate limiter.
        assert!(ctx.backoff.lock().unwrap().blocked("127.0.0.1".parse().unwrap(), Instant::now()).is_none());
    }

    #[test]
    fn relay_refuses_other_keys_paired_keys_and_pairing() {
        let (ctx, _) = ctx(Some(true));
        let granted = Identity::generate();
        let other = Identity::generate();
        // A key paired over the LAN doesn't get in through the relay without a grant.
        ctx.trust.add("lan", &other.public()).unwrap();
        ctx.grants.insert(grant_for("ses_2", granted.public()), Instant::now());
        let mut a = viewer_auth(&other, Some(ctx.identity.public()), TestUi::new(true));
        a.target = crate::cloud::relay_target("ses_2");
        let (r, out) = run_relay(&ctx, "ses_2", &a);
        assert!(r.err().unwrap().is_unknown_viewer());
        assert_eq!(out.err(), Some(Failure::Rejected(AUTH_UNKNOWN_VIEWER)));
        assert!(ctx.grants.is_empty(), "a wrong key uses the grant up");
        // A grant for another session doesn't help.
        ctx.grants.insert(grant_for("ses_3", granted.public()), Instant::now());
        let mut a = viewer_auth(&granted, Some(ctx.identity.public()), TestUi::new(true));
        a.target = crate::cloud::relay_target("ses_4");
        let (r, _) = run_relay(&ctx, "ses_4", &a);
        assert!(r.err().unwrap().is_unknown_viewer());
        // An unpinned viewer asking to pair over the relay: the window reads closed even if open.
        ctx.open_pairing(Duration::from_secs(60));
        let a = viewer_auth(&granted, None, TestUi::new(true));
        let (r, _) = run_relay(&ctx, "ses_3", &a);
        assert!(matches!(r.err().unwrap(), ConnectError::HostPairingClosed));
    }

    #[test]
    fn org_settings_gate_pairing_and_lan() {
        let (ctx, _) = ctx(Some(true));
        assert!(ctx.open_pairing(Duration::from_secs(60)));
        ctx.set_policy(true, false);
        assert!(!ctx.window.is_open(Instant::now()), "turning pairing off closes the window");
        assert!(!ctx.open_pairing(Duration::from_secs(60)));
        assert!(!ctx.window.is_open(Instant::now()));
        ctx.set_policy(false, true);
        assert!(!ctx.local_pairing_allowed(), "no LAN, no LAN pairing");
        assert!(!ctx.lan_allowed());
        // serve() stops listening once LAN mode is off (woken by a connection).
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let c2 = ctx.clone();
        let h = thread::spawn(move || serve(l, c2, Arc::new(|_| {})));
        let _wake = TcpStream::connect(addr).unwrap();
        assert!(h.join().unwrap().is_ok());
        assert!(TcpStream::connect(addr).is_err(), "no longer listening");
        ctx.set_policy(true, true);
        assert!(ctx.open_pairing(Duration::from_secs(60)));
    }
}
