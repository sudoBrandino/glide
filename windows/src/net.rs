//! TCP transport: connect + handshake, a shared encrypted writer (single send counter),
//! a dedicated receive thread, and a 1 Hz ping thread with RTT / clock-offset tracking.
//! Platform independent (std::net only).

use crate::crypto::{self, CryptoError, Opener, Sealer};
use crate::protocol::{ClientMsg, HostMsg, VideoConfig};
use crate::util::now_us;
use std::io::{BufReader, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// Thread-safe encrypted message writer. Cloning shares the same socket and counter.
///
/// Two priorities share the one record counter:
/// - `send` (input, control, acks): written immediately, on the caller's thread.
/// - `send_bulk` (file chunks, §6): yields to every pending `send`. A bulk record is only started
///   while no normal send is waiting, so an input event never queues behind more than the one
///   chunk (≤ FILE_CHUNK_MAX) already being written. Bulk senders also bound what sits in the
///   kernel socket buffer with the FileAck window (FILE_WINDOW), see `files`.
#[derive(Clone)]
pub struct Sender {
    inner: Arc<Mutex<SenderInner>>,
    /// Normal-priority sends waiting for (or holding) the lock.
    urgent: Arc<AtomicUsize>,
}

struct SenderInner {
    out: Box<dyn Write + Send>,
    /// Same socket, for shutdown (None for in-memory test writers).
    closer: Option<TcpStream>,
    sealer: Sealer,
    dead: bool,
}

impl Sender {
    fn new(stream: TcpStream, sealer: Sealer) -> std::io::Result<Sender> {
        let closer = stream.try_clone()?;
        Ok(Sender::with_writer(Box::new(stream), Some(closer), sealer))
    }

    /// A sender over any writer (tests and tooling).
    pub fn with_writer(out: Box<dyn Write + Send>, closer: Option<TcpStream>, sealer: Sealer) -> Sender {
        Sender {
            inner: Arc::new(Mutex::new(SenderInner { out, closer, sealer, dead: false })),
            urgent: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn write_locked(g: &mut SenderInner, pt: &[u8]) -> std::io::Result<()> {
        if g.dead {
            return Err(std::io::Error::new(std::io::ErrorKind::NotConnected, "connection closed"));
        }
        // Seal under the lock so record order on the wire == counter order.
        let rec = g.sealer.seal(pt);
        let r = g.out.write_all(&rec);
        if r.is_err() {
            g.dead = true;
        }
        r
    }

    /// Send one message now (input, control). Never waits behind more than one bulk record.
    pub fn send(&self, msg: &ClientMsg) -> std::io::Result<()> {
        self.send_plaintext(&msg.encode())
    }

    /// `send` for an already encoded message (`type || payload`).
    pub fn send_plaintext(&self, pt: &[u8]) -> std::io::Result<()> {
        self.urgent.fetch_add(1, Ordering::SeqCst);
        let mut g = self.inner.lock().unwrap();
        self.urgent.fetch_sub(1, Ordering::SeqCst);
        Self::write_locked(&mut g, pt)
    }

    /// Send a low-priority message (a file chunk): waits until no normal send is pending.
    pub fn send_bulk(&self, msg: &ClientMsg) -> std::io::Result<()> {
        self.send_bulk_plaintext(&msg.encode())
    }

    /// `send_bulk` for an already encoded message.
    pub fn send_bulk_plaintext(&self, pt: &[u8]) -> std::io::Result<()> {
        let mut spins = 0u32;
        loop {
            if self.urgent.load(Ordering::SeqCst) == 0 {
                let mut g = self.inner.lock().unwrap();
                // Re-check under the lock: a normal send that arrived meanwhile goes first.
                if self.urgent.load(Ordering::SeqCst) == 0 {
                    return Self::write_locked(&mut g, pt);
                }
            }
            spins += 1;
            if spins < 64 {
                std::thread::yield_now();
            } else {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }

    pub fn shutdown(&self) {
        let mut g = self.inner.lock().unwrap();
        g.dead = true;
        if let Some(c) = &g.closer {
            let _ = c.shutdown(Shutdown::Both);
        }
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

pub enum NetEvent {
    Msg(HostMsg),
    Closed(String),
}

pub struct Connection {
    pub sender: Sender,
    pub host_name: String,
    pub config: VideoConfig,
    pub clock: Arc<Mutex<ClockSync>>,
    reader: Option<(BufReader<TcpStream>, Opener)>,
    stop: Arc<AtomicBool>,
}

#[derive(Debug)]
pub enum ConnectError {
    Resolve(String),
    Io(std::io::Error),
    Crypto(CryptoError),
    Protocol(String),
    /// Host closed/reset the connection right after ClientHello, or our first decrypt failed:
    /// almost certainly a password mismatch.
    AuthFailed(String),
}

impl ConnectError {
    pub fn is_auth_failure(&self) -> bool {
        matches!(self, ConnectError::AuthFailed(_))
    }
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectError::Resolve(s) => write!(f, "cannot resolve {s}"),
            ConnectError::Io(e) => write!(f, "{e}"),
            ConnectError::Crypto(e) => write!(f, "{e}"),
            ConnectError::Protocol(s) => write!(f, "{s}"),
            ConnectError::AuthFailed(s) => write!(f, "authentication failed: {s}"),
        }
    }
}

impl std::error::Error for ConnectError {}

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

impl Connection {
    /// Connect, handshake, send `hello`, and wait for `ServerHello`.
    pub fn connect(addr: &str, password: &str, hello: &ClientMsg) -> Result<Connection, ConnectError> {
        let addr = parse_addr(addr);
        let sa = addr
            .to_socket_addrs()
            .map_err(|_| ConnectError::Resolve(addr.clone()))?
            .next()
            .ok_or_else(|| ConnectError::Resolve(addr.clone()))?;
        let stream = TcpStream::connect_timeout(&sa, Duration::from_secs(5)).map_err(ConnectError::Io)?;
        Self::from_stream(stream, password, hello)
    }

    /// Reverse-connect mode: listen on `0.0.0.0:port`, accept ONE TCP connection from the
    /// host, then run the normal client protocol on it (client still sends ClientHandshake first).
    pub fn listen(port: u16, password: &str, hello: &ClientMsg) -> Result<Connection, ConnectError> {
        let l = std::net::TcpListener::bind(("0.0.0.0", port)).map_err(ConnectError::Io)?;
        eprintln!("listening on 0.0.0.0:{port}, waiting for the host to connect...");
        let (stream, peer) = l.accept().map_err(ConnectError::Io)?;
        drop(l);
        eprintln!("host connected from {peer}");
        Self::from_stream(stream, password, hello)
    }

    /// Accept one connection on an existing (possibly reused) listener, polling `quit`.
    /// Returns Ok(None) if `quit` was set before a host connected.
    pub fn accept_on(
        listener: &std::net::TcpListener,
        password: &str,
        hello: &ClientMsg,
        quit: &AtomicBool,
    ) -> Result<Option<Connection>, ConnectError> {
        listener.set_nonblocking(true).map_err(ConnectError::Io)?;
        loop {
            if quit.load(Ordering::Relaxed) {
                return Ok(None);
            }
            match listener.accept() {
                Ok((stream, peer)) => {
                    // Accepted sockets inherit non-blocking mode on Windows.
                    stream.set_nonblocking(false).map_err(ConnectError::Io)?;
                    eprintln!("host connected from {peer}");
                    return Self::from_stream(stream, password, hello).map(Some);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(50)),
                Err(e) => return Err(ConnectError::Io(e)),
            }
        }
    }

    /// Run the client handshake on an already-connected stream.
    pub fn from_stream(stream: TcpStream, password: &str, hello: &ClientMsg) -> Result<Connection, ConnectError> {
        Self::from_stream_timeout(stream, password, hello, HANDSHAKE_TIMEOUT)
    }

    /// Like `from_stream`, with a per-read handshake timeout. Listen mode passes its pre-auth
    /// deadline here: on Windows, shutting a socket down from another thread does not interrupt a
    /// blocked recv(), so the read timeout itself must enforce the deadline.
    pub fn from_stream_timeout(mut stream: TcpStream, password: &str, hello: &ClientMsg, read_timeout: Duration) -> Result<Connection, ConnectError> {
        stream.set_nodelay(true).map_err(ConnectError::Io)?;
        stream.set_read_timeout(Some(read_timeout.min(HANDSHAKE_TIMEOUT).max(Duration::from_millis(50)))).map_err(ConnectError::Io)?;
        let sess = crypto::client_handshake(&mut stream, password).map_err(ConnectError::Crypto)?;
        let mut sealer = sess.sealer;
        let mut opener = sess.opener;
        stream.write_all(&sealer.seal(&hello.encode())).map_err(ConnectError::Io)?;

        let mut reader = BufReader::with_capacity(1 << 20, stream.try_clone().map_err(ConnectError::Io)?);
        let mut buf = Vec::new();
        let first = match opener.read_record(&mut reader, &mut buf) {
            Ok(pt) => pt,
            Err(CryptoError::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
                ) =>
            {
                return Err(ConnectError::AuthFailed("host closed the connection after ClientHello (wrong password?)".into()))
            }
            Err(CryptoError::DecryptFailed) => {
                return Err(ConnectError::AuthFailed("could not decrypt ServerHello (wrong password?)".into()))
            }
            Err(e) => return Err(ConnectError::Crypto(e)),
        };
        let (host_name, config) = match HostMsg::decode(first) {
            Ok(HostMsg::ServerHello { version, host_name, config }) => {
                if version != crate::protocol::PROTOCOL_VERSION {
                    return Err(ConnectError::Protocol(format!("host speaks protocol version {version}")));
                }
                (host_name, config)
            }
            Ok(other) => return Err(ConnectError::Protocol(format!("expected ServerHello, got {other:?}"))),
            Err(e) => return Err(ConnectError::Protocol(format!("bad ServerHello: {e}"))),
        };
        // Streaming: no read timeout (the host only sends on change; pings keep it alive).
        stream.set_read_timeout(None).map_err(ConnectError::Io)?;
        Ok(Connection {
            sender: Sender::new(stream, sealer).map_err(ConnectError::Io)?,
            host_name,
            config,
            clock: Arc::new(Mutex::new(ClockSync::default())),
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
mod tests {
    use super::*;

    #[test]
    fn addr_parsing() {
        assert_eq!(parse_addr("192.168.50.4"), "192.168.50.4:7420");
        assert_eq!(parse_addr("192.168.50.4:7421"), "192.168.50.4:7421");
        assert_eq!(parse_addr("mac.local"), "mac.local:7420");
        assert_eq!(parse_addr("[::1]:9"), "[::1]:9");
        assert_eq!(parse_addr("::1"), "[::1]:7420");
    }

    /// In-memory "link": records which kind of record was written and how many bulk bytes had
    /// been written before it; sleeps per byte to model a slow network.
    struct SlowLink {
        log: Arc<Mutex<Vec<(bool, usize)>>>,
        bulk_written: Arc<AtomicUsize>,
        ns_per_byte: u64,
    }

    impl Write for SlowLink {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            let bulk = b.len() > 4096;
            std::thread::sleep(Duration::from_nanos(self.ns_per_byte * b.len() as u64));
            self.log.lock().unwrap().push((bulk, self.bulk_written.load(Ordering::SeqCst)));
            if bulk {
                self.bulk_written.fetch_add(b.len(), Ordering::SeqCst);
            }
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Chunk scheduler fairness: while a file streams as fast as the link allows, every input
    /// event goes out with at most one chunk (256 KiB + record overhead) written after it was
    /// queued, and the file still completes.
    #[test]
    fn input_never_waits_behind_more_than_one_chunk() {
        use crate::protocol::{FileMsg, FILE_CHUNK_MAX};
        let log = Arc::new(Mutex::new(Vec::new()));
        let bulk_written = Arc::new(AtomicUsize::new(0));
        // ~250 MB/s: a 256 KiB chunk takes ~1 ms.
        let link = SlowLink { log: log.clone(), bulk_written: bulk_written.clone(), ns_per_byte: 4 };
        let s = Sender::with_writer(Box::new(link), None, Sealer::new(&[7u8; 32]));
        const CHUNKS: usize = 40;
        let bulk = {
            let s = s.clone();
            thread::spawn(move || {
                for i in 0..CHUNKS {
                    let m = ClientMsg::File(FileMsg::Chunk { id: 1, index: 0, offset: (i * FILE_CHUNK_MAX) as u64, data: vec![0xAB; FILE_CHUNK_MAX] });
                    s.send_bulk(&m).unwrap();
                }
            })
        };
        let mut worst = 0usize;
        let mut sent = 0;
        while !bulk.is_finished() || sent < 10 {
            thread::sleep(Duration::from_micros(700));
            let before = bulk_written.load(Ordering::SeqCst);
            s.send(&ClientMsg::Key { hid_usage: 0x04, down: sent % 2 == 0 }).unwrap();
            // The key record is in the log once send() returns: find how much bulk preceded it.
            let at = log.lock().unwrap().iter().rev().find(|e| !e.0).unwrap().1;
            worst = worst.max(at - before);
            sent += 1;
            assert!(sent < 100_000);
        }
        bulk.join().unwrap();
        let rec = FILE_CHUNK_MAX + 17 + 16 + 4; // payload + header + tag + length
        assert!(worst <= rec, "an input event waited behind {worst} bulk bytes (max one chunk = {rec})");
        assert_eq!(bulk_written.load(Ordering::SeqCst), CHUNKS * rec);
        // Interleaving actually happened (inputs were not all deferred to the end).
        let l = log.lock().unwrap();
        let first_bulk_after_input = l.iter().position(|e| !e.0).map(|i| l[i..].iter().any(|e| e.0));
        assert_eq!(first_bulk_after_input, Some(true));
    }

    #[test]
    fn bulk_yields_to_pending_urgent_sends() {
        // With an urgent sender registered, a bulk send must not start.
        let log = Arc::new(Mutex::new(Vec::new()));
        let link = SlowLink { log: log.clone(), bulk_written: Arc::new(AtomicUsize::new(0)), ns_per_byte: 0 };
        let s = Sender::with_writer(Box::new(link), None, Sealer::new(&[1u8; 32]));
        s.urgent.fetch_add(1, Ordering::SeqCst);
        let b = {
            let s = s.clone();
            thread::spawn(move || s.send_bulk(&ClientMsg::File(crate::protocol::FileMsg::Chunk { id: 1, index: 0, offset: 0, data: vec![0; 8192] })))
        };
        thread::sleep(Duration::from_millis(30));
        assert!(log.lock().unwrap().is_empty(), "bulk wrote while an urgent send was pending");
        s.urgent.fetch_sub(1, Ordering::SeqCst);
        b.join().unwrap().unwrap();
        assert_eq!(log.lock().unwrap().len(), 1);
        s.shutdown();
        assert!(s.send(&ClientMsg::ReleaseAll).is_err());
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
