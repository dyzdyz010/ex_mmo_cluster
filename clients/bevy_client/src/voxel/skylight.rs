//! Per-cell static skylight (光可见度 Phase A · 弥漫光场).
//!
//! Pure, client-side skylight derived from the authoritative chunk occupancy
//! (`AuthorityChunk` / `CellState`): open-sky cells are full-bright, cells under
//! cover attenuate per cell of depth down to an ambient floor. This is the
//! "world has light and dark — surface bright, caves dark" base layer; the mesher
//! (step3) bakes it (combined with the server `:light` block-light field) into the
//! chunk mesh vertex colors, replacing the fixed global ambient.
//!
//! Decision (Phase A): skylight is computed CLIENT-SIDE from the server's
//! authoritative geometry — zero wire cost, deterministic from truth, cheap
//! (O(chunk)). Server-authoritative skylight/visibility (for stealth / AOI) is
//! Phase B. See `docs/2026-06-23-light-visibility-phase-a-diffuse-lightmap.md`.
//!
//! Model (v1, static skylight + ambient floor, per the user's pick): top-down per
//! column — open air above the first occupied cell stays full; once below cover,
//! light drops sharply through each occupier and dims gradually through the air
//! under it, clamped to a floor. Chunk-local (cross-chunk occlusion is v2).
//!
//! Pure data, no Bevy — Layer-1 assertable (the 5 formal invariants below).

use crate::voxel::authority::{AuthorityChunk, CellState};

/// Tunable skylight parameters. Defaults give a clear surface/cave contrast while
/// keeping deep interiors faintly visible (never pure black).
#[derive(Debug, Clone, Copy)]
pub struct SkylightConfig {
    /// Multiplier applied to the skylight passing THROUGH an occupied cell — an
    /// opaque block strongly shadows everything below it.
    pub occluder_attenuation: f32,
    /// Multiplier applied per air cell of depth once below cover — interiors dim
    /// gradually the deeper they are.
    pub depth_attenuation: f32,
    /// Ambient floor: no cell ever reads darker than this (keeps caves legible).
    pub floor: f32,
}

impl Default for SkylightConfig {
    fn default() -> Self {
        Self {
            occluder_attenuation: 0.35,
            depth_attenuation: 0.82,
            floor: 0.12,
        }
    }
}

/// Per-cell skylight levels in `[floor, 1.0]`, flat `size^3` row-major
/// (`x + y*size + z*size^2`), matching the mesher's cell indexing.
#[derive(Debug, Clone, PartialEq)]
pub struct Skylight {
    size: usize,
    floor: f32,
    levels: Vec<f32>,
}

impl Skylight {
    /// Computes skylight for `chunk`. A degenerate chunk (size 0 / cell count
    /// mismatch) yields an all-floor field of the declared size (safe fallback).
    pub fn compute(chunk: &AuthorityChunk, config: SkylightConfig) -> Self {
        let size = chunk.chunk_size_in_macro as usize;
        let floor = config.floor;

        if size == 0 || chunk.cells.len() != size * size * size {
            return Self {
                size,
                floor,
                levels: vec![floor; size * size * size],
            };
        }

        let mut levels = vec![floor; size * size * size];
        let index_of = |x: usize, y: usize, z: usize| x + y * size + z * size * size;

        for z in 0..size {
            for x in 0..size {
                // Top-down: `light` = skylight reaching the current cell from above.
                let mut light = 1.0_f32;
                let mut covered = false;

                for y in (0..size).rev() {
                    let idx = index_of(x, y, z);
                    levels[idx] = light.max(floor);

                    if occupies(&chunk.cells[idx]) {
                        // The block shadows everything below it.
                        covered = true;
                        light *= config.occluder_attenuation;
                    } else if covered {
                        // Air under cover dims with depth; open air above the
                        // surface keeps full skylight (no else branch).
                        light *= config.depth_attenuation;
                    }
                }
            }
        }

        Self {
            size,
            floor,
            levels,
        }
    }

    pub fn size(&self) -> usize {
        self.size
    }

    pub fn floor(&self) -> f32 {
        self.floor
    }

    /// Skylight at a local cell, or the floor for out-of-bounds (callers may probe
    /// chunk-boundary neighbors; treating outside as floor is the safe default —
    /// upward boundary open-sky is handled by the mesher, not here).
    pub fn at(&self, x: i32, y: i32, z: i32) -> f32 {
        let s = self.size as i32;
        if x < 0 || y < 0 || z < 0 || x >= s || y >= s || z >= s {
            return self.floor;
        }
        let idx = (x as usize) + (y as usize) * self.size + (z as usize) * self.size * self.size;
        self.levels[idx]
    }

    pub fn at_index(&self, idx: usize) -> f32 {
        self.levels.get(idx).copied().unwrap_or(self.floor)
    }
}

/// Whether a cell occludes skylight (same occupancy rule the mesher culls on).
fn occupies(cell: &CellState) -> bool {
    matches!(cell, CellState::Solid(_) | CellState::Refined(_))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::NormalBlock;

    const SIZE: usize = 16;

    fn empty_chunk() -> AuthorityChunk {
        AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: SIZE as u8,
            cells: vec![CellState::Empty; SIZE * SIZE * SIZE],
            surface_elements: vec![],
        }
    }

    fn solid() -> CellState {
        CellState::Solid(NormalBlock {
            material_id: 2,
            state_flags: 0,
            health: 0,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        })
    }

    fn set(chunk: &mut AuthorityChunk, x: usize, y: usize, z: usize, cell: CellState) {
        chunk.cells[x + y * SIZE + z * SIZE * SIZE] = cell;
    }

    /// Invariant 5 + 1: an all-empty chunk is full skylight everywhere (open sky).
    #[test]
    fn empty_chunk_is_full_skylight() {
        let sky = Skylight::compute(&empty_chunk(), SkylightConfig::default());
        for y in 0..SIZE as i32 {
            assert_eq!(sky.at(0, y, 0), 1.0, "open column y={y} should be full");
        }
    }

    /// Invariant 1: cells in an open column above any cover are full-bright.
    #[test]
    fn open_air_above_surface_is_full() {
        let mut chunk = empty_chunk();
        set(&mut chunk, 3, 5, 3, solid()); // a surface block at y=5
        let sky = Skylight::compute(&chunk, SkylightConfig::default());
        // Everything strictly above the surface block is open sky → full.
        for y in 6..SIZE as i32 {
            assert_eq!(sky.at(3, y, 3), 1.0, "above-surface y={y} should be full");
        }
        // The surface block's own cell records the light arriving at its top (full).
        assert_eq!(sky.at(3, 5, 3), 1.0);
    }

    /// Invariant 2: below a single cover, skylight decreases monotonically with depth.
    #[test]
    fn under_cover_decreases_monotonically_with_depth() {
        let mut chunk = empty_chunk();
        set(&mut chunk, 7, 10, 7, solid()); // roof at y=10, hollow below
        let sky = Skylight::compute(&chunk, SkylightConfig::default());

        let mut prev = sky.at(7, 9, 7); // first air cell under the roof
        assert!(prev < 1.0, "directly under the roof should be shadowed");
        for y in (0..9).rev() {
            let cur = sky.at(7, y, 7);
            assert!(
                cur <= prev + 1e-6,
                "depth y={y}: {cur} should be ≤ shallower {prev}"
            );
            prev = cur;
        }
    }

    /// Invariant 3: deep under cover, skylight bottoms out at the ambient floor.
    #[test]
    fn deep_interior_reaches_floor() {
        let mut chunk = empty_chunk();
        set(&mut chunk, 2, 15, 2, solid()); // roof at the very top
        let cfg = SkylightConfig::default();
        let sky = Skylight::compute(&chunk, cfg);
        // The bottom cell of a deep covered column is clamped to the floor.
        assert_eq!(sky.at(2, 0, 2), cfg.floor);
    }

    /// Invariant 4: deterministic — same input yields byte-identical output.
    #[test]
    fn deterministic() {
        let mut chunk = empty_chunk();
        set(&mut chunk, 4, 8, 4, solid());
        set(&mut chunk, 4, 3, 4, solid());
        let a = Skylight::compute(&chunk, SkylightConfig::default());
        let b = Skylight::compute(&chunk, SkylightConfig::default());
        assert_eq!(a, b);
    }

    /// Source-dominance corollary: adding cover never brightens any cell.
    #[test]
    fn adding_cover_never_brightens() {
        let open = Skylight::compute(&empty_chunk(), SkylightConfig::default());
        let mut chunk = empty_chunk();
        set(&mut chunk, 9, 12, 9, solid());
        let covered = Skylight::compute(&chunk, SkylightConfig::default());
        for y in 0..SIZE as i32 {
            assert!(
                covered.at(9, y, 9) <= open.at(9, y, 9) + 1e-6,
                "adding a roof must not brighten y={y}"
            );
        }
    }

    /// Bounded: every level stays within [floor, 1.0].
    #[test]
    fn levels_are_bounded() {
        let mut chunk = empty_chunk();
        for y in 0..SIZE {
            set(&mut chunk, 5, y, 5, solid()); // a full solid column
        }
        let cfg = SkylightConfig::default();
        let sky = Skylight::compute(&chunk, cfg);
        for &v in &sky.levels {
            assert!(v >= cfg.floor - 1e-6 && v <= 1.0 + 1e-6, "level {v} out of range");
        }
    }
}
