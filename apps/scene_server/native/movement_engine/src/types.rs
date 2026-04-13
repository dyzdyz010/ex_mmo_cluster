use rustler::{Atom, NifStruct};

use crate::math::{Vec2, Vec3};

#[derive(Debug, Clone, NifStruct)]
#[module = "SceneServer.Movement.State"]
pub struct MovementState {
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: Atom,
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
}

impl InputFrame {
    pub fn braking(&self) -> bool {
        self.movement_flags & 0b10 != 0
    }
}
