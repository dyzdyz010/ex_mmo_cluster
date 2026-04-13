use rustler::Atom;

use crate::{
    atoms,
    math::{
        add, clamp_vec3, div, magnitude, magnitude_sq, mul, normalize_or_zero, normalize_vec3, sub,
    },
    types::{InputFrame, MovementProfile, MovementState},
};

pub fn step(
    previous: &MovementState,
    input: &InputFrame,
    profile: &MovementProfile,
) -> MovementState {
    let dt = (input.dt_ms.max(1) as f64) / 1000.0;
    let (dir_x, dir_y) = normalize_or_zero(input.input_dir);

    let desired_velocity = (
        dir_x * profile.max_speed * input.speed_scale,
        dir_y * profile.max_speed * input.speed_scale,
        0.0,
    );

    let accel_limit = accel_limit(
        previous.velocity,
        desired_velocity,
        profile,
        input.braking(),
    );
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
        tick: input.client_tick,
        position,
        velocity,
        acceleration,
        movement_mode: grounded_atom(),
    }
}

pub fn replay(
    anchor: &MovementState,
    inputs: &[InputFrame],
    profile: &MovementProfile,
) -> Vec<MovementState> {
    let mut states = Vec::with_capacity(inputs.len());
    let mut current = anchor.clone();

    for input in inputs {
        current = step(&current, input, profile);
        states.push(current.clone());
    }

    states
}

fn accel_limit(
    current_velocity: (f64, f64, f64),
    desired_velocity: (f64, f64, f64),
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
    current: (f64, f64, f64),
    target: (f64, f64, f64),
    max_jerk: f64,
    dt: f64,
) -> (f64, f64, f64) {
    let delta = sub(target, current);
    let max_delta = max_jerk * dt;

    if magnitude(delta) <= max_delta {
        target
    } else {
        add(current, mul(normalize_vec3(delta), max_delta))
    }
}

fn grounded_atom() -> Atom {
    atoms::grounded()
}
