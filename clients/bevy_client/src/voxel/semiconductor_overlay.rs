//! Semiconductor / logic debug overlay (C5.3): a render sub-layer that marks the
//! construction system's semiconductor cells — passive **resistor** (server
//! `MaterialCatalog` id 20) and threshold **comparator** (id 21) — by their LOGIC
//! state, so a builder can read a circuit's digital behaviour at a glance.
//!
//! Distinct from the analog FieldView overlays (`field_view`): those colour cells
//! by raw electric potential/current magnitude. This layer instead correlates two
//! authoritative sources — **which** cells are semiconductors (the chunk material,
//! authority store) and **how** they behave (the electric field, FieldView regions
//! over that cell) — and renders a binary logic readout: a resistor is amber when it
//! carries current (active) / dim grey when idle; a comparator is bright green when
//! its potential clears the logic threshold (the server `:signal_high`) / dim red
//! when low.
//!
//! Pure data (no Bevy): the core `semiconductor_overlay_mesh` takes the cell list
//! plus a per-cell `(current, potential)` lookup, so it is Layer-1 geometry / colour
//! assertable and Layer-3 pixel-provable; the Bevy adapter (`semiconductor_render`)
//! feeds it the authority materials + the field grids.

use crate::voxel::mesher::{ChunkMeshData, push_cube};

/// Server `MaterialCatalog` ids of the placeable semiconductors (C3/C4a). Mirrored
/// here so the overlay can pick them out of chunk truth without a material table.
pub const RESISTOR_MATERIAL_ID: u16 = 20;
pub const COMPARATOR_MATERIAL_ID: u16 = 21;

/// Reserved marker-id range for the four logic states, disjoint from every
/// `field_view` field range (those top out at `LIGHT_MATERIAL_BASE` 10_500 +
/// buckets). `field_color` ignores this range, so the semiconductor overlay owns
/// its own colour table ([`semiconductor_color`]).
pub const SEMICONDUCTOR_MATERIAL_BASE: u32 = 10_600;

/// Current magnitude (amps) at/above which a resistor counts as "carrying current"
/// (active). Matches the FieldView current draw threshold so the two layers agree
/// on which cells are live.
pub const RESISTOR_ACTIVE_CURRENT: f32 = 0.001;

/// Potential at/above which a comparator reads logic-high — the client-side mirror
/// of the server `CircuitCurrentKernel`'s `:signal_high` (node potential ≥ the
/// comparator's `logic_threshold`). The default comparator threshold; the overlay
/// is a debug read, not the authority (the server owns the real decision).
pub const COMPARATOR_LOGIC_HIGH_POTENTIAL: f32 = 0.5;

/// The four logic-readout states, each a fixed marker id + colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemiconductorState {
    /// Resistor with no appreciable current → dim grey.
    ResistorIdle,
    /// Resistor carrying current → amber (active).
    ResistorActive,
    /// Comparator below its logic threshold → dim red (output low).
    ComparatorLow,
    /// Comparator at/above its logic threshold → bright green (`:signal_high`).
    ComparatorHigh,
}

impl SemiconductorState {
    /// The baked marker material id for this state (within the reserved range).
    pub fn marker_id(self) -> u32 {
        SEMICONDUCTOR_MATERIAL_BASE
            + match self {
                SemiconductorState::ResistorIdle => 0,
                SemiconductorState::ResistorActive => 1,
                SemiconductorState::ComparatorLow => 2,
                SemiconductorState::ComparatorHigh => 3,
            }
    }

    /// Classifies a semiconductor cell from its material id + electric state. Returns
    /// `None` for a non-semiconductor material (so callers can scan all cells).
    pub fn classify(material_id: u16, current: f32, potential: f32) -> Option<Self> {
        match material_id {
            RESISTOR_MATERIAL_ID => Some(if current.abs() >= RESISTOR_ACTIVE_CURRENT {
                SemiconductorState::ResistorActive
            } else {
                SemiconductorState::ResistorIdle
            }),
            COMPARATOR_MATERIAL_ID => Some(if potential >= COMPARATOR_LOGIC_HIGH_POTENTIAL {
                SemiconductorState::ComparatorHigh
            } else {
                SemiconductorState::ComparatorLow
            }),
            _ => None,
        }
    }
}

/// Alpha of the logic markers — translucent like the FieldView debug cells so the
/// host block stays visible through the readout.
const SEMICONDUCTOR_ALPHA: f32 = 0.6;

/// Marker cube edge as a fraction of a macro cell (slightly smaller than the
/// FieldView markers so a semiconductor's logic readout nests inside any analog
/// field overlay sharing the cell, instead of z-fighting it).
const MARKER_FRACTION: f32 = 0.6;

/// RGBA for a baked semiconductor marker id, or `None` if the id is outside the
/// reserved range (lets a unified colour dispatcher fall through).
pub fn semiconductor_color(material_id: u32) -> Option<[f32; 4]> {
    let state = match material_id.checked_sub(SEMICONDUCTOR_MATERIAL_BASE)? {
        0 => SemiconductorState::ResistorIdle,
        1 => SemiconductorState::ResistorActive,
        2 => SemiconductorState::ComparatorLow,
        3 => SemiconductorState::ComparatorHigh,
        _ => return None,
    };
    Some(match state {
        // dim grey (idle resistor)
        SemiconductorState::ResistorIdle => [0.30, 0.30, 0.32, SEMICONDUCTOR_ALPHA],
        // amber (active resistor — current flowing, like the FieldView current ramp top)
        SemiconductorState::ResistorActive => [1.0, 0.62, 0.10, SEMICONDUCTOR_ALPHA],
        // dim red (comparator output low)
        SemiconductorState::ComparatorLow => [0.45, 0.06, 0.06, SEMICONDUCTOR_ALPHA],
        // bright green (comparator :signal_high)
        SemiconductorState::ComparatorHigh => [0.10, 1.0, 0.20, SEMICONDUCTOR_ALPHA],
    })
}

/// One semiconductor cell to render: its local macro index (0..4095) + material id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemiconductorCell {
    pub macro_index: u16,
    pub material_id: u16,
}

/// Builds the logic overlay mesh: a centered marker cube at each semiconductor
/// cell, coloured by [`SemiconductorState::classify`]. `electric` returns the
/// `(current, potential)` for a cell's macro index (0 / 0 when no field covers it
/// — an unpowered semiconductor still draws its idle/low marker). Non-semiconductor
/// cells in the list are skipped.
pub fn semiconductor_overlay_mesh(
    cells: &[SemiconductorCell],
    voxel_size: f32,
    electric: impl Fn(u16) -> (f32, f32),
) -> ChunkMeshData {
    let mut mesh = ChunkMeshData::default();
    let marker = voxel_size * MARKER_FRACTION;
    let inset = (voxel_size - marker) * 0.5; // center the marker in the macro cell

    for cell in cells {
        let (current, potential) = electric(cell.macro_index);
        let Some(state) = SemiconductorState::classify(cell.material_id, current, potential) else {
            continue;
        };
        let (mx, my, mz) = macro_coord(cell.macro_index);
        let min = [
            mx as f32 * voxel_size + inset,
            my as f32 * voxel_size + inset,
            mz as f32 * voxel_size + inset,
        ];
        push_cube(&mut mesh, min, marker, state.marker_id());
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

    #[test]
    fn classify_resistor_by_current_and_comparator_by_potential() {
        // Resistor: idle below the current threshold, active at/above it.
        assert_eq!(
            SemiconductorState::classify(RESISTOR_MATERIAL_ID, 0.0, 99.0),
            Some(SemiconductorState::ResistorIdle)
        );
        assert_eq!(
            SemiconductorState::classify(RESISTOR_MATERIAL_ID, 5.0, 0.0),
            Some(SemiconductorState::ResistorActive)
        );
        // Negative current still counts (magnitude).
        assert_eq!(
            SemiconductorState::classify(RESISTOR_MATERIAL_ID, -2.0, 0.0),
            Some(SemiconductorState::ResistorActive)
        );

        // Comparator: low below threshold, high at/above (signal_high).
        assert_eq!(
            SemiconductorState::classify(COMPARATOR_MATERIAL_ID, 99.0, 0.1),
            Some(SemiconductorState::ComparatorLow)
        );
        assert_eq!(
            SemiconductorState::classify(COMPARATOR_MATERIAL_ID, 0.0, 0.6),
            Some(SemiconductorState::ComparatorHigh)
        );

        // Non-semiconductor material → not classified.
        assert_eq!(SemiconductorState::classify(2, 5.0, 5.0), None);
    }

    #[test]
    fn marker_ids_are_distinct_and_in_reserved_range() {
        let ids = [
            SemiconductorState::ResistorIdle.marker_id(),
            SemiconductorState::ResistorActive.marker_id(),
            SemiconductorState::ComparatorLow.marker_id(),
            SemiconductorState::ComparatorHigh.marker_id(),
        ];
        // All distinct.
        for (i, a) in ids.iter().enumerate() {
            for b in &ids[i + 1..] {
                assert_ne!(a, b);
            }
        }
        // All in the reserved range, above every field_view range.
        assert!(ids.iter().all(|&m| m >= SEMICONDUCTOR_MATERIAL_BASE && m < SEMICONDUCTOR_MATERIAL_BASE + 4));
        // field_view's top range (light) does not collide.
        assert!(SEMICONDUCTOR_MATERIAL_BASE > crate::voxel::field_view::LIGHT_MATERIAL_BASE);
    }

    #[test]
    fn colors_read_amber_active_green_high_and_round_trip_marker_ids() {
        // Active resistor = amber (R > B, warm).
        let amber = semiconductor_color(SemiconductorState::ResistorActive.marker_id()).unwrap();
        assert!(amber[0] > amber[2] && amber[1] > amber[2], "active resistor warm amber; {amber:?}");
        // Comparator high = green dominant.
        let green = semiconductor_color(SemiconductorState::ComparatorHigh.marker_id()).unwrap();
        assert!(green[1] > green[0] && green[1] > green[2], "signal_high green; {green:?}");
        // Comparator low = red dominant.
        let red = semiconductor_color(SemiconductorState::ComparatorLow.marker_id()).unwrap();
        assert!(red[0] > red[1] && red[0] > red[2], "output low red; {red:?}");
        // Out-of-range id → None (so a unified dispatcher falls through).
        assert_eq!(semiconductor_color(SEMICONDUCTOR_MATERIAL_BASE + 99), None);
        assert_eq!(semiconductor_color(5), None);
    }

    #[test]
    fn overlay_draws_one_marker_per_semiconductor_with_state_color() {
        let cells = vec![
            SemiconductorCell { macro_index: 0, material_id: RESISTOR_MATERIAL_ID },
            SemiconductorCell { macro_index: 5, material_id: COMPARATOR_MATERIAL_ID },
            SemiconductorCell { macro_index: 9, material_id: 2 }, // stone → skipped
        ];
        // Resistor (idx 0) carries current; comparator (idx 5) is high.
        let mesh = semiconductor_overlay_mesh(&cells, 1.0, |idx| match idx {
            0 => (3.0, 0.0),  // resistor active
            5 => (0.0, 0.9),  // comparator high
            _ => (0.0, 0.0),
        });
        let s = mesh.summary();
        // Two semiconductors → two marker cubes (12 quads); the stone cell is skipped.
        assert_eq!(s.quad_count, 12);
        assert!(s.structural_ok);
        let mats: Vec<u32> = s.area_by_material.keys().copied().collect();
        assert!(mats.contains(&SemiconductorState::ResistorActive.marker_id()));
        assert!(mats.contains(&SemiconductorState::ComparatorHigh.marker_id()));
    }

    #[test]
    fn unpowered_semiconductor_still_draws_idle_low_marker() {
        // No field covering the cells → idle resistor / low comparator (not skipped).
        let cells = vec![
            SemiconductorCell { macro_index: 1, material_id: RESISTOR_MATERIAL_ID },
            SemiconductorCell { macro_index: 2, material_id: COMPARATOR_MATERIAL_ID },
        ];
        let mesh = semiconductor_overlay_mesh(&cells, 1.0, |_| (0.0, 0.0));
        let s = mesh.summary();
        assert_eq!(s.quad_count, 12);
        let mats: Vec<u32> = s.area_by_material.keys().copied().collect();
        assert!(mats.contains(&SemiconductorState::ResistorIdle.marker_id()));
        assert!(mats.contains(&SemiconductorState::ComparatorLow.marker_id()));
    }

    #[test]
    fn marker_cube_is_centered_in_its_macro_cell() {
        // macro 0 → cell (0,0,0); marker 0.6 of a 100-unit cell, inset 20 → [20,80].
        let cells = vec![SemiconductorCell { macro_index: 0, material_id: RESISTOR_MATERIAL_ID }];
        let mesh = semiconductor_overlay_mesh(&cells, 100.0, |_| (5.0, 0.0));
        let s = mesh.summary();
        let min = s.aabb_min.unwrap();
        let max = s.aabb_max.unwrap();
        // 0.6 isn't exactly representable; assert within a small tolerance.
        assert!(min.iter().all(|v| (v - 20.0).abs() < 1e-3), "min {min:?}");
        assert!(max.iter().all(|v| (v - 80.0).abs() < 1e-3), "max {max:?}");
    }
}
