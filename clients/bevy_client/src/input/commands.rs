//! Fixed-step input command types for local prediction and network transport.

use bevy::prelude::Vec2;

/// Bitflag storage for movement modifiers.
pub type MovementFlags = u16;

/// Run modifier bit.
pub const MOVEMENT_FLAG_RUN: MovementFlags = 0b0000_0001;
/// Brake modifier bit.
pub const MOVEMENT_FLAG_BRAKE: MovementFlags = 0b0000_0010;

#[derive(Debug, Clone, PartialEq)]
/// One local input sample destined for prediction and transport.
pub struct MoveInputFrame {
    pub seq: u32,
    pub client_tick: u32,
    pub dt_ms: u16,
    pub input_dir: Vec2,
    pub speed_scale: f32,
    pub movement_flags: MovementFlags,
}

impl MoveInputFrame {
    /// Returns whether the frame requests braking behavior.
    pub fn is_braking(&self) -> bool {
        self.movement_flags & MOVEMENT_FLAG_BRAKE != 0
    }

    /// Returns whether the frame requests the run modifier.
    pub fn is_running(&self) -> bool {
        self.movement_flags & MOVEMENT_FLAG_RUN != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn movement_flags_report_run_and_brake() {
        let frame = MoveInputFrame {
            seq: 1,
            client_tick: 10,
            dt_ms: 16,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: MOVEMENT_FLAG_RUN | MOVEMENT_FLAG_BRAKE,
        };

        assert!(frame.is_running());
        assert!(frame.is_braking());
    }
}
