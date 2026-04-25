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

/// Rotates a 2D WASD input vector (`x` = strafe / D-key, `y` = forward /
/// W-key) into the sim-coordinate horizontal velocity direction expected
/// by the server's movement integrator.
///
/// Without this rotation, pressing W always sends "north in sim space"
/// regardless of camera direction — the player walks away from where the
/// camera is pointing. Mirrors `clients/web_client/src/domain/movement/
/// inputDirection.ts::buildMovementInputDirection`.
///
/// Convention: `OrbitCameraState::yaw` rotates the camera offset around
/// the world Y axis as `(h*sin(yaw), _, h*cos(yaw))`, so camera forward
/// (where the player walks when pressing W) is `(-sin(yaw), 0, -cos(yaw))`
/// in render space; mapping render `(x, z)` to sim `(x, y)` gives the
/// formula below.
pub fn input_to_world_direction(input: bevy::prelude::Vec2, yaw: f32) -> bevy::prelude::Vec2 {
    let cos_yaw = yaw.cos();
    let sin_yaw = yaw.sin();
    let strafe = input.x;
    let forward = input.y;
    bevy::prelude::Vec2::new(
        strafe * cos_yaw - forward * sin_yaw,
        -strafe * sin_yaw - forward * cos_yaw,
    )
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

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::prelude::Vec2;

    /// W press (forward = 1) at yaw=0 must produce sim direction (0, -1).
    /// At yaw=0 the camera is at +Z render = +Y sim, looking toward the
    /// origin (camera forward = -Z render = -Y sim). "Forward" therefore
    /// walks in -Y sim.
    #[test]
    fn input_to_world_direction_w_at_zero_yaw_walks_negative_y() {
        let direction = input_to_world_direction(Vec2::new(0.0, 1.0), 0.0);
        assert!((direction.x - 0.0).abs() < 1e-6);
        assert!((direction.y - (-1.0)).abs() < 1e-6);
    }

    /// W press at yaw = π/2 rotates the camera so it sits at +X render and
    /// looks toward -X. Pressing W must walk in -X sim.
    #[test]
    fn input_to_world_direction_w_at_quarter_yaw_walks_negative_x() {
        let direction = input_to_world_direction(Vec2::new(0.0, 1.0), std::f32::consts::FRAC_PI_2);
        assert!((direction.x - (-1.0)).abs() < 1e-6);
        assert!((direction.y - 0.0).abs() < 1e-6);
    }

    /// D press (strafe = 1) at yaw=0 must walk in +X sim — the camera is
    /// behind the player, screen-right is +X.
    #[test]
    fn input_to_world_direction_d_at_zero_yaw_walks_positive_x() {
        let direction = input_to_world_direction(Vec2::new(1.0, 0.0), 0.0);
        assert!((direction.x - 1.0).abs() < 1e-6);
        assert!((direction.y - 0.0).abs() < 1e-6);
    }

    /// D press at yaw = π/2 — camera at +X looking -X — screen-right is
    /// -Z render = -Y sim.
    #[test]
    fn input_to_world_direction_d_at_quarter_yaw_walks_negative_y() {
        let direction = input_to_world_direction(Vec2::new(1.0, 0.0), std::f32::consts::FRAC_PI_2);
        assert!((direction.x - 0.0).abs() < 1e-6);
        assert!((direction.y - (-1.0)).abs() < 1e-6);
    }
}
