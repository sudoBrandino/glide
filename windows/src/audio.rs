//! Audio jitter buffer (docs/PROTOCOL.md §3.2). Platform independent and unit-tested; the WASAPI
//! output that drains it lives in `win/audio.rs`.
//!
//! Network side `push`es AudioFrames (s16le interleaved) as they arrive; the device side `pull`s
//! whatever the output device wants. The buffer:
//! - primes to a target level (default 30 ms) before playing, with a short fade-in;
//! - holds that level against clock drift and arrival jitter: a smoothed (≈1 s) level estimate
//!   that leaves a ±8 ms dead band starts a gentle resample (±0.2 %, cubic interpolation) that
//!   runs until the level is back at target; inside the band the output is bit-exact;
//! - on underrun plays silence, raises the target 10 ms (max 120 ms) and re-primes; the target
//!   decays back 5 ms per 20 s without underruns. If the audio that eventually arrives starts well
//!   after where the old audio ended (capture timestamps jump), the source simply paused (the
//!   Mac sends nothing while silent): that is counted as a pause and the target bump is undone;
//! - drops the oldest audio if it ever holds more than target + 60 ms (e.g. after a stall),
//!   so latency is always bounded.

use std::collections::VecDeque;

#[derive(Debug, Clone, Copy)]
pub struct JitterParams {
    pub target_ms: f64,
    pub max_target_ms: f64,
    pub underrun_step_ms: f64,
    pub decay_after_s: f64,
    pub decay_step_ms: f64,
    pub deadband_ms: f64,
    pub max_ratio_dev: f64,
    pub trim_excess_ms: f64,
    pub ema_tau_s: f64,
    pub fade_ms: f64,
}

impl Default for JitterParams {
    fn default() -> Self {
        JitterParams {
            target_ms: 30.0,
            max_target_ms: 120.0,
            underrun_step_ms: 10.0,
            decay_after_s: 20.0,
            decay_step_ms: 5.0,
            deadband_ms: 8.0,
            max_ratio_dev: 0.002,
            trim_excess_ms: 60.0,
            ema_tau_s: 1.0,
            fade_ms: 3.0,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct JitterStats {
    /// Frames (samples per channel) received / played (silence excluded).
    pub frames_in: u64,
    pub frames_out: u64,
    pub underruns: u64,
    /// Times the buffer overflowed and old audio was dropped, and how many frames.
    pub trims: u64,
    pub trimmed_frames: u64,
    /// AudioFrames missing according to `seq` (dropped by the host).
    pub lost_packets: u64,
    pub malformed: u64,
    /// Output frames produced while resampling (drift correction active).
    pub corrected_frames: u64,
    /// Buffer ran dry because the host stopped sending (silence), not because audio was late.
    pub pauses: u64,
}

pub struct JitterBuffer {
    p: JitterParams,
    rate: u32,
    channels: usize,
    /// Interleaved f32 samples, oldest first.
    q: VecDeque<f32>,
    /// Last frame consumed (left neighbour for interpolation).
    prev: Vec<f32>,
    primed: bool,
    target: f64, // frames
    ema: f64,    // smoothed level, frames
    /// Fractional read position (frames) relative to the front of `q`; 0 <= pos < 1 between pulls.
    pos: f64,
    /// Drift correction in progress: +1 = playing faster (draining), -1 = slower.
    correcting: i8,
    /// Back at target: keep resampling until the read position lands on a whole frame, then stop
    /// (so returning to bit-exact passthrough never jumps).
    settling: bool,
    fade_left: usize,
    expected_seq: Option<u32>,
    frames_since_adjust: u64,
    /// (absolute frame index, host timestamp µs) of each pushed packet's first frame.
    markers: VecDeque<(u64, u64)>,
    head_abs: u64,
    tail_abs: u64,
    /// Host timestamp just past the last pushed sample.
    end_ts_us: Option<u64>,
    /// Target increase applied by the last underrun, until the next push classifies it.
    pending_bump: Option<f64>,
    pub stats: JitterStats,
}

/// A gap in capture timestamps larger than this after an underrun means the source paused.
const PAUSE_GAP_US: u64 = 20_000;

/// Catmull-Rom cubic between p1 (t=0) and p2 (t=1). Exact for linear signals.
#[inline]
pub fn cubic(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) -> f32 {
    let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
    let b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
    let c = -0.5 * p0 + 0.5 * p2;
    ((a * t + b) * t + c) * t + p1
}

impl JitterBuffer {
    pub fn new(rate: u32, channels: usize, p: JitterParams) -> JitterBuffer {
        let mut jb = JitterBuffer {
            p,
            rate: 0,
            channels: 0,
            q: VecDeque::new(),
            prev: Vec::new(),
            primed: false,
            target: 0.0,
            ema: 0.0,
            pos: 0.0,
            correcting: 0,
            settling: false,
            fade_left: 0,
            expected_seq: None,
            frames_since_adjust: 0,
            markers: VecDeque::new(),
            head_abs: 0,
            tail_abs: 0,
            end_ts_us: None,
            pending_bump: None,
            stats: JitterStats::default(),
        };
        jb.reset(rate, channels);
        jb
    }

    /// Start a new stream (AudioConfig): flush everything, keep the adaptive target.
    pub fn reset(&mut self, rate: u32, channels: usize) {
        let keep_target = self.rate == rate && self.target > 0.0;
        let target = if keep_target { self.target } else { self.ms_to_frames_at(self.p.target_ms, rate) };
        self.rate = rate;
        self.channels = channels;
        self.q.clear();
        self.prev = vec![0.0; channels];
        self.primed = false;
        self.target = target;
        self.ema = 0.0;
        self.pos = 0.0;
        self.correcting = 0;
        self.settling = false;
        self.fade_left = 0;
        self.expected_seq = None;
        self.frames_since_adjust = 0;
        self.markers.clear();
        self.head_abs = 0;
        self.tail_abs = 0;
        self.end_ts_us = None;
        self.pending_bump = None;
    }

    fn ms_to_frames_at(&self, ms: f64, rate: u32) -> f64 {
        ms * rate as f64 / 1000.0
    }
    fn ms(&self, frames: f64) -> f64 {
        if self.rate == 0 { 0.0 } else { frames * 1000.0 / self.rate as f64 }
    }

    pub fn rate(&self) -> u32 {
        self.rate
    }
    pub fn channels(&self) -> usize {
        self.channels
    }
    fn avail(&self) -> usize {
        self.q.len().checked_div(self.channels).unwrap_or(0)
    }
    /// Buffered audio not yet played, in ms.
    pub fn level_ms(&self) -> f64 {
        self.ms(self.avail() as f64 - self.pos)
    }
    pub fn target_ms(&self) -> f64 {
        self.ms(self.target)
    }
    pub fn smoothed_level_ms(&self) -> f64 {
        self.ms(self.ema)
    }
    pub fn is_playing(&self) -> bool {
        self.primed
    }
    /// Current playback rate factor (1.0 = bit-exact passthrough).
    pub fn ratio(&self) -> f64 {
        1.0 + self.correcting as f64 * self.p.max_ratio_dev
    }

    /// Host capture timestamp (µs) of the next frame to be played, if known.
    pub fn next_play_ts_us(&self) -> Option<u64> {
        let &(abs, ts) = self.markers.front()?;
        let off = (self.head_abs as f64 + self.pos - abs as f64).max(0.0);
        Some(ts + (off * 1e6 / self.rate.max(1) as f64) as u64)
    }

    /// Add one AudioFrame payload (interleaved s16le). Returns false if malformed.
    pub fn push(&mut self, seq: u32, capture_time_us: u64, pcm: &[u8]) -> bool {
        let ch = self.channels;
        if ch == 0 || !pcm.len().is_multiple_of(2 * ch) {
            self.stats.malformed += 1;
            return false;
        }
        if let Some(e) = self.expected_seq {
            let d = seq.wrapping_sub(e);
            if d != 0 && d < 1 << 31 {
                self.stats.lost_packets += d as u64;
            }
        }
        self.expected_seq = Some(seq.wrapping_add(1));
        let n = pcm.len() / (2 * ch);
        if n == 0 {
            return true;
        }
        if let Some(bump) = self.pending_bump.take() {
            if self.end_ts_us.is_some_and(|end| capture_time_us > end.saturating_add(PAUSE_GAP_US)) {
                // The host went quiet; nothing arrived late. Undo the underrun's target bump.
                self.target -= bump;
                self.stats.underruns -= 1;
                self.stats.pauses += 1;
            }
        }
        // Host-supplied timestamp: saturate rather than overflow.
        self.end_ts_us = Some(capture_time_us.saturating_add(n as u64 * 1_000_000 / self.rate.max(1) as u64));
        self.q.extend(pcm.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0));
        self.markers.push_back((self.tail_abs, capture_time_us));
        self.tail_abs += n as u64;
        self.stats.frames_in += n as u64;

        // Bound latency: way over target (stall then burst, or the device isn't pulling) -> drop
        // the oldest audio down to the target.
        let excess = self.ms_to_frames_at(self.p.trim_excess_ms, self.rate);
        let level = self.avail() as f64 - self.pos;
        if level > self.target + excess {
            let drop = (level - self.target).floor() as usize;
            self.consume(drop);
            self.pos = 0.0;
            self.ema = self.avail() as f64;
            self.correcting = 0;
            self.settling = false;
            self.stats.trims += 1;
            self.stats.trimmed_frames += drop as u64;
        }
        true
    }

    /// Remove `n` frames from the front (keeping the last one as the interpolation neighbour).
    fn consume(&mut self, n: usize) {
        let n = n.min(self.avail());
        if n == 0 {
            return;
        }
        let ch = self.channels;
        for c in 0..ch {
            self.prev[c] = self.q[(n - 1) * ch + c];
        }
        self.q.drain(..n * ch);
        self.head_abs += n as u64;
        while self.markers.len() >= 2 && self.markers[1].0 <= self.head_abs {
            self.markers.pop_front();
        }
    }

    /// Fill `out` (interleaved, `channels` per frame) with the next audio; silence while priming.
    pub fn pull(&mut self, out: &mut [f32]) {
        let ch = self.channels;
        if ch == 0 {
            out.fill(0.0);
            return;
        }
        let frames = out.len() / ch;
        let level = self.avail() as f64 - self.pos;
        if !self.primed {
            if level + 0.5 >= self.target && level >= 1.0 {
                self.primed = true;
                self.ema = level;
                self.correcting = 0;
                self.settling = false;
                self.fade_left = self.ms_to_frames_at(self.p.fade_ms, self.rate) as usize;
                self.pos = 0.0;
            } else {
                out.fill(0.0);
                return;
            }
        }

        // Smoothed level + dead-band drift control (hysteresis: correct until back at target).
        let alpha = (frames as f64 / (self.rate as f64 * self.p.ema_tau_s)).min(1.0);
        self.ema += alpha * (level - self.ema);
        let err = self.ema - self.target;
        let band = self.ms_to_frames_at(self.p.deadband_ms, self.rate);
        if self.correcting == 0 && err.abs() > band {
            self.correcting = if err > 0.0 { 1 } else { -1 };
        } else if self.correcting != 0 && err * self.correcting as f64 <= 0.0 {
            self.settling = true;
        }
        let mut ratio = self.ratio();
        let snap = self.p.max_ratio_dev * 1.5;

        let avail = self.avail();
        let mut produced = 0;
        for i in 0..frames {
            let idx = self.pos.floor() as usize;
            let t = (self.pos - idx as f64) as f32;
            if (t == 0.0 && idx >= avail) || (t != 0.0 && idx + 1 >= avail) {
                break;
            }
            let o = &mut out[i * ch..(i + 1) * ch];
            if t == 0.0 {
                for (c, v) in o.iter_mut().enumerate() {
                    *v = self.q[idx * ch + c];
                }
            } else {
                for (c, v) in o.iter_mut().enumerate() {
                    let p1 = self.q[idx * ch + c];
                    let p2 = self.q[(idx + 1) * ch + c];
                    let p0 = if idx == 0 { self.prev[c] } else { self.q[(idx - 1) * ch + c] };
                    let p3 = if idx + 2 < avail { self.q[(idx + 2) * ch + c] } else { p2 };
                    *v = cubic(p0, p1, p2, p3, t);
                }
            }
            self.pos += ratio;
            produced += 1;
            if ratio != 1.0 {
                self.stats.corrected_frames += 1;
                if self.settling {
                    let frac = self.pos - self.pos.floor();
                    if frac < snap || frac > 1.0 - snap {
                        self.pos = self.pos.round();
                        self.correcting = 0;
                        self.settling = false;
                        ratio = 1.0;
                    }
                }
            }
        }
        let whole = self.pos.floor();
        self.consume(whole as usize);
        self.pos -= whole;

        if self.fade_left > 0 {
            let total = self.ms_to_frames_at(self.p.fade_ms, self.rate).max(1.0);
            let start = total as usize - self.fade_left;
            for i in 0..produced.min(self.fade_left) {
                let g = ((start + i) as f32 + 1.0) / total as f32;
                for s in &mut out[i * ch..(i + 1) * ch] {
                    *s *= g;
                }
            }
            self.fade_left -= produced.min(self.fade_left);
        }
        self.stats.frames_out += produced as u64;

        if produced < frames {
            // Underrun: silence for the rest, re-prime at a higher target.
            out[produced * ch..].fill(0.0);
            self.stats.underruns += 1;
            self.primed = false;
            self.correcting = 0;
            self.settling = false;
            self.pos = 0.0;
            let max = self.ms_to_frames_at(self.p.max_target_ms, self.rate);
            let old = self.target;
            self.target = (self.target + self.ms_to_frames_at(self.p.underrun_step_ms, self.rate)).min(max);
            self.pending_bump = Some(self.target - old);
            self.frames_since_adjust = 0;
            return;
        }
        // Slowly give back latency after a quiet period.
        self.frames_since_adjust += frames as u64;
        let base = self.ms_to_frames_at(self.p.target_ms, self.rate);
        if self.target > base && self.frames_since_adjust as f64 >= self.p.decay_after_s * self.rate as f64 {
            self.target = (self.target - self.ms_to_frames_at(self.p.decay_step_ms, self.rate)).max(base);
            self.frames_since_adjust = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 48_000;

    fn pcm(samples: &[i16]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    /// Stereo test signal: L = 440 Hz sine, R = -L, amplitude 0.5.
    struct Sine {
        n: u64,
    }
    impl Sine {
        fn next(&mut self, frames: usize) -> Vec<i16> {
            let mut v = Vec::with_capacity(frames * 2);
            for _ in 0..frames {
                let x = (self.n as f64 * 2.0 * std::f64::consts::PI * 440.0 / RATE as f64).sin() * 0.5;
                let s = (x * 32767.0).round() as i16;
                v.push(s);
                v.push(-s);
                self.n += 1;
            }
            v
        }
    }

    fn jb() -> JitterBuffer {
        JitterBuffer::new(RATE, 2, JitterParams::default())
    }

    #[test]
    fn primes_then_plays_bit_exact() {
        let mut j = jb();
        let mut src = Sine { n: 0 };
        let mut sent: Vec<i16> = Vec::new();
        let mut out = vec![0f32; 480 * 2];
        // 20 ms buffered < 30 ms target: silence.
        for s in 0..2 {
            let x = src.next(480);
            sent.extend(&x);
            j.push(s, s as u64 * 10_000, &pcm(&x));
        }
        j.pull(&mut out);
        assert!(out.iter().all(|&v| v == 0.0));
        assert!(!j.is_playing());
        let x = src.next(480);
        sent.extend(&x);
        j.push(2, 20_000, &pcm(&x));
        assert!((j.level_ms() - 30.0).abs() < 1e-9);
        assert_eq!(j.next_play_ts_us(), Some(0));
        // Steady state: push 10 ms, pull 10 ms; output = input delayed by the 30 ms prime.
        let mut got: Vec<f32> = Vec::new();
        for s in 3..300u32 {
            j.pull(&mut out);
            got.extend(&out);
            let x = src.next(480);
            sent.extend(&x);
            j.push(s, s as u64 * 10_000, &pcm(&x));
        }
        assert_eq!(j.stats.underruns, 0);
        assert_eq!(j.stats.corrected_frames, 0, "no resampling inside the dead band");
        let fade = (3.0 * RATE as f64 / 1000.0) as usize;
        for (i, (&g, &s)) in got.iter().zip(sent.iter()).enumerate() {
            if i / 2 >= fade {
                assert_eq!(g, s as f32 / 32768.0, "sample {i}");
            } else {
                assert!(g.abs() <= (s as f32 / 32768.0).abs() + 1e-6, "fade-in sample {i}");
            }
        }
        assert_eq!(j.next_play_ts_us(), Some(297 * 10_000));
        assert!((j.level_ms() - 30.0).abs() < 1e-9);
    }

    #[test]
    fn underrun_raises_target_and_reprimes_then_decays() {
        let mut j = jb();
        let mut src = Sine { n: 0 };
        let mut out = vec![0f32; 480 * 2];
        for s in 0..3 {
            j.push(s, 0, &pcm(&src.next(480)));
        }
        for _ in 0..3 {
            j.pull(&mut out);
        }
        assert_eq!(j.stats.underruns, 0);
        j.pull(&mut out); // nothing left
        assert_eq!(j.stats.underruns, 1);
        assert!(out.iter().all(|&v| v == 0.0));
        assert!(!j.is_playing());
        assert!((j.target_ms() - 40.0).abs() < 1e-9);
        // Re-primes only at the new 40 ms target.
        for s in 3..6 {
            j.push(s, 0, &pcm(&src.next(480)));
        }
        j.pull(&mut out);
        assert!(!j.is_playing() && out.iter().all(|&v| v == 0.0));
        j.push(6, 0, &pcm(&src.next(480)));
        j.pull(&mut out);
        assert!(j.is_playing());
        // 20 s without underruns gives 5 ms back (never below the base target).
        for s in 7..(7 + 2100) {
            j.push(s, 0, &pcm(&src.next(480)));
            j.pull(&mut out);
        }
        assert_eq!(j.stats.underruns, 1);
        assert!((j.target_ms() - 35.0).abs() < 1e-9, "{}", j.target_ms());
        for s in 2107..(2107 + 6000) {
            j.push(s, 0, &pcm(&src.next(480)));
            j.pull(&mut out);
        }
        assert!((j.target_ms() - 30.0).abs() < 1e-9);
        // Target is capped.
        let mut k = jb();
        for _ in 0..30 {
            k.pull(&mut out);
            k.push(0, 0, &pcm(&vec![1i16; 2 * 48 * 200]));
            while k.level_ms() > 0.0 {
                k.pull(&mut out);
            }
        }
        assert!((k.target_ms() - 120.0).abs() < 1e-9);
    }

    /// The Mac sends nothing while silent: a source pause must not ratchet the latency target up,
    /// but late audio (continuous timestamps) must.
    #[test]
    fn source_pause_is_not_an_underrun() {
        let mut j = jb();
        let mut src = Sine { n: 0 };
        let mut out = vec![0f32; 480 * 2];
        let mut ts = 0u64;
        let mut seq = 0u32;
        let mut feed = |j: &mut JitterBuffer, ts: &mut u64, k: usize| {
            for _ in 0..k {
                j.push(seq, *ts, &pcm(&src.next(480)));
                seq += 1;
                *ts += 10_000;
            }
        };
        feed(&mut j, &mut ts, 3);
        for _ in 0..3 {
            j.pull(&mut out);
        }
        j.pull(&mut out); // drained: provisional underrun
        assert_eq!(j.stats.underruns, 1);
        // Sound resumes 2 s later (timestamps jump): a pause, target back to 30 ms.
        ts += 2_000_000;
        feed(&mut j, &mut ts, 3);
        assert_eq!((j.stats.underruns, j.stats.pauses), (0, 1));
        assert!((j.target_ms() - 30.0).abs() < 1e-9);
        j.pull(&mut out);
        assert!(j.is_playing());
        for _ in 0..2 {
            j.pull(&mut out);
        }
        j.pull(&mut out); // drained again...
        // ...and the audio arrives late but continuous: a real underrun, target stays raised.
        feed(&mut j, &mut ts, 4);
        assert_eq!((j.stats.underruns, j.stats.pauses), (1, 1));
        assert!((j.target_ms() - 40.0).abs() < 1e-9);
    }

    #[test]
    fn overflow_trims_to_target() {
        let mut j = jb();
        let mut src = Sine { n: 0 };
        // A 200 ms burst (e.g. after a network stall).
        for s in 0..20 {
            j.push(s, s as u64 * 10_000, &pcm(&src.next(480)));
        }
        assert!(j.stats.trims >= 1);
        assert!(j.level_ms() <= 90.0 + 1e-9);
        // The kept audio is the newest; its timestamps follow.
        let lvl = j.level_ms();
        let ts = j.next_play_ts_us().unwrap();
        assert!(((200_000.0 - lvl * 1000.0) - ts as f64).abs() < 30.0, "ts {ts} level {lvl}");
        // Bounded regardless of how much arrives while the device isn't pulling.
        for s in 20..500 {
            j.push(s, 0, &pcm(&src.next(480)));
            assert!(j.level_ms() <= 90.0 + 1e-9);
        }
        assert_eq!(j.stats.frames_in, 500 * 480);
        assert_eq!(j.stats.frames_in - j.stats.trimmed_frames, (j.level_ms() * 48.0).round() as u64);
    }

    #[test]
    fn seq_gaps_and_malformed() {
        let mut j = jb();
        assert!(j.push(10, 0, &pcm(&[1, 2])));
        assert!(j.push(11, 0, &pcm(&[1, 2])));
        assert!(j.push(15, 0, &pcm(&[1, 2]))); // 12..14 lost
        assert!(j.push(u32::MAX, 0, &pcm(&[1, 2]))); // older/reordered: not counted as a gap
        assert!(j.push(0, 0, &pcm(&[1, 2]))); // wraps
        assert_eq!(j.stats.lost_packets, 3);
        assert!(!j.push(1, 0, &[1, 2, 3])); // not a multiple of 2*channels
        assert_eq!(j.stats.malformed, 1);
        assert!(j.push(1, 0, &[]));
        assert_eq!(j.stats.frames_in, 5);
    }

    #[test]
    fn reset_flushes_and_changes_format() {
        let mut j = jb();
        j.push(0, 0, &pcm(&[5; 2 * 2000]));
        j.reset(44_100, 1);
        assert_eq!(j.level_ms(), 0.0);
        assert_eq!((j.rate(), j.channels()), (44_100, 1));
        assert!((j.target_ms() - 30.0).abs() < 1e-9);
        assert_eq!(j.next_play_ts_us(), None);
        // seq tracking restarts too
        j.push(100, 0, &pcm(&[1]));
        assert_eq!(j.stats.lost_packets, 0);
    }

    /// Drift between the host clock and the PC's audio clock is absorbed by gentle resampling,
    /// without clicks, without underruns or trims, and with latency bounded near the target.
    #[test]
    fn absorbs_clock_drift_both_ways() {
        for ppm in [-1000.0f64, -300.0, 300.0, 1000.0] {
            let mut j = jb();
            let mut src = Sine { n: 0 };
            let mut owed = 0.0f64;
            let mut out = vec![0f32; 480 * 2];
            let mut prev: Option<f32> = None;
            let mut max_step = 0f32;
            let (mut lo, mut hi) = (f64::MAX, f64::MIN);
            for tick in 0..20_000u32 {
                // producer: 10 ms of host time = 480 * (1 + ppm) device frames
                owed += 480.0 * (1.0 + ppm * 1e-6);
                let n = owed.floor() as usize;
                owed -= n as f64;
                j.push(tick, 0, &pcm(&src.next(n)));
                if tick > 500 {
                    // level as the device sees it (before its pull)
                    lo = lo.min(j.level_ms());
                    hi = hi.max(j.level_ms());
                }
                j.pull(&mut out);
                if tick > 500 {
                    for f in out.chunks(2) {
                        if let Some(p) = prev {
                            max_step = max_step.max((f[0] - p).abs());
                        }
                        prev = Some(f[0]);
                    }
                } else if j.is_playing() {
                    prev = out.chunks(2).last().map(|f| f[0]);
                }
            }
            eprintln!(
                "drift {ppm:+} ppm: level {lo:.1}..{hi:.1} ms, resampled {:.1}% of the time, max step {max_step:.5}",
                100.0 * j.stats.corrected_frames as f64 / j.stats.frames_out as f64
            );
            assert_eq!(j.stats.underruns, 0, "ppm {ppm}");
            assert_eq!(j.stats.trims, 0, "ppm {ppm}");
            assert!(j.stats.corrected_frames > 0, "ppm {ppm}: drift must be corrected");
            // Mostly bit-exact: resampling only a fraction of the time.
            let frac = j.stats.corrected_frames as f64 / j.stats.frames_out as f64;
            assert!(frac < (ppm.abs() * 1e-6 / 0.002) * 1.6 + 0.02, "ppm {ppm}: corrected {frac:.3}");
            assert!(lo > 30.0 - 8.0 - 6.0 && hi < 30.0 + 8.0 + 6.0, "ppm {ppm}: level {lo:.1}..{hi:.1} ms");
            // Max slope of a 0.5-amplitude 440 Hz sine is 2π·440/48000·0.5 ≈ 0.0288/sample.
            assert!(max_step < 0.0288 * 1.01, "ppm {ppm}: click, step {max_step}");
        }
    }

    /// ScreenCaptureKit-like bursts (1024 frames every 21.3 ms, split into 3 packets) against a
    /// 10 ms device period, with arrival jitter: no underruns at the default target.
    #[test]
    fn bursty_jittery_arrival() {
        let mut j = jb();
        let mut src = Sine { n: 0 };
        let mut out = vec![0f32; 480 * 2];
        let mut rng = 0x2545F4914F6CDD1Du64;
        let mut rand = move || {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            (rng % 1000) as f64 / 1000.0
        };
        // Event simulation in µs: capture bursts arrive at k*21333 + jitter(0..3 ms); device pulls every 10 ms.
        let mut next_burst = 0.0f64;
        let mut next_pull = 0.0f64;
        let mut seq = 0u32;
        let mut pending: Vec<(f64, Vec<i16>)> = Vec::new();
        let (mut lo, mut hi) = (f64::MAX, f64::MIN);
        for _ in 0..100_000 {
            if next_burst <= next_pull {
                let data = src.next(1024);
                pending.push((next_burst + 21_333.0 + rand() * 3000.0, data));
                next_burst += 1024.0 / 48.0 * 1000.0;
            } else {
                pending.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
                while pending.first().is_some_and(|p| p.0 <= next_pull) {
                    let (_, d) = pending.remove(0);
                    for r in [0..342usize, 342..683, 683..1024] {
                        j.push(seq, 0, &pcm(&d[r.start * 2..r.end * 2]));
                        seq += 1;
                    }
                }
                j.pull(&mut out);
                if next_pull > 5e6 {
                    lo = lo.min(j.level_ms());
                    hi = hi.max(j.level_ms());
                }
                next_pull += 10_000.0;
            }
        }
        assert!(next_pull > 30e6);
        assert_eq!(j.stats.underruns, 0);
        assert_eq!(j.stats.trims, 0);
        assert!(hi - lo < 45.0 && lo > 5.0, "level {lo:.1}..{hi:.1}");
    }

    #[test]
    fn cubic_interpolation() {
        assert_eq!(cubic(1.0, 2.0, 3.0, 4.0, 0.0), 2.0);
        assert!((cubic(1.0, 2.0, 3.0, 4.0, 1.0) - 3.0).abs() < 1e-6);
        assert!((cubic(1.0, 2.0, 3.0, 4.0, 0.25) - 2.25).abs() < 1e-6); // linear in, linear out
        assert!((cubic(0.0, 1.0, 1.0, 0.0, 0.5) - 1.125).abs() < 1e-6);
    }
}
