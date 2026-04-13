mod atoms;
mod integrator;
mod math;
mod types;

use rustler::NifResult;

use crate::types::{InputFrame, MovementProfile, MovementState};

rustler::init!("Elixir.SceneServer.Native.MovementEngine");

#[rustler::nif]
fn step(
    state: MovementState,
    input_frame: InputFrame,
    profile: MovementProfile,
) -> NifResult<MovementState> {
    Ok(integrator::step(&state, &input_frame, &profile))
}

#[rustler::nif]
fn replay(
    anchor_state: MovementState,
    input_frames: Vec<InputFrame>,
    profile: MovementProfile,
) -> NifResult<Vec<MovementState>> {
    Ok(integrator::replay(&anchor_state, &input_frames, &profile))
}
