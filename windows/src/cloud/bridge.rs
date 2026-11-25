//! Client-side relay bridge (docs/ENTERPRISE.md §6.6): the session code runs on TCP streams, so a
//! managed session plugs the relay WebSocket in through a loopback socket pair.
//!
//! 1. Bind `127.0.0.1:0`, connect to it, accept. The accepted socket's peer port must equal the
//!    connecting socket's local port; otherwise another local process won the race: close both
//!    and retry. Close the listener.
//! 2. Pump: socket → WebSocket binary frames (reads of up to 256 KiB, one frame each),
//!    WebSocket binary → socket. Either side closing closes both.
//! 3. The other end goes to the existing connection code.
//!
//! Nothing binary is sent before the relay's `peer_joined` (§6.5): `open` waits for it before it
//! even creates the socket pair. Noise authenticates the peer whatever happens on the loopback hop.

use super::api::{close, RelayControl};
use super::transport::{WebSocket, WsMsg, MAX_MESSAGE};
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// Largest socket read, sent as one binary frame.
pub const READ_MAX: usize = 256 << 10;
/// Largest binary frame accepted from the relay (senders keep frames ≤ 1 MiB).
pub const FRAME_MAX: usize = MAX_MESSAGE;
/// The relay waits 60 s for the second side; give up a little after that.
pub const JOIN_WAIT: Duration = Duration::from_secs(70);
/// Loopback pairing attempts before giving up.
const PAIR_ATTEMPTS: u32 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeError {
    /// The relay closed before the other side joined (code, reason).
    Closed(u16, String),
    /// Nobody joined within `JOIN_WAIT`.
    PeerDidNotJoin,
    /// The relay broke the protocol (binary data before `peer_joined`).
    Protocol(String),
    Io(String),
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BridgeError::Closed(code, _) => write!(f, "{} (relay close {code})", close::describe(*code)),
            BridgeError::PeerDidNotJoin => write!(f, "the other computer didn't join the session"),
            BridgeError::Protocol(e) => write!(f, "relay protocol error: {e}"),
            BridgeError::Io(e) => write!(f, "{e}"),
        }
    }
}

/// Whether the connection `accept()` returned is ours: its peer is our connecting socket.
pub fn is_our_connection(accepted_peer: SocketAddr, connector_local: SocketAddr) -> bool {
    accepted_peer.port() == connector_local.port() && accepted_peer.ip() == connector_local.ip()
}

/// Step 1 with the real loopback: (app end, pump end).
pub fn loopback_pair() -> io::Result<(TcpStream, TcpStream)> {
    loopback_pair_with(&|| TcpListener::bind("127.0.0.1:0"), &|a| TcpStream::connect(a)).map(|(a, p, _)| (a, p))
}

/// Step 1 with injectable bind/connect (tests race another "process" against it). Returns the
/// app end (the socket we connected), the pump end (the one we accepted) and the attempts used.
pub fn loopback_pair_with(bind: &dyn Fn() -> io::Result<TcpListener>, connect: &dyn Fn(SocketAddr) -> io::Result<TcpStream>) -> io::Result<(TcpStream, TcpStream, u32)> {
    for attempt in 1..=PAIR_ATTEMPTS {
        let listener = bind()?;
        let addr = listener.local_addr()?;
        let app = connect(addr)?;
        let (pump, peer) = listener.accept()?;
        drop(listener);
        if is_our_connection(peer, app.local_addr()?) {
            let _ = app.set_nodelay(true);
            let _ = pump.set_nodelay(true);
            return Ok((app, pump, attempt));
        }
        crate::host::log(&format!("relay bridge: loopback connection from an unexpected port {} (ours {}); retrying", peer.port(), app.local_addr()?.port()));
        let _ = pump.shutdown(Shutdown::Both);
        let _ = app.shutdown(Shutdown::Both);
    }
    Err(io::Error::other("another program kept taking the loopback connection"))
}

/// Waits for `peer_joined`. `on_waiting` runs when the relay says the other side is absent.
pub fn wait_peer_joined(ws: &Arc<dyn WebSocket>, on_waiting: &dyn Fn()) -> Result<(), BridgeError> {
    // recv() blocks; a watchdog closes the socket when the wait is over.
    let done = Arc::new(AtomicBool::new(false));
    let timed_out = Arc::new(AtomicBool::new(false));
    {
        let (ws, done, timed_out) = (ws.clone(), done.clone(), timed_out.clone());
        thread::spawn(move || {
            let end = Instant::now() + JOIN_WAIT;
            while Instant::now() < end {
                if done.load(Ordering::SeqCst) {
                    return;
                }
                thread::sleep(Duration::from_millis(100));
            }
            if !done.load(Ordering::SeqCst) {
                timed_out.store(true, Ordering::SeqCst);
                ws.close(close::NORMAL, "peer did not join");
            }
        });
    }
    let r = loop {
        match ws.recv() {
            Ok(WsMsg::Text(t)) => match serde_json::from_str::<RelayControl>(&t) {
                Ok(RelayControl::PeerJoined) => break Ok(()),
                Ok(RelayControl::Waiting) => on_waiting(),
                Ok(RelayControl::PeerLeft) => break Err(BridgeError::Closed(close::PEER_DID_NOT_JOIN, "peer left".into())),
                Ok(RelayControl::Unknown) | Err(_) => {}
            },
            Ok(WsMsg::Binary(_)) => {
                ws.close(close::PROTOCOL, "data before peer_joined");
                break Err(BridgeError::Protocol("binary data before peer_joined".into()));
            }
            Ok(WsMsg::Close(code, reason)) => break Err(BridgeError::Closed(code, reason)),
            Err(e) => break Err(BridgeError::Io(e.to_string())),
        }
    };
    done.store(true, Ordering::SeqCst);
    match r {
        Err(_) if timed_out.load(Ordering::SeqCst) => Err(BridgeError::PeerDidNotJoin),
        r => r,
    }
}

/// A running pump between the relay and the loopback socket.
pub struct Bridge {
    ws: Arc<dyn WebSocket>,
    pump: TcpStream,
    closed: Arc<AtomicBool>,
    /// The relay's close (code, reason), or a local reason.
    reason: Arc<Mutex<Option<(u16, String)>>>,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

fn close_both(ws: &Arc<dyn WebSocket>, sock: &TcpStream, closed: &AtomicBool, code: u16, why: &str) {
    if !closed.swap(true, Ordering::SeqCst) {
        let _ = sock.shutdown(Shutdown::Both);
        ws.close(code, why);
    }
}

impl Bridge {
    /// Step 2: pump between `ws` (the other side has joined) and `pump` (our loopback end).
    pub fn start(ws: Arc<dyn WebSocket>, pump: TcpStream) -> io::Result<Bridge> {
        let closed = Arc::new(AtomicBool::new(false));
        let reason: Arc<Mutex<Option<(u16, String)>>> = Arc::new(Mutex::new(None));
        let up = {
            let (ws, closed, mut sock, closer) = (ws.clone(), closed.clone(), pump.try_clone()?, pump.try_clone()?);
            thread::Builder::new().name("glide-relay-up".into()).spawn(move || {
                let mut buf = vec![0u8; READ_MAX];
                loop {
                    match sock.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if ws.send(WsMsg::Binary(buf[..n].to_vec())).is_err() {
                                break;
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
                close_both(&ws, &closer, &closed, close::NORMAL, "");
            })?
        };
        let down = {
            let (ws, closed, reason, mut sock, closer) = (ws.clone(), closed.clone(), reason.clone(), pump.try_clone()?, pump.try_clone()?);
            thread::Builder::new().name("glide-relay-down".into()).spawn(move || {
                let mut code = close::NORMAL;
                loop {
                    match ws.recv() {
                        Ok(WsMsg::Binary(b)) => {
                            if b.len() > FRAME_MAX {
                                reason.lock().unwrap().get_or_insert((close::PROTOCOL, "oversized relay frame".into()));
                                code = close::PROTOCOL;
                                break;
                            }
                            if sock.write_all(&b).is_err() {
                                break;
                            }
                        }
                        Ok(WsMsg::Text(t)) => {
                            if let Ok(RelayControl::PeerLeft) = serde_json::from_str::<RelayControl>(&t) {
                                reason.lock().unwrap().get_or_insert((close::NORMAL, "peer left".into()));
                            }
                        }
                        Ok(WsMsg::Close(c, r)) => {
                            reason.lock().unwrap().get_or_insert((c, r));
                            break;
                        }
                        Err(e) => {
                            reason.lock().unwrap().get_or_insert((1006, e.to_string()));
                            break;
                        }
                    }
                }
                close_both(&ws, &closer, &closed, code, "");
            })?
        };
        Ok(Bridge { ws, pump, closed, reason, threads: Mutex::new(vec![up, down]) })
    }

    /// End the session from this side (End session / Disconnect).
    pub fn close(&self) {
        self.reason.lock().unwrap().get_or_insert((close::NORMAL, "ended here".into()));
        close_both(&self.ws, &self.pump, &self.closed, close::NORMAL, "");
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// The relay's close code and reason (or a local reason) once closed.
    pub fn close_reason(&self) -> Option<(u16, String)> {
        self.reason.lock().unwrap().clone()
    }

    /// Wait for both pump threads.
    pub fn join(&self) {
        for t in self.threads.lock().unwrap().drain(..) {
            let _ = t.join();
        }
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        close_both(&self.ws, &self.pump, &self.closed, close::NORMAL, "");
    }
}

/// Wait for `peer_joined`, pair the loopback sockets and start the pump. Returns the app's end.
pub fn open(ws: Arc<dyn WebSocket>, on_waiting: &dyn Fn()) -> Result<(TcpStream, Bridge), BridgeError> {
    if let Err(e) = wait_peer_joined(&ws, on_waiting) {
        ws.close(close::NORMAL, "");
        return Err(e);
    }
    let (app, pump) = loopback_pair().map_err(|e| {
        ws.close(close::NORMAL, "");
        BridgeError::Io(format!("loopback bridge: {e}"))
    })?;
    let b = Bridge::start(ws, pump).map_err(|e| BridgeError::Io(e.to_string()))?;
    Ok((app, b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::transport::fake::{pair, FakeWs};
    use std::cell::Cell;

    fn relay_text(ws: &FakeWs, ty: &str) {
        ws.send(WsMsg::Text(format!(r#"{{"type":"{ty}"}}"#))).unwrap();
    }

    fn binaries(ws: &FakeWs) -> Vec<u8> {
        ws.sent.lock().unwrap().iter().filter_map(|m| if let WsMsg::Binary(b) = m { Some(b.clone()) } else { None }).flatten().collect()
    }

    #[test]
    fn pair_rejects_a_stranger_who_wins_the_race() {
        let attempt = Cell::new(0);
        let strangers = Mutex::new(Vec::new());
        let (app, pump, attempts) = loopback_pair_with(&|| TcpListener::bind("127.0.0.1:0"), &|addr| {
            attempt.set(attempt.get() + 1);
            if attempt.get() == 1 {
                // Another local process connects first and sits in the accept queue ahead of us.
                strangers.lock().unwrap().push(TcpStream::connect(addr)?);
            }
            TcpStream::connect(addr)
        })
        .unwrap();
        assert_eq!(attempts, 2, "the first pairing was refused and retried");
        assert!(is_our_connection(pump.peer_addr().unwrap(), app.local_addr().unwrap()));
        // The stranger's socket was closed by us.
        let mut s = strangers.lock().unwrap().pop().unwrap();
        s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut b = [0u8; 1];
        assert!(matches!(s.read(&mut b), Ok(0) | Err(_)));
        assert!(!is_our_connection("127.0.0.1:5000".parse().unwrap(), "127.0.0.1:5001".parse().unwrap()));
    }

    #[test]
    fn pump_both_ways_and_close() {
        let (client, relay) = pair();
        relay_text(&relay, "waiting");
        relay_text(&relay, "peer_joined");
        let waited = Cell::new(false);
        let (mut app, bridge) = open(client.clone(), &|| waited.set(true)).unwrap();
        assert!(waited.get());
        // Viewer → relay.
        app.write_all(b"hello relay").unwrap();
        let end = Instant::now() + Duration::from_secs(5);
        while binaries(&client) != b"hello relay" && Instant::now() < end {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(binaries(&client), b"hello relay");
        // Relay → viewer, frame boundaries don't matter.
        relay.send(WsMsg::Binary(b"from ".to_vec())).unwrap();
        relay.send(WsMsg::Binary(b"host".to_vec())).unwrap();
        let mut got = [0u8; 9];
        app.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        app.read_exact(&mut got).unwrap();
        assert_eq!(&got, b"from host");
        // The relay closes: the loopback socket closes too.
        relay.send(WsMsg::Text(r#"{"type":"peer_left"}"#.into())).unwrap();
        relay.close(close::ENDED_BY_ADMIN, "admin");
        let mut b = [0u8; 1];
        assert!(matches!(app.read(&mut b), Ok(0) | Err(_)));
        bridge.join();
        assert!(bridge.is_closed());
        assert_eq!(bridge.close_reason().map(|r| r.0), Some(close::NORMAL), "peer_left arrived first");
    }

    #[test]
    fn app_closing_closes_the_relay_socket() {
        let (client, relay) = pair();
        relay_text(&relay, "peer_joined");
        let (app, bridge) = open(client.clone(), &|| {}).unwrap();
        drop(app);
        bridge.join();
        assert!(bridge.is_closed());
        assert_eq!(*client.closed.lock().unwrap(), Some(close::NORMAL));
        let _ = relay;
    }

    #[test]
    fn nothing_is_sent_before_peer_joined() {
        // Data before peer_joined from the relay is a protocol violation; nothing was sent by us.
        let (client, relay) = pair();
        relay_text(&relay, "waiting");
        relay.send(WsMsg::Binary(vec![1, 2, 3])).unwrap();
        assert!(matches!(open(client.clone(), &|| {}), Err(BridgeError::Protocol(_))));
        assert!(binaries(&client).is_empty());
        // The relay closing while waiting (4004: the other side never came).
        let (client, relay) = pair();
        relay_text(&relay, "waiting");
        relay.close(close::PEER_DID_NOT_JOIN, "timeout");
        assert_eq!(open(client.clone(), &|| {}).err(), Some(BridgeError::Closed(close::PEER_DID_NOT_JOIN, "timeout".into())));
        assert!(binaries(&client).is_empty());
    }

    #[test]
    fn oversized_frames_end_the_session() {
        let (client, relay) = pair();
        relay_text(&relay, "peer_joined");
        let (mut app, bridge) = open(client.clone(), &|| {}).unwrap();
        // The fake enforces MAX_MESSAGE in recv like the real transport does.
        relay.send(WsMsg::Binary(vec![0; FRAME_MAX + 1])).unwrap();
        let mut b = [0u8; 1];
        app.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        assert!(matches!(app.read(&mut b), Ok(0) | Err(_)));
        bridge.join();
        assert!(bridge.is_closed());
    }

    #[test]
    fn large_writes_are_split_into_frames_of_at_most_256_kib() {
        let (client, relay) = pair();
        relay_text(&relay, "peer_joined");
        let (mut app, bridge) = open(client.clone(), &|| {}).unwrap();
        let data: Vec<u8> = (0..(READ_MAX * 3 + 17)).map(|i| i as u8).collect();
        app.write_all(&data).unwrap();
        let end = Instant::now() + Duration::from_secs(5);
        while binaries(&client).len() < data.len() && Instant::now() < end {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(binaries(&client), data);
        assert!(client.sent.lock().unwrap().iter().all(|m| !matches!(m, WsMsg::Binary(b) if b.len() > READ_MAX)));
        bridge.close();
        bridge.join();
        let _ = relay;
    }
}
