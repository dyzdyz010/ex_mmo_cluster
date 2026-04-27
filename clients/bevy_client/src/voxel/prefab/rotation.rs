//! Prefab rotation transforms shared between definition rasterization and
//! boundary snap previewing.

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCoord, Rotation, VoxelMaterialId,
    micro_coord_from_index, micro_linear_index,
};

use super::definition::{PrefabCellData, PrefabDefinitionCell};

pub(crate) fn rotate_macro_offset(
    offset: MacroCoord,
    bounds: MacroCoord,
    rotation: Rotation,
) -> MacroCoord {
    match rotation {
        Rotation::Rot0 => offset,
        Rotation::Rot90 => MacroCoord::new(bounds.z - 1 - offset.z, offset.y, offset.x),
        Rotation::Rot180 => {
            MacroCoord::new(bounds.x - 1 - offset.x, offset.y, bounds.z - 1 - offset.z)
        }
        Rotation::Rot270 => MacroCoord::new(offset.z, offset.y, bounds.x - 1 - offset.x),
    }
}

pub(crate) fn rotate_prefab_cell(
    cell: &PrefabDefinitionCell,
    rotation: Rotation,
) -> PrefabCellData {
    if rotation == Rotation::Rot0 {
        return PrefabCellData {
            micro_occupancy_mask: cell.micro_occupancy_mask,
            micro_material_ids: cell.micro_material_ids.clone(),
            micro_state_flags: cell.micro_state_flags.clone(),
            micro_part_ids: cell.micro_part_ids.clone(),
        };
    }

    let mut mask = MicroMask::empty();
    let mut materials = vec![VoxelMaterialId::Dirt; MICRO_GRID_SLOT_COUNT];
    let mut states = vec![0; MICRO_GRID_SLOT_COUNT];
    let mut parts = vec![-1; MICRO_GRID_SLOT_COUNT];

    for source_index in cell.micro_occupancy_mask.indices() {
        let source = micro_coord_from_index(source_index).expect("valid source index");
        let rotated = rotate_micro(source, rotation);
        let target_index = micro_linear_index(rotated).expect("valid rotated index");
        mask.set_index(target_index);
        materials[target_index] = cell.micro_material_ids[source_index];
        states[target_index] = cell.micro_state_flags[source_index];
        parts[target_index] = cell.micro_part_ids[source_index];
    }

    PrefabCellData {
        micro_occupancy_mask: mask,
        micro_material_ids: materials,
        micro_state_flags: states,
        micro_part_ids: parts,
    }
}

pub(crate) fn rotate_micro(coord: MicroCoord, rotation: Rotation) -> MicroCoord {
    let max = MICRO_PER_MACRO - 1;
    match rotation {
        Rotation::Rot0 => coord,
        Rotation::Rot90 => MicroCoord::new(max - coord.z, coord.y, coord.x),
        Rotation::Rot180 => MicroCoord::new(max - coord.x, coord.y, max - coord.z),
        Rotation::Rot270 => MicroCoord::new(coord.z, coord.y, max - coord.x),
    }
}
