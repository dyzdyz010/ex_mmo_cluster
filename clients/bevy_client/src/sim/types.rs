//! Core movement simulation data types shared by prediction and networking.

use bevy::prelude::Vec3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Simulation movement mode mirrored from the server.
pub enum MovementMode {
    Grounded,
    Airborne,
    Disabled,
}

#[derive(Debug, Clone, PartialEq)]
/// Predicted or authoritative local movement state at a fixed tick.
///
/// `seq` tracks the input-sequence number that produced this state so the
/// reconciler can match authoritative acks by client-issued seq first and
/// fall back to `tick` when matching server-synthesized idle frames.
pub struct PredictedMoveState {
    pub seq: u32,
    pub tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: MovementMode,
}

impl PredictedMoveState {
    /// Builds an idle grounded state at the given position.
    pub fn idle(position: Vec3) -> Self {
        Self {
            seq: 0,
            tick: 0,
            position,
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
/// Authoritative movement correction payload consumed by reconciliation.
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
/// Remote actor movement snapshot used for interpolation.
pub struct RemoteMoveSnapshot {
    pub cid: i64,
    pub server_tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: MovementMode,
}
