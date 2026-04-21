//! Policy knobs and stats for local replay/reconciliation behavior.

#[derive(Debug, Clone)]
/// Limits and thresholds for replay-based reconciliation.
///
/// `soft_position_error` is the *current effective* soft threshold actually
/// consulted by `reconcile()`. It is seeded from `base_soft_position_error`
/// and can be bumped up on the fly by `apply_jitter` (C.1 adaptive path).
pub struct ReplayGovernance {
    pub soft_position_error: f32,
    pub hard_snap_distance: f32,
    pub max_replay_frames: usize,
    pub max_pending_inputs: usize,
    // --- C.1 jitter-adaptive knobs ---
    /// Floor for the adaptive soft threshold — what we use when jitter is
    /// zero. Matches the pre-C.1 constant default.
    pub base_soft_position_error: f32,
    /// Ceiling for the adaptive soft threshold — caps how far jitter can
    /// stretch the soft band before genuine misprediction stops triggering
    /// replay.
    pub max_soft_position_error: f32,
    /// Additional soft-threshold units per millisecond of smoothed jitter.
    /// Overwatch GDC 2017 cites ~0.02 u/ms as a reasonable starting point.
    pub k_jitter: f32,
}

impl Default for ReplayGovernance {
    fn default() -> Self {
        // Defaults are chosen around a 100 ms server tick and a max speed of
        // 220 u/s:
        // - soft_position_error: below ~2 u (<~2% of a 100 ms step) we treat
        //   the correction as floating-point noise and accept the prediction.
        // - hard_snap_distance: 256 u is roughly a full second of authoritative
        //   movement; under that we replay instead of teleporting.
        // - max_replay_frames: 32 matches 3.2 s of buffered inputs which is
        //   deeper than typical round-trip, keeping replay budget generous.
        // - adaptive soft: base 2 u, cap 8 u, 0.02 u per ms of jitter —
        //   300 ms jitter lifts the threshold to 8 u, the cap.
        Self {
            soft_position_error: 2.0,
            hard_snap_distance: 256.0,
            max_replay_frames: 32,
            max_pending_inputs: 64,
            base_soft_position_error: 2.0,
            max_soft_position_error: 8.0,
            k_jitter: 0.02,
        }
    }
}

impl ReplayGovernance {
    /// Computes the clamped adaptive soft threshold for a given smoothed
    /// jitter estimate, without mutating state.
    pub fn effective_soft_position_error(&self, jitter_ms: f32) -> f32 {
        let raw = self.base_soft_position_error + self.k_jitter * jitter_ms.max(0.0);
        raw.clamp(self.base_soft_position_error, self.max_soft_position_error)
    }

    /// Updates `soft_position_error` in-place from the current jitter, so
    /// the next `reconcile()` call sees the jitter-adjusted threshold.
    pub fn apply_jitter(&mut self, jitter_ms: f32) {
        self.soft_position_error = self.effective_soft_position_error(jitter_ms);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// High-level reconciliation action taken for one authoritative correction.
pub enum ReplayAction {
    Accepted,
    Replayed,
    HardSnap,
    WindowTrimmed,
    /// Replay forced by `CorrectionFlags::COLLISION_PUSH` — server physics
    /// pushed the avatar against input, so the soft-threshold short-circuit
    /// must not turn it into an `Accepted`.
    ForcedReplay,
    /// Hard snap driven by `CorrectionFlags::TELEPORT` or
    /// `::ANTI_CHEAT_REJECT` rather than by distance; distinct from the
    /// distance-based `HardSnap` for observability.
    Teleport,
    /// Status-effect override: velocity/mode replaced from the ack, pending
    /// inputs are dropped rather than replayed (stun, root, buff).
    StatusOverride,
}

#[derive(Debug, Clone, Default)]
/// Aggregate stats collected from reconciliation behavior.
pub struct ReplayGovernanceStats {
    pub total_corrections: u32,
    pub total_replays: u32,
    pub total_hard_snaps: u32,
    pub total_window_trims: u32,
    /// Subset of `total_replays` triggered by `CorrectionFlags::COLLISION_PUSH`.
    pub total_forced_replays: u32,
    /// Subset of `total_hard_snaps` triggered by TELEPORT or ANTI_CHEAT_REJECT.
    pub total_teleports: u32,
    /// Count of status-override acks applied without replay.
    pub total_status_overrides: u32,
    pub last_replayed_frames: usize,
    pub last_pending_inputs: usize,
    pub last_correction_distance: f32,
}

impl ReplayGovernanceStats {
    /// Records one reconciliation result into the aggregate stats.
    pub fn record(
        &mut self,
        action: ReplayAction,
        replayed_frames: usize,
        pending_inputs: usize,
        correction_distance: f32,
    ) {
        self.total_corrections += 1;
        self.last_replayed_frames = replayed_frames;
        self.last_pending_inputs = pending_inputs;
        self.last_correction_distance = correction_distance;

        match action {
            ReplayAction::Accepted => {}
            ReplayAction::Replayed => self.total_replays += 1,
            ReplayAction::HardSnap => self.total_hard_snaps += 1,
            ReplayAction::WindowTrimmed => {
                self.total_replays += 1;
                self.total_window_trims += 1;
            }
            ReplayAction::ForcedReplay => {
                self.total_replays += 1;
                self.total_forced_replays += 1;
            }
            ReplayAction::Teleport => {
                self.total_hard_snaps += 1;
                self.total_teleports += 1;
            }
            ReplayAction::StatusOverride => {
                self.total_status_overrides += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective_soft_returns_base_when_jitter_is_zero() {
        let gov = ReplayGovernance::default();
        assert!(
            (gov.effective_soft_position_error(0.0) - gov.base_soft_position_error).abs() < 1e-6
        );
    }

    #[test]
    fn effective_soft_scales_linearly_within_range() {
        let gov = ReplayGovernance::default();
        // base=2.0, k=0.02 → 150 ms jitter → 2.0 + 3.0 = 5.0
        let v = gov.effective_soft_position_error(150.0);
        assert!((v - 5.0).abs() < 1e-4, "expected 5.0, got {v}");
    }

    #[test]
    fn effective_soft_clamped_at_max() {
        let gov = ReplayGovernance::default();
        // 1000 ms jitter × 0.02 = 20 u + 2 u base = 22 u → clamped to 8.
        let v = gov.effective_soft_position_error(1000.0);
        assert!((v - gov.max_soft_position_error).abs() < 1e-6);
    }

    #[test]
    fn effective_soft_rejects_negative_jitter() {
        let gov = ReplayGovernance::default();
        let v = gov.effective_soft_position_error(-50.0);
        assert!((v - gov.base_soft_position_error).abs() < 1e-6);
    }

    #[test]
    fn apply_jitter_updates_soft_threshold_in_place() {
        let mut gov = ReplayGovernance::default();
        assert!((gov.soft_position_error - 2.0).abs() < 1e-6);
        gov.apply_jitter(100.0);
        // 100 ms × 0.02 = 2.0 bump → 4.0.
        assert!((gov.soft_position_error - 4.0).abs() < 1e-4);
        // Larger spike → clamp.
        gov.apply_jitter(10_000.0);
        assert!((gov.soft_position_error - gov.max_soft_position_error).abs() < 1e-6);
        // Calming down returns to the floor.
        gov.apply_jitter(0.0);
        assert!((gov.soft_position_error - gov.base_soft_position_error).abs() < 1e-6);
    }

    #[test]
    fn record_accumulates_semantic_flag_buckets() {
        let mut stats = ReplayGovernanceStats::default();
        stats.record(ReplayAction::Teleport, 0, 0, 10.0);
        stats.record(ReplayAction::ForcedReplay, 3, 5, 0.5);
        stats.record(ReplayAction::StatusOverride, 0, 2, 1.0);
        stats.record(ReplayAction::Replayed, 4, 4, 3.0);

        assert_eq!(stats.total_corrections, 4);
        assert_eq!(stats.total_hard_snaps, 1);
        assert_eq!(stats.total_teleports, 1);
        assert_eq!(stats.total_replays, 2); // ForcedReplay + Replayed
        assert_eq!(stats.total_forced_replays, 1);
        assert_eq!(stats.total_status_overrides, 1);
        assert_eq!(stats.last_replayed_frames, 4);
    }
}
