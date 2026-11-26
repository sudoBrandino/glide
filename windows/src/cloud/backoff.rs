//! Reconnect backoff for the hub and other cloud retries (docs/ENTERPRISE.md §6.4): 1 s doubling
//! to 60 s, each delay with ±20 % jitter so a fleet doesn't reconnect in lockstep after an outage.

use std::time::Duration;

pub const INITIAL: Duration = Duration::from_secs(1);
pub const MAX: Duration = Duration::from_secs(60);
/// ±20 %.
pub const JITTER: f64 = 0.2;

#[derive(Debug, Clone)]
pub struct Backoff {
    next: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Backoff { next: INITIAL }
    }
}

impl Backoff {
    /// The base delay of the next attempt (without jitter).
    pub fn base(&self) -> Duration {
        self.next
    }

    /// The delay before the next attempt, with jitter from `unit` (uniform in [0, 1)); doubles
    /// the base for the attempt after.
    pub fn next_with(&mut self, unit: f64) -> Duration {
        let base = self.next;
        self.next = (self.next * 2).min(MAX);
        let factor = 1.0 + JITTER * (2.0 * unit.clamp(0.0, 1.0) - 1.0);
        base.mul_f64(factor)
    }

    /// `next_with` using the OS random generator.
    pub fn next_delay(&mut self) -> Duration {
        self.next_with(random_unit())
    }

    /// A connection worked: start again from 1 s.
    pub fn reset(&mut self) {
        self.next = INITIAL;
    }
}

/// Uniform in [0, 1) from the OS RNG.
pub fn random_unit() -> f64 {
    use rand_core::RngCore;
    (rand_core::OsRng.next_u64() >> 11) as f64 / (1u64 << 53) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_to_sixty_seconds() {
        let mut b = Backoff::default();
        let bases: Vec<u64> = (0..9).map(|_| b.next_with(0.5).as_secs()).collect();
        assert_eq!(bases, vec![1, 2, 4, 8, 16, 32, 60, 60, 60]);
        b.reset();
        assert_eq!(b.base(), INITIAL);
    }

    #[test]
    fn jitter_is_within_twenty_percent() {
        let mut b = Backoff::default();
        assert_eq!(b.next_with(0.0), Duration::from_millis(800));
        let mut b = Backoff::default();
        assert_eq!(b.next_with(1.0), Duration::from_millis(1200));
        let mut b = Backoff { next: MAX };
        for _ in 0..200 {
            let d = b.next_delay();
            assert!(d >= Duration::from_secs(48) && d <= Duration::from_secs(72), "{d:?}");
        }
        assert!((0..100).map(|_| random_unit()).all(|u| (0.0..1.0).contains(&u)));
    }
}
