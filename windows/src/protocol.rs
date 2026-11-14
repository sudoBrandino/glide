//! Glide message encoding/decoding (docs/PROTOCOL.md §2.4 auth phase, §3). Platform independent.
//!
//! A message plaintext is `u8 message_type || payload`, all integers little-endian.

use std::fmt;

pub const PROTOCOL_VERSION: u16 = 2;
pub const DEFAULT_PORT: u16 = 7420;

// codec_caps bits
pub const CAP_HEVC_420: u32 = 1 << 0;
pub const CAP_HEVC_444: u32 = 1 << 1;
pub const CAP_H264_420: u32 = 1 << 2;
/// Bits 8+ are non-video features. Clipboard sync (§5).
pub const CAP_CLIPBOARD: u32 = 1 << 8;
/// Viewer plays PCM s16le audio (§3.2).
pub const CAP_AUDIO_PCM: u32 = 1 << 9;
/// Reserved: Opus audio.
pub const CAP_AUDIO_OPUS: u32 = 1 << 10;
/// File transfer in both directions (§6).
pub const CAP_FILES: u32 = 1 << 11;
/// Display selection: DisplayList / DisplayChanged / SelectDisplay (PROTOCOL.md §3.5).
pub const CAP_DISPLAYS: u32 = 1 << 13;
/// Input extensions (§3.6): the viewer understands InputCaps and sends Scroll/MouseDelta/KeyExtra.
pub const CAP_INPUT_EXT: u32 = 1 << 12;

// Client -> Host message types
pub const MSG_CLIENT_HELLO: u8 = 0x01;
pub const MSG_MOUSE_MOVE: u8 = 0x10;
pub const MSG_MOUSE_BUTTON: u8 = 0x11;
pub const MSG_MOUSE_WHEEL: u8 = 0x12;
pub const MSG_KEY: u8 = 0x13;
pub const MSG_RELEASE_ALL: u8 = 0x14;
pub const MSG_VIEW_SIZE: u8 = 0x15;
/// Viewer → host: Mac display-mode preference for this session (v1.3).
pub const MSG_SET_DISPLAY_PREFERENCE: u8 = 0x16;
/// Stream a given Mac display (§3.5).
pub const MSG_SELECT_DISPLAY: u8 = 0x1A;
/// Input extensions (§3.6), viewer → host; only after the host's InputCaps.
pub const MSG_SCROLL: u8 = 0x17;
pub const MSG_MOUSE_DELTA: u8 = 0x18;
pub const MSG_KEY_EXTRA: u8 = 0x19;
pub const MSG_REQUEST_KEYFRAME: u8 = 0x20;
pub const MSG_SET_MODE: u8 = 0x21;
pub const MSG_PING: u8 = 0x30;
pub const MSG_CLIPBOARD: u8 = 0x50;
pub const MSG_AUDIO_ENABLE: u8 = 0x62;
/// Pairing: the user confirmed (1) / rejected (0) the code (§2.4). 0x08–0x0F: auth phase.
pub const MSG_PAIR_CONFIRM: u8 = 0x0A;
/// Latency instrumentation (§3.4), client -> host.
pub const MSG_LATENCY_ENABLE: u8 = 0x80;
pub const MSG_LATENCY_REPORT: u8 = 0x82;

// Host -> Client message types
pub const MSG_SERVER_HELLO: u8 = 0x02;
pub const MSG_VIDEO_CONFIG: u8 = 0x03;
pub const MSG_SHARP_LAYER_CONFIG: u8 = 0x04;
/// Auth phase (§2.4): `u8 code` (AUTH_*).
pub const MSG_AUTH_RESULT: u8 = 0x08;
/// Pairing: the host's 32-byte pairing nonce (opens the commitment from msg2).
pub const MSG_PAIR_REVEAL: u8 = 0x09;

// AuthResult codes (§2.4)
pub const AUTH_OK: u8 = 0;
pub const AUTH_UNKNOWN_VIEWER: u8 = 1;
pub const AUTH_PAIRING_CLOSED: u8 = 2;
pub const AUTH_DECLINED: u8 = 3;
pub const AUTH_TIMEOUT: u8 = 4;
pub const AUTH_BUSY: u8 = 5;
/// Host → viewer: current display preference + mode (v1.3).
pub const MSG_DISPLAY_INFO: u8 = 0x05;
/// The Mac's displays (§3.5, caps bit 13).
pub const MSG_DISPLAY_LIST: u8 = 0x06;
/// The streamed display changed, or a SelectDisplay was answered (§3.5).
pub const MSG_DISPLAY_CHANGED: u8 = 0x07;
/// DisplayList entry flags.
pub const DISPLAY_FLAG_MAIN: u8 = 1 << 0;
pub const DISPLAY_FLAG_BUILTIN: u8 = 1 << 1;
pub const DISPLAY_FLAG_HIDPI: u8 = 1 << 2;
/// What SelectDisplay(0) streams.
pub const DISPLAY_FLAG_DEFAULT: u8 = 1 << 3;
/// DisplayChanged reasons.
pub const DISPLAY_REASON_SELECTED: u8 = 0;
pub const DISPLAY_REASON_UNAVAILABLE: u8 = 1;
pub const DISPLAY_REASON_FALLBACK: u8 = 2;
pub const DISPLAY_REASON_RESTORED: u8 = 3;
pub const DISPLAY_REASON_HOST: u8 = 4;
pub const DISPLAY_REASON_DEFAULT: u8 = 5;

/// Mac display-mode preferences (SetDisplayPreference / DisplayInfo `u8 preference`).
pub const DISPLAY_PREF_AUTOMATIC: u8 = 0;
pub const DISPLAY_PREF_CRISP: u8 = 1;
pub const DISPLAY_PREF_SMOOTH: u8 = 2;
pub const DISPLAY_PREF_RETINA: u8 = 3;
/// Never change the display mode ("Don't change").
pub const DISPLAY_PREF_MANUAL: u8 = 4;
pub const MSG_PONG: u8 = 0x31;
pub const MSG_VIDEO_FRAME: u8 = 0x40;
pub const MSG_CURSOR_POS: u8 = 0x41;
pub const MSG_CURSOR_SHAPE: u8 = 0x42;
pub const MSG_CURSOR_SHAPE_REF: u8 = 0x43;
/// Host → viewer (§3.6): `u32 flags` (INPUT_CAPS_*), only to viewers with CAP_INPUT_EXT.
pub const MSG_INPUT_CAPS: u8 = 0x44;
pub const MSG_CLIPBOARD_CAPS: u8 = 0x51;
/// Per-frame host pipeline timestamps (§3.4), host -> client.
pub const MSG_FRAME_TIMING: u8 = 0x81;

// Clipboard (§5)
pub const CLIP_FORMAT_TEXT: u8 = 1;
pub const CLIP_FORMAT_PNG: u8 = 2;
/// `ClipboardCaps.formats` bits.
pub const CLIP_CAPS_TEXT: u32 = 1 << 0;
pub const CLIP_CAPS_PNG: u32 = 1 << 1;
/// Max total item payload of one Clipboard message (CLIPBOARD_MAX).
pub const CLIPBOARD_MAX_BYTES: usize = 16 << 20;
pub const MSG_AUDIO_CONFIG: u8 = 0x60;
pub const MSG_AUDIO_FRAME: u8 = 0x61;

// File transfer (§6): 0x70-0x7F, both directions unless noted.
/// H→C only.
pub const MSG_FILE_CAPS: u8 = 0x70;
pub const MSG_FILE_OFFER: u8 = 0x71;
pub const MSG_FILE_ANSWER: u8 = 0x72;
pub const MSG_FILE_CHUNK: u8 = 0x73;
pub const MSG_FILE_END: u8 = 0x74;
pub const MSG_FILE_ACK: u8 = 0x75;
pub const MSG_FILE_CANCEL: u8 = 0x76;
pub const MSG_FILE_DONE: u8 = 0x77;
/// C→H only.
pub const MSG_FILE_PULL: u8 = 0x78;
/// H→C only.
pub const MSG_FILE_PULL_RESULT: u8 = 0x79;
/// Largest FileChunk payload.
pub const FILE_CHUNK_MAX: usize = 256 << 10;
/// A sender keeps at most this many chunk bytes unacknowledged (FileAck); protocol maximum.
pub const FILE_WINDOW: u64 = 1 << 20;
/// The window Glide's senders actually use: ≤ 512 KiB of file data sits ahead of an input event
/// or video frame anywhere in the pipe (~4 ms at 1 Gbit/s), still > the LAN bandwidth-delay product.
pub const FILE_SEND_WINDOW: u64 = 512 << 10;
/// FileCaps.flags: the host accepts files from the viewer.
pub const FILE_CAPS_RECEIVE: u32 = 1 << 0;
/// FileCaps.flags: the host can send files (menu, FilePull).
pub const FILE_CAPS_SEND: u32 = 1 << 1;
/// Host-chosen transfer ids have bit 31 set; viewer ids are 1..=0x7FFF_FFFF.
pub const FILE_HOST_ID_BIT: u32 = 0x8000_0000;

// AudioConfig codecs
pub const AUDIO_CODEC_OFF: u8 = 0;
pub const AUDIO_CODEC_PCM_S16: u8 = 1;
pub const AUDIO_CODEC_OPUS: u8 = 2;

// Input extensions (§3.6)
/// InputCaps flags: which messages the host accepts.
pub const INPUT_CAPS_SCROLL: u32 = 1 << 0;
pub const INPUT_CAPS_RELATIVE: u32 = 1 << 1;
pub const INPUT_CAPS_LOCKS: u32 = 1 << 2;
pub const INPUT_CAPS_CONSUMER: u32 = 1 << 3;
/// Scroll flags bit0: touchpad / high-resolution wheel.
pub const SCROLL_PRECISE: u8 = 1;
/// KeyExtra kinds.
pub const KEY_EXTRA_LOCKS: u8 = 0;
pub const KEY_EXTRA_CONSUMER: u8 = 1;
/// LockState bits.
pub const LOCK_CAPS: u8 = 1;
pub const LOCK_NUM: u8 = 2;
pub const LOCK_SCROLL: u8 = 4;

pub const MOUSE_LEFT: u8 = 0;
pub const MOUSE_RIGHT: u8 = 1;
pub const MOUSE_MIDDLE: u8 = 2;
pub const MOUSE_BACK: u8 = 3;
pub const MOUSE_FORWARD: u8 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Fast = 0,
    Sharp = 1,
    /// 4:2:0 base layer while changing + 4:4:4 refinement layer at rest (§3.1).
    Hybrid = 2,
}

impl Mode {
    pub fn from_u8(v: u8) -> Mode {
        match v {
            1 => Mode::Sharp,
            2 => Mode::Hybrid,
            _ => Mode::Fast,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Mode::Fast => "fast",
            Mode::Sharp => "sharp",
            Mode::Hybrid => "hybrid",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    Hevc,
    H264,
    Unknown(u8),
}

impl Codec {
    pub fn from_u8(v: u8) -> Codec {
        match v {
            1 => Codec::Hevc,
            2 => Codec::H264,
            x => Codec::Unknown(x),
        }
    }
    pub fn to_u8(self) -> u8 {
        match self {
            Codec::Hevc => 1,
            Codec::H264 => 2,
            Codec::Unknown(x) => x,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Codec::Hevc => "HEVC",
            Codec::H264 => "H.264",
            Codec::Unknown(_) => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoConfig {
    pub width: u16,
    pub height: u16,
    pub codec: Codec,
    /// 0 = 4:2:0, 1 = 4:4:4
    pub chroma: u8,
    /// 0 = BT.709 limited
    pub color: u8,
    pub scale: f32,
}

impl VideoConfig {
    pub fn chroma_name(&self) -> &'static str {
        if self.chroma == 1 { "4:4:4" } else { "4:2:0" }
    }
}

/// One clipboard snapshot (§5): `u32 seq`, `u8 count`, count × (`u8 format`, `u32 len`, bytes).
/// All present items are alternative representations of the same content.
#[derive(Clone, PartialEq, Default)]
pub struct ClipboardData {
    pub seq: u32,
    /// UTF-8 with LF line endings.
    pub text: Option<String>,
    /// A complete PNG file.
    pub png: Option<Vec<u8>>,
}

impl ClipboardData {
    pub fn is_empty(&self) -> bool {
        self.text.is_none() && self.png.is_none()
    }
    /// Sum of item payload lengths (what CLIPBOARD_MAX_BYTES applies to).
    pub fn payload_len(&self) -> usize {
        self.text.as_ref().map_or(0, |t| t.len()) + self.png.as_ref().map_or(0, |p| p.len())
    }
    /// Size/format summary for logs (never the content: it may be a password).
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        if let Some(t) = &self.text {
            parts.push(format!("text {} bytes", t.len()));
        }
        if let Some(p) = &self.png {
            parts.push(format!("png {} bytes", p.len()));
        }
        if parts.is_empty() {
            parts.push("empty".into());
        }
        format!("{} (seq {})", parts.join(" + "), self.seq)
    }
    fn write(&self, w: &mut Writer) {
        w.u32(self.seq).u8(self.text.is_some() as u8 + self.png.is_some() as u8);
        if let Some(t) = &self.text {
            w.u8(CLIP_FORMAT_TEXT).u32(t.len() as u32).bytes(t.as_bytes());
        }
        if let Some(p) = &self.png {
            w.u8(CLIP_FORMAT_PNG).u32(p.len() as u32).bytes(p);
        }
    }
    fn read(r: &mut Reader) -> Result<ClipboardData, DecodeError> {
        let mut c = ClipboardData { seq: r.u32()?, ..Default::default() };
        let n = r.u8()?;
        for _ in 0..n {
            let fmt = r.u8()?;
            let len = r.u32()? as usize;
            let b = r.take(len)?;
            match fmt {
                // Invalid UTF-8 is replaced, not fatal (§5).
                CLIP_FORMAT_TEXT if c.text.is_none() => c.text = Some(String::from_utf8_lossy(b).into_owned()),
                CLIP_FORMAT_PNG if c.png.is_none() => c.png = Some(b.to_vec()),
                _ => {} // unknown format or duplicate: skip
            }
        }
        Ok(c)
    }
}

impl fmt::Debug for ClipboardData {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ClipboardData({})", self.describe())
    }
}

/// `AudioConfig` (0x60, §3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioConfig {
    /// AUDIO_CODEC_* (0 = host has no audio).
    pub codec: u8,
    pub sample_rate: u32,
    pub channels: u8,
    /// Nominal samples per channel per AudioFrame (informational).
    pub frame_samples: u16,
}

/// One file of a FileOffer (§6). `path` is '/'-separated and relative; receivers sanitize it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    /// Modification time, ms since the Unix epoch (0 = unknown).
    pub mtime_ms: i64,
}

/// File-transfer messages (§6), carried by both `ClientMsg::File` and `HostMsg::File`.
#[derive(Clone, PartialEq, Eq)]
pub enum FileMsg {
    /// 0x70, H→C: `flags` = FILE_CAPS_* bits.
    Caps { flags: u32, max_total_bytes: u64, max_files: u32 },
    /// 0x71: `total_bytes` = sum of the sizes.
    Offer { id: u32, total_bytes: u64, files: Vec<FileEntry> },
    /// 0x72: `status` 0 = accepted, else a decline reason (`files::status`).
    Answer { id: u32, status: u8, detail: String },
    /// 0x73: 1..=FILE_CHUNK_MAX bytes of file `index` at `offset`.
    Chunk { id: u32, index: u32, offset: u64, data: Vec<u8> },
    /// 0x74: file `index` is complete; SHA-256 of its content.
    End { id: u32, index: u32, sha256: [u8; 32] },
    /// 0x75: receiver has written `bytes` bytes of this transfer so far (flow control).
    Ack { id: u32, bytes: u64 },
    /// 0x76: either side gives up on transfer `id`.
    Cancel { id: u32, reason: u8, detail: String },
    /// 0x77: receiver verified and saved all `files` files.
    Done { id: u32, files: u32 },
    /// 0x78, C→H: send the files on the Mac's pasteboard.
    Pull,
    /// 0x79, H→C: answer to Pull (0 = an offer follows).
    PullResult { status: u8, detail: String },
}

impl fmt::Debug for FileMsg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // Never dump chunk payloads into logs.
            FileMsg::Chunk { id, index, offset, data } => {
                write!(f, "Chunk {{ id: {id:#x}, index: {index}, offset: {offset}, len: {} }}", data.len())
            }
            FileMsg::Caps { flags, max_total_bytes, max_files } => {
                write!(f, "Caps {{ flags: {flags:#x}, max_total_bytes: {max_total_bytes}, max_files: {max_files} }}")
            }
            FileMsg::Offer { id, total_bytes, files } => write!(f, "Offer {{ id: {id:#x}, total_bytes: {total_bytes}, files: {files:?} }}"),
            FileMsg::Answer { id, status, detail } => write!(f, "Answer {{ id: {id:#x}, status: {status}, detail: {detail:?} }}"),
            FileMsg::End { id, index, .. } => write!(f, "End {{ id: {id:#x}, index: {index} }}"),
            FileMsg::Ack { id, bytes } => write!(f, "Ack {{ id: {id:#x}, bytes: {bytes} }}"),
            FileMsg::Cancel { id, reason, detail } => write!(f, "Cancel {{ id: {id:#x}, reason: {reason}, detail: {detail:?} }}"),
            FileMsg::Done { id, files } => write!(f, "Done {{ id: {id:#x}, files: {files} }}"),
            FileMsg::Pull => write!(f, "Pull"),
            FileMsg::PullResult { status, detail } => write!(f, "PullResult {{ status: {status}, detail: {detail:?} }}"),
        }
    }
}

impl FileMsg {
    pub fn is_file_type(t: u8) -> bool {
        (MSG_FILE_CAPS..=MSG_FILE_PULL_RESULT).contains(&t)
    }

    pub fn encode(&self) -> Vec<u8> {
        match self {
            FileMsg::Caps { flags, max_total_bytes, max_files } => {
                Writer::new(MSG_FILE_CAPS).u32(*flags).u64(*max_total_bytes).u32(*max_files).finish()
            }
            FileMsg::Offer { id, total_bytes, files } => {
                let mut w = Writer::new(MSG_FILE_OFFER);
                w.u32(*id).u64(*total_bytes).u32(files.len() as u32);
                for f in files {
                    w.str(&f.path).u64(f.size).u64(f.mtime_ms as u64);
                }
                w.finish()
            }
            FileMsg::Answer { id, status, detail } => Writer::new(MSG_FILE_ANSWER).u32(*id).u8(*status).str(detail).finish(),
            FileMsg::Chunk { id, index, offset, data } => {
                let mut w = Writer::new(MSG_FILE_CHUNK);
                w.buf.reserve(data.len() + 16);
                w.u32(*id).u32(*index).u64(*offset).bytes(data).finish()
            }
            FileMsg::End { id, index, sha256 } => Writer::new(MSG_FILE_END).u32(*id).u32(*index).bytes(sha256).finish(),
            FileMsg::Ack { id, bytes } => Writer::new(MSG_FILE_ACK).u32(*id).u64(*bytes).finish(),
            FileMsg::Cancel { id, reason, detail } => Writer::new(MSG_FILE_CANCEL).u32(*id).u8(*reason).str(detail).finish(),
            FileMsg::Done { id, files } => Writer::new(MSG_FILE_DONE).u32(*id).u32(*files).finish(),
            FileMsg::Pull => vec![MSG_FILE_PULL],
            FileMsg::PullResult { status, detail } => Writer::new(MSG_FILE_PULL_RESULT).u8(*status).str(detail).finish(),
        }
    }

    /// Decode a file message (type byte `t` already read). Strings are decoded lossily: a bad
    /// name must not be a fatal protocol error (receivers sanitize/refuse it instead).
    fn read(t: u8, r: &mut Reader) -> Result<FileMsg, DecodeError> {
        Ok(match t {
            MSG_FILE_CAPS => FileMsg::Caps { flags: r.u32()?, max_total_bytes: r.u64()?, max_files: r.u32()? },
            MSG_FILE_OFFER => {
                let id = r.u32()?;
                let total_bytes = r.u64()?;
                let n = r.u32()? as usize;
                // Each entry is at least 18 bytes: don't trust `n` for the allocation.
                if n > r.remaining() / 18 {
                    return Err(DecodeError::BadLength(t));
                }
                let mut files = Vec::with_capacity(n);
                for _ in 0..n {
                    let path = r.str_lossy()?;
                    files.push(FileEntry { path, size: r.u64()?, mtime_ms: r.u64()? as i64 });
                }
                FileMsg::Offer { id, total_bytes, files }
            }
            MSG_FILE_ANSWER => FileMsg::Answer { id: r.u32()?, status: r.u8()?, detail: r.str_lossy()? },
            MSG_FILE_CHUNK => FileMsg::Chunk { id: r.u32()?, index: r.u32()?, offset: r.u64()?, data: r.rest().to_vec() },
            MSG_FILE_END => {
                let id = r.u32()?;
                let index = r.u32()?;
                let sha256: [u8; 32] = r.take(32)?.try_into().unwrap();
                FileMsg::End { id, index, sha256 }
            }
            MSG_FILE_ACK => FileMsg::Ack { id: r.u32()?, bytes: r.u64()? },
            MSG_FILE_CANCEL => FileMsg::Cancel { id: r.u32()?, reason: r.u8()?, detail: r.str_lossy()? },
            MSG_FILE_DONE => FileMsg::Done { id: r.u32()?, files: r.u32()? },
            MSG_FILE_PULL => FileMsg::Pull,
            MSG_FILE_PULL_RESULT => FileMsg::PullResult { status: r.u8()?, detail: r.str_lossy()? },
            _ => return Err(DecodeError::BadLength(t)),
        })
    }
}

/// "Unknown" marker for `FrameTiming` / `LatencyReport` fields.
pub const TIMING_UNKNOWN: u32 = u32::MAX;

/// `FrameTiming` (0x81, §3.4): host-side timestamps of one `VideoFrame`, as µs offsets after
/// `capture_us` (host monotonic clock); `TIMING_UNKNOWN` = not measured.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FrameTiming {
    pub frame_id: u32,
    /// Same as the frame's `capture_time_us` (ScreenCaptureKit PTS).
    pub capture_us: u64,
    /// The frame's `VideoFrame` flags.
    pub flags: u8,
    /// Capture callback ran on the host.
    pub callback: u32,
    /// Handed to the encoder.
    pub submit: u32,
    /// Encoder output callback.
    pub encoded: u32,
    /// Queued on the connection (record sealed, `send` called).
    pub enqueued: u32,
    /// The network stack accepted the whole record (send completion).
    pub sent: u32,
}

impl FrameTiming {
    /// Absolute host time of a stage offset, if known.
    pub fn at(&self, d: u32) -> Option<u64> {
        // Host-supplied: an absurd capture time is "unknown", not an overflow.
        (d != TIMING_UNKNOWN).then(|| self.capture_us.checked_add(d as u64)).flatten()
    }
}

/// `LatencyReport` (0x82, §3.4): the viewer's p50 breakdown over its last window, in µs
/// (`TIMING_UNKNOWN` = not measured). Informational: the host logs it and shows the total.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LatencyReport {
    pub samples: u16,
    /// bit0: `total_us` ends at scan-out (else at the Present call); bit1: ground truth valid.
    pub flags: u8,
    pub host_us: u32,
    pub network_us: u32,
    pub queue_us: u32,
    pub decode_us: u32,
    pub render_us: u32,
    pub scanout_us: u32,
    pub total_us: u32,
    /// Glass-to-glass ground truth from the test pattern (latency test mode).
    pub ground_truth_us: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ClientMsg {
    ClientHello {
        version: u16,
        codec_caps: u32,
        view_w: u16,
        view_h: u16,
        mode: u8,
        max_fps: u8,
        client_name: String,
    },
    MouseMove { x: f32, y: f32 },
    MouseButton { button: u8, down: bool },
    MouseWheel { dx: f32, dy: f32 },
    Key { hid_usage: u16, down: bool },
    ReleaseAll,
    /// Physical pixel size of the monitor the viewer presents on (sent when it changes).
    ViewSize { view_w: u16, view_h: u16 },
    RequestKeyframe,
    SetMode { mode: u8, bitrate_kbps: u32, max_fps: u8 },
    Ping { client_time_us: u64 },
    Clipboard(ClipboardData),
    /// Start (true) / stop (false, muted) audio.
    AudioEnable { enabled: bool },
    /// Pairing: the user compared the codes (§2.4).
    PairConfirm { matched: bool },
    /// File transfer (§6).
    File(FileMsg),
    /// Ask the host for `FrameTiming` messages (§3.4). `flags` bit0 = enabled.
    LatencyEnable { flags: u8 },
    LatencyReport(LatencyReport),
    /// Mac display-mode preference for this session (`DISPLAY_PREF_*`).
    SetDisplayPreference { mode: u8 },
    /// Stream Mac display `display_id` (0 = the host's default), §3.5.
    SelectDisplay { display_id: u32 },
    /// §3.6: scroll in notches (like MouseWheel) with its source (`SCROLL_PRECISE`).
    Scroll { flags: u8, dx: f32, dy: f32 },
    /// §3.6: relative motion in device counts (pointer-lock mode).
    MouseDelta { dx: i16, dy: i16 },
    /// §3.6 KeyExtra kind 0: lock-key state (`LOCK_*` bits).
    LockState { locks: u8 },
    /// §3.6 KeyExtra kind 1: HID Consumer page usage (media keys).
    ConsumerKey { usage: u16, down: bool },
}

/// One Mac display from DisplayList (§3.5). `id` is volatile (this connection only).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MacDisplay {
    pub id: u32,
    pub flags: u8,
    /// Top-left in global points (main display at 0,0; y grows downwards).
    pub x: i32,
    pub y: i32,
    /// Current mode in points and backing pixels.
    pub width: u16,
    pub height: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
    /// 1/100 Hz, 0 = unknown.
    pub refresh: u16,
    pub vendor: u32,
    pub model: u32,
    pub serial: u32,
    pub name: String,
}

impl MacDisplay {
    fn write(&self, w: &mut Writer) {
        w.u32(self.id).u8(self.flags).u32(self.x as u32).u32(self.y as u32);
        w.u16(self.width).u16(self.height).u16(self.pixel_width).u16(self.pixel_height).u16(self.refresh);
        w.u32(self.vendor).u32(self.model).u32(self.serial).str(&self.name);
    }
    fn read(r: &mut Reader) -> Result<MacDisplay, DecodeError> {
        Ok(MacDisplay {
            id: r.u32()?,
            flags: r.u8()?,
            x: r.u32()? as i32,
            y: r.u32()? as i32,
            width: r.u16()?,
            height: r.u16()?,
            pixel_width: r.u16()?,
            pixel_height: r.u16()?,
            refresh: r.u16()?,
            vendor: r.u32()?,
            model: r.u32()?,
            serial: r.u32()?,
            name: r.str_lossy()?,
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum HostMsg {
    /// Auth phase result (§2.4); nonzero = rejected, the host closes the connection.
    AuthResult { code: u8 },
    /// Pairing: the host's nonce n_h (§2.4).
    PairReveal { nonce: [u8; 32] },
    ServerHello { version: u16, host_name: String, config: VideoConfig },
    VideoConfig(VideoConfig),
    Pong { client_time_us: u64, host_time_us: u64 },
    /// Refinement-layer configuration (hybrid mode).
    SharpLayerConfig(VideoConfig),
    /// `rects` is `Some` iff flags bit3 is set; `data` is the Annex-B payload only.
    VideoFrame { frame_id: u32, capture_time_us: u64, flags: u8, rects: Option<Vec<Rect>>, data: Vec<u8> },
    CursorPos { x: f32, y: f32, visible: bool },
    CursorShape { shape_id: u32, w: u16, h: u16, hot_x: u16, hot_y: u16, bgra: Vec<u8> },
    CursorShapeRef { shape_id: u32 },
    Clipboard(ClipboardData),
    /// Host accepts clipboard sync (§5): `formats` = CLIP_CAPS_* bits, `max_bytes` payload limit.
    ClipboardCaps { formats: u32, max_bytes: u32 },
    AudioConfig(AudioConfig),
    /// `data`: interleaved s16le PCM (codec 1); `capture_time_us` is the first sample's host time.
    AudioFrame { seq: u32, capture_time_us: u64, data: Vec<u8> },
    /// File transfer (§6).
    File(FileMsg),
    FrameTiming(FrameTiming),
    /// Current Mac display preference (`DISPLAY_PREF_*`) and mode ("looks like" size in points,
    /// `hidpi` = Retina backing). Sent after ServerHello and whenever either changes.
    DisplayInfo { preference: u8, mode_w: u16, mode_h: u16, hidpi: bool },
    /// The Mac's displays in list order (§3.5); `selected` 0 = following the host's default.
    DisplayList { streamed: u32, selected: u32, displays: Vec<MacDisplay> },
    /// `reason` = `DISPLAY_REASON_*`.
    DisplayChanged { display_id: u32, reason: u8, requested: u32 },
    /// §3.6: the input-extension messages this host accepts (`INPUT_CAPS_*`).
    InputCaps { flags: u32 },
    /// Unknown message type: ignored for forward compatibility.
    Unknown { msg_type: u8 },
}

pub const FRAME_FLAG_KEYFRAME: u8 = 1;
/// Re-encode of unchanged content for quality; capture_time_us is the original capture.
pub const FRAME_FLAG_REFRESH: u8 = 2;
/// Sharp (refinement) layer: decode with the second decoder; standalone 4:4:4 IDR.
pub const FRAME_FLAG_SHARP: u8 = 4;
/// Payload starts with `u16 n` + n × (u16 x, y, w, h) update rectangles.
pub const FRAME_FLAG_RECTS: u8 = 8;

/// Update rectangle in encoded pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

impl Rect {
    /// Clamp to a `fw x fh` frame; None if empty afterwards.
    pub fn clamped(self, fw: u32, fh: u32) -> Option<(u32, u32, u32, u32)> {
        let x0 = (self.x as u32).min(fw);
        let y0 = (self.y as u32).min(fh);
        let x1 = (self.x as u32 + self.w as u32).min(fw);
        let y1 = (self.y as u32 + self.h as u32).min(fh);
        (x1 > x0 && y1 > y0).then_some((x0, y0, x1 - x0, y1 - y0))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    Empty,
    Truncated(u8),
    BadUtf8,
    BadLength(u8),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::Empty => write!(f, "empty message"),
            DecodeError::Truncated(t) => write!(f, "truncated message type 0x{t:02x}"),
            DecodeError::BadUtf8 => write!(f, "invalid UTF-8 string"),
            DecodeError::BadLength(t) => write!(f, "bad length for message type 0x{t:02x}"),
        }
    }
}

impl std::error::Error for DecodeError {}

// ---------------------------------------------------------------- writer

#[derive(Default)]
pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn new(msg_type: u8) -> Writer {
        Writer { buf: vec![msg_type] }
    }
    pub fn u8(&mut self, v: u8) -> &mut Self {
        self.buf.push(v);
        self
    }
    pub fn u16(&mut self, v: u16) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn f32(&mut self, v: f32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn str(&mut self, s: &str) -> &mut Self {
        let b = s.as_bytes();
        let n = b.len().min(u16::MAX as usize);
        self.u16(n as u16);
        self.buf.extend_from_slice(&b[..n]);
        self
    }
    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(b);
        self
    }
    pub fn finish(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.buf)
    }
}

// ---------------------------------------------------------------- reader

pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
    t: u8,
}

impl<'a> Reader<'a> {
    pub fn new(t: u8, data: &'a [u8]) -> Self {
        Reader { data, pos: 0, t }
    }
    pub fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        if self.data.len() - self.pos < n {
            return Err(DecodeError::Truncated(self.t));
        }
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    pub fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }
    pub fn u16(&mut self) -> Result<u16, DecodeError> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    pub fn u32(&mut self) -> Result<u32, DecodeError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    pub fn u64(&mut self) -> Result<u64, DecodeError> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    pub fn f32(&mut self) -> Result<f32, DecodeError> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    pub fn str(&mut self) -> Result<String, DecodeError> {
        let n = self.u16()? as usize;
        let b = self.take(n)?;
        String::from_utf8(b.to_vec()).map_err(|_| DecodeError::BadUtf8)
    }
    /// `str` with invalid UTF-8 replaced (U+FFFD) instead of failing.
    pub fn str_lossy(&mut self) -> Result<String, DecodeError> {
        let n = self.u16()? as usize;
        Ok(String::from_utf8_lossy(self.take(n)?).into_owned())
    }
    pub fn remaining(&self) -> usize {
        self.data.len() - self.pos
    }
    pub fn rest(&mut self) -> &'a [u8] {
        let s = &self.data[self.pos..];
        self.pos = self.data.len();
        s
    }
    pub fn pos(&self) -> usize {
        self.pos
    }
}

fn read_video_config(r: &mut Reader) -> Result<VideoConfig, DecodeError> {
    Ok(VideoConfig {
        width: r.u16()?,
        height: r.u16()?,
        codec: Codec::from_u8(r.u8()?),
        chroma: r.u8()?,
        color: r.u8()?,
        scale: r.f32()?,
    })
}

fn write_video_config(w: &mut Writer, c: &VideoConfig) {
    w.u16(c.width).u16(c.height).u8(c.codec.to_u8()).u8(c.chroma).u8(c.color).f32(c.scale);
}

impl ClientMsg {
    pub fn encode(&self) -> Vec<u8> {
        match self {
            ClientMsg::ClientHello { version, codec_caps, view_w, view_h, mode, max_fps, client_name } => Writer::new(MSG_CLIENT_HELLO)
                .u16(*version)
                .u32(*codec_caps)
                .u16(*view_w)
                .u16(*view_h)
                .u8(*mode)
                .u8(*max_fps)
                .str(client_name)
                .finish(),
            ClientMsg::MouseMove { x, y } => Writer::new(MSG_MOUSE_MOVE).f32(*x).f32(*y).finish(),
            ClientMsg::MouseButton { button, down } => Writer::new(MSG_MOUSE_BUTTON).u8(*button).u8(*down as u8).finish(),
            ClientMsg::MouseWheel { dx, dy } => Writer::new(MSG_MOUSE_WHEEL).f32(*dx).f32(*dy).finish(),
            ClientMsg::Key { hid_usage, down } => Writer::new(MSG_KEY).u16(*hid_usage).u8(*down as u8).finish(),
            ClientMsg::ReleaseAll => vec![MSG_RELEASE_ALL],
            ClientMsg::ViewSize { view_w, view_h } => Writer::new(MSG_VIEW_SIZE).u16(*view_w).u16(*view_h).finish(),
            ClientMsg::RequestKeyframe => vec![MSG_REQUEST_KEYFRAME],
            ClientMsg::SetMode { mode, bitrate_kbps, max_fps } => Writer::new(MSG_SET_MODE).u8(*mode).u32(*bitrate_kbps).u8(*max_fps).finish(),
            ClientMsg::Ping { client_time_us } => Writer::new(MSG_PING).u64(*client_time_us).finish(),
            ClientMsg::Clipboard(c) => {
                let mut w = Writer::new(MSG_CLIPBOARD);
                w.buf.reserve(c.payload_len() + 16);
                c.write(&mut w);
                w.finish()
            }
            ClientMsg::AudioEnable { enabled } => Writer::new(MSG_AUDIO_ENABLE).u8(*enabled as u8).finish(),
            ClientMsg::PairConfirm { matched } => Writer::new(MSG_PAIR_CONFIRM).u8(*matched as u8).finish(),
            ClientMsg::File(m) => m.encode(),
            ClientMsg::LatencyEnable { flags } => Writer::new(MSG_LATENCY_ENABLE).u8(*flags).finish(),
            ClientMsg::LatencyReport(r) => Writer::new(MSG_LATENCY_REPORT)
                .u16(r.samples)
                .u8(r.flags)
                .u32(r.host_us)
                .u32(r.network_us)
                .u32(r.queue_us)
                .u32(r.decode_us)
                .u32(r.render_us)
                .u32(r.scanout_us)
                .u32(r.total_us)
                .u32(r.ground_truth_us)
                .finish(),
            ClientMsg::SetDisplayPreference { mode } => Writer::new(MSG_SET_DISPLAY_PREFERENCE).u8(*mode).finish(),
            ClientMsg::SelectDisplay { display_id } => Writer::new(MSG_SELECT_DISPLAY).u32(*display_id).finish(),
            ClientMsg::Scroll { flags, dx, dy } => Writer::new(MSG_SCROLL).u8(*flags).f32(*dx).f32(*dy).finish(),
            ClientMsg::MouseDelta { dx, dy } => Writer::new(MSG_MOUSE_DELTA).u16(*dx as u16).u16(*dy as u16).finish(),
            ClientMsg::LockState { locks } => Writer::new(MSG_KEY_EXTRA).u8(KEY_EXTRA_LOCKS).u8(*locks).finish(),
            ClientMsg::ConsumerKey { usage, down } => Writer::new(MSG_KEY_EXTRA).u8(KEY_EXTRA_CONSUMER).u16(*usage).u8(*down as u8).finish(),
        }
    }

    /// Decode (used by tests / tooling; the host is the real consumer).
    pub fn decode(buf: &[u8]) -> Result<ClientMsg, DecodeError> {
        let (&t, body) = buf.split_first().ok_or(DecodeError::Empty)?;
        let mut r = Reader::new(t, body);
        Ok(match t {
            MSG_CLIENT_HELLO => ClientMsg::ClientHello {
                version: r.u16()?,
                codec_caps: r.u32()?,
                view_w: r.u16()?,
                view_h: r.u16()?,
                mode: r.u8()?,
                max_fps: r.u8()?,
                client_name: r.str()?,
            },
            MSG_MOUSE_MOVE => ClientMsg::MouseMove { x: r.f32()?, y: r.f32()? },
            MSG_MOUSE_BUTTON => ClientMsg::MouseButton { button: r.u8()?, down: r.u8()? != 0 },
            MSG_MOUSE_WHEEL => ClientMsg::MouseWheel { dx: r.f32()?, dy: r.f32()? },
            MSG_KEY => ClientMsg::Key { hid_usage: r.u16()?, down: r.u8()? != 0 },
            MSG_RELEASE_ALL => ClientMsg::ReleaseAll,
            MSG_VIEW_SIZE => ClientMsg::ViewSize { view_w: r.u16()?, view_h: r.u16()? },
            MSG_REQUEST_KEYFRAME => ClientMsg::RequestKeyframe,
            MSG_SET_MODE => ClientMsg::SetMode { mode: r.u8()?, bitrate_kbps: r.u32()?, max_fps: r.u8()? },
            MSG_PING => ClientMsg::Ping { client_time_us: r.u64()? },
            MSG_CLIPBOARD => ClientMsg::Clipboard(ClipboardData::read(&mut r)?),
            MSG_AUDIO_ENABLE => ClientMsg::AudioEnable { enabled: r.u8()? != 0 },
            MSG_PAIR_CONFIRM => ClientMsg::PairConfirm { matched: r.u8()? != 0 },
            t if FileMsg::is_file_type(t) => ClientMsg::File(FileMsg::read(t, &mut r)?),
            MSG_LATENCY_ENABLE => ClientMsg::LatencyEnable { flags: r.u8()? },
            MSG_LATENCY_REPORT => ClientMsg::LatencyReport(LatencyReport {
                samples: r.u16()?,
                flags: r.u8()?,
                host_us: r.u32()?,
                network_us: r.u32()?,
                queue_us: r.u32()?,
                decode_us: r.u32()?,
                render_us: r.u32()?,
                scanout_us: r.u32()?,
                total_us: r.u32()?,
                ground_truth_us: r.u32()?,
            }),
            MSG_SET_DISPLAY_PREFERENCE => ClientMsg::SetDisplayPreference { mode: r.u8()? },
            MSG_SELECT_DISPLAY => ClientMsg::SelectDisplay { display_id: r.u32()? },
            MSG_SCROLL => ClientMsg::Scroll { flags: r.u8()?, dx: r.f32()?, dy: r.f32()? },
            MSG_MOUSE_DELTA => ClientMsg::MouseDelta { dx: r.u16()? as i16, dy: r.u16()? as i16 },
            MSG_KEY_EXTRA => match r.u8()? {
                KEY_EXTRA_LOCKS => ClientMsg::LockState { locks: r.u8()? },
                KEY_EXTRA_CONSUMER => ClientMsg::ConsumerKey { usage: r.u16()?, down: r.u8()? != 0 },
                _ => return Err(DecodeError::BadLength(t)), // unknown kind: a host ignores it
            },
            _ => return Err(DecodeError::BadLength(t)),
        })
    }
}

impl HostMsg {
    /// Decode a host->client plaintext (type byte + payload). Takes ownership so
    /// the (large) video payload can be split off without re-parsing.
    pub fn decode(mut buf: Vec<u8>) -> Result<HostMsg, DecodeError> {
        let t = *buf.first().ok_or(DecodeError::Empty)?;
        let mut r = Reader::new(t, &buf[1..]);
        let msg = match t {
            MSG_AUTH_RESULT => HostMsg::AuthResult { code: r.u8()? },
            MSG_PAIR_REVEAL => {
                let rest = r.rest();
                if rest.len() < 32 {
                    return Err(DecodeError::BadLength(t));
                }
                HostMsg::PairReveal { nonce: rest[..32].try_into().unwrap() }
            }
            MSG_SERVER_HELLO => {
                let version = r.u16()?;
                let host_name = r.str()?;
                let config = read_video_config(&mut r)?;
                HostMsg::ServerHello { version, host_name, config }
            }
            MSG_VIDEO_CONFIG => HostMsg::VideoConfig(read_video_config(&mut r)?),
            MSG_SHARP_LAYER_CONFIG => HostMsg::SharpLayerConfig(read_video_config(&mut r)?),
            MSG_PONG => HostMsg::Pong { client_time_us: r.u64()?, host_time_us: r.u64()? },
            MSG_VIDEO_FRAME => {
                let frame_id = r.u32()?;
                let capture_time_us = r.u64()?;
                let flags = r.u8()?;
                let rects = if flags & FRAME_FLAG_RECTS != 0 {
                    let n = r.u16()? as usize;
                    let mut v = Vec::with_capacity(n.min(r.remaining() / 8)); // don't trust n for the allocation
                    for _ in 0..n {
                        v.push(Rect { x: r.u16()?, y: r.u16()?, w: r.u16()?, h: r.u16()? });
                    }
                    Some(v)
                } else {
                    None
                };
                let start = 1 + r.pos();
                // Reuse the allocation: drop the header (and rect table) in place.
                buf.drain(..start);
                return Ok(HostMsg::VideoFrame { frame_id, capture_time_us, flags, rects, data: buf });
            }
            MSG_CURSOR_POS => HostMsg::CursorPos { x: r.f32()?, y: r.f32()?, visible: r.u8()? != 0 },
            MSG_CURSOR_SHAPE => {
                let shape_id = r.u32()?;
                let w = r.u16()?;
                let h = r.u16()?;
                let hot_x = r.u16()?;
                let hot_y = r.u16()?;
                // checked: `usize` is 32 bits on 32-bit targets (65535² × 4 overflows it).
                let n = (w as usize).checked_mul(h as usize).and_then(|n| n.checked_mul(4)).ok_or(DecodeError::BadLength(t))?;
                let rest = r.rest();
                if rest.len() < n {
                    return Err(DecodeError::BadLength(t));
                }
                HostMsg::CursorShape { shape_id, w, h, hot_x, hot_y, bgra: rest[..n].to_vec() }
            }
            MSG_CURSOR_SHAPE_REF => HostMsg::CursorShapeRef { shape_id: r.u32()? },
            MSG_CLIPBOARD => HostMsg::Clipboard(ClipboardData::read(&mut r)?),
            MSG_CLIPBOARD_CAPS => HostMsg::ClipboardCaps { formats: r.u32()?, max_bytes: r.u32()? },
            MSG_AUDIO_CONFIG => HostMsg::AudioConfig(AudioConfig {
                codec: r.u8()?,
                sample_rate: r.u32()?,
                channels: r.u8()?,
                frame_samples: r.u16()?,
            }),
            MSG_AUDIO_FRAME => {
                let seq = r.u32()?;
                let capture_time_us = r.u64()?;
                buf.drain(..1 + r.pos());
                return Ok(HostMsg::AudioFrame { seq, capture_time_us, data: buf });
            }
            MSG_FILE_CHUNK => {
                // Like VideoFrame: keep the allocation, drop the 17-byte header in place.
                let (id, index, offset) = (r.u32()?, r.u32()?, r.u64()?);
                buf.drain(..1 + r.pos());
                return Ok(HostMsg::File(FileMsg::Chunk { id, index, offset, data: buf }));
            }
            t if FileMsg::is_file_type(t) => HostMsg::File(FileMsg::read(t, &mut r)?),
            MSG_FRAME_TIMING => HostMsg::FrameTiming(FrameTiming {
                frame_id: r.u32()?,
                capture_us: r.u64()?,
                flags: r.u8()?,
                callback: r.u32()?,
                submit: r.u32()?,
                encoded: r.u32()?,
                enqueued: r.u32()?,
                sent: r.u32()?,
            }),
            MSG_DISPLAY_INFO => {
                HostMsg::DisplayInfo { preference: r.u8()?, mode_w: r.u16()?, mode_h: r.u16()?, hidpi: r.u8()? != 0 }
            }
            MSG_DISPLAY_LIST => {
                let (streamed, selected, n) = (r.u32()?, r.u32()?, r.u8()?);
                let displays = (0..n).map(|_| MacDisplay::read(&mut r)).collect::<Result<Vec<_>, _>>()?;
                HostMsg::DisplayList { streamed, selected, displays }
            }
            MSG_DISPLAY_CHANGED => HostMsg::DisplayChanged { display_id: r.u32()?, reason: r.u8()?, requested: r.u32()? },
            MSG_INPUT_CAPS => HostMsg::InputCaps { flags: r.u32()? },
            other => HostMsg::Unknown { msg_type: other },
        };
        Ok(msg)
    }

    /// Encode (used by tests and the Rust-side loopback tooling).
    pub fn encode(&self) -> Vec<u8> {
        match self {
            HostMsg::AuthResult { code } => vec![MSG_AUTH_RESULT, *code],
            HostMsg::PairReveal { nonce } => {
                let mut v = vec![MSG_PAIR_REVEAL];
                v.extend_from_slice(nonce);
                v
            }
            HostMsg::ServerHello { version, host_name, config } => {
                let mut w = Writer::new(MSG_SERVER_HELLO);
                w.u16(*version).str(host_name);
                write_video_config(&mut w, config);
                w.finish()
            }
            HostMsg::VideoConfig(c) => {
                let mut w = Writer::new(MSG_VIDEO_CONFIG);
                write_video_config(&mut w, c);
                w.finish()
            }
            HostMsg::Pong { client_time_us, host_time_us } => Writer::new(MSG_PONG).u64(*client_time_us).u64(*host_time_us).finish(),
            HostMsg::SharpLayerConfig(c) => {
                let mut w = Writer::new(MSG_SHARP_LAYER_CONFIG);
                write_video_config(&mut w, c);
                w.finish()
            }
            HostMsg::VideoFrame { frame_id, capture_time_us, flags, rects, data } => {
                let mut w = Writer::new(MSG_VIDEO_FRAME);
                w.u32(*frame_id).u64(*capture_time_us);
                match rects {
                    Some(rs) => {
                        w.u8(*flags | FRAME_FLAG_RECTS).u16(rs.len() as u16);
                        for r in rs {
                            w.u16(r.x).u16(r.y).u16(r.w).u16(r.h);
                        }
                    }
                    None => {
                        w.u8(*flags & !FRAME_FLAG_RECTS);
                    }
                }
                w.bytes(data).finish()
            }
            HostMsg::CursorPos { x, y, visible } => Writer::new(MSG_CURSOR_POS).f32(*x).f32(*y).u8(*visible as u8).finish(),
            HostMsg::CursorShape { shape_id, w, h, hot_x, hot_y, bgra } => {
                Writer::new(MSG_CURSOR_SHAPE).u32(*shape_id).u16(*w).u16(*h).u16(*hot_x).u16(*hot_y).bytes(bgra).finish()
            }
            HostMsg::CursorShapeRef { shape_id } => Writer::new(MSG_CURSOR_SHAPE_REF).u32(*shape_id).finish(),
            HostMsg::Clipboard(c) => {
                let mut w = Writer::new(MSG_CLIPBOARD);
                c.write(&mut w);
                w.finish()
            }
            HostMsg::ClipboardCaps { formats, max_bytes } => Writer::new(MSG_CLIPBOARD_CAPS).u32(*formats).u32(*max_bytes).finish(),
            HostMsg::AudioConfig(c) => {
                Writer::new(MSG_AUDIO_CONFIG).u8(c.codec).u32(c.sample_rate).u8(c.channels).u16(c.frame_samples).finish()
            }
            HostMsg::AudioFrame { seq, capture_time_us, data } => {
                Writer::new(MSG_AUDIO_FRAME).u32(*seq).u64(*capture_time_us).bytes(data).finish()
            }
            HostMsg::File(m) => m.encode(),
            HostMsg::FrameTiming(t) => Writer::new(MSG_FRAME_TIMING)
                .u32(t.frame_id)
                .u64(t.capture_us)
                .u8(t.flags)
                .u32(t.callback)
                .u32(t.submit)
                .u32(t.encoded)
                .u32(t.enqueued)
                .u32(t.sent)
                .finish(),
            HostMsg::DisplayInfo { preference, mode_w, mode_h, hidpi } => {
                Writer::new(MSG_DISPLAY_INFO).u8(*preference).u16(*mode_w).u16(*mode_h).u8(*hidpi as u8).finish()
            }
            HostMsg::DisplayList { streamed, selected, displays } => {
                let mut w = Writer::new(MSG_DISPLAY_LIST);
                let list = &displays[..displays.len().min(255)];
                w.u32(*streamed).u32(*selected).u8(list.len() as u8);
                for d in list {
                    d.write(&mut w);
                }
                w.finish()
            }
            HostMsg::DisplayChanged { display_id, reason, requested } => {
                Writer::new(MSG_DISPLAY_CHANGED).u32(*display_id).u8(*reason).u32(*requested).finish()
            }
            HostMsg::InputCaps { flags } => Writer::new(MSG_INPUT_CAPS).u32(*flags).finish(),
            HostMsg::Unknown { msg_type } => vec![*msg_type],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_hello_matches_vector_plaintext() {
        // From docs/test-vectors.json records[0].plaintext
        let m = ClientMsg::ClientHello {
            version: 1,
            codec_caps: 0b111,
            view_w: 3840,
            view_h: 2160,
            mode: 0,
            max_fps: 60,
            client_name: "test-client".into(),
        };
        assert_eq!(crate::util::hex(&m.encode()), "01010007000000000f7008003c0b00746573742d636c69656e74");
        assert_eq!(ClientMsg::decode(&m.encode()).unwrap(), m);
    }

    #[test]
    fn mouse_move_matches_vector_plaintext() {
        let m = ClientMsg::MouseMove { x: 0.25, y: 0.75 };
        assert_eq!(crate::util::hex(&m.encode()), "100000803e0000403f");
    }

    #[test]
    fn server_hello_decodes_vector_plaintext() {
        let pt = crate::util::unhex("0201000900746573742d686f7374000aa00501000000000040");
        let m = HostMsg::decode(pt.clone()).unwrap();
        assert_eq!(
            m,
            HostMsg::ServerHello {
                version: 1,
                host_name: "test-host".into(),
                config: VideoConfig { width: 2560, height: 1440, codec: Codec::Hevc, chroma: 0, color: 0, scale: 2.0 }
            }
        );
        assert_eq!(m.encode(), pt);
    }

    #[test]
    fn auth_phase_messages() {
        assert_eq!(HostMsg::AuthResult { code: AUTH_UNKNOWN_VIEWER }.encode(), vec![0x08, 0x01]);
        assert_eq!(HostMsg::decode(vec![0x08, 0x03]).unwrap(), HostMsg::AuthResult { code: AUTH_DECLINED });
        let r = HostMsg::PairReveal { nonce: [9; 32] };
        assert_eq!(r.encode().len(), 33);
        assert_eq!(HostMsg::decode(r.encode()).unwrap(), r);
        assert!(HostMsg::decode(vec![0x09, 1, 2]).is_err());
        assert_eq!(ClientMsg::PairConfirm { matched: true }.encode(), vec![0x0A, 0x01]);
        assert_eq!(ClientMsg::decode(&[0x0A, 0x00]).unwrap(), ClientMsg::PairConfirm { matched: false });
    }

    #[test]
    fn video_frame_roundtrip() {
        let m = HostMsg::VideoFrame { frame_id: 7, capture_time_us: 123456789, flags: 1, rects: None, data: vec![0, 0, 0, 1, 0x40, 1, 2, 3] };
        let enc = m.encode();
        assert_eq!(enc.len(), 1 + 4 + 8 + 1 + 8);
        assert_eq!(HostMsg::decode(enc).unwrap(), m);
    }

    #[test]
    fn all_client_msgs_roundtrip() {
        let msgs = vec![
            ClientMsg::MouseButton { button: MOUSE_FORWARD, down: true },
            ClientMsg::MouseWheel { dx: -0.5, dy: 1.0 },
            ClientMsg::Key { hid_usage: 0xE3, down: false },
            ClientMsg::ReleaseAll,
            ClientMsg::RequestKeyframe,
            ClientMsg::SetMode { mode: 1, bitrate_kbps: 50000, max_fps: 120 },
            ClientMsg::Ping { client_time_us: u64::MAX - 3 },
            ClientMsg::Clipboard(ClipboardData { seq: 3, text: Some("héllo\nwörld".into()), png: None }),
            ClientMsg::Clipboard(ClipboardData { seq: 4, text: None, png: Some(vec![0x89, b'P', b'N', b'G']) }),
            ClientMsg::Clipboard(ClipboardData { seq: u32::MAX, text: Some(String::new()), png: Some(vec![1]) }),
            ClientMsg::Clipboard(ClipboardData::default()),
        ];
        for m in msgs {
            assert_eq!(ClientMsg::decode(&m.encode()).unwrap(), m);
        }
        assert_eq!(ClientMsg::Key { hid_usage: 0x04, down: true }.encode(), vec![0x13, 0x04, 0x00, 0x01]);
    }

    #[test]
    fn host_msgs_roundtrip_and_truncation() {
        let msgs = vec![
            HostMsg::VideoConfig(VideoConfig { width: 1920, height: 1080, codec: Codec::H264, chroma: 0, color: 0, scale: 1.0 }),
            HostMsg::Pong { client_time_us: 1, host_time_us: 2 },
            HostMsg::CursorPos { x: 0.5, y: 0.1, visible: true },
            HostMsg::CursorShape { shape_id: 9, w: 2, h: 1, hot_x: 0, hot_y: 0, bgra: vec![1, 2, 3, 4, 5, 6, 7, 8] },
            HostMsg::CursorShapeRef { shape_id: 9 },
        ];
        for m in msgs {
            let enc = m.encode();
            assert_eq!(HostMsg::decode(enc.clone()).unwrap(), m);
            if enc.len() > 1 {
                assert!(HostMsg::decode(enc[..enc.len() - 1].to_vec()).is_err());
            }
        }
        assert_eq!(HostMsg::decode(vec![0x9E, 1, 2]).unwrap(), HostMsg::Unknown { msg_type: 0x9E });
        assert!(HostMsg::decode(vec![]).is_err());
    }

    #[test]
    fn video_frame_with_rects() {
        // Hand-built wire bytes: flags = refresh|rects, 2 rects, then 4 bytes of Annex-B.
        let mut raw = vec![MSG_VIDEO_FRAME];
        raw.extend_from_slice(&5u32.to_le_bytes());
        raw.extend_from_slice(&99u64.to_le_bytes());
        raw.push(FRAME_FLAG_RECTS | FRAME_FLAG_REFRESH);
        raw.extend_from_slice(&2u16.to_le_bytes());
        for v in [16u16, 32, 64, 48, 3824, 2144, 32, 32] {
            raw.extend_from_slice(&v.to_le_bytes());
        }
        raw.extend_from_slice(&[0, 0, 0, 1]);
        let m = HostMsg::decode(raw.clone()).unwrap();
        let HostMsg::VideoFrame { frame_id, capture_time_us, flags, rects, data } = &m else { panic!() };
        assert_eq!((*frame_id, *capture_time_us, *flags), (5, 99, FRAME_FLAG_RECTS | FRAME_FLAG_REFRESH));
        let rs = rects.as_ref().unwrap();
        assert_eq!(rs, &vec![Rect { x: 16, y: 32, w: 64, h: 48 }, Rect { x: 3824, y: 2144, w: 32, h: 32 }]);
        assert_eq!(data, &vec![0, 0, 0, 1]);
        assert_eq!(m.encode(), raw);
        // clamping to a 3840x2160 frame
        assert_eq!(rs[1].clamped(3840, 2160), Some((3824, 2144, 16, 16)));
        assert_eq!(Rect { x: 4000, y: 0, w: 10, h: 10 }.clamped(3840, 2160), None);
        // zero rects is valid (empty update)
        let mut raw0 = raw[..14].to_vec();
        raw0.extend_from_slice(&0u16.to_le_bytes());
        raw0.extend_from_slice(&[9, 9]);
        let HostMsg::VideoFrame { rects, data, .. } = HostMsg::decode(raw0).unwrap() else { panic!() };
        assert_eq!((rects, data), (Some(vec![]), vec![9, 9]));
        // truncated rect table
        assert!(HostMsg::decode(raw[..14 + 2 + 6].to_vec()).is_err());
        // no rects flag: payload untouched
        let mut raw2 = raw[..13].to_vec();
        raw2.push(FRAME_FLAG_KEYFRAME | FRAME_FLAG_SHARP);
        raw2.extend_from_slice(&[0, 0, 0, 1, 0x40]);
        let HostMsg::VideoFrame { rects, data, flags, .. } = HostMsg::decode(raw2).unwrap() else { panic!() };
        assert_eq!((rects, data, flags), (None, vec![0, 0, 0, 1, 0x40], 5));
    }

    #[test]
    fn sharp_layer_config_roundtrip() {
        let c = VideoConfig { width: 3840, height: 2160, codec: Codec::Hevc, chroma: 1, color: 0, scale: 1.5 };
        let m = HostMsg::SharpLayerConfig(c);
        let enc = m.encode();
        assert_eq!(enc[0], 0x04);
        assert_eq!(HostMsg::decode(enc).unwrap(), m);
        assert_eq!(Mode::from_u8(2), Mode::Hybrid);
    }

    #[test]
    fn latency_messages_match_reference_bytes() {
        // docs/PROTOCOL.md §3.4 reference encodings (mac glide-selftest and mock_host check the same bytes).
        let ft_hex = "810700000040420f000000000001dc0500004006000048260000ac26000074270000";
        let ft = HostMsg::FrameTiming(FrameTiming {
            frame_id: 7,
            capture_us: 1_000_000,
            flags: 1,
            callback: 1500,
            submit: 1600,
            encoded: 9800,
            enqueued: 9900,
            sent: 10100,
        });
        assert_eq!(crate::util::hex(&ft.encode()), ft_hex);
        assert_eq!(HostMsg::decode(crate::util::unhex(ft_hex)).unwrap(), ft);
        assert!(HostMsg::decode(crate::util::unhex(&ft_hex[..ft_hex.len() - 2])).is_err());
        if let HostMsg::FrameTiming(t) = ft {
            assert_eq!(t.at(t.encoded), Some(1_009_800));
            assert_eq!(t.at(TIMING_UNKNOWN), None);
        }
        assert_eq!(ClientMsg::LatencyEnable { flags: 1 }.encode(), vec![0x80, 0x01]);
        let lr_hex = "82780001f82a0000b00400002c0100000807000090010000f41a000060540000ffffffff";
        let lr = ClientMsg::LatencyReport(LatencyReport {
            samples: 120,
            flags: 1,
            host_us: 11000,
            network_us: 1200,
            queue_us: 300,
            decode_us: 1800,
            render_us: 400,
            scanout_us: 6900,
            total_us: 21600,
            ground_truth_us: TIMING_UNKNOWN,
        });
        assert_eq!(crate::util::hex(&lr.encode()), lr_hex);
        assert_eq!(ClientMsg::decode(&crate::util::unhex(lr_hex)).unwrap(), lr);
        assert_eq!(ClientMsg::decode(&[0x80, 0x01]).unwrap(), ClientMsg::LatencyEnable { flags: 1 });
    }

    #[test]
    fn audio_messages_match_reference_bytes() {
        // docs/PROTOCOL.md §3.2 reference encodings (mac glide-selftest checks the same bytes).
        let cfg = HostMsg::AudioConfig(AudioConfig { codec: AUDIO_CODEC_PCM_S16, sample_rate: 48000, channels: 2, frame_samples: 480 });
        assert_eq!(crate::util::hex(&cfg.encode()), "600180bb000002e001");
        assert_eq!(HostMsg::decode(crate::util::unhex("600180bb000002e001")).unwrap(), cfg);
        let frame_hex = "610700000040420f00000000000100ffffff7f0080";
        let m = HostMsg::decode(crate::util::unhex(frame_hex)).unwrap();
        assert_eq!(m, HostMsg::AudioFrame { seq: 7, capture_time_us: 1_000_000, data: crate::util::unhex("0100ffffff7f0080") });
        assert_eq!(crate::util::hex(&m.encode()), frame_hex);
        assert_eq!(ClientMsg::AudioEnable { enabled: false }.encode(), vec![0x62, 0x00]);
        assert_eq!(ClientMsg::decode(&[0x62, 0x01]).unwrap(), ClientMsg::AudioEnable { enabled: true });
        assert!(ClientMsg::decode(&[0x62]).is_err());
        // truncated headers are errors; an empty payload is a valid (empty) frame
        assert!(HostMsg::decode(crate::util::unhex("600180bb000002e0")).is_err());
        assert!(HostMsg::decode(crate::util::unhex("610700000040420f000000")).is_err());
        assert_eq!(
            HostMsg::decode(crate::util::unhex("610700000040420f0000000000")).unwrap(),
            HostMsg::AudioFrame { seq: 7, capture_time_us: 1_000_000, data: vec![] }
        );
        assert_eq!(CAP_AUDIO_PCM, 0x200);
    }

    #[test]
    fn display_messages_match_reference_bytes() {
        // docs/PROTOCOL.md §3.3 reference encodings (mac glide-selftest checks the same bytes).
        let set = ClientMsg::SetDisplayPreference { mode: DISPLAY_PREF_RETINA };
        assert_eq!(crate::util::hex(&set.encode()), "1603");
        assert_eq!(ClientMsg::decode(&[0x16, 0x03]).unwrap(), set);
        assert!(ClientMsg::decode(&[0x16]).is_err());
        let info = HostMsg::DisplayInfo { preference: DISPLAY_PREF_AUTOMATIC, mode_w: 1920, mode_h: 1080, hidpi: true };
        assert_eq!(crate::util::hex(&info.encode()), "05008007380401");
        assert_eq!(HostMsg::decode(crate::util::unhex("05008007380401")).unwrap(), info);
        assert_eq!(
            HostMsg::decode(crate::util::unhex("0504000a400600")).unwrap(),
            HostMsg::DisplayInfo { preference: DISPLAY_PREF_MANUAL, mode_w: 2560, mode_h: 1600, hidpi: false }
        );
        assert!(HostMsg::decode(crate::util::unhex("050080073804")).is_err());
    }

    #[test]
    fn view_size_encoding() {
        // 0x15 ViewSize { u16 view_w, u16 view_h }, little-endian: 3072x1728 (DSR 1.44x of 2560x1440)
        let m = ClientMsg::ViewSize { view_w: 3072, view_h: 1728 };
        assert_eq!(m.encode(), vec![0x15, 0x00, 0x0C, 0xC0, 0x06]);
        assert_eq!(ClientMsg::decode(&m.encode()).unwrap(), m);
        assert!(ClientMsg::decode(&[0x15, 0x00, 0x0C, 0xC0]).is_err());
    }

    #[test]
    fn clipboard_reference_bytes() {
        // PROTOCOL.md §5 (also checked by glide-selftest and mock_host.py --selftest).
        let c = ClipboardData { seq: 1, text: Some("hi\n".into()), png: None };
        let want = crate::util::unhex("500100000001010300000068690a");
        assert_eq!(ClientMsg::Clipboard(c.clone()).encode(), want);
        assert_eq!(HostMsg::Clipboard(c.clone()).encode(), want);
        assert_eq!(HostMsg::decode(want.clone()).unwrap(), HostMsg::Clipboard(c.clone()));
        assert_eq!(ClientMsg::decode(&want).unwrap(), ClientMsg::Clipboard(c));
        let caps = HostMsg::ClipboardCaps { formats: CLIP_CAPS_TEXT | CLIP_CAPS_PNG, max_bytes: CLIPBOARD_MAX_BYTES as u32 };
        assert_eq!(crate::util::hex(&caps.encode()), "510300000000000001");
        assert_eq!(HostMsg::decode(caps.encode()).unwrap(), caps);
        assert_eq!(CAP_CLIPBOARD, 0x100);
    }

    /// docs/input-vectors.json (§3.6; also checked by glide-selftest and mock_host.py --selftest).
    #[test]
    fn input_messages_match_reference_bytes() {
        let v: serde_json::Value = serde_json::from_str(include_str!("../../docs/input-vectors.json")).unwrap();
        let msgs = v["messages"].as_array().unwrap();
        let get = |name: &str| {
            let m = msgs.iter().find(|m| m["name"] == name).unwrap_or_else(|| panic!("no vector {name}"));
            crate::util::unhex(m["hex"].as_str().unwrap())
        };
        let caps = HostMsg::InputCaps { flags: INPUT_CAPS_SCROLL | INPUT_CAPS_RELATIVE | INPUT_CAPS_LOCKS | INPUT_CAPS_CONSUMER };
        assert_eq!(caps.encode(), get("InputCaps"));
        assert_eq!(HostMsg::decode(get("InputCaps")).unwrap(), caps);
        let cases = [
            ("ScrollPrecise", ClientMsg::Scroll { flags: SCROLL_PRECISE, dx: 0.0, dy: 0.25 }),
            ("ScrollDiscrete", ClientMsg::Scroll { flags: 0, dx: -1.0, dy: 0.0 }),
            ("MouseDelta", ClientMsg::MouseDelta { dx: 5, dy: -3 }),
            ("LockState", ClientMsg::LockState { locks: LOCK_CAPS }),
            ("ConsumerKey", ClientMsg::ConsumerKey { usage: 0xCD, down: true }),
        ];
        assert_eq!(cases.len() + 1, msgs.len(), "one case per reference message");
        for (name, m) in cases {
            let want = get(name);
            assert_eq!(m.encode(), want, "{name}");
            assert_eq!(ClientMsg::decode(&want).unwrap(), m, "{name}");
            for n in 1..want.len() {
                assert!(ClientMsg::decode(&want[..n]).is_err(), "{name} truncated to {n}");
            }
        }
        assert_eq!(CAP_INPUT_EXT, 0x1000);
    }

    /// docs/file-transfer-vectors.json "messages" (also checked by glide-selftest and mock_host.py).
    pub(crate) fn file_vector(name: &str) -> Vec<u8> {
        let v: serde_json::Value = serde_json::from_str(include_str!("../../docs/file-transfer-vectors.json")).unwrap();
        let m = v["messages"].as_array().unwrap().iter().find(|m| m["name"] == name).unwrap_or_else(|| panic!("no vector {name}"));
        crate::util::unhex(m["hex"].as_str().unwrap())
    }

    #[test]
    fn file_messages_match_reference_bytes() {
        use sha2::Digest;
        let sha: [u8; 32] = sha2::Sha256::digest(b"hello").into();
        let cases = [
            ("FileCaps", FileMsg::Caps { flags: FILE_CAPS_RECEIVE | FILE_CAPS_SEND, max_total_bytes: 8 << 30, max_files: 10000 }),
            (
                "FileOffer",
                FileMsg::Offer {
                    id: 1,
                    total_bytes: 5,
                    files: vec![
                        FileEntry { path: "Photos/a.jpg".into(), size: 5, mtime_ms: 1_700_000_000_123 },
                        FileEntry { path: "b.txt".into(), size: 0, mtime_ms: -1 },
                    ],
                },
            ),
            ("FileAnswer", FileMsg::Answer { id: 1, status: 0, detail: String::new() }),
            ("FileAnswerDecline", FileMsg::Answer { id: 0x8000_0002, status: 2, detail: "max 1 GiB".into() }),
            ("FileChunk", FileMsg::Chunk { id: 1, index: 0, offset: 0, data: b"hello".to_vec() }),
            ("FileEnd", FileMsg::End { id: 1, index: 0, sha256: sha }),
            ("FileAck", FileMsg::Ack { id: 1, bytes: 5 }),
            ("FileCancel", FileMsg::Cancel { id: 0x8000_0001, reason: 7, detail: "user".into() }),
            ("FileDone", FileMsg::Done { id: 1, files: 2 }),
            ("FilePull", FileMsg::Pull),
            ("FilePullResult", FileMsg::PullResult { status: 11, detail: "no files".into() }),
        ];
        for (name, m) in cases {
            let want = file_vector(name);
            assert_eq!(m.encode(), want, "{name}");
            assert_eq!(ClientMsg::File(m.clone()).encode(), want, "{name}");
            assert_eq!(ClientMsg::decode(&want).unwrap(), ClientMsg::File(m.clone()), "{name}");
            assert_eq!(HostMsg::decode(want.clone()).unwrap(), HostMsg::File(m.clone()), "{name}");
            assert_eq!(HostMsg::File(m).encode(), want, "{name}");
            // Every strict prefix fails, except where the tail is a variable-length payload.
            for n in 1..want.len() {
                let r = HostMsg::decode(want[..n].to_vec());
                if name == "FileChunk" && n >= 17 {
                    assert!(r.is_ok());
                } else {
                    assert!(r.is_err(), "{name} prefix {n} decoded as {r:?}");
                }
            }
        }
        assert_eq!(CAP_FILES, 0x800);
    }

    #[test]
    fn file_offer_decoding_is_robust() {
        // A huge declared count with no entries must not allocate or panic.
        let mut raw = vec![MSG_FILE_OFFER];
        raw.extend_from_slice(&1u32.to_le_bytes());
        raw.extend_from_slice(&0u64.to_le_bytes());
        raw.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(HostMsg::decode(raw).is_err());
        // Invalid UTF-8 in a path is replaced, not fatal (the receiver then sanitizes it).
        let mut raw = vec![MSG_FILE_OFFER];
        raw.extend_from_slice(&7u32.to_le_bytes());
        raw.extend_from_slice(&1u64.to_le_bytes());
        raw.extend_from_slice(&1u32.to_le_bytes());
        raw.extend_from_slice(&[2, 0, 0xFF, b'a']);
        raw.extend_from_slice(&1u64.to_le_bytes());
        raw.extend_from_slice(&0u64.to_le_bytes());
        let HostMsg::File(FileMsg::Offer { files, .. }) = HostMsg::decode(raw).unwrap() else { panic!() };
        assert_eq!(files[0].path, "\u{FFFD}a");
        // Chunk payloads are not printed by Debug.
        let dbg = format!("{:?}", FileMsg::Chunk { id: 1, index: 2, offset: 3, data: b"secret".to_vec() });
        assert!(!dbg.contains("secret") && dbg.contains("len: 6"));
    }

    #[test]
    fn clipboard_decoding_rules() {
        // Unknown format skipped, duplicate text ignored (first wins), png kept.
        let mut raw = vec![MSG_CLIPBOARD, 2, 0, 0, 0, 4];
        raw.extend_from_slice(&[9, 2, 0, 0, 0, 0xAA, 0xBB]);
        raw.extend_from_slice(&[1, 2, 0, 0, 0, b'o', b'k']);
        raw.extend_from_slice(&[1, 1, 0, 0, 0, b'x']);
        raw.extend_from_slice(&[2, 2, 0, 0, 0, 0xFF, 0xC0]);
        let want = ClipboardData { seq: 2, text: Some("ok".into()), png: Some(vec![0xFF, 0xC0]) };
        assert_eq!(HostMsg::decode(raw.clone()).unwrap(), HostMsg::Clipboard(want.clone()));
        assert_eq!(ClientMsg::decode(&raw).unwrap(), ClientMsg::Clipboard(want));
        // Invalid UTF-8 is replaced, not an error.
        let bad = vec![MSG_CLIPBOARD, 1, 0, 0, 0, 1, 1, 2, 0, 0, 0, 0xFF, b'A'];
        let HostMsg::Clipboard(c) = HostMsg::decode(bad).unwrap() else { panic!() };
        assert_eq!(c.text.as_deref(), Some("\u{FFFD}A"));
        // Every truncation is an error; a length past the end too.
        let enc = HostMsg::Clipboard(ClipboardData { seq: 5, text: Some("abc".into()), png: Some(vec![1, 2]) }).encode();
        for n in 1..enc.len() {
            assert!(HostMsg::decode(enc[..n].to_vec()).is_err(), "prefix {n}");
        }
        assert!(HostMsg::decode(vec![MSG_CLIPBOARD, 1, 0, 0, 0, 1, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0]).is_err());
        // Text larger than the u16 `str` limit.
        let big = ClipboardData { seq: 1, text: Some("y".repeat(200_000)), png: None };
        assert_eq!(big.payload_len(), 200_000);
        assert_eq!(HostMsg::decode(HostMsg::Clipboard(big.clone()).encode()).unwrap(), HostMsg::Clipboard(big));
        // Debug never prints content.
        let dbg = format!("{:?}", ClipboardData { seq: 1, text: Some("hunter2".into()), png: None });
        assert!(!dbg.contains("hunter2") && dbg.contains("text 7 bytes"));
    }
}
