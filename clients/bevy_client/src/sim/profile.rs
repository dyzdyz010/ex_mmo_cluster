#[derive(Debug, Clone, PartialEq)]
pub struct MovementProfile {
    pub max_speed: f32,
    pub max_accel: f32,
    pub max_decel: f32,
    pub max_jerk: f32,
    pub friction: f32,
    pub turn_response: f32,
}

impl Default for MovementProfile {
    fn default() -> Self {
        Self {
            max_speed: 220.0,
            max_accel: 1200.0,
            max_decel: 1400.0,
            max_jerk: 9_000.0,
            friction: 0.0,
            turn_response: 1.0,
        }
    }
}
