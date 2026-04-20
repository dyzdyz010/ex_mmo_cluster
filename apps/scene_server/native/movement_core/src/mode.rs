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
    /// Decide the mode for the upcoming step. This round we always keep the
    /// previous mode — transitions will be added when jump/skill code lands.
    pub fn transition(prev: MovementMode, _input: &InputFrame) -> MovementMode {
        prev
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
    fn transition_preserves_previous_mode_this_round() {
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
}
