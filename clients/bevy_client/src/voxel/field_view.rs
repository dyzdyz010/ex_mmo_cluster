//! Field visualization (C3): consumes the Phase-6 `FieldRegionSnapshot` (0x73)
//! / `FieldRegionDestroyed` (0x74) stream and turns the emergence layer's
//! thermal/electric field truth into a renderable overlay — the FieldView render
//! sub-layer, parallel to ChunkMesh / SurfaceDecal.
//!
//! Design (mirrors the web oracle's `fieldDebugOverlay.ts`, but as assertable
//! geometry rather than InstancedMesh): a field region is keyed by `region_id`
//! (ephemeral; replaced on a newer snapshot, dropped on destroy). Each field
//! type the snapshot carries becomes its own overlay — a marker cube at each
//! macro cell whose value clears that field's threshold, colored by a bucket on
//! that field's reference color ramp:
//!
//!   * Temperature — warm→white-hot, cells above a threshold (°C).
//!   * Electric potential — black→yellow, `|v|/100` ramp, `|v| >= 0.5`.
//!   * Electric current — dark amber→bright amber, `|v|/20` ramp, `|v| >= 0.001`.
//!
//! The thresholds / ramps mirror the web reference 1:1 so the two clients agree
//! on which cells light up and how. Pure data (no Bevy) → Layer-1 geometry +
//! color-bucket assertable; the Bevy adapter spawns each overlay as an entity.
//!
//! Only reads committed field truth (no fabrication) — same authority discipline
//! as the chunk store.

use crate::voxel::mesher::{ChunkMeshData, push_cube};
use crate::voxel::wire::{
    FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_ELECTRIC_POTENTIAL, FIELD_MASK_TEMPERATURE,
    FieldRegionDestroyed, FieldRegionSnapshot,
};
use std::collections::{HashMap, HashSet};

/// Heat-marker material ids (a reserved range above real `MaterialCatalog` ids,
/// so the FieldView palette never collides with block/decal materials). The
/// bucket reflects temperature magnitude; the color ramp is warm→white-hot.
pub const HEAT_MATERIAL_BASE: u32 = 10_000;
pub const HEAT_BUCKET_COUNT: u32 = 4;

/// Electric-potential marker ids (black→yellow ramp), and electric-current ids
/// (dark→bright amber). Disjoint reserved ranges so `field_color` can dispatch
/// the right ramp purely from the baked material id.
pub const POTENTIAL_MATERIAL_BASE: u32 = 10_100;
pub const POTENTIAL_BUCKET_COUNT: u32 = 8;
pub const CURRENT_MATERIAL_BASE: u32 = 10_200;
pub const CURRENT_BUCKET_COUNT: u32 = 8;

/// Default "show this cell" threshold (°C): above ambient/room so only genuinely
/// heated cells (electric I2R, combustion, torches) light up.
pub const DEFAULT_HEAT_THRESHOLD_C: f32 = 40.0;

/// Electric thresholds + ramp scales, mirrored from the web `fieldDebugOverlay`:
/// potential below 0.5 (and current below 0.001) is noise and not drawn; the
/// color saturates at `|v| >= *_RAMP`.
pub const POTENTIAL_THRESHOLD: f32 = 0.5;
pub const POTENTIAL_RAMP: f32 = 100.0;
pub const CURRENT_THRESHOLD: f32 = 0.001;
pub const CURRENT_RAMP: f32 = 20.0;

/// Marker cube edge as a fraction of a macro cell (centered in the cell). The
/// electric overlay uses the web reference's 0.85; temperature uses a smaller
/// 0.5 so a co-located heat marker reads as nested inside the electric cell.
const TEMP_MARKER_FRACTION: f32 = 0.5;
const ELECTRIC_MARKER_FRACTION: f32 = 0.85;

/// The field types the FieldView renders, one overlay entity per (region, kind).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FieldOverlayKind {
    Temperature,
    ElectricPotential,
    ElectricCurrent,
}

impl FieldOverlayKind {
    /// All kinds, in a stable order (so the render adapter iterates deterministically).
    pub const ALL: [FieldOverlayKind; 3] = [
        FieldOverlayKind::Temperature,
        FieldOverlayKind::ElectricPotential,
        FieldOverlayKind::ElectricCurrent,
    ];

    /// A stable small id for keying render entities by (region_id, kind).
    pub fn ordinal(self) -> u8 {
        match self {
            FieldOverlayKind::Temperature => 0,
            FieldOverlayKind::ElectricPotential => 1,
            FieldOverlayKind::ElectricCurrent => 2,
        }
    }
}

/// Pure store of the latest field snapshot per region, driven by the 0x73/0x74
/// stream. Ephemeral: a newer snapshot for a region replaces it; destroy removes.
/// Touched regions are marked dirty so the FieldView render rebuilds only those.
#[derive(Debug, Default)]
pub struct VoxelFieldStore {
    regions: HashMap<u64, FieldRegionSnapshot>,
    dirty: HashSet<u64>,
}

impl VoxelFieldStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores (replaces) the field region's latest snapshot; marks it dirty.
    pub fn apply_snapshot(&mut self, snapshot: FieldRegionSnapshot) {
        let region_id = snapshot.region_id;
        self.regions.insert(region_id, snapshot);
        self.dirty.insert(region_id);
    }

    /// Drops a destroyed field region (marks dirty so the overlay despawns).
    /// Returns whether a region was removed.
    pub fn apply_destroyed(&mut self, destroyed: &FieldRegionDestroyed) -> bool {
        self.dirty.insert(destroyed.region_id);
        self.regions.remove(&destroyed.region_id).is_some()
    }

    pub fn region(&self, region_id: u64) -> Option<&FieldRegionSnapshot> {
        self.regions.get(&region_id)
    }

    pub fn region_count(&self) -> usize {
        self.regions.len()
    }

    /// Drains regions touched since the last call — the FieldView render rebuilds
    /// exactly these (rebuild overlay if still present, despawn if destroyed).
    pub fn take_dirty(&mut self) -> Vec<u64> {
        let mut dirty: Vec<u64> = self.dirty.drain().collect();
        dirty.sort_unstable();
        dirty
    }
}

/// Unified FieldView color ramp, keyed by the reserved marker material ids the
/// overlay meshers bake. Dispatches by reserved range so the Bevy adapter bakes
/// per-vertex colors without knowing which field produced a quad. Non-field ids
/// fall back to white.
pub fn field_color(material_id: u32) -> [f32; 4] {
    if (HEAT_MATERIAL_BASE..HEAT_MATERIAL_BASE + HEAT_BUCKET_COUNT).contains(&material_id) {
        return heat_color(material_id);
    }
    if (POTENTIAL_MATERIAL_BASE..POTENTIAL_MATERIAL_BASE + POTENTIAL_BUCKET_COUNT)
        .contains(&material_id)
    {
        // black (low) -> yellow (high), mirroring web LOW/HIGH_ELEC_COLOR.
        let t = bucket_fraction(
            material_id - POTENTIAL_MATERIAL_BASE,
            POTENTIAL_BUCKET_COUNT,
        );
        return [t, t, 0.0, 1.0];
    }
    if (CURRENT_MATERIAL_BASE..CURRENT_MATERIAL_BASE + CURRENT_BUCKET_COUNT).contains(&material_id)
    {
        // dark amber -> bright amber, mirroring web LOW/HIGH_CURRENT_COLOR.
        let t = bucket_fraction(material_id - CURRENT_MATERIAL_BASE, CURRENT_BUCKET_COUNT);
        return lerp_rgba([0.18, 0.11, 0.02, 1.0], [1.0, 0.82, 0.16, 1.0], t);
    }
    [1.0, 1.0, 1.0, 1.0]
}

/// Heat-marker color ramp (warm→white-hot) for the temperature overlay, keyed by
/// the `heat_material` bucket ids. Kept distinct so existing call sites/tests are
/// stable; `field_color` delegates to it for the heat range.
pub fn heat_color(material_id: u32) -> [f32; 4] {
    match material_id.checked_sub(HEAT_MATERIAL_BASE) {
        Some(0) => [0.80, 0.20, 0.05, 1.0], // just over threshold — dark red
        Some(1) => [1.00, 0.40, 0.05, 1.0], // hot — orange-red
        Some(2) => [1.00, 0.70, 0.15, 1.0], // very hot — orange
        Some(3) => [1.00, 1.00, 0.65, 1.0], // hottest — yellow-white
        _ => [1.0, 1.0, 1.0, 1.0],
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

/// Buckets an electric potential into `0..POTENTIAL_BUCKET_COUNT` marker ids on
/// the `|v|/POTENTIAL_RAMP` ramp (mirrors the web overlay's `t` scale).
pub fn potential_material(potential: f32) -> u32 {
    POTENTIAL_MATERIAL_BASE + ramp_bucket(potential.abs(), POTENTIAL_RAMP, POTENTIAL_BUCKET_COUNT)
}

/// Buckets an electric current into `0..CURRENT_BUCKET_COUNT` marker ids on the
/// `|v|/CURRENT_RAMP` ramp.
pub fn current_material(current: f32) -> u32 {
    CURRENT_MATERIAL_BASE + ramp_bucket(current.abs(), CURRENT_RAMP, CURRENT_BUCKET_COUNT)
}

/// Maps a magnitude onto `0..bucket_count` via the `magnitude/ramp` fraction
/// (saturating at the top bucket), matching the web reference's `clamp(v/scale)`.
fn ramp_bucket(magnitude: f32, ramp: f32, bucket_count: u32) -> u32 {
    let t = (magnitude / ramp).clamp(0.0, 1.0);
    ((t * bucket_count as f32).floor() as u32).min(bucket_count - 1)
}

/// The [0,1] color-ramp position of a bucket (bucket / (count-1)).
fn bucket_fraction(bucket: u32, bucket_count: u32) -> f32 {
    if bucket_count <= 1 {
        0.0
    } else {
        bucket as f32 / (bucket_count - 1) as f32
    }
}

fn lerp_rgba(a: [f32; 4], b: [f32; 4], t: f32) -> [f32; 4] {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    ]
}

/// Builds the overlay mesh for one `kind` of field in a region, or an empty mesh
/// if the snapshot doesn't carry that field (mask bit clear) or no cell clears
/// its threshold. The Bevy adapter spawns one entity per non-empty overlay.
pub fn overlay_mesh(
    field: &FieldRegionSnapshot,
    kind: FieldOverlayKind,
    voxel_size: f32,
) -> ChunkMeshData {
    match kind {
        FieldOverlayKind::Temperature => {
            temperature_overlay_mesh(field, voxel_size, DEFAULT_HEAT_THRESHOLD_C)
        }
        FieldOverlayKind::ElectricPotential => electric_potential_overlay_mesh(field, voxel_size),
        FieldOverlayKind::ElectricCurrent => electric_current_overlay_mesh(field, voxel_size),
    }
}

/// Builds the temperature heat overlay for a field region: a marker cube at each
/// macro cell whose temperature exceeds `threshold_c`, colored by heat bucket.
/// Cells in the snapshot without temperature data (mask bit clear) produce nothing.
pub fn temperature_overlay_mesh(
    field: &FieldRegionSnapshot,
    voxel_size: f32,
    threshold_c: f32,
) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_TEMPERATURE == 0 {
        return ChunkMeshData::default();
    }
    overlay_from_values(
        &field.macro_indices,
        &field.temperature,
        voxel_size,
        TEMP_MARKER_FRACTION,
        |temp| (temp > threshold_c).then(|| heat_material(temp, threshold_c)),
    )
}

/// Builds the electric-potential overlay: a marker cube at each macro cell whose
/// `|potential| >= POTENTIAL_THRESHOLD`, colored on the black→yellow ramp.
pub fn electric_potential_overlay_mesh(
    field: &FieldRegionSnapshot,
    voxel_size: f32,
) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_ELECTRIC_POTENTIAL == 0 {
        return ChunkMeshData::default();
    }
    overlay_from_values(
        &field.macro_indices,
        &field.electric_potential,
        voxel_size,
        ELECTRIC_MARKER_FRACTION,
        |v| (v.abs() >= POTENTIAL_THRESHOLD).then(|| potential_material(v)),
    )
}

/// Builds the electric-current overlay: a marker cube at each macro cell whose
/// `|current| >= CURRENT_THRESHOLD`, colored on the dark→bright amber ramp.
pub fn electric_current_overlay_mesh(
    field: &FieldRegionSnapshot,
    voxel_size: f32,
) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_ELECTRIC_CURRENT == 0 {
        return ChunkMeshData::default();
    }
    overlay_from_values(
        &field.macro_indices,
        &field.electric_current,
        voxel_size,
        ELECTRIC_MARKER_FRACTION,
        |v| (v.abs() >= CURRENT_THRESHOLD).then(|| current_material(v)),
    )
}

/// Shared overlay core: a centered marker cube per macro cell whose value passes
/// `material_for` (which returns the baked marker material id, or `None` to skip).
fn overlay_from_values(
    macro_indices: &[u16],
    values: &[f32],
    voxel_size: f32,
    marker_fraction: f32,
    material_for: impl Fn(f32) -> Option<u32>,
) -> ChunkMeshData {
    let mut mesh = ChunkMeshData::default();
    let marker = voxel_size * marker_fraction;
    let inset = (voxel_size - marker) * 0.5; // center the marker in the macro cell

    for (i, &macro_index) in macro_indices.iter().enumerate() {
        let Some(&value) = values.get(i) else {
            continue;
        };
        let Some(material_id) = material_for(value) else {
            continue;
        };
        let (mx, my, mz) = macro_coord(macro_index);
        let min = [
            mx as f32 * voxel_size + inset,
            my as f32 * voxel_size + inset,
            mz as f32 * voxel_size + inset,
        ];
        push_cube(&mut mesh, min, marker, material_id);
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

    fn temperature_snapshot(region_id: u64, cells: &[(u16, f32)]) -> FieldRegionSnapshot {
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

    fn electric_snapshot(
        region_id: u64,
        mask: u8,
        cells: &[(u16, f32)],
        as_current: bool,
    ) -> FieldRegionSnapshot {
        let indices: Vec<u16> = cells.iter().map(|(i, _)| *i).collect();
        let values: Vec<f32> = cells.iter().map(|(_, v)| *v).collect();
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id,
            tick_count: 1,
            field_mask: mask,
            macro_indices: indices,
            temperature: vec![],
            electric_potential: if as_current { vec![] } else { values.clone() },
            electric_current: if as_current { values } else { vec![] },
            ionization: vec![],
        }
    }

    #[test]
    fn store_replaces_per_region_and_drops_on_destroy() {
        let mut store = VoxelFieldStore::new();
        store.apply_snapshot(temperature_snapshot(7, &[(0, 100.0)]));
        assert_eq!(store.region_count(), 1);
        assert_eq!(store.take_dirty(), vec![7]); // snapshot marked dirty
        assert!(store.take_dirty().is_empty());

        // Newer snapshot for same region replaces + re-dirties.
        store.apply_snapshot(temperature_snapshot(7, &[(0, 200.0), (1, 50.0)]));
        assert_eq!(store.region(7).unwrap().macro_indices.len(), 2);
        assert_eq!(store.take_dirty(), vec![7]);

        let destroyed = FieldRegionDestroyed {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id: 7,
            destroy_reason: 0,
        };
        assert!(store.apply_destroyed(&destroyed));
        assert_eq!(store.region_count(), 0);
        assert_eq!(store.take_dirty(), vec![7]); // destroy marks dirty (overlay despawns)
        assert!(!store.apply_destroyed(&destroyed)); // already gone
    }

    #[test]
    fn field_color_dispatches_by_reserved_range() {
        // Heat range → warm ramp; potential → black→yellow; current → amber.
        assert_eq!(
            field_color(HEAT_MATERIAL_BASE),
            heat_color(HEAT_MATERIAL_BASE)
        );
        // Potential bucket 0 = black, top bucket = yellow.
        assert_eq!(field_color(POTENTIAL_MATERIAL_BASE), [0.0, 0.0, 0.0, 1.0]);
        assert_eq!(
            field_color(POTENTIAL_MATERIAL_BASE + POTENTIAL_BUCKET_COUNT - 1),
            [1.0, 1.0, 0.0, 1.0]
        );
        // Current top bucket = bright amber.
        assert_eq!(
            field_color(CURRENT_MATERIAL_BASE + CURRENT_BUCKET_COUNT - 1),
            [1.0, 0.82, 0.16, 1.0]
        );
        // Non-field id → white fallback.
        assert_eq!(field_color(5), [1.0, 1.0, 1.0, 1.0]);
    }

    #[test]
    fn heat_color_ramps_warm_to_hot_and_falls_back_white() {
        // Hotter bucket → brighter/whiter (higher green channel here).
        assert!(heat_color(HEAT_MATERIAL_BASE + 3)[1] > heat_color(HEAT_MATERIAL_BASE)[1]);
        // Non-heat id → white fallback.
        assert_eq!(heat_color(5), [1.0, 1.0, 1.0, 1.0]);
    }

    #[test]
    fn overlay_marks_only_cells_above_threshold() {
        // Three cells: 20°C (cold), 100°C, 500°C. Only the two hot ones get a
        // marker cube (6 faces each → 12 quads).
        let field = temperature_snapshot(1, &[(0, 20.0), (5, 100.0), (10, 500.0)]);
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
        let mut field = temperature_snapshot(1, &[(0, 999.0)]);
        field.field_mask = 0; // temperature bit clear
        assert!(temperature_overlay_mesh(&field, 1.0, DEFAULT_HEAT_THRESHOLD_C).is_empty());
    }

    #[test]
    fn marker_cube_is_centered_in_its_macro_cell() {
        // macro index 0 → cell (0,0,0); temp marker is 0.5 of a 100-unit cell,
        // inset 25 → spans [25,75] in each axis (centered).
        let field = temperature_snapshot(1, &[(0, 100.0)]);
        let mesh = temperature_overlay_mesh(&field, 100.0, DEFAULT_HEAT_THRESHOLD_C);
        let s = mesh.summary();
        assert_eq!(s.aabb_min, Some([25.0, 25.0, 25.0]));
        assert_eq!(s.aabb_max, Some([75.0, 75.0, 75.0]));
    }

    #[test]
    fn electric_potential_overlay_thresholds_and_buckets() {
        // Below 0.5 → skipped; 0.5 and 200 → drawn. Two magnitudes far apart land
        // in different potential buckets.
        let field = electric_snapshot(
            1,
            FIELD_MASK_ELECTRIC_POTENTIAL,
            &[(0, 0.1), (5, 0.6), (10, 200.0)],
            false,
        );
        let mesh = electric_potential_overlay_mesh(&field, 100.0);
        let s = mesh.summary();
        assert_eq!(s.quad_count, 12); // two cells × 6 faces
        assert_eq!(s.area_by_material.len(), 2);
        assert!(s.area_by_material.keys().all(|m| {
            (POTENTIAL_MATERIAL_BASE..POTENTIAL_MATERIAL_BASE + POTENTIAL_BUCKET_COUNT).contains(m)
        }));

        // Electric marker uses the 0.85 fraction → a single cell at index 0
        // spans [7.5, 92.5] of a 100-unit cell (centered).
        let one = electric_snapshot(9, FIELD_MASK_ELECTRIC_POTENTIAL, &[(0, 50.0)], false);
        let one_s = electric_potential_overlay_mesh(&one, 100.0).summary();
        assert_eq!(one_s.aabb_min, Some([7.5, 7.5, 7.5]));
        assert_eq!(one_s.aabb_max, Some([92.5, 92.5, 92.5]));
    }

    #[test]
    fn electric_current_overlay_thresholds_on_tiny_currents() {
        // 0.0005 < 0.001 threshold → skipped; 0.5 and 15 → drawn.
        let field = electric_snapshot(
            2,
            FIELD_MASK_ELECTRIC_CURRENT,
            &[(0, 0.0005), (5, 0.5), (10, 15.0)],
            true,
        );
        let mesh = electric_current_overlay_mesh(&field, 100.0);
        let s = mesh.summary();
        assert_eq!(s.quad_count, 12);
        assert!(s.area_by_material.keys().all(|m| {
            (CURRENT_MATERIAL_BASE..CURRENT_MATERIAL_BASE + CURRENT_BUCKET_COUNT).contains(m)
        }));
    }

    #[test]
    fn overlay_mesh_dispatches_by_kind_and_respects_absent_layers() {
        // A potential-only snapshot: Temperature/Current overlays are empty,
        // Potential overlay is populated.
        let field = electric_snapshot(3, FIELD_MASK_ELECTRIC_POTENTIAL, &[(0, 50.0)], false);
        assert!(overlay_mesh(&field, FieldOverlayKind::Temperature, 100.0).is_empty());
        assert!(overlay_mesh(&field, FieldOverlayKind::ElectricCurrent, 100.0).is_empty());
        assert!(!overlay_mesh(&field, FieldOverlayKind::ElectricPotential, 100.0).is_empty());
    }

    #[test]
    fn higher_magnitude_gets_higher_electric_bucket() {
        assert!(potential_material(200.0) > potential_material(10.0));
        assert!(current_material(15.0) > current_material(0.1));
        // Saturate at the top bucket.
        assert_eq!(
            potential_material(10_000.0),
            POTENTIAL_MATERIAL_BASE + POTENTIAL_BUCKET_COUNT - 1
        );
        assert_eq!(
            current_material(10_000.0),
            CURRENT_MATERIAL_BASE + CURRENT_BUCKET_COUNT - 1
        );
    }
}
