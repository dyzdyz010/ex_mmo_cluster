//! Per-tick input frame supplied by the client to the authoritative simulator.

use crate::mode::MovementMode;

/// Bit flag signalling the player is actively braking (e.g. release-key decel).
pub const MOVEMENT_FLAG_BRAKE: u16 = 0b10;
/// Bit flag signalling a one-shot grounded jump request.
pub const MOVEMENT_FLAG_JUMP: u16 = 0b100;

#[derive(Debug, Clone, PartialEq)]
pub struct InputFrame {
    pub seq: u32,
    pub client_tick: u32,
    pub dt_ms: u16,
    pub input_dir: [f64; 2],
    pub speed_scale: f64,
    pub movement_flags: u16,
    pub movement_mode: MovementMode,
}

impl InputFrame {
    /// Helper: build an idle frame (no direction, no flags) for tests and
    /// server-synthesized keepalive ticks.
    pub fn idle(seq: u32, client_tick: u32) -> Self {
        Self {
            seq,
            client_tick,
            dt_ms: 100,
            input_dir: [0.0, 0.0],
            speed_scale: 1.0,
            movement_flags: 0,
            movement_mode: MovementMode::default(),
        }
    }

    pub fn braking(&self) -> bool {
        self.movement_flags & MOVEMENT_FLAG_BRAKE != 0
    }

    pub fn jump_requested(&self) -> bool {
        self.movement_flags & MOVEMENT_FLAG_JUMP != 0
    }
}
