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
        Self {
            soft_position_error: 0.01,
            hard_snap_distance: 32.0,
            max_replay_frames: 24,
            max_pending_inputs: 48,
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
