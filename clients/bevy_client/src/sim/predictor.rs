//! Local fixed-step movement predictor.

use bevy::prelude::{Vec2, Vec3};

use crate::{
    input::commands::MoveInputFrame,
    sim::{
        profile::MovementProfile,
        types::{MovementMode, PredictedMoveState},
    },
};

/// Advances the predicted local movement state by one input frame.
pub fn step(
    previous: &PredictedMoveState,
    input: &MoveInputFrame,
    profile: &MovementProfile,
) -> PredictedMoveState {
    let dt = input.dt_ms as f32 / 1_000.0;
    let direction = normalize_or_zero(input.input_dir);
    let desired_velocity = direction.extend(0.0) * profile.max_speed * input.speed_scale;
    let velocity_error = desired_velocity - previous.velocity;
    let accel_limit = accel_limit(
        previous.velocity,
        desired_velocity,
        profile,
        input.is_braking(),
    );
    let accel_target = clamp_vec3_length(velocity_error / dt.max(f32::EPSILON), accel_limit);
    let acceleration =
        smooth_acceleration(previous.acceleration, accel_target, profile.max_jerk, dt);
    let velocity = clamp_vec3_length(previous.velocity + acceleration * dt, profile.max_speed);
    let position = previous.position + velocity * dt;

    PredictedMoveState {
        tick: input.client_tick,
        position,
        velocity,
        acceleration,
        movement_mode: MovementMode::Grounded,
    }
}

fn accel_limit(
    current_velocity: Vec3,
    desired_velocity: Vec3,
    profile: &MovementProfile,
    braking: bool,
) -> f32 {
    if braking {
        return profile.max_decel;
    }

    if desired_velocity.length_squared() <= f32::EPSILON
        || desired_velocity.length() < current_velocity.length()
    {
        profile.max_decel
    } else {
        profile.max_accel
    }
}

fn smooth_acceleration(current: Vec3, target: Vec3, max_jerk: f32, dt: f32) -> Vec3 {
    let delta = target - current;
    let max_delta = max_jerk * dt;
    if delta.length() <= max_delta {
        target
    } else {
        current + delta.normalize() * max_delta
    }
}

fn normalize_or_zero(direction: Vec2) -> Vec2 {
    if direction.length_squared() <= f32::EPSILON {
        Vec2::ZERO
    } else {
        direction.normalize()
    }
}

fn clamp_vec3_length(vector: Vec3, max_length: f32) -> Vec3 {
    if vector.length_squared() <= max_length * max_length {
        vector
    } else {
        vector.normalize() * max_length
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::prelude::Vec2;

    #[test]
    fn step_builds_velocity_gradually_with_acceleration() {
        let previous = PredictedMoveState::idle(Vec3::ZERO);
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
            tick: 1,
            position: Vec3::ZERO,
            velocity: Vec3::new(220.0, 0.0, 0.0),
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
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
}
