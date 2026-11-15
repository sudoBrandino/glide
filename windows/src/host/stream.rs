//! After authentication: decoding and validating viewer messages (docs/PROTOCOL.md §3) into
//! actions for the platform pipeline, the one-session-at-a-time slot, and the `--test-mode`
//! session (ServerHello + Pong only, no capture or input; runs on any OS).

use super::auth::Authed;
use crate::crypto::{CryptoError, Opener, Sealer, MAX_RECORD, MIN_RECORD};
use crate::net::Sender;
use crate::protocol::{ClientMsg, Codec, HostMsg, VideoConfig};
use std::io::Read;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// Input from the viewer, validated.
#[derive(Debug, Clone, PartialEq)]
pub enum InputEvent {
    /// Normalized, clamped to 0..=1.
    MouseMove {
        x: f32,
        y: f32,
    },
    MouseButton {
        button: u8,
        down: bool,
    },
    /// Notches, `dy > 0` = up, `dx > 0` = right.
    Wheel {
        dx: f32,
        dy: f32,
    },
    Key {
        usage: u16,
        down: bool,
    },
    ReleaseAll,
}

/// What the session should do with one viewer message.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    Input(InputEvent),
    /// Clamped view size (`video::clamp_view`).
    ViewSize {
        w: u32,
        h: u32,
    },
    RequestKeyframe,
    SetMode {
        mode: u8,
        bitrate_kbps: u32,
        max_fps: u8,
    },
    Pong {
        client_time_us: u64,
    },
    /// Valid but unused here (not negotiated or not implemented); logged at most once per type.
    Ignore(&'static str),
}

/// Decodes one plaintext from an authenticated viewer. Err = malformed or invalid input: the
/// host logs and drops it and the session continues (§3).
pub fn dispatch(pt: &[u8]) -> Result<Action, String> {
    let m = ClientMsg::decode(pt).map_err(|e| e.to_string())?;
    let finite = |v: f32, max: f32| v.is_finite() && v.abs() <= max;
    Ok(match m {
        ClientMsg::MouseMove { x, y } => {
            if !finite(x, 1000.0) || !finite(y, 1000.0) {
                return Err(format!("MouseMove out of range ({x}, {y})"));
            }
            Action::Input(InputEvent::MouseMove { x: x.clamp(0.0, 1.0), y: y.clamp(0.0, 1.0) })
        }
        ClientMsg::MouseWheel { dx, dy } => {
            if !finite(dx, 10000.0) || !finite(dy, 10000.0) {
                return Err(format!("MouseWheel out of range ({dx}, {dy})"));
            }
            Action::Input(InputEvent::Wheel { dx, dy })
        }
        ClientMsg::MouseButton { button, down } => {
            if button > super::input::MAX_BUTTON {
                return Err(format!("unknown mouse button {button}"));
            }
            Action::Input(InputEvent::MouseButton { button, down })
        }
        ClientMsg::Key { hid_usage, down } => Action::Input(InputEvent::Key { usage: hid_usage, down }),
        ClientMsg::ReleaseAll => Action::Input(InputEvent::ReleaseAll),
        ClientMsg::ViewSize { view_w, view_h } => match super::video::clamp_view(view_w, view_h) {
            Some((w, h)) => Action::ViewSize { w, h },
            None => return Err(format!("ViewSize {view_w}x{view_h}")),
        },
        ClientMsg::RequestKeyframe => Action::RequestKeyframe,
        ClientMsg::SetMode { mode, bitrate_kbps, max_fps } => Action::SetMode { mode, bitrate_kbps, max_fps },
        ClientMsg::Ping { client_time_us } => Action::Pong { client_time_us },
        ClientMsg::ClientHello { .. } => Action::Ignore("ClientHello (again)"),
        ClientMsg::PairConfirm { .. } => Action::Ignore("PairConfirm after auth"),
        ClientMsg::Clipboard(_) => Action::Ignore("Clipboard (not negotiated)"),
        ClientMsg::AudioEnable { .. } => Action::Ignore("AudioEnable"),
        ClientMsg::File(_) => Action::Ignore("file transfer (not negotiated)"),
        ClientMsg::LatencyEnable { .. } => Action::Ignore("LatencyEnable"),
        ClientMsg::LatencyReport(_) => Action::Ignore("LatencyReport"),
        ClientMsg::SetDisplayPreference { .. } => Action::Ignore("SetDisplayPreference"),
        ClientMsg::SelectDisplay { .. } => Action::Ignore("SelectDisplay (not negotiated)"),
        ClientMsg::Scroll { .. } | ClientMsg::MouseDelta { .. } | ClientMsg::LockState { .. } | ClientMsg::ConsumerKey { .. } => {
            Action::Ignore("input extension (no InputCaps sent)")
        }
    })
}

/// A shared, thread-safe writer for an authenticated session (record counter shared by video,
/// cursor and Pong).
pub fn sender(stream: &TcpStream, sealer: Sealer) -> std::io::Result<Sender> {
    stream.set_write_timeout(Some(crate::net::WRITE_TIMEOUT))?;
    let w = stream.try_clone()?;
    let closer = stream.try_clone()?;
    Ok(Sender::with_writer(Box::new(w), Some(closer), sealer))
}

/// Reads records from a socket that has a read timeout (so the caller can poll a stop flag)
/// without losing framing: bytes of a partly received length prefix or body are kept across
/// timeouts, and only complete records are decrypted.
#[derive(Default)]
pub struct RecordReader {
    buf: Vec<u8>,
    filled: usize,
}

impl RecordReader {
    /// The next record's plaintext; `Ok(None)` when the read timed out (state kept, call again).
    pub fn poll<R: Read>(&mut self, r: &mut R, opener: &mut Opener) -> Result<Option<Vec<u8>>, CryptoError> {
        loop {
            let want = if self.filled < 4 {
                4
            } else {
                let n = u32::from_le_bytes([self.buf[0], self.buf[1], self.buf[2], self.buf[3]]) as usize;
                if !(MIN_RECORD..=MAX_RECORD).contains(&n) {
                    return Err(CryptoError::BadRecordLength(n));
                }
                4 + n
            };
            if want > 4 && self.filled == want {
                self.filled = 0;
                let pt = opener.open(&self.buf[4..want]);
                if self.buf.len() > 1 << 20 {
                    self.buf = Vec::new(); // don't keep a huge buffer after one large record
                }
                return pt.map(Some);
            }
            if self.buf.len() < want {
                self.buf.resize(want, 0);
            }
            match r.read(&mut self.buf[self.filled..want]) {
                Ok(0) => return Err(CryptoError::Io(std::io::ErrorKind::UnexpectedEof.into())),
                Ok(k) => self.filled += k,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => return Ok(None),
                Err(e) => return Err(CryptoError::Io(e)),
            }
        }
    }
}

/// One streaming session at a time: a newly authenticated viewer replaces the current one
/// (like the Mac host). `enter` stops the previous session and waits until it has released
/// capture and input.
#[derive(Default)]
pub struct SessionSlot {
    state: Mutex<SlotState>,
    freed: Condvar,
}

#[derive(Default)]
struct SlotState {
    current: Option<(u64, Arc<AtomicBool>)>,
}

impl SessionSlot {
    /// Takes the slot for session `id`; returns its stop flag. Stops whoever holds the slot and
    /// waits (at most `wait` in all) until it called `leave`. Replacements are serialized: when
    /// several wait at once, each one that finds another (newer) holder stops that one too, so
    /// after a timeout the slot is only ever taken from a session whose stop flag is set.
    pub fn enter(&self, id: u64, wait: Duration) -> Arc<AtomicBool> {
        let deadline = std::time::Instant::now() + wait;
        let mut g = self.state.lock().unwrap();
        while let Some((old, stop)) = g.current.clone() {
            if !stop.swap(true, Ordering::SeqCst) {
                super::log(&format!("session {id} replaces session {old}"));
            }
            let now = std::time::Instant::now();
            if now >= deadline {
                super::log(&format!("session {old} didn't stop in time; session {id} takes over"));
                break;
            }
            g = self.freed.wait_timeout_while(g, deadline - now, |s| s.current.as_ref().is_some_and(|(c, _)| *c == old)).unwrap().0;
        }
        let stop = Arc::new(AtomicBool::new(false));
        g.current = Some((id, stop.clone()));
        stop
    }

    pub fn leave(&self, id: u64) {
        let mut g = self.state.lock().unwrap();
        if g.current.as_ref().is_some_and(|(c, _)| *c == id) {
            g.current = None;
            self.freed.notify_all();
        }
    }

    /// Stops the current session (if any) without taking the slot.
    pub fn stop_current(&self) {
        if let Some((_, s)) = &self.state.lock().unwrap().current {
            s.store(true, Ordering::SeqCst);
        }
    }
}

/// `--test-mode`: ServerHello with a placeholder config, then Pong for Ping until the viewer
/// leaves. Never captures the screen or injects input.
pub fn run_test_session(a: Authed, host_name: &str, stop: Arc<AtomicBool>) {
    let Authed { stream, sealer, mut opener, conn_id, .. } = a;
    let Ok(tx) = sender(&stream, sealer) else { return };
    let cfg = VideoConfig { width: 640, height: 360, codec: Codec::H264, chroma: 0, color: 0, scale: 1.0 };
    if tx
        .send_plaintext(&HostMsg::ServerHello { version: crate::protocol::PROTOCOL_VERSION, host_name: host_name.into(), config: cfg }.encode())
        .is_err()
    {
        return;
    }
    super::log(&format!("session {conn_id}: TEST MODE: sent ServerHello only"));
    let mut r = &stream;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut reader = RecordReader::default();
    while !stop.load(Ordering::SeqCst) {
        let pt = match reader.poll(&mut r, &mut opener) {
            Ok(Some(pt)) => pt,
            Ok(None) => continue,
            Err(e) => {
                super::log(&format!("session {conn_id}: closed: {e}"));
                break;
            }
        };
        match dispatch(&pt) {
            Ok(Action::Pong { client_time_us }) => {
                let _ = tx.send_plaintext(&HostMsg::Pong { client_time_us, host_time_us: crate::util::now_us() }.encode());
            }
            Ok(a) => super::log(&format!("session {conn_id}: TEST MODE: ignoring {a:?}")),
            Err(e) => super::log(&format!("session {conn_id}: dropped message: {e}")),
        }
    }
    tx.shutdown();
    let _ = (&stream).read(&mut [0u8; 1]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ClientMsg, FileMsg};
    use std::time::Instant;

    fn d(m: ClientMsg) -> Result<Action, String> {
        dispatch(&m.encode())
    }

    #[test]
    fn input_validation() {
        assert_eq!(d(ClientMsg::MouseMove { x: 0.5, y: 2.0 }), Ok(Action::Input(InputEvent::MouseMove { x: 0.5, y: 1.0 })));
        assert_eq!(d(ClientMsg::MouseMove { x: -999.0, y: 0.0 }), Ok(Action::Input(InputEvent::MouseMove { x: 0.0, y: 0.0 })));
        assert!(d(ClientMsg::MouseMove { x: f32::NAN, y: 0.0 }).is_err());
        assert!(d(ClientMsg::MouseMove { x: 0.0, y: f32::INFINITY }).is_err());
        assert!(d(ClientMsg::MouseMove { x: 1000.5, y: 0.0 }).is_err());
        assert_eq!(d(ClientMsg::MouseWheel { dx: 0.0, dy: -3.5 }), Ok(Action::Input(InputEvent::Wheel { dx: 0.0, dy: -3.5 })));
        assert!(d(ClientMsg::MouseWheel { dx: f32::NEG_INFINITY, dy: 0.0 }).is_err());
        assert!(d(ClientMsg::MouseWheel { dx: 0.0, dy: 10001.0 }).is_err());
        assert_eq!(d(ClientMsg::MouseButton { button: 4, down: true }), Ok(Action::Input(InputEvent::MouseButton { button: 4, down: true })));
        assert!(d(ClientMsg::MouseButton { button: 5, down: true }).is_err());
        assert_eq!(d(ClientMsg::Key { hid_usage: 0x04, down: false }), Ok(Action::Input(InputEvent::Key { usage: 0x04, down: false })));
        assert_eq!(d(ClientMsg::ReleaseAll), Ok(Action::Input(InputEvent::ReleaseAll)));
        assert_eq!(d(ClientMsg::ViewSize { view_w: 1920, view_h: 1080 }), Ok(Action::ViewSize { w: 1920, h: 1080 }));
        assert_eq!(d(ClientMsg::ViewSize { view_w: 1, view_h: 1 }), Ok(Action::ViewSize { w: 320, h: 200 }));
        assert!(d(ClientMsg::ViewSize { view_w: 0, view_h: 1080 }).is_err());
        assert_eq!(d(ClientMsg::RequestKeyframe), Ok(Action::RequestKeyframe));
        assert_eq!(
            d(ClientMsg::SetMode { mode: 0, bitrate_kbps: 5000, max_fps: 30 }),
            Ok(Action::SetMode { mode: 0, bitrate_kbps: 5000, max_fps: 30 })
        );
        assert_eq!(d(ClientMsg::Ping { client_time_us: 77 }), Ok(Action::Pong { client_time_us: 77 }));
        assert!(matches!(d(ClientMsg::File(FileMsg::Pull)), Ok(Action::Ignore(_))));
        assert!(matches!(d(ClientMsg::Scroll { flags: 1, dx: 0.0, dy: 1.0 }), Ok(Action::Ignore(_))));
        assert!(dispatch(&[]).is_err());
        assert!(dispatch(&[0xEE]).is_err(), "unknown type: dropped, not fatal");
        assert!(dispatch(&[0x10, 0, 0]).is_err(), "truncated");
    }

    /// Wire bytes of the messages this host decodes and encodes (§3 reference layouts).
    #[test]
    fn host_direction_wire_bytes() {
        use crate::util::hex;
        // MouseMove {0.25, 0.75} as in docs/test-vectors.json.
        assert_eq!(dispatch(&[0x10, 0, 0, 0x80, 0x3e, 0, 0, 0x40, 0x3f]), Ok(Action::Input(InputEvent::MouseMove { x: 0.25, y: 0.75 })));
        assert_eq!(dispatch(&[0x13, 0x04, 0x00, 0x01]), Ok(Action::Input(InputEvent::Key { usage: 4, down: true })));
        assert_eq!(dispatch(&[0x0a, 0x01]), Ok(Action::Ignore("PairConfirm after auth")));
        assert_eq!(hex(&HostMsg::AuthResult { code: 1 }.encode()), "0801");
        assert_eq!(hex(&HostMsg::Pong { client_time_us: 1, host_time_us: 2 }.encode()), "3101000000000000000200000000000000");
        assert_eq!(hex(&HostMsg::CursorPos { x: 0.5, y: 1.0, visible: true }.encode()), "410000003f0000803f01");
        assert_eq!(hex(&HostMsg::CursorShapeRef { shape_id: 7 }.encode()), "4307000000");
        assert_eq!(
            hex(&HostMsg::CursorShape { shape_id: 1, w: 1, h: 1, hot_x: 0, hot_y: 0, bgra: vec![1, 2, 3, 4] }.encode()),
            "4201000000010001000000000001020304"
        );
        let vf = HostMsg::VideoFrame { frame_id: 2, capture_time_us: 3, flags: 1, rects: None, data: vec![0, 0, 0, 1, 0x65] };
        assert_eq!(hex(&vf.encode()), "40020000000300000000000000010000000165");
    }

    #[test]
    fn slot_replaces_previous_session() {
        let slot = Arc::new(SessionSlot::default());
        let s1 = slot.enter(1, Duration::from_secs(5));
        let slot2 = slot.clone();
        let s1c = s1.clone();
        let h = std::thread::spawn(move || {
            while !s1c.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(5));
            }
            std::thread::sleep(Duration::from_millis(50));
            slot2.leave(1);
        });
        let t = Instant::now();
        let s2 = slot.enter(2, Duration::from_secs(5));
        assert!(s1.load(Ordering::SeqCst));
        assert!(!s2.load(Ordering::SeqCst));
        assert!(t.elapsed() >= Duration::from_millis(40));
        h.join().unwrap();
        slot.leave(1); // stale: no effect
        slot.stop_current();
        assert!(s2.load(Ordering::SeqCst));
        slot.leave(2);
        let s3 = slot.enter(3, Duration::from_millis(10));
        assert!(!s3.load(Ordering::SeqCst));
    }

    /// Two sessions replace the current one at the same time: the slot ends with exactly one
    /// live (not stopped) session, and it is the one holding the slot.
    #[test]
    fn concurrent_replacements_leave_one_live_session() {
        let slot = Arc::new(SessionSlot::default());
        // A session leaves the slot 50 ms after it is told to stop.
        let run = |slot: Arc<SessionSlot>, id: u64, stop: Arc<AtomicBool>| {
            std::thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(5));
                }
                std::thread::sleep(Duration::from_millis(50));
                slot.leave(id);
            })
        };
        let s1 = slot.enter(1, Duration::from_secs(1));
        let mut threads = vec![run(slot.clone(), 1, s1)];
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let entering: Vec<_> = [2u64, 3]
            .into_iter()
            .map(|id| {
                let (slot, barrier) = (slot.clone(), barrier.clone());
                std::thread::spawn(move || {
                    barrier.wait();
                    (id, slot.enter(id, Duration::from_millis(600)))
                })
            })
            .collect();
        let entered: Vec<(u64, Arc<AtomicBool>)> = entering.into_iter().map(|h| h.join().unwrap()).collect();
        let live: Vec<u64> = entered.iter().filter(|(_, s)| !s.load(Ordering::SeqCst)).map(|(id, _)| *id).collect();
        let current = slot.state.lock().unwrap().current.as_ref().map(|(id, _)| *id);
        assert_eq!(live.len(), 1, "live sessions {live:?}, slot holder {current:?}");
        assert_eq!(current, Some(live[0]));
        for (id, s) in entered {
            threads.push(run(slot.clone(), id, s));
        }
        slot.stop_current();
        for t in threads {
            t.join().unwrap();
        }
        assert!(slot.state.lock().unwrap().current.is_none());
    }

    /// A reader that returns the script's chunks in order (`Err` = that error kind).
    struct Script(std::collections::VecDeque<Result<Vec<u8>, std::io::ErrorKind>>);
    impl Read for Script {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            match self.0.pop_front() {
                None => Ok(0),
                Some(Err(k)) => Err(k.into()),
                Some(Ok(mut c)) => {
                    let n = c.len().min(out.len());
                    out[..n].copy_from_slice(&c[..n]);
                    if n < c.len() {
                        self.0.push_front(Ok(c.split_off(n)));
                    }
                    Ok(n)
                }
            }
        }
    }

    /// Read timeouts in the middle of a length prefix or a body don't lose framing.
    #[test]
    fn record_reader_keeps_framing_across_timeouts() {
        let key = crate::handshake::random32(); // any key: the test is about framing
        let mut sealer = Sealer::new(&key);
        let msgs: Vec<Vec<u8>> = vec![b"one".to_vec(), vec![0xAB; 3000], b"three".to_vec()];
        let wire: Vec<u8> = msgs.iter().flat_map(|m| sealer.seal(m)).collect();
        // 1–3 byte chunks with a timeout (and an EINTR) after every chunk.
        let mut script = std::collections::VecDeque::new();
        let mut i = 0;
        let mut n = 1;
        while i < wire.len() {
            let end = (i + n).min(wire.len());
            script.push_back(Ok(wire[i..end].to_vec()));
            script.push_back(Err(if n == 2 { std::io::ErrorKind::Interrupted } else { std::io::ErrorKind::TimedOut }));
            script.push_back(Err(std::io::ErrorKind::WouldBlock));
            i = end;
            n = n % 3 + 1;
        }
        let mut r = Script(script);
        let mut opener = Opener::new(&key);
        let mut reader = RecordReader::default();
        let mut got = Vec::new();
        let mut timeouts = 0;
        loop {
            match reader.poll(&mut r, &mut opener) {
                Ok(Some(pt)) => got.push(pt),
                Ok(None) => timeouts += 1,
                Err(CryptoError::Io(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => panic!("{e}"),
            }
        }
        assert_eq!(got, msgs);
        assert!(timeouts > 100);
        // A bad length prefix is an error, not a hang.
        let mut r = Script(vec![Ok(vec![1, 0]), Err(std::io::ErrorKind::TimedOut), Ok(vec![0, 0])].into());
        let mut reader = RecordReader::default();
        assert!(matches!(reader.poll(&mut r, &mut opener), Ok(None)));
        assert!(matches!(reader.poll(&mut r, &mut opener), Err(CryptoError::BadRecordLength(1))));
    }
}
