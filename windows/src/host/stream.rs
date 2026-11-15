//! After authentication: decoding and validating viewer messages (docs/PROTOCOL.md §3) into
//! actions for the platform pipeline, the one-session-at-a-time slot, and the `--test-mode`
//! session (ServerHello + Pong only, no capture or input; runs on any OS).

use super::auth::Authed;
use crate::crypto::Sealer;
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
    /// Takes the slot for session `id`; returns its stop flag. Blocks (at most `wait`) until the
    /// previous holder called `leave`.
    pub fn enter(&self, id: u64, wait: Duration) -> Arc<AtomicBool> {
        let g = self.state.lock().unwrap();
        if let Some((old, stop)) = &g.current {
            super::log(&format!("session {id} replaces session {old}"));
            stop.store(true, Ordering::SeqCst);
        }
        let (mut g, _) = self.freed.wait_timeout_while(g, wait, |s| s.current.is_some()).unwrap();
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
    let mut buf = Vec::new();
    while !stop.load(Ordering::SeqCst) {
        let pt = match opener.read_record(&mut r, &mut buf) {
            Ok(pt) => pt,
            Err(crate::crypto::CryptoError::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                continue;
            }
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
}
