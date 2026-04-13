use bevy::prelude::Vec3;

pub fn smooth_translation(
    current: Vec3,
    target: Vec3,
    delta_secs: f32,
    smoothing_speed: f32,
    snap_distance: f32,
) -> Vec3 {
    let distance = current.distance(target);

    if distance <= f32::EPSILON {
        return target;
    }

    if distance >= snap_distance {
        return target;
    }

    let factor = (smoothing_speed * delta_secs).clamp(0.0, 1.0);
    current.lerp(target, factor)
}

pub fn smooth_scale(current: Vec3, target: Vec3, delta_secs: f32, smoothing_speed: f32) -> Vec3 {
    let factor = (smoothing_speed * delta_secs).clamp(0.0, 1.0);
    current.lerp(target, factor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smooth_translation_moves_toward_target_without_overshoot() {
        let current = Vec3::new(0.0, 0.0, 0.0);
        let target = Vec3::new(10.0, 0.0, 0.0);

        let next = smooth_translation(current, target, 1.0 / 60.0, 18.0, 96.0);

        assert!(next.x > current.x);
        assert!(next.x < target.x);
        assert_eq!(next.y, 0.0);
    }

    #[test]
    fn smooth_translation_snaps_large_corrections() {
        let current = Vec3::new(0.0, 0.0, 0.0);
        let target = Vec3::new(200.0, 0.0, 0.0);

        let next = smooth_translation(current, target, 1.0 / 60.0, 18.0, 96.0);

        assert_eq!(next, target);
    }
}
