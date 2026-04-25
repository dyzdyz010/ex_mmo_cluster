//! Local prefab registry: built-ins and captured definitions.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{
    MICRO_PER_MACRO, MacroCoord, Rotation, VoxelMaterialId,
    coord::{max_macro_coord, min_macro_coord},
};

use super::boundary::prefab_cell_from_mask;
use super::builtins::{cylinder_mask, sphere_mask, stairs_mask};
use super::definition::{PrefabDefinitionData, PrefabPartDefinition, PrefabRasterCell};
use super::rotation::{rotate_macro_offset, rotate_prefab_cell};

/// Runtime prefab definition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalPrefab {
    pub name: String,
    pub definition: PrefabDefinitionData,
}

impl LocalPrefab {
    /// Counts all occupied micro slots.
    pub fn total_occupied_slots(&self) -> u32 {
        self.definition
            .cells
            .iter()
            .map(|cell| cell.micro_occupancy_mask.occupied_slot_count())
            .sum()
    }

    pub(crate) fn rasterize(
        &self,
        origin: MacroCoord,
        rotation: Rotation,
    ) -> Vec<PrefabRasterCell> {
        self.definition
            .cells
            .iter()
            .map(|cell| {
                let rotated_offset = rotate_macro_offset(
                    cell.offset,
                    self.definition.bounds_in_macro_cells,
                    rotation,
                );
                let rotated_cell = rotate_prefab_cell(cell, rotation);
                PrefabRasterCell {
                    macro_coord: origin.offset(rotated_offset),
                    data: rotated_cell,
                }
            })
            .collect()
    }
}

/// Local prefab registry with built-ins and captured definitions.
#[derive(Debug, Clone)]
pub struct LocalPrefabRegistry {
    prefabs: BTreeMap<String, LocalPrefab>,
}

impl LocalPrefabRegistry {
    /// Builds a registry with browser-compatible built-in prefabs.
    pub fn with_builtins() -> Self {
        let mut registry = Self {
            prefabs: BTreeMap::new(),
        };
        registry.register_builtin("builtin_sphere", VoxelMaterialId::Wood, sphere_mask());
        registry.register_builtin("builtin_cylinder", VoxelMaterialId::Stone, cylinder_mask());
        registry.register_builtin("builtin_stairs", VoxelMaterialId::Wood, stairs_mask());
        registry
    }

    /// Returns a prefab by name.
    pub fn get(&self, name: &str) -> Option<&LocalPrefab> {
        self.prefabs.get(name)
    }

    /// Lists prefabs in deterministic order.
    pub fn list(&self) -> Vec<LocalPrefab> {
        self.prefabs.values().cloned().collect()
    }

    fn register_builtin(&mut self, name: &str, material: VoxelMaterialId, mask: MicroMask) {
        let cell = prefab_cell_from_mask(MacroCoord::new(0, 0, 0), mask, material, 0);
        self.prefabs.insert(
            name.to_string(),
            LocalPrefab {
                name: name.to_string(),
                definition: PrefabDefinitionData {
                    prefab_id: name.to_string(),
                    bounds_in_macro_cells: MacroCoord::new(1, 1, 1),
                    micro_resolution: MICRO_PER_MACRO,
                    cells: vec![cell],
                    part_definitions: vec![PrefabPartDefinition {
                        part_id: "body".to_string(),
                        part_tags: vec!["solid".to_string()],
                        default_affordances: vec!["breakable".to_string()],
                        default_health: material.max_health(),
                    }],
                    allowed_rotations: vec![
                        Rotation::Rot0,
                        Rotation::Rot90,
                        Rotation::Rot180,
                        Rotation::Rot270,
                    ],
                    tags: vec!["builtin".to_string()],
                },
            },
        );
    }

    /// Captures a prefab from a flat list of (offset-in-bounds, material) blocks.
    ///
    /// The caller is responsible for translating world coords to bounds-relative
    /// offsets and filtering only normal blocks; this keeps the registry
    /// independent of `voxel::world` storage internals.
    pub(crate) fn capture(
        &mut self,
        name: &str,
        bounds: MacroCoord,
        blocks: &[(MacroCoord, VoxelMaterialId)],
    ) -> LocalPrefab {
        let prefab_cells: Vec<_> = blocks
            .iter()
            .enumerate()
            .map(|(part_index, (offset, material))| {
                prefab_cell_from_mask(*offset, MicroMask::full(), *material, part_index as i32)
            })
            .collect();

        let part_count = prefab_cells.len();
        let prefab = LocalPrefab {
            name: name.to_string(),
            definition: PrefabDefinitionData {
                prefab_id: name.to_string(),
                bounds_in_macro_cells: bounds,
                micro_resolution: MICRO_PER_MACRO,
                cells: prefab_cells,
                part_definitions: (0..part_count)
                    .map(|index| PrefabPartDefinition {
                        part_id: format!("part_{index}"),
                        part_tags: vec!["captured".to_string()],
                        default_affordances: vec!["breakable".to_string()],
                        default_health: 100,
                    })
                    .collect(),
                allowed_rotations: vec![
                    Rotation::Rot0,
                    Rotation::Rot90,
                    Rotation::Rot180,
                    Rotation::Rot270,
                ],
                tags: vec!["captured".to_string()],
            },
        };
        self.prefabs.insert(name.to_string(), prefab.clone());
        prefab
    }

    /// Bounds spanning the inclusive box from `min` to `max` after normalising.
    pub(crate) fn capture_bounds(
        min: MacroCoord,
        max: MacroCoord,
    ) -> (MacroCoord, MacroCoord, MacroCoord) {
        let low = min_macro_coord(min, max);
        let high = max_macro_coord(min, max);
        let bounds = MacroCoord::new(high.x - low.x + 1, high.y - low.y + 1, high.z - low.z + 1);
        (low, high, bounds)
    }
}

impl Default for LocalPrefabRegistry {
    fn default() -> Self {
        Self::with_builtins()
    }
}
