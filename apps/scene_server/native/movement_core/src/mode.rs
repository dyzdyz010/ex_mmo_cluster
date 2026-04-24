//! MovementMode state machine.
//!
//! Four variants shared verbatim with the bevy_client and the NIF atoms:
//! - `Grounded`  — standard walking; the only mode actively driven this round
//! - `Airborne`  — reserved for future jump; currently reuses grounded step
//! - `Scripted`  — reserved for displacement skills; currently no-op
//! - `Disabled`  — CC / stun; zeroes velocity and acceleration

use crate::input::InputFrame;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MovementMode {
    Grounded,
    Airborne,
    Scripted,
    Disabled,
}

impl Default for MovementMode {
    fn default() -> Self {
        Self::Grounded
    }
}

impl MovementMode {
    /// Decide the mode for the upcoming step.
    ///
    /// Jump is a one-shot intent: only a grounded actor can enter Airborne from
    /// a jump flag. Airborne cannot re-trigger the impulse until it lands.
    pub fn transition(prev: MovementMode, input: &InputFrame) -> MovementMode {
        match prev {
            MovementMode::Grounded if input.jump_requested() => MovementMode::Airborne,
            _ => prev,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_grounded() {
        assert_eq!(MovementMode::default(), MovementMode::Grounded);
    }

    #[test]
    fn transition_preserves_previous_mode_without_jump() {
        let input = InputFrame::idle(1, 1);
        assert_eq!(
            MovementMode::transition(MovementMode::Grounded, &input),
            MovementMode::Grounded
        );
        assert_eq!(
            MovementMode::transition(MovementMode::Disabled, &input),
            MovementMode::Disabled
        );
    }

    #[test]
    fn grounded_jump_enters_airborne_once() {
        let mut input = InputFrame::idle(1, 1);
        input.movement_flags = crate::input::MOVEMENT_FLAG_JUMP;
        assert_eq!(
            MovementMode::transition(MovementMode::Grounded, &input),
            MovementMode::Airborne
        );
        assert_eq!(
            MovementMode::transition(MovementMode::Airborne, &input),
            MovementMode::Airborne
        );
    }

    /// Extends `transition_preserves_previous_mode_this_round` with a multi-tick
    /// run: 20 consecutive idle ticks starting from Grounded must all return
    /// Grounded, confirming that the identity transition holds across a full
    /// server-frame window and not just a single call.
    ///
    /// UE5 analogue: `SetMovementMode` is the explicit trigger for mode changes;
    /// in the absence of such a call the mode is unconditionally preserved.
    #[test]
    fn transition_preserves_mode_across_ticks() {
        let mut mode = MovementMode::Grounded;
        for tick in 1u32..=20 {
            let input = InputFrame::idle(tick, tick);
            mode = MovementMode::transition(mode, &input);
            assert_eq!(
                mode,
                MovementMode::Grounded,
                "tick {tick}: mode drifted away from Grounded without an explicit transition"
            );
        }
    }
}
