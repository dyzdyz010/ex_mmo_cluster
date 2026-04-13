use bevy::prelude::Vec3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MovementMode {
    Grounded,
    Airborne,
    Disabled,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PredictedMoveState {
    pub tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: MovementMode,
}

impl PredictedMoveState {
    pub fn idle(position: Vec3) -> Self {
        Self {
            tick: 0,
            position,
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MovementAck {
    pub ack_seq: u32,
    pub auth_tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: MovementMode,
    pub correction_flags: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RemoteMoveSnapshot {
    pub cid: i64,
    pub server_tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: MovementMode,
}
