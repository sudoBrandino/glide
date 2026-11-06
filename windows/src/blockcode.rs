//! Machine-readable clock "block code" for glass-to-glass latency tests (docs/LATENCY.md).
//!
//! A test pattern on the host (glide-probe `--pattern`, or `tools/mock_host.py --latency-pattern`)
//! draws its host clock every frame as one row of square cells, white = 1, black = 0, on a black
//! quiet zone (≥ 2 cells on every side):
//!
//! ```text
//! sync 10110010 | value (32 bits, MSB first) | kind (4) | counter (4) | CRC-8 (8)   = 56 cells
//! ```
//!
//! `value` is the low 32 bits of a host-clock time in µs (CLOCK_UPTIME_RAW on the Mac); the viewer
//! restores the high bits from its own clock estimate (`unwrap32`). `kind` says which instant the
//! value is (see `KIND_*`), `counter` increments per drawn frame. The CRC is CRC-8/SMBUS
//! (poly 0x07, init 0) over `[value big-endian (4 bytes), kind << 4 | counter]`.
//!
//! The pattern image is `(56 + 4) × cell` wide and `4 × cell` tall: one black cell row, a code
//! strip two cells tall, one black cell row. Cells survive HEVC 4:2:0 at any sane bitrate when
//! they are ≥ 4 px; the reference pattern uses 8-point cells.
//!
//! The decoder finds the code anywhere in a luma image by run lengths (no fixed position, any
//! cell size from 2.5 to ~64 px), so the pattern window can sit anywhere on the host screen.

pub const SYNC: u8 = 0b1011_0010;
pub const CELLS: usize = 56;
/// Black cells around the code (each side).
pub const QUIET: usize = 2;
/// `value` = the time the frame was drawn.
pub const KIND_DRAW: u8 = 0;
/// `value` = the display link's target timestamp (when the frame is due on the host display).
pub const KIND_TARGET: u8 = 1;
/// `value` = generation time of a synthetic frame (mock host; same instant as `capture_time_us`).
pub const KIND_FRAME: u8 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Code {
    pub value: u32,
    pub kind: u8,
    pub counter: u8,
}

/// CRC-8/SMBUS: poly 0x07, init 0, no reflection, no final xor ("123456789" → 0xF4).
pub fn crc8(data: &[u8]) -> u8 {
    let mut c = 0u8;
    for &b in data {
        c ^= b;
        for _ in 0..8 {
            c = if c & 0x80 != 0 { (c << 1) ^ 0x07 } else { c << 1 };
        }
    }
    c
}

impl Code {
    fn payload(&self) -> [u8; 5] {
        let v = self.value.to_be_bytes();
        [v[0], v[1], v[2], v[3], (self.kind & 15) << 4 | (self.counter & 15)]
    }

    /// The 56 cells, left to right.
    pub fn bits(&self) -> [bool; CELLS] {
        let p = self.payload();
        let mut bytes = [0u8; 7];
        bytes[0] = SYNC;
        bytes[1..6].copy_from_slice(&p);
        bytes[6] = crc8(&p);
        let mut out = [false; CELLS];
        for (i, o) in out.iter_mut().enumerate() {
            *o = bytes[i / 8] >> (7 - i % 8) & 1 == 1;
        }
        out
    }

    /// Cells as a '0'/'1' string (reference vectors).
    pub fn bit_string(&self) -> String {
        self.bits().iter().map(|&b| if b { '1' } else { '0' }).collect()
    }

    /// Parse 56 cells; None unless the sync byte and the CRC match.
    pub fn from_bits(b: &[bool]) -> Option<Code> {
        if b.len() < CELLS {
            return None;
        }
        let mut bytes = [0u8; 7];
        for (i, &bit) in b[..CELLS].iter().enumerate() {
            bytes[i / 8] |= (bit as u8) << (7 - i % 8);
        }
        if bytes[0] != SYNC || crc8(&bytes[1..6]) != bytes[6] {
            return None;
        }
        Some(Code {
            value: u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]),
            kind: bytes[5] >> 4,
            counter: bytes[5] & 15,
        })
    }
}

/// Full host time from the low 32 bits: the candidate nearest `host_now` (valid while the
/// pattern is less than ~35 minutes old).
pub fn unwrap32(low: u32, host_now: u64) -> u64 {
    let d = (host_now as u32).wrapping_sub(low) as i32 as i64;
    (host_now as i64 - d).max(0) as u64
}

/// Render the pattern as an 8-bit luma image (0 / 255) with `cell`-pixel cells.
/// Returns (pixels, width, height).
pub fn render(code: &Code, cell: usize) -> (Vec<u8>, usize, usize) {
    let w = (CELLS + 2 * QUIET) * cell;
    let h = 4 * cell;
    let mut img = vec![0u8; w * h];
    for (i, &bit) in code.bits().iter().enumerate() {
        if !bit {
            continue;
        }
        let x0 = (QUIET + i) * cell;
        for y in cell..3 * cell {
            img[y * w + x0..y * w + x0 + cell].fill(255);
        }
    }
    (img, w, h)
}

/// Where a code was found: left edge of the first sync cell, the row through the strip's middle,
/// and the cell size, in image pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Loc {
    pub x0: f32,
    pub y: usize,
    pub cell: f32,
}

const THRESH: u8 = 128;

/// Decode one row of luma pixels: find the sync run pattern (quiet ≥ 1.5 cells, then
/// W1 B1 W2 B2 W1 cells) and sample all 56 cells at their centers.
pub fn scan_row(row: &[u8]) -> Option<(f32, f32, Code)> {
    if row.len() < CELLS * 3 {
        return None;
    }
    // Run-length encode.
    let mut runs: Vec<(usize, usize, bool)> = Vec::new();
    let mut start = 0;
    let mut cur = row[0] >= THRESH;
    for (x, &p) in row.iter().enumerate().skip(1) {
        let v = p >= THRESH;
        if v != cur {
            runs.push((start, x - start, cur));
            start = x;
            cur = v;
        }
    }
    runs.push((start, row.len() - start, cur));
    const EXP: [f32; 5] = [1.0, 1.0, 2.0, 2.0, 1.0];
    for i in 0..runs.len().saturating_sub(6) {
        let (_, quiet, qv) = runs[i];
        if qv || !runs[i + 1].2 {
            continue;
        }
        let r = &runs[i + 1..i + 6];
        let span = r[4].0 + r[4].1 - r[0].0;
        let c = span as f32 / 7.0;
        if !(2.5..=64.0).contains(&c) || (quiet as f32) < 1.5 * c {
            continue;
        }
        let fits = r.iter().zip(EXP).all(|(&(_, len, _), e)| (len as f32 - e * c).abs() <= (0.35 * c * e).max(1.5));
        if !fits {
            continue;
        }
        let x0 = r[0].0 as f32;
        if let Some(code) = sample(row, x0, c) {
            return Some((x0, c, code));
        }
    }
    None
}

/// Sample the 56 cells of a row given the code's left edge and cell size.
pub fn sample(row: &[u8], x0: f32, cell: f32) -> Option<Code> {
    let mut bits = [false; CELLS];
    for (i, b) in bits.iter_mut().enumerate() {
        let xc = x0 + (i as f32 + 0.5) * cell;
        let x = xc.round() as isize;
        if x < 0 || x as usize >= row.len() {
            return None;
        }
        let lo = (x - 1).max(0) as usize;
        let hi = (x as usize + 1).min(row.len() - 1);
        let sum: u32 = row[lo..=hi].iter().map(|&p| p as u32).sum();
        *b = sum / (hi - lo + 1) as u32 >= THRESH as u32;
    }
    Code::from_bits(&bits)
}

/// Find the code anywhere in a luma image (`stride` bytes per row). Scans every second row,
/// and reports the middle row of the band where the code decodes.
pub fn locate(luma: &[u8], w: usize, h: usize, stride: usize) -> Option<(Loc, Code)> {
    let row = |y: usize| &luma[y * stride..y * stride + w];
    let mut first: Option<(usize, f32, f32, Code)> = None;
    let mut last_y = 0;
    for y in (0..h).step_by(2) {
        match scan_row(row(y)) {
            Some((x0, c, code)) => {
                if first.is_none() {
                    first = Some((y, x0, c, code));
                }
                last_y = y;
            }
            None if first.is_some() => break,
            None => {}
        }
    }
    let (y0, x0, c, code) = first?;
    let mid = (y0 + last_y) / 2;
    match scan_row(row(mid)) {
        Some((x, c2, code2)) => Some((Loc { x0: x, y: mid, cell: c2 }, code2)),
        None => Some((Loc { x0, y: y0, cell: c }, code)),
    }
}

/// Re-read a known location (a small readback around `loc`): tries the stored geometry first,
/// then a fresh sync search on the same row (the pattern may have moved horizontally).
pub fn read_at(row: &[u8], loc: &Loc, row_x0: usize) -> Option<Code> {
    sample(row, loc.x0 - row_x0 as f32, loc.cell).or_else(|| scan_row(row).map(|r| r.2))
}

/// Luma (8-bit) of an R10G10B10A2 pixel.
pub fn luma_rgb10a2(px: u32) -> u8 {
    let r = px & 0x3FF;
    let g = (px >> 10) & 0x3FF;
    let b = (px >> 20) & 0x3FF;
    ((r + 2 * g + b) >> 4) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shared reference vector: glide-selftest (Swift) and mock_host.py --selftest check the same
    /// string (docs/LATENCY.md).
    pub const REF: &str = "10110010000100100011010001010110011110000001010100111111";

    #[test]
    fn reference_bits_and_crc() {
        assert_eq!(crc8(b"123456789"), 0xF4);
        let c = Code { value: 0x1234_5678, kind: 1, counter: 5 };
        assert_eq!(c.bit_string(), REF);
        let bits: Vec<bool> = REF.chars().map(|ch| ch == '1').collect();
        assert_eq!(Code::from_bits(&bits), Some(c));
        let mut bad = bits.clone();
        bad[20] = !bad[20];
        assert_eq!(Code::from_bits(&bad), None);
        bad = bits.clone();
        bad[1] = true; // sync broken
        assert_eq!(Code::from_bits(&bad), None);
    }

    #[test]
    fn unwrap_picks_nearest() {
        assert_eq!(unwrap32(1000, 1500), 1000);
        let host_now = (7u64 << 32) + 100; // just after a wrap of the low bits
        let low = (u32::MAX - 50_000) as u32; // drawn 50 ms earlier, before the wrap
        assert_eq!(unwrap32(low, host_now), host_now - 50_101);
        assert_eq!(unwrap32(5, 3), 5); // slightly in the future also works
    }

    fn blur(img: &[u8], w: usize, h: usize) -> Vec<u8> {
        let mut out = img.to_vec();
        for y in 1..h - 1 {
            for x in 1..w - 1 {
                let mut s = 0u32;
                for dy in 0..3 {
                    for dx in 0..3 {
                        s += img[(y + dy - 1) * w + x + dx - 1] as u32;
                    }
                }
                out[y * w + x] = (s / 9) as u8;
            }
        }
        out
    }

    /// The pattern embedded at an arbitrary position in a large, busy frame, blurred and with
    /// noise (codec softening), is found and decoded; the middle row of the strip is reported.
    #[test]
    fn locate_in_frame() {
        for &cell in &[4usize, 8, 16] {
            let code = Code { value: 0xDEAD_BEEF, kind: KIND_TARGET, counter: 9 };
            let (pat, pw, ph) = render(&code, cell);
            let (w, h) = (1280usize, 720usize);
            let mut img = vec![0u8; w * h];
            // Busy background: diagonal stripes (contain runs, but no valid sync + CRC).
            for y in 0..h {
                for x in 0..w {
                    img[y * w + x] = if (x / 7 + y / 5) % 3 == 0 { 230 } else { 20 };
                }
            }
            let (ox, oy) = (123usize, 457usize);
            for y in 0..ph {
                img[(oy + y) * w + ox..(oy + y) * w + ox + pw].copy_from_slice(&pat[y * pw..(y + 1) * pw]);
            }
            let mut img = blur(&img, w, h);
            let mut seed = 99u32;
            for p in img.iter_mut() {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
                *p = (*p as i32 + (seed >> 16) as i32 % 31 - 15).clamp(0, 255) as u8;
            }
            let (loc, got) = locate(&img, w, h, w).expect("found");
            assert_eq!(got, code, "cell {cell}");
            assert!((loc.cell - cell as f32).abs() < 0.5, "cell {cell}: {loc:?}");
            assert!((loc.x0 - (ox + QUIET * cell) as f32).abs() <= 1.5, "cell {cell}: {loc:?}");
            let mid = oy + 2 * cell;
            assert!((loc.y as isize - mid as isize).abs() <= (cell / 2 + 2) as isize, "cell {cell}: {loc:?}");
            // Re-read from a small window around the location.
            let rx = (loc.x0 as usize).saturating_sub(2 * cell);
            let row = &img[loc.y * w + rx..loc.y * w + (rx + 60 * cell).min(w)];
            assert_eq!(read_at(row, &loc, rx), Some(code));
        }
    }

    #[test]
    fn non_integer_cells_and_no_false_positives() {
        // 1.5x scaled (e.g. a HiDPI pattern captured at a fractional scale).
        let code = Code { value: 42, kind: KIND_DRAW, counter: 0 };
        let (pat, pw, ph) = render(&code, 8);
        let (w, h) = (pw * 3 / 2, ph * 3 / 2);
        let img: Vec<u8> = (0..w * h).map(|i| pat[(i / w * 2 / 3) * pw + (i % w) * 2 / 3]).collect();
        assert_eq!(locate(&img, w, h, w).map(|r| r.1), Some(code));
        // Noise only: nothing found.
        let mut seed = 7u32;
        let noise: Vec<u8> = (0..640 * 64)
            .map(|_| {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
                if (seed >> 16) & 1 == 1 { 255 } else { 0 }
            })
            .collect();
        assert_eq!(locate(&noise, 640, 64, 640), None);
    }

    #[test]
    fn rgb10a2_luma() {
        assert_eq!(luma_rgb10a2(0x3FFF_FFFF), 255);
        assert_eq!(luma_rgb10a2(0), 0);
        assert_eq!(luma_rgb10a2(0x3FF << 10), 127);
    }
}
