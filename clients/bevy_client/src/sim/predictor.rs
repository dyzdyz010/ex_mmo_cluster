//! Local fixed-step movement predictor.
//!
//! The kinematic algorithm lives in `movement_core::integrator` — this file
//! is a thin `f32 ↔ f64` adapter so the Bevy client keeps its native `Vec3`
//! surface while sharing the authoritative maths with the server NIF.

use crate::{
    input::commands::MoveInputFrame,
    sim::{profile::MovementProfile, types::PredictedMoveState},
};

/// Advances the predicted local movement state by one input frame.
pub fn step(
    previous: &PredictedMoveState,
    input: &MoveInputFrame,
    profile: &MovementProfile,
) -> PredictedMoveState {
    let core_out = movement_core::integrator::step(
        &previous.to_core(),
        &input_to_core(input),
        &profile.to_core(),
    );
    PredictedMoveState::from_core(&core_out)
}

fn input_to_core(input: &MoveInputFrame) -> movement_core::InputFrame {
    movement_core::InputFrame {
        seq: input.seq,
        client_tick: input.client_tick,
        dt_ms: input.dt_ms,
        input_dir: [input.input_dir.x as f64, input.input_dir.y as f64],
        speed_scale: input.speed_scale as f64,
        movement_flags: input.movement_flags,
        movement_mode: movement_core::MovementMode::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::prelude::Vec2;

    #[test]
    fn step_builds_velocity_gradually_with_acceleration() {
        let previous = PredictedMoveState::idle(bevy::prelude::Vec3::ZERO);
        let input = MoveInputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 100,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: 0,
        };
        let profile = MovementProfile::default();

        let next = step(&previous, &input, &profile);

        assert!(next.velocity.x > 0.0);
        assert!(next.velocity.x < profile.max_speed);
        assert!(next.position.x > 0.0);
        assert!(next.acceleration.x > 0.0);
    }

    #[test]
    fn braking_uses_deceleration_limit() {
        let previous = PredictedMoveState {
            seq: 1,
            tick: 1,
            position: bevy::prelude::Vec3::ZERO,
            velocity: bevy::prelude::Vec3::new(220.0, 0.0, 0.0),
            acceleration: bevy::prelude::Vec3::ZERO,
            movement_mode: crate::sim::types::MovementMode::Grounded,
            ground_z: 0.0,
        };
        let input = MoveInputFrame {
            seq: 2,
            client_tick: 2,
            dt_ms: 100,
            input_dir: Vec2::ZERO,
            speed_scale: 1.0,
            movement_flags: crate::input::commands::MOVEMENT_FLAG_BRAKE,
        };
        let profile = MovementProfile::default();

        let next = step(&previous, &input, &profile);

        assert!(next.velocity.x < previous.velocity.x);
    }

    #[test]
    fn core_bridge_round_trip_matches_core_reference_values() {
        // Golden: (idle, +x, dt=100ms, default profile) → x position ≈ 9.0,
        // x velocity ≈ 90.0, x acceleration ≈ 900.0 (see movement_core::
        // integrator::golden_single_step_matches_legacy_algorithm).
        let previous = PredictedMoveState::idle(bevy::prelude::Vec3::ZERO);
        let input = MoveInputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 100,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: 0,
        };
        let profile = MovementProfile::default();
        let next = step(&previous, &input, &profile);

        assert!((next.position.x - 9.0).abs() < 1.0e-4);
        assert!((next.velocity.x - 90.0).abs() < 1.0e-3);
        assert!((next.acceleration.x - 900.0).abs() < 1.0e-2);
    }
}
