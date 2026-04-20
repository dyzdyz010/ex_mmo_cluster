//! Authoritative movement correction payload — sent server → client after
//! each authoritative tick so the client can reconcile its prediction.

use crate::mode::MovementMode;

#[derive(Debug, Clone, PartialEq)]
pub struct MovementAck {
    pub ack_seq: u32,
    pub auth_tick: u32,
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub acceleration: [f64; 3],
    pub movement_mode: MovementMode,
    pub correction_flags: u32,
}
