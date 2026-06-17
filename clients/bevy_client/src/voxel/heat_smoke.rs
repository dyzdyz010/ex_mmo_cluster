//! Heat-smoke particle simulation (the reference's PRIMARY heat visual): a
//! pure-data port of `heatSmokeEffect.ts` `HeatSmokeSimulation`. Joule heating
//! along a powered circuit (electric field stream, 0x73) emits rising smoke
//! whose volume scales with the dissipated energy.
//!
//! Split (mirrors debris / field_view): pure data + integration here — no Bevy,
//! no GPU — so spawn-count scaling, particle motion, and caps are Layer-1
//! assertable; the injected `&mut dyn FnMut() -> f32` lets tests drive the RNG
//! deterministically. The Bevy adapter feeds per-arrival electric snapshots and
//! uploads `live_particles()` to instanced cubes.
//!
//! UNIT NOTE (differs from debris!): positions & velocities are in WORLD units —
//! the reference pre-multiplies macro coords by `MacroWorldSize` (100), so the
//! Bevy adapter does NOT scale by the macro render size; it uses positions as-is.
//!
//! Scope: the web `overlayTarget` projector (prefab / refined per-micro emission)
//! does NOT exist on the bevy side, so this ports the no-projector (macro-cell)
//! path. Under that specialization the reference's point-group + fair-sampling
//! machinery collapses to a trivial selector over the active-cell list (verified
//! against the TS source): round-robin when `spawn_count >= n`, even spread
//! otherwise. The `emissionGroupKey` upsert/dedup is dead code on this path.

use crate::voxel::wire::{FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_ELECTRIC_POTENTIAL};
use std::collections::HashMap;

/// World units per macro cell (web `MacroWorldSize`; matches the renderer's
/// macro size). Heat-smoke positions are already in world units.
pub const MACRO_WORLD: f32 = 100.0;

// HEAT_SMOKE_DEFAULTS (web), with the MacroWorldSize-derived sizes resolved.
pub const JOULES_PER_ACTIVE_CELL_PARTICLE: f32 = 240.0;
pub const FALLBACK_CURRENT_VOLTAGE: f32 = 120.0;
pub const FIELD_TICK_SECONDS: f32 = 0.1;
pub const MAX_SPAWN_PER_SNAPSHOT: usize = 96;
pub const MAX_LIVE_PARTICLES: usize = 640;
pub const PARTICLE_LIFETIME_MS: f32 = 2200.0;
const PARTICLE_SIZE_WORLD: f32 = MACRO_WORLD * 0.16; // 16
const RISE_SPEED_WORLD: f32 = MACRO_WORLD * 0.34; // 34
const DRIFT_SPEED_WORLD: f32 = MACRO_WORLD * 0.05; // 5

/// Active-cell thresholds: current preferred (|I| >= 0.001), else potential
/// (|V| >= 0.5) — mirrors `activeElectricCells`.
const CURRENT_ACTIVE_THRESHOLD: f32 = 0.001;
const POTENTIAL_ACTIVE_THRESHOLD: f32 = 0.5;

/// Horizontal velocity damping per `update` (vy/rise is NOT damped).
const HORIZONTAL_DAMPING: f32 = 0.985;

const CHUNK_SIZE_MACRO: i32 = 16;

/// A borrowed view of the electric data from one `FieldRegionSnapshot` (0x73) —
/// the sim's spawn input, kept decoupled from the wire/Bevy types so it stays
/// pure and trivially testable.
pub struct ElectricField<'a> {
    pub region_id: u64,
    pub chunk_coord: [i32; 3],
    pub field_mask: u8,
    pub macro_indices: &'a [u16],
    pub electric_potential: &'a [f32],
    pub electric_current: &'a [f32],
}

/// One live smoke particle. Positions/velocities are WORLD units; `region_id`
/// scopes per-region clears; `size_world` drives the render cube scale.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HeatSmokeParticle {
    pub region_id: u64,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub vx: f32,
    pub vy: f32,
    pub vz: f32,
    pub age_ms: f32,
    pub lifetime_ms: f32,
    pub size_world: f32,
}

/// Tunable parameters (defaults mirror `HEAT_SMOKE_DEFAULTS`).
#[derive(Debug, Clone, Copy)]
pub struct HeatSmokeConfig {
    pub joules_per_active_cell_particle: f32,
    pub max_spawn_per_snapshot: usize,
    pub max_live_particles: usize,
    pub particle_lifetime_ms: f32,
    pub particle_size_world: f32,
    pub rise_speed_world: f32,
    pub drift_speed_world: f32,
}

impl Default for HeatSmokeConfig {
    fn default() -> Self {
        Self {
            joules_per_active_cell_particle: JOULES_PER_ACTIVE_CELL_PARTICLE,
            max_spawn_per_snapshot: MAX_SPAWN_PER_SNAPSHOT,
            max_live_particles: MAX_LIVE_PARTICLES,
            particle_lifetime_ms: PARTICLE_LIFETIME_MS,
            particle_size_world: PARTICLE_SIZE_WORLD,
            rise_speed_world: RISE_SPEED_WORLD,
            drift_speed_world: DRIFT_SPEED_WORLD,
        }
    }
}

struct ActiveCell {
    x: i32,
    y: i32,
    z: i32,
    potential: f32,
}

/// Pure heat-smoke simulation: emits per electric snapshot, integrates each
/// frame. No Bevy.
#[derive(Debug, Default)]
pub struct HeatSmokeSimulation {
    particles: Vec<HeatSmokeParticle>,
    region_heat_joules_per_tick: HashMap<u64, f32>,
    config: HeatSmokeConfig,
}

impl HeatSmokeSimulation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_config(config: HeatSmokeConfig) -> Self {
        Self {
            particles: Vec::new(),
            region_heat_joules_per_tick: HashMap::new(),
            config,
        }
    }

    /// Overrides a region's dissipated energy/tick (e.g. from a known power
    /// draw). `<= 0` / non-finite clears the override (falls back to estimate),
    /// matching `setRegionHeatSmokeSource`.
    pub fn set_region_heat_source(&mut self, region_id: u64, joules_per_tick: f32) {
        if !joules_per_tick.is_finite() || joules_per_tick <= 0.0 {
            self.region_heat_joules_per_tick.remove(&region_id);
        } else {
            self.region_heat_joules_per_tick
                .insert(region_id, joules_per_tick);
        }
    }

    /// Emits a smoke burst for one electric snapshot. Returns the number spawned.
    /// Gated (like the reference) on: an electric mask bit present, positive heat
    /// energy (region override else current estimate), and ≥1 active cell.
    pub fn spawn_from_electric(
        &mut self,
        field: &ElectricField,
        rng: &mut dyn FnMut() -> f32,
    ) -> usize {
        if field.field_mask & (FIELD_MASK_ELECTRIC_POTENTIAL | FIELD_MASK_ELECTRIC_CURRENT) == 0 {
            return 0;
        }

        let heat = self
            .region_heat_joules_per_tick
            .get(&field.region_id)
            .copied()
            .unwrap_or_else(|| estimate_heat_energy(field));
        if heat <= 0.0 {
            return 0;
        }

        let cells = active_electric_cells(field);
        if cells.is_empty() {
            return 0;
        }

        let heat_scale = heat / self.config.joules_per_active_cell_particle;
        // pointCount = active-cell count (one point per cell, no projector).
        let point_count = cells.len();
        let spawn_count = ((point_count as f32 * heat_scale).ceil() as i64)
            .clamp(1, self.config.max_spawn_per_snapshot as i64) as usize;

        for cell_index in fair_selection(cells.len(), spawn_count) {
            let particle = self.build_particle(field, &cells[cell_index], heat_scale, rng);
            self.particles.push(particle);
        }

        // Global cap: trim the oldest (front).
        if self.particles.len() > self.config.max_live_particles {
            let overflow = self.particles.len() - self.config.max_live_particles;
            self.particles.drain(0..overflow);
        }

        spawn_count
    }

    /// Advances every particle by `dt_ms`: rise + drift, horizontal damping only,
    /// expire at lifetime. Compacts in place.
    pub fn update(&mut self, dt_ms: f32) {
        if dt_ms <= 0.0 {
            return;
        }
        let dt_s = dt_ms / 1000.0;
        self.particles.retain_mut(|p| {
            let new_age = p.age_ms + dt_ms;
            if new_age >= p.lifetime_ms {
                return false; // expired
            }
            p.x += p.vx * dt_s;
            p.y += p.vy * dt_s;
            p.z += p.vz * dt_s;
            p.vx *= HORIZONTAL_DAMPING;
            p.vz *= HORIZONTAL_DAMPING;
            p.age_ms = new_age;
            true
        });
    }

    /// Live count, optionally scoped to one region.
    pub fn active_count(&self, region_id: Option<u64>) -> usize {
        match region_id {
            None => self.particles.len(),
            Some(id) => self.particles.iter().filter(|p| p.region_id == id).count(),
        }
    }

    pub fn live_particles(&self) -> &[HeatSmokeParticle] {
        &self.particles
    }

    /// Drops a region's heat source override AND its live particles.
    pub fn clear_region(&mut self, region_id: u64) {
        self.region_heat_joules_per_tick.remove(&region_id);
        self.clear_region_particles(region_id);
    }

    pub fn clear_region_particles(&mut self, region_id: u64) {
        self.particles.retain(|p| p.region_id != region_id);
    }

    pub fn reset(&mut self) {
        self.region_heat_joules_per_tick.clear();
        self.particles.clear();
    }

    fn build_particle(
        &self,
        field: &ElectricField,
        cell: &ActiveCell,
        heat_scale: f32,
        rng: &mut dyn FnMut() -> f32,
    ) -> HeatSmokeParticle {
        // World emission point: cell center in x/z, near the top (0.92) in y.
        let wx = field.chunk_coord[0] * CHUNK_SIZE_MACRO + cell.x;
        let wy = field.chunk_coord[1] * CHUNK_SIZE_MACRO + cell.y;
        let wz = field.chunk_coord[2] * CHUNK_SIZE_MACRO + cell.z;
        let origin_x = (wx as f32 + 0.5) * MACRO_WORLD;
        let origin_y = (wy as f32 + 0.92) * MACRO_WORLD;
        let origin_z = (wz as f32 + 0.5) * MACRO_WORLD;

        // RNG draw order MUST match the reference: jitterX, jitterZ, driftAngle,
        // driftSpeed, riseSpeed (5 draws).
        let jitter_x = (rng() - 0.5) * MACRO_WORLD * 0.34;
        let jitter_z = (rng() - 0.5) * MACRO_WORLD * 0.34;
        let drift_angle = rng() * std::f32::consts::TAU;
        let drift_speed =
            self.config.drift_speed_world * (0.35 + 0.65 * rng()) * heat_scale.min(2.0);
        let rise_speed = self.config.rise_speed_world * (0.75 + 0.5 * rng()) * heat_scale.min(1.6);
        let potential_scale = (cell.potential.abs() / 120.0).clamp(0.75, 1.8);

        HeatSmokeParticle {
            region_id: field.region_id,
            x: origin_x + jitter_x,
            y: origin_y, // no y jitter
            z: origin_z + jitter_z,
            vx: drift_angle.cos() * drift_speed,
            vy: rise_speed,
            vz: drift_angle.sin() * drift_speed,
            age_ms: 0.0,
            lifetime_ms: self.config.particle_lifetime_ms,
            size_world: self.config.particle_size_world * potential_scale,
        }
    }
}

/// Estimates dissipated energy/tick from peak current: `max|I| * V * tick`
/// (V=120, tick=0.1). Zero when there is no current layer → no spawn.
fn estimate_heat_energy(field: &ElectricField) -> f32 {
    if field.field_mask & FIELD_MASK_ELECTRIC_CURRENT == 0 {
        return 0.0;
    }
    let max_current = field
        .electric_current
        .iter()
        .copied()
        .filter(|v| v.is_finite())
        .fold(0.0f32, |m, v| m.max(v.abs()));
    max_current * FALLBACK_CURRENT_VOLTAGE * FIELD_TICK_SECONDS
}

/// Active cells: current first (|I| >= 0.001), else potential (|V| >= 0.5).
fn active_electric_cells(field: &ElectricField) -> Vec<ActiveCell> {
    let from_current = active_from_values(
        field.macro_indices,
        field.electric_current,
        CURRENT_ACTIVE_THRESHOLD,
    );
    if !from_current.is_empty() {
        return from_current;
    }
    active_from_values(
        field.macro_indices,
        field.electric_potential,
        POTENTIAL_ACTIVE_THRESHOLD,
    )
}

fn active_from_values(indices: &[u16], values: &[f32], threshold: f32) -> Vec<ActiveCell> {
    indices
        .iter()
        .zip(values.iter())
        .filter_map(|(&idx, &value)| {
            if value.is_finite() && value.abs() >= threshold {
                let (x, y, z) = macro_coord(idx);
                Some(ActiveCell {
                    x,
                    y,
                    z,
                    potential: value,
                })
            } else {
                None
            }
        })
        .collect()
}

fn macro_coord(idx: u16) -> (i32, i32, i32) {
    let i = idx as i32;
    (i & 0xf, (i >> 4) & 0xf, (i >> 8) & 0xf)
}

/// Selects `spawn_count` cell indices from `n` cells, reproducing the reference
/// fair-sampler under the one-point-per-cell / infinite-capacity specialization:
/// round-robin when `spawn_count >= n`, an even spread otherwise.
fn fair_selection(n: usize, spawn_count: usize) -> Vec<usize> {
    if n == 0 || spawn_count == 0 {
        return Vec::new();
    }
    if spawn_count >= n {
        (0..spawn_count).map(|k| k % n).collect()
    } else {
        (0..spawn_count)
            .map(|i| {
                let raw = (((i as f64) + 0.5) * n as f64 / spawn_count as f64).floor() as usize;
                raw.min(n - 1)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seq_rng(values: Vec<f32>) -> impl FnMut() -> f32 {
        let mut i = 0;
        move || {
            let v = values[i % values.len()];
            i += 1;
            v
        }
    }

    fn current_field<'a>(
        region_id: u64,
        chunk: [i32; 3],
        indices: &'a [u16],
        current: &'a [f32],
    ) -> ElectricField<'a> {
        ElectricField {
            region_id,
            chunk_coord: chunk,
            field_mask: FIELD_MASK_ELECTRIC_CURRENT,
            macro_indices: indices,
            electric_potential: &[],
            electric_current: current,
        }
    }

    #[test]
    fn no_electric_mask_spawns_nothing() {
        let mut sim = HeatSmokeSimulation::new();
        let field = ElectricField {
            region_id: 1,
            chunk_coord: [0, 0, 0],
            field_mask: FIELD_MASK_TEMPERATURE_ONLY,
            macro_indices: &[0],
            electric_potential: &[],
            electric_current: &[],
        };
        let mut rng = seq_rng(vec![0.5]);
        assert_eq!(sim.spawn_from_electric(&field, &mut rng), 0);
        assert_eq!(sim.active_count(None), 0);
    }

    const FIELD_MASK_TEMPERATURE_ONLY: u8 = 0x01;

    #[test]
    fn current_snapshot_spawns_and_scales_with_current() {
        let mut sim = HeatSmokeSimulation::new();
        let indices = [0u16, 1, 2];
        // Small current: max|I| = 0.5 → heat = 0.5*120*0.1 = 6; heatScale = 6/240
        // = 0.025; ceil(3*0.025)=ceil(0.075)=1 → clamp(1,96)=1 particle.
        let low = [0.5f32, 0.2, 0.1];
        let mut rng = seq_rng(vec![0.5, 0.25, 0.1, 0.9, 0.3]);
        let n_low = sim.spawn_from_electric(&current_field(1, [0, 0, 0], &indices, &low), &mut rng);
        assert_eq!(n_low, 1);

        // Large current: max|I| = 5000 → heat = 5000*12 = 60000; heatScale = 250;
        // ceil(3*250)=750 → clamped to maxSpawnPerSnapshot 96.
        let high = [5000.0f32, 4000.0, 3000.0];
        let mut sim2 = HeatSmokeSimulation::new();
        let mut rng2 = seq_rng(vec![0.5, 0.25, 0.1, 0.9, 0.3]);
        let n_high =
            sim2.spawn_from_electric(&current_field(2, [0, 0, 0], &indices, &high), &mut rng2);
        assert_eq!(n_high, 96);
        assert!(n_high > n_low);
    }

    #[test]
    fn region_heat_source_overrides_estimate() {
        let mut sim = HeatSmokeSimulation::new();
        // Potential-only field (no current mask → estimate would be 0 → no spawn).
        let indices = [0u16];
        let field = ElectricField {
            region_id: 7,
            chunk_coord: [0, 0, 0],
            field_mask: FIELD_MASK_ELECTRIC_POTENTIAL,
            macro_indices: &indices,
            electric_potential: &[100.0],
            electric_current: &[],
        };
        let mut rng = seq_rng(vec![0.5, 0.25, 0.1, 0.9, 0.3]);
        assert_eq!(sim.spawn_from_electric(&field, &mut rng), 0);

        // With an override, a potential-only snapshot spawns.
        sim.set_region_heat_source(7, 480.0); // heatScale = 2; ceil(1*2)=2
        let mut rng2 = seq_rng(vec![0.5, 0.25, 0.1, 0.9, 0.3]);
        assert_eq!(sim.spawn_from_electric(&field, &mut rng2), 2);
        // Clearing the override (<=0) reverts to estimate (0 → no spawn).
        sim.set_region_heat_source(7, 0.0);
        sim.reset();
        let mut rng3 = seq_rng(vec![0.5, 0.25, 0.1, 0.9, 0.3]);
        assert_eq!(sim.spawn_from_electric(&field, &mut rng3), 0);
    }

    #[test]
    fn particles_rise_in_world_units_and_at_cell_top() {
        let mut sim = HeatSmokeSimulation::new();
        let indices = [0u16];
        let current = [10.0f32]; // heat = 12000, heatScale=50 → ceil(1*50)=50 → 50
        // rng all 0.5 → jitter 0, driftAngle = pi, drift/rise mid.
        let mut rng = seq_rng(vec![0.5]);
        sim.spawn_from_electric(&current_field(1, [1, 0, -1], &indices, &current), &mut rng);
        let p = sim.live_particles()[0];
        // chunk (1,0,-1), cell (0,0,0) → world macro (16,0,-16); origin
        // ((16.5)*100, (0.92)*100, (-15.5)*100) = (1650, 92, -1550); jitter 0.
        assert!((p.x - 1650.0).abs() < 1e-3);
        assert!((p.y - 92.0).abs() < 1e-3);
        assert!((p.z - (-1550.0)).abs() < 1e-3);
        assert!(p.vy > 0.0, "smoke rises");
    }

    #[test]
    fn update_rises_damps_horizontal_and_expires() {
        let mut sim = HeatSmokeSimulation::new();
        let indices = [0u16];
        let current = [10.0f32];
        let mut rng = seq_rng(vec![0.5]);
        sim.spawn_from_electric(&current_field(1, [0, 0, 0], &indices, &current), &mut rng);
        let before = sim.live_particles()[0];
        let vx0 = before.vx;

        sim.update(100.0); // 0.1 s
        let after = sim.live_particles()[0];
        assert!(
            (after.y - (before.y + before.vy * 0.1)).abs() < 1e-2,
            "rises"
        );
        // Horizontal velocity damped by 0.985 (vy untouched).
        assert!((after.vx - vx0 * 0.985).abs() < 1e-4);
        assert_eq!(after.vy, before.vy);
        assert_eq!(after.age_ms, 100.0);

        // Past the 2200ms lifetime → expires.
        sim.update(2200.0);
        assert_eq!(sim.active_count(None), 0);
    }

    #[test]
    fn global_cap_trims_oldest() {
        let mut sim = HeatSmokeSimulation::with_config(HeatSmokeConfig {
            max_live_particles: 10,
            ..Default::default()
        });
        let indices = [0u16, 1, 2];
        let current = [5000.0f32, 4000.0, 3000.0]; // spawns 96 → capped to 10
        let mut rng = seq_rng(vec![0.5]);
        sim.spawn_from_electric(&current_field(1, [0, 0, 0], &indices, &current), &mut rng);
        assert_eq!(sim.active_count(None), 10);
    }

    #[test]
    fn clear_region_drops_only_that_regions_particles() {
        let mut sim = HeatSmokeSimulation::new();
        let indices = [0u16];
        let current = [10.0f32];
        let mut rng = seq_rng(vec![0.5]);
        sim.spawn_from_electric(&current_field(1, [0, 0, 0], &indices, &current), &mut rng);
        sim.spawn_from_electric(&current_field(2, [0, 0, 0], &indices, &current), &mut rng);
        let total = sim.active_count(None);
        let region1 = sim.active_count(Some(1));
        assert!(region1 > 0 && total > region1);
        sim.clear_region(1);
        assert_eq!(sim.active_count(Some(1)), 0);
        assert_eq!(sim.active_count(None), total - region1);
    }

    #[test]
    fn active_cells_prefer_current_over_potential() {
        // Both layers present: current cells (>=0.001) win over potential.
        let indices = [0u16, 1];
        let field = ElectricField {
            region_id: 1,
            chunk_coord: [0, 0, 0],
            field_mask: FIELD_MASK_ELECTRIC_POTENTIAL | FIELD_MASK_ELECTRIC_CURRENT,
            macro_indices: &indices,
            electric_potential: &[100.0, 100.0],
            electric_current: &[2.0, 0.0], // only cell 0 has active current
        };
        let cells = active_electric_cells(&field);
        assert_eq!(cells.len(), 1); // current path: only cell 0
        assert_eq!(cells[0].potential, 2.0);
    }

    #[test]
    fn fair_selection_round_robin_and_spread() {
        // spawn_count >= n → round-robin.
        assert_eq!(fair_selection(3, 5), vec![0, 1, 2, 0, 1]);
        // spawn_count < n → even spread (distinct, increasing).
        let spread = fair_selection(10, 3);
        assert_eq!(spread, vec![1, 5, 8]);
        // edges
        assert_eq!(fair_selection(0, 5), Vec::<usize>::new());
        assert_eq!(fair_selection(4, 0), Vec::<usize>::new());
    }
}
