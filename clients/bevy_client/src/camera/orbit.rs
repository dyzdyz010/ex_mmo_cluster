//! Orbit-camera primitives — pure data + pure transform math.
//!
//! Constants and `OrbitCameraState` live here so other systems
//! (voxel ray-pick, hud, etc.) can read camera tuning without depending
//! on `camera::plugin`. The system that drives this state lives in
//! `camera::plugin::update_orbit_camera`.

use bevy::prelude::{Component, Resource, Transform, Vec3};

/// Y offset above the local actor used as the orbit camera's look-at
/// height.
pub const CAMERA_LOOK_HEIGHT: f32 = 110.0;
/// Default orbit distance from the look-at target.
pub const CAMERA_DEFAULT_DISTANCE: f32 = 410.0;
/// Minimum allowed orbit distance (closest zoom).
pub const CAMERA_MIN_DISTANCE: f32 = 180.0;
/// Maximum allowed orbit distance (farthest zoom).
pub const CAMERA_MAX_DISTANCE: f32 = 620.0;
/// Yaw rotation per pixel of horizontal mouse motion when dragging.
pub const CAMERA_YAW_SENSITIVITY: f32 = 0.005;
/// Pitch rotation per pixel of vertical mouse motion when dragging.
pub const CAMERA_PITCH_SENSITIVITY: f32 = 0.004;
/// Minimum allowed pitch (looking nearly straight forward).
pub const CAMERA_MIN_PITCH: f32 = 0.2;
/// Maximum allowed pitch (looking nearly straight down).
pub const CAMERA_MAX_PITCH: f32 = 1.15;

/// Marker component attached to the active 3D camera entity.
#[derive(Component)]
pub struct MainCamera;

/// Orbit camera bookkeeping resource — yaw/pitch around the look-at target.
#[derive(Resource, Debug)]
pub struct OrbitCameraState {
    pub yaw: f32,
    pub pitch: f32,
    pub distance: f32,
    pub target: Vec3,
}

impl Default for OrbitCameraState {
    fn default() -> Self {
        Self {
            yaw: -0.75,
            pitch: 0.55,
            distance: CAMERA_DEFAULT_DISTANCE,
            target: Vec3::new(0.0, CAMERA_LOOK_HEIGHT, 0.0),
        }
    }
}

/// Builds a Bevy `Transform` from the orbit state — pure math, no Bevy
/// world access. Used both by `camera::plugin::update_orbit_camera` and
/// by the initial `setup` system that spawns the camera entity.
pub fn camera_transform_from_orbit(state: &OrbitCameraState) -> Transform {
    let horizontal = state.distance * state.pitch.cos();
    let offset = Vec3::new(
        horizontal * state.yaw.sin(),
        state.distance * state.pitch.sin(),
        horizontal * state.yaw.cos(),
    );
    Transform::from_translation(state.target + offset).looking_at(state.target, Vec3::Y)
}
