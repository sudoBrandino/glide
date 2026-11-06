//! TCP transport: connect + v2 handshake (Noise XX, key pinning, pairing — docs/PROTOCOL.md
//! §1–2), a shared encrypted writer (single send counter), a dedicated receive thread, and a
//! 1 Hz ping thread with RTT / clock-offset tracking. Platform independent (std::net only).

use crate::crypto::{CryptoError, Opener, Sealer};
use crate::handshake::{
    commitment, fingerprint, parse_host_preamble, sas_code, sas_text, HsError, ViewerHandshake, HOST_PREAMBLE_LEN, VIEWER_FLAG_PAIR_REQUEST,
};
use crate::identity::Identity;
use crate::protocol::{ClientMsg, HostMsg, VideoConfig};
use crate::util::now_us;
use std::io::{BufReader, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// Thread-safe encrypted message writer. Cloning shares the same socket and counter.
#[derive(Clone)]
pub struct Sender {
    inner: Arc<Mutex<SenderInner>>,
}

struct SenderInner {
    stream: TcpStream,
    sealer: Sealer,
    dead: bool,
}

impl Sender {
    pub fn send(&self, msg: &ClientMsg) -> std::io::Result<()> {
        let pt = msg.encode();
        let mut g = self.inner.lock().unwrap();
        if g.dead {
            return Err(std::io::Error::new(std::io::ErrorKind::NotConnected, "connection closed"));
        }
        // Seal under the lock so record order on the wire == counter order.
        let rec = g.sealer.seal(&pt);
        let r = g.stream.write_all(&rec);
        if r.is_err() {
            g.dead = true;
        }
        r
    }

    pub fn shutdown(&self) {
        let mut g = self.inner.lock().unwrap();
        g.dead = true;
        let _ = g.stream.shutdown(Shutdown::Both);
    }
}

/// RTT + host clock offset estimation from Ping/Pong.
#[derive(Default)]
pub struct ClockSync {
    pub rtts_ms: Vec<f64>,
    pub last_rtt_ms: Option<f64>,
    /// host_time_us - client_time_us, estimated from the lowest-RTT sample.
    pub offset_us: Option<i64>,
    best_rtt_us: Option<u64>,
}

impl ClockSync {
    pub fn on_pong(&mut self, client_time_us: u64, host_time_us: u64, now: u64) {
        let rtt = now.saturating_sub(client_time_us);
        self.last_rtt_ms = Some(rtt as f64 / 1000.0);
        self.rtts_ms.push(rtt as f64 / 1000.0);
        if self.rtts_ms.len() > 10_000 {
            self.rtts_ms.drain(..5_000);
        }
        if self.best_rtt_us.map_or(true, |b| rtt <= b) {
            self.best_rtt_us = Some(rtt);
            let mid = client_time_us + rtt / 2;
            self.offset_us = Some(host_time_us as i64 - mid as i64);
        }
    }

    /// Convert a host monotonic timestamp into client `now_us()` time, if synced.
    pub fn host_to_client_us(&self, host_us: u64) -> Option<i64> {
        self.offset_us.map(|o| host_us as i64 - o)
    }
}

/// Per-read timeout during the handshake (an idle pre-auth peer is dropped after this).
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
/// Total time for the user part of a pairing (both users compare + the host's verdict), counted
/// from a verified PairReveal. The host gives up after 60 s (AuthResult 4); this bounds a host
/// that goes silent. Matches the host's 2-minute pairing window.
pub const PAIRING_TIMEOUT: Duration = Duration::from_secs(120);

pub enum NetEvent {
    Msg(HostMsg),
    Closed(String),
}

/// What the viewer shows while pairing (docs/PROTOCOL.md §2.4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairPrompt {
    /// The 6-digit code, "123 456"; must match what the Mac shows.
    pub code: String,
    pub host_fingerprint: String,
    pub viewer_fingerprint: String,
    /// The target being paired ("192.168.50.4:7420", "listen:7420").
    pub target: String,
}

/// Asks the user to compare the pairing code. Implemented by the GUI (a dialog) and the console.
pub trait PairingUi: Send + Sync {
    /// Show `p` and block until the user answers: true = the codes match.
    fn confirm(&self, p: &PairPrompt) -> bool;
    /// The host ended the pairing (declined on the Mac, timed out, disconnected) while the
    /// prompt may still be open: close it (confirm then returns false).
    fn dismiss(&self) {}
}

/// Viewer identity and trust state for one connection attempt.
#[derive(Clone)]
pub struct Auth {
    pub identity: Identity,
    /// Viewer name sent in msg3 (shown in the Mac's paired-viewer list).
    pub name: String,
    /// Pin-store target (`config::pin_target`), shown while pairing.
    pub target: String,
    /// The host key pinned for this target, if paired.
    pub pinned: Option<[u8; 32]>,
    /// Ask to pair even though a key is pinned (the host said it no longer knows this viewer).
    /// The host key must still equal the pin.
    pub request_pairing: bool,
    pub pairing: Arc<dyn PairingUi>,
}

impl Auth {
    fn wants_pairing(&self) -> bool {
        self.pinned.is_none() || self.request_pairing
    }
}

pub struct Connection {
    pub sender: Sender,
    pub host_name: String,
    pub config: VideoConfig,
    pub clock: Arc<Mutex<ClockSync>>,
    /// The host's static public key (equal to the pin, or newly paired).
    pub host_key: [u8; 32],
    /// This connection completed a pairing: the caller pins `host_key` for the target.
    pub paired: bool,
    reader: Option<(BufReader<TcpStream>, Opener)>,
    stop: Arc<AtomicBool>,
}

#[derive(Debug)]
pub enum ConnectError {
    Resolve(String),
    Io(std::io::Error),
    Crypto(CryptoError),
    Protocol(String),
    Handshake(HsError),
    /// The host closed the connection without answering the preamble (a v1 host does this:
    /// it reads 54 bytes, sees the wrong magic and closes), or answered with the v1 magic.
    HostIsV1,
    /// HostPreamble status != 0: 1 unsupported version, 2 paused, 3 rate limited.
    Refused { status: u16, version: u16 },
    /// The host presented a different key than the one pinned for this target.
    HostKeyChanged { pinned: [u8; 32], presented: [u8; 32] },
    /// AuthResult with a nonzero code (protocol::AUTH_*).
    Rejected(u8),
    /// The user on this PC said the codes don't match (or closed the dialog).
    PairingCancelled,
    /// Pairing broke off (bad commitment, connection dropped, timeout).
    PairingFailed(String),
}

impl ConnectError {
    /// The host doesn't accept this viewer's key (unknown / not paired): retrying without
    /// pairing won't help.
    pub fn is_unknown_viewer(&self) -> bool {
        matches!(self, ConnectError::Rejected(crate::protocol::AUTH_UNKNOWN_VIEWER))
    }

    /// One-line status for the viewer window / log. `host` names the target.
    pub fn user_message(&self, host: &str) -> String {
        use crate::protocol::*;
        match self {
            ConnectError::HostIsV1 => {
                format!("{host} closed the connection without answering — it is probably still running Glide v1. Update Glide Host on the Mac")
            }
            ConnectError::Refused { status: 1, version } => {
                format!("{host} speaks Glide protocol v{version}; this viewer speaks v{} — update the older side", crate::handshake::VERSION)
            }
            ConnectError::Refused { status: 2, .. } => format!("{host} is paused (not accepting viewers)"),
            ConnectError::Refused { status: 3, .. } => format!("{host} is rate-limiting this PC after failed attempts; retrying"),
            ConnectError::Refused { status, .. } => format!("{host} refused the connection (status {status})"),
            ConnectError::HostKeyChanged { presented, .. } => format!(
                "HOST KEY CHANGED for {host} (now {}). This could be an impersonation attempt. If you reset or reinstalled Glide Host, use the tray menu: Forget host (unpair), then pair again",
                crate::handshake::fingerprint(presented)
            ),
            ConnectError::Rejected(AUTH_UNKNOWN_VIEWER) => {
                format!("{host} doesn't recognize this PC. On the Mac choose Glide → Pair New Viewer…; a code will appear here")
            }
            ConnectError::Rejected(AUTH_PAIRING_CLOSED) => {
                format!("Not paired with {host} yet. On the Mac choose Glide → Pair New Viewer…; a code will appear here")
            }
            ConnectError::Rejected(AUTH_DECLINED) => "Pairing was declined on the Mac".into(),
            ConnectError::Rejected(AUTH_TIMEOUT) => "Pairing timed out (nobody confirmed the code on the Mac)".into(),
            ConnectError::Rejected(AUTH_BUSY) => format!("{host} is busy pairing another viewer; try again"),
            ConnectError::Rejected(c) => format!("{host} rejected this viewer (code {c})"),
            ConnectError::PairingCancelled => "Pairing cancelled on this PC".into(),
            ConnectError::PairingFailed(s) => format!("Pairing failed: {s}"),
            other => other.to_string(),
        }
    }
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectError::Resolve(s) => write!(f, "cannot resolve {s}"),
            ConnectError::Io(e) => write!(f, "{e}"),
            ConnectError::Crypto(e) => write!(f, "{e}"),
            ConnectError::Protocol(s) => write!(f, "{s}"),
            ConnectError::Handshake(e) => write!(f, "{e}"),
            ConnectError::HostIsV1 => write!(f, "host closed the connection before answering (Glide v1 host?)"),
            ConnectError::Refused { status, version } => write!(f, "host refused the handshake (status {status}, version {version})"),
            ConnectError::HostKeyChanged { pinned, presented } => write!(
                f,
                "host key changed: pinned {}, presented {}",
                crate::handshake::fingerprint(pinned),
                crate::handshake::fingerprint(presented)
            ),
            ConnectError::Rejected(c) => write!(f, "host rejected the viewer (AuthResult {c})"),
            ConnectError::PairingCancelled => write!(f, "pairing cancelled by the user"),
            ConnectError::PairingFailed(s) => write!(f, "pairing failed: {s}"),
        }
    }
}

impl std::error::Error for ConnectError {}

impl From<std::io::Error> for ConnectError {
    fn from(e: std::io::Error) -> Self {
        ConnectError::Io(e)
    }
}

fn is_eof(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
    )
}

/// Parse `host`, `host:port`, `[v6]:port`; default port 7420.
pub fn parse_addr(s: &str) -> String {
    let has_port = if s.starts_with('[') { s.contains("]:") } else { s.matches(':').count() == 1 };
    if has_port {
        s.to_string()
    } else if s.contains(':') && !s.starts_with('[') {
        format!("[{s}]:{}", crate::protocol::DEFAULT_PORT) // bare IPv6
    } else {
        format!("{s}:{}", crate::protocol::DEFAULT_PORT)
    }
}

/// One `u16 length || message` handshake frame.
fn read_frame(r: &mut impl Read) -> Result<Vec<u8>, ConnectError> {
    let mut len = [0u8; 2];
    r.read_exact(&mut len)?;
    let n = u16::from_le_bytes(len) as usize;
    if n > crate::handshake::MAX_HANDSHAKE_MSG {
        return Err(ConnectError::Protocol(format!("handshake message too large ({n} bytes)")));
    }
    let mut m = vec![0u8; n];
    r.read_exact(&mut m)?;
    Ok(m)
}

/// Largest record body before the session is authenticated (ServerHello carries a name; the
/// auth-phase messages are tiny).
pub const PREAUTH_MAX_RECORD: usize = 64 * 1024;
/// The first record of a pairing: PairReveal (1 + 32 bytes) or AuthResult (2), + 16-byte tag.
pub const PAIR_REVEAL_MAX_RECORD: usize = 1 + 32 + crate::crypto::TAG_LEN;
/// AuthResult after the codes were compared: 2 bytes + tag.
pub const AUTH_RESULT_MAX_RECORD: usize = 2 + crate::crypto::TAG_LEN;

/// A socket handle whose read timeout can be set (TcpStream, or the BufReader around one).
trait HasSocket: Read {
    fn socket(&self) -> &TcpStream;
}
impl HasSocket for TcpStream {
    fn socket(&self) -> &TcpStream {
        self
    }
}
impl HasSocket for BufReader<TcpStream> {
    fn socket(&self) -> &TcpStream {
        self.get_ref()
    }
}

/// Reads with a wall-clock deadline: every read() gets only the time left, so a peer that drips
/// bytes can't stretch the phase (a per-read timeout alone would restart on every byte).
struct Timed<'a, R: HasSocket> {
    r: &'a mut R,
    until: Instant,
}

impl<R: HasSocket> Read for Timed<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let left = self.until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "handshake deadline exceeded"));
        }
        self.r.socket().set_read_timeout(Some(left.max(Duration::from_millis(1))))?;
        self.r.read(buf)
    }
}

fn timed<R: HasSocket>(r: &mut R, until: Instant) -> Timed<'_, R> {
    Timed { r, until }
}

/// Read + decrypt + decode one host record during the auth phase (bounded size and time).
fn read_host_msg(opener: &mut Opener, r: &mut BufReader<TcpStream>, buf: &mut Vec<u8>, max: usize, until: Instant) -> Result<HostMsg, ConnectError> {
    let pt = match opener.read_record_max(&mut timed(r, until), buf, max) {
        Ok(pt) => pt,
        Err(CryptoError::Io(e)) => return Err(ConnectError::Io(e)),
        Err(e) => return Err(ConnectError::Crypto(e)),
    };
    HostMsg::decode(pt).map_err(|e| ConnectError::Protocol(format!("bad host message: {e}")))
}

impl Connection {
    /// Connect, handshake (pairing if needed), send `hello`, and wait for `ServerHello`.
    pub fn connect(addr: &str, auth: &Auth, hello: &ClientMsg) -> Result<Connection, ConnectError> {
        let addr = parse_addr(addr);
        let sa = addr
            .to_socket_addrs()
            .map_err(|_| ConnectError::Resolve(addr.clone()))?
            .next()
            .ok_or_else(|| ConnectError::Resolve(addr.clone()))?;
        let stream = TcpStream::connect_timeout(&sa, Duration::from_secs(5)).map_err(ConnectError::Io)?;
        Self::from_stream(stream, auth, hello)
    }

    /// Reverse-connect mode: listen on `0.0.0.0:port`, accept ONE TCP connection from the
    /// host, then run the normal client protocol on it (the viewer still sends first).
    pub fn listen(port: u16, auth: &Auth, hello: &ClientMsg) -> Result<Connection, ConnectError> {
        let l = std::net::TcpListener::bind(("0.0.0.0", port)).map_err(ConnectError::Io)?;
        eprintln!("listening on 0.0.0.0:{port}, waiting for the host to connect...");
        let (stream, peer) = l.accept().map_err(ConnectError::Io)?;
        drop(l);
        eprintln!("host connected from {peer}");
        Self::from_stream(stream, auth, hello)
    }

    /// Run the client handshake on an already-connected stream.
    pub fn from_stream(stream: TcpStream, auth: &Auth, hello: &ClientMsg) -> Result<Connection, ConnectError> {
        Self::from_stream_timeout(stream, auth, hello, HANDSHAKE_TIMEOUT, &|| {})
    }

    /// Like `from_stream`, with an explicit pre-auth deadline. Everything up to the first
    /// authenticated host record (ServerHello, or PairReveal with a valid commitment) must arrive
    /// within `read_timeout` of wall-clock time, enforced through the socket read timeout (on
    /// Windows, shutting a socket down from another thread does not interrupt a blocked recv()).
    /// Only once the host has proven its pairing commitment does the user prompt start; it has its
    /// own total deadline (`PAIRING_TIMEOUT`), and `on_pairing` runs then (listen mode lifts its
    /// pre-auth timer there).
    pub fn from_stream_timeout(
        mut stream: TcpStream,
        auth: &Auth,
        hello: &ClientMsg,
        read_timeout: Duration,
        on_pairing: &dyn Fn(),
    ) -> Result<Connection, ConnectError> {
        stream.set_nodelay(true).map_err(ConnectError::Io)?;
        let preauth = Instant::now() + read_timeout.min(HANDSHAKE_TIMEOUT).max(Duration::from_millis(50));

        // -> ClientPreamble, msg1
        let mut hs = ViewerHandshake::new(auth.identity.secret(), &auth.name, None, None);
        stream.write_all(&hs.first_flight())?;
        // <- HostPreamble, msg2
        let mut pre = [0u8; HOST_PREAMBLE_LEN];
        if let Err(e) = timed(&mut stream, preauth).read_exact(&mut pre) {
            return Err(if is_eof(&e) { ConnectError::HostIsV1 } else { ConnectError::Io(e) });
        }
        let version = match parse_host_preamble(&pre) {
            Ok(v) => v,
            Err(HsError::BadMagic { v1: true }) => return Err(ConnectError::HostIsV1),
            Err(HsError::Status { version, status }) => return Err(ConnectError::Refused { status, version }),
            Err(e) => return Err(ConnectError::Handshake(e)),
        };
        let msg2 = read_frame(&mut timed(&mut stream, preauth))?;
        let (host_key, info) = hs.read_msg2(&msg2, version).map_err(ConnectError::Handshake)?;
        if let Some(pinned) = auth.pinned {
            if pinned != host_key {
                // Abort before msg3: an impostor learns nothing about this viewer.
                let _ = stream.shutdown(Shutdown::Both);
                return Err(ConnectError::HostKeyChanged { pinned, presented: host_key });
            }
        }
        let pairing = auth.wants_pairing();
        // -> msg3 (+ ClientHello right away when already paired)
        let mut out = hs.write_msg3(if pairing { VIEWER_FLAG_PAIR_REQUEST } else { 0 });
        let n_v = hs.nonce();
        let est = hs.finish();
        let mut sealer = Sealer::new(&est.send_key());
        let mut opener = Opener::new(&est.recv_key());
        if !pairing {
            out.extend(sealer.seal(&hello.encode()));
        }
        stream.write_all(&out)?;
        let mut reader = BufReader::with_capacity(1 << 20, stream.try_clone().map_err(ConnectError::Io)?);
        let mut buf = Vec::new();
        let mut hello_deadline = preauth;

        if pairing {
            // Still pre-auth: PairReveal must come within the same short deadline, and be small.
            let n_h = match read_host_msg(&mut opener, &mut reader, &mut buf, PAIR_REVEAL_MAX_RECORD, preauth) {
                Ok(HostMsg::PairReveal { nonce }) => nonce,
                Ok(HostMsg::AuthResult { code }) => return Err(ConnectError::Rejected(code)),
                Ok(other) => return Err(ConnectError::Protocol(format!("expected PairReveal, got {other:?}"))),
                Err(ConnectError::Io(e)) if is_eof(&e) => return Err(ConnectError::PairingFailed("the host closed the connection".into())),
                Err(e) => return Err(e),
            };
            if commitment(&n_h) != info.commitment {
                let _ = stream.shutdown(Shutdown::Both);
                return Err(ConnectError::PairingFailed("the host's pairing nonce doesn't match its commitment".into()));
            }
            // The host has committed to this pairing: now (and only now) involve the user.
            on_pairing();
            let pairing_deadline = Instant::now() + PAIRING_TIMEOUT;
            let prompt = PairPrompt {
                code: sas_text(sas_code(&est.handshake_hash, &n_v, &n_h)),
                host_fingerprint: fingerprint(&host_key),
                viewer_fingerprint: auth.identity.fingerprint(),
                target: auth.target.clone(),
            };
            eprintln!("pairing with {}: code {} (host key {})", prompt.target, prompt.code, prompt.host_fingerprint);
            // The host's verdict may arrive while the prompt is open (declined/timeout on the Mac),
            // and the whole pairing has a total deadline: a helper thread reads the verdict until
            // then and closes the prompt as soon as it has one (or time is up).
            let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
            let ui = auth.pairing.clone();
            let watcher = thread::spawn(move || {
                let mut b = Vec::new();
                let r = read_host_msg(&mut opener, &mut reader, &mut b, AUTH_RESULT_MAX_RECORD, pairing_deadline);
                let _ = done_tx.send(());
                ui.dismiss();
                (r, opener, reader)
            });
            let matched = auth.pairing.confirm(&prompt);
            if done_rx.try_recv().is_ok() {
                // The host ended it first, or the deadline passed.
                let (r, _, _) = watcher.join().expect("pairing watcher");
                let _ = stream.shutdown(Shutdown::Both);
                return Err(match r {
                    Ok(HostMsg::AuthResult { code }) if code != 0 => ConnectError::Rejected(code),
                    Ok(other) => ConnectError::Protocol(format!("unexpected {other:?} during pairing")),
                    Err(ConnectError::Io(e)) if is_eof(&e) => ConnectError::PairingFailed("the host closed the connection".into()),
                    Err(ConnectError::Io(e)) if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) => {
                        ConnectError::PairingFailed("timed out waiting for the codes to be confirmed".into())
                    }
                    Err(e) => e,
                });
            }
            let confirm = sealer.seal(&ClientMsg::PairConfirm { matched }.encode());
            let wrote = stream.write_all(&confirm);
            if !matched {
                let _ = stream.shutdown(Shutdown::Both);
                let _ = watcher.join();
                return Err(ConnectError::PairingCancelled);
            }
            wrote?;
            let (r, op, rd) = watcher.join().expect("pairing watcher");
            opener = op;
            reader = rd;
            match r {
                Ok(HostMsg::AuthResult { code: 0 }) => {}
                Ok(HostMsg::AuthResult { code }) => return Err(ConnectError::Rejected(code)),
                Ok(other) => return Err(ConnectError::Protocol(format!("expected AuthResult, got {other:?}"))),
                Err(ConnectError::Io(e)) if is_eof(&e) => return Err(ConnectError::PairingFailed("the host closed the connection".into())),
                Err(ConnectError::Io(e)) if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) => {
                    let _ = stream.shutdown(Shutdown::Both);
                    return Err(ConnectError::PairingFailed("timed out waiting for the Mac to confirm".into()));
                }
                Err(e) => return Err(e),
            }
            eprintln!("paired with {} (host key {})", prompt.target, prompt.host_fingerprint);
            hello_deadline = Instant::now() + HANDSHAKE_TIMEOUT;
            stream.write_all(&sealer.seal(&hello.encode()))?;
        }

        // <- ServerHello (or AuthResult != 0)
        let (host_name, config) = match read_host_msg(&mut opener, &mut reader, &mut buf, PREAUTH_MAX_RECORD, hello_deadline) {
            Ok(HostMsg::ServerHello { version, host_name, config }) => {
                if version != crate::protocol::PROTOCOL_VERSION {
                    return Err(ConnectError::Protocol(format!("host speaks protocol version {version}")));
                }
                (host_name, config)
            }
            Ok(HostMsg::AuthResult { code }) => return Err(ConnectError::Rejected(code)),
            Ok(other) => return Err(ConnectError::Protocol(format!("expected ServerHello, got {other:?}"))),
            Err(ConnectError::Io(e)) if is_eof(&e) => {
                return Err(ConnectError::Protocol("host closed the connection after the handshake".into()))
            }
            Err(e) => return Err(e),
        };
        // Streaming: no read timeout (the host only sends on change; pings keep it alive).
        stream.set_read_timeout(None).map_err(ConnectError::Io)?;
        reader.get_ref().set_read_timeout(None).map_err(ConnectError::Io)?;
        Ok(Connection {
            sender: Sender { inner: Arc::new(Mutex::new(SenderInner { stream, sealer, dead: false })) },
            host_name,
            config,
            clock: Arc::new(Mutex::new(ClockSync::default())),
            host_key,
            paired: pairing,
            reader: Some((reader, opener)),
            stop: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Start the receive thread. Pongs are folded into `self.clock` before being
    /// passed on. The handler runs on the receive thread; it must be quick or hand off.
    pub fn spawn_receiver<F>(&mut self, mut handler: F) -> JoinHandle<()>
    where
        F: FnMut(NetEvent) + Send + 'static,
    {
        let (mut reader, mut opener) = self.reader.take().expect("receiver already started");
        let clock = self.clock.clone();
        let stop = self.stop.clone();
        let sender = self.sender.clone();
        thread::Builder::new()
            .name("glide-recv".into())
            .spawn(move || {
                let mut buf = Vec::with_capacity(1 << 20);
                loop {
                    let pt = match opener.read_record(&mut reader, &mut buf) {
                        Ok(pt) => pt,
                        Err(e) => {
                            if !stop.load(Ordering::Relaxed) {
                                handler(NetEvent::Closed(e.to_string()));
                            }
                            sender.shutdown();
                            return;
                        }
                    };
                    match HostMsg::decode(pt) {
                        Ok(msg) => {
                            if let HostMsg::Pong { client_time_us, host_time_us } = msg {
                                clock.lock().unwrap().on_pong(client_time_us, host_time_us, now_us());
                            }
                            handler(NetEvent::Msg(msg));
                        }
                        Err(e) => {
                            handler(NetEvent::Closed(format!("protocol error: {e}")));
                            sender.shutdown();
                            return;
                        }
                    }
                }
            })
            .expect("spawn receiver")
    }

    /// Send a Ping every `interval` until the connection closes or `stop()` is called.
    pub fn spawn_pinger(&self, interval: Duration) -> JoinHandle<()> {
        let sender = self.sender.clone();
        let stop = self.stop.clone();
        thread::Builder::new()
            .name("glide-ping".into())
            .spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    if sender.send(&ClientMsg::Ping { client_time_us: now_us() }).is_err() {
                        return;
                    }
                    // Sleep in small steps so stop() is responsive.
                    let mut slept = Duration::ZERO;
                    while slept < interval && !stop.load(Ordering::Relaxed) {
                        thread::sleep(Duration::from_millis(50));
                        slept += Duration::from_millis(50);
                    }
                }
            })
            .expect("spawn pinger")
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.sender.shutdown();
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::testhost::{serve, HostCfg, Outcome};
    use std::sync::atomic::AtomicUsize;

    /// Scripted user at the pairing prompt.
    pub(crate) struct TestUi {
        pub answer: bool,
        /// Answer after this long (unless dismissed first).
        pub delay: Duration,
        pub dismissed: AtomicBool,
        pub shown: Mutex<Vec<PairPrompt>>,
        pub dismiss_calls: AtomicUsize,
    }
    impl TestUi {
        pub fn new(answer: bool) -> Arc<TestUi> {
            Arc::new(TestUi { answer, delay: Duration::ZERO, dismissed: AtomicBool::new(false), shown: Mutex::new(vec![]), dismiss_calls: AtomicUsize::new(0) })
        }
    }
    impl PairingUi for TestUi {
        fn confirm(&self, p: &PairPrompt) -> bool {
            self.shown.lock().unwrap().push(p.clone());
            let end = std::time::Instant::now() + self.delay;
            while std::time::Instant::now() < end {
                if self.dismissed.load(Ordering::SeqCst) {
                    return false;
                }
                thread::sleep(Duration::from_millis(5));
            }
            self.answer && !self.dismissed.load(Ordering::SeqCst)
        }
        fn dismiss(&self) {
            self.dismiss_calls.fetch_add(1, Ordering::SeqCst);
            self.dismissed.store(true, Ordering::SeqCst);
        }
    }

    pub(crate) fn hello() -> ClientMsg {
        ClientMsg::ClientHello { version: 2, codec_caps: 1, view_w: 1, view_h: 1, mode: 0, max_fps: 60, client_name: "t".into() }
    }

    pub(crate) fn auth(id: &Identity, pinned: Option<[u8; 32]>, ui: Arc<TestUi>) -> Auth {
        Auth { identity: id.clone(), name: "test-pc".into(), target: "test:1".into(), pinned, request_pairing: false, pairing: ui }
    }

    /// Run the fake host on a loopback listener and connect the viewer to it.
    fn run(cfg: HostCfg, a: &Auth) -> (Result<Connection, ConnectError>, Outcome) {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let h = thread::spawn(move || serve(l.accept().unwrap().0, &cfg));
        let r = Connection::connect(&addr.to_string(), a, &hello());
        let out = h.join().unwrap();
        (r, out)
    }

    #[test]
    fn paired_viewer_connects_without_prompt() {
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let mut cfg = HostCfg::new(host.clone());
        cfg.paired = vec![viewer.public()];
        let ui = TestUi::new(true);
        let (r, out) = run(cfg, &auth(&viewer, Some(host.public()), ui.clone()));
        let c = r.unwrap();
        assert_eq!((c.host_name.as_str(), c.host_key, c.paired), ("fake", host.public(), false));
        assert_eq!(out, Outcome::Streaming { viewer_key: viewer.public(), name: "test-pc".into(), paired_now: false });
        assert!(ui.shown.lock().unwrap().is_empty(), "no pairing prompt for a pinned host");
    }

    #[test]
    fn unknown_viewer_is_rejected() {
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let (r, out) = run(HostCfg::new(host.clone()), &auth(&viewer, Some(host.public()), TestUi::new(true)));
        let e = r.err().unwrap();
        assert!(e.is_unknown_viewer(), "{e:?}");
        assert!(e.user_message("mac").contains("Pair New Viewer"));
        assert_eq!(out, Outcome::Rejected(crate::protocol::AUTH_UNKNOWN_VIEWER));
    }

    #[test]
    fn pairing_flow_both_confirm() {
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let mut cfg = HostCfg::new(host.clone());
        cfg.pairing_open = true;
        cfg.confirm_delay = Duration::from_millis(100);
        let ui = TestUi::new(true);
        let (r, out) = run(cfg, &auth(&viewer, None, ui.clone()));
        let c = r.unwrap();
        assert!(c.paired && c.host_key == host.public());
        assert_eq!(out, Outcome::Streaming { viewer_key: viewer.public(), name: "test-pc".into(), paired_now: true });
        let shown = ui.shown.lock().unwrap();
        assert_eq!(shown.len(), 1);
        assert_eq!(shown[0].code.len(), 7);
        assert_eq!(shown[0].host_fingerprint, host.fingerprint());
        assert_eq!(shown[0].viewer_fingerprint, viewer.fingerprint());
    }

    #[test]
    fn repair_with_same_pinned_key() {
        // The Mac forgot this viewer: request_pairing re-pairs, but only with the pinned key.
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let mut cfg = HostCfg::new(host.clone());
        cfg.pairing_open = true;
        let mut a = auth(&viewer, Some(host.public()), TestUi::new(true));
        a.request_pairing = true;
        let (r, out) = run(cfg.clone(), &a);
        assert!(r.unwrap().paired);
        assert!(matches!(out, Outcome::Streaming { paired_now: true, .. }));
        a.pinned = Some([7; 32]);
        let (r, out) = run(cfg, &a);
        assert!(matches!(r, Err(ConnectError::HostKeyChanged { .. })));
        assert!(matches!(out, Outcome::Closed(ref s) if s.contains("before msg3")), "{out:?}");
    }

    #[test]
    fn pairing_rejections() {
        let (host, viewer) = (Identity::generate(), Identity::generate());
        // window closed
        let (r, out) = run(HostCfg::new(host.clone()), &auth(&viewer, None, TestUi::new(true)));
        assert!(matches!(r, Err(ConnectError::Rejected(crate::protocol::AUTH_PAIRING_CLOSED))));
        assert_eq!(out, Outcome::Rejected(crate::protocol::AUTH_PAIRING_CLOSED));
        // the Mac says no
        let mut cfg = HostCfg::new(host.clone());
        cfg.pairing_open = true;
        cfg.confirm = false;
        let (r, _) = run(cfg.clone(), &auth(&viewer, None, TestUi::new(true)));
        assert!(matches!(r, Err(ConnectError::Rejected(crate::protocol::AUTH_DECLINED))), "{:?}", r.err());
        // the PC says no
        cfg.confirm = true;
        let (r, out) = run(cfg.clone(), &auth(&viewer, None, TestUi::new(false)));
        assert!(matches!(r, Err(ConnectError::PairingCancelled)));
        assert_eq!(out, Outcome::ViewerDeclined);
        // the Mac gives up while the PC's prompt is open: the prompt is dismissed
        cfg.abort_after_reveal = Some(crate::protocol::AUTH_TIMEOUT);
        let ui = Arc::new(TestUi { delay: Duration::from_secs(20), ..Arc::try_unwrap(TestUi::new(true)).ok().unwrap() });
        let t0 = std::time::Instant::now();
        let (r, _) = run(cfg, &auth(&viewer, None, ui.clone()));
        assert!(matches!(r, Err(ConnectError::Rejected(crate::protocol::AUTH_TIMEOUT))), "{:?}", r.err());
        assert!(ui.dismiss_calls.load(Ordering::SeqCst) >= 1);
        assert!(t0.elapsed() < Duration::from_secs(5), "prompt closed when the host gave up");
    }

    /// Security review: an unpaired / unauthenticated peer must not be able to hold the
    /// connection for the pairing timeout. Until PairReveal arrives (small, with a valid
    /// commitment) the short wall-clock pre-auth deadline applies and no prompt is shown.
    #[test]
    fn preauth_deadline_holds_until_a_valid_pair_reveal() {
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let connect_with = |cfg: HostCfg, ui: Arc<TestUi>, deadline: Duration| {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = l.local_addr().unwrap();
            let h = thread::spawn(move || serve(l.accept().unwrap().0, &cfg));
            let paired_phase = Arc::new(AtomicBool::new(false));
            let pp = paired_phase.clone();
            let t0 = std::time::Instant::now();
            let s = TcpStream::connect(addr).unwrap();
            let r = Connection::from_stream_timeout(s, &auth(&viewer, None, ui), &hello(), deadline, &move || pp.store(true, Ordering::SeqCst));
            let took = t0.elapsed();
            let _ = h.join();
            (r, took, paired_phase.load(Ordering::SeqCst))
        };
        let mut cfg = HostCfg::new(host.clone());
        cfg.pairing_open = true;
        // 1. silent after msg3: cut off by the 300 ms pre-auth deadline, not PAIRING_TIMEOUT
        let mut c = cfg.clone();
        c.stall_after_msg3 = Some(Duration::from_secs(3));
        let ui = TestUi::new(true);
        let (r, took, lifted) = connect_with(c, ui.clone(), Duration::from_millis(300));
        assert!(matches!(r, Err(ConnectError::Io(ref e)) if e.kind() == std::io::ErrorKind::TimedOut || e.kind() == std::io::ErrorKind::WouldBlock), "{:?}", r.err());
        assert!(took < Duration::from_secs(2), "pre-auth deadline enforced ({took:?})");
        assert!(!lifted && ui.shown.lock().unwrap().is_empty(), "no pairing phase, no prompt");
        // 2. oversized first record: rejected by size before it is read
        let mut c = cfg.clone();
        c.oversize_reveal = true;
        let ui = TestUi::new(true);
        let (r, _, lifted) = connect_with(c, ui.clone(), Duration::from_secs(2));
        assert!(matches!(r, Err(ConnectError::Crypto(CryptoError::BadRecordLength(n))) if n > PAIR_REVEAL_MAX_RECORD), "{:?}", r.err());
        assert!(!lifted && ui.shown.lock().unwrap().is_empty());
        // 3. a reveal that doesn't open the commitment: no prompt
        let mut c = cfg.clone();
        c.wrong_reveal = true;
        let ui = TestUi::new(true);
        let (r, _, lifted) = connect_with(c, ui.clone(), Duration::from_secs(2));
        assert!(matches!(r, Err(ConnectError::PairingFailed(ref s)) if s.contains("commitment")), "{:?}", r.err());
        assert!(!lifted && ui.shown.lock().unwrap().is_empty());
        // 4. a valid reveal lifts the pre-auth deadline: a user slower than it still pairs
        let ui = Arc::new(TestUi { delay: Duration::from_millis(700), ..Arc::try_unwrap(TestUi::new(true)).ok().unwrap() });
        let (r, _, lifted) = connect_with(cfg, ui, Duration::from_millis(300));
        assert!(r.unwrap().paired && lifted);
    }

    #[test]
    fn host_key_change_and_old_or_refusing_hosts() {
        let (host, viewer) = (Identity::generate(), Identity::generate());
        let (r, out) = run(HostCfg::new(host.clone()), &auth(&viewer, Some(Identity::generate().public()), TestUi::new(true)));
        let e = r.err().unwrap();
        assert!(matches!(e, ConnectError::HostKeyChanged { presented, .. } if presented == host.public()));
        assert!(e.user_message("mac").contains("HOST KEY CHANGED"));
        assert!(matches!(out, Outcome::Closed(_)));
        // v1 host: reads 54 bytes and hangs up
        let mut cfg = HostCfg::new(host.clone());
        cfg.v1 = true;
        let (r, _) = run(cfg, &auth(&viewer, None, TestUi::new(true)));
        let e = r.err().unwrap();
        assert!(matches!(e, ConnectError::HostIsV1), "{e:?}");
        assert!(e.user_message("mac").contains("Glide v1"));
        // rate limited / paused
        for st in [crate::handshake::ST_RATE_LIMITED, crate::handshake::ST_PAUSED] {
            let mut cfg = HostCfg::new(host.clone());
            cfg.status = st;
            let (r, _) = run(cfg, &auth(&viewer, None, TestUi::new(true)));
            assert!(matches!(r, Err(ConnectError::Refused { status, .. }) if status == st));
        }
    }

    #[test]
    fn addr_parsing() {
        assert_eq!(parse_addr("192.168.50.4"), "192.168.50.4:7420");
        assert_eq!(parse_addr("192.168.50.4:7421"), "192.168.50.4:7421");
        assert_eq!(parse_addr("mac.local"), "mac.local:7420");
        assert_eq!(parse_addr("[::1]:9"), "[::1]:9");
        assert_eq!(parse_addr("::1"), "[::1]:7420");
    }

    #[test]
    fn clock_sync_prefers_lowest_rtt() {
        let mut c = ClockSync::default();
        // client sent at 1000, host stamped 501000 (offset ~ +500000), reply at 3000 (rtt 2000)
        c.on_pong(1000, 502000, 3000);
        assert_eq!(c.offset_us, Some(500000));
        // a slower sample must not override the better estimate
        c.on_pong(10_000, 600_000, 30_000);
        assert_eq!(c.offset_us, Some(500000));
        assert_eq!(c.host_to_client_us(600_000), Some(100_000));
        assert_eq!(c.rtts_ms.len(), 2);
    }
}
