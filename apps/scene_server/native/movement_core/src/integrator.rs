//! Authoritative deterministic integrator — single source of truth shared by
//! the scene_server NIF and the bevy_client local predictor.
//!
//! The `grounded_step` kinematics are a bit-exact port of the legacy
//! `movement_engine::integrator::step`. The Bevy client wraps this in an
//! `f32 ↔ f64` adapter whose documented round-trip budget is ≤ 1e-4.
//!
//! Mode dispatch layout (this round):
//!   - Grounded  → jerk-limited walking
//!   - Airborne  → reuses grounded (future jump placeholder)
//!   - Scripted  → no-op on pos/vel/accel (reserved for displacement skills)
//!   - Disabled  → zeroes velocity + acceleration, position held

use crate::{
    input::InputFrame,
    math::{
        add, clamp_vec3, div, magnitude, magnitude_sq, mul, normalize_or_zero, normalize_vec3, sub,
    },
    mode::MovementMode,
    profile::MovementProfile,
    state::MovementState,
};

pub fn step(
    previous: &MovementState,
    input: &InputFrame,
    profile: &MovementProfile,
) -> MovementState {
    let mode = MovementMode::transition(previous.movement_mode, input);
    match mode {
        MovementMode::Grounded => grounded_step(previous, input, profile, mode),
        MovementMode::Airborne => grounded_step(previous, input, profile, mode),
        MovementMode::Scripted => scripted_step(previous, input, mode),
        MovementMode::Disabled => disabled_step(previous, input, mode),
    }
}

pub fn replay(
    anchor: &MovementState,
    inputs: &[InputFrame],
    profile: &MovementProfile,
) -> Vec<MovementState> {
    let mut out = Vec::with_capacity(inputs.len());
    let mut current = anchor.clone();
    for input in inputs {
        current = step(&current, input, profile);
        out.push(current.clone());
    }
    out
}

fn grounded_step(
    previous: &MovementState,
    input: &InputFrame,
    profile: &MovementProfile,
    mode: MovementMode,
) -> MovementState {
    let dt = (input.dt_ms.max(1) as f64) / 1000.0;
    let dir2 = normalize_or_zero(input.input_dir);
    // speed_scale is client-supplied — clamp to [0, max_speed_scale] so a
    // tampered input can never amplify desired velocity past the server's
    // authoritative ceiling.
    let clamped_scale = input.speed_scale.clamp(0.0, profile.max_speed_scale);

    let desired_velocity = [
        dir2[0] * profile.max_speed * clamped_scale,
        dir2[1] * profile.max_speed * clamped_scale,
        0.0,
    ];

    let accel_limit = accel_limit(previous.velocity, desired_velocity, profile, input.braking());
    let velocity_error = sub(desired_velocity, previous.velocity);
    let accel_target = clamp_vec3(div(velocity_error, dt.max(f64::EPSILON)), accel_limit);
    let acceleration =
        smooth_acceleration(previous.acceleration, accel_target, profile.max_jerk, dt);
    let velocity = clamp_vec3(
        add(previous.velocity, mul(acceleration, dt)),
        profile.max_speed,
    );
    let position = add(previous.position, mul(velocity, dt));

    MovementState {
        position,
        velocity,
        acceleration,
        movement_mode: mode,
        tick: input.client_tick,
        seq: input.seq,
    }
}

fn scripted_step(
    previous: &MovementState,
    input: &InputFrame,
    mode: MovementMode,
) -> MovementState {
    MovementState {
        position: previous.position,
        velocity: previous.velocity,
        acceleration: previous.acceleration,
        movement_mode: mode,
        tick: input.client_tick,
        seq: input.seq,
    }
}

fn disabled_step(
    previous: &MovementState,
    input: &InputFrame,
    mode: MovementMode,
) -> MovementState {
    MovementState {
        position: previous.position,
        velocity: [0.0, 0.0, 0.0],
        acceleration: [0.0, 0.0, 0.0],
        movement_mode: mode,
        tick: input.client_tick,
        seq: input.seq,
    }
}

fn accel_limit(
    current_velocity: [f64; 3],
    desired_velocity: [f64; 3],
    profile: &MovementProfile,
    braking: bool,
) -> f64 {
    if braking {
        return profile.max_decel;
    }
    if magnitude_sq(desired_velocity) <= 1.0e-6
        || magnitude(desired_velocity) < magnitude(current_velocity)
    {
        profile.max_decel
    } else {
        profile.max_accel
    }
}

fn smooth_acceleration(
    current: [f64; 3],
    target: [f64; 3],
    max_jerk: f64,
    dt: f64,
) -> [f64; 3] {
    let delta = sub(target, current);
    let max_delta = max_jerk * dt;
    if magnitude(delta) <= max_delta {
        target
    } else {
        add(current, mul(normalize_vec3(delta), max_delta))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::MOVEMENT_FLAG_BRAKE;

    fn idle_at(pos: [f64; 3]) -> MovementState {
        MovementState::idle(pos)
    }

    fn moving_state(velocity: [f64; 3]) -> MovementState {
        MovementState {
            position: [0.0, 0.0, 0.0],
            velocity,
            acceleration: [0.0, 0.0, 0.0],
            movement_mode: MovementMode::Grounded,
            tick: 1,
            seq: 1,
        }
    }

    fn input_dir(seq: u32, dir: [f64; 2], flags: u16) -> InputFrame {
        InputFrame {
            seq,
            client_tick: seq,
            dt_ms: 100,
            input_dir: dir,
            speed_scale: 1.0,
            movement_flags: flags,
            movement_mode: MovementMode::Grounded,
        }
    }

    #[test]
    fn grounded_accel_builds_velocity_gradually() {
        let prev = idle_at([0.0, 0.0, 0.0]);
        let input = input_dir(1, [1.0, 0.0], 0);
        let profile = MovementProfile::default();

        let next = step(&prev, &input, &profile);
        assert!(next.velocity[0] > 0.0);
        assert!(next.velocity[0] < profile.max_speed);
        assert!(next.position[0] > 0.0);
        assert!(next.acceleration[0] > 0.0);
        assert_eq!(next.tick, 1);
        assert_eq!(next.seq, 1);
        assert_eq!(next.movement_mode, MovementMode::Grounded);
    }

    #[test]
    fn grounded_braking_applies_decel_limit() {
        let prev = moving_state([220.0, 0.0, 0.0]);
        let input = input_dir(2, [0.0, 0.0], MOVEMENT_FLAG_BRAKE);
        let profile = MovementProfile::default();

        let next = step(&prev, &input, &profile);
        assert!(next.velocity[0] < prev.velocity[0]);
    }

    #[test]
    fn grounded_turn_decelerates_then_redirects() {
        // Moving east at full speed, commanded to go north.
        let prev = moving_state([220.0, 0.0, 0.0]);
        let input = input_dir(2, [0.0, 1.0], 0);
        let profile = MovementProfile::default();

        let next = step(&prev, &input, &profile);
        // Jerk-limit means acceleration has a non-zero north component.
        assert!(next.acceleration[1] > 0.0);
        // And the east velocity strictly decreased (decel regime).
        assert!(next.velocity[0] < prev.velocity[0]);
    }

    #[test]
    fn grounded_jerk_clamp_bounds_acceleration_delta() {
        // With dt=0.1 and max_jerk=9000, accel delta magnitude ≤ 900 per step.
        let prev = idle_at([0.0, 0.0, 0.0]);
        let input = input_dir(1, [1.0, 0.0], 0);
        let profile = MovementProfile::default();

        let next = step(&prev, &input, &profile);
        let delta_mag = magnitude(sub(next.acceleration, prev.acceleration));
        let max_delta = profile.max_jerk * (input.dt_ms as f64 / 1000.0);
        // Small floating epsilon tolerance.
        assert!(delta_mag <= max_delta + 1.0e-9);
    }

    #[test]
    fn grounded_velocity_cannot_exceed_max_speed() {
        // Take many steps with full-direction input; final speed must stay bounded.
        let profile = MovementProfile::default();
        let mut current = idle_at([0.0, 0.0, 0.0]);
        for seq in 1..=200 {
            let input = input_dir(seq, [1.0, 0.0], 0);
            current = step(&current, &input, &profile);
        }
        assert!(magnitude(current.velocity) <= profile.max_speed + 1.0e-6);
    }

    #[test]
    fn scripted_step_holds_position_velocity_acceleration() {
        let prev = MovementState {
            position: [10.0, 20.0, 0.0],
            velocity: [5.0, -3.0, 0.0],
            acceleration: [1.0, 2.0, 0.0],
            movement_mode: MovementMode::Scripted,
            tick: 1,
            seq: 1,
        };
        let input = InputFrame {
            seq: 42,
            client_tick: 99,
            dt_ms: 100,
            input_dir: [1.0, 0.0], // ignored by scripted_step
            speed_scale: 1.0,
            movement_flags: 0,
            movement_mode: MovementMode::Scripted,
        };
        let next = step(&prev, &input, &MovementProfile::default());
        assert_eq!(next.position, prev.position);
        assert_eq!(next.velocity, prev.velocity);
        assert_eq!(next.acceleration, prev.acceleration);
        assert_eq!(next.movement_mode, MovementMode::Scripted);
        assert_eq!(next.tick, 99);
        assert_eq!(next.seq, 42);
    }

    #[test]
    fn disabled_step_zeroes_velocity_and_acceleration() {
        let prev = MovementState {
            position: [10.0, 20.0, 0.0],
            velocity: [100.0, -50.0, 0.0],
            acceleration: [200.0, 200.0, 0.0],
            movement_mode: MovementMode::Disabled,
            tick: 1,
            seq: 1,
        };
        let input = InputFrame {
            seq: 2,
            client_tick: 2,
            dt_ms: 100,
            input_dir: [1.0, 0.0],
            speed_scale: 1.0,
            movement_flags: 0,
            movement_mode: MovementMode::Disabled,
        };
        let next = step(&prev, &input, &MovementProfile::default());
        assert_eq!(next.position, prev.position);
        assert_eq!(next.velocity, [0.0, 0.0, 0.0]);
        assert_eq!(next.acceleration, [0.0, 0.0, 0.0]);
        assert_eq!(next.movement_mode, MovementMode::Disabled);
    }

    #[test]
    fn replay_is_deterministic_and_tracks_anchor_progression() {
        let anchor = idle_at([0.0, 0.0, 0.0]);
        let inputs: Vec<InputFrame> = (1u32..=5).map(|s| input_dir(s, [1.0, 0.0], 0)).collect();
        let profile = MovementProfile::default();

        let run_a = replay(&anchor, &inputs, &profile);
        let run_b = replay(&anchor, &inputs, &profile);

        assert_eq!(run_a.len(), 5);
        assert_eq!(run_a, run_b);
        // Monotone forward progress on x.
        for w in run_a.windows(2) {
            assert!(w[1].position[0] >= w[0].position[0]);
        }
        assert_eq!(run_a.last().unwrap().seq, 5);
        assert_eq!(run_a.last().unwrap().tick, 5);
    }

    #[test]
    fn grounded_clamps_speed_scale_to_profile_ceiling() {
        // speed_scale from a tampered client must not amplify desired velocity
        // past profile.max_speed_scale. With default max_speed_scale=1.0,
        // sending speed_scale=1e6 must match speed_scale=1.0 exactly.
        let prev = idle_at([0.0, 0.0, 0.0]);
        let profile = MovementProfile::default();

        let legitimate = InputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 100,
            input_dir: [1.0, 0.0],
            speed_scale: 1.0,
            movement_flags: 0,
            movement_mode: MovementMode::Grounded,
        };
        let tampered = InputFrame {
            speed_scale: 1.0e6,
            ..legitimate.clone()
        };
        let negative = InputFrame {
            speed_scale: -5.0,
            ..legitimate.clone()
        };

        let ok = step(&prev, &legitimate, &profile);
        let clamped = step(&prev, &tampered, &profile);
        assert_eq!(ok.position, clamped.position);
        assert_eq!(ok.velocity, clamped.velocity);
        assert_eq!(ok.acceleration, clamped.acceleration);

        // Negative scale collapses to 0 (braking-like, no forward desire).
        let zero = step(&prev, &negative, &profile);
        assert_eq!(zero.velocity, [0.0, 0.0, 0.0]);
    }

    #[test]
    fn golden_single_step_matches_legacy_algorithm() {
        // Reproduces the output shape of the legacy movement_engine::step for
        // the canonical (idle → input_dir=+x, dt=100ms) input. Any change here
        // indicates divergence from the server's f64 kinematics contract.
        let prev = idle_at([0.0, 0.0, 0.0]);
        let input = input_dir(1, [1.0, 0.0], 0);
        let profile = MovementProfile::default();
        let next = step(&prev, &input, &profile);

        // Deterministic algorithm identity:
        // dt = 0.1; desired = (220,0,0); velocity_error = (220,0,0)
        // accel_target = clamp((2200,0,0), accel_limit=1200) = (1200,0,0)
        // max_delta = 9000*0.1 = 900; delta_mag=1200 > 900, so
        // acceleration = current + unit(delta)*900 = (900,0,0)
        // velocity = clamp((0+900*0.1,0,0), 220) = (90,0,0)
        // position = (0+90*0.1, 0, 0) = (9.0, 0, 0)
        assert!((next.acceleration[0] - 900.0).abs() < 1.0e-9);
        assert!((next.velocity[0] - 90.0).abs() < 1.0e-9);
        assert!((next.position[0] - 9.0).abs() < 1.0e-9);
        assert_eq!(next.acceleration[1], 0.0);
        assert_eq!(next.acceleration[2], 0.0);
    }
}
