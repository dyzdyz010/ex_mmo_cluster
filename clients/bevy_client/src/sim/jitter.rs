//! EWMA smoother for RTT jitter.
//!
//! Observes raw RTT samples (ms) and exposes an exponentially-weighted
//! moving average of the per-sample absolute delta — `|RTT_n − RTT_{n-1}|`.
//! `α = 0.15` is the Overwatch-style default (Timothy Ford, GDC 2017):
//! reacts quickly to a genuine jitter spike while suppressing single-packet
//! outliers.
//!
//! The estimator is intentionally stateless beyond the previous RTT sample
//! and the current value — it has no time-based decay, so stale data will
//! not drift to zero on its own. Callers that detect a quiet period can
//! call `reset` to restart from a clean baseline.

#[derive(Debug, Clone)]
pub struct JitterEstimator {
    alpha: f32,
    prev_rtt: Option<f32>,
    value: f32,
}

impl JitterEstimator {
    pub const DEFAULT_ALPHA: f32 = 0.15;

    pub fn new(alpha: f32) -> Self {
        Self {
            alpha: alpha.clamp(0.0, 1.0),
            prev_rtt: None,
            value: 0.0,
        }
    }

    pub fn with_default_alpha() -> Self {
        Self::new(Self::DEFAULT_ALPHA)
    }

    /// Consumes one RTT sample and returns the updated jitter estimate (ms).
    /// The first sample seeds the previous-RTT slot and returns 0.0.
    ///
    /// Negative samples (impossible by definition — RTT is a non-negative
    /// duration) are rejected rather than clamped: clamping injects a fake
    /// zero-RTT into the EWMA and silently corrupts the estimate for the
    /// next real sample.
    pub fn observe(&mut self, rtt_ms: f32) -> f32 {
        if !rtt_ms.is_finite() || rtt_ms < 0.0 {
            return self.value;
        }
        match self.prev_rtt {
            None => {
                self.prev_rtt = Some(rtt_ms);
                self.value
            }
            Some(prev) => {
                let delta = (rtt_ms - prev).abs();
                self.value = self.alpha * delta + (1.0 - self.alpha) * self.value;
                self.prev_rtt = Some(rtt_ms);
                self.value
            }
        }
    }

    pub fn current(&self) -> f32 {
        self.value
    }

    pub fn reset(&mut self) {
        self.prev_rtt = None;
        self.value = 0.0;
    }
}

impl Default for JitterEstimator {
    fn default() -> Self {
        Self::with_default_alpha()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_sample_yields_zero_jitter() {
        let mut est = JitterEstimator::default();
        assert_eq!(est.observe(50.0), 0.0);
        assert_eq!(est.current(), 0.0);
    }

    #[test]
    fn constant_rtt_keeps_jitter_at_zero() {
        let mut est = JitterEstimator::default();
        for _ in 0..10 {
            est.observe(60.0);
        }
        assert!(est.current().abs() < 1e-6);
    }

    #[test]
    fn step_change_raises_jitter_toward_delta() {
        let mut est = JitterEstimator::new(0.5);
        est.observe(50.0);
        // Δ = 30 with α=0.5 → value = 15 after one step.
        let j = est.observe(80.0);
        assert!((j - 15.0).abs() < 1e-4, "expected ~15.0, got {}", j);
    }

    #[test]
    fn ewma_smooths_single_outlier() {
        let mut est = JitterEstimator::default();
        // Stable baseline — jitter must stay near zero.
        for _ in 0..5 {
            est.observe(40.0);
        }
        assert!(est.current() < 0.01);

        // Single outlier of +100 ms — jitter jumps but not all the way to 100.
        let after_outlier = est.observe(140.0);
        assert!(after_outlier > 10.0 && after_outlier < 100.0);

        // Recovery: back to baseline slowly decays value with α=0.15
        // weighting of Δ=100 downward, but current is still well above zero
        // at the first recovery sample (|40-140| = 100, contribution
        // 0.15 * 100 = 15 + 0.85 * 15 ≈ 27.75).
        est.observe(40.0);
    }

    #[test]
    fn reset_clears_state() {
        let mut est = JitterEstimator::default();
        est.observe(50.0);
        est.observe(150.0);
        assert!(est.current() > 0.0);
        est.reset();
        assert_eq!(est.current(), 0.0);
        assert_eq!(est.observe(100.0), 0.0);
    }

    #[test]
    fn negative_sample_is_rejected_without_state_change() {
        let mut est = JitterEstimator::new(0.5);
        est.observe(100.0);
        let value_before = est.current();
        // Negative RTT is impossible; it must not perturb state.
        assert_eq!(est.observe(-20.0), value_before);
        assert_eq!(est.observe(f32::NAN), value_before);
        assert_eq!(est.observe(f32::INFINITY), value_before);
        // prev_rtt remained 100 → delta with 80 is 20, so value = 0.5*20 = 10.
        let j = est.observe(80.0);
        assert!((j - 10.0).abs() < 1e-4, "expected 10.0, got {}", j);
    }
}
