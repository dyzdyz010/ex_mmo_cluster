//! Field visualization (C3): consumes the Phase-6 `FieldRegionSnapshot` (0x73)
//! / `FieldRegionDestroyed` (0x74) stream and turns the emergence layer's
//! thermal/electric field truth into a renderable overlay — the FieldView render
//! sub-layer, parallel to ChunkMesh / SurfaceDecal.
//!
//! Design (mirrors the web oracle's `fieldDebugOverlay.ts`, but as assertable
//! geometry rather than InstancedMesh): a field region is keyed by `region_id`
//! (ephemeral; replaced on a newer snapshot, dropped on destroy). Each field
//! type the snapshot carries becomes its own overlay — a marker cube at each
//! macro cell whose value is anomalous, colored on that field's reference ramp
//! with a magnitude-driven alpha (so the Bevy adapter renders them translucent,
//! like the web overlay's see-through debug cells):
//!
//!   * Temperature — hot (red) above / cold (purple) below the ambient baseline
//!     (20°C); opacity ramps with `|deviation|` (saturating at 20°C off baseline),
//!     mirroring the web overlay's hot/cold + opacity-bucket model.
//!   * Electric potential — black→yellow by `|v|/100`, drawn when `|v| >= 0.5`.
//!   * Electric current — dark→bright amber by `|v|/20`, drawn when `|v| >= 0.001`.
//!
//! The thresholds / ramps mirror the web reference 1:1 so the two clients agree
//! on which cells light up and how. Pure data (no Bevy) → Layer-1 geometry +
//! color/bucket assertable; the Bevy adapter spawns each overlay as an entity.
//!
//! Only reads committed field truth (no fabrication) — same authority discipline
//! as the chunk store.

use crate::voxel::mesher::{ChunkMeshData, push_cube};
use crate::voxel::wire::{
    FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_ELECTRIC_POTENTIAL, FIELD_MASK_IONIZATION,
    FIELD_MASK_LIGHT, FIELD_MASK_LIGHT_COLOR, FIELD_MASK_TEMPERATURE, FieldRegionDestroyed,
    FieldRegionSnapshot,
};
use std::collections::{HashMap, HashSet};

/// Temperature marker ids, split hot/cold (a reserved range above real
/// `MaterialCatalog` ids, so the FieldView palette never collides with
/// block/decal materials). The bucket within each range is the opacity bucket;
/// `field_color` maps hot→red / cold→purple with that bucket's alpha.
pub const HEAT_MATERIAL_BASE: u32 = 10_000;
pub const COLD_MATERIAL_BASE: u32 = 10_010;
pub const TEMP_OPACITY_BUCKET_COUNT: u32 = 5;

/// Electric-potential marker ids (black→yellow ramp), and electric-current ids
/// (dark→bright amber). Disjoint reserved ranges so `field_color` can dispatch
/// the right ramp purely from the baked material id.
pub const POTENTIAL_MATERIAL_BASE: u32 = 10_100;
pub const POTENTIAL_BUCKET_COUNT: u32 = 8;
pub const CURRENT_MATERIAL_BASE: u32 = 10_200;
pub const CURRENT_BUCKET_COUNT: u32 = 8;
/// Ionization marker ids (dark-blue → bright-cyan plasma ramp). Ionization is the
/// breakdown-conditioning / discharge-channel field (wire u8 0..255); neither
/// client mirrored it before, so this is a new overlay (plasma glow along
/// conditioned channels), complementing the discharge/lightning visuals.
pub const IONIZATION_MATERIAL_BASE: u32 = 10_300;
pub const IONIZATION_BUCKET_COUNT: u32 = 8;
/// Light marker ids (dark-amber → warm-white ramp). The authoritative light field
/// (emergent optics, wire u8 0..255 from the server `LightPropagationKernel`):
/// illuminated cells glow warm-white proportional to light level. Base 10_500 keeps
/// it disjoint from the client-side incandescence palette (10_400).
pub const LIGHT_MATERIAL_BASE: u32 = 10_500;
pub const LIGHT_BUCKET_COUNT: u32 = 8;
const LIGHT_THRESHOLD: f32 = 8.0;
const LIGHT_RAMP: f32 = 255.0;
const LIGHT_ALPHA: f32 = 0.5;
/// Colored-light marker base: `LIGHT_COLOR_PACKED_BASE + packed_rgb888` is baked
/// as the per-vertex material id (u32, exact) for the authoritative colored light
/// field; `field_color` detects this range and unpacks the RGB. 0x0100_0000 (16M)
/// sits far above every reserved field marker range, so no collision.
pub const LIGHT_COLOR_PACKED_BASE: u32 = 0x0100_0000;

/// Temperature overlay model (mirrors web `fieldDebugOverlay`): cells are colored
/// by their deviation from the ambient baseline; below `TEMP_MIN_DEVIATION` off
/// baseline is "no anomaly" and not drawn. Opacity ramps with `|deviation|` under
/// a gamma curve, saturating `TEMP_FULL_OPACITY_DELTA` (°C) off baseline.
pub const TEMP_BASELINE_C: f32 = 20.0;
pub const TEMP_MIN_DEVIATION: f32 = 0.0001;
const TEMP_FULL_OPACITY_DELTA: f32 = 20.0;
const TEMP_VISUAL_GAMMA: f32 = 0.25;
const TEMP_MAX_OPACITY: f32 = 0.62;
/// The five opacity buckets (web `TEMP_OPACITY_BUCKETS`); a marker's `|deviation|`
/// snaps to the nearest. Indexed by the bucket id within the hot/cold ranges.
const TEMP_OPACITY_BUCKETS: [f32; 5] = [0.08, 0.16, 0.28, 0.42, TEMP_MAX_OPACITY];

/// Constant overlay alphas for the electric layers (web overlay material opacity):
/// potential cells at 0.42, current at 0.5. Color encodes magnitude; alpha is flat.
const POTENTIAL_ALPHA: f32 = 0.42;
const CURRENT_ALPHA: f32 = 0.5;

/// Electric thresholds + ramp scales, mirrored from the web `fieldDebugOverlay`:
/// potential below 0.5 (and current below 0.001) is noise and not drawn; the
/// color saturates at `|v| >= *_RAMP`.
pub const POTENTIAL_THRESHOLD: f32 = 0.5;
pub const POTENTIAL_RAMP: f32 = 100.0;
pub const CURRENT_THRESHOLD: f32 = 0.001;
pub const CURRENT_RAMP: f32 = 20.0;

/// Ionization (u8 0..255): below `IONIZATION_THRESHOLD` is background noise and
/// not drawn; the plasma color saturates at `IONIZATION_RAMP` (full scale).
const IONIZATION_THRESHOLD: f32 = 8.0;
const IONIZATION_RAMP: f32 = 255.0;
const IONIZATION_ALPHA: f32 = 0.5;

/// Marker cube edge as a fraction of a macro cell (centered in the cell). The web
/// overlay draws field cells at 0.85 of the cell; all FieldView overlays match.
const MARKER_FRACTION: f32 = 0.85;

/// The field types the FieldView renders, one overlay entity per (region, kind).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FieldOverlayKind {
    Temperature,
    ElectricPotential,
    ElectricCurrent,
    Ionization,
    Light,
}

impl FieldOverlayKind {
    /// All kinds, in a stable order (so the render adapter iterates deterministically).
    pub const ALL: [FieldOverlayKind; 5] = [
        FieldOverlayKind::Temperature,
        FieldOverlayKind::ElectricPotential,
        FieldOverlayKind::ElectricCurrent,
        FieldOverlayKind::Ionization,
        FieldOverlayKind::Light,
    ];

    /// A stable small id for keying render entities by (region_id, kind).
    pub fn ordinal(self) -> u8 {
        match self {
            FieldOverlayKind::Temperature => 0,
            FieldOverlayKind::ElectricPotential => 1,
            FieldOverlayKind::ElectricCurrent => 2,
            FieldOverlayKind::Ionization => 3,
            FieldOverlayKind::Light => 4,
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
    // Parallel dirty channel for the incandescence (emergent-optics) render layer.
    // The overlay render `take_dirty`-drains `dirty`, so a second consumer can't
    // share it (mem::take contention — same lesson as discharge/heat_smoke); the
    // incandescence layer drains this instead. Marked alongside `dirty`.
    incandescence_dirty: HashSet<u64>,
}

impl VoxelFieldStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores (replaces) the field region's latest snapshot; marks it dirty on
    /// both the overlay and incandescence channels.
    pub fn apply_snapshot(&mut self, snapshot: FieldRegionSnapshot) {
        let region_id = snapshot.region_id;
        self.regions.insert(region_id, snapshot);
        self.dirty.insert(region_id);
        self.incandescence_dirty.insert(region_id);
    }

    /// Drops a destroyed field region (marks dirty on both channels so the overlay
    /// AND the incandescence glow despawn). Returns whether a region was removed.
    pub fn apply_destroyed(&mut self, destroyed: &FieldRegionDestroyed) -> bool {
        self.dirty.insert(destroyed.region_id);
        self.incandescence_dirty.insert(destroyed.region_id);
        self.regions.remove(&destroyed.region_id).is_some()
    }

    pub fn region(&self, region_id: u64) -> Option<&FieldRegionSnapshot> {
        self.regions.get(&region_id)
    }

    /// 光可见度 Phase A:dense block-light grid (u8 0..255 per macro cell) for a
    /// chunk, **max-combined** over every retained `:light` region stamped with
    /// `chunk_coord`, or `None` if no light region covers it. The wire `macro_index`
    /// equals the chunk cell flat index (both `x + y*16 + z*256`), so the returned
    /// `Vec<u8>` of length 4096 is directly cell-indexable. Block light combines
    /// with skylight by `max` (either illuminant lights a cell) at bake time.
    pub fn block_light_grid(&self, chunk_coord: [i32; 3]) -> Option<Vec<u8>> {
        const CELLS: usize = 16 * 16 * 16;
        let mut grid: Option<Vec<u8>> = None;
        for region in self.regions.values() {
            if region.chunk_coord != chunk_coord || region.field_mask & FIELD_MASK_LIGHT == 0 {
                continue;
            }
            let g = grid.get_or_insert_with(|| vec![0u8; CELLS]);
            for (i, &macro_index) in region.macro_indices.iter().enumerate() {
                if let Some(&level) = region.light.get(i) {
                    let idx = macro_index as usize;
                    if idx < CELLS {
                        g[idx] = g[idx].max(level);
                    }
                }
            }
        }
        grid
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

    /// Drains regions touched since the last call on the incandescence channel —
    /// the emergent-optics glow layer rebuilds exactly these. Disjoint from
    /// `take_dirty` so the two render layers never contend.
    pub fn take_incandescence_dirty(&mut self) -> Vec<u64> {
        let mut dirty: Vec<u64> = self.incandescence_dirty.drain().collect();
        dirty.sort_unstable();
        dirty
    }
}

/// Unified FieldView color ramp (RGBA, alpha meaningful), keyed by the reserved
/// marker material ids the overlay meshers bake. Dispatches by reserved range so
/// the Bevy adapter bakes per-vertex colors without knowing which field produced
/// a quad. Non-field ids fall back to opaque white.
pub fn field_color(material_id: u32) -> [f32; 4] {
    // Colored light: a packed RGB888 baked above LIGHT_COLOR_PACKED_BASE → unpack.
    if material_id >= LIGHT_COLOR_PACKED_BASE {
        let packed = material_id - LIGHT_COLOR_PACKED_BASE;
        return [
            ((packed >> 16) & 0xFF) as f32 / 255.0,
            ((packed >> 8) & 0xFF) as f32 / 255.0,
            (packed & 0xFF) as f32 / 255.0,
            LIGHT_ALPHA,
        ];
    }
    if let Some(color) = temperature_color(material_id) {
        return color;
    }
    if (POTENTIAL_MATERIAL_BASE..POTENTIAL_MATERIAL_BASE + POTENTIAL_BUCKET_COUNT)
        .contains(&material_id)
    {
        // black (low) -> yellow (high), mirroring web LOW/HIGH_ELEC_COLOR.
        let t = bucket_fraction(
            material_id - POTENTIAL_MATERIAL_BASE,
            POTENTIAL_BUCKET_COUNT,
        );
        return [t, t, 0.0, POTENTIAL_ALPHA];
    }
    if (CURRENT_MATERIAL_BASE..CURRENT_MATERIAL_BASE + CURRENT_BUCKET_COUNT).contains(&material_id)
    {
        // dark amber -> bright amber, mirroring web LOW/HIGH_CURRENT_COLOR.
        let t = bucket_fraction(material_id - CURRENT_MATERIAL_BASE, CURRENT_BUCKET_COUNT);
        return lerp_rgb([0.18, 0.11, 0.02], [1.0, 0.82, 0.16], t, CURRENT_ALPHA);
    }
    if (IONIZATION_MATERIAL_BASE..IONIZATION_MATERIAL_BASE + IONIZATION_BUCKET_COUNT)
        .contains(&material_id)
    {
        // deep blue (low) -> bright cyan (high): a plasma/ionization glow.
        let t = bucket_fraction(
            material_id - IONIZATION_MATERIAL_BASE,
            IONIZATION_BUCKET_COUNT,
        );
        return lerp_rgb([0.0, 0.10, 0.35], [0.35, 0.95, 1.0], t, IONIZATION_ALPHA);
    }
    if (LIGHT_MATERIAL_BASE..LIGHT_MATERIAL_BASE + LIGHT_BUCKET_COUNT).contains(&material_id) {
        // dark-amber (dim) -> warm-white (bright): the authoritative light field.
        let t = bucket_fraction(material_id - LIGHT_MATERIAL_BASE, LIGHT_BUCKET_COUNT);
        return lerp_rgb([0.15, 0.12, 0.05], [1.0, 0.95, 0.70], t, LIGHT_ALPHA);
    }
    [1.0, 1.0, 1.0, 1.0]
}

/// Temperature marker color: hot (red) / cold (purple) base color with the
/// bucket's opacity baked into alpha. Returns `None` for non-temperature ids so
/// `field_color` can fall through to the electric ranges.
fn temperature_color(material_id: u32) -> Option<[f32; 4]> {
    if let Some(bucket) = material_id
        .checked_sub(HEAT_MATERIAL_BASE)
        .filter(|b| *b < TEMP_OPACITY_BUCKET_COUNT)
    {
        return Some([1.0, 0.0, 0.0, TEMP_OPACITY_BUCKETS[bucket as usize]]);
    }
    if let Some(bucket) = material_id
        .checked_sub(COLD_MATERIAL_BASE)
        .filter(|b| *b < TEMP_OPACITY_BUCKET_COUNT)
    {
        return Some([0.55, 0.0, 1.0, TEMP_OPACITY_BUCKETS[bucket as usize]]);
    }
    None
}

/// Maps a temperature (°C) to its hot/cold marker id, or `None` if the cell is at
/// the ambient baseline (no anomaly to draw). Hot (>= baseline) lands in the heat
/// range, cold in the cold range; the bucket is the opacity bucket for `|dev|`.
pub fn temperature_marker(temperature_c: f32) -> Option<u32> {
    let deviation = temperature_c - TEMP_BASELINE_C;
    if deviation.abs() < TEMP_MIN_DEVIATION {
        return None;
    }
    let bucket = temperature_opacity_bucket(deviation.abs());
    let base = if deviation >= 0.0 {
        HEAT_MATERIAL_BASE
    } else {
        COLD_MATERIAL_BASE
    };
    Some(base + bucket)
}

/// Snaps `|deviation|` to the nearest opacity bucket index (`0..5`), under the web
/// overlay's gamma curve: `opacity = (|dev|/full)^gamma * max`, nearest bucket.
fn temperature_opacity_bucket(abs_deviation: f32) -> u32 {
    let linear = (abs_deviation / TEMP_FULL_OPACITY_DELTA).clamp(0.0, 1.0);
    let target = linear.powf(TEMP_VISUAL_GAMMA) * TEMP_MAX_OPACITY;
    let mut best = 0u32;
    let mut best_dist = f32::INFINITY;
    for (i, &opacity) in TEMP_OPACITY_BUCKETS.iter().enumerate() {
        let dist = (opacity - target).abs();
        if dist < best_dist {
            best_dist = dist;
            best = i as u32;
        }
    }
    best
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

/// Maps an ionization value (u8 0..255, passed as f32) to its marker id, or `None`
/// below the noise threshold. Bucketed on the `value/255` plasma ramp.
pub fn ionization_material(value: f32) -> Option<u32> {
    if value < IONIZATION_THRESHOLD {
        return None;
    }
    Some(IONIZATION_MATERIAL_BASE + ramp_bucket(value, IONIZATION_RAMP, IONIZATION_BUCKET_COUNT))
}

/// Maps a light value (u8 0..255, passed as f32) to its marker id, or `None` below
/// the dim-noise threshold. Bucketed on the `value/255` warm-white ramp.
pub fn light_material(value: f32) -> Option<u32> {
    if value < LIGHT_THRESHOLD {
        return None;
    }
    Some(LIGHT_MATERIAL_BASE + ramp_bucket(value, LIGHT_RAMP, LIGHT_BUCKET_COUNT))
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

/// Lerps an RGB pair by `t` and tacks on a fixed `alpha`.
fn lerp_rgb(a: [f32; 3], b: [f32; 3], t: f32, alpha: f32) -> [f32; 4] {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        alpha,
    ]
}

/// Builds the overlay mesh for one `kind` of field in a region, or an empty mesh
/// if the snapshot doesn't carry that field (mask bit clear) or no cell is
/// anomalous. The Bevy adapter spawns one entity per non-empty overlay.
pub fn overlay_mesh(
    field: &FieldRegionSnapshot,
    kind: FieldOverlayKind,
    voxel_size: f32,
) -> ChunkMeshData {
    match kind {
        FieldOverlayKind::Temperature => temperature_overlay_mesh(field, voxel_size),
        FieldOverlayKind::ElectricPotential => electric_potential_overlay_mesh(field, voxel_size),
        FieldOverlayKind::ElectricCurrent => electric_current_overlay_mesh(field, voxel_size),
        FieldOverlayKind::Ionization => ionization_overlay_mesh(field, voxel_size),
        FieldOverlayKind::Light => light_overlay_mesh(field, voxel_size),
    }
}

/// Builds the ionization overlay: a marker cube at each macro cell whose
/// ionization (u8 0..255) clears the noise threshold, on the blue→cyan plasma
/// ramp. Cells without an ionization layer (mask bit clear) produce nothing.
pub fn ionization_overlay_mesh(field: &FieldRegionSnapshot, voxel_size: f32) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_IONIZATION == 0 {
        return ChunkMeshData::default();
    }
    // `ionization` is u8 on the wire; widen to f32 for the shared overlay core.
    let values: Vec<f32> = field.ionization.iter().map(|&v| v as f32).collect();
    overlay_from_values(
        &field.macro_indices,
        &values,
        voxel_size,
        ionization_material,
    )
}

/// Builds the light overlay: a marker cube at each macro cell whose authoritative
/// light level (u8 0..255) clears the dim-noise threshold, on the dark-amber →
/// warm-white ramp. Cells without a light layer (mask bit clear) produce nothing.
pub fn light_overlay_mesh(field: &FieldRegionSnapshot, voxel_size: f32) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_LIGHT == 0 {
        return ChunkMeshData::default();
    }
    // Colored path: when the authoritative light_color layer is present, bake the
    // per-cell RGB (gated by intensity ≥ threshold) so the overlay shows the actual
    // light color (warm ember vs cool glowstone). Falls back to the warm-white
    // intensity ramp when no color layer (older streams / intensity-only regions).
    if field.field_mask & FIELD_MASK_LIGHT_COLOR != 0
        && field.light_color.len() == field.light.len()
    {
        let mut mesh = ChunkMeshData::default();
        let marker = voxel_size * MARKER_FRACTION;
        let inset = (voxel_size - marker) * 0.5;
        for (i, &macro_index) in field.macro_indices.iter().enumerate() {
            let Some(&intensity) = field.light.get(i) else {
                continue;
            };
            if (intensity as f32) < LIGHT_THRESHOLD {
                continue;
            }
            let packed = field.light_color.get(i).copied().unwrap_or(0xFFFFFF) & 0xFF_FFFF;
            let (mx, my, mz) = macro_coord(macro_index);
            let min = [
                mx as f32 * voxel_size + inset,
                my as f32 * voxel_size + inset,
                mz as f32 * voxel_size + inset,
            ];
            push_cube(&mut mesh, min, marker, LIGHT_COLOR_PACKED_BASE + packed);
        }
        return mesh;
    }
    // `light` is u8 on the wire; widen to f32 for the shared overlay core.
    let values: Vec<f32> = field.light.iter().map(|&v| v as f32).collect();
    overlay_from_values(&field.macro_indices, &values, voxel_size, light_material)
}

/// Builds the temperature overlay for a field region: a marker cube at each macro
/// cell whose temperature deviates from the ambient baseline, colored hot/cold by
/// the deviation's sign and bucketed by its magnitude. Cells in the snapshot
/// without temperature data (mask bit clear) produce nothing.
pub fn temperature_overlay_mesh(field: &FieldRegionSnapshot, voxel_size: f32) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_TEMPERATURE == 0 {
        return ChunkMeshData::default();
    }
    overlay_from_values(
        &field.macro_indices,
        &field.temperature,
        voxel_size,
        temperature_marker,
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
        |v| (v.abs() >= CURRENT_THRESHOLD).then(|| current_material(v)),
    )
}

/// Shared overlay core: a centered marker cube per macro cell whose value passes
/// `material_for` (which returns the baked marker material id, or `None` to skip).
/// `pub(crate)` so the incandescence layer reuses the exact same per-cell marker
/// geometry with its own blackbody marker fn.
pub(crate) fn overlay_from_values(
    macro_indices: &[u16],
    values: &[f32],
    voxel_size: f32,
    material_for: impl Fn(f32) -> Option<u32>,
) -> ChunkMeshData {
    let mut mesh = ChunkMeshData::default();
    let marker = voxel_size * MARKER_FRACTION;
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
            light: vec![],
            light_color: vec![],
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
            light: vec![],
            light_color: vec![],
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
    fn field_color_dispatches_by_reserved_range_with_alpha() {
        // Temperature: hot = red, cold = purple, alpha = bucket opacity.
        let hot = field_color(HEAT_MATERIAL_BASE);
        assert_eq!([hot[0], hot[1], hot[2]], [1.0, 0.0, 0.0]);
        assert_eq!(hot[3], TEMP_OPACITY_BUCKETS[0]);
        let cold = field_color(COLD_MATERIAL_BASE + 4);
        assert_eq!([cold[0], cold[1], cold[2]], [0.55, 0.0, 1.0]);
        assert_eq!(cold[3], TEMP_OPACITY_BUCKETS[4]);
        // Potential bucket 0 = black, top bucket = yellow, alpha 0.42.
        assert_eq!(
            field_color(POTENTIAL_MATERIAL_BASE),
            [0.0, 0.0, 0.0, POTENTIAL_ALPHA]
        );
        assert_eq!(
            field_color(POTENTIAL_MATERIAL_BASE + POTENTIAL_BUCKET_COUNT - 1),
            [1.0, 1.0, 0.0, POTENTIAL_ALPHA]
        );
        // Current top bucket = bright amber, alpha 0.5.
        assert_eq!(
            field_color(CURRENT_MATERIAL_BASE + CURRENT_BUCKET_COUNT - 1),
            [1.0, 0.82, 0.16, CURRENT_ALPHA]
        );
        // Non-field id → opaque white fallback.
        assert_eq!(field_color(5), [1.0, 1.0, 1.0, 1.0]);
    }

    #[test]
    fn temperature_marker_splits_hot_cold_and_skips_baseline() {
        // At baseline → no marker.
        assert_eq!(temperature_marker(TEMP_BASELINE_C), None);
        // Above baseline → heat range; below → cold range.
        let hot = temperature_marker(300.0).unwrap();
        assert!(
            (HEAT_MATERIAL_BASE..HEAT_MATERIAL_BASE + TEMP_OPACITY_BUCKET_COUNT).contains(&hot)
        );
        let cold = temperature_marker(5.0).unwrap();
        assert!(
            (COLD_MATERIAL_BASE..COLD_MATERIAL_BASE + TEMP_OPACITY_BUCKET_COUNT).contains(&cold)
        );
        // A larger deviation → higher (or equal) opacity bucket.
        let mild = temperature_marker(25.0).unwrap() - HEAT_MATERIAL_BASE;
        let strong = temperature_marker(60.0).unwrap() - HEAT_MATERIAL_BASE;
        assert!(strong >= mild);
        // Far off baseline saturates at the top opacity bucket.
        assert_eq!(
            temperature_marker(10_000.0),
            Some(HEAT_MATERIAL_BASE + TEMP_OPACITY_BUCKET_COUNT - 1)
        );
    }

    #[test]
    fn overlay_draws_hot_and_cold_anomalies_skips_baseline() {
        // 20°C (baseline → skip), 100°C (hot), 5°C (cold). Two markers → 12 quads,
        // one in the heat range and one in the cold range.
        let field = temperature_snapshot(1, &[(0, 20.0), (5, 100.0), (10, 5.0)]);
        let mesh = temperature_overlay_mesh(&field, 1.0);
        let s = mesh.summary();
        assert_eq!(s.quad_count, 12);
        assert!(s.structural_ok);
        let mats: Vec<u32> = s.area_by_material.keys().copied().collect();
        assert!(mats.iter().any(|m| {
            (HEAT_MATERIAL_BASE..HEAT_MATERIAL_BASE + TEMP_OPACITY_BUCKET_COUNT).contains(m)
        }));
        assert!(mats.iter().any(|m| {
            (COLD_MATERIAL_BASE..COLD_MATERIAL_BASE + TEMP_OPACITY_BUCKET_COUNT).contains(m)
        }));
    }

    #[test]
    fn no_temperature_data_no_overlay() {
        let mut field = temperature_snapshot(1, &[(0, 999.0)]);
        field.field_mask = 0; // temperature bit clear
        assert!(temperature_overlay_mesh(&field, 1.0).is_empty());
    }

    #[test]
    fn marker_cube_is_centered_in_its_macro_cell() {
        // macro index 0 → cell (0,0,0); marker is 0.85 of a 100-unit cell, inset
        // 7.5 → spans [7.5, 92.5] in each axis (centered).
        let field = temperature_snapshot(1, &[(0, 100.0)]);
        let mesh = temperature_overlay_mesh(&field, 100.0);
        let s = mesh.summary();
        assert_eq!(s.aabb_min, Some([7.5, 7.5, 7.5]));
        assert_eq!(s.aabb_max, Some([92.5, 92.5, 92.5]));
    }

    #[test]
    fn electric_potential_overlay_thresholds_and_buckets() {
        // Below 0.5 → skipped; 0.6 and 200 → drawn. Two magnitudes far apart land
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

    #[test]
    fn ionization_overlay_thresholds_buckets_and_plasma_color() {
        // Below threshold (8) skipped; mid + full drawn into distinct buckets.
        assert_eq!(ionization_material(2.0), None);
        let mid = ionization_material(120.0).unwrap();
        let full = ionization_material(255.0).unwrap();
        assert!(
            (IONIZATION_MATERIAL_BASE..IONIZATION_MATERIAL_BASE + IONIZATION_BUCKET_COUNT)
                .contains(&mid)
        );
        assert!(full > mid); // higher ionization → higher bucket
        assert_eq!(full, IONIZATION_MATERIAL_BASE + IONIZATION_BUCKET_COUNT - 1);

        // Plasma color: blue→cyan, so blue & green dominate red.
        let c = field_color(full);
        assert!(
            c[2] > c[0] && c[1] > c[0],
            "ionization should be blue/cyan; got {c:?}"
        );

        // Overlay mesher: an ionization snapshot draws markers in the ion range.
        let field = FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id: 1,
            tick_count: 1,
            field_mask: FIELD_MASK_IONIZATION,
            macro_indices: vec![0, 5],
            temperature: vec![],
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![2, 200], // first below threshold, second drawn
            light: vec![],
            light_color: vec![],
        };
        let s = ionization_overlay_mesh(&field, 100.0).summary();
        assert_eq!(s.quad_count, 6); // only the 200-ion cell → one marker cube
        assert!(s.area_by_material.keys().all(|m| {
            (IONIZATION_MATERIAL_BASE..IONIZATION_MATERIAL_BASE + IONIZATION_BUCKET_COUNT)
                .contains(m)
        }));
        // Temperature-only / mask clear → no ionization overlay.
        let mut bare = field.clone();
        bare.field_mask = 0;
        assert!(ionization_overlay_mesh(&bare, 100.0).is_empty());
    }

    #[test]
    fn light_overlay_is_warm_white_and_thresholds() {
        // Light color ramp is warm-white (all channels lift, no single cool channel
        // dominates as in ionization). A bright bucket reads warm (R highest).
        let bright = field_color(LIGHT_MATERIAL_BASE + LIGHT_BUCKET_COUNT - 1);
        assert!(
            bright[0] >= bright[2] && bright[1] >= bright[2] && bright[0] > 0.7,
            "bright light should be warm-white (R,G ≥ B, R high); got {bright:?}"
        );

        // light_material: below threshold → None; above → in the light range.
        assert_eq!(light_material(2.0), None);
        let m = light_material(200.0).unwrap();
        assert!((LIGHT_MATERIAL_BASE..LIGHT_MATERIAL_BASE + LIGHT_BUCKET_COUNT).contains(&m));

        // Overlay mesher: a light snapshot draws markers only for above-threshold cells.
        let field = FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id: 1,
            tick_count: 1,
            field_mask: FIELD_MASK_LIGHT,
            macro_indices: vec![0, 5],
            temperature: vec![],
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![],
            light: vec![1, 255], // first below threshold, second drawn
            light_color: vec![],
        };
        let s = light_overlay_mesh(&field, 100.0).summary();
        assert_eq!(s.quad_count, 6); // only the bright cell → one marker cube
        assert!(
            s.area_by_material.keys().all(|m| (LIGHT_MATERIAL_BASE
                ..LIGHT_MATERIAL_BASE + LIGHT_BUCKET_COUNT)
                .contains(m))
        );
        // mask clear → no light overlay.
        let mut bare = field.clone();
        bare.field_mask = 0;
        assert!(light_overlay_mesh(&bare, 100.0).is_empty());
    }

    #[test]
    fn block_light_grid_max_combines_light_regions() {
        let light_region = |region_id, macro_indices: Vec<u16>, light: Vec<u8>| FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id,
            tick_count: 1,
            field_mask: FIELD_MASK_LIGHT,
            macro_indices,
            temperature: vec![],
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![],
            light,
            light_color: vec![],
        };

        let mut store = VoxelFieldStore::new();
        // No light region for the chunk → None.
        assert!(store.block_light_grid([0, 0, 0]).is_none());

        // Region 1: cells 0→100, 5→200.
        store.apply_snapshot(light_region(1, vec![0, 5], vec![100, 200]));
        // Region 2 (same chunk): cells 5→250, 9→50 → max-combine at 5.
        store.apply_snapshot(light_region(2, vec![5, 9], vec![250, 50]));

        let grid = store.block_light_grid([0, 0, 0]).expect("light present");
        assert_eq!(grid.len(), 4096);
        assert_eq!(grid[0], 100);
        assert_eq!(grid[5], 250, "max(200, 250)");
        assert_eq!(grid[9], 50);
        assert_eq!(grid[1], 0, "untouched cell stays dark");

        // A different chunk is unaffected.
        assert!(store.block_light_grid([1, 0, 0]).is_none());

        // A temperature-only region produces no block-light grid.
        let mut store2 = VoxelFieldStore::new();
        let mut temp = light_region(3, vec![0], vec![]);
        temp.field_mask = FIELD_MASK_TEMPERATURE;
        temp.temperature = vec![100.0];
        store2.apply_snapshot(temp);
        assert!(store2.block_light_grid([0, 0, 0]).is_none());
    }

    #[test]
    fn colored_light_overlay_bakes_per_cell_rgb() {
        // field_color unpacks a packed-RGB marker into its exact channels.
        let warm = field_color(LIGHT_COLOR_PACKED_BASE + 0xFFA040);
        assert!((warm[0] - 1.0).abs() < 1e-3); // R = 0xFF
        assert!((warm[1] - 0xA0 as f32 / 255.0).abs() < 1e-3); // G = 0xA0
        assert!((warm[2] - 0x40 as f32 / 255.0).abs() < 1e-3); // B = 0x40
        assert!(warm[0] > warm[2], "ember light is warm (R > B)");
        let cool = field_color(LIGHT_COLOR_PACKED_BASE + 0x60A0FF);
        assert!(cool[2] > cool[0], "glowstone light is cool (B > R)");

        // Colored overlay path: intensity-gated, baked with the packed color marker.
        let field = FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id: 1,
            tick_count: 1,
            field_mask: FIELD_MASK_LIGHT | FIELD_MASK_LIGHT_COLOR,
            macro_indices: vec![0, 5],
            temperature: vec![],
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![],
            light: vec![1, 255], // first below threshold, second drawn
            light_color: vec![0xFFA040, 0x60A0FF], // warm, cool
        };
        let mesh = light_overlay_mesh(&field, 100.0);
        let summary = mesh.summary();
        assert_eq!(summary.quad_count, 6); // only the bright cell → one cube
        // The drawn cell's marker is the packed cool color (cell 5, light 255).
        assert!(
            summary
                .area_by_material
                .keys()
                .all(|&m| m == LIGHT_COLOR_PACKED_BASE + 0x60A0FF)
        );
    }
}
