//! Camera follow helpers — **passive utility library** (audit D-S3).
//!
//! Nothing here registers a Bevy system. The functions are pure transforms
//! that the actual camera-driving system (in `camera::plugin`) may compose.
//! Today, the third-person camera in `camera::plugin::update_orbit_camera`
//! does its own `smooth_translation(...)` call with constants tuned for the
//! 3D third-person view (`8.0` follow speed, `300.0` snap distance).
//!
//! The constants and helpers in this file are kept around for the older
//! orbital / top-down camera that preserves Z depth (`smooth_camera_translation`).
//! If a future camera system needs that behaviour again it can reuse these
//! helpers directly; **plugin code should not duplicate this smoothing
//! logic with different constants — instead extend the helper or add a new
//! one here.**

use bevy::prelude::Vec3;

use crate::presentation::smoothing::smooth_translation;

/// Follow speed for the older orbital / top-down camera. The third-person
/// camera in `camera::plugin` uses `8.0` and is intentionally *not* using
/// this constant — see module doc.
pub const CAMERA_FOLLOW_SPEED: f32 = 12.0;
/// Snap distance for the older orbital / top-down camera. See above.
pub const CAMERA_SNAP_DISTANCE: f32 = 180.0;

/// Chooses the preferred camera target for the local player.
pub fn desired_camera_target(
    local_visual_translation: Option<Vec3>,
    fallback_local_position: Option<Vec3>,
) -> Option<Vec3> {
    local_visual_translation.or(fallback_local_position)
}

/// Smoothly follows the target while preserving the current camera depth.
/// Used by the orbital top-down camera. The third-person camera does not
/// preserve depth and so does its own `smooth_translation` call.
pub fn smooth_camera_translation(current: Vec3, target_xy: Vec3, delta_secs: f32) -> Vec3 {
    let target = Vec3::new(target_xy.x, target_xy.y, current.z);
    smooth_translation(
        current,
        target,
        delta_secs,
        CAMERA_FOLLOW_SPEED,
        CAMERA_SNAP_DISTANCE,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_local_visual_target_over_fallback_position() {
        let visual = Some(Vec3::new(10.0, 20.0, 5.0));
        let fallback = Some(Vec3::new(1.0, 2.0, 3.0));

        assert_eq!(desired_camera_target(visual, fallback), visual);
    }
}
