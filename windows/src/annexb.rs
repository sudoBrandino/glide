//! Annex-B helpers: NAL iteration and access-unit splitting (HEVC / H.264).
//! Used by the probe's decode tests and for diagnostics. Platform independent.

use crate::protocol::Codec;

/// Returns (start_code_offset, nal_payload_offset) for each NAL unit.
pub fn nal_offsets(data: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            let sc = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
            out.push((sc, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

/// Split into NAL payloads (without start codes).
pub fn nals(data: &[u8]) -> Vec<&[u8]> {
    let offs = nal_offsets(data);
    offs.iter()
        .enumerate()
        .map(|(k, &(_, p))| {
            let end = offs.get(k + 1).map_or(data.len(), |n| n.0);
            &data[p..end]
        })
        .collect()
}

fn hevc_type(n: &[u8]) -> u8 {
    (n[0] >> 1) & 0x3F
}

pub fn is_vcl(codec: Codec, n: &[u8]) -> bool {
    if n.is_empty() {
        return false;
    }
    match codec {
        Codec::H264 => matches!(n[0] & 0x1F, 1..=5),
        _ => hevc_type(n) < 32,
    }
}

pub fn is_keyframe_nal(codec: Codec, n: &[u8]) -> bool {
    if n.is_empty() {
        return false;
    }
    match codec {
        Codec::H264 => n[0] & 0x1F == 5,
        _ => (16..=23).contains(&hevc_type(n)),
    }
}

/// True if this NAL begins a new access unit (given a VCL NAL has been seen already).
fn starts_au(codec: Codec, n: &[u8]) -> bool {
    if n.is_empty() {
        return false;
    }
    match codec {
        Codec::H264 => {
            let t = n[0] & 0x1F;
            match t {
                6..=9 | 14..=18 => true,
                1 | 5 => n.len() > 1 && n[1] & 0x80 != 0, // first_mb_in_slice == 0
                _ => false,
            }
        }
        _ => {
            let t = hevc_type(n);
            match t {
                32..=35 | 39 | 41..=44 | 48..=55 => true,
                0..=31 => n.len() > 2 && n[2] & 0x80 != 0, // first_slice_segment_in_pic_flag
                _ => false,
            }
        }
    }
}

pub struct AccessUnit {
    /// Annex-B bytes with 4-byte start codes.
    pub data: Vec<u8>,
    pub keyframe: bool,
}

pub fn split_access_units(codec: Codec, data: &[u8]) -> Vec<AccessUnit> {
    let mut aus = Vec::new();
    let mut cur = AccessUnit { data: Vec::new(), keyframe: false };
    let mut seen_vcl = false;
    for n in nals(data) {
        // Strip trailing zero bytes (trailing_zero_8bits / next start-code prefix).
        let mut end = n.len();
        while end > 0 && n[end - 1] == 0 {
            end -= 1;
        }
        let n = &n[..end];
        if n.is_empty() {
            continue;
        }
        if seen_vcl && starts_au(codec, n) {
            aus.push(std::mem::replace(&mut cur, AccessUnit { data: Vec::new(), keyframe: false }));
            seen_vcl = false;
        }
        if is_vcl(codec, n) {
            seen_vcl = true;
        }
        if is_keyframe_nal(codec, n) {
            cur.keyframe = true;
        }
        cur.data.extend_from_slice(&[0, 0, 0, 1]);
        cur.data.extend_from_slice(n);
    }
    if !cur.data.is_empty() {
        aus.push(cur);
    }
    aus
}

/// Parse `chroma_format_idc` and `bit_depth_luma` from the first HEVC SPS, if present.
/// Lightweight (handles the common profile_tier_level layout with no sub-layers).
pub fn hevc_sps_info(data: &[u8]) -> Option<(u32, u32, u32, u32)> {
    let sps = nals(data).into_iter().find(|n| !n.is_empty() && hevc_type(n) == 33)?;
    let rbsp = unescape(&sps[2..]);
    let mut br = BitReader::new(&rbsp);
    br.skip(4); // sps_video_parameter_set_id
    let max_sub_layers_minus1 = br.bits(3)?;
    br.skip(1); // temporal_id_nesting
    // profile_tier_level(1, max_sub_layers_minus1)
    br.skip(2 + 1 + 5 + 32 + 4 + 43 + 1 + 8);
    let mut sub_profile = [false; 8];
    let mut sub_level = [false; 8];
    for i in 0..max_sub_layers_minus1 as usize {
        sub_profile[i] = br.bits(1)? == 1;
        sub_level[i] = br.bits(1)? == 1;
    }
    if max_sub_layers_minus1 > 0 {
        for _ in max_sub_layers_minus1..8 {
            br.skip(2);
        }
    }
    for i in 0..max_sub_layers_minus1 as usize {
        if sub_profile[i] {
            br.skip(88);
        }
        if sub_level[i] {
            br.skip(8);
        }
    }
    br.ue()?; // sps_seq_parameter_set_id
    let chroma = br.ue()?;
    if chroma == 3 {
        br.skip(1);
    }
    let w = br.ue()?;
    let h = br.ue()?;
    if br.bits(1)? == 1 {
        br.ue()?;
        br.ue()?;
        br.ue()?;
        br.ue()?;
    }
    let bd = br.ue()? + 8;
    Some((chroma, bd, w, h))
}

fn unescape(d: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(d.len());
    let mut zeros = 0;
    for &b in d {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

struct BitReader<'a> {
    d: &'a [u8],
    pos: usize,
}

impl<'a> BitReader<'a> {
    fn new(d: &'a [u8]) -> Self {
        BitReader { d, pos: 0 }
    }
    fn skip(&mut self, n: usize) {
        self.pos += n;
    }
    fn bits(&mut self, n: usize) -> Option<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            let byte = *self.d.get(self.pos / 8)?;
            v = (v << 1) | ((byte >> (7 - self.pos % 8)) & 1) as u32;
            self.pos += 1;
        }
        Some(v)
    }
    fn ue(&mut self) -> Option<u32> {
        let mut lz = 0;
        while self.bits(1)? == 0 {
            lz += 1;
            if lz > 31 {
                return None;
            }
        }
        Some((1u32 << lz) - 1 + self.bits(lz)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_hevc_aus() {
        // VPS SPS PPS IDR(first slice) | TRAIL_R(first slice) TRAIL_R(second slice, flag 0) | TRAIL_R(first)
        let mut s = Vec::new();
        for nal in [
            vec![0x40, 0x01, 0xAA],
            vec![0x42, 0x01, 0xBB],
            vec![0x44, 0x01, 0xCC],
            vec![0x26, 0x01, 0x80, 0x11], // IDR_W_RADL (19)
            vec![0x02, 0x01, 0x80, 0x22], // TRAIL_R first slice
            vec![0x02, 0x01, 0x00, 0x33], // TRAIL_R continuation
            vec![0x02, 0x01, 0x80, 0x44],
        ] {
            s.extend_from_slice(&[0, 0, 1]);
            s.extend_from_slice(&nal);
        }
        let aus = split_access_units(Codec::Hevc, &s);
        assert_eq!(aus.len(), 3);
        assert!(aus[0].keyframe && !aus[1].keyframe && !aus[2].keyframe);
        assert_eq!(nals(&aus[0].data).len(), 4);
        assert_eq!(nals(&aus[1].data).len(), 2);
        assert_eq!(&aus[0].data[..5], &[0, 0, 0, 1, 0x40]);
    }

    #[test]
    fn splits_h264_aus() {
        let mut s = Vec::new();
        for nal in [vec![0x67, 1], vec![0x68, 2], vec![0x65, 0x88], vec![0x41, 0x9A], vec![0x41, 0x9B]] {
            s.extend_from_slice(&[0, 0, 0, 1]);
            s.extend_from_slice(&nal);
        }
        let aus = split_access_units(Codec::H264, &s);
        assert_eq!(aus.len(), 3);
        assert!(aus[0].keyframe);
    }
}
