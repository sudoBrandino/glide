//! Video and cursor logic without Win32: encoded size for a viewer's `ViewSize`, codec choice,
//! bitrate, Annex-B checks/normalization for encoder output, and cursor bitmap conversion
//! (GDI color/monochrome cursors → BGRA straight alpha, top-down, ≤ 256 px).

use crate::protocol::{Codec, VideoConfig, CAP_HEVC_420};

/// Widest encoded frame the host produces (hardware encoders handle 4K at 60 fps).
pub const MAX_ENCODE_WIDTH: u32 = 3840;
/// Tallest encoded frame (portrait 4K panels; H.264 level 5.1 / HEVC limits).
pub const MAX_ENCODE_HEIGHT: u32 = 4096;
/// Sanity limits for a viewer's reported view size (mac/Sources/GlideCore/ViewSize.swift).
pub const VIEW_MIN_W: u32 = 320;
pub const VIEW_MIN_H: u32 = 200;
pub const VIEW_MAX: u32 = 16384;
/// Largest cursor shape sent (§3).
pub const MAX_CURSOR: u32 = 256;

/// The view size to use for a reported `w` x `h`: None when unknown (either is 0), else clamped.
pub fn clamp_view(w: u16, h: u16) -> Option<(u32, u32)> {
    if w == 0 || h == 0 {
        return None;
    }
    Some(((w as u32).clamp(VIEW_MIN_W, VIEW_MAX), (h as u32).clamp(VIEW_MIN_H, VIEW_MAX)))
}

/// Encoded size for a `native_w` x `native_h` output: width ≤ min(native, viewer width, 3840),
/// height ≤ 4096, aspect kept, both even and ≥ 2. Never upscales.
pub fn encode_size(native_w: u32, native_h: u32, view_w: Option<u32>) -> (u32, u32) {
    let (nw, nh) = (native_w.max(2), native_h.max(2));
    let mut limit = MAX_ENCODE_WIDTH.min(nw);
    if let Some(v) = view_w {
        limit = limit.min(v.max(VIEW_MIN_W));
    }
    let (mut w, mut h) = (nw, nh);
    if w > limit {
        h = (h as u64 * limit as u64 / w as u64) as u32;
        w = limit;
    }
    if h > MAX_ENCODE_HEIGHT {
        w = (w as u64 * MAX_ENCODE_HEIGHT as u64 / h as u64) as u32;
        h = MAX_ENCODE_HEIGHT;
    }
    ((w & !1).max(2), (h & !1).max(2))
}

/// Codec for a viewer's `codec_caps`: HEVC when it decodes HEVC and an HEVC encoder exists,
/// else H.264 (also for a viewer that names no codec, or only ones this host can't encode —
/// every Glide viewer decodes H.264).
pub fn choose_codec(codec_caps: u32, hevc_available: bool) -> Codec {
    if codec_caps & CAP_HEVC_420 != 0 && hevc_available {
        Codec::Hevc
    } else {
        Codec::H264
    }
}

/// Default bitrate: about 0.13 bits per pixel per frame at 60 fps (≈ 29 Mbps at 2560x1440),
/// HEVC 25 % less, clamped to 6–80 Mbps. `fps` scales it sublinearly.
pub fn default_bitrate_kbps(w: u32, h: u32, fps: u32, codec: Codec) -> u32 {
    let fps = fps.clamp(10, 240) as f64;
    let pixels = (w as f64) * (h as f64);
    let mut kbps = pixels * 60.0 * 0.13 / 1000.0 * (fps / 60.0).sqrt();
    if codec == Codec::Hevc {
        kbps *= 0.75;
    }
    (kbps as u32).clamp(6_000, 80_000)
}

/// The VideoConfig for an encoded stream. `scale` = the monitor's DPI scale (1.0 = 96 dpi).
pub fn video_config(w: u32, h: u32, codec: Codec, scale: f32) -> VideoConfig {
    VideoConfig { width: w as u16, height: h as u16, codec, chroma: 0, color: 0, scale: if scale.is_finite() && scale > 0.0 { scale } else { 1.0 } }
}

/// NAL units of an Annex-B stream (start code removed), with 3- or 4-byte start codes.
pub fn nal_units(data: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new(); // (start code pos, payload pos)
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            let sc = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
            starts.push((sc, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (k, &(_, p)) in starts.iter().enumerate() {
        let end = starts.get(k + 1).map_or(data.len(), |n| n.0);
        if end > p {
            out.push(&data[p..end]);
        }
    }
    out
}

fn nal_type(codec: Codec, nal: &[u8]) -> u8 {
    match codec {
        Codec::Hevc => (nal[0] >> 1) & 0x3F,
        _ => nal[0] & 0x1F,
    }
}

/// The stream carries its parameter sets (H.264 SPS+PPS; HEVC VPS+SPS+PPS).
pub fn has_parameter_sets(data: &[u8], codec: Codec) -> bool {
    let types: Vec<u8> = nal_units(data).iter().map(|n| nal_type(codec, n)).collect();
    match codec {
        Codec::Hevc => [32, 33, 34].iter().all(|t| types.contains(t)),
        _ => [7, 8].iter().all(|t| types.contains(t)),
    }
}

/// The access unit contains an IDR/IRAP picture.
pub fn is_keyframe(data: &[u8], codec: Codec) -> bool {
    nal_units(data).iter().any(|n| {
        let t = nal_type(codec, n);
        match codec {
            Codec::Hevc => (16..=21).contains(&t),
            _ => t == 5,
        }
    })
}

/// Re-frames an Annex-B stream with 4-byte start codes (§3). Data that doesn't start with a
/// start code is returned unchanged.
pub fn normalize_annexb(data: &[u8]) -> Vec<u8> {
    let nals = nal_units(data);
    if nals.is_empty() {
        return data.to_vec();
    }
    let mut out = Vec::with_capacity(data.len() + nals.len());
    for n in nals {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(n);
    }
    out
}

/// A keyframe as sent: parameter sets in-band. If the encoder didn't include them, prepend
/// `sequence_header` (MF_MT_MPEG_SEQUENCE_HEADER, Annex-B). Always 4-byte start codes.
pub fn prepare_access_unit(data: &[u8], codec: Codec, keyframe: bool, sequence_header: Option<&[u8]>) -> Vec<u8> {
    if keyframe && !has_parameter_sets(data, codec) {
        if let Some(sh) = sequence_header.filter(|s| !s.is_empty()) {
            let mut v = normalize_annexb(sh);
            v.extend(normalize_annexb(data));
            return v;
        }
    }
    normalize_annexb(data)
}

// ---------------------------------------------------------------- cursor bitmaps

/// A cursor shape ready to send: BGRA, straight alpha, top-down.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorImage {
    pub w: u32,
    pub h: u32,
    pub hot_x: u32,
    pub hot_y: u32,
    pub bgra: Vec<u8>,
}

fn px(b: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3]])
}

/// Pixels that invert the screen can't be shown as such: draw them black with a white outline
/// (so an I-beam stays visible on dark and light backgrounds).
fn outline_inverted(out: &mut [u8], invert: &[bool], w: usize, h: usize) {
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if invert[i] || out[i * 4 + 3] != 0 {
                continue;
            }
            let near = (y.saturating_sub(1)..(y + 2).min(h)).any(|yy| (x.saturating_sub(1)..(x + 2).min(w)).any(|xx| invert[yy * w + xx]));
            if near {
                out[i * 4..i * 4 + 4].copy_from_slice(&[255, 255, 255, 255]);
            }
        }
    }
}

/// Monochrome cursor (GDI `hbmMask` only, height 2h: AND mask on top, XOR mask below), as
/// 32-bpp top-down pixels (GetDIBits output: 0 = black, 0xFFFFFF = white).
/// AND 0 / XOR 0 = black, AND 0 / XOR 1 = white, AND 1 / XOR 0 = transparent, AND 1 / XOR 1 = invert.
pub fn mono_cursor(mask32: &[u8], w: u32, h: u32) -> Vec<u8> {
    let (w, h) = (w as usize, h as usize);
    let mut out = vec![0u8; w * h * 4];
    let mut invert = vec![false; w * h];
    for i in 0..w * h {
        let and = px(mask32, i) & 0xFF_FFFF != 0;
        let xor = px(mask32, w * h + i) & 0xFF_FFFF != 0;
        let v: [u8; 4] = match (and, xor) {
            (false, false) => [0, 0, 0, 255],
            (false, true) => [255, 255, 255, 255],
            (true, false) => [0, 0, 0, 0],
            (true, true) => {
                invert[i] = true;
                [0, 0, 0, 255]
            }
        };
        out[i * 4..i * 4 + 4].copy_from_slice(&v);
    }
    outline_inverted(&mut out, &invert, w, h);
    out
}

/// Color cursor (`hbmColor`, 32-bpp top-down BGRA) with its AND mask (32-bpp, same size).
/// With an alpha channel (any nonzero alpha) the alpha is used as is; without, the mask gives
/// transparency and masked pixels with nonzero color invert the screen.
pub fn color_cursor(color: &[u8], mask32: Option<&[u8]>, w: u32, h: u32) -> Vec<u8> {
    let (w, h) = (w as usize, h as usize);
    let n = w * h;
    let mut out = color[..n * 4].to_vec();
    if (0..n).any(|i| color[i * 4 + 3] != 0) {
        return out;
    }
    let mut invert = vec![false; n];
    for i in 0..n {
        let masked = mask32.is_some_and(|m| px(m, i) & 0xFF_FFFF != 0);
        let rgb = px(color, i) & 0xFF_FFFF;
        if !masked {
            out[i * 4 + 3] = 255;
        } else if rgb != 0 {
            invert[i] = true;
            out[i * 4..i * 4 + 4].copy_from_slice(&[0, 0, 0, 255]);
        } else {
            out[i * 4..i * 4 + 4].copy_from_slice(&[0, 0, 0, 0]);
        }
    }
    outline_inverted(&mut out, &invert, w, h);
    out
}

/// Fits a shape for sending: scales by `scale` (encoded / native pixels, ≤ 1 shrinks with an
/// area filter in premultiplied space) and crops to at most 256 x 256 around the hotspot.
pub fn fit_cursor(img: CursorImage, scale: f32) -> CursorImage {
    let img = if scale.is_finite() && scale > 0.0 && scale < 0.99 { downscale(&img, scale) } else { img };
    if img.w <= MAX_CURSOR && img.h <= MAX_CURSOR {
        return img;
    }
    let cw = img.w.min(MAX_CURSOR);
    let ch = img.h.min(MAX_CURSOR);
    let x0 = img.hot_x.saturating_sub(cw / 2).min(img.w - cw);
    let y0 = img.hot_y.saturating_sub(ch / 2).min(img.h - ch);
    let mut bgra = Vec::with_capacity((cw * ch * 4) as usize);
    for y in y0..y0 + ch {
        let s = ((y * img.w + x0) * 4) as usize;
        bgra.extend_from_slice(&img.bgra[s..s + (cw * 4) as usize]);
    }
    CursorImage { w: cw, h: ch, hot_x: (img.hot_x - x0).min(cw - 1), hot_y: (img.hot_y - y0).min(ch - 1), bgra }
}

fn downscale(img: &CursorImage, scale: f32) -> CursorImage {
    let nw = ((img.w as f32 * scale).round() as u32).max(1);
    let nh = ((img.h as f32 * scale).round() as u32).max(1);
    let mut bgra = vec![0u8; (nw * nh * 4) as usize];
    let (fx, fy) = (img.w as f32 / nw as f32, img.h as f32 / nh as f32);
    for y in 0..nh {
        let (sy0, sy1) = ((y as f32 * fy) as u32, (((y + 1) as f32 * fy).ceil() as u32).min(img.h));
        for x in 0..nw {
            let (sx0, sx1) = ((x as f32 * fx) as u32, (((x + 1) as f32 * fx).ceil() as u32).min(img.w));
            let mut acc = [0f32; 4];
            let mut n = 0f32;
            for sy in sy0..sy1.max(sy0 + 1) {
                for sx in sx0..sx1.max(sx0 + 1) {
                    let i = ((sy * img.w + sx) * 4) as usize;
                    let a = img.bgra[i + 3] as f32 / 255.0;
                    for (c, v) in acc.iter_mut().take(3).enumerate() {
                        *v += img.bgra[i + c] as f32 * a;
                    }
                    acc[3] += a;
                    n += 1.0;
                }
            }
            let o = ((y * nw + x) * 4) as usize;
            let a = acc[3] / n;
            if a > 0.0 {
                for (c, v) in acc.iter().take(3).enumerate() {
                    bgra[o + c] = (v / acc[3]).round().clamp(0.0, 255.0) as u8;
                }
            }
            bgra[o + 3] = (a * 255.0).round() as u8;
        }
    }
    let hx = ((img.hot_x as f32 * scale) as u32).min(nw - 1);
    let hy = ((img.hot_y as f32 * scale) as u32).min(nh - 1);
    CursorImage { w: nw, h: nh, hot_x: hx, hot_y: hy, bgra }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{HostMsg, CAP_H264_420, CAP_HEVC_444};

    #[test]
    fn view_clamp() {
        assert_eq!(clamp_view(0, 1080), None);
        assert_eq!(clamp_view(1, 1), Some((320, 200)));
        assert_eq!(clamp_view(2560, 1440), Some((2560, 1440)));
        assert_eq!(clamp_view(u16::MAX, u16::MAX), Some((16384, 16384)));
    }

    #[test]
    fn encode_sizes() {
        assert_eq!(encode_size(2560, 1440, None), (2560, 1440));
        assert_eq!(encode_size(2560, 1440, Some(1920)), (1920, 1080));
        assert_eq!(encode_size(3840, 2160, Some(5120)), (3840, 2160), "never upscales");
        assert_eq!(encode_size(5120, 2880, None), (3840, 2160), "3840 cap");
        assert_eq!(encode_size(1366, 768, Some(1440)), (1366, 768));
        assert_eq!(encode_size(1366, 768, Some(1000)), (1000, 562));
        assert_eq!(encode_size(1365, 767, None), (1364, 766), "even");
        assert_eq!(encode_size(2160, 3840, None), (2160, 3840), "portrait");
        assert_eq!(encode_size(2160, 7680, None), (1152, 4096), "height cap");
        assert_eq!(encode_size(0, 0, Some(1)), (2, 2));
        assert_eq!(encode_size(3440, 1440, Some(320)), (320, 132));
    }

    #[test]
    fn codec_choice_and_bitrate() {
        assert_eq!(choose_codec(CAP_HEVC_420 | CAP_H264_420, true), Codec::Hevc);
        assert_eq!(choose_codec(CAP_HEVC_420 | CAP_H264_420, false), Codec::H264);
        assert_eq!(choose_codec(CAP_H264_420 | CAP_HEVC_444, true), Codec::H264);
        assert_eq!(choose_codec(0, true), Codec::H264);
        let b = default_bitrate_kbps(2560, 1440, 60, Codec::H264);
        assert!((20_000..=40_000).contains(&b), "{b}");
        assert!(default_bitrate_kbps(2560, 1440, 60, Codec::Hevc) < b);
        assert_eq!(default_bitrate_kbps(320, 200, 30, Codec::H264), 6_000);
        assert_eq!(default_bitrate_kbps(3840, 2160, 240, Codec::H264), 80_000);
        let c = video_config(1920, 1080, Codec::Hevc, f32::NAN);
        assert_eq!(c.scale, 1.0);
        // VideoConfig {1920x1080 HEVC 4:2:0 BT.709 scale 1.5}
        let e = HostMsg::VideoConfig(video_config(1920, 1080, Codec::Hevc, 1.5)).encode();
        assert_eq!(crate::util::hex(&e), "03800738040100000000c03f");
    }

    #[test]
    fn annexb_helpers() {
        let sps = [0x67, 1, 2];
        let pps = [0x68, 3];
        let idr = [0x65, 9, 9, 0, 0, 3, 1];
        let mut au = vec![0, 0, 1];
        au.extend_from_slice(&idr);
        assert!(is_keyframe(&au, Codec::H264));
        assert!(!has_parameter_sets(&au, Codec::H264));
        let mut sh = vec![0, 0, 0, 1];
        sh.extend_from_slice(&sps);
        sh.extend_from_slice(&[0, 0, 1]);
        sh.extend_from_slice(&pps);
        let out = prepare_access_unit(&au, Codec::H264, true, Some(&sh));
        let mut want = vec![0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1];
        want.extend_from_slice(&idr);
        assert_eq!(out, want);
        assert!(has_parameter_sets(&out, Codec::H264));
        // Already in-band: unchanged apart from start codes.
        assert_eq!(prepare_access_unit(&out, Codec::H264, true, Some(&sh)), out);
        // P frame: no parameter sets added.
        let p = [0, 0, 0, 1, 0x41, 7];
        assert_eq!(prepare_access_unit(&p, Codec::H264, false, Some(&sh)), p.to_vec());
        assert!(!is_keyframe(&p, Codec::H264));
        // HEVC: VPS 32, SPS 33, PPS 34, IDR_W_RADL 19.
        let hevc = [0, 0, 0, 1, 0x40, 1, 0, 0, 1, 0x42, 1, 0, 0, 1, 0x44, 1, 0, 0, 1, 0x26, 1, 5];
        assert!(has_parameter_sets(&hevc, Codec::Hevc));
        assert!(is_keyframe(&hevc, Codec::Hevc));
        assert_eq!(nal_units(&hevc).len(), 4);
        assert_eq!(normalize_annexb(b"\x01\x02"), vec![1, 2], "no start code: unchanged");
    }

    fn rgba32(px: &[u32]) -> Vec<u8> {
        px.iter().flat_map(|p| p.to_le_bytes()).collect()
    }

    #[test]
    fn monochrome_cursor_conversion() {
        // 3x1: AND = [0, 1, 1], XOR = [1, 0, 1] -> white, transparent, invert
        let mask = rgba32(&[0, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0, 0xFFFFFF]);
        let out = mono_cursor(&mask, 3, 1);
        assert_eq!(&out[0..4], &[255, 255, 255, 255]);
        assert_eq!(&out[8..12], &[0, 0, 0, 255], "invert -> black");
        assert_eq!(&out[4..8], &[255, 255, 255, 255], "next to an inverted pixel -> white outline");
        // AND 0 XOR 0 -> opaque black; isolated transparent stays transparent
        let mask = rgba32(&[0, 0xFFFFFF, 0, 0]);
        assert_eq!(mono_cursor(&mask, 2, 1), vec![0, 0, 0, 255, 0, 0, 0, 0]);
    }

    #[test]
    fn color_cursor_conversion() {
        // With alpha: kept as is.
        let c = rgba32(&[0x80112233, 0x00000000]);
        assert_eq!(color_cursor(&c, None, 2, 1), c);
        // Without alpha: mask decides; masked nonzero color inverts (black, outlined).
        let c = rgba32(&[0x00112233, 0x00000000, 0x00FFFFFF, 0]);
        let m = rgba32(&[0, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF]);
        let out = color_cursor(&c, Some(&m), 4, 1);
        assert_eq!(&out[0..4], &[0x33, 0x22, 0x11, 255]);
        assert_eq!(&out[4..8], &[255, 255, 255, 255]);
        assert_eq!(&out[8..12], &[0, 0, 0, 255]);
        assert_eq!(&out[12..16], &[255, 255, 255, 255]);
    }

    #[test]
    fn cursor_fit() {
        let img = CursorImage { w: 300, h: 10, hot_x: 290, hot_y: 3, bgra: vec![255; 300 * 10 * 4] };
        let f = fit_cursor(img, 1.0);
        assert_eq!((f.w, f.h), (256, 10));
        assert_eq!(f.bgra.len(), 256 * 10 * 4);
        assert_eq!((f.hot_x, f.hot_y), (290 - 44, 3));
        // Downscale by half: 4x4 opaque white with a transparent half -> 2x2.
        let mut bgra = vec![255u8; 4 * 4 * 4];
        for y in 0..4 {
            for x in 2..4 {
                bgra[(y * 4 + x) * 4 + 3] = 0;
            }
        }
        let f = fit_cursor(CursorImage { w: 4, h: 4, hot_x: 3, hot_y: 1, bgra }, 0.5);
        assert_eq!((f.w, f.h, f.hot_x, f.hot_y), (2, 2, 1, 0));
        assert_eq!(&f.bgra[0..4], &[255, 255, 255, 255]);
        assert_eq!(f.bgra[7], 0);
        assert!(f.w <= MAX_CURSOR);
    }
}
