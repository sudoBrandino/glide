//! Clipboard sync logic (docs/PROTOCOL.md §5) that does not touch Win32: line endings, echo
//! suppression, DIB <-> PNG conversion, and building/preparing `ClipboardData`. Platform
//! independent and unit-tested; `win::clipboard` does the actual clipboard I/O.

use crate::protocol::{ClipboardData, CLIPBOARD_MAX_BYTES, CLIP_FORMAT_PNG, CLIP_FORMAT_TEXT};

// ------------------------------------------------------------------ text

/// Wire form of text: CRLF (and lone CR) -> LF.
pub fn to_wire_text(s: &str) -> String {
    if !s.contains('\r') {
        return s.to_string();
    }
    s.replace("\r\n", "\n").replace('\r', "\n")
}

/// CF_UNICODETEXT contents (UTF-16, stops at the first NUL) -> wire text.
pub fn utf16_to_wire(units: &[u16]) -> String {
    let end = units.iter().position(|&u| u == 0).unwrap_or(units.len());
    to_wire_text(&String::from_utf16_lossy(&units[..end]))
}

/// Wire text -> NUL-terminated UTF-16 with CRLF line endings, for CF_UNICODETEXT.
pub fn wire_to_utf16_crlf(s: &str) -> Vec<u16> {
    let lf = to_wire_text(s);
    let mut out = Vec::with_capacity(lf.len() + lf.len() / 16 + 1);
    for u in lf.encode_utf16() {
        if u == u16::from(b'\n') {
            out.push(u16::from(b'\r'));
        }
        out.push(u);
    }
    out.push(0);
    out
}

// ------------------------------------------------------------------ echo suppression

/// 64-bit FNV-1a.
pub fn fnv1a64(data: &[u8], seed: u64) -> u64 {
    let mut h = seed;
    for &b in data {
        h = (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

/// Hash of the content that would be sent (text if any, else image bytes), tagged with the format.
pub fn content_hash(format: u8, bytes: &[u8]) -> u64 {
    fnv1a64(bytes, fnv1a64(&[format], FNV_OFFSET))
}

pub fn data_hash(c: &ClipboardData) -> Option<u64> {
    if let Some(t) = &c.text {
        return Some(content_hash(CLIP_FORMAT_TEXT, t.as_bytes()));
    }
    c.png.as_ref().map(|p| content_hash(CLIP_FORMAT_PNG, p))
}

/// Echo suppression (§5): the OS change marker of our own write, plus a hash of the last content
/// sent or applied. Same semantics as the Swift `ClipboardEchoGuard`.
#[derive(Default, Debug)]
pub struct EchoGuard {
    last_marker: Option<u64>,
    own_marker: Option<u64>,
    last_hash: Option<u64>,
    /// Marker at which the clipboard held `last_hash` content.
    hash_marker: Option<u64>,
}

impl EchoGuard {
    /// Record the marker at session start (the current clipboard is not sent).
    pub fn baseline(&mut self, marker: u64) {
        self.last_marker = Some(marker);
    }
    /// True when the clipboard changed since the last call and it isn't our own write.
    pub fn changed(&mut self, marker: u64) -> bool {
        if Some(marker) == self.last_marker {
            return false;
        }
        self.last_marker = Some(marker);
        Some(marker) != self.own_marker
    }
    /// False if `hash` equals the last content sent or applied; otherwise remembers it.
    /// `marker`: the clipboard's marker when the content was read.
    pub fn should_send(&mut self, hash: u64, marker: u64) -> bool {
        if Some(hash) == self.last_hash {
            return false;
        }
        self.last_hash = Some(hash);
        self.hash_marker = Some(marker);
        true
    }
    /// False when received content equals what we last sent/applied and the clipboard hasn't
    /// changed since (rewriting would only drop richer formats the source app put there).
    pub fn should_apply(&self, hash: Option<u64>, marker: u64) -> bool {
        !(hash.is_some() && hash == self.last_hash && Some(marker) == self.hash_marker)
    }
    /// After writing received content locally; `marker` is the OS marker right after the write.
    pub fn did_apply(&mut self, hash: Option<u64>, marker: u64) {
        if hash.is_some() {
            self.last_hash = hash;
        }
        self.hash_marker = Some(marker);
        self.own_marker = Some(marker);
        self.last_marker = Some(marker);
    }
}

// ------------------------------------------------------------------ images

/// Decoded image, straight (non-premultiplied) RGBA8, top-down rows.
#[derive(Debug, Clone, PartialEq)]
pub struct Rgba {
    pub w: u32,
    pub h: u32,
    pub px: Vec<u8>,
}

/// Refuse absurd sizes before allocating (64 Mpx = 256 MB RGBA).
const MAX_PIXELS: u64 = 64 << 20;

fn le_u16(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn le_u32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const BI_ALPHABITFIELDS: u32 = 6;

/// Extract a channel with `mask` from `v`, scaled to 0..=255.
fn channel(v: u32, mask: u32) -> u8 {
    if mask == 0 {
        return 0;
    }
    let shift = mask.trailing_zeros();
    let bits = (mask >> shift).count_ones().min(16);
    let x = (v & mask) >> shift;
    let max = (1u32 << bits) - 1;
    ((x * 255 + max / 2) / max) as u8
}

/// Parse a packed DIB (CF_DIB / CF_DIBV5 content: BITMAPINFOHEADER/V4/V5 + optional masks +
/// color table + bits). Supports 1/4/8 bpp palettized, 16/24/32 bpp BI_RGB and BI_BITFIELDS.
/// Alpha is used only when the header declares an alpha mask and it isn't all zero.
pub fn dib_to_rgba(dib: &[u8]) -> Result<Rgba, String> {
    if dib.len() < 40 {
        return Err("DIB too short".into());
    }
    let hsize = le_u32(dib, 0) as usize;
    if hsize < 40 || hsize > dib.len() {
        return Err(format!("unsupported DIB header size {hsize}"));
    }
    let w = le_u32(dib, 4) as i32;
    let h_raw = le_u32(dib, 8) as i32;
    let bpp = le_u16(dib, 14) as u32;
    let comp = le_u32(dib, 16);
    let clr_used = le_u32(dib, 32) as usize;
    if w <= 0 || h_raw == 0 || h_raw == i32::MIN {
        return Err(format!("bad DIB size {w}x{h_raw}"));
    }
    let (w, h, top_down) = (w as u32, h_raw.unsigned_abs(), h_raw < 0);
    if w as u64 * h as u64 > MAX_PIXELS {
        return Err(format!("DIB too large ({w}x{h})"));
    }
    // Masks: inside V2+ headers, else after a 40-byte header for (ALPHA)BITFIELDS.
    let mut off = hsize;
    let (mut rm, mut gm, mut bm, mut am) = (0u32, 0u32, 0u32, 0u32);
    let bitfields = comp == BI_BITFIELDS || comp == BI_ALPHABITFIELDS;
    if bitfields {
        if hsize >= 52 {
            rm = le_u32(dib, 40);
            gm = le_u32(dib, 44);
            bm = le_u32(dib, 48);
            if hsize >= 56 {
                am = le_u32(dib, 52);
            }
        } else {
            let n = if comp == BI_ALPHABITFIELDS { 4 } else { 3 };
            if dib.len() < off + 4 * n {
                return Err("DIB masks truncated".into());
            }
            rm = le_u32(dib, off);
            gm = le_u32(dib, off + 4);
            bm = le_u32(dib, off + 8);
            if n == 4 {
                am = le_u32(dib, off + 12);
            }
            off += 4 * n;
        }
    } else if comp != BI_RGB {
        return Err(format!("unsupported DIB compression {comp}"));
    } else if hsize >= 56 && bpp == 32 {
        // V4/V5 BI_RGB: an alpha mask may still be declared.
        am = le_u32(dib, 52);
    }
    let palette_len = match bpp {
        1 | 4 | 8 => {
            if clr_used == 0 {
                1usize << bpp
            } else {
                clr_used.min(1 << bpp)
            }
        }
        16 | 24 | 32 => clr_used.min(256), // optional optimization palette: skip it
        _ => return Err(format!("unsupported DIB bit depth {bpp}")),
    };
    if dib.len() < off + palette_len * 4 {
        return Err("DIB color table truncated".into());
    }
    let palette = &dib[off..off + palette_len * 4];
    off += palette_len * 4;
    if !bitfields {
        match bpp {
            16 => (rm, gm, bm) = (0x7C00, 0x03E0, 0x001F),
            32 => (rm, gm, bm) = (0x00FF_0000, 0x0000_FF00, 0x0000_00FF),
            _ => {}
        }
    }
    let stride = (w as usize * bpp as usize).div_ceil(32) * 4;
    let need = stride * h as usize;
    if dib.len() < off + need {
        return Err(format!("DIB pixel data truncated ({} < {})", dib.len() - off, need));
    }
    let bits = &dib[off..off + need];
    let mut px = vec![0u8; w as usize * h as usize * 4];
    let mut any_alpha = false;
    for y in 0..h as usize {
        let src_row = if top_down { y } else { h as usize - 1 - y };
        let row = &bits[src_row * stride..(src_row + 1) * stride];
        let out = &mut px[y * w as usize * 4..(y + 1) * w as usize * 4];
        for x in 0..w as usize {
            let (r, g, b, a) = match bpp {
                1 | 4 | 8 => {
                    let idx = match bpp {
                        8 => row[x] as usize,
                        4 => ((row[x / 2] >> (if x % 2 == 0 { 4 } else { 0 })) & 0xF) as usize,
                        _ => ((row[x / 8] >> (7 - x % 8)) & 1) as usize,
                    };
                    let e = &palette[(idx.min(palette_len.saturating_sub(1))) * 4..][..4];
                    (e[2], e[1], e[0], 255)
                }
                24 => (row[x * 3 + 2], row[x * 3 + 1], row[x * 3], 255),
                16 => {
                    let v = le_u16(row, x * 2) as u32;
                    (channel(v, rm), channel(v, gm), channel(v, bm), if am != 0 { channel(v, am) } else { 255 })
                }
                _ => {
                    let v = le_u32(row, x * 4);
                    (channel(v, rm), channel(v, gm), channel(v, bm), if am != 0 { channel(v, am) } else { 255 })
                }
            };
            any_alpha |= am != 0 && a != 0;
            out[x * 4..x * 4 + 4].copy_from_slice(&[r, g, b, a]);
        }
    }
    if am != 0 && !any_alpha {
        // Declared alpha but all zero: the usual "alpha unused" case. Treat as opaque.
        for p in px.chunks_exact_mut(4) {
            p[3] = 255;
        }
    }
    Ok(Rgba { w, h, px })
}

/// RGBA -> packed DIB for CF_DIB: BITMAPINFOHEADER, 32 bpp BI_RGB, bottom-up. Translucent
/// pixels are composited over white with alpha 255 (CF_DIB readers mostly ignore alpha; apps that
/// care about transparency read the "PNG" format, which is set alongside).
pub fn rgba_to_dib(img: &Rgba) -> Vec<u8> {
    let (w, h) = (img.w as usize, img.h as usize);
    let mut out = Vec::with_capacity(40 + w * h * 4);
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(img.w as i32).to_le_bytes());
    out.extend_from_slice(&(img.h as i32).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&BI_RGB.to_le_bytes());
    out.extend_from_slice(&((w * h * 4) as u32).to_le_bytes());
    out.extend_from_slice(&2835i32.to_le_bytes()); // 72 dpi
    out.extend_from_slice(&2835i32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    for y in (0..h).rev() {
        for p in img.px[y * w * 4..(y + 1) * w * 4].chunks_exact(4) {
            let a = p[3] as u32;
            let over_white = |c: u8| ((c as u32 * a + 255 * (255 - a) + 127) / 255) as u8;
            out.extend_from_slice(&[over_white(p[2]), over_white(p[1]), over_white(p[0]), 255]);
        }
    }
    out
}

/// Encode as PNG (RGB if fully opaque, else RGBA), fast compression.
pub fn rgba_to_png(img: &Rgba) -> Result<Vec<u8>, String> {
    let opaque = img.px.chunks_exact(4).all(|p| p[3] == 255);
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, img.w, img.h);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Fast);
        let rgb: Vec<u8>;
        let data: &[u8] = if opaque {
            enc.set_color(png::ColorType::Rgb);
            rgb = img.px.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
            &rgb
        } else {
            enc.set_color(png::ColorType::Rgba);
            &img.px
        };
        let mut wr = enc.write_header().map_err(|e| format!("png header: {e}"))?;
        wr.write_image_data(data).map_err(|e| format!("png encode: {e}"))?;
        wr.finish().map_err(|e| format!("png finish: {e}"))?;
    }
    Ok(out)
}

/// Decode any PNG (palette, gray, 16-bit, ...) to RGBA8.
pub fn png_to_rgba(data: &[u8]) -> Result<Rgba, String> {
    let mut dec = png::Decoder::new_with_limits(std::io::Cursor::new(data), png::Limits { bytes: (MAX_PIXELS * 4) as usize });
    dec.set_transformations(png::Transformations::normalize_to_color8());
    let mut rd = dec.read_info().map_err(|e| format!("png: {e}"))?;
    let (w, h) = (rd.info().width, rd.info().height);
    if w as u64 * h as u64 > MAX_PIXELS {
        return Err(format!("png too large ({w}x{h})"));
    }
    let mut buf = vec![0u8; rd.output_buffer_size().ok_or("png: size overflow")?];
    let info = rd.next_frame(&mut buf).map_err(|e| format!("png: {e}"))?;
    let n = w as usize * h as usize;
    let line = info.line_size;
    let mut px = Vec::with_capacity(n * 4);
    for y in 0..h as usize {
        let row = &buf[y * line..];
        for x in 0..w as usize {
            let p: [u8; 4] = match info.color_type {
                png::ColorType::Rgba => [row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]],
                png::ColorType::Rgb => [row[x * 3], row[x * 3 + 1], row[x * 3 + 2], 255],
                png::ColorType::GrayscaleAlpha => [row[x * 2], row[x * 2], row[x * 2], row[x * 2 + 1]],
                png::ColorType::Grayscale => [row[x], row[x], row[x], 255],
                png::ColorType::Indexed => return Err("png: palette not expanded".into()),
            };
            px.extend_from_slice(&p);
        }
    }
    Ok(Rgba { w, h, px })
}

/// Width/height from the PNG signature + IHDR (must be the first chunk), without decoding.
pub fn png_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 33 || !data.starts_with(b"\x89PNG\r\n\x1a\n") || data[8..12] != [0, 0, 0, 13] || &data[12..16] != b"IHDR" {
        return None;
    }
    let be = |o: usize| u32::from_be_bytes([data[o], data[o + 1], data[o + 2], data[o + 3]]);
    Some((be(16), be(20)))
}

/// Untrusted PNG from the peer: None if acceptable, else why not. Checked before decoding
/// (decompression bombs); same 64 Mpx cap as the Mac host.
pub fn png_refusal(data: &[u8]) -> Option<String> {
    match png_dimensions(data) {
        None => Some("received image is not a PNG".into()),
        Some((0, _)) | Some((_, 0)) => Some("received PNG has an empty size".into()),
        Some((w, h)) if w as u64 * h as u64 > MAX_PIXELS => Some(format!("received PNG is too large ({w}x{h} > {} Mpx)", MAX_PIXELS >> 20)),
        Some(_) => None,
    }
}

/// Clipboard privacy markers (registered format names) that apps such as password managers put
/// next to secret content. `ExcludeClipboardContentFromMonitorProcessing` and
/// `Clipboard Viewer Ignore` mean "don't monitor"; the `Can*` formats hold a DWORD, 0 = no.
pub const PRIVACY_FORMATS: [&str; 4] =
    ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"];

/// Given the privacy formats present on the clipboard (with their DWORD value when readable),
/// return the marker that makes the content private, if any.
pub fn privacy_marker(present: &[(&str, Option<u32>)]) -> Option<&'static str> {
    for &(name, value) in present {
        let Some(&known) = PRIVACY_FORMATS.iter().find(|&&f| f == name) else { continue };
        match known {
            "CanIncludeInClipboardHistory" | "CanUploadToCloudClipboard" => {
                if value == Some(0) {
                    return Some(known);
                }
            }
            _ => return Some(known),
        }
    }
    None
}

/// Clipboard HGLOBALs can be larger than the PNG they hold: cut after the IEND chunk.
pub fn png_trim(data: &[u8]) -> &[u8] {
    const SIG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if !data.starts_with(SIG) {
        return data;
    }
    let mut p = SIG.len();
    while p + 12 <= data.len() {
        let len = u32::from_be_bytes([data[p], data[p + 1], data[p + 2], data[p + 3]]) as usize;
        let end = p.saturating_add(12).saturating_add(len);
        if end > data.len() {
            break;
        }
        if &data[p + 4..p + 8] == b"IEND" {
            return &data[..end];
        }
        p = end;
    }
    data
}

// ------------------------------------------------------------------ outgoing / incoming

/// What the local clipboard held (raw, as read on the UI thread).
#[derive(Debug, Clone, PartialEq)]
pub enum LocalClip {
    /// Already wire-normalized (LF).
    Text(String),
    /// Bytes of the registered "PNG" format (trimmed).
    Png(Vec<u8>),
    /// CF_DIB bytes.
    Dib(Vec<u8>),
}

impl LocalClip {
    /// Echo-guard hash (computed before any expensive conversion).
    pub fn hash(&self) -> u64 {
        match self {
            LocalClip::Text(t) => content_hash(CLIP_FORMAT_TEXT, t.as_bytes()),
            LocalClip::Png(p) | LocalClip::Dib(p) => content_hash(CLIP_FORMAT_PNG, p),
        }
    }

    /// Build the message payload (DIB -> PNG here). Err = a log line explaining why nothing is sent.
    pub fn into_data(self, seq: u32, max_bytes: usize) -> Result<ClipboardData, String> {
        let max = max_bytes.min(CLIPBOARD_MAX_BYTES);
        let mib = |n: usize| format!("{:.1} MiB", n as f64 / 1_048_576.0);
        match self {
            LocalClip::Text(t) => {
                if t.len() > max {
                    return Err(format!("text too large ({} > {}), not sent", mib(t.len()), mib(max)));
                }
                Ok(ClipboardData { seq, text: Some(t), png: None })
            }
            LocalClip::Png(p) => {
                if p.len() > max {
                    return Err(format!("image too large ({} PNG > {}), not sent", mib(p.len()), mib(max)));
                }
                Ok(ClipboardData { seq, text: None, png: Some(p) })
            }
            LocalClip::Dib(d) => {
                let img = dib_to_rgba(&d).map_err(|e| format!("image not sent: {e}"))?;
                let p = rgba_to_png(&img).map_err(|e| format!("image not sent: {e}"))?;
                if p.len() > max {
                    return Err(format!("image too large ({}x{}, {} PNG > {}), not sent", img.w, img.h, mib(p.len()), mib(max)));
                }
                Ok(ClipboardData { seq, text: None, png: Some(p) })
            }
        }
    }
}

/// Received clipboard converted to what `SetClipboardData` needs (done off the UI thread).
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Prepared {
    pub seq: u32,
    /// NUL-terminated UTF-16, CRLF.
    pub text_utf16: Option<Vec<u16>>,
    /// For the registered "PNG" format.
    pub png: Option<Vec<u8>>,
    /// For CF_DIB.
    pub dib: Option<Vec<u8>>,
    /// Echo-guard hash of the received content.
    pub hash: Option<u64>,
}

pub fn prepare_incoming(c: &ClipboardData) -> Result<Prepared, String> {
    if c.payload_len() > CLIPBOARD_MAX_BYTES {
        return Err(format!("ignoring oversized clipboard ({} bytes)", c.payload_len()));
    }
    let mut p = Prepared { seq: c.seq, hash: data_hash(c), text_utf16: c.text.as_deref().map(wire_to_utf16_crlf), ..Default::default() };
    if let Some(png) = &c.png {
        match png_refusal(png).map_or_else(|| png_to_rgba(png), Err) {
            Ok(img) => {
                p.dib = Some(rgba_to_dib(&img));
                p.png = Some(png.clone());
            }
            Err(e) if p.text_utf16.is_none() => return Err(format!("received image ignored: {e}")),
            Err(_) => {} // keep the text
        }
    }
    if p.text_utf16.is_none() && p.png.is_none() {
        return Err("empty clipboard message ignored".into());
    }
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_endings() {
        assert_eq!(to_wire_text("a\r\nb\rc\nd"), "a\nb\nc\nd");
        assert_eq!(to_wire_text("x\r\ny\r\n"), "x\ny\n");
        let u: Vec<u16> = "l1\r\nl2\r\n\0garbage".encode_utf16().collect();
        assert_eq!(utf16_to_wire(&u), "l1\nl2\n");
        assert_eq!(utf16_to_wire(&"no nul".encode_utf16().collect::<Vec<_>>()), "no nul");
        let back = wire_to_utf16_crlf("l1\nl2\r\nl3");
        assert_eq!(String::from_utf16(&back[..back.len() - 1]).unwrap(), "l1\r\nl2\r\nl3");
        assert_eq!(*back.last().unwrap(), 0);
        // Round trip: Windows text -> wire -> Windows text is stable.
        let win = "héllo 🎉\r\nworld\r\n";
        let w = wire_to_utf16_crlf(&utf16_to_wire(&win.encode_utf16().collect::<Vec<_>>()));
        assert_eq!(String::from_utf16(&w[..w.len() - 1]).unwrap(), win);
    }

    #[test]
    fn fnv_known_values() {
        assert_eq!(fnv1a64(b"", FNV_OFFSET), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a", FNV_OFFSET), 0xaf63_dc4c_8601_ec8c);
        assert_ne!(content_hash(CLIP_FORMAT_TEXT, b"x"), content_hash(CLIP_FORMAT_PNG, b"x"));
    }

    #[test]
    fn echo_guard_scenarios() {
        let mut g = EchoGuard::default();
        let h1 = content_hash(CLIP_FORMAT_TEXT, b"one");
        let two = ClipboardData { seq: 1, text: Some("two".into()), png: None };
        let h2 = data_hash(&two).unwrap();
        g.baseline(5);
        assert!(!g.changed(5), "baseline content not sent");
        assert!(g.changed(6) && g.should_send(h1, 6), "local change sent");
        assert!(!g.changed(6), "same marker not re-sent");
        assert!(!g.should_apply(Some(h1), 6), "echo of what we sent not re-applied while unchanged");
        assert!(g.should_apply(Some(h2), 6), "different content applied");
        assert!(g.changed(7) && !g.should_send(h1, 7), "identical content not re-sent");
        assert!(g.should_apply(Some(h1), 7), "same content applied after a local change");
        g.did_apply(Some(h2), 9);
        assert!(!g.changed(9), "own write not echoed");
        assert!(g.changed(10) && !g.should_send(h2, 10), "re-write of received content not echoed");
        assert!(g.changed(11) && g.should_send(h1, 11), "new local content after apply sent");
        g.did_apply(Some(h1), 12);
        assert!(!g.changed(12) && !g.should_send(h1, 12), "ping-pong stops");
        // Hash of a received message == hash of the same content read back locally.
        assert_eq!(LocalClip::Text("two".into()).hash(), h2);
        let img = ClipboardData { seq: 2, text: None, png: Some(vec![1, 2, 3]) };
        assert_eq!(LocalClip::Png(vec![1, 2, 3]).hash(), data_hash(&img).unwrap());
    }

    fn test_image(w: u32, h: u32, alpha: bool) -> Rgba {
        let mut px = Vec::new();
        for y in 0..h {
            for x in 0..w {
                px.extend_from_slice(&[(x * 40) as u8, (y * 60) as u8, (x * y) as u8, if alpha { (x * 50) as u8 } else { 255 }]);
            }
        }
        Rgba { w, h, px }
    }

    #[test]
    fn png_roundtrip_rgb_and_rgba() {
        for alpha in [false, true] {
            let img = test_image(5, 3, alpha);
            let png = rgba_to_png(&img).unwrap();
            assert!(png.starts_with(b"\x89PNG"));
            assert_eq!(png_to_rgba(&png).unwrap(), img);
            // Trailing HGLOBAL slack is trimmed; malformed data is returned as-is.
            let mut padded = png.clone();
            padded.extend_from_slice(&[0; 37]);
            assert_eq!(png_trim(&padded), &png[..]);
        }
        assert_eq!(png_trim(b"not a png"), b"not a png");
        assert!(png_to_rgba(b"\x89PNG\r\n\x1a\ngarbage").is_err());
    }

    #[test]
    fn png_gray_and_palette_decode() {
        // 2x1 grayscale + 2x1 palette images built with the encoder.
        let mut g = Vec::new();
        {
            let mut e = png::Encoder::new(&mut g, 2, 1);
            e.set_color(png::ColorType::Grayscale);
            e.set_depth(png::BitDepth::Eight);
            e.write_header().unwrap().write_image_data(&[0, 200]).unwrap();
        }
        assert_eq!(png_to_rgba(&g).unwrap().px, vec![0, 0, 0, 255, 200, 200, 200, 255]);
        let mut p = Vec::new();
        {
            let mut e = png::Encoder::new(&mut p, 2, 1);
            e.set_color(png::ColorType::Indexed);
            e.set_depth(png::BitDepth::Eight);
            e.set_palette(vec![10, 20, 30, 40, 50, 60]);
            e.set_trns(vec![255, 128]);
            e.write_header().unwrap().write_image_data(&[1, 0]).unwrap();
        }
        assert_eq!(png_to_rgba(&p).unwrap().px, vec![40, 50, 60, 128, 10, 20, 30, 255]);
    }

    /// Hand-built DIB: header (size, w, h, bpp, compression, clr_used) + extra + rows.
    fn dib(hsize: u32, w: i32, h: i32, bpp: u16, comp: u32, clr_used: u32, extra: &[u8], rows: &[u8]) -> Vec<u8> {
        let mut d = Vec::new();
        d.extend_from_slice(&hsize.to_le_bytes());
        d.extend_from_slice(&w.to_le_bytes());
        d.extend_from_slice(&h.to_le_bytes());
        d.extend_from_slice(&1u16.to_le_bytes());
        d.extend_from_slice(&bpp.to_le_bytes());
        d.extend_from_slice(&comp.to_le_bytes());
        d.extend_from_slice(&[0; 12]);
        d.extend_from_slice(&clr_used.to_le_bytes());
        d.extend_from_slice(&[0; 4]);
        d.resize(hsize as usize, 0);
        d.extend_from_slice(extra);
        d.extend_from_slice(rows);
        d
    }

    #[test]
    fn dib_variants() {
        // 24 bpp, 2x2 bottom-up, rows padded to 8 bytes. Bottom row first: blue, white; top: red, green.
        let rows24 = [255, 0, 0, 255, 255, 255, 0, 0, /* top */ 0, 0, 255, 0, 255, 0, 0, 0];
        let img = dib_to_rgba(&dib(40, 2, 2, 24, BI_RGB, 0, &[], &rows24)).unwrap();
        assert_eq!(img.px, vec![255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
        // Same image top-down (negative height).
        let td = [0, 0, 255, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0];
        assert_eq!(dib_to_rgba(&dib(40, 2, -2, 24, BI_RGB, 0, &[], &td)).unwrap(), img);
        // 32 bpp BI_RGB: the 4th byte is ignored (opaque), 1x1 BGRX.
        let i32 = dib_to_rgba(&dib(40, 1, 1, 32, BI_RGB, 0, &[], &[10, 20, 30, 7])).unwrap();
        assert_eq!(i32.px, vec![30, 20, 10, 255]);
        // 32 bpp BI_BITFIELDS (40-byte header + 3 masks) as R,G,B,X byte order.
        let masks: Vec<u8> = [0xFFu32, 0xFF00, 0xFF_0000].iter().flat_map(|m| m.to_le_bytes()).collect();
        let bf = dib_to_rgba(&dib(40, 1, 1, 32, BI_BITFIELDS, 0, &masks, &[1, 2, 3, 0])).unwrap();
        assert_eq!(bf.px, vec![1, 2, 3, 255]);
        // V5 header with an alpha mask: alpha honored; all-zero alpha => opaque.
        let mut v5 = dib(124, 2, 1, 32, BI_BITFIELDS, 0, &[], &[10, 20, 30, 128, 1, 2, 3, 0]);
        for (i, m) in [0xFF_0000u32, 0xFF00, 0xFF, 0xFF00_0000].iter().enumerate() {
            v5[40 + i * 4..44 + i * 4].copy_from_slice(&m.to_le_bytes());
        }
        assert_eq!(dib_to_rgba(&v5).unwrap().px, vec![30, 20, 10, 128, 3, 2, 1, 0]);
        let n = v5.len();
        v5[n - 5] = 0; // first pixel alpha -> 0 too
        assert_eq!(dib_to_rgba(&v5).unwrap().px, vec![30, 20, 10, 255, 3, 2, 1, 255]);
        // 16 bpp 5-6-5 bitfields: pure red.
        let m565: Vec<u8> = [0xF800u32, 0x07E0, 0x001F].iter().flat_map(|m| m.to_le_bytes()).collect();
        let r = dib_to_rgba(&dib(40, 1, 1, 16, BI_BITFIELDS, 0, &m565, &[0x00, 0xF8, 0, 0])).unwrap();
        assert_eq!(r.px, vec![255, 0, 0, 255]);
        // 8 bpp palettized with clr_used = 2.
        let pal = [0, 0, 0, 0, 0, 0, 255, 0]; // black, red
        let p8 = dib_to_rgba(&dib(40, 2, 1, 8, BI_RGB, 2, &pal, &[1, 0, 0, 0])).unwrap();
        assert_eq!(p8.px, vec![255, 0, 0, 255, 0, 0, 0, 255]);
        // 1 bpp: 0b1000_0000 -> first pixel = palette[1].
        let p1 = dib_to_rgba(&dib(40, 2, 1, 1, BI_RGB, 0, &[0, 0, 0, 0, 255, 255, 255, 0], &[0x80, 0, 0, 0])).unwrap();
        assert_eq!(p1.px, vec![255, 255, 255, 255, 0, 0, 0, 255]);
        // Errors: truncated pixels, RLE, silly sizes.
        assert!(dib_to_rgba(&dib(40, 2, 2, 24, BI_RGB, 0, &[], &rows24[..10])).is_err());
        assert!(dib_to_rgba(&dib(40, 1, 1, 8, 1 /* BI_RLE8 */, 0, &[0; 1024], &[0; 4])).is_err());
        assert!(dib_to_rgba(&dib(40, 100_000, 100_000, 32, BI_RGB, 0, &[], &[])).is_err());
        assert!(dib_to_rgba(&[0; 10]).is_err());
    }

    #[test]
    fn png_header_checks() {
        let ihdr = |w: u32, h: u32| {
            let mut d = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
            d.extend_from_slice(&w.to_be_bytes());
            d.extend_from_slice(&h.to_be_bytes());
            d.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
            d
        };
        let real = rgba_to_png(&test_image(5, 3, true)).unwrap();
        assert_eq!(png_dimensions(&real), Some((5, 3)));
        assert_eq!(png_refusal(&real), None);
        assert!(png_refusal(&ihdr(100_000, 100_000)).unwrap().contains("too large"));
        assert!(png_refusal(&ihdr(u32::MAX, u32::MAX)).unwrap().contains("too large"));
        assert_eq!(png_refusal(&ihdr(8192, 8192)), None);
        assert!(png_refusal(&ihdr(8193, 8192)).is_some());
        assert!(png_refusal(&ihdr(0, 7)).is_some());
        assert!(png_refusal(b"GIF89a....................................").unwrap().contains("not a PNG"));
        assert!(png_refusal(&rgba_to_dib(&test_image(2, 2, false))).is_some());
        assert_eq!(png_dimensions(&real[..20]), None);
        let mut idat_first = real.clone();
        idat_first[12..16].copy_from_slice(b"IDAT");
        assert_eq!(png_dimensions(&idat_first), None);
        // prepare_incoming refuses a bomb before decoding; text alongside survives.
        let bomb = ClipboardData { seq: 1, text: None, png: Some(ihdr(60_000, 60_000)) };
        assert!(prepare_incoming(&bomb).unwrap_err().contains("too large"));
        let with_text = ClipboardData { text: Some("t".into()), ..bomb };
        let p = prepare_incoming(&with_text).unwrap();
        assert!(p.png.is_none() && p.dib.is_none() && p.text_utf16.is_some());
    }

    #[test]
    fn privacy_markers() {
        assert_eq!(privacy_marker(&[]), None);
        assert_eq!(
            privacy_marker(&[("ExcludeClipboardContentFromMonitorProcessing", None)]),
            Some("ExcludeClipboardContentFromMonitorProcessing")
        );
        assert_eq!(privacy_marker(&[("Clipboard Viewer Ignore", Some(5))]), Some("Clipboard Viewer Ignore"));
        // Can* formats only mark content private with DWORD 0.
        assert_eq!(privacy_marker(&[("CanIncludeInClipboardHistory", Some(1))]), None);
        assert_eq!(privacy_marker(&[("CanIncludeInClipboardHistory", None)]), None);
        assert_eq!(privacy_marker(&[("CanIncludeInClipboardHistory", Some(0))]), Some("CanIncludeInClipboardHistory"));
        assert_eq!(
            privacy_marker(&[("CanIncludeInClipboardHistory", Some(1)), ("CanUploadToCloudClipboard", Some(0))]),
            Some("CanUploadToCloudClipboard")
        );
        assert_eq!(privacy_marker(&[("SomethingElse", Some(0))]), None);
    }

    #[test]
    fn dib_write_read_roundtrip() {
        let img = test_image(3, 2, false);
        let d = rgba_to_dib(&img);
        assert_eq!(d.len(), 40 + 3 * 2 * 4);
        assert_eq!(dib_to_rgba(&d).unwrap(), img);
        // Translucent pixels are composited over white.
        let t = Rgba { w: 1, h: 1, px: vec![0, 0, 0, 0] };
        assert_eq!(dib_to_rgba(&rgba_to_dib(&t)).unwrap().px, vec![255, 255, 255, 255]);
        let half = Rgba { w: 1, h: 1, px: vec![0, 0, 0, 128] };
        assert_eq!(dib_to_rgba(&rgba_to_dib(&half)).unwrap().px, vec![127, 127, 127, 255]);
    }

    #[test]
    fn outgoing_and_incoming() {
        // Text: limit enforced without truncation.
        let c = LocalClip::Text("hello".into()).into_data(4, CLIPBOARD_MAX_BYTES).unwrap();
        assert_eq!(c, ClipboardData { seq: 4, text: Some("hello".into()), png: None });
        assert!(LocalClip::Text("hello".into()).into_data(1, 4).unwrap_err().contains("too large"));
        // DIB -> PNG -> (receiver) -> DIB + PNG.
        let img = test_image(4, 4, false);
        let sent = LocalClip::Dib(rgba_to_dib(&img)).into_data(5, CLIPBOARD_MAX_BYTES).unwrap();
        let png = sent.png.clone().unwrap();
        assert_eq!(png_to_rgba(&png).unwrap(), img);
        assert!(LocalClip::Dib(rgba_to_dib(&img)).into_data(5, 20).unwrap_err().contains("too large"));
        let p = prepare_incoming(&sent).unwrap();
        assert_eq!(p.png.as_deref(), Some(&png[..]));
        assert_eq!(dib_to_rgba(p.dib.as_ref().unwrap()).unwrap(), img);
        assert_eq!(p.hash, data_hash(&sent));
        // Reading back what we applied (the "PNG" format) hashes the same -> no echo.
        assert_eq!(LocalClip::Png(png).hash(), p.hash.unwrap());
        // Text incoming -> CRLF UTF-16.
        let t = prepare_incoming(&ClipboardData { seq: 6, text: Some("a\nb".into()), png: None }).unwrap();
        assert_eq!(t.text_utf16.unwrap(), "a\r\nb\0".encode_utf16().collect::<Vec<_>>());
        // Bad PNG alone is refused; with text, the text is kept.
        assert!(prepare_incoming(&ClipboardData { seq: 7, text: None, png: Some(vec![1, 2]) }).is_err());
        let k = prepare_incoming(&ClipboardData { seq: 8, text: Some("x".into()), png: Some(vec![1, 2]) }).unwrap();
        assert!(k.text_utf16.is_some() && k.png.is_none() && k.dib.is_none());
        assert!(prepare_incoming(&ClipboardData::default()).is_err());
    }
}
