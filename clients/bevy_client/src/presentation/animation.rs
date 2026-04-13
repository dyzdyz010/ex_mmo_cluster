use bevy::prelude::{Vec2, Vec3};

use crate::presentation::smoothing::smooth_scale;

pub const ANIMATION_SCALE_SMOOTHING: f32 = 10.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VisualAnimationState {
    pub moving: bool,
    pub speed_ratio: f32,
    pub heading: Vec2,
}

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

pub fn animated_scale(
    current_scale: Vec3,
    animation: VisualAnimationState,
    delta_secs: f32,
) -> Vec3 {
    let target = if animation.moving {
        Vec3::new(
            1.0 + 0.06 * animation.speed_ratio,
            1.0 - 0.04 * animation.speed_ratio,
            1.0,
        )
    } else {
        Vec3::ONE
    };

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
}
