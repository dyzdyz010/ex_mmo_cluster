//! Thin adapter: Rustler structs ↔ `movement_core`. All kinematic logic now
//! lives in the shared `movement_core` crate (single source of truth).

use crate::types::{InputFrame, MovementProfile, MovementState};

pub fn step(
    previous: &MovementState,
    input: &InputFrame,
    profile: &MovementProfile,
) -> MovementState {
    let core_out = movement_core::integrator::step(
        &previous.to_core(),
        &input.to_core(),
        &profile.to_core(),
    );
    MovementState::from_core(&core_out)
}

pub fn replay(
    anchor: &MovementState,
    inputs: &[InputFrame],
    profile: &MovementProfile,
) -> Vec<MovementState> {
    let core_inputs: Vec<movement_core::InputFrame> =
        inputs.iter().map(|i| i.to_core()).collect();
    let core_states = movement_core::integrator::replay(
        &anchor.to_core(),
        &core_inputs,
        &profile.to_core(),
    );
    core_states.iter().map(MovementState::from_core).collect()
}
