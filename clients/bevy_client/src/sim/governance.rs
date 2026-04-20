//! Policy knobs and stats for local replay/reconciliation behavior.

#[derive(Debug, Clone)]
/// Limits and thresholds for replay-based reconciliation.
pub struct ReplayGovernance {
    pub soft_position_error: f32,
    pub hard_snap_distance: f32,
    pub max_replay_frames: usize,
    pub max_pending_inputs: usize,
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
        Self {
            soft_position_error: 2.0,
            hard_snap_distance: 256.0,
            max_replay_frames: 32,
            max_pending_inputs: 64,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// High-level reconciliation action taken for one authoritative correction.
pub enum ReplayAction {
    Accepted,
    Replayed,
    HardSnap,
    WindowTrimmed,
}

#[derive(Debug, Clone, Default)]
/// Aggregate stats collected from reconciliation behavior.
pub struct ReplayGovernanceStats {
    pub total_corrections: u32,
    pub total_replays: u32,
    pub total_hard_snaps: u32,
    pub total_window_trims: u32,
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
        }
    }
}
