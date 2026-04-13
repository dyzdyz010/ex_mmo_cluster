use crate::sim::{
    history::{InputHistory, PredictedHistory},
    predictor,
    profile::MovementProfile,
    types::{MovementAck, PredictedMoveState},
};

#[derive(Debug, Clone, PartialEq)]
pub struct ReconcileResult {
    pub replayed: bool,
    pub latest_state: PredictedMoveState,
}

pub fn reconcile(
    ack: &MovementAck,
    input_history: &mut InputHistory,
    predicted_history: &mut PredictedHistory,
    profile: &MovementProfile,
    position_error_threshold: f32,
) -> Option<ReconcileResult> {
    input_history.drop_through(ack.ack_seq);

    let predicted = predicted_history.state_at_tick(ack.auth_tick)?.clone();
    let authoritative = PredictedMoveState {
        tick: ack.auth_tick,
        position: ack.position,
        velocity: ack.velocity,
        acceleration: ack.acceleration,
        movement_mode: ack.movement_mode,
    };

    if predicted.position.distance(authoritative.position) <= position_error_threshold {
        return Some(ReconcileResult {
            replayed: false,
            latest_state: predicted,
        });
    }

    predicted_history.truncate_after(ack.auth_tick);

    let mut replay_state = authoritative.clone();
    for frame in input_history.frames_after_tick(ack.auth_tick) {
        replay_state = predictor::step(&replay_state, frame, profile);
        predicted_history.push(replay_state.clone());
    }

    Some(ReconcileResult {
        replayed: true,
        latest_state: replay_state,
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
            0.01,
        )
        .expect("reconcile result");

        assert!(result.replayed);
        assert_eq!(input_history.len(), 1);
        assert!(result.latest_state.position.x > ack.position.x);
    }
}
