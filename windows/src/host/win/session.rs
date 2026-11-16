//! One streaming session on Windows, after `auth::accept`: ServerHello, then three threads —
//! the receiver (input → SendInput, Ping → Pong, ViewSize / RequestKeyframe / SetMode → video),
//! the cursor poller, and the video loop (this thread): Desktop Duplication → video processor
//! (scale + NV12) → MF encoder → VideoFrame. Frames are only sent when the screen changed (or a
//! keyframe was requested / a new configuration started), at most `max_fps` per second, one at a
//! time: the send blocks while the socket is full, so captures that pile up meanwhile collapse
//! into the latest one (latest frame wins).

use super::capture::{primary_output, Acquired, Device, Duplicator, Output};
use super::convert::Converter;
use super::cursor::{self, CursorShared};
use super::encoder::{self, EncodedFrame, Encoder};
use super::hr;
use super::inject::Injector;
use crate::handshake::fingerprint;
use crate::host::auth::Authed;
use crate::host::input::PxRect;
use crate::host::log;
use crate::host::stream::{dispatch, sender, Action};
use crate::host::trust::TrustStore;
use crate::host::video::{choose_codec, default_bitrate_kbps, encode_size, video_config};
use crate::net::Sender;
use crate::protocol::{Codec, HostMsg, VideoConfig, FRAME_FLAG_KEYFRAME, PROTOCOL_VERSION};
use crate::util::now_us;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub struct SessionOpts {
    pub host_name: String,
    /// Fixed bitrate (kbps) from the command line; None = automatic.
    pub bitrate_kbps: Option<u32>,
}

/// Requests from the receiver thread to the video loop.
struct Control {
    view_w: Mutex<Option<u32>>,
    keyframe: AtomicBool,
    reconfig: AtomicBool,
    /// kbps, 0 = automatic.
    bitrate: AtomicU32,
    fps: AtomicU32,
}

pub fn run(a: Authed, opts: &SessionOpts, trust: &TrustStore, stop: Arc<AtomicBool>) {
    unsafe {
        let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
    }
    let Authed { stream, sealer, opener, viewer_key, hello, conn_id: id, viewer_name, .. } = a;
    let tx = match sender(&stream, sealer) {
        Ok(t) => t,
        Err(e) => {
            log(&format!("session {id}: {e}"));
            return;
        }
    };
    let view_w = crate::host::video::clamp_view(hello.view_w, hello.view_h).map(|v| v.0);
    let hevc = hello.codec_caps & crate::protocol::CAP_HEVC_420 != 0 && encoder::available(Codec::Hevc);
    let codec = choose_codec(hello.codec_caps, hevc);
    let fps = if hello.max_fps == 0 { 60 } else { (hello.max_fps as u32).clamp(10, 144) };
    // ServerHello must go out within the viewer's pre-auth deadline, capture or not.
    let (rect, scale) = match primary_output() {
        Ok(o) => (o.rect, o.dpi_scale()),
        Err(e) => {
            log(&format!("session {id}: no output found ({}); announcing 1920x1080", hr(&e)));
            (PxRect { left: 0, top: 0, right: 1920, bottom: 1080 }, 1.0)
        }
    };
    let (ew, eh) = encode_size(rect.width() as u32, rect.height() as u32, view_w);
    let cfg = video_config(ew, eh, codec, scale);
    let hello_msg = HostMsg::ServerHello { version: PROTOCOL_VERSION, host_name: opts.host_name.clone(), config: cfg };
    if let Err(e) = tx.send_plaintext(&hello_msg.encode()) {
        log(&format!("session {id}: ServerHello failed: {e}"));
        return;
    }
    log(&format!(
        "session {id}: streaming to “{viewer_name}”: {} {}x{} (output {}x{}, DPI scale {scale}), up to {fps} fps",
        codec.name(),
        ew,
        eh,
        rect.width(),
        rect.height()
    ));
    let control = Arc::new(Control {
        view_w: Mutex::new(view_w),
        keyframe: AtomicBool::new(true),
        reconfig: AtomicBool::new(false),
        bitrate: AtomicU32::new(opts.bitrate_kbps.unwrap_or(0)),
        fps: AtomicU32::new(fps),
    });
    let injector = Arc::new(Mutex::new(Injector::new(rect)));
    let cursor_shared = Arc::new(CursorShared::new(rect));
    cursor_shared.scale_bits.store((ew as f32 / rect.width().max(1) as f32).min(1.0).to_bits(), Ordering::SeqCst);

    let receiver = {
        let (tx, stop, control, injector) = (tx.clone(), stop.clone(), control.clone(), injector.clone());
        let stream = match stream.try_clone() {
            Ok(s) => s,
            Err(e) => {
                log(&format!("session {id}: {e}"));
                return;
            }
        };
        thread::spawn(move || receive(id, stream, opener, tx, stop, control, injector))
    };
    let cursor_thread = {
        let (tx, shared, stop) = (tx.clone(), cursor_shared.clone(), stop.clone());
        thread::spawn(move || cursor::run(tx, shared, stop))
    };

    let mut v = Video { id, tx: tx.clone(), control: control.clone(), sent: cfg, codec, frame_id: 0, pipe: None, last_error: None };
    let mut last_trust_check = Instant::now();
    while !stop.load(Ordering::SeqCst) && !tx.is_closed() {
        if last_trust_check.elapsed() >= Duration::from_secs(2) {
            last_trust_check = Instant::now();
            if !trust.is_paired(&viewer_key) {
                log(&format!("session {id}: viewer {} was unpaired; ending the session", fingerprint(&viewer_key)));
                break;
            }
        }
        v.step(&injector, &cursor_shared);
    }
    stop.store(true, Ordering::SeqCst);
    tx.shutdown();
    let _ = receiver.join();
    let _ = cursor_thread.join();
    injector.lock().unwrap().release_all();
    log(&format!("session {id}: ended ({} frames sent)", v.frame_id));
}

fn receive(
    id: u64,
    stream: std::net::TcpStream,
    mut opener: crate::crypto::Opener,
    tx: Sender,
    stop: Arc<AtomicBool>,
    control: Arc<Control>,
    injector: Arc<Mutex<Injector>>,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut r = &stream;
    let mut reader = crate::host::stream::RecordReader::default();
    let mut ignored: HashSet<&'static str> = HashSet::new();
    let mut dropped = 0u32;
    while !stop.load(Ordering::SeqCst) {
        let pt = match reader.poll(&mut r, &mut opener) {
            Ok(Some(pt)) => pt,
            Ok(None) => continue, // read timeout: check the stop flag; framing progress is kept
            Err(e) => {
                if !stop.load(Ordering::SeqCst) {
                    log(&format!("session {id}: connection closed: {e}"));
                }
                break;
            }
        };
        match dispatch(&pt) {
            Ok(Action::Input(ev)) => injector.lock().unwrap().handle(&ev),
            Ok(Action::Pong { client_time_us }) => {
                let _ = tx.send_plaintext(&HostMsg::Pong { client_time_us, host_time_us: now_us() }.encode());
            }
            Ok(Action::ViewSize { w, h }) => {
                log(&format!("session {id}: viewer view size {w}x{h}"));
                *control.view_w.lock().unwrap() = Some(w);
                control.reconfig.store(true, Ordering::SeqCst);
            }
            Ok(Action::RequestKeyframe) => control.keyframe.store(true, Ordering::SeqCst),
            Ok(Action::SetMode { mode, bitrate_kbps, max_fps }) => {
                log(&format!("session {id}: SetMode mode {mode} (fast only), bitrate {bitrate_kbps} kbps, fps {max_fps}"));
                control.bitrate.store(if bitrate_kbps == 0 { 0 } else { bitrate_kbps.clamp(1_000, 200_000) }, Ordering::SeqCst);
                if max_fps > 0 {
                    control.fps.store((max_fps as u32).clamp(10, 144), Ordering::SeqCst);
                }
                control.reconfig.store(true, Ordering::SeqCst);
            }
            Ok(Action::Ignore(what)) => {
                if ignored.insert(what) {
                    log(&format!("session {id}: ignoring {what}"));
                }
            }
            Err(e) => {
                dropped += 1;
                if dropped <= 20 || dropped.is_power_of_two() {
                    log(&format!("session {id}: dropped a message ({e}; {dropped} so far)"));
                }
            }
        }
    }
    stop.store(true, Ordering::SeqCst);
}

/// Capture → convert → encode objects for the current output.
struct Pipe {
    out: Output,
    dev: Device,
    dup: Duplicator,
    conv: Option<Converter>,
    enc: Option<Encoder>,
    /// (w, h, codec, kbps, fps) the encoder was built for.
    enc_params: Option<(u32, u32, Codec, u32, u32)>,
    has_frame: bool,
    dirty: bool,
    frame_us: u64,
    /// Capture time of the frame last handed to the encoder (for output that comes out late).
    encoded_us: u64,
    next_due: Instant,
}

struct Video {
    id: u64,
    tx: Sender,
    control: Arc<Control>,
    /// The configuration the viewer was last told (ServerHello / VideoConfig).
    sent: VideoConfig,
    codec: Codec,
    frame_id: u32,
    pipe: Option<Pipe>,
    last_error: Option<String>,
}

impl Video {
    /// Logs `e` once until a different error (or success) happens.
    fn error(&mut self, e: String) {
        if self.last_error.as_deref() != Some(&e) {
            log(&format!("session {}: {e}", self.id));
            self.last_error = Some(e);
        }
    }

    fn step(&mut self, injector: &Mutex<Injector>, cursor: &CursorShared) {
        if self.pipe.is_none() {
            match build_pipe() {
                Ok(p) => {
                    log(&format!(
                        "session {}: capturing {} on {} ({}x{} at {},{})",
                        self.id,
                        p.out.device_name,
                        p.out.adapter_name,
                        p.out.rect.width(),
                        p.out.rect.height(),
                        p.out.rect.left,
                        p.out.rect.top
                    ));
                    injector.lock().unwrap().output = p.out.rect;
                    *cursor.output.lock().unwrap() = p.out.rect;
                    self.last_error = None;
                    self.pipe = Some(p);
                    self.control.reconfig.store(true, Ordering::SeqCst);
                    self.control.keyframe.store(true, Ordering::SeqCst);
                }
                Err(e) => {
                    self.error(format!(
                        "capture unavailable: {e} (the secure desktop — UAC prompt, lock or sign-in screen — can't be captured; retrying)"
                    ));
                    thread::sleep(Duration::from_millis(500));
                    return;
                }
            }
        }
        if self.control.reconfig.swap(false, Ordering::SeqCst) {
            if let Err(e) = self.configure(cursor) {
                self.error(format!("encoder setup failed: {e}; retrying"));
                self.pipe = None;
                thread::sleep(Duration::from_millis(1000));
                return;
            }
        }
        let fps = self.control.fps.load(Ordering::SeqCst).max(1);
        let p = self.pipe.as_mut().unwrap();
        let now = Instant::now();
        let wait = if p.dirty { p.next_due.saturating_duration_since(now) } else { Duration::from_millis(50) };
        match p.dup.acquire(wait.as_millis().clamp(1, 50) as u32) {
            Ok(Acquired::Updated) => {
                p.has_frame = true;
                p.dirty = true;
                p.frame_us = now_us();
            }
            Ok(Acquired::NoChange) => {}
            Err(e) => {
                log(&format!("session {}: capture lost ({}); re-creating it", self.id, hr(&e)));
                self.pipe = None;
                return;
            }
        }
        let keyframe = self.control.keyframe.load(Ordering::SeqCst);
        if !(p.has_frame && (p.dirty || keyframe) && Instant::now() >= p.next_due) {
            // Nothing new to encode: still collect a frame the encoder finished late, or the
            // viewer would keep the previous picture until the screen changes again.
            let late = match p.enc.as_mut().map(|e| e.poll()) {
                Some(Ok(f)) => f,
                Some(Err(e)) => {
                    log(&format!("session {}: encoder poll failed ({}); re-creating the encoder", self.id, hr(&e)));
                    p.enc = None;
                    p.enc_params = None;
                    self.control.reconfig.store(true, Ordering::SeqCst);
                    self.control.keyframe.store(true, Ordering::SeqCst);
                    return;
                }
                None => Vec::new(),
            };
            let capture_us = p.encoded_us;
            self.send_frames(late, capture_us);
            return;
        }
        let (Some(conv), Some(enc), Some(src)) = (p.conv.as_mut(), p.enc.as_mut(), p.dup.frame.clone()) else { return };
        p.encoded_us = p.frame_us;
        let r = conv.convert(&src).and_then(|nv12| enc.encode(&nv12, keyframe, p.frame_us));
        p.dirty = false;
        p.next_due = Instant::now() + Duration::from_micros(1_000_000 / fps as u64);
        let frames = match r {
            Ok(f) => f,
            Err(e) => {
                log(&format!("session {}: encode failed ({}); re-creating the encoder", self.id, hr(&e)));
                p.enc = None;
                p.enc_params = None;
                self.control.reconfig.store(true, Ordering::SeqCst);
                self.control.keyframe.store(true, Ordering::SeqCst);
                return;
            }
        };
        let capture_us = p.frame_us;
        self.send_frames(frames, capture_us);
    }

    /// Sends encoded access units as VideoFrames (`capture_us` = when their capture happened).
    fn send_frames(&mut self, frames: Vec<EncodedFrame>, capture_us: u64) {
        for f in frames {
            if f.keyframe {
                self.control.keyframe.store(false, Ordering::SeqCst);
            }
            self.frame_id = self.frame_id.wrapping_add(1);
            let m = HostMsg::VideoFrame {
                frame_id: self.frame_id,
                capture_time_us: capture_us,
                flags: if f.keyframe { FRAME_FLAG_KEYFRAME } else { 0 },
                rects: None,
                data: f.data,
            };
            if self.tx.send_plaintext(&m.encode()).is_err() {
                return;
            }
        }
    }

    /// (Re)builds converter + encoder for the current output, view size, bitrate and fps; tells
    /// the viewer (VideoConfig) when the encoded configuration changed.
    fn configure(&mut self, cursor: &CursorShared) -> Result<(), String> {
        let view_w = *self.control.view_w.lock().unwrap();
        let fps = self.control.fps.load(Ordering::SeqCst).max(1);
        let p = self.pipe.as_mut().unwrap();
        let (nw, nh) = (p.out.rect.width() as u32, p.out.rect.height() as u32);
        let (ew, eh) = encode_size(nw, nh, view_w);
        let mut codec = self.codec;
        let kbps = match self.control.bitrate.load(Ordering::SeqCst) {
            0 => default_bitrate_kbps(ew, eh, fps, codec),
            b => b,
        };
        if p.enc_params == Some((ew, eh, codec, kbps, fps)) && p.conv.is_some() {
            return Ok(());
        }
        p.enc = None;
        p.conv = Some(
            Converter::new(&p.dev.device, &p.dev.context, p.dup.tex_w, p.dup.tex_h, ew, eh, p.dup.rotation)
                .map_err(|e| format!("video processor: {}", hr(&e)))?,
        );
        let enc = match Encoder::new(&p.dev, codec, ew, eh, fps, kbps, Some(p.out.luid)) {
            Ok(e) => e,
            Err(e) if codec == Codec::Hevc => {
                log(&format!("session {}: no working HEVC encoder ({}); using H.264", self.id, hr(&e)));
                codec = Codec::H264;
                self.codec = codec;
                Encoder::new(&p.dev, codec, ew, eh, fps, kbps, Some(p.out.luid)).map_err(|e| hr(&e))?
            }
            Err(e) => return Err(hr(&e)),
        };
        p.enc = Some(enc);
        p.enc_params = Some((ew, eh, codec, kbps, fps));
        cursor.scale_bits.store((ew as f32 / nw.max(1) as f32).min(1.0).to_bits(), Ordering::SeqCst);
        let cfg = video_config(ew, eh, codec, p.out.dpi_scale());
        if cfg != self.sent {
            log(&format!("session {}: new video configuration {} {}x{}", self.id, codec.name(), ew, eh));
            if self.tx.send_plaintext(&HostMsg::VideoConfig(cfg).encode()).is_err() {
                return Ok(());
            }
            self.sent = cfg;
        }
        // A new encoder starts with a keyframe; make sure the first frame goes out soon.
        p.dirty = p.has_frame;
        self.control.keyframe.store(true, Ordering::SeqCst);
        Ok(())
    }
}

fn build_pipe() -> Result<Pipe, String> {
    let out = primary_output().map_err(|e| format!("no output: {}", hr(&e)))?;
    let dev = Device::new(&out.adapter).map_err(|e| format!("D3D11 device: {}", hr(&e)))?;
    let dup = Duplicator::new(&dev, &out).map_err(|e| format!("Desktop Duplication: {}", hr(&e)))?;
    Ok(Pipe { out, dev, dup, conv: None, enc: None, enc_params: None, has_frame: false, dirty: false, frame_us: 0, encoded_us: 0, next_due: Instant::now() })
}
