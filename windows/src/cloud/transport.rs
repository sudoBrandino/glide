//! HTTP and WebSocket client abstraction. The Windows implementation is WinHTTP (`winhttp`:
//! system proxy settings, the OS certificate store, so an org's TLS-inspection root works, §3.3);
//! tests use in-memory fakes. Everything above this (API client, hub, relay bridge) is generic.

use std::io;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: &'static str,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    /// Total time allowed (`POST /v1/sessions` waits up to 60 s for the host's answer).
    pub timeout: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// A WebSocket message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WsMsg {
    Text(String),
    Binary(Vec<u8>),
    /// The peer closed (code, reason). Only returned by `recv`.
    Close(u16, String),
}

/// Largest message a client accepts (relay frames are ≤ 1 MiB, hub frames far smaller).
pub const MAX_MESSAGE: usize = 1 << 20;

/// A connected WebSocket. One thread may `recv` while others `send` (sends are serialized by the
/// implementation); `close` may be called from any thread and makes a blocked `recv` return.
pub trait WebSocket: Send + Sync {
    fn send(&self, m: WsMsg) -> io::Result<()>;
    /// Blocks for the next message. A message larger than `MAX_MESSAGE` is an error.
    fn recv(&self) -> io::Result<WsMsg>;
    fn close(&self, code: u16, reason: &str);
}

/// Why a WebSocket upgrade failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WsConnectError {
    /// The server answered with this HTTP status instead of 101.
    Status(u16),
    /// Network / TLS / proxy problem.
    Transport(String),
}

impl std::fmt::Display for WsConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WsConnectError::Status(s) => write!(f, "WebSocket upgrade refused (HTTP {s})"),
            WsConnectError::Transport(e) => write!(f, "{e}"),
        }
    }
}

pub trait Http: Send + Sync {
    /// One request; Err = no HTTP response (network, TLS, proxy, timeout).
    fn request(&self, req: &Request) -> Result<Response, String>;
    /// Opens a WebSocket (`url` is `wss://…` or, to a loopback host, `ws://…`).
    fn websocket(&self, url: &str, headers: &[(String, String)]) -> Result<Arc<dyn WebSocket>, WsConnectError>;
}

/// Percent-encodes a query value (RFC 3986 unreserved characters pass).
pub fn query_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// In-memory WebSocket pair for tests: what one end sends, the other receives.
#[cfg(test)]
pub mod fake {
    use super::*;
    use std::sync::mpsc;
    use std::sync::Mutex;

    pub struct FakeWs {
        tx: Mutex<Option<mpsc::Sender<WsMsg>>>,
        /// Feeds this end's own `recv` (the server echoing a close).
        echo: mpsc::Sender<WsMsg>,
        rx: Mutex<mpsc::Receiver<WsMsg>>,
        /// Everything sent through this end (for assertions).
        pub sent: Mutex<Vec<WsMsg>>,
        pub closed: Mutex<Option<u16>>,
    }

    /// Two connected ends.
    pub fn pair() -> (Arc<FakeWs>, Arc<FakeWs>) {
        let (atx, brx) = mpsc::channel();
        let (btx, arx) = mpsc::channel();
        let mk = |tx, echo, rx| Arc::new(FakeWs { tx: Mutex::new(Some(tx)), echo, rx: Mutex::new(rx), sent: Mutex::new(vec![]), closed: Mutex::new(None) });
        let (a_echo, b_echo) = (btx.clone(), atx.clone());
        (mk(atx, a_echo, arx), mk(btx, b_echo, brx))
    }

    impl FakeWs {
        /// A message already queued for this end, without blocking.
        pub fn try_recv(&self) -> Option<WsMsg> {
            self.rx.lock().unwrap().try_recv().ok()
        }
    }

    impl WebSocket for FakeWs {
        fn send(&self, m: WsMsg) -> io::Result<()> {
            self.sent.lock().unwrap().push(m.clone());
            match self.tx.lock().unwrap().as_ref() {
                Some(tx) => tx.send(m).map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "peer gone")),
                None => Err(io::Error::new(io::ErrorKind::NotConnected, "closed")),
            }
        }
        fn recv(&self) -> io::Result<WsMsg> {
            match self.rx.lock().unwrap().recv() {
                Ok(WsMsg::Binary(b)) if b.len() > MAX_MESSAGE => Err(io::Error::new(io::ErrorKind::InvalidData, "message too large")),
                Ok(m) => Ok(m),
                Err(_) => Ok(WsMsg::Close(1006, "gone".into())),
            }
        }
        fn close(&self, code: u16, reason: &str) {
            let mut c = self.closed.lock().unwrap();
            if c.is_none() {
                *c = Some(code);
            }
            if let Some(tx) = self.tx.lock().unwrap().take() {
                let _ = tx.send(WsMsg::Close(code, reason.into()));
                let _ = self.echo.send(WsMsg::Close(code, reason.into()));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn escape() {
        assert_eq!(super::query_escape("eyJzaWQ.abc-_~"), "eyJzaWQ.abc-_~");
        assert_eq!(super::query_escape("a b+/="), "a%20b%2B%2F%3D");
    }
}
