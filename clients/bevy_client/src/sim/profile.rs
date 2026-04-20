//! Shared client-side movement tuning used by prediction/replay.

#[derive(Debug, Clone, PartialEq)]
/// Client-side prediction profile that mirrors the server-side movement profile.
///
/// Stays `f32` for ergonomic interaction with Bevy's `Vec3`. The adapter
/// `to_core()` widens to `f64` before feeding `movement_core` — any future
/// f64-only tuning must stay within f32 representable range.
pub struct MovementProfile {
    pub max_speed: f32,
    pub max_accel: f32,
    pub max_decel: f32,
    pub max_jerk: f32,
    pub friction: f32,
    pub turn_response: f32,
    /// Authoritative server tick duration in milliseconds. Mirrors
    /// `SceneServer.Movement.Profile.fixed_dt_ms` so server-synthesized idle
    /// frames can be replayed locally with matching step size.
    pub fixed_dt_ms: u16,
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
            fixed_dt_ms: 100,
        }
    }
}

impl MovementProfile {
    /// Widens to `movement_core::MovementProfile`. `max_speed_scale` is fixed
    /// at 1.0 on the client — per-input speed scaling is supplied through
    /// `MoveInputFrame::speed_scale`, and the server owns any global scalar.
    pub fn to_core(&self) -> movement_core::MovementProfile {
        movement_core::MovementProfile {
            max_speed: self.max_speed as f64,
            max_accel: self.max_accel as f64,
            max_decel: self.max_decel as f64,
            max_jerk: self.max_jerk as f64,
            friction: self.friction as f64,
            turn_response: self.turn_response as f64,
            fixed_dt_ms: self.fixed_dt_ms,
            max_speed_scale: 1.0,
        }
    }
}
