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
}

impl Default for MovementProfile {
    fn default() -> Self {
        Self {
            // MMO walking baseline (7–8 m/s at 1 unit = 1 cm). Below Unreal
            // CMC default `MaxWalkSpeed = 600` because our 1 unit = 1 cm world
            // runs slower than UE's 1 unit = 1 cm humanoid. Roadmap (plan C):
            // shift to per-class profile (ranger 240 / heavy 180).
            max_speed: 220.0,
            // Unreal CMC default `MaxAcceleration = 2048`; MMO-tuned lower so
            // players never exceed walking physics in one tick. Roadmap: keep
            // < max_speed * 6 for stable jerk-limited response.
            max_accel: 1200.0,
            // Valve/Source recommend decel ≈ 1.15 × accel so key-release feels
            // snappier than key-hold. Roadmap: expose as PVP vs PVE scaler.
            max_decel: 1400.0,
            // GDC 2016 Epic "Networked Character Movement": jerk ceiling ≈ 7.5
            // × max_accel keeps transient acceleration responsive without
            // shoulder-popping artefacts. Roadmap: per-mount override.
            max_jerk: 9_000.0,
            // Floor friction driven per-surface by the physics layer; the
            // integrator itself treats friction as already resolved.
            friction: 0.0,
            turn_response: 1.0,
            // 100ms authoritative tick matches Amazon New World GDC 2022
            // "500 players in one shard" default. Roadmap: stays 100ms — any
            // change is P3+ scope, not P2.
            fixed_dt_ms: 100,
            max_speed_scale: 1.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_matches_mmo_starter_tuning() {
        let p = MovementProfile::default();
        assert_eq!(p.max_speed, 220.0);
        assert_eq!(p.max_accel, 1200.0);
        assert_eq!(p.max_decel, 1400.0);
        assert_eq!(p.max_jerk, 9_000.0);
        assert_eq!(p.friction, 0.0);
        assert_eq!(p.turn_response, 1.0);
        assert_eq!(p.fixed_dt_ms, 100);
        assert_eq!(p.max_speed_scale, 1.0);
    }
}
