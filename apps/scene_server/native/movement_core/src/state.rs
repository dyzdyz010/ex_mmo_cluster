//! Movement state at a fixed tick — produced by the integrator, consumed by
//! reconciliation, history buffers, and on-wire movement messages.

use crate::mode::MovementMode;

#[derive(Debug, Clone, PartialEq)]
pub struct MovementState {
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub acceleration: [f64; 3],
    pub movement_mode: MovementMode,
    pub ground_z: f64,
    pub tick: u32,
    pub seq: u32,
}

impl MovementState {
    /// Idle grounded state anchored at `position` with zero velocity.
    pub fn idle(position: [f64; 3]) -> Self {
        Self {
            position,
            velocity: [0.0, 0.0, 0.0],
            acceleration: [0.0, 0.0, 0.0],
            movement_mode: MovementMode::default(),
            ground_z: position[2],
            tick: 0,
            seq: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_round_trip_preserves_position() {
        let state = MovementState::idle([1.0, 2.0, 3.0]);
        assert_eq!(state.position, [1.0, 2.0, 3.0]);
        assert_eq!(state.velocity, [0.0, 0.0, 0.0]);
        assert_eq!(state.acceleration, [0.0, 0.0, 0.0]);
        assert_eq!(state.movement_mode, MovementMode::Grounded);
        assert_eq!(state.ground_z, 3.0);
        assert_eq!(state.tick, 0);
        assert_eq!(state.seq, 0);
    }
}
