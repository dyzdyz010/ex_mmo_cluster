//! Emergent optics — thermal incandescence (increment 1).
//!
//! Light is DERIVED from physical truth, not authored per material: any cell whose
//! temperature clears the Draper point (~525 °C, where solids start to visibly
//! glow) emits a blackbody glow whose hue + brightness climb with temperature
//! (dull red → orange → yellow → white). So heated iron, molten iron, lava,
//! embers, burning wood, and Joule-heated power blocks all glow *because they are
//! hot* — zero per-material authoring. This is the principled version of "things
//! that light up": glow emerges from the temperature field the server already
//! streams (0x73), purely client-side.
//!
//! Pure data here (no Bevy): the Draper threshold, the blackbody ramp, the bucket
//! mapping, and the per-cell glow mesh are all Layer-1 assertable. The Bevy
//! adapter (`incandescence_render`) bakes these colors into an additive-emissive
//! mesh per temperature region.

use crate::voxel::field_view::overlay_from_values;
use crate::voxel::mesher::ChunkMeshData;
use crate::voxel::wire::{FIELD_MASK_TEMPERATURE, FieldRegionSnapshot};

/// Draper point: solids begin to emit visible (dull red) light around here. Below
/// this a cell is dark (no incandescence).
pub const DRAPER_C: f32 = 525.0;
/// Temperature at which the glow saturates to white-hot (the ramp's top anchor).
pub const WHITE_HOT_C: f32 = 2200.0;
/// Discrete glow levels between Draper and white-hot (12 → visually smooth).
pub const INCANDESCENCE_BUCKET_COUNT: u32 = 12;
/// Reserved marker-id base for incandescence buckets (disjoint from the field
/// overlay ranges: heat 10000 / cold 10010 / potential 10100 / current 10200 /
/// ionization 10300 — incandescence takes 10400).
pub const INCANDESCENCE_MATERIAL_BASE: u32 = 10_400;

/// Blackbody anchor colors (sRGB-ish), low→high temperature. Lerped between by the
/// normalized temperature `t` in `[0, 1]` (0 = Draper, 1 = white-hot). RGB
/// magnitude doubles as brightness (an additive blend makes hotter = brighter).
const BLACKBODY_ANCHORS: [[f32; 3]; 6] = [
    [0.30, 0.02, 0.0],   // ~Draper: dim dark red
    [0.85, 0.12, 0.0],   // red
    [1.0, 0.36, 0.05],   // orange-red
    [1.0, 0.60, 0.20],   // orange
    [1.0, 0.82, 0.55],   // yellow-white
    [1.0, 0.96, 0.88],   // white-hot
];

/// Blackbody glow color for a temperature, or `None` if below the Draper point
/// (the cell is not visibly glowing). The hue + brightness climb monotonically
/// from dim dark red toward white as the temperature rises.
pub fn blackbody_color(temp_c: f32) -> Option<[f32; 3]> {
    if !temp_c.is_finite() || temp_c < DRAPER_C {
        return None;
    }
    let t = ((temp_c - DRAPER_C) / (WHITE_HOT_C - DRAPER_C)).clamp(0.0, 1.0);
    Some(blackbody_ramp(t))
}

/// Samples the blackbody anchor ramp at `t` in `[0, 1]` (piecewise-linear).
fn blackbody_ramp(t: f32) -> [f32; 3] {
    let segments = (BLACKBODY_ANCHORS.len() - 1) as f32;
    let scaled = (t.clamp(0.0, 1.0) * segments).min(segments - 0.000_001);
    let i = scaled.floor() as usize;
    let frac = scaled - i as f32;
    let a = BLACKBODY_ANCHORS[i];
    let b = BLACKBODY_ANCHORS[i + 1];
    [
        a[0] + (b[0] - a[0]) * frac,
        a[1] + (b[1] - a[1]) * frac,
        a[2] + (b[2] - a[2]) * frac,
    ]
}

/// Maps a temperature to its incandescence marker id (Draper..white-hot bucketed),
/// or `None` below the Draper point (dark, not drawn).
pub fn incandescence_material(temp_c: f32) -> Option<u32> {
    if !temp_c.is_finite() || temp_c < DRAPER_C {
        return None;
    }
    let t = ((temp_c - DRAPER_C) / (WHITE_HOT_C - DRAPER_C)).clamp(0.0, 1.0);
    let bucket = ((t * INCANDESCENCE_BUCKET_COUNT as f32) as u32).min(INCANDESCENCE_BUCKET_COUNT - 1);
    Some(INCANDESCENCE_MATERIAL_BASE + bucket)
}

/// Marker id → blackbody glow color (RGBA; alpha 1.0 — the additive material uses
/// RGB magnitude as brightness). Non-incandescence ids fall back to black (no
/// glow contribution under additive blend).
pub fn incandescence_color(material_id: u32) -> [f32; 4] {
    match material_id.checked_sub(INCANDESCENCE_MATERIAL_BASE) {
        Some(bucket) if bucket < INCANDESCENCE_BUCKET_COUNT => {
            // Bucket center → representative t → blackbody color.
            let t = (bucket as f32 + 0.5) / INCANDESCENCE_BUCKET_COUNT as f32;
            let [r, g, b] = blackbody_ramp(t);
            [r, g, b, 1.0]
        }
        _ => [0.0, 0.0, 0.0, 1.0],
    }
}

/// Builds the incandescence glow mesh for a region: a marker cube at each macro
/// cell above the Draper point, colored on the blackbody ramp. Regions without a
/// temperature layer (mask bit clear) produce nothing.
pub fn incandescence_mesh(field: &FieldRegionSnapshot, voxel_size: f32) -> ChunkMeshData {
    if field.field_mask & FIELD_MASK_TEMPERATURE == 0 {
        return ChunkMeshData::default();
    }
    overlay_from_values(
        &field.macro_indices,
        &field.temperature,
        voxel_size,
        incandescence_material,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn below_draper_is_dark() {
        assert_eq!(blackbody_color(20.0), None); // ambient
        assert_eq!(blackbody_color(524.9), None); // just below Draper
        assert_eq!(incandescence_material(400.0), None);
        // NaN is dark (never glows), not a panic.
        assert_eq!(blackbody_color(f32::NAN), None);
    }

    #[test]
    fn at_and_above_draper_glows() {
        assert!(blackbody_color(DRAPER_C).is_some());
        assert!(blackbody_color(1000.0).is_some());
        assert!(incandescence_material(DRAPER_C).is_some());
    }

    #[test]
    fn hotter_shifts_toward_white_and_brightens() {
        let dull = blackbody_color(600.0).unwrap();
        let mid = blackbody_color(1200.0).unwrap();
        let hot = blackbody_color(2000.0).unwrap();

        // Green and blue channels climb with temperature (red→orange→yellow→white):
        // the telltale of a blackbody shift toward white.
        assert!(mid[1] > dull[1] && hot[1] > mid[1], "green climbs with temp");
        assert!(mid[2] > dull[2] && hot[2] > mid[2], "blue climbs with temp");
        // Overall brightness (R+G+B) climbs monotonically.
        let lum = |c: [f32; 3]| c[0] + c[1] + c[2];
        assert!(lum(mid) > lum(dull) && lum(hot) > lum(mid), "brightness climbs");
        // The hottest is near-white (all channels high).
        assert!(hot[0] > 0.9 && hot[1] > 0.8 && hot[2] > 0.5);
    }

    #[test]
    fn buckets_are_monotonic_and_clamped() {
        let cool = incandescence_material(DRAPER_C + 1.0).unwrap();
        let warm = incandescence_material(1200.0).unwrap();
        let hot = incandescence_material(2000.0).unwrap();
        assert!(cool < warm && warm < hot, "hotter → higher bucket id");
        // Way past white-hot saturates at the top bucket (no overflow).
        let saturated = incandescence_material(10_000.0).unwrap();
        assert_eq!(saturated, INCANDESCENCE_MATERIAL_BASE + INCANDESCENCE_BUCKET_COUNT - 1);
    }

    #[test]
    fn incandescence_color_maps_buckets_and_ignores_foreign_ids() {
        // A low bucket is reddish (red dominates); a high bucket is near-white.
        let low = incandescence_color(INCANDESCENCE_MATERIAL_BASE);
        assert!(low[0] > low[1] && low[0] > low[2], "low bucket reddish");
        let high = incandescence_color(INCANDESCENCE_MATERIAL_BASE + INCANDESCENCE_BUCKET_COUNT - 1);
        assert!(high[1] > 0.7 && high[2] > 0.4, "high bucket near-white");
        // A non-incandescence id contributes no glow (black under additive).
        assert_eq!(incandescence_color(2), [0.0, 0.0, 0.0, 1.0]);
        assert_eq!(incandescence_color(10_000), [0.0, 0.0, 0.0, 1.0]);
    }

    fn temp_field(cells: &[(u16, f32)]) -> FieldRegionSnapshot {
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id: 1,
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
    fn mesh_only_includes_glowing_cells() {
        // Two cells: one hot (1200 → glows), one cool (100 → dark). Only the hot
        // one produces geometry.
        let hot_only = temp_field(&[(0, 1200.0), (1, 100.0)]);
        let mesh = incandescence_mesh(&hot_only, 100.0);
        assert!(!mesh.positions.is_empty(), "hot cell produces a glow cube");

        // A cube is 24 vertices; exactly one cell glows → exactly one cube.
        assert_eq!(mesh.positions.len(), 24);
    }

    #[test]
    fn no_temperature_layer_produces_nothing() {
        let mut field = temp_field(&[(0, 1500.0)]);
        field.field_mask = 0; // strip the temperature bit
        assert!(incandescence_mesh(&field, 100.0).positions.is_empty());
    }
}
