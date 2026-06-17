//! Debris particle simulation (C2): a pure-data port of the web reference's
//! `debrisEffect.ts` `DebrisSimulation`. When an object part is damaged /
//! part-destroyed / destroyed (the `ObjectStateDelta` the authority already
//! tracks), a burst of small particles is spawned at the affected cells; they
//! fly outward in an upward hemisphere, fall under gravity, and expire.
//!
//! Split (mirroring the reference): this module is **pure data + physics
//! integration** — no Bevy, no GPU — so the spawn count, integration, decay, and
//! the global cap are all Layer-1 assertable. The randomness source is injected
//! (`&mut dyn FnMut() -> f32`) so tests drive it deterministically; the Bevy
//! adapter (a later step) feeds a real PRNG and uploads `live_particles()` to an
//! instanced mesh.
//!
//! Units match the reference: positions/velocities are in macro cells (1 macro =
//! 1 m); the Bevy renderer scales by the macro render size. Gravity is m/s².

/// Reference defaults (web `DEBRIS_DEFAULTS`). Tunable per simulation via
/// [`DebrisConfig`]; the constants pin the canonical values for parity.
pub const DEFAULT_BURST_SIZE: usize = 8;
pub const DEFAULT_MAX_LIVE_PARTICLES: usize = 500;
pub const DEFAULT_PARTICLE_LIFETIME_MS: f32 = 800.0;
pub const DEFAULT_OUTWARD_SPEED_MPS: f32 = 1.5;
pub const DEFAULT_TANGENTIAL_SPEED_MPS: f32 = 0.6;
pub const DEFAULT_GRAVITY_MPS2: f32 = -9.8;
/// Visual edge of a debris cube, in meters (= macro units). The render adapter
/// draws each particle at `DEFAULT_PARTICLE_SIZE_M * macro_render_size` units
/// (0.05 * 100 = 5), matching the web `debrisRenderer` DEFAULT_PARTICLE_SIZE_WORLD.
/// Kept here as the parity anchor even though the pure sim never reads it.
pub const DEFAULT_PARTICLE_SIZE_M: f32 = 0.05;

/// The destruction event that triggered a burst. Mirrors the server's single
/// `state_flags` events; currently informational (the reference's spawn ignores
/// kind), retained for future per-kind tuning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebrisKind {
    Damaged,
    PartDestroyed,
    Destroyed,
}

/// A world-space point (macro units) where a burst originates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DebrisSpawnPoint {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

/// One live debris particle (position + velocity in macro units, age in ms).
///
/// `seed_*` is the spawn origin, frozen at birth (x/y/z mutate as the particle
/// moves), retained so the render adapter can derive stable per-particle visual
/// variation (rotation seed / color jitter) — mirroring the web reference.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DebrisParticle {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub vx: f32,
    pub vy: f32,
    pub vz: f32,
    pub age_ms: f32,
    pub seed_x: f32,
    pub seed_y: f32,
    pub seed_z: f32,
}

/// Tunable simulation parameters (defaults mirror the reference).
#[derive(Debug, Clone, Copy)]
pub struct DebrisConfig {
    pub burst_size: usize,
    pub max_live_particles: usize,
    pub particle_lifetime_ms: f32,
    pub outward_speed_mps: f32,
    pub tangential_speed_mps: f32,
    pub gravity_mps2: f32,
}

impl Default for DebrisConfig {
    fn default() -> Self {
        Self {
            burst_size: DEFAULT_BURST_SIZE,
            max_live_particles: DEFAULT_MAX_LIVE_PARTICLES,
            particle_lifetime_ms: DEFAULT_PARTICLE_LIFETIME_MS,
            outward_speed_mps: DEFAULT_OUTWARD_SPEED_MPS,
            tangential_speed_mps: DEFAULT_TANGENTIAL_SPEED_MPS,
            gravity_mps2: DEFAULT_GRAVITY_MPS2,
        }
    }
}

/// Pure debris particle simulation. Holds the live particle pool; `spawn` adds
/// bursts (random source injected), `update` integrates + expires. No Bevy.
#[derive(Debug, Default)]
pub struct DebrisSimulation {
    particles: Vec<DebrisParticle>,
    config: DebrisConfig,
}

impl DebrisSimulation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_config(config: DebrisConfig) -> Self {
        Self {
            particles: Vec::new(),
            config,
        }
    }

    /// Spawns `burst_size` particles per sample point. Each gets an upward-biased
    /// hemisphere direction plus a tangential jitter, exactly as the web sim. The
    /// global cap trims the oldest particles (front of the pool). `rng` must yield
    /// values in `[0, 1)`; four draws are consumed per particle. Returns spawned.
    pub fn spawn(
        &mut self,
        points: &[DebrisSpawnPoint],
        _kind: DebrisKind,
        rng: &mut dyn FnMut() -> f32,
    ) -> usize {
        let mut spawned = 0;
        for point in points {
            for _ in 0..self.config.burst_size {
                let particle = self.build_particle(point, rng);
                self.particles.push(particle);
                spawned += 1;
            }
        }

        // Enforce the global cap by trimming the oldest particles (front).
        if self.particles.len() > self.config.max_live_particles {
            let overflow = self.particles.len() - self.config.max_live_particles;
            self.particles.drain(0..overflow);
        }

        spawned
    }

    /// Advances every particle by `dt_ms`: symplectic Euler (gravity then move),
    /// dropping any that reach their lifetime. Compacts the pool in place.
    pub fn update(&mut self, dt_ms: f32) {
        if dt_ms <= 0.0 {
            return;
        }
        let dt_s = dt_ms / 1000.0;
        let lifetime = self.config.particle_lifetime_ms;
        let gravity = self.config.gravity_mps2;

        self.particles.retain_mut(|p| {
            let new_age = p.age_ms + dt_ms;
            if new_age >= lifetime {
                return false; // expired → drop
            }
            // Symplectic Euler: integrate velocity (gravity) then position.
            p.vy += gravity * dt_s;
            p.x += p.vx * dt_s;
            p.y += p.vy * dt_s;
            p.z += p.vz * dt_s;
            p.age_ms = new_age;
            true
        });
    }

    pub fn active_count(&self) -> usize {
        self.particles.len()
    }

    /// Read-only view of the live particles — the Bevy adapter syncs instanced
    /// transforms from this each frame.
    pub fn live_particles(&self) -> &[DebrisParticle] {
        &self.particles
    }

    pub fn reset(&mut self) {
        self.particles.clear();
    }

    fn build_particle(
        &self,
        point: &DebrisSpawnPoint,
        rng: &mut dyn FnMut() -> f32,
    ) -> DebrisParticle {
        use std::f32::consts::PI;

        // Upward-biased hemisphere direction (theta full circle, phi in [0, pi/2]).
        let u = rng();
        let v = rng();
        let theta = 2.0 * PI * u;
        let phi = (v * PI) / 2.0;
        let sin_phi = phi.sin();
        let dir_x = theta.cos() * sin_phi;
        let dir_z = theta.sin() * sin_phi;
        let dir_y = phi.cos();

        let outward_scale = self.config.outward_speed_mps * (0.4 + 0.6 * rng());
        let tang_scale = self.config.tangential_speed_mps * (rng() * 2.0 - 1.0);

        DebrisParticle {
            x: point.x,
            y: point.y,
            z: point.z,
            vx: dir_x * outward_scale + tang_scale,
            vy: dir_y * outward_scale,
            vz: dir_z * outward_scale + tang_scale,
            age_ms: 0.0,
            seed_x: point.x,
            seed_y: point.y,
            seed_z: point.z,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic RNG cycling a fixed sequence — lets tests pin exact
    /// particle math without depending on a real PRNG.
    fn seq_rng(values: Vec<f32>) -> impl FnMut() -> f32 {
        let mut i = 0;
        move || {
            let v = values[i % values.len()];
            i += 1;
            v
        }
    }

    fn point(x: f32, y: f32, z: f32) -> DebrisSpawnPoint {
        DebrisSpawnPoint { x, y, z }
    }

    #[test]
    fn spawn_emits_burst_size_particles_per_point() {
        let mut sim = DebrisSimulation::new();
        let mut rng = seq_rng(vec![0.5]);
        let spawned = sim.spawn(
            &[point(1.0, 2.0, 3.0), point(4.0, 5.0, 6.0)],
            DebrisKind::Destroyed,
            &mut rng,
        );
        // 2 points × burst 8 = 16.
        assert_eq!(spawned, 16);
        assert_eq!(sim.active_count(), 16);
    }

    #[test]
    fn particles_originate_at_spawn_point_with_upward_velocity() {
        let mut sim = DebrisSimulation::with_config(DebrisConfig {
            burst_size: 1,
            ..Default::default()
        });
        // u=0,v=0 → theta=0, phi=0 → dir=(0,1,0) (straight up); outward scale
        // = 1.5*(0.4+0.6*0)=0.6; tang = 0.6*(0*2-1) = -0.6.
        let mut rng = seq_rng(vec![0.0, 0.0, 0.0, 0.0]);
        sim.spawn(&[point(10.0, 20.0, 30.0)], DebrisKind::Destroyed, &mut rng);
        let p = sim.live_particles()[0];
        assert_eq!((p.x, p.y, p.z), (10.0, 20.0, 30.0));
        // dir_y=1 → vy = 0.6 (outward), straight up dominates.
        assert!((p.vy - 0.6).abs() < 1e-5);
        // dir_x=dir_z=0 → vx=vz=tangential=-0.6.
        assert!((p.vx - (-0.6)).abs() < 1e-5);
        assert!((p.vz - (-0.6)).abs() < 1e-5);
        assert_eq!(p.age_ms, 0.0);
    }

    #[test]
    fn update_integrates_gravity_and_position() {
        let mut sim = DebrisSimulation::with_config(DebrisConfig {
            burst_size: 1,
            ..Default::default()
        });
        // Straight-up particle, no tangential: u=0,v=0,outward draw=0,tang draw=0.5
        // → tang = 0.6*(0.5*2-1)=0.
        let mut rng = seq_rng(vec![0.0, 0.0, 0.0, 0.5]);
        sim.spawn(&[point(0.0, 0.0, 0.0)], DebrisKind::Destroyed, &mut rng);
        let v0 = sim.live_particles()[0];
        assert!((v0.vx).abs() < 1e-6 && (v0.vz).abs() < 1e-6);
        let vy0 = v0.vy;

        sim.update(100.0); // 0.1 s
        let p = sim.live_particles()[0];
        // vy' = vy0 + g*0.1; y' = vy'*0.1 (symplectic: velocity updated first).
        let expected_vy = vy0 + DEFAULT_GRAVITY_MPS2 * 0.1;
        assert!((p.vy - expected_vy).abs() < 1e-4);
        assert!((p.y - expected_vy * 0.1).abs() < 1e-4);
        assert_eq!(p.age_ms, 100.0);
    }

    #[test]
    fn particles_expire_at_lifetime() {
        let mut sim = DebrisSimulation::with_config(DebrisConfig {
            burst_size: 3,
            particle_lifetime_ms: 800.0,
            ..Default::default()
        });
        let mut rng = seq_rng(vec![0.3, 0.7, 0.5, 0.5]);
        sim.spawn(&[point(0.0, 0.0, 0.0)], DebrisKind::Damaged, &mut rng);
        assert_eq!(sim.active_count(), 3);

        sim.update(799.0);
        assert_eq!(sim.active_count(), 3, "just under lifetime → still alive");
        sim.update(1.0); // reaches 800 → expired
        assert_eq!(sim.active_count(), 0, "at lifetime → dropped");
    }

    #[test]
    fn global_cap_trims_oldest_particles() {
        let mut sim = DebrisSimulation::with_config(DebrisConfig {
            burst_size: 1,
            max_live_particles: 5,
            ..Default::default()
        });
        let mut rng = seq_rng(vec![0.1, 0.2, 0.3, 0.4]);
        // Spawn 8 single-particle bursts at distinguishable y; cap = 5 → oldest 3
        // (y=0,1,2) trimmed, newest 5 (y=3..7) survive.
        for i in 0..8 {
            sim.spawn(
                &[point(0.0, i as f32, 0.0)],
                DebrisKind::Destroyed,
                &mut rng,
            );
        }
        assert_eq!(sim.active_count(), 5);
        let ys: Vec<f32> = sim.live_particles().iter().map(|p| p.y).collect();
        assert_eq!(ys, vec![3.0, 4.0, 5.0, 6.0, 7.0]);
    }

    #[test]
    fn update_is_a_noop_for_nonpositive_dt() {
        let mut sim = DebrisSimulation::with_config(DebrisConfig {
            burst_size: 2,
            ..Default::default()
        });
        let mut rng = seq_rng(vec![0.5]);
        sim.spawn(&[point(1.0, 1.0, 1.0)], DebrisKind::Destroyed, &mut rng);
        let before = sim.live_particles().to_vec();
        sim.update(0.0);
        sim.update(-16.0);
        assert_eq!(sim.live_particles(), before.as_slice());
    }

    #[test]
    fn reset_clears_all_particles() {
        let mut sim = DebrisSimulation::new();
        let mut rng = seq_rng(vec![0.5]);
        sim.spawn(&[point(0.0, 0.0, 0.0)], DebrisKind::Destroyed, &mut rng);
        assert!(sim.active_count() > 0);
        sim.reset();
        assert_eq!(sim.active_count(), 0);
    }
}
