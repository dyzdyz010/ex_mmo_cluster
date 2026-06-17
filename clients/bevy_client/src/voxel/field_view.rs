//! Field visualization (C3): consumes the Phase-6 `FieldRegionSnapshot` (0x73)
//! / `FieldRegionDestroyed` (0x74) stream and turns the emergence layer's
//! thermal/electric field truth into a renderable overlay — the FieldView render
//! sub-layer, parallel to ChunkMesh / SurfaceDecal.
//!
//! Design (mirrors the web oracle's heat-smoke / lightning, but as assertable
//! geometry): a field region is keyed by `region_id` (ephemeral; replaced on a
//! newer snapshot, dropped on destroy). The first visualization is a TEMPERATURE
//! heat overlay — a small marker cube at each macro cell hotter than a threshold,
//! colored by a heat bucket. Pure data (no Bevy) → Layer-1 geometry assertable;
//! the Bevy adapter spawns the overlay mesh as an entity.
//!
//! Only reads committed field truth (no fabrication) — same authority discipline
//! as the chunk store.

use crate::voxel::mesher::{ChunkMeshData, push_cube};
use crate::voxel::wire::{FIELD_MASK_TEMPERATURE, FieldRegionDestroyed, FieldRegionSnapshot};
use std::collections::HashMap;

/// Heat-marker material ids (a reserved range above real `MaterialCatalog` ids,
/// so the FieldView palette never collides with block/decal materials). The
/// bucket reflects temperature magnitude; the Bevy adapter maps these to a
/// warm→hot color ramp.
pub const HEAT_MATERIAL_BASE: u32 = 10_000;
pub const HEAT_BUCKET_COUNT: u32 = 4;

/// Default "show this cell" threshold (°C): above ambient/room so only genuinely
/// heated cells (electric I²R, combustion, torches) light up.
pub const DEFAULT_HEAT_THRESHOLD_C: f32 = 40.0;

/// Marker cube edge as a fraction of a macro cell (centered in the cell).
const MARKER_FRACTION: f32 = 0.5;

/// Pure store of the latest field snapshot per region, driven by the 0x73/0x74
/// stream. Ephemeral: a newer snapshot for a region replaces it; destroy removes.
#[derive(Debug, Default)]
pub struct VoxelFieldStore {
    regions: HashMap<u64, FieldRegionSnapshot>,
}

impl VoxelFieldStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores (replaces) the field region's latest snapshot.
    pub fn apply_snapshot(&mut self, snapshot: FieldRegionSnapshot) {
        self.regions.insert(snapshot.region_id, snapshot);
    }

    /// Drops a destroyed field region. Returns whether a region was removed.
    pub fn apply_destroyed(&mut self, destroyed: &FieldRegionDestroyed) -> bool {
        self.regions.remove(&destroyed.region_id).is_some()
    }

    pub fn region(&self, region_id: u64) -> Option<&FieldRegionSnapshot> {
        self.regions.get(&region_id)
    }

    pub fn region_count(&self) -> usize {
        self.regions.len()
    }
}

/// Buckets a temperature (°C) into `0..HEAT_BUCKET_COUNT` heat-marker materials.
/// Threshold..(threshold+ramp) maps across the buckets; hotter → higher bucket.
pub fn heat_material(temperature_c: f32, threshold_c: f32) -> u32 {
    let over = (temperature_c - threshold_c).max(0.0);
    // 200°C of headroom spread across the buckets (qualitative, like the server
    // heat gains): >threshold+200 saturates at the top bucket.
    let ramp = 200.0;
    let bucket = ((over / ramp) * HEAT_BUCKET_COUNT as f32).floor() as u32;
    HEAT_MATERIAL_BASE + bucket.min(HEAT_BUCKET_COUNT - 1)
}

/// Builds the temperature heat overlay for a field region: a marker cube at each
/// macro cell whose temperature exceeds `threshold_c`, colored by heat bucket.
/// Cells in the snapshot without temperature data (mask bit clear) produce nothing.
pub fn temperature_overlay_mesh(
    field: &FieldRegionSnapshot,
    voxel_size: f32,
    threshold_c: f32,
) -> ChunkMeshData {
    let mut mesh = ChunkMeshData::default();
    if field.field_mask & FIELD_MASK_TEMPERATURE == 0 {
        return mesh;
    }

    let marker = voxel_size * MARKER_FRACTION;
    let inset = (voxel_size - marker) * 0.5; // center the marker in the macro cell

    for (i, &macro_index) in field.macro_indices.iter().enumerate() {
        let Some(&temp) = field.temperature.get(i) else {
            continue;
        };
        if temp <= threshold_c {
            continue;
        }
        let (mx, my, mz) = macro_coord(macro_index);
        let min = [
            mx as f32 * voxel_size + inset,
            my as f32 * voxel_size + inset,
            mz as f32 * voxel_size + inset,
        ];
        push_cube(&mut mesh, min, marker, heat_material(temp, threshold_c));
    }

    mesh
}

fn macro_coord(macro_index: u16) -> (i32, i32, i32) {
    let i = macro_index as i32;
    (i % 16, (i / 16) % 16, i / 256)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(region_id: u64, cells: &[(u16, f32)]) -> FieldRegionSnapshot {
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id,
            tick_count: 1,
            field_mask: FIELD_MASK_TEMPERATURE,
            macro_indices: cells.iter().map(|(i, _)| *i).collect(),
            temperature: cells.iter().map(|(_, t)| *t).collect(),
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![],
        }
    }

    #[test]
    fn store_replaces_per_region_and_drops_on_destroy() {
        let mut store = VoxelFieldStore::new();
        store.apply_snapshot(snapshot(7, &[(0, 100.0)]));
        assert_eq!(store.region_count(), 1);
        // Newer snapshot for same region replaces.
        store.apply_snapshot(snapshot(7, &[(0, 200.0), (1, 50.0)]));
        assert_eq!(store.region(7).unwrap().macro_indices.len(), 2);

        let destroyed = FieldRegionDestroyed {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id: 7,
            destroy_reason: 0,
        };
        assert!(store.apply_destroyed(&destroyed));
        assert_eq!(store.region_count(), 0);
        assert!(!store.apply_destroyed(&destroyed)); // already gone
    }

    #[test]
    fn overlay_marks_only_cells_above_threshold() {
        // Three cells: 20°C (cold), 100°C, 500°C. Only the two hot ones get a
        // marker cube (6 faces each → 12 quads).
        let field = snapshot(1, &[(0, 20.0), (5, 100.0), (10, 500.0)]);
        let mesh = temperature_overlay_mesh(&field, 1.0, DEFAULT_HEAT_THRESHOLD_C);
        let s = mesh.summary();
        assert_eq!(s.quad_count, 12);
        assert!(s.structural_ok);
        // Two distinct heat buckets (100°C vs 500°C) → two materials.
        assert_eq!(s.area_by_material.len(), 2);
        assert!(s.area_by_material.keys().all(|m| *m >= HEAT_MATERIAL_BASE));
    }

    #[test]
    fn hotter_cell_gets_higher_heat_bucket() {
        assert!(heat_material(500.0, 40.0) > heat_material(60.0, 40.0));
        // Saturates at the top bucket.
        assert_eq!(
            heat_material(100_000.0, 40.0),
            HEAT_MATERIAL_BASE + HEAT_BUCKET_COUNT - 1
        );
        // At/below threshold → base bucket.
        assert_eq!(heat_material(40.0, 40.0), HEAT_MATERIAL_BASE);
    }

    #[test]
    fn no_temperature_data_no_overlay() {
        let mut field = snapshot(1, &[(0, 999.0)]);
        field.field_mask = 0; // temperature bit clear
        assert!(temperature_overlay_mesh(&field, 1.0, DEFAULT_HEAT_THRESHOLD_C).is_empty());
    }

    #[test]
    fn marker_cube_is_centered_in_its_macro_cell() {
        // macro index 0 → cell (0,0,0); marker is 0.5 of a 100-unit cell, inset
        // 25 → spans [25,75] in each axis (centered).
        let field = snapshot(1, &[(0, 100.0)]);
        let mesh = temperature_overlay_mesh(&field, 100.0, DEFAULT_HEAT_THRESHOLD_C);
        let s = mesh.summary();
        assert_eq!(s.aabb_min, Some([25.0, 25.0, 25.0]));
        assert_eq!(s.aabb_max, Some([75.0, 75.0, 75.0]));
    }
}
