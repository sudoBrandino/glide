//! Glide v1 message encoding/decoding (docs/PROTOCOL.md §3). Platform independent.
//!
//! A message plaintext is `u8 message_type || payload`, all integers little-endian.

use std::fmt;

pub const PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_PORT: u16 = 7420;

// codec_caps bits
pub const CAP_HEVC_420: u32 = 1 << 0;
pub const CAP_HEVC_444: u32 = 1 << 1;
pub const CAP_H264_420: u32 = 1 << 2;
/// Bits 8+ are non-video features. Clipboard sync (§5).
pub const CAP_CLIPBOARD: u32 = 1 << 8;

// Client -> Host message types
pub const MSG_CLIENT_HELLO: u8 = 0x01;
pub const MSG_MOUSE_MOVE: u8 = 0x10;
pub const MSG_MOUSE_BUTTON: u8 = 0x11;
pub const MSG_MOUSE_WHEEL: u8 = 0x12;
pub const MSG_KEY: u8 = 0x13;
pub const MSG_RELEASE_ALL: u8 = 0x14;
pub const MSG_VIEW_SIZE: u8 = 0x15;
pub const MSG_REQUEST_KEYFRAME: u8 = 0x20;
pub const MSG_SET_MODE: u8 = 0x21;
pub const MSG_PING: u8 = 0x30;
pub const MSG_CLIPBOARD: u8 = 0x50;

// Host -> Client message types
pub const MSG_SERVER_HELLO: u8 = 0x02;
pub const MSG_VIDEO_CONFIG: u8 = 0x03;
pub const MSG_SHARP_LAYER_CONFIG: u8 = 0x04;
pub const MSG_PONG: u8 = 0x31;
pub const MSG_VIDEO_FRAME: u8 = 0x40;
pub const MSG_CURSOR_POS: u8 = 0x41;
pub const MSG_CURSOR_SHAPE: u8 = 0x42;
pub const MSG_CURSOR_SHAPE_REF: u8 = 0x43;
pub const MSG_CLIPBOARD_CAPS: u8 = 0x51;

// Clipboard (§5)
pub const CLIP_FORMAT_TEXT: u8 = 1;
pub const CLIP_FORMAT_PNG: u8 = 2;
/// `ClipboardCaps.formats` bits.
pub const CLIP_CAPS_TEXT: u32 = 1 << 0;
pub const CLIP_CAPS_PNG: u32 = 1 << 1;
/// Max total item payload of one Clipboard message (CLIPBOARD_MAX).
pub const CLIPBOARD_MAX_BYTES: usize = 16 << 20;

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
}

#[derive(Debug, Clone, PartialEq)]
pub enum HostMsg {
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
                    let mut v = Vec::with_capacity(n);
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
                let n = w as usize * h as usize * 4;
                let rest = r.rest();
                if rest.len() < n {
                    return Err(DecodeError::BadLength(t));
                }
                HostMsg::CursorShape { shape_id, w, h, hot_x, hot_y, bgra: rest[..n].to_vec() }
            }
            MSG_CURSOR_SHAPE_REF => HostMsg::CursorShapeRef { shape_id: r.u32()? },
            MSG_CLIPBOARD => HostMsg::Clipboard(ClipboardData::read(&mut r)?),
            MSG_CLIPBOARD_CAPS => HostMsg::ClipboardCaps { formats: r.u32()?, max_bytes: r.u32()? },
            other => HostMsg::Unknown { msg_type: other },
        };
        Ok(msg)
    }

    /// Encode (used by tests and the Rust-side loopback tooling).
    pub fn encode(&self) -> Vec<u8> {
        match self {
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
        assert_eq!(HostMsg::decode(vec![0x77, 1, 2]).unwrap(), HostMsg::Unknown { msg_type: 0x77 });
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
