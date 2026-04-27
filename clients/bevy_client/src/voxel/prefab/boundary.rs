//! Socket-free micro-boundary snapping primitives.
//!
//! Pure module: defines snap requests, previews, and place results, plus the
//! geometry helpers (`is_axis_normal`, `is_on_face`, `contact_slots_for_face`,
//! `prefab_cell_from_mask`). The actual application against [`super::super::world::VoxelWorld`]
//! lives in `world::store`.

use serde::{Deserialize, Serialize};

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCellTarget, MicroCoord, Rotation,
    VoxelMaterialId, micro_coord_from_index,
};

use super::definition::{PrefabDefinitionCell, PrefabRasterCell};
use super::registry::LocalPrefab;
use super::rotation::rotate_micro;

/// Socket-free boundary snap request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundarySnapRequest {
    pub prefab_name: String,
    pub hit_macro: MacroCoord,
    pub face_normal: MacroCoord,
    pub rotation: Rotation,
    /// Optional micro-aligned anchor point. When `Some`, the prefab's
    /// contact-face centre micro slot is positioned at this world-space
    /// micro location, allowing the prefab to span across macro
    /// boundaries (design 2026-04-26 prefab-micro-snap). When `None`,
    /// preview falls back to the legacy macro-aligned path that anchors
    /// the prefab's local (0,0,0) at the adjacent macro's (0,0,0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor_micro: Option<MicroCellTarget>,
}

/// Socket-free boundary snap preview.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundarySnapPreview {
    pub ok: bool,
    pub prefab_id: String,
    pub hit_macro: MacroCoord,
    pub face_normal: MacroCoord,
    pub anchor_micro_coord: Option<MicroCoord>,
    pub affected_macro_count: u32,
    pub incoming_occupied_slots: u32,
    pub overlap_slots: u32,
    pub contact_slots: u32,
    pub reject_reason: Option<String>,
    pub cells: Vec<PrefabRasterCell>,
}

impl BoundarySnapPreview {
    pub(crate) fn rejected(request: &BoundarySnapRequest, reason: &str) -> Self {
        Self {
            ok: false,
            prefab_id: request.prefab_name.clone(),
            hit_macro: request.hit_macro,
            face_normal: request.face_normal,
            anchor_micro_coord: None,
            affected_macro_count: 0,
            incoming_occupied_slots: 0,
            overlap_slots: 0,
            contact_slots: 0,
            reject_reason: Some(reason.to_string()),
            cells: Vec::new(),
        }
    }
}

/// Result of committing a boundary snap operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundarySnapPlaceResult {
    pub ok: bool,
    pub conflict: bool,
    pub instance_id: Option<u32>,
    pub preview: Option<BoundarySnapPreview>,
}

pub(crate) fn is_axis_normal(normal: MacroCoord) -> bool {
    matches!(
        (normal.x, normal.y, normal.z),
        (-1, 0, 0) | (1, 0, 0) | (0, -1, 0) | (0, 1, 0) | (0, 0, -1) | (0, 0, 1)
    )
}

pub(crate) fn opposite_normal(normal: MacroCoord) -> MacroCoord {
    MacroCoord::new(-normal.x, -normal.y, -normal.z)
}

fn is_on_face(coord: MicroCoord, normal: MacroCoord) -> bool {
    match (normal.x, normal.y, normal.z) {
        (-1, 0, 0) => coord.x == 0,
        (1, 0, 0) => coord.x == MICRO_PER_MACRO - 1,
        (0, -1, 0) => coord.y == 0,
        (0, 1, 0) => coord.y == MICRO_PER_MACRO - 1,
        (0, 0, -1) => coord.z == 0,
        (0, 0, 1) => coord.z == MICRO_PER_MACRO - 1,
        _ => false,
    }
}

pub(crate) fn contact_slots_for_face(prefab: &LocalPrefab, normal: MacroCoord) -> u32 {
    prefab
        .definition
        .cells
        .iter()
        .map(|cell| {
            cell.micro_occupancy_mask
                .indices()
                .filter_map(micro_coord_from_index)
                .filter(|coord| is_on_face(*coord, normal))
                .count() as u32
        })
        .sum()
}

/// Returns the prefab-local micro coord that should anchor against the
/// user-aimed `adjacent_micro` when the user clicks a face whose outward
/// normal is `face_normal`. Picks the centre of the prefab's *contact*
/// face (= -face_normal) before applying `rotation`. Falls back to the
/// prefab's geometric centre for non-axial normals.
///
/// Builtin prefabs all have `bounds_in_macro_cells == (1, 1, 1)`, so the
/// returned coord is in `[0, MICRO_PER_MACRO)` on each axis. For
/// multi-macro prefabs the coord may still address the bounds-relative
/// micro extent but the calling site must combine it with the prefab's
/// origin macro to compute a world-space anchor.
pub(crate) fn contact_face_center(
    prefab: &LocalPrefab,
    face_normal: MacroCoord,
    rotation: Rotation,
) -> MicroCoord {
    let bounds = prefab.definition.bounds_in_macro_cells;
    let max_x = bounds.x * MICRO_PER_MACRO - 1;
    let max_y = bounds.y * MICRO_PER_MACRO - 1;
    let max_z = bounds.z * MICRO_PER_MACRO - 1;
    let cx = max_x / 2;
    let cy = max_y / 2;
    let cz = max_z / 2;

    // Contact face = -face_normal. Pick the centre of that face on the
    // prefab BEFORE rotation. Rotation is applied below so each axis
    // is treated as if the prefab were in its un-rotated frame.
    let local = match (face_normal.x, face_normal.y, face_normal.z) {
        (0, 1, 0) => MicroCoord::new(cx, 0, cz), // user clicked +Y → prefab bottom
        (0, -1, 0) => MicroCoord::new(cx, max_y, cz), // user clicked -Y → prefab top
        (1, 0, 0) => MicroCoord::new(0, cy, cz), // user clicked +X → prefab -X face
        (-1, 0, 0) => MicroCoord::new(max_x, cy, cz), // user clicked -X → prefab +X face
        (0, 0, 1) => MicroCoord::new(cx, cy, 0), // user clicked +Z → prefab -Z face
        (0, 0, -1) => MicroCoord::new(cx, cy, max_z), // user clicked -Z → prefab +Z face
        _ => MicroCoord::new(cx, cy, cz),        // non-axial → prefab geometric centre
    };

    // Bounds rotation only matters for multi-macro prefabs; for the (1,1,1)
    // builtins `rotate_micro` operates in a single macro frame and is
    // exactly the right transform.
    if matches!(bounds, MacroCoord { x: 1, y: 1, z: 1 }) {
        rotate_micro(local, rotation)
    } else {
        // Future multi-macro prefab support: rotate around the bounds
        // centre. For now we keep the local coord untransformed and let
        // callers inspect bounds.
        local
    }
}

pub(crate) fn prefab_cell_from_mask(
    offset: MacroCoord,
    mask: MicroMask,
    material: VoxelMaterialId,
    part_id: i32,
) -> PrefabDefinitionCell {
    let mut materials = vec![VoxelMaterialId::Dirt; MICRO_GRID_SLOT_COUNT];
    let states = vec![0; MICRO_GRID_SLOT_COUNT];
    let mut part_ids = vec![-1; MICRO_GRID_SLOT_COUNT];
    for index in mask.indices() {
        materials[index] = material;
        part_ids[index] = part_id;
    }
    PrefabDefinitionCell {
        offset,
        micro_occupancy_mask: mask,
        micro_material_ids: materials,
        micro_state_flags: states,
        micro_part_ids: part_ids,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::prefab::registry::LocalPrefabRegistry;

    fn sphere() -> LocalPrefab {
        LocalPrefabRegistry::with_builtins()
            .get("builtin_sphere")
            .expect("sphere prefab")
            .clone()
    }

    /// `MICRO_PER_MACRO = 8`, so for a (1,1,1) bounds prefab the
    /// per-axis range is `[0, 7]` and the centre is `7/2 = 3`.
    const CENTER: i32 = 3;
    const MAX: i32 = MICRO_PER_MACRO - 1;

    #[test]
    fn contact_face_center_for_top_face_uses_prefab_bottom_center() {
        let coord = contact_face_center(&sphere(), MacroCoord::new(0, 1, 0), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(CENTER, 0, CENTER));
    }

    #[test]
    fn contact_face_center_for_bottom_face_uses_prefab_top_center() {
        let coord = contact_face_center(&sphere(), MacroCoord::new(0, -1, 0), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(CENTER, MAX, CENTER));
    }

    #[test]
    fn contact_face_center_for_east_face_uses_prefab_west_center() {
        let coord = contact_face_center(&sphere(), MacroCoord::new(1, 0, 0), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(0, CENTER, CENTER));
    }

    #[test]
    fn contact_face_center_for_west_face_uses_prefab_east_center() {
        let coord = contact_face_center(&sphere(), MacroCoord::new(-1, 0, 0), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(MAX, CENTER, CENTER));
    }

    #[test]
    fn contact_face_center_for_south_face_uses_prefab_north_center() {
        let coord = contact_face_center(&sphere(), MacroCoord::new(0, 0, 1), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(CENTER, CENTER, 0));
    }

    #[test]
    fn contact_face_center_for_north_face_uses_prefab_south_center() {
        let coord = contact_face_center(&sphere(), MacroCoord::new(0, 0, -1), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(CENTER, CENTER, MAX));
    }

    #[test]
    fn contact_face_center_for_non_axial_falls_back_to_geometric_center() {
        // (1, 1, 0) is not an axial face normal — should not pick any face.
        let coord = contact_face_center(&sphere(), MacroCoord::new(1, 1, 0), Rotation::Rot0);
        assert_eq!(coord, MicroCoord::new(CENTER, CENTER, CENTER));
    }

    #[test]
    fn contact_face_center_rot90_rotates_top_face_anchor() {
        // Top-face anchor is (3, 0, 3) at Rot0. After Rot90 (around vertical
        // Y axis), (3, 0, 3) → (max - 3, 0, 3) = (4, 0, 3).
        let coord = contact_face_center(&sphere(), MacroCoord::new(0, 1, 0), Rotation::Rot90);
        assert_eq!(coord, MicroCoord::new(MAX - CENTER, 0, CENTER));
    }
}
