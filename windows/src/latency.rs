//! Per-frame latency breakdown (docs/LATENCY.md). Platform independent.
//!
//! Joins, by `frame_id`, the host's `FrameTiming` stamps (§3.4: capture, capture callback,
//! encode submit/done, enqueued, sent — host clock) with the viewer's own stamps (receive,
//! decode start/done, canvas update, `Present()` call, and the vblank the present reached the
//! screen at — client clock). Host times are converted with the Ping/Pong clock estimate
//! (`net::ClockSync`). Finished frames go into a sliding window (p50s for the HUD and the
//! `LatencyReport`) and, optionally, into a full log for `--latency-test` / `--bench` reports.
//!
//! Stage definitions (all in ms):
//!
//! | stage | from → to | clock |
//! |---|---|---|
//! | `cap_to_callback` | SCK frame PTS → capture callback runs | host |
//! | `callback_to_submit` | callback → handed to the encoder (encoder busy / backpressure) | host |
//! | `encode` | encoder submit → encoder output | host |
//! | `host` | capture → encoded (sum of the three above) | host |
//! | `encoded_to_sent` | encoded → network stack accepted the record | host |
//! | `network` | host enqueued → viewer received + decrypted | synced |
//! | `queue` | received → decode start (render thread busy / batching) | viewer |
//! | `decode` | decode start → decoded (CPU-side; GPU work may still be queued) | viewer |
//! | `render` | decoded → `Present()` call (canvas update + frame-latency wait) | viewer |
//! | `scanout` | `Present()` → vblank at which it was displayed | viewer |
//! | `total` | capture → scan-out (→ `Present()` when scan-out is unknown) | synced |

use crate::net::ClockSync;
use crate::protocol::{FrameTiming, LatencyReport, FRAME_FLAG_REFRESH, FRAME_FLAG_SHARP, TIMING_UNKNOWN};
use crate::util::{json_opt, percentile};
use std::collections::{HashMap, VecDeque};

/// How long a presented frame waits for its scan-out time before it is finalized without one.
pub const SCANOUT_WAIT_US: u64 = 300_000;
/// Records that never complete (frame skipped, timing lost) are dropped after this.
pub const EXPIRE_US: u64 = 3_000_000;
/// HUD / LatencyReport window.
pub const WINDOW_US: u64 = 2_000_000;

#[derive(Debug, Clone, Default)]
struct Pending {
    flags: u8,
    host: Option<FrameTiming>,
    recv: Option<u64>,
    decode_start: Option<u64>,
    decode_done: Option<u64>,
    canvas: Option<u64>,
    present: Option<u64>,
    present_id: Option<u64>,
    scanout: Option<u64>,
    born: u64,
}

/// Stage durations of one finished frame, in ms. None = not measured.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Sample {
    /// Viewer time the frame was finalized.
    pub t: u64,
    pub frame_id: u32,
    pub sharp: bool,
    pub cap_to_callback: Option<f64>,
    pub callback_to_submit: Option<f64>,
    pub encode: Option<f64>,
    pub host: Option<f64>,
    pub encoded_to_sent: Option<f64>,
    pub network: Option<f64>,
    pub queue: Option<f64>,
    pub decode: Option<f64>,
    pub render: Option<f64>,
    pub scanout: Option<f64>,
    pub to_decoded: Option<f64>,
    pub to_present: Option<f64>,
    pub total: Option<f64>,
    pub total_has_scanout: bool,
    /// Presented to a swap chain but never reported on screen (replaced by a newer present
    /// within the same refresh, or statistics unavailable).
    pub present_not_shown: bool,
}

/// One ground-truth measurement from the test pattern (latency test mode).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct GroundTruth {
    pub t: u64,
    /// `blockcode::KIND_*` of the pattern's clock value.
    pub kind: u8,
    /// Pattern clock → `Present()` call of the first present that showed it, ms.
    pub to_present: f64,
    /// Pattern clock → vblank of that present, ms (None without present statistics).
    pub to_scanout: Option<f64>,
    /// The instrumentation's capture → `Present()` for the newest frame in that present, ms.
    pub instrumented_to_present: Option<f64>,
}

#[derive(Debug, Clone, Copy)]
struct PendingGt {
    code_host_us: u64,
    kind: u8,
    present: u64,
    present_id: Option<u64>,
    last_frame: Option<u32>,
    scanout: Option<u64>,
}

/// p50s over the window (ms), for the HUD and `LatencyReport`.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Summary {
    pub n: usize,
    pub cap_to_callback: Option<f64>,
    pub encode: Option<f64>,
    pub host: Option<f64>,
    pub network: Option<f64>,
    pub queue: Option<f64>,
    pub decode: Option<f64>,
    pub render: Option<f64>,
    pub scanout: Option<f64>,
    pub total: Option<f64>,
    pub total_p95: Option<f64>,
    /// Most samples' totals end at scan-out (present statistics available).
    pub total_has_scanout: bool,
    pub to_decoded: Option<f64>,
    pub gt_n: usize,
    pub gt_to_present: Option<f64>,
    pub gt_to_scanout: Option<f64>,
}

pub struct Tracker {
    /// The viewer presents frames (GUI). False for `--bench`: frames finish when decoded.
    presents: bool,
    pending: HashMap<u32, Pending>,
    pending_gt: Vec<PendingGt>,
    /// Recent (frame_id, capture_us), for ground-truth comparisons after records finished.
    recent_capture: VecDeque<(u32, u64)>,
    window: VecDeque<Sample>,
    gt_window: VecDeque<GroundTruth>,
    /// Keep every finished sample (latency-test / bench reports).
    pub keep_all: bool,
    pub all: Vec<Sample>,
    pub all_gt: Vec<GroundTruth>,
    /// The host sent at least one FrameTiming (it implements §3.4).
    pub host_timing_seen: bool,
    pub dropped: u64,
    pub window_us: u64,
}

// Inputs include host-supplied timestamps: saturate instead of overflowing.
fn ms(a: u64, b: u64) -> f64 {
    (b as i64).saturating_sub(a as i64) as f64 / 1000.0
}

fn ms_i(a: i64, b: u64) -> f64 {
    (b as i64).saturating_sub(a) as f64 / 1000.0
}

impl Tracker {
    pub fn new(presents: bool) -> Tracker {
        Tracker {
            presents,
            pending: HashMap::new(),
            pending_gt: Vec::new(),
            recent_capture: VecDeque::new(),
            window: VecDeque::new(),
            gt_window: VecDeque::new(),
            keep_all: false,
            all: Vec::new(),
            all_gt: Vec::new(),
            host_timing_seen: false,
            dropped: 0,
            window_us: WINDOW_US,
        }
    }

    /// New connection: frame ids restart.
    pub fn reset(&mut self) {
        self.pending.clear();
        self.pending_gt.clear();
        self.recent_capture.clear();
        self.host_timing_seen = false;
    }

    fn rec(&mut self, id: u32, now: u64) -> &mut Pending {
        if self.pending.len() > 4096 {
            // Something never completes (e.g. a host without §3.4): bound the memory.
            let n = self.pending.len() as u64;
            self.pending.clear();
            self.dropped += n;
        }
        self.pending.entry(id).or_insert_with(|| Pending { born: now, ..Default::default() })
    }

    pub fn on_recv(&mut self, id: u32, flags: u8, t: u64) {
        let r = self.rec(id, t);
        r.flags = flags;
        r.recv = Some(t);
    }

    pub fn on_timing(&mut self, ft: FrameTiming, now: u64) {
        self.host_timing_seen = true;
        self.recent_capture.push_back((ft.frame_id, ft.capture_us));
        if self.recent_capture.len() > 256 {
            self.recent_capture.pop_front();
        }
        let r = self.rec(ft.frame_id, now);
        r.flags |= ft.flags;
        r.host = Some(ft);
    }

    pub fn on_decode(&mut self, id: u32, start: u64, done: u64) {
        let r = self.rec(id, start);
        r.decode_start = Some(start);
        r.decode_done = Some(done);
    }

    pub fn on_canvas(&mut self, id: u32, t: u64) {
        self.rec(id, t).canvas = Some(t);
    }

    /// `ids`: frames whose canvas updates this present shows (oldest first).
    /// `present_id`: the swap chain's present count (None offscreen).
    pub fn on_present(&mut self, ids: &[u32], t: u64, present_id: Option<u64>) {
        for &id in ids {
            let r = self.rec(id, t);
            r.present = Some(t);
            r.present_id = present_id;
        }
    }

    /// The present `present_id` reached the screen at vblank time `t` (client clock).
    pub fn on_scanout(&mut self, present_id: u64, t: u64) {
        for r in self.pending.values_mut() {
            if r.present_id == Some(present_id) {
                r.scanout = Some(t);
            }
        }
        for g in self.pending_gt.iter_mut() {
            if g.present_id == Some(present_id) {
                g.scanout = Some(t);
            }
        }
    }

    /// A test-pattern value (`code_host_us`, host clock) was first seen in present
    /// `present_id` (called at `present` time, client clock). `last_frame` = newest frame id
    /// in that present.
    pub fn on_ground_truth(&mut self, code_host_us: u64, kind: u8, present: u64, present_id: Option<u64>, last_frame: Option<u32>) {
        self.pending_gt.push(PendingGt { code_host_us, kind, present, present_id, last_frame, scanout: None });
    }

    /// Present ids still waiting for a scan-out time (the renderer polls frame statistics while
    /// this is non-empty).
    pub fn awaiting_scanout(&self, now: u64) -> bool {
        self.pending.values().any(|r| r.present_id.is_some() && r.scanout.is_none() && r.present.is_some_and(|p| now.saturating_sub(p) < SCANOUT_WAIT_US))
    }

    /// Finalize what is complete; convert with `clock` (None = not synced yet: host-only stages).
    pub fn tick(&mut self, now: u64, clock: Option<&ClockSync>) {
        let presents = self.presents;
        let mut done: Vec<(u32, Pending)> = Vec::new();
        let mut expired = 0u64;
        self.pending.retain(|&id, r| {
            let ready = r.host.is_some()
                && if presents {
                    r.present.is_some_and(|p| r.present_id.is_none() || r.scanout.is_some() || now.saturating_sub(p) >= SCANOUT_WAIT_US)
                } else {
                    r.decode_done.is_some()
                };
            if ready {
                done.push((id, r.clone()));
                false
            } else if now.saturating_sub(r.born) > EXPIRE_US {
                expired += 1;
                false
            } else {
                true
            }
        });
        self.dropped += expired;
        done.sort_by_key(|d| d.0);
        for (id, r) in done {
            let s = Self::sample(id, &r, now, clock);
            if r.flags & FRAME_FLAG_REFRESH != 0 {
                continue; // capture time is the original capture: not a latency
            }
            if self.keep_all {
                self.all.push(s);
            }
            if !s.sharp {
                self.window.push_back(s);
            }
        }
        // Ground truth.
        let mut keep = Vec::new();
        for g in std::mem::take(&mut self.pending_gt) {
            let ready = g.present_id.is_none() || g.scanout.is_some() || now.saturating_sub(g.present) >= SCANOUT_WAIT_US;
            if !ready {
                keep.push(g);
                continue;
            }
            let Some(c) = clock else { continue };
            let Some(code_c) = c.host_to_client_us(g.code_host_us) else { continue };
            let instrumented = g
                .last_frame
                .and_then(|f| self.recent_capture.iter().rev().find(|x| x.0 == f))
                .and_then(|&(_, cap)| c.host_to_client_us(cap))
                .map(|cap_c| ms_i(cap_c, g.present));
            let gt = GroundTruth {
                t: now,
                kind: g.kind,
                to_present: ms_i(code_c, g.present),
                to_scanout: g.scanout.map(|s| ms_i(code_c, s)),
                instrumented_to_present: instrumented,
            };
            if self.keep_all {
                self.all_gt.push(gt);
            }
            self.gt_window.push_back(gt);
        }
        self.pending_gt = keep;
        while self.window.front().is_some_and(|s| now.saturating_sub(s.t) > self.window_us) {
            self.window.pop_front();
        }
        while self.gt_window.front().is_some_and(|s| now.saturating_sub(s.t) > self.window_us) {
            self.gt_window.pop_front();
        }
    }

    fn sample(id: u32, r: &Pending, now: u64, clock: Option<&ClockSync>) -> Sample {
        let h = r.host.unwrap_or_default();
        let d = |a: u32, b: u32| (a != TIMING_UNKNOWN && b != TIMING_UNKNOWN).then(|| (b as f64 - a as f64) / 1000.0);
        let conv = |host_us: Option<u64>| -> Option<i64> { clock?.host_to_client_us(host_us?) };
        let cap_c = conv(Some(h.capture_us));
        let opt = |a: Option<u64>, b: Option<u64>| Some(ms(a?, b?));
        let from_cap = |b: Option<u64>| Some(ms_i(cap_c?, b?));
        let end = r.scanout.or(r.present);
        Sample {
            t: now,
            frame_id: id,
            sharp: r.flags & FRAME_FLAG_SHARP != 0,
            cap_to_callback: d(0, h.callback),
            callback_to_submit: d(h.callback, h.submit),
            encode: d(h.submit, h.encoded),
            host: d(0, h.encoded),
            encoded_to_sent: d(h.encoded, h.sent),
            network: conv(h.at(h.enqueued)).zip(r.recv).map(|(e, rv)| ms_i(e, rv)),
            queue: opt(r.recv, r.decode_start),
            decode: opt(r.decode_start, r.decode_done),
            render: opt(r.decode_done, r.present),
            scanout: opt(r.present, r.scanout),
            to_decoded: from_cap(r.decode_done),
            to_present: from_cap(r.present),
            total: from_cap(end),
            total_has_scanout: r.scanout.is_some(),
            present_not_shown: r.present_id.is_some() && r.scanout.is_none(),
        }
    }

    pub fn summary(&self) -> Summary {
        let w = &self.window;
        let p50 = |f: fn(&Sample) -> Option<f64>| {
            let v: Vec<f64> = w.iter().filter_map(f).collect();
            percentile(&v, 50.0)
        };
        // Once present statistics work, the total is capture → scan-out over the frames that
        // reached the screen; otherwise capture → Present().
        let has_scanout = w.iter().filter(|s| s.total_has_scanout).count() * 2 > w.len();
        let totals: Vec<f64> = w.iter().filter(|s| s.total_has_scanout == has_scanout).filter_map(|s| s.total).collect();
        let gtp: Vec<f64> = self.gt_window.iter().map(|g| g.to_present).collect();
        let gts: Vec<f64> = self.gt_window.iter().filter_map(|g| g.to_scanout).collect();
        Summary {
            n: w.len(),
            cap_to_callback: p50(|s| s.cap_to_callback),
            encode: p50(|s| s.encode),
            host: p50(|s| s.host),
            network: p50(|s| s.network),
            queue: p50(|s| s.queue),
            decode: p50(|s| s.decode),
            render: p50(|s| s.render),
            scanout: p50(|s| s.scanout),
            total: percentile(&totals, 50.0),
            total_p95: percentile(&totals, 95.0),
            total_has_scanout: has_scanout,
            to_decoded: p50(|s| s.to_decoded),
            gt_n: self.gt_window.len(),
            gt_to_present: percentile(&gtp, 50.0),
            gt_to_scanout: percentile(&gts, 50.0),
        }
    }

    /// Distributions over everything kept (`keep_all`), as a JSON object.
    pub fn report_json(&self) -> String {
        let s = &self.all;
        let base: Vec<&Sample> = s.iter().filter(|x| !x.sharp).collect();
        let col = |f: fn(&Sample) -> Option<f64>| -> Vec<f64> { base.iter().filter_map(|x| f(x)).collect() };
        let stages: [(&str, fn(&Sample) -> Option<f64>); 14] = [
            ("cap_to_callback", |s| s.cap_to_callback),
            ("callback_to_submit", |s| s.callback_to_submit),
            ("encode", |s| s.encode),
            ("host_capture_to_encoded", |s| s.host),
            ("encoded_to_sent", |s| s.encoded_to_sent),
            ("network", |s| s.network),
            ("queue", |s| s.queue),
            ("decode", |s| s.decode),
            ("render", |s| s.render),
            ("present_to_scanout", |s| s.scanout),
            ("capture_to_decoded", |s| s.to_decoded),
            ("capture_to_present", |s| s.to_present),
            ("total", |s| s.total),
            ("total_scanout_only", |s| if s.total_has_scanout { s.total } else { None }),
        ];
        let mut parts: Vec<String> = stages.iter().map(|(n, f)| format!("\"{n}\":{}", dist_json(&col(*f)))).collect();
        let g = &self.all_gt;
        let gp: Vec<f64> = g.iter().map(|x| x.to_present).collect();
        let gs: Vec<f64> = g.iter().filter_map(|x| x.to_scanout).collect();
        let diff: Vec<f64> = g.iter().filter_map(|x| x.instrumented_to_present.map(|i| x.to_present - i)).collect();
        let kinds: Vec<String> = {
            let mut k: Vec<u8> = g.iter().map(|x| x.kind).collect();
            k.sort();
            k.dedup();
            k.iter().map(|x| x.to_string()).collect()
        };
        parts.push(format!(
            "\"ground_truth\":{{\"kinds\":[{}],\"to_present\":{},\"to_scanout\":{},\"minus_instrumented_to_present\":{}}}",
            kinds.join(","),
            dist_json(&gp),
            dist_json(&gs),
            dist_json(&diff)
        ));
        parts.push(format!(
            "\"frames\":{},\"sharp_frames\":{},\"dropped\":{},\"presents_not_shown\":{}",
            base.len(),
            s.len() - base.len(),
            self.dropped,
            base.iter().filter(|x| x.present_not_shown).count()
        ));
        format!("{{{}}}", parts.join(","))
    }

    /// The window's p50s as a `LatencyReport` (§3.4).
    pub fn report(&self) -> LatencyReport {
        let s = self.summary();
        let us = |v: Option<f64>| v.map_or(TIMING_UNKNOWN, |ms| (ms * 1000.0).round().clamp(0.0, (TIMING_UNKNOWN - 1) as f64) as u32);
        LatencyReport {
            samples: s.n.min(u16::MAX as usize) as u16,
            flags: s.total_has_scanout as u8 | ((s.gt_n > 0) as u8) << 1,
            host_us: us(s.host),
            network_us: us(s.network),
            queue_us: us(s.queue),
            decode_us: us(s.decode),
            render_us: us(s.render),
            scanout_us: us(s.scanout),
            total_us: us(s.total),
            ground_truth_us: us(s.gt_to_scanout.or(s.gt_to_present)),
        }
    }
}

/// `{"n":..,"p5":..,"p50":..,"p95":..,"max":..,"mean":..}` (null fields when empty).
pub fn dist_json(v: &[f64]) -> String {
    let mean = (!v.is_empty()).then(|| v.iter().sum::<f64>() / v.len() as f64);
    format!(
        "{{\"n\":{},\"p5\":{},\"p50\":{},\"p95\":{},\"max\":{},\"mean\":{}}}",
        v.len(),
        json_opt(percentile(v, 5.0)),
        json_opt(percentile(v, 50.0)),
        json_opt(percentile(v, 95.0)),
        json_opt(v.iter().cloned().reduce(f64::max)),
        json_opt(mean)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synced(offset: i64) -> ClockSync {
        // host = client + offset, perfect symmetric 200 µs RTT.
        let mut c = ClockSync::default();
        for i in 0..5u64 {
            let t = 1_000 + i * 10_000;
            c.on_pong(t, (t as i64 + 100 + offset) as u64, t + 200);
        }
        c
    }

    fn timing(id: u32, cap: u64) -> FrameTiming {
        FrameTiming { frame_id: id, capture_us: cap, flags: 0, callback: 2_000, submit: 2_100, encoded: 12_100, enqueued: 12_300, sent: 12_500 }
    }

    #[test]
    fn breakdown_with_scanout() {
        let off = 5_000_000i64; // host clock is 5 s ahead
        let clock = synced(off);
        let mut t = Tracker::new(true);
        t.keep_all = true;
        // Frame 1 captured at client time 100_000 (host 5_100_000).
        let cap_host = (100_000 + off) as u64;
        t.on_recv(1, 0, 113_500); // network: enqueued at 112_300 -> 1.2 ms
        t.on_timing(timing(1, cap_host), 113_600); // timing arrives after the frame
        t.on_decode(1, 113_800, 115_600);
        t.on_canvas(1, 115_700);
        t.on_present(&[1], 116_000, Some(42));
        t.tick(116_100, Some(&clock));
        assert!(t.all.is_empty(), "waits for scan-out");
        assert!(t.awaiting_scanout(116_100));
        t.on_scanout(42, 122_900);
        t.tick(123_000, Some(&clock));
        assert_eq!(t.all.len(), 1);
        let s = t.all[0];
        let close = |a: Option<f64>, b: f64| (a.unwrap() - b).abs() < 1e-6;
        assert!(close(s.cap_to_callback, 2.0));
        assert!(close(s.callback_to_submit, 0.1));
        assert!(close(s.encode, 10.0));
        assert!(close(s.host, 12.1));
        assert!(close(s.encoded_to_sent, 0.4));
        assert!(close(s.network, 1.2));
        assert!(close(s.queue, 0.3));
        assert!(close(s.decode, 1.8));
        assert!(close(s.render, 0.4));
        assert!(close(s.scanout, 6.9));
        assert!(close(s.to_present, 16.0));
        assert!(close(s.total, 22.9));
        assert!(s.total_has_scanout);
        let sum = t.summary();
        assert_eq!(sum.n, 1);
        assert!(sum.total_has_scanout);
        let r = t.report();
        assert_eq!((r.samples, r.flags, r.total_us, r.network_us, r.scanout_us), (1, 1, 22_900, 1_200, 6_900));
        assert_eq!(r.ground_truth_us, TIMING_UNKNOWN);
    }

    #[test]
    fn scanout_timeout_refresh_and_coalesced_presents() {
        let clock = synced(0);
        let mut t = Tracker::new(true);
        t.keep_all = true;
        // Two frames decoded in one batch share one present; a refresh frame is excluded.
        for (id, flags) in [(1u32, 0u8), (2, 0), (3, FRAME_FLAG_REFRESH)] {
            t.on_recv(id, flags, 20_000);
            t.on_timing(FrameTiming { flags, ..timing(id, 10_000) }, 20_000);
            t.on_decode(id, 21_000, 22_000);
        }
        t.on_present(&[1, 2, 3], 23_000, Some(7));
        t.tick(23_000 + SCANOUT_WAIT_US, Some(&clock)); // never got a scan-out time
        assert_eq!(t.all.len(), 2);
        assert!(t.all.iter().all(|s| !s.total_has_scanout && s.scanout.is_none() && s.present_not_shown));
        assert!((t.all[0].total.unwrap() - 13.0).abs() < 1e-6);
        // A frame whose timing never arrives expires.
        t.on_recv(9, 0, 30_000);
        t.tick(30_000 + EXPIRE_US + 1, Some(&clock));
        assert_eq!(t.dropped, 1);
        assert_eq!(t.summary().n, 0, "window slid past");
    }

    #[test]
    fn bench_mode_finishes_at_decode_and_unsynced_keeps_host_stages() {
        let mut t = Tracker::new(false);
        t.keep_all = true;
        t.on_recv(1, 0, 5_000);
        t.on_timing(timing(1, 1_000), 5_000);
        t.on_decode(1, 5_100, 6_000);
        t.tick(6_000, None);
        let s = t.all[0];
        assert!((s.host.unwrap() - 12.1).abs() < 1e-6);
        assert_eq!(s.network, None);
        assert_eq!(s.total, None);
        assert!(t.report_json().contains("\"host_capture_to_encoded\":{\"n\":1"));
    }

    #[test]
    fn ground_truth_against_instrumentation() {
        let off = -3_000_000i64;
        let clock = synced(off);
        let mut t = Tracker::new(true);
        t.keep_all = true;
        let cap_client = 4_000_000u64;
        let cap_host = (cap_client as i64 + off) as u64;
        t.on_timing(timing(5, cap_host), cap_client + 15_000);
        // The pattern was drawn 8 ms before the capture (compositor wait).
        t.on_ground_truth(cap_host - 8_000, crate::blockcode::KIND_DRAW, cap_client + 20_000, Some(11), Some(5));
        t.on_scanout(11, cap_client + 27_000);
        t.tick(cap_client + 27_500, Some(&clock));
        let g = t.all_gt[0];
        assert!((g.to_present - 28.0).abs() < 1e-6);
        assert!((g.to_scanout.unwrap() - 35.0).abs() < 1e-6);
        assert!((g.instrumented_to_present.unwrap() - 20.0).abs() < 1e-6);
        let s = t.summary();
        assert_eq!(s.gt_n, 1);
        assert_eq!(t.report().flags & 2, 2);
        assert_eq!(t.report().ground_truth_us, 35_000);
        let j = t.report_json();
        assert!(j.contains("\"minus_instrumented_to_present\":{\"n\":1,\"p5\":8.000"), "{j}");
    }

    #[test]
    fn dist_json_shape() {
        assert_eq!(dist_json(&[]), "{\"n\":0,\"p5\":null,\"p50\":null,\"p95\":null,\"max\":null,\"mean\":null}");
        assert!(dist_json(&[1.0, 3.0]).starts_with("{\"n\":2,\"p5\":1.000,\"p50\":1.000"));
    }
}
