use bevy::prelude::{Vec2, Vec3};

use crate::{
    input::commands::MoveInputFrame,
    sim::{
        history::{InputHistory, PredictedHistory},
        predictor,
        profile::MovementProfile,
        reconcile::{ReconcileResult, reconcile},
        types::{MovementAck, PredictedMoveState},
    },
};

#[derive(Debug, Clone)]
pub struct LocalPredictionRuntime {
    next_seq: u32,
    next_tick: u32,
    current_state: Option<PredictedMoveState>,
    input_history: InputHistory,
    predicted_history: PredictedHistory,
    profile: MovementProfile,
    position_error_threshold: f32,
}

impl Default for LocalPredictionRuntime {
    fn default() -> Self {
        Self {
            next_seq: 1,
            next_tick: 1,
            current_state: None,
            input_history: InputHistory::new(128),
            predicted_history: PredictedHistory::new(256),
            profile: MovementProfile::default(),
            // TODO(vnext-stage3): upgrade this fixed threshold into replay-window governance.
            // Future work should track correction distance, replayed frame count, and
            // bounded history watermarks so high-latency sessions can degrade gracefully
            // instead of relying on a single hardcoded epsilon.
            position_error_threshold: 0.01,
        }
    }
}

impl LocalPredictionRuntime {
    pub fn reset(&mut self, position: Vec3, profile: Option<MovementProfile>) {
        self.next_seq = 1;
        self.next_tick = 1;
        self.input_history = InputHistory::new(128);
        self.predicted_history = PredictedHistory::new(256);
        if let Some(profile) = profile {
            self.profile = profile;
        }

        let state = PredictedMoveState::idle(position);
        self.predicted_history.push(state.clone());
        self.current_state = Some(state);
    }

    pub fn clear(&mut self) {
        self.current_state = None;
        self.input_history = InputHistory::new(128);
        self.predicted_history = PredictedHistory::new(256);
        self.next_seq = 1;
        self.next_tick = 1;
    }

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

    pub fn apply_local_input(&mut self, frame: MoveInputFrame) -> Option<PredictedMoveState> {
        let current = self.current_state.clone()?;
        self.input_history.push(frame.clone());
        let next = predictor::step(&current, &frame, &self.profile);
        self.predicted_history.push(next.clone());
        self.current_state = Some(next.clone());
        Some(next)
    }

    pub fn apply_ack(&mut self, ack: MovementAck) -> Option<ReconcileResult> {
        if let Some(result) = reconcile(
            &ack,
            &mut self.input_history,
            &mut self.predicted_history,
            &self.profile,
            self.position_error_threshold,
        ) {
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
            replayed: false,
            latest_state: authoritative,
        })
    }

    pub fn current_state(&self) -> Option<&PredictedMoveState> {
        self.current_state.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_builds_frames_and_applies_prediction() {
        let mut runtime = LocalPredictionRuntime::default();
        runtime.reset(Vec3::ZERO, None);

        let frame = runtime.build_input_frame(Vec2::new(1.0, 0.0), 100, 1.0, 0);
        let state = runtime.apply_local_input(frame).expect("predicted state");

        assert_eq!(state.tick, 1);
        assert!(state.position.x > 0.0);
    }
}
