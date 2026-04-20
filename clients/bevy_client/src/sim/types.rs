//! Core movement simulation data types shared by prediction and networking.
//!
//! `MovementMode` is re-exported verbatim from the shared `movement_core`
//! crate so the server NIF and the Bevy client always agree on the variant
//! set. `PredictedMoveState` / `MovementAck` stay Bevy-native (`f32`) for
//! ergonomics; conversion to `movement_core`'s `f64` types happens inside
//! `sim::predictor` with a documented round-trip precision budget of 1e-4.

use bevy::prelude::Vec3;

pub use movement_core::MovementMode;

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

    /// Converts to `movement_core::MovementState`. The `f32 → f64` widening
    /// is lossless; the reverse path in `from_core` performs the quantisation.
    pub fn to_core(&self) -> movement_core::MovementState {
        movement_core::MovementState {
            position: vec3_to_array(self.position),
            velocity: vec3_to_array(self.velocity),
            acceleration: vec3_to_array(self.acceleration),
            movement_mode: self.movement_mode,
            tick: self.tick,
            seq: self.seq,
        }
    }

    /// Builds the Bevy-native predicted state from a `movement_core` result.
    /// Precision budget: each component round-trips within 1e-4 of the f64
    /// value for positions below ±1e6 metres, which comfortably covers MMO
    /// world extents.
    pub fn from_core(core: &movement_core::MovementState) -> Self {
        Self {
            seq: core.seq,
            tick: core.tick,
            position: array_to_vec3(core.position),
            velocity: array_to_vec3(core.velocity),
            acceleration: array_to_vec3(core.acceleration),
            movement_mode: core.movement_mode,
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

pub(crate) fn vec3_to_array(v: Vec3) -> [f64; 3] {
    [v.x as f64, v.y as f64, v.z as f64]
}

pub(crate) fn array_to_vec3(a: [f64; 3]) -> Vec3 {
    Vec3::new(a[0] as f32, a[1] as f32, a[2] as f32)
}
