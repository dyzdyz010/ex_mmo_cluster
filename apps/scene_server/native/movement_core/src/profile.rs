//! Authoritative movement tuning profile.
//!
//! All fields are `f64` so the NIF and client share bit-exact arithmetic.
//! Defaults are the GDC/SIGGRAPH-inspired MMO starting values — see `docs/`
//! for the tuning roadmap.

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
            // MMO running baseline (6 m/s at 1 unit = 1 cm), matches Unreal CMC
            // default `MaxWalkSpeed = 600`. Phase A2 设定:per-class 速度档调
            // 用 max_speed_scale,profile default 给"满速跑"。
            max_speed: 600.0,
            // 维持 max_accel ≈ max_speed * 5.5 的 jerk-limited 响应窗口
            // (旧 1200 / 220 = 5.45,新 3300 / 600 = 5.5)。
            max_accel: 3300.0,
            // Valve/Source 经验 decel ≈ 1.15 × accel 让按键释放比按下更脆。
            max_decel: 3800.0,
            // GDC 2016 Epic "Networked Character Movement":jerk ≈ 7.5 ×
            // max_accel 让瞬时加速不肩膀震弹。
            max_jerk: 24_500.0,
            // Floor friction 由 physics layer 按 surface 算,integrator 视为
            // 已结算。
            friction: 0.0,
            turn_response: 1.0,
            // 100ms 权威 tick 对齐 Amazon New World GDC 2022 "500 players in
            // one shard"。改 tick 长度是 P3+ 范围。
            fixed_dt_ms: 100,
            max_speed_scale: 1.0,
            // 现实立定跳远 0.5-0.8m,demo 体感 1.2m apex 更舒服:
            // apex = jump_impulse² / (2 × gravity) = 485² / 1960 ≈ 120 cm。
            jump_impulse: 485.0,
            // 9.8 m/s²,符合现实重力。
            gravity: 980.0,
            air_control: 0.35,
            // air_accel 跟 max_accel 同比例(0.35 × 3300 ≈ 1140),air_control
            // 系数另算。
            air_accel: 1140.0,
            // 人体 terminal velocity ≈ 53 m/s。
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
        assert_eq!(p.jump_impulse, 485.0);
        assert_eq!(p.gravity, 980.0);
        assert_eq!(p.air_control, 0.35);
        assert_eq!(p.air_accel, 1140.0);
        assert_eq!(p.max_fall_speed, 5300.0);
    }
}
