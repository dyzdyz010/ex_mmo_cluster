//! Camera follow helpers built on top of presentation smoothing.

use bevy::prelude::Vec3;

use crate::presentation::smoothing::smooth_translation;

pub const CAMERA_FOLLOW_SPEED: f32 = 12.0;
pub const CAMERA_SNAP_DISTANCE: f32 = 180.0;

/// Chooses the preferred camera target for the local player.
pub fn desired_camera_target(
    local_visual_translation: Option<Vec3>,
    fallback_local_position: Option<Vec3>,
) -> Option<Vec3> {
    local_visual_translation.or(fallback_local_position)
}

/// Smoothly follows the target while preserving the current camera depth.
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
