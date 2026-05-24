//! Authoritative movement tuning profile.
//!
//! All fields are `f64` so the NIF and client share the same movement contract.
//! Defaults must stay aligned with `SceneServer.Movement.Profile.default/0` and
//! the browser prediction profile.

#[derive(Debug, Clone, PartialEq)]
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

impl Default for MovementProfile {
    fn default() -> Self {
        Self {
            // MMO running baseline: 6 m/s at 1 unit = 1 cm.
            max_speed: 600.0,
            max_accel: 3300.0,
            max_decel: 3800.0,
            max_jerk: 24_500.0,
            friction: 0.0,
            turn_response: 1.0,
            fixed_dt_ms: 100,
            max_speed_scale: 1.0,
            // Demo escape jump. At gravity=980, apex ~= 900^2 / 1960 = 413 cm.
            jump_impulse: 900.0,
            // 9.8 m/s^2 in centimeters.
            gravity: 980.0,
            air_control: 0.35,
            air_accel: 1140.0,
            max_fall_speed: 5300.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_matches_mmo_starter_tuning() {
        let p = MovementProfile::default();
        assert_eq!(p.max_speed, 600.0);
        assert_eq!(p.max_accel, 3300.0);
        assert_eq!(p.max_decel, 3800.0);
        assert_eq!(p.max_jerk, 24_500.0);
        assert_eq!(p.friction, 0.0);
        assert_eq!(p.turn_response, 1.0);
        assert_eq!(p.fixed_dt_ms, 100);
        assert_eq!(p.max_speed_scale, 1.0);
        assert_eq!(p.jump_impulse, 900.0);
        assert_eq!(p.gravity, 980.0);
        assert_eq!(p.air_control, 0.35);
        assert_eq!(p.air_accel, 1140.0);
        assert_eq!(p.max_fall_speed, 5300.0);
    }
}
