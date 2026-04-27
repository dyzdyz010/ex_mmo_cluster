//! Local prefab registry: built-ins and captured definitions.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCoord, Rotation, VoxelMaterialId,
    coord::{max_macro_coord, micro_coord_from_index, micro_linear_index, min_macro_coord},
};

use super::boundary::prefab_cell_from_mask;
use super::builtins::{cylinder_mask, sphere_mask, stairs_mask};
use super::definition::{
    PrefabCellData, PrefabDefinitionData, PrefabPartDefinition, PrefabRasterCell,
};
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
        self.rasterize_with_micro_shift(origin, rotation, 0, 0, 0)
    }

    /// Rasterizes the prefab at `origin` macro with `rotation`, then shifts
    /// every micro slot by `(shift_x, shift_y, shift_z)` micros. Slots that
    /// cross a macro boundary spill into neighbour macros — a single source
    /// cell can produce up to 8 destination raster cells when the shift is
    /// diagonal across all three axes. Cells that fall in the same
    /// destination macro (e.g. multi-cell prefab whose adjacent cells both
    /// shift across the same boundary) are merged into one PrefabRasterCell
    /// with their micro masks and per-slot metadata combined.
    ///
    /// `(0, 0, 0)` shift returns the same set of macro-aligned cells the
    /// pre-existing `rasterize` produced — the original method now defers
    /// here so all callers share the same rotation+merge code path.
    pub(crate) fn rasterize_with_micro_shift(
        &self,
        origin: MacroCoord,
        rotation: Rotation,
        shift_x: i32,
        shift_y: i32,
        shift_z: i32,
    ) -> Vec<PrefabRasterCell> {
        let mut by_dest: BTreeMap<MacroCoord, PrefabCellData> = BTreeMap::new();
        for source_cell in &self.definition.cells {
            let rotated_offset = rotate_macro_offset(
                source_cell.offset,
                self.definition.bounds_in_macro_cells,
                rotation,
            );
            let rotated_cell = rotate_prefab_cell(source_cell, rotation);
            let cell_origin_macro = origin.offset(rotated_offset);

            for (macro_off, sub_cell) in
                shift_cell_to_neighbours(&rotated_cell, shift_x, shift_y, shift_z)
            {
                let dest_macro = cell_origin_macro.offset(macro_off);
                let entry = by_dest.entry(dest_macro).or_insert_with(empty_prefab_cell);
                merge_cell_data_into(entry, &sub_cell);
            }
        }
        by_dest
            .into_iter()
            .map(|(macro_coord, data)| PrefabRasterCell { macro_coord, data })
            .collect()
    }
}

fn empty_prefab_cell() -> PrefabCellData {
    PrefabCellData {
        micro_occupancy_mask: MicroMask::empty(),
        micro_material_ids: vec![VoxelMaterialId::Dirt; MICRO_GRID_SLOT_COUNT],
        micro_state_flags: vec![0; MICRO_GRID_SLOT_COUNT],
        micro_part_ids: vec![-1; MICRO_GRID_SLOT_COUNT],
    }
}

fn merge_cell_data_into(target: &mut PrefabCellData, source: &PrefabCellData) {
    for slot in source.micro_occupancy_mask.indices() {
        target.micro_occupancy_mask.set_index(slot);
        target.micro_material_ids[slot] = source.micro_material_ids[slot];
        target.micro_state_flags[slot] = source.micro_state_flags[slot];
        target.micro_part_ids[slot] = source.micro_part_ids[slot];
    }
}

/// Splits one rotated prefab cell's micro slots into `(macro_offset,
/// PrefabCellData)` buckets according to `(shift_x, shift_y, shift_z)`.
/// Each bucket holds only the slots that fell into that destination
/// macro, with per-slot metadata copied to the new slot index.
fn shift_cell_to_neighbours(
    cell: &PrefabCellData,
    shift_x: i32,
    shift_y: i32,
    shift_z: i32,
) -> Vec<(MacroCoord, PrefabCellData)> {
    let mut buckets: BTreeMap<MacroCoord, PrefabCellData> = BTreeMap::new();
    for source_index in cell.micro_occupancy_mask.indices() {
        let Some(source) = micro_coord_from_index(source_index) else {
            continue;
        };
        let nx = source.x + shift_x;
        let ny = source.y + shift_y;
        let nz = source.z + shift_z;
        let macro_off = MacroCoord::new(
            nx.div_euclid(MICRO_PER_MACRO),
            ny.div_euclid(MICRO_PER_MACRO),
            nz.div_euclid(MICRO_PER_MACRO),
        );
        let dest = MicroCoord::new(
            nx.rem_euclid(MICRO_PER_MACRO),
            ny.rem_euclid(MICRO_PER_MACRO),
            nz.rem_euclid(MICRO_PER_MACRO),
        );
        let Some(dest_index) = micro_linear_index(dest) else {
            continue;
        };
        let bucket = buckets.entry(macro_off).or_insert_with(empty_prefab_cell);
        bucket.micro_occupancy_mask.set_index(dest_index);
        bucket.micro_material_ids[dest_index] = cell.micro_material_ids[source_index];
        bucket.micro_state_flags[dest_index] = cell.micro_state_flags[source_index];
        bucket.micro_part_ids[dest_index] = cell.micro_part_ids[source_index];
    }
    buckets.into_iter().collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    fn sphere() -> LocalPrefab {
        LocalPrefabRegistry::with_builtins()
            .get("builtin_sphere")
            .expect("sphere prefab")
            .clone()
    }

    #[test]
    fn rasterize_with_zero_shift_matches_legacy_rasterize() {
        let prefab = sphere();
        let origin = MacroCoord::new(2, 4, 6);
        let baseline = prefab.rasterize(origin, Rotation::Rot0);
        let shifted = prefab.rasterize_with_micro_shift(origin, Rotation::Rot0, 0, 0, 0);
        assert_eq!(baseline, shifted);
    }

    #[test]
    fn rasterize_with_x_shift_splits_one_macro_prefab_into_two_dest_macros() {
        let prefab = sphere();
        let origin = MacroCoord::new(0, 0, 0);
        let occupied_total = prefab.total_occupied_slots();

        let result = prefab.rasterize_with_micro_shift(origin, Rotation::Rot0, 5, 0, 0);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].macro_coord, MacroCoord::new(0, 0, 0));
        assert_eq!(result[1].macro_coord, MacroCoord::new(1, 0, 0));

        let combined: u32 = result
            .iter()
            .map(|cell| cell.data.micro_occupancy_mask.occupied_slot_count())
            .sum();
        assert_eq!(combined, occupied_total);
    }

    #[test]
    fn rasterize_with_diagonal_shift_can_produce_up_to_eight_dest_macros() {
        let prefab = sphere();
        let origin = MacroCoord::new(0, 0, 0);
        let occupied_total = prefab.total_occupied_slots();

        let result = prefab.rasterize_with_micro_shift(origin, Rotation::Rot0, 5, 3, 7);
        assert!(result.len() <= 8);

        let combined: u32 = result
            .iter()
            .map(|cell| cell.data.micro_occupancy_mask.occupied_slot_count())
            .sum();
        assert_eq!(combined, occupied_total);
    }

    #[test]
    fn rasterize_with_negative_shift_uses_div_euclid() {
        let prefab = sphere();
        let origin = MacroCoord::new(5, 5, 5);
        let result = prefab.rasterize_with_micro_shift(origin, Rotation::Rot0, -1, 0, 0);
        // Sphere mask has slots at micro x=0, which after shift x=-1 land in
        // the (4, 5, 5) destination macro.
        let mut dest_macros: Vec<MacroCoord> = result.iter().map(|c| c.macro_coord).collect();
        dest_macros.sort();
        assert!(dest_macros.contains(&MacroCoord::new(4, 5, 5)));
        assert!(dest_macros.contains(&MacroCoord::new(5, 5, 5)));
    }

    #[test]
    fn rasterize_with_shift_preserves_per_slot_material() {
        let prefab = sphere();
        let origin = MacroCoord::new(0, 0, 0);
        let baseline = prefab.rasterize_with_micro_shift(origin, Rotation::Rot0, 0, 0, 0);
        let baseline_cell = &baseline[0];
        // Pick the first occupied slot and read its material.
        let any_slot = baseline_cell
            .data
            .micro_occupancy_mask
            .indices()
            .next()
            .expect("sphere has occupied slots");
        let baseline_material = baseline_cell.data.micro_material_ids[any_slot];
        assert_eq!(baseline_material, VoxelMaterialId::Wood);

        // After a shift of +1 along X, the same source slot ends up at a
        // micro coord whose linear index is +1, with the same material.
        let shifted = prefab.rasterize_with_micro_shift(origin, Rotation::Rot0, 1, 0, 0);
        // Find that same destination slot:
        let source_coord = micro_coord_from_index(any_slot).unwrap();
        let nx = source_coord.x + 1;
        let macro_off = MacroCoord::new(nx.div_euclid(MICRO_PER_MACRO), 0, 0);
        let dest_micro = MicroCoord::new(
            nx.rem_euclid(MICRO_PER_MACRO),
            source_coord.y,
            source_coord.z,
        );
        let dest_index = micro_linear_index(dest_micro).unwrap();
        let dest_cell = shifted
            .iter()
            .find(|c| c.macro_coord == origin.offset(macro_off))
            .expect("destination cell exists");
        assert_eq!(
            dest_cell.data.micro_material_ids[dest_index],
            VoxelMaterialId::Wood
        );
    }
}
