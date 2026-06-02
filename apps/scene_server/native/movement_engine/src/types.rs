//! Rustler term ↔ `movement_core` adapters.
//!
//! The Rustler struct shapes mirror `SceneServer.Movement.State` /
//! `InputFrame` / `Profile` exactly, so the Elixir ↔ NIF boundary is
//! unchanged. Conversion into `movement_core` types happens entirely here;
//! the rest of the NIF is a thin pass-through.

use rustler::{Atom, NifStruct};

use crate::atoms;

pub type Vec2 = (f64, f64);
pub type Vec3 = (f64, f64, f64);

#[derive(Debug, Clone, NifStruct)]
#[module = "SceneServer.Movement.State"]
pub struct MovementState {
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: Atom,
    pub ground_z: f64,
    pub server_state_ms: u64,
    pub tick: u32,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "SceneServer.Movement.InputFrame"]
pub struct InputFrame {
    pub seq: u32,
    pub client_tick: u32,
    pub dt_ms: u16,
    pub input_dir: Vec2,
    pub speed_scale: f64,
    pub movement_flags: u16,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "SceneServer.Movement.Profile"]
pub struct MovementProfile {
    pub max_speed: f64,
    pub max_accel: f64,
    pub max_decel: f64,
    pub max_jerk: f64,
    pub friction: f64,
    pub turn_response: f64,
    pub fixed_dt_ms: u16,
    pub max_speed_scale: f64,
    pub jump_impulse: f64,
    pub gravity: f64,
    pub air_control: f64,
    pub air_accel: f64,
    pub max_fall_speed: f64,
}

// ---------- atom <-> movement_core::MovementMode ----------

pub fn atom_to_mode(atom: Atom) -> movement_core::MovementMode {
    use movement_core::MovementMode::*;
    if atom == atoms::grounded() {
        Grounded
    } else if atom == atoms::airborne() {
        Airborne
    } else if atom == atoms::scripted() {
        Scripted
    } else if atom == atoms::disabled() {
        Disabled
    } else {
        // Unknown atom from Elixir — fall back to Grounded so the integrator
        // still advances deterministically instead of panicking.
        Grounded
    }
}

pub fn mode_to_atom(mode: movement_core::MovementMode) -> Atom {
    use movement_core::MovementMode::*;
    match mode {
        Grounded => atoms::grounded(),
        Airborne => atoms::airborne(),
        Scripted => atoms::scripted(),
        Disabled => atoms::disabled(),
    }
}

// ---------- tuple <-> array ----------

fn vec3_to_array(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

fn array_to_vec3(v: [f64; 3]) -> Vec3 {
    (v[0], v[1], v[2])
}

// ---------- struct adapters ----------

impl MovementState {
    /// Into core form. The Elixir struct does not carry `seq`, so `seq` is
    /// synthesized from `tick` for the core type (core needs seq for its
    /// internal scripted/disabled no-op path; Elixir never reads it back).
    pub fn to_core(&self) -> movement_core::MovementState {
        movement_core::MovementState {
            position: vec3_to_array(self.position),
            velocity: vec3_to_array(self.velocity),
            acceleration: vec3_to_array(self.acceleration),
            movement_mode: atom_to_mode(self.movement_mode),
            ground_z: self.ground_z,
            tick: self.tick,
            seq: self.tick,
        }
    }

    /// Build the Elixir-facing struct from a core state. The core's `seq`
    /// field is dropped on purpose: `SceneServer.Movement.State` has no
    /// `:seq` key, and adding one would break every pattern match in the
    /// server actor path. `server_state_ms` is owned by Scene's actor layer
    /// after integration, so native math returns the struct-default zero.
    pub fn from_core(core: &movement_core::MovementState) -> Self {
        Self {
            position: array_to_vec3(core.position),
            velocity: array_to_vec3(core.velocity),
            acceleration: array_to_vec3(core.acceleration),
            movement_mode: mode_to_atom(core.movement_mode),
            ground_z: core.ground_z,
            server_state_ms: 0,
            tick: core.tick,
        }
    }
}

impl InputFrame {
    /// The Elixir struct has no `:movement_mode` field — inject the default
    /// (`Grounded`) so movement_core's dispatch always has a valid mode.
    /// INVARIANT: `MovementMode::transition()` currently ignores
    /// `input.movement_mode`; once transitions become input-driven, the
    /// Elixir struct must gain a `:movement_mode` field and this default
    /// must be replaced with a real forwarding.
    pub fn to_core(&self) -> movement_core::InputFrame {
        movement_core::InputFrame {
            seq: self.seq,
            client_tick: self.client_tick,
            dt_ms: self.dt_ms,
            input_dir: [self.input_dir.0, self.input_dir.1],
            speed_scale: self.speed_scale,
            movement_flags: self.movement_flags,
            movement_mode: movement_core::MovementMode::default(),
        }
    }
}

impl MovementProfile {
    pub fn to_core(&self) -> movement_core::MovementProfile {
        movement_core::MovementProfile {
            max_speed: self.max_speed,
            max_accel: self.max_accel,
            max_decel: self.max_decel,
            max_jerk: self.max_jerk,
            friction: self.friction,
            turn_response: self.turn_response,
            fixed_dt_ms: self.fixed_dt_ms,
            max_speed_scale: self.max_speed_scale,
            jump_impulse: self.jump_impulse,
            gravity: self.gravity,
            air_control: self.air_control,
            air_accel: self.air_accel,
            max_fall_speed: self.max_fall_speed,
        }
    }
}
