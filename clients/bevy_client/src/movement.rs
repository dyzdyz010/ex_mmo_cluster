//! Simple movement helpers retained for older/local command flows.

use bevy::prelude::{Vec2, Vec3};

/// Computes a naïve movement step from position, direction, speed, and interval.
pub fn compute_movement_step(
    position: Vec3,
    direction: Vec2,
    movement_speed: f32,
    movement_interval_ms: u64,
) -> (Vec3, [f64; 3]) {
    let normalized = direction.normalize() * movement_speed;
    let dt = movement_interval_ms as f32 / 1_000.0;
    let desired_position = position + Vec3::new(normalized.x * dt, normalized.y * dt, 0.0);

    (
        desired_position,
        [normalized.x as f64, normalized.y as f64, 0.0],
    )
}

/// Returns the next movement command payload, including single-shot stop sync.
pub fn next_movement_command(
    position: Vec3,
    direction: Vec2,
    movement_speed: f32,
    movement_interval_ms: u64,
    stop_sent: bool,
) -> Option<(Vec3, [f64; 3], bool)> {
    if direction.length_squared() == 0.0 {
        return (!stop_sent).then_some((position, [0.0, 0.0, 0.0], true));
    }

    let (desired_position, velocity) =
        compute_movement_step(position, direction, movement_speed, movement_interval_ms);

    Some((desired_position, velocity, false))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn movement_step_advances_in_input_direction() {
        let position = Vec3::new(1_000.0, 1_000.0, 90.0);
        let direction = Vec2::new(1.0, 0.0);

        let (desired, velocity) = compute_movement_step(position, direction, 220.0, 100);

        assert!(desired.x > position.x);
        assert_eq!(desired.y, position.y);
        assert_eq!(desired.z, position.z);
        assert_eq!(velocity, [220.0, 0.0, 0.0]);
    }

    #[test]
    fn next_movement_command_emits_single_stop_update() {
        let position = Vec3::new(12.0, 34.0, 56.0);

        let first_stop = next_movement_command(position, Vec2::ZERO, 220.0, 100, false);
        let repeated_stop = next_movement_command(position, Vec2::ZERO, 220.0, 100, true);

        assert_eq!(first_stop, Some((position, [0.0, 0.0, 0.0], true)));
        assert_eq!(repeated_stop, None);
    }

    #[test]
    fn next_movement_command_resumes_motion_after_stop() {
        let position = Vec3::new(0.0, 0.0, 0.0);
        let direction = Vec2::new(0.0, 1.0);

        let Some((desired, velocity, stop_sent)) =
            next_movement_command(position, direction, 220.0, 100, true)
        else {
            panic!("expected movement command");
        };

        assert!(desired.y > position.y);
        assert_eq!(velocity, [0.0, 220.0, 0.0]);
        assert!(!stop_sent);
    }
}
