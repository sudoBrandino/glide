//! Present → scan-out timing from DXGI frame statistics (docs/LATENCY.md).
//!
//! `IDXGISwapChain::GetFrameStatistics` reports the most recent present that reached the screen
//! (`PresentCount`, comparable with `GetLastPresentCount`) and the vblank count it was first
//! shown at (`PresentRefreshCount`), plus one (vblank count, QPC time) pair the OS sampled
//! (`SyncRefreshCount`, `SyncQPCTime`). The present's vblank time is therefore
//! `SyncQPCTime + (PresentRefreshCount − SyncRefreshCount) × refresh period`. The period is
//! measured from successive samples (falls back to the monitor's nominal rate). QPC times are
//! converted to `util::now_us()` with a one-time calibration.

use super::render::FrameStats;
use crate::util::now_us;
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

pub struct ScanoutClock {
    freq: f64,
    qpc_base: i64,
    us_base: u64,
    /// (sync refresh count, QPC) of an earlier sample, for the period estimate.
    anchor: Option<(u32, i64)>,
    period_qpc: Option<f64>,
    last_present: u32,
}

fn qpc() -> i64 {
    let mut q = 0i64;
    unsafe {
        let _ = QueryPerformanceCounter(&mut q);
    }
    q
}

impl Default for ScanoutClock {
    fn default() -> Self {
        Self::new()
    }
}

impl ScanoutClock {
    pub fn new() -> ScanoutClock {
        let mut f = 0i64;
        unsafe {
            let _ = QueryPerformanceFrequency(&mut f);
        }
        // Bracket now_us() between two QPC reads (sub-µs apart) and take the midpoint.
        let (mut best, mut base) = (i64::MAX, (0i64, 0u64));
        for _ in 0..5 {
            let a = qpc();
            let u = now_us();
            let b = qpc();
            if b - a < best {
                best = b - a;
                base = ((a + b) / 2, u);
            }
        }
        ScanoutClock { freq: f.max(1) as f64, qpc_base: base.0, us_base: base.1, anchor: None, period_qpc: None, last_present: 0 }
    }

    pub fn qpc_to_us(&self, q: i64) -> u64 {
        (self.us_base as f64 + (q - self.qpc_base) as f64 * 1e6 / self.freq).max(0.0) as u64
    }

    /// Measured refresh rate, Hz.
    pub fn refresh_hz(&self) -> Option<f64> {
        self.period_qpc.map(|p| self.freq / p)
    }

    /// Feed one statistics sample. Returns (present count, vblank time in `now_us` µs) when a
    /// present we haven't reported yet reached the screen.
    pub fn poll(&mut self, s: FrameStats, nominal_hz: f64) -> Option<(u64, u64)> {
        match self.anchor {
            None => self.anchor = Some((s.sync_refresh_count, s.sync_qpc)),
            Some((c0, q0)) => {
                let dc = s.sync_refresh_count.wrapping_sub(c0) as i32;
                let dq = s.sync_qpc - q0;
                if dc >= 120 && dq > 0 {
                    let p = dq as f64 / dc as f64;
                    // Long baselines average out sampling jitter; restart after ~10k vblanks so a
                    // refresh-rate change is picked up.
                    self.period_qpc = Some(p);
                    if dc > 10_000 {
                        self.anchor = Some((s.sync_refresh_count, s.sync_qpc));
                    }
                } else if dc < 0 {
                    self.anchor = Some((s.sync_refresh_count, s.sync_qpc));
                }
            }
        }
        if s.present_count == self.last_present {
            return None;
        }
        self.last_present = s.present_count;
        let period = self.period_qpc.unwrap_or(self.freq / nominal_hz.max(1.0));
        let dv = s.present_refresh_count.wrapping_sub(s.sync_refresh_count) as i32;
        let q = s.sync_qpc as f64 + dv as f64 * period;
        Some((s.present_count as u64, self.qpc_to_us(q as i64)))
    }
}
