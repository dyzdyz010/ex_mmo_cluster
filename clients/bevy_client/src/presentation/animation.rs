//! Lightweight animation-facing helpers derived from runtime velocity.

use bevy::prelude::{Vec2, Vec3};

use crate::presentation::smoothing::smooth_scale;

pub const ANIMATION_SCALE_SMOOTHING: f32 = 10.0;

#[derive(Debug, Clone, Copy, PartialEq)]
/// Simplified visual animation state derived from velocity.
pub struct VisualAnimationState {
    pub moving: bool,
    pub speed_ratio: f32,
    pub heading: Vec2,
}

/// Derives a lightweight animation state from movement velocity.
pub fn animation_state_from_velocity(velocity: Vec3, max_speed: f32) -> VisualAnimationState {
    let planar = Vec2::new(velocity.x, velocity.y);
    let speed = planar.length();
    let moving = speed > 0.5;
    let heading = if moving { planar.normalize() } else { Vec2::Y };

    VisualAnimationState {
        moving,
        speed_ratio: if max_speed <= f32::EPSILON {
            0.0
        } else {
            (speed / max_speed).clamp(0.0, 1.0)
        },
        heading,
    }
}

/// Per-frame breathing/lean multiplier applied to an actor's base scale
/// (always near `Vec3::ONE`). Pure function — no smoothing. Public so the
/// presentation layer can compose it with a per-actor `base_scale`.
pub fn animation_scale_multiplier(animation: VisualAnimationState) -> Vec3 {
    if animation.moving {
        Vec3::new(
            1.0 + 0.06 * animation.speed_ratio,
            1.0 - 0.04 * animation.speed_ratio,
            1.0,
        )
    } else {
        Vec3::ONE
    }
}

/// Smoothly animates an actor's transform scale toward `base_scale *
/// animation_scale_multiplier(animation)`.
///
/// The `base_scale` argument is the per-actor authored size (e.g.
/// `Vec3::new(48.0, 90.0, 48.0)` for the local player cube). Without it
/// the smoothing target would be the multiplier alone (~`Vec3::ONE`),
/// and the cube would shrink to a unit cube one frame at a time.
pub fn animated_scale(
    current_scale: Vec3,
    base_scale: Vec3,
    animation: VisualAnimationState,
    delta_secs: f32,
) -> Vec3 {
    let target = base_scale * animation_scale_multiplier(animation);
    smooth_scale(current_scale, target, delta_secs, ANIMATION_SCALE_SMOOTHING)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_animation_state_from_velocity() {
        let animation = animation_state_from_velocity(Vec3::new(50.0, 0.0, 0.0), 100.0);

        assert!(animation.moving);
        assert!(animation.speed_ratio > 0.4);
        assert_eq!(animation.heading, Vec2::X);
    }

    #[test]
    fn idle_actor_keeps_base_scale_across_many_frames() {
        let base = Vec3::new(48.0, 90.0, 48.0);
        let idle = animation_state_from_velocity(Vec3::ZERO, 100.0);
        assert!(!idle.moving);

        let mut current = base;
        for _ in 0..600 {
            current = animated_scale(current, base, idle, 1.0 / 60.0);
        }

        assert!(
            (current - base).length() < 0.01,
            "idle actor scale drifted: got {current:?}, expected ~{base:?}"
        );
    }
}
