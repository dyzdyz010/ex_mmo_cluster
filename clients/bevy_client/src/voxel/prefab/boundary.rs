//! Socket-free micro-boundary snapping primitives.
//!
//! Pure module: defines snap requests, previews, and place results, plus the
//! geometry helpers (`is_axis_normal`, `is_on_face`, `contact_slots_for_face`,
//! `prefab_cell_from_mask`). The actual application against [`super::super::world::VoxelWorld`]
//! lives in `world::store`.

use serde::{Deserialize, Serialize};

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCoord, Rotation, VoxelMaterialId,
    micro_coord_from_index,
};

use super::definition::{PrefabDefinitionCell, PrefabRasterCell};
use super::registry::LocalPrefab;

/// Socket-free boundary snap request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundarySnapRequest {
    pub prefab_name: String,
    pub hit_macro: MacroCoord,
    pub face_normal: MacroCoord,
    pub rotation: Rotation,
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
