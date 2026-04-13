use crate::sim::{
    governance::{ReplayAction, ReplayGovernance},
    history::{InputHistory, PredictedHistory},
    predictor,
    profile::MovementProfile,
    types::{MovementAck, PredictedMoveState},
};

#[derive(Debug, Clone, PartialEq)]
pub struct ReconcileResult {
    pub action: ReplayAction,
    pub latest_state: PredictedMoveState,
    pub replayed_frames: usize,
    pub pending_inputs: usize,
    pub correction_distance: f32,
}

pub fn reconcile(
    ack: &MovementAck,
    input_history: &mut InputHistory,
    predicted_history: &mut PredictedHistory,
    profile: &MovementProfile,
    governance: &ReplayGovernance,
) -> Option<ReconcileResult> {
    input_history.drop_through(ack.ack_seq);
    let pending_frames = input_history.frames_after_tick_cloned(ack.auth_tick);
    let pending_inputs = pending_frames.len();

    let authoritative = PredictedMoveState {
        tick: ack.auth_tick,
        position: ack.position,
        velocity: ack.velocity,
        acceleration: ack.acceleration,
        movement_mode: ack.movement_mode,
    };
    let Some(predicted) = predicted_history.state_at_tick(ack.auth_tick).cloned() else {
        predicted_history.clear();
        predicted_history.push(authoritative.clone());

        return Some(ReconcileResult {
            action: ReplayAction::HardSnap,
            latest_state: authoritative,
            replayed_frames: 0,
            pending_inputs,
            correction_distance: f32::INFINITY,
        });
    };
    let correction_distance = predicted.position.distance(authoritative.position);

    if correction_distance <= governance.soft_position_error {
        return Some(ReconcileResult {
            action: ReplayAction::Accepted,
            latest_state: predicted,
            replayed_frames: 0,
            pending_inputs,
            correction_distance,
        });
    }

    predicted_history.truncate_after(ack.auth_tick);

    let mut replay_state = authoritative.clone();
    if correction_distance >= governance.hard_snap_distance {
        input_history.clear();
        predicted_history.clear();
        predicted_history.push(authoritative.clone());

        return Some(ReconcileResult {
            action: ReplayAction::HardSnap,
            latest_state: authoritative,
            replayed_frames: 0,
            pending_inputs,
            correction_distance,
        });
    }

    let mut replay_frames = pending_frames;
    let action = if replay_frames.len() > governance.max_replay_frames {
        let start = replay_frames.len() - governance.max_replay_frames;
        replay_frames = replay_frames.split_off(start);
        input_history.retain_recent(governance.max_pending_inputs);
        ReplayAction::WindowTrimmed
    } else {
        ReplayAction::Replayed
    };

    for frame in &replay_frames {
        replay_state = predictor::step(&replay_state, frame, profile);
        predicted_history.push(replay_state.clone());
    }

    Some(ReconcileResult {
        action,
        latest_state: replay_state,
        replayed_frames: replay_frames.len(),
        pending_inputs,
        correction_distance,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        input::commands::MoveInputFrame,
        sim::types::{MovementMode, PredictedMoveState},
    };
    use bevy::prelude::{Vec2, Vec3};

    #[test]
    fn reconcile_replays_future_inputs_when_authoritative_state_diverges() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());

        let first = MoveInputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 100,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: 0,
        };
        let second = MoveInputFrame {
            seq: 2,
            client_tick: 2,
            ..first.clone()
        };

        input_history.push(first.clone());
        let predicted_one = predictor::step(&origin, &first, &profile);
        predicted_history.push(predicted_one.clone());

        input_history.push(second.clone());
        let predicted_two = predictor::step(&predicted_one, &second, &profile);
        predicted_history.push(predicted_two.clone());

        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: Vec3::new(5.0, 0.0, 0.0),
            velocity: Vec3::new(50.0, 0.0, 0.0),
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &crate::sim::governance::ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Replayed);
        assert_eq!(input_history.len(), 1);
        assert!(result.latest_state.position.x > ack.position.x);
    }

    #[test]
    fn reconcile_hard_snaps_when_correction_is_too_large() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);
        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());
        predicted_history.push(PredictedMoveState {
            tick: 1,
            position: Vec3::new(500.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        });

        let ack = MovementAck {
            ack_seq: 0,
            auth_tick: 1,
            position: Vec3::new(0.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let mut governance = crate::sim::governance::ReplayGovernance::default();
        governance.hard_snap_distance = 64.0;

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::HardSnap);
        assert_eq!(result.latest_state.position, Vec3::ZERO);
    }
}
