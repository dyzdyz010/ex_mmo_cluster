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

#[cfg(test)]
mod invariants {
    use super::*;
    use crate::{
        input::{InputFrame, MOVEMENT_FLAG_BRAKE},
        math::magnitude,
        mode::MovementMode,
        profile::MovementProfile,
        state::MovementState,
    };

    fn mk_input(seq: u32, dir: [f64; 2], speed_scale: f64, flags: u16) -> InputFrame {
        InputFrame {
            seq,
            client_tick: seq,
            dt_ms: 100,
            input_dir: dir,
            speed_scale,
            movement_flags: flags,
            movement_mode: MovementMode::Grounded,
        }
    }

    // -----------------------------------------------------------------------
    // 1. Velocity never exceeds the effective speed budget for any tick.
    //
    //    Effective ceiling = profile.max_speed * min(speed_scale, max_speed_scale).
    //    The integrator clamps velocity to profile.max_speed regardless, and
    //    desired velocity is attractor at max_speed * clamped_scale, so the
    //    magnitude can never exceed that ceiling either.
    // -----------------------------------------------------------------------
    #[test]
    fn test_velocity_never_exceeds_speed_budget() {
        let speed_scales = [0.0_f64, 0.25, 0.5, 1.0];
        let max_speed_scale_values = [1.0_f64, 2.0];

        for &ss in &speed_scales {
            for &mss in &max_speed_scale_values {
                let profile = MovementProfile {
                    max_speed_scale: mss,
                    ..MovementProfile::default()
                };
                let ceiling =
                    profile.max_speed * ss.min(profile.max_speed_scale) + 1.0e-9;
                let mut state = MovementState::idle([0.0, 0.0, 0.0]);

                for seq in 1u32..=200 {
                    let input = mk_input(seq, [1.0, 0.0], ss, 0);
                    state = step(&state, &input, &profile);
                    assert!(
                        magnitude(state.velocity) <= ceiling,
                        "tick {seq}: speed_scale={ss} max_speed_scale={mss} \
                         vel_mag={} ceiling={ceiling}",
                        magnitude(state.velocity)
                    );
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 2. Per-tick change in acceleration is bounded by max_jerk * dt.
    //
    //    Alternating between zero input and full-direction input stresses the
    //    jerk limiter maximally because desired acceleration flips sign each
    //    tick.
    // -----------------------------------------------------------------------
    #[test]
    fn test_jerk_bound_per_tick() {
        let profile = MovementProfile::default();
        let dt = profile.fixed_dt_ms as f64 / 1000.0;
        let max_accel_delta = profile.max_jerk * dt + 1.0e-9;

        let mut state = MovementState::idle([0.0, 0.0, 0.0]);
        let mut prev_accel = state.acceleration;

        for seq in 1u32..=100 {
            // Alternate: even ticks full-direction, odd ticks zero input.
            let dir = if seq % 2 == 0 {
                [1.0_f64, 0.0]
            } else {
                [0.0_f64, 0.0]
            };
            let input = mk_input(seq, dir, 1.0, 0);
            state = step(&state, &input, &profile);

            let accel_delta = [
                state.acceleration[0] - prev_accel[0],
                state.acceleration[1] - prev_accel[1],
                state.acceleration[2] - prev_accel[2],
            ];
            let delta_mag = magnitude(accel_delta);
            assert!(
                delta_mag <= max_accel_delta,
                "tick {seq}: accel delta mag={delta_mag} exceeds max_jerk*dt={max_accel_delta}"
            );
            prev_accel = state.acceleration;
        }
    }

    // -----------------------------------------------------------------------
    // 3. Position displacement per tick is bounded by max_speed * dt.
    //
    //    Input directions are generated deterministically from a trigonometric
    //    sequence to exercise varied headings without introducing randomness.
    // -----------------------------------------------------------------------
    #[test]
    fn test_position_delta_bounded_by_speed_dt() {
        let profile = MovementProfile::default();
        let dt = profile.fixed_dt_ms as f64 / 1000.0;
        let max_pos_delta = profile.max_speed * dt + 1.0e-6;

        let mut state = MovementState::idle([0.0, 0.0, 0.0]);
        let mut prev_pos = state.position;

        for seq in 1u32..=200 {
            let i = seq as f64;
            let dir = [(i * 0.37_f64).sin(), (i * 0.41_f64).cos()];
            let input = mk_input(seq, dir, 1.0, 0);
            state = step(&state, &input, &profile);

            let pos_delta = [
                state.position[0] - prev_pos[0],
                state.position[1] - prev_pos[1],
                state.position[2] - prev_pos[2],
            ];
            let delta_mag = magnitude(pos_delta);
            assert!(
                delta_mag <= max_pos_delta,
                "tick {seq}: position delta mag={delta_mag} exceeds max_speed*dt={max_pos_delta}"
            );
            prev_pos = state.position;
        }
    }

    // -----------------------------------------------------------------------
    // 4. Braking with zero input reduces velocity magnitude monotonically
    //    while speed is above a jerk-resolution threshold.
    //
    //    Seeds a state at max_speed, then runs 50 ticks with zero input and
    //    MOVEMENT_FLAG_BRAKE set.  Because smooth_acceleration is jerk-limited
    //    the residual deceleration can carry speed briefly into the opposite
    //    direction once the body has already stopped; the invariant therefore
    //    only applies while the previous tick's speed exceeds the per-tick
    //    jerk-induced velocity budget (max_jerk * dt * dt) — below that
    //    threshold the integrator has effectively halted.  After 50 ticks the
    //    net distance travelled must be strictly less than the 1-tick maximum.
    // -----------------------------------------------------------------------
    #[test]
    fn test_braking_reduces_velocity_monotonically() {
        let profile = MovementProfile::default();
        let dt = profile.fixed_dt_ms as f64 / 1000.0;
        // Minimum speed below which jerk-carry-over can briefly reverse
        // velocity — below this the body is kinematically stopped.
        let jerk_floor = profile.max_jerk * dt * dt + 1.0e-9;

        // Seed state: full speed in +x direction.
        let mut state = MovementState {
            position: [0.0, 0.0, 0.0],
            velocity: [profile.max_speed, 0.0, 0.0],
            acceleration: [0.0, 0.0, 0.0],
            movement_mode: MovementMode::Grounded,
            tick: 0,
            seq: 0,
        };
        let mut prev_speed = magnitude(state.velocity);

        for seq in 1u32..=50 {
            let input = mk_input(seq, [0.0, 0.0], 1.0, MOVEMENT_FLAG_BRAKE);
            state = step(&state, &input, &profile);

            let speed = magnitude(state.velocity);
            // Assert monotone decrease only while the previous speed was
            // above the jerk-floor; once we are in jerk-carry-over territory
            // the sign of velocity is implementation-defined.
            if prev_speed > jerk_floor {
                assert!(
                    speed <= prev_speed + 1.0e-9,
                    "tick {seq}: speed {speed} increased from previous {prev_speed} \
                     while braking (above jerk floor {jerk_floor})"
                );
            }
            prev_speed = speed;
        }

        // After 50 ticks (5 s) the body must have effectively halted:
        // remaining speed must be well below the 1-tick maximum travel.
        let max_one_tick_speed = profile.max_speed * dt;
        assert!(
            prev_speed < max_one_tick_speed,
            "speed after 50 braking ticks ({prev_speed}) should be below \
             one-tick max ({max_one_tick_speed})"
        );
    }

    // -----------------------------------------------------------------------
    // 5. Sustained max-direction input converges to terminal velocity.
    //
    //    After 100 ticks (10 seconds at dt=0.1s) of full +x input the speed
    //    must be within 1 % of profile.max_speed * profile.max_speed_scale.
    // -----------------------------------------------------------------------
    #[test]
    fn test_constant_input_converges_to_terminal_velocity() {
        let profile = MovementProfile::default();
        let terminal = profile.max_speed * profile.max_speed_scale;
        let tolerance = terminal * 0.01;

        let mut state = MovementState::idle([0.0, 0.0, 0.0]);
        for seq in 1u32..=100 {
            let input = mk_input(seq, [1.0, 0.0], 1.0, 0);
            state = step(&state, &input, &profile);
        }

        let final_speed = magnitude(state.velocity);
        assert!(
            (final_speed - terminal).abs() <= tolerance,
            "final speed {final_speed} not within 1% of terminal {terminal}"
        );
    }
}

/// Behavioral tests for each MovementMode variant — UE5 EMovementMode analogue.
///
/// Mapping:
///   Grounded  ↔ MOVE_Walking  — jerk-limited walking kinematics
///   Airborne  ↔ MOVE_Falling  — placeholder; currently reuses grounded step
///   Scripted  ↔ MOVE_Flying   — displacement-skill hook; currently no-op
///   Disabled  ↔ MOVE_None     — CC/stun; zeroes velocity + acceleration
#[cfg(test)]
mod mode_dispatch {
    use super::*;
    use crate::math::magnitude;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    fn idle_grounded() -> MovementState {
        MovementState::idle([0.0, 0.0, 0.0])
    }

    fn seeded_state(mode: MovementMode, velocity: [f64; 3], position: [f64; 3]) -> MovementState {
        MovementState {
            position,
            velocity,
            acceleration: [0.0, 0.0, 0.0],
            movement_mode: mode,
            tick: 0,
            seq: 0,
        }
    }

    /// Full diagonal input at speed_scale=1.0 tagged with the given mode.
    /// The integrator resolves the mode from the *previous state*, not the input
    /// frame, but we tag consistently for readability.
    fn diagonal_input(seq: u32, mode: MovementMode) -> InputFrame {
        InputFrame {
            seq,
            client_tick: seq,
            dt_ms: 100,
            input_dir: [1.0, 1.0],
            speed_scale: 1.0,
            movement_flags: 0,
            movement_mode: mode,
        }
    }

    // -------------------------------------------------------------------------
    // Test 1: Grounded — normal kinematics accumulate velocity and position
    // -------------------------------------------------------------------------

    /// Seeds a Grounded state with full diagonal input + full speed_scale for
    /// 10 ticks. Velocity must accumulate and position must advance.
    ///
    /// UE5 analogue: MOVE_Walking calls CalcVelocity then performs Euler
    /// integration every tick; velocity magnitude must be non-zero by tick 2.
    #[test]
    fn grounded_mode_dispatches_normal_kinematics() {
        let profile = MovementProfile::default();
        let mut state = idle_grounded();
        let mut vel_mag_after_tick2 = 0.0_f64;

        for seq in 1u32..=10 {
            let input = diagonal_input(seq, MovementMode::Grounded);
            state = step(&state, &input, &profile);
            if seq == 2 {
                vel_mag_after_tick2 = magnitude(state.velocity);
            }
            assert_eq!(
                state.movement_mode,
                MovementMode::Grounded,
                "tick {seq}: mode must stay Grounded"
            );
        }

        assert!(
            vel_mag_after_tick2 > 0.0,
            "velocity magnitude must be > 0 after tick 2 (got {vel_mag_after_tick2})"
        );
        assert!(
            state.position[0] > 0.0 || state.position[1] > 0.0,
            "position must advance in at least one axis after 10 Grounded ticks \
             (pos={:?})",
            state.position
        );
        assert!(
            magnitude(state.velocity) <= profile.max_speed + 1.0e-6,
            "velocity must not exceed max_speed"
        );
    }

    // -------------------------------------------------------------------------
    // Test 2: Scripted — input is a complete no-op
    // -------------------------------------------------------------------------

    /// Observed scripted-mode contract (from `scripted_step`):
    ///   next.position     == previous.position      — no integrator-driven drift
    ///   next.velocity     == previous.velocity      — input direction NOT applied
    ///   next.acceleration == previous.acceleration  — input acceleration NOT applied
    ///
    /// The skill/server system drives position externally while in Scripted
    /// mode; the input integrator is intentionally a complete no-op.
    ///
    /// UE5 analogue: MOVE_Flying reserved for root-motion / displacement skills.
    #[test]
    fn scripted_mode_bypasses_input() {
        let profile = MovementProfile::default();
        // Seed a non-zero +x velocity so we can distinguish "unchanged" from "zeroed".
        let initial_vel = [5.0, 0.0, 0.0];
        let initial_pos = [0.0, 0.0, 0.0];
        let mut state = seeded_state(MovementMode::Scripted, initial_vel, initial_pos);

        for seq in 1u32..=5 {
            // Command +y movement — must be entirely ignored by the scripted branch.
            let input = InputFrame {
                seq,
                client_tick: seq,
                dt_ms: 100,
                input_dir: [0.0, 1.0],
                speed_scale: 1.0,
                movement_flags: 0,
                movement_mode: MovementMode::Scripted,
            };
            let prev_pos = state.position;
            let prev_vel = state.velocity;
            let prev_accel = state.acceleration;

            state = step(&state, &input, &profile);

            assert_eq!(
                state.velocity, prev_vel,
                "tick {seq}: Scripted must not modify velocity (input bypassed)"
            );
            assert_eq!(
                state.acceleration, prev_accel,
                "tick {seq}: Scripted must not modify acceleration (input bypassed)"
            );
            assert_eq!(
                state.position, prev_pos,
                "tick {seq}: Scripted must not advance position via input integrator"
            );
            assert_eq!(
                state.movement_mode,
                MovementMode::Scripted,
                "tick {seq}: mode must remain Scripted"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Test 3: Disabled — velocity + acceleration zeroed, position held
    // -------------------------------------------------------------------------

    /// Observed disabled-mode contract (from `disabled_step`):
    ///   next.velocity     == [0, 0, 0]         — zeroed every tick
    ///   next.acceleration == [0, 0, 0]         — zeroed every tick
    ///   next.position     == previous.position — held, no drift while stunned
    ///
    /// This matches the mode.rs doc comment: "CC / stun; zeroes velocity and
    /// acceleration". The documented contract is fully implemented.
    ///
    /// UE5 analogue: MOVE_None / CC stun where the actor is completely frozen.
    #[test]
    fn disabled_mode_freezes_state() {
        let profile = MovementProfile::default();
        let initial_pos = [5.0, 5.0, 0.0];
        // Seed a non-zero velocity to confirm it is zeroed on the first tick.
        let mut state = seeded_state(MovementMode::Disabled, [10.0, 0.0, 0.0], initial_pos);

        for seq in 1u32..=5 {
            let input = diagonal_input(seq, MovementMode::Disabled);
            state = step(&state, &input, &profile);

            assert_eq!(
                state.velocity,
                [0.0, 0.0, 0.0],
                "tick {seq}: Disabled must zero velocity"
            );
            assert_eq!(
                state.acceleration,
                [0.0, 0.0, 0.0],
                "tick {seq}: Disabled must zero acceleration"
            );
            assert_eq!(
                state.position, initial_pos,
                "tick {seq}: Disabled must hold position — no drift while stunned"
            );
            assert_eq!(
                state.movement_mode,
                MovementMode::Disabled,
                "tick {seq}: mode must remain Disabled"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Test 4: Airborne — currently reuses grounded step (placeholder)
    // -------------------------------------------------------------------------

    /// Per the mode.rs doc comment: "reserved for future jump; currently reuses
    /// grounded step". This test confirms that Airborne and Grounded produce
    /// bit-exact identical position and velocity for the same seed + input
    /// sequence, validating the shared code path.
    ///
    /// When jump/gravity physics land, this test will diverge intentionally and
    /// must be updated to assert arc/gravity behavior instead of equality.
    ///
    /// UE5 analogue: MOVE_Falling — gravity not yet implemented.
    #[test]
    fn airborne_mode_currently_reuses_grounded_behavior() {
        let profile = MovementProfile::default();

        let mut grounded = idle_grounded();
        let mut airborne = MovementState {
            movement_mode: MovementMode::Airborne,
            ..idle_grounded()
        };

        for seq in 1u32..=10 {
            let g_input = diagonal_input(seq, MovementMode::Grounded);
            let a_input = InputFrame {
                movement_mode: MovementMode::Airborne,
                ..g_input.clone()
            };

            grounded = step(&grounded, &g_input, &profile);
            airborne = step(&airborne, &a_input, &profile);

            // Both must be bit-exact — they share grounded_step internally.
            for axis in 0..3 {
                assert!(
                    (grounded.position[axis] - airborne.position[axis]).abs() < 1.0e-9,
                    "tick {seq}: Airborne position[{axis}] ({}) diverges from \
                     Grounded ({}) — expected identical while placeholder is active",
                    airborne.position[axis],
                    grounded.position[axis]
                );
                assert!(
                    (grounded.velocity[axis] - airborne.velocity[axis]).abs() < 1.0e-9,
                    "tick {seq}: Airborne velocity[{axis}] ({}) diverges from \
                     Grounded ({}) — expected identical while placeholder is active",
                    airborne.velocity[axis],
                    grounded.velocity[axis]
                );
            }
        }
    }
}

/// Long-horizon determinism and numerical stability tests.
///
/// Reference: IEEE 754 double-precision accumulation bounds + Glenn Fiedler
/// "Fix Your Timestep!" deterministic fixed-timestep guarantees.
///
/// All four tests run 100_000 consecutive integrator ticks in release mode
/// and complete well under 2 seconds on modern hardware. They are NOT marked
/// #[ignore] because `cargo test --lib stability --release` targets only
/// this module and is fast enough for CI. If you run the full test suite in
/// debug mode and find them slow, opt in selectively:
///   cargo test --lib stability --release
#[cfg(test)]
mod stability {
    use super::*;
    use crate::{
        input::InputFrame,
        mode::MovementMode,
        profile::MovementProfile,
        state::MovementState,
    };

    const TICKS: u32 = 100_000;

    fn profile() -> MovementProfile {
        MovementProfile::default()
    }

    fn origin() -> MovementState {
        MovementState::idle([0.0, 0.0, 0.0])
    }

    /// Deterministic input direction from tick index `i`.
    /// raw_x = ((i*37+13) % 100) / 100.0, raw_y = ((i*41+7) % 100) / 100.0,
    /// then normalize to unit vector. Produces a varied but fully deterministic
    /// heading each tick with no external randomness.
    fn det_dir(i: u32) -> [f64; 2] {
        let raw_x = ((i as u64 * 37 + 13) % 100) as f64 / 100.0;
        let raw_y = ((i as u64 * 41 + 7) % 100) as f64 / 100.0;
        let mag = (raw_x * raw_x + raw_y * raw_y).sqrt();
        if mag < f64::EPSILON {
            [0.0, 0.0]
        } else {
            [raw_x / mag, raw_y / mag]
        }
    }

    fn det_input(i: u32) -> InputFrame {
        InputFrame {
            seq: i,
            client_tick: i,
            dt_ms: 100,
            input_dir: det_dir(i),
            speed_scale: 1.0,
            movement_flags: 0,
            movement_mode: MovementMode::Grounded,
        }
    }

    // -------------------------------------------------------------------------
    // Test 1: bit-exact repeatability over 100k ticks
    // -------------------------------------------------------------------------
    /// Run the same 100_000-tick deterministic input sequence twice from the
    /// same initial state and assert the final states are bit-identical (==
    /// on f64, not approximate).
    ///
    /// Verifies the Fiedler fixed-timestep guarantee: same inputs => same
    /// outputs regardless of wall-clock, scheduling, or FP rounding mode.
    /// Any divergence indicates a non-deterministic code path (e.g. HashMap
    /// ordering, uninitialized value, platform-variant FP instruction).
    #[test]
    fn long_horizon_deterministic_repeatability() {
        let profile = profile();

        let run = |start: MovementState| {
            let mut state = start;
            for i in 1..=TICKS {
                state = step(&state, &det_input(i), &profile);
            }
            state
        };

        let final_a = run(origin());
        let final_b = run(origin());

        // == on f64 compares raw IEEE 754 bit patterns (NaN != NaN is irrelevant
        // here since test 2 already rules out NaN).
        assert_eq!(
            final_a.position, final_b.position,
            "position diverged between two identical runs"
        );
        assert_eq!(
            final_a.velocity, final_b.velocity,
            "velocity diverged between two identical runs"
        );
        assert_eq!(
            final_a.acceleration, final_b.acceleration,
            "acceleration diverged between two identical runs"
        );
        assert_eq!(
            final_a.movement_mode, final_b.movement_mode,
            "movement_mode diverged between two identical runs"
        );
    }

    // -------------------------------------------------------------------------
    // Test 2: no NaN or Inf anywhere in the trajectory
    // -------------------------------------------------------------------------
    /// Over 100_000 ticks assert every tick's position, velocity, and
    /// acceleration components remain finite (no NaN, no Inf).
    ///
    /// At max_speed=220 and dt=0.1 the integrator accumulates at most 2.2
    /// units/tick; 100k ticks yields ~220k units, well inside f64 range
    /// (~1.8e308). Any NaN/Inf signals division-by-zero, degenerate input, or
    /// FP overflow in intermediate kinematic calculations.
    #[test]
    fn long_horizon_no_nan_or_inf() {
        let profile = profile();
        let mut state = origin();

        for i in 1..=TICKS {
            state = step(&state, &det_input(i), &profile);

            for (k, &v) in state.position.iter().enumerate() {
                assert!(
                    v.is_finite(),
                    "tick {i}: position[{k}] = {v} is not finite"
                );
            }
            for (k, &v) in state.velocity.iter().enumerate() {
                assert!(
                    v.is_finite(),
                    "tick {i}: velocity[{k}] = {v} is not finite"
                );
            }
            for (k, &v) in state.acceleration.iter().enumerate() {
                assert!(
                    v.is_finite(),
                    "tick {i}: acceleration[{k}] = {v} is not finite"
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // Test 3: velocity budget never exceeded under sustained full input
    // -------------------------------------------------------------------------
    /// Over 100_000 ticks with sustained full +x input at max speed_scale,
    /// verify the velocity magnitude never exceeds
    /// `profile.max_speed * profile.max_speed_scale * (1 + 1e-6)`.
    ///
    /// The 1e-6 guard matches the invariants module's accumulated-FP budget
    /// over a long simulation. 100k jerk-limited integration ticks accumulate
    /// more drift than 200-tick invariant tests, so the epsilon must be at
    /// least as loose to avoid flaky CI without hiding real speed-hacks.
    /// Exceeding this bound would mean a speed-hack vector exists: a client
    /// could accumulate velocity above the server ceiling via FP drift.
    #[test]
    fn long_horizon_velocity_budget_holds() {
        let profile = profile();
        let budget = profile.max_speed * profile.max_speed_scale * (1.0 + 1.0e-6);

        let mut state = origin();
        for i in 1..=TICKS {
            let input = InputFrame {
                seq: i,
                client_tick: i,
                dt_ms: 100,
                input_dir: [1.0, 0.0],
                speed_scale: 1.0,
                movement_flags: 0,
                movement_mode: MovementMode::Grounded,
            };
            state = step(&state, &input, &profile);

            let speed = (state.velocity[0] * state.velocity[0]
                + state.velocity[1] * state.velocity[1]
                + state.velocity[2] * state.velocity[2])
                .sqrt();
            assert!(
                speed <= budget,
                "tick {i}: speed {speed} exceeded budget {budget}"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Test 4: mirror symmetry -- opposite inputs produce exact reflections
    // -------------------------------------------------------------------------
    /// Run 100_000-tick sinusoidal sequences with two antipodal input series:
    ///   dir_a = ( sin(i*0.1),  cos(i*0.1))
    ///   dir_b = (-sin(i*0.1), -cos(i*0.1))
    ///
    /// Starting from the origin, the two trajectories must be exact reflections:
    /// |pos_a + pos_b|.magnitude() < 1e-6.
    ///
    /// Mirror symmetry failure exposes an asymmetric FP error path -- e.g. a
    /// branch in accel_limit that fires only for positive velocity, or a
    /// clamp_vec3 implementation that is not odd-symmetric.
    #[test]
    fn long_horizon_mirror_symmetry() {
        let profile = profile();

        let make_input = |i: u32, sign: f64| -> InputFrame {
            let angle = (i as f64) * 0.1_f64;
            InputFrame {
                seq: i,
                client_tick: i,
                dt_ms: 100,
                input_dir: [sign * angle.sin(), sign * angle.cos()],
                speed_scale: 1.0,
                movement_flags: 0,
                movement_mode: MovementMode::Grounded,
            }
        };

        let mut state_a = origin();
        let mut state_b = origin();

        for i in 1..=TICKS {
            state_a = step(&state_a, &make_input(i, 1.0), &profile);
            state_b = step(&state_b, &make_input(i, -1.0), &profile);
        }

        // pos_a + pos_b should equal the zero vector to within 1e-6.
        let sum: [f64; 3] = [
            state_a.position[0] + state_b.position[0],
            state_a.position[1] + state_b.position[1],
            state_a.position[2] + state_b.position[2],
        ];
        let magnitude = (sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]).sqrt();

        assert!(
            magnitude < 1.0e-6,
            "|pos_a + pos_b| = {magnitude} >= 1e-6; mirror symmetry broken.\n\
             pos_a = {:?}\n\
             pos_b = {:?}\n\
             sum   = {:?}",
            state_a.position,
            state_b.position,
            sum
        );
    }
}
