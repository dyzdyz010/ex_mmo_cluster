//! Local predicted-player runtime state and reconciliation orchestration.

use bevy::prelude::{Vec2, Vec3};

use crate::{
    input::commands::MoveInputFrame,
    sim::{
        governance::{ReplayAction, ReplayGovernance, ReplayGovernanceStats},
        history::{InputHistory, PredictedHistory},
        predictor,
        profile::MovementProfile,
        reconcile::{ReconcileResult, reconcile},
        types::{MovementAck, PredictedMoveState},
    },
};

#[derive(Debug, Clone)]
/// Local prediction runtime that owns input history, predicted history, and reconciliation stats.
pub struct LocalPredictionRuntime {
    next_seq: u32,
    next_tick: u32,
    current_state: Option<PredictedMoveState>,
    last_input_frame: Option<MoveInputFrame>,
    input_history: InputHistory,
    predicted_history: PredictedHistory,
    profile: MovementProfile,
    governance: ReplayGovernance,
    governance_stats: ReplayGovernanceStats,
}

impl Default for LocalPredictionRuntime {
    fn default() -> Self {
        Self {
            next_seq: 1,
            next_tick: 1,
            current_state: None,
            last_input_frame: None,
            input_history: InputHistory::new(128),
            predicted_history: PredictedHistory::new(256),
            profile: MovementProfile::default(),
            governance: ReplayGovernance::default(),
            governance_stats: ReplayGovernanceStats::default(),
        }
    }
}

impl LocalPredictionRuntime {
    /// Resets local prediction around a fresh authoritative spawn position.
    pub fn reset(&mut self, position: Vec3, profile: Option<MovementProfile>) {
        self.next_seq = 1;
        self.next_tick = 1;
        self.input_history = InputHistory::new(128);
        self.predicted_history = PredictedHistory::new(256);
        self.governance_stats = ReplayGovernanceStats::default();
        self.last_input_frame = None;
        if let Some(profile) = profile {
            self.profile = profile;
        }

        let state = PredictedMoveState::idle(position);
        self.predicted_history.push(state.clone());
        self.current_state = Some(state);
    }

    /// Clears local prediction state after disconnect/scene leave.
    pub fn clear(&mut self) {
        self.current_state = None;
        self.input_history = InputHistory::new(128);
        self.predicted_history = PredictedHistory::new(256);
        self.next_seq = 1;
        self.next_tick = 1;
        self.governance_stats = ReplayGovernanceStats::default();
        self.last_input_frame = None;
    }

    /// Builds the next local input frame using monotonic local sequence/tick counters.
    pub fn build_input_frame(
        &mut self,
        input_dir: Vec2,
        dt_ms: u16,
        speed_scale: f32,
        movement_flags: u16,
    ) -> MoveInputFrame {
        let frame = MoveInputFrame {
            seq: self.next_seq,
            client_tick: self.next_tick,
            dt_ms,
            input_dir,
            speed_scale,
            movement_flags,
        };

        self.next_seq += 1;
        self.next_tick += 1;
        frame
    }

    /// Applies one locally generated input frame to the predicted timeline.
    pub fn apply_local_input(&mut self, frame: MoveInputFrame) -> Option<PredictedMoveState> {
        let current = self.current_state.clone()?;
        self.input_history.push(frame.clone());
        self.last_input_frame = Some(frame.clone());
        let next = predictor::step(&current, &frame, &self.profile);
        self.predicted_history.push(next.clone());
        self.current_state = Some(next.clone());
        Some(next)
    }

    /// Applies one authoritative movement acknowledgement and reconciles local prediction.
    pub fn apply_ack(&mut self, ack: MovementAck) -> Option<ReconcileResult> {
        self.extend_prediction_through(ack.auth_tick);
        self.next_tick = self.next_tick.max(ack.auth_tick + 1);

        if let Some(result) = reconcile(
            &ack,
            &mut self.input_history,
            &mut self.predicted_history,
            &self.profile,
            &self.governance,
        ) {
            self.governance_stats.record(
                result.action,
                result.replayed_frames,
                result.pending_inputs,
                result.correction_distance,
            );
            self.current_state = Some(result.latest_state.clone());
            return Some(result);
        }

        let authoritative = PredictedMoveState {
            tick: ack.auth_tick,
            position: ack.position,
            velocity: ack.velocity,
            acceleration: ack.acceleration,
            movement_mode: ack.movement_mode,
        };

        self.predicted_history.push(authoritative.clone());
        self.current_state = Some(authoritative.clone());

        Some(ReconcileResult {
            action: ReplayAction::Accepted,
            latest_state: authoritative,
            replayed_frames: 0,
            pending_inputs: 0,
            correction_distance: 0.0,
        })
    }

    /// Returns the current predicted state, if any.
    pub fn current_state(&self) -> Option<&PredictedMoveState> {
        self.current_state.as_ref()
    }

    /// Returns the latest replay-governance stats.
    pub fn governance_stats(&self) -> &ReplayGovernanceStats {
        &self.governance_stats
    }

    fn extend_prediction_through(&mut self, auth_tick: u32) {
        let Some(mut frame) = self.last_input_frame.clone() else {
            return;
        };

        while self
            .current_state
            .as_ref()
            .is_some_and(|state| state.tick < auth_tick)
        {
            let current = match self.current_state.clone() {
                Some(current) => current,
                None => return,
            };

            frame.client_tick = current.tick + 1;

            let next = predictor::step(&current, &frame, &self.profile);
            self.predicted_history.push(next.clone());
            self.current_state = Some(next);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sim::{governance::ReplayAction, profile::MovementProfile};

    #[test]
    fn runtime_builds_frames_and_applies_prediction() {
        let mut runtime = LocalPredictionRuntime::default();
        runtime.reset(Vec3::ZERO, None);

        let frame = runtime.build_input_frame(Vec2::new(1.0, 0.0), 100, 1.0, 0);
        let state = runtime.apply_local_input(frame).expect("predicted state");

        assert_eq!(state.tick, 1);
        assert!(state.position.x > 0.0);
    }

    #[test]
    fn runtime_extends_prediction_when_ack_tick_advances_past_last_sent_frame() {
        let mut runtime = LocalPredictionRuntime::default();
        runtime.reset(Vec3::ZERO, None);

        let frame = runtime.build_input_frame(Vec2::new(0.0, 1.0), 100, 1.0, 0);
        let predicted_one = runtime
            .apply_local_input(frame.clone())
            .expect("predicted state");

        let frame_tick_two = MoveInputFrame {
            client_tick: 2,
            ..frame.clone()
        };
        let predicted_two = predictor::step(&predicted_one, &frame_tick_two, &MovementProfile::default());

        let ack = MovementAck {
            ack_seq: frame.seq,
            auth_tick: 2,
            position: predicted_two.position,
            velocity: predicted_two.velocity,
            acceleration: predicted_two.acceleration,
            movement_mode: predicted_two.movement_mode,
            correction_flags: 0,
        };

        let result = runtime.apply_ack(ack).expect("ack result");

        assert_ne!(result.action, ReplayAction::HardSnap);
        assert_eq!(result.latest_state.tick, 2);
        assert_eq!(result.latest_state.position, predicted_two.position);
    }
}
