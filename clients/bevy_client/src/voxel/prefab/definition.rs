//! Prefab definition payloads and rasterized cell types.

use serde::{Deserialize, Serialize};

use crate::voxel::core::{MacroCoord, MicroMask, Rotation, VoxelMaterialId};

/// Runtime prefab definition payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabDefinitionData {
    pub prefab_id: String,
    pub bounds_in_macro_cells: MacroCoord,
    pub micro_resolution: i32,
    pub cells: Vec<PrefabDefinitionCell>,
    pub part_definitions: Vec<PrefabPartDefinition>,
    pub allowed_rotations: Vec<Rotation>,
    pub tags: Vec<String>,
}

/// One prefab macro-cell payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabDefinitionCell {
    pub offset: MacroCoord,
    pub micro_occupancy_mask: MicroMask,
    pub micro_material_ids: Vec<VoxelMaterialId>,
    pub micro_state_flags: Vec<u16>,
    pub micro_part_ids: Vec<i32>,
}

/// Prefab part metadata retained for future gameplay semantics.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabPartDefinition {
    pub part_id: String,
    pub part_tags: Vec<String>,
    pub default_affordances: Vec<String>,
    pub default_health: u16,
}

/// Rasterized prefab cell ready to merge into world storage.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabRasterCell {
    pub macro_coord: MacroCoord,
    pub data: PrefabCellData,
}

/// Prefab cell payload ready for world storage.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabCellData {
    pub micro_occupancy_mask: MicroMask,
    pub micro_material_ids: Vec<VoxelMaterialId>,
    pub micro_state_flags: Vec<u16>,
    pub micro_part_ids: Vec<i32>,
}
