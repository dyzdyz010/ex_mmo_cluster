//! Local voxel world truth: cell storage, prefab instances, hotbar, edit
//! stats, and snapshot import/export wiring.
//!
//! `VoxelWorld` is the only `bevy::Resource` in this module — everything else
//! is a plain serde-friendly value type. The Bevy plugin layer in
//! `voxel::plugin` owns scheduling; this file owns truth.

use std::collections::{BTreeMap, BTreeSet};

use bevy::prelude::Resource;
use serde::{Deserialize, Serialize};

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCoord, Rotation, VoxelMaterialId,
    is_micro_coord_in_bounds, micro_coord_from_index, micro_linear_index,
};
use crate::voxel::prefab::{
    LocalPrefab, LocalPrefabRegistry,
    boundary::{
        BoundarySnapPlaceResult, BoundarySnapPreview, BoundarySnapRequest, contact_face_center,
        contact_slots_for_face, is_axis_normal, opposite_normal,
    },
    definition::{PrefabCellData, PrefabRasterCell},
};

use super::hotbar::{HotbarState, hotbar_entries};
use super::snapshot::{SnapshotCell, WorldSnapshot};

/// Normal macro-cell block payload.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalBlockData {
    pub material_id: VoxelMaterialId,
    pub state_flags: u16,
    pub health: u16,
    pub temperature_delta: i16,
    pub moisture_delta: i16,
}

impl NormalBlockData {
    /// Builds a healthy block using the material's default health.
    pub fn new(material_id: VoxelMaterialId) -> Self {
        Self {
            material_id,
            state_flags: 0,
            health: material_id.max_health(),
            temperature_delta: 0,
            moisture_delta: 0,
        }
    }
}

/// Refined cell payload with per-slot material/state/part metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefinedCellData {
    pub micro_occupancy_mask: MicroMask,
    pub micro_material_ids: Vec<VoxelMaterialId>,
    pub micro_state_flags: Vec<u16>,
    pub micro_part_ids: Vec<i32>,
    pub prefab_instance_ids: Vec<u32>,
    pub boundary_cache: u32,
}

impl RefinedCellData {
    /// Builds an empty refined cell.
    pub fn empty() -> Self {
        Self {
            micro_occupancy_mask: MicroMask::empty(),
            micro_material_ids: vec![VoxelMaterialId::Dirt; MICRO_GRID_SLOT_COUNT],
            micro_state_flags: vec![0; MICRO_GRID_SLOT_COUNT],
            micro_part_ids: vec![-1; MICRO_GRID_SLOT_COUNT],
            prefab_instance_ids: Vec::new(),
            boundary_cache: 0,
        }
    }

    /// Builds a full refined cell from a normal macro block.
    pub fn from_block(block: NormalBlockData) -> Self {
        Self {
            micro_occupancy_mask: MicroMask::full(),
            micro_material_ids: vec![block.material_id; MICRO_GRID_SLOT_COUNT],
            micro_state_flags: vec![block.state_flags; MICRO_GRID_SLOT_COUNT],
            micro_part_ids: vec![-1; MICRO_GRID_SLOT_COUNT],
            prefab_instance_ids: Vec::new(),
            boundary_cache: 0,
        }
    }

    /// Counts occupied micro slots.
    pub fn occupied_slot_count(&self) -> u32 {
        self.micro_occupancy_mask.occupied_slot_count()
    }

    fn set_micro(&mut self, coord: MicroCoord, block: NormalBlockData) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        self.micro_occupancy_mask.set_index(index);
        self.micro_material_ids[index] = block.material_id;
        self.micro_state_flags[index] = block.state_flags;
        true
    }

    fn clear_micro(&mut self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        if !self.micro_occupancy_mask.contains_index(index) {
            return false;
        }
        self.micro_occupancy_mask.clear(coord);
        self.micro_material_ids[index] = VoxelMaterialId::Dirt;
        self.micro_state_flags[index] = 0;
        self.micro_part_ids[index] = -1;
        true
    }

    fn micro_block(&self, coord: MicroCoord) -> Option<NormalBlockData> {
        let index = micro_linear_index(coord)?;
        self.micro_occupancy_mask
            .contains_index(index)
            .then(|| NormalBlockData {
                material_id: self.micro_material_ids[index],
                state_flags: self.micro_state_flags[index],
                health: 100,
                temperature_delta: 0,
                moisture_delta: 0,
            })
    }

    fn merge_prefab_cell(&mut self, incoming: &PrefabCellData, instance_id: u32) -> Result<(), ()> {
        if self
            .micro_occupancy_mask
            .overlaps(incoming.micro_occupancy_mask)
        {
            return Err(());
        }
        self.micro_occupancy_mask = self
            .micro_occupancy_mask
            .union(incoming.micro_occupancy_mask);
        for index in incoming.micro_occupancy_mask.indices() {
            self.micro_material_ids[index] = incoming.micro_material_ids[index];
            self.micro_state_flags[index] = incoming.micro_state_flags[index];
            self.micro_part_ids[index] = incoming.micro_part_ids[index];
        }
        if !self.prefab_instance_ids.contains(&instance_id) {
            self.prefab_instance_ids.push(instance_id);
            self.prefab_instance_ids.sort_unstable();
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
enum CellData {
    Normal(NormalBlockData),
    Refined(RefinedCellData),
}

/// Placed prefab instance metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabInstanceData {
    pub instance_id: u32,
    pub prefab_id: String,
    pub anchor_micro_coord: MicroCoord,
    pub rotation: Rotation,
    pub covered_macro_min: MacroCoord,
    pub covered_macro_max: MacroCoord,
}

/// Local edit counters exposed through CLI snapshots.
#[derive(Debug, Copy, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditStats {
    pub placed: u32,
    pub broken: u32,
    pub rejected: u32,
    pub conflicts: u32,
    pub prefab_placed: u32,
}

/// One occupied voxel render/picking cell for Bevy presentation.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub struct VoxelRenderCell {
    pub macro_coord: MacroCoord,
    pub micro: Option<MicroCoord>,
    pub material_id: VoxelMaterialId,
    pub refined: bool,
}

/// Result of a prefab placement operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefabPlaceResult {
    pub ok: bool,
    pub placed: u32,
    pub instance_id: Option<u32>,
    pub conflict: bool,
}

impl PrefabPlaceResult {
    fn rejected(conflict: bool) -> Self {
        Self {
            ok: false,
            placed: 0,
            instance_id: None,
            conflict,
        }
    }
}

/// Local voxel world including storage, prefabs, hotbar, and edit stats.
#[derive(Debug, Clone, Resource)]
pub struct VoxelWorld {
    cells: BTreeMap<MacroCoord, CellData>,
    prefab_instances: BTreeMap<u32, PrefabInstanceData>,
    registry: LocalPrefabRegistry,
    edit_stats: EditStats,
    selected_hotbar_index: usize,
    next_instance_id: u32,
}

impl VoxelWorld {
    /// Builds an empty offline-local world with built-in prefabs.
    pub fn new() -> Self {
        Self {
            cells: BTreeMap::new(),
            prefab_instances: BTreeMap::new(),
            registry: LocalPrefabRegistry::with_builtins(),
            edit_stats: EditStats::default(),
            selected_hotbar_index: 0,
            next_instance_id: 1,
        }
    }

    /// Seeds a small local showcase plane for interactive exploration.
    pub fn bootstrap_showcase(&mut self, radius: i32) {
        for x in -radius..=radius {
            for z in -radius..=radius {
                let material = if (x + z).rem_euclid(2) == 0 {
                    VoxelMaterialId::Dirt
                } else {
                    VoxelMaterialId::Stone
                };
                let _ = self.place_block(MacroCoord::new(x, 0, z), NormalBlockData::new(material));
            }
        }
    }

    /// Returns edit stats.
    pub fn edit_stats(&self) -> EditStats {
        self.edit_stats
    }

    /// Returns the current hotbar state.
    pub fn hotbar(&self) -> HotbarState {
        let entries = hotbar_entries();
        let selected = entries[self.selected_hotbar_index].clone();
        HotbarState {
            entries,
            selected_index: self.selected_hotbar_index,
            selected,
        }
    }

    /// Selects a one-based browser hotbar index converted by the caller to zero-based.
    pub fn select_hotbar_index(&mut self, index: usize) -> Result<(), String> {
        if index >= hotbar_entries().len() {
            self.edit_stats.rejected += 1;
            return Err(format!("hotbar index out of range: {}", index + 1));
        }
        self.selected_hotbar_index = index;
        Ok(())
    }

    /// Selects the material entry matching the given material.
    pub fn select_material(&mut self, material_id: VoxelMaterialId) {
        if let Some(index) = hotbar_entries()
            .iter()
            .position(|entry| entry.material_id == Some(material_id))
        {
            self.selected_hotbar_index = index;
        }
    }

    /// Selects the prefab entry matching the given prefab name.
    pub fn select_prefab(&mut self, prefab_name: &str) -> Result<(), String> {
        if self.registry.get(prefab_name).is_none() {
            self.edit_stats.rejected += 1;
            return Err(format!("unknown prefab: {prefab_name}"));
        }
        if let Some(index) = hotbar_entries()
            .iter()
            .position(|entry| entry.prefab_name.as_deref() == Some(prefab_name))
        {
            self.selected_hotbar_index = index;
        }
        Ok(())
    }

    /// Places a normal block into an empty macro cell.
    pub fn place_block(&mut self, coord: MacroCoord, block: NormalBlockData) -> bool {
        if self.cells.contains_key(&coord) {
            self.edit_stats.rejected += 1;
            self.edit_stats.conflicts += 1;
            return false;
        }
        self.cells.insert(coord, CellData::Normal(block));
        self.edit_stats.placed += 1;
        true
    }

    /// Breaks any cell at the macro coordinate.
    pub fn break_block(&mut self, coord: MacroCoord) -> bool {
        if self.cells.remove(&coord).is_some() {
            self.edit_stats.broken += 1;
            true
        } else {
            self.edit_stats.rejected += 1;
            false
        }
    }

    /// Returns a normal block only when the macro cell is stored as a normal block.
    pub fn normal_block(&self, coord: MacroCoord) -> Option<NormalBlockData> {
        match self.cells.get(&coord) {
            Some(CellData::Normal(block)) => Some(*block),
            _ => None,
        }
    }

    /// Returns a refined cell, converting normal blocks to full refined cells for read-only use.
    pub fn refined_cell(&self, coord: MacroCoord) -> Option<RefinedCellData> {
        match self.cells.get(&coord) {
            Some(CellData::Normal(block)) => Some(RefinedCellData::from_block(*block)),
            Some(CellData::Refined(cell)) => Some(cell.clone()),
            None => None,
        }
    }

    /// Returns a micro block from normal or refined storage.
    pub fn micro_block(
        &self,
        macro_coord: MacroCoord,
        micro: MicroCoord,
    ) -> Option<NormalBlockData> {
        match self.cells.get(&macro_coord) {
            Some(CellData::Normal(block)) if is_micro_coord_in_bounds(micro) => Some(*block),
            Some(CellData::Refined(cell)) => cell.micro_block(micro),
            _ => None,
        }
    }

    /// Sets one refined micro block. Normal cells are converted to full refined cells first.
    pub fn set_micro_block(
        &mut self,
        macro_coord: MacroCoord,
        micro: MicroCoord,
        block: NormalBlockData,
    ) -> bool {
        if !is_micro_coord_in_bounds(micro) {
            self.edit_stats.rejected += 1;
            return false;
        }

        let mut refined = match self.cells.remove(&macro_coord) {
            Some(CellData::Normal(existing)) => RefinedCellData::from_block(existing),
            Some(CellData::Refined(existing)) => existing,
            None => RefinedCellData::empty(),
        };
        let ok = refined.set_micro(micro, block);
        self.cells.insert(macro_coord, CellData::Refined(refined));
        if ok {
            self.edit_stats.placed += 1;
        } else {
            self.edit_stats.rejected += 1;
        }
        ok
    }

    /// Clears one refined micro block. Normal cells are converted to full refined cells first.
    pub fn clear_micro_block(&mut self, macro_coord: MacroCoord, micro: MicroCoord) -> bool {
        if !is_micro_coord_in_bounds(micro) {
            self.edit_stats.rejected += 1;
            return false;
        }

        let Some(current) = self.cells.remove(&macro_coord) else {
            self.edit_stats.rejected += 1;
            return false;
        };

        let mut refined = match current {
            CellData::Normal(block) => RefinedCellData::from_block(block),
            CellData::Refined(cell) => cell,
        };

        if !refined.clear_micro(micro) {
            self.cells.insert(macro_coord, CellData::Refined(refined));
            self.edit_stats.rejected += 1;
            return false;
        }

        if !refined.micro_occupancy_mask.is_empty() {
            self.cells.insert(macro_coord, CellData::Refined(refined));
        }
        self.edit_stats.broken += 1;
        true
    }

    /// Lists all registered prefabs.
    pub fn list_prefabs(&self) -> Vec<LocalPrefab> {
        self.registry.list()
    }

    /// Returns a registered prefab.
    pub fn prefab(&self, name: &str) -> Option<LocalPrefab> {
        self.registry.get(name).cloned()
    }

    /// Captures normal cells into a local prefab.
    pub fn capture_prefab(&mut self, name: &str, min: MacroCoord, max: MacroCoord) -> LocalPrefab {
        let (low, high, bounds) = LocalPrefabRegistry::capture_bounds(min, max);
        let mut blocks = Vec::new();
        for x in low.x..=high.x {
            for y in low.y..=high.y {
                for z in low.z..=high.z {
                    let coord = MacroCoord::new(x, y, z);
                    if let Some(CellData::Normal(block)) = self.cells.get(&coord) {
                        blocks.push((
                            MacroCoord::new(x - low.x, y - low.y, z - low.z),
                            block.material_id,
                        ));
                    }
                }
            }
        }
        self.registry.capture(name, bounds, &blocks)
    }

    /// Places a prefab at a macro origin.
    pub fn place_prefab(
        &mut self,
        name: &str,
        origin: MacroCoord,
        rotation: Rotation,
    ) -> PrefabPlaceResult {
        let Some(prefab) = self.registry.get(name).cloned() else {
            self.edit_stats.rejected += 1;
            return PrefabPlaceResult::rejected(false);
        };
        let raster = prefab.rasterize(origin, rotation);
        // Legacy macro-aligned placement anchors the prefab's local (0,0,0).
        self.commit_prefab_raster(&prefab.name, rotation, MicroCoord::new(0, 0, 0), raster)
    }

    /// Previews socket-free micro boundary snapping.
    ///
    /// Dispatches on `request.anchor_micro`:
    /// - `Some(target)` (design 2026-04-26 prefab-micro-snap): the
    ///   prefab's contact-face centre micro is positioned at
    ///   `target`'s world micro coord. The resulting raster may span
    ///   multiple destination macros. Works against any existing voxel
    ///   (refined OR fully-occupied normal macro) — the no-refined-cell
    ///   short-circuit only applies to the legacy path.
    /// - `None` (legacy): macro-aligned anchor, requires hit_macro to be
    ///   a refined cell. Behaviour byte-equal to pre-2026-04-26.
    pub fn preview_prefab_boundary_snap(
        &self,
        request: &BoundarySnapRequest,
    ) -> BoundarySnapPreview {
        let Some(prefab) = self.registry.get(&request.prefab_name).cloned() else {
            return BoundarySnapPreview::rejected(request, "unknown_prefab");
        };
        if !is_axis_normal(request.face_normal) {
            return BoundarySnapPreview::rejected(request, "invalid_face_normal");
        }

        if let Some(target) = request.anchor_micro {
            return self.preview_micro_anchored(&prefab, request, target);
        }

        // Legacy macro-aligned path.
        if self.refined_cell(request.hit_macro).is_none() {
            return BoundarySnapPreview::rejected(request, "no_target_boundary");
        }

        let origin = request.hit_macro.offset(request.face_normal);
        let raster = prefab.rasterize(origin, request.rotation);
        let overlap_slots = raster
            .iter()
            .map(|cell| {
                self.refined_cell(cell.macro_coord)
                    .map(|existing| {
                        existing
                            .micro_occupancy_mask
                            .overlap_count(cell.data.micro_occupancy_mask)
                    })
                    .unwrap_or(0)
            })
            .sum();
        let contact_slots = if overlap_slots == 0 {
            contact_slots_for_face(&prefab, opposite_normal(request.face_normal))
        } else {
            0
        };

        BoundarySnapPreview {
            ok: overlap_slots == 0 && contact_slots > 0,
            prefab_id: request.prefab_name.clone(),
            hit_macro: request.hit_macro,
            face_normal: request.face_normal,
            anchor_micro_coord: Some(MicroCoord::new(0, 0, 0)),
            affected_macro_count: raster.len() as u32,
            incoming_occupied_slots: raster
                .iter()
                .map(|cell| cell.data.micro_occupancy_mask.occupied_slot_count())
                .sum(),
            overlap_slots,
            contact_slots,
            reject_reason: if overlap_slots > 0 {
                Some("micro_overlap".to_string())
            } else if contact_slots == 0 {
                Some("no_contact".to_string())
            } else {
                None
            },
            cells: raster,
        }
    }

    fn preview_micro_anchored(
        &self,
        prefab: &LocalPrefab,
        request: &BoundarySnapRequest,
        target: crate::voxel::core::MicroCellTarget,
    ) -> BoundarySnapPreview {
        // Origin macro: the macro adjacent to hit_macro along face_normal.
        // Rasterising at `origin` then shifting puts the prefab's contact-
        // face centre micro at the user's target micro.
        let origin = request.hit_macro.offset(request.face_normal);
        let prefab_local = contact_face_center(prefab, request.face_normal, request.rotation);

        let target_world_x = target.macro_coord.x * MICRO_PER_MACRO + target.micro.x;
        let target_world_y = target.macro_coord.y * MICRO_PER_MACRO + target.micro.y;
        let target_world_z = target.macro_coord.z * MICRO_PER_MACRO + target.micro.z;
        let origin_world_x = origin.x * MICRO_PER_MACRO + prefab_local.x;
        let origin_world_y = origin.y * MICRO_PER_MACRO + prefab_local.y;
        let origin_world_z = origin.z * MICRO_PER_MACRO + prefab_local.z;
        let shift_x = target_world_x - origin_world_x;
        let shift_y = target_world_y - origin_world_y;
        let shift_z = target_world_z - origin_world_z;

        let raster =
            prefab.rasterize_with_micro_shift(origin, request.rotation, shift_x, shift_y, shift_z);

        // Overlap: any prefab micro slot that lands on an existing
        // occupied micro (refined OR fully-occupied normal macro).
        let overlap_slots: u32 = raster
            .iter()
            .map(|cell| self.cell_micro_overlap_count(cell))
            .sum();

        // Contact: any prefab micro slot whose neighbour in -face_normal
        // direction is occupied in the world.
        let contact_slots = if overlap_slots == 0 {
            self.compute_micro_contact_slots(&raster, request.face_normal)
        } else {
            0
        };

        BoundarySnapPreview {
            ok: overlap_slots == 0 && contact_slots > 0,
            prefab_id: request.prefab_name.clone(),
            hit_macro: request.hit_macro,
            face_normal: request.face_normal,
            anchor_micro_coord: Some(target.micro),
            affected_macro_count: raster.len() as u32,
            incoming_occupied_slots: raster
                .iter()
                .map(|cell| cell.data.micro_occupancy_mask.occupied_slot_count())
                .sum(),
            overlap_slots,
            contact_slots,
            reject_reason: if overlap_slots > 0 {
                Some("micro_overlap".to_string())
            } else if contact_slots == 0 {
                Some("no_contact".to_string())
            } else {
                None
            },
            cells: raster,
        }
    }

    /// Counts prefab micro slots in `cell` that overlap an existing
    /// occupied micro at the same world position. Treats normal macros
    /// as fully occupied and refined macros via their micro mask.
    fn cell_micro_overlap_count(&self, cell: &PrefabRasterCell) -> u32 {
        match self.cells.get(&cell.macro_coord) {
            None => 0,
            Some(CellData::Normal(_)) => cell.data.micro_occupancy_mask.occupied_slot_count(),
            Some(CellData::Refined(refined)) => refined
                .micro_occupancy_mask
                .overlap_count(cell.data.micro_occupancy_mask),
        }
    }

    /// Counts prefab micro slots whose -face_normal neighbour (1 micro
    /// in the opposite direction of the user's click) is occupied in the
    /// world. ≥1 means the prefab is touching the existing structure.
    fn compute_micro_contact_slots(
        &self,
        raster: &[PrefabRasterCell],
        face_normal: MacroCoord,
    ) -> u32 {
        let mut count = 0u32;
        for cell in raster {
            for slot_index in cell.data.micro_occupancy_mask.indices() {
                let Some(local) = micro_coord_from_index(slot_index) else {
                    continue;
                };
                // World micro coord of this slot.
                let wx = cell.macro_coord.x * MICRO_PER_MACRO + local.x;
                let wy = cell.macro_coord.y * MICRO_PER_MACRO + local.y;
                let wz = cell.macro_coord.z * MICRO_PER_MACRO + local.z;
                // Neighbour in -face_normal direction.
                let nwx = wx - face_normal.x;
                let nwy = wy - face_normal.y;
                let nwz = wz - face_normal.z;
                let neighbour_macro = MacroCoord::new(
                    nwx.div_euclid(MICRO_PER_MACRO),
                    nwy.div_euclid(MICRO_PER_MACRO),
                    nwz.div_euclid(MICRO_PER_MACRO),
                );
                let neighbour_micro = MicroCoord::new(
                    nwx.rem_euclid(MICRO_PER_MACRO),
                    nwy.rem_euclid(MICRO_PER_MACRO),
                    nwz.rem_euclid(MICRO_PER_MACRO),
                );
                if self.world_micro_occupied(neighbour_macro, neighbour_micro) {
                    count += 1;
                }
            }
        }
        count
    }

    fn world_micro_occupied(&self, macro_coord: MacroCoord, micro: MicroCoord) -> bool {
        match self.cells.get(&macro_coord) {
            None => false,
            Some(CellData::Normal(_)) => true,
            Some(CellData::Refined(refined)) => refined.micro_occupancy_mask.contains(micro),
        }
    }

    /// Commits a socket-free micro boundary snap.
    pub fn place_prefab_boundary_snap(
        &mut self,
        request: &BoundarySnapRequest,
    ) -> BoundarySnapPlaceResult {
        let preview = self.preview_prefab_boundary_snap(request);
        if !preview.ok {
            self.edit_stats.rejected += 1;
            if preview.overlap_slots > 0 {
                self.edit_stats.conflicts += 1;
            }
            return BoundarySnapPlaceResult {
                ok: false,
                conflict: preview.overlap_slots > 0,
                instance_id: None,
                preview: Some(preview),
            };
        }

        let result = self.commit_prefab_raster(
            &request.prefab_name,
            request.rotation,
            preview
                .anchor_micro_coord
                .unwrap_or_else(|| MicroCoord::new(0, 0, 0)),
            preview.cells.clone(),
        );
        BoundarySnapPlaceResult {
            ok: result.ok,
            conflict: result.conflict,
            instance_id: result.instance_id,
            preview: Some(preview),
        }
    }

    /// Exports a deterministic local snapshot.
    pub fn export_snapshot(&self) -> WorldSnapshot {
        let cells = self
            .cells
            .iter()
            .map(|(macro_coord, cell)| match cell {
                CellData::Normal(normal) => SnapshotCell {
                    macro_coord: *macro_coord,
                    normal: Some(*normal),
                    refined: None,
                },
                CellData::Refined(refined) => SnapshotCell {
                    macro_coord: *macro_coord,
                    normal: None,
                    refined: Some(refined.clone()),
                },
            })
            .collect();
        WorldSnapshot {
            version: 1,
            cells,
            prefab_instances: self.prefab_instances.values().cloned().collect(),
            edit_stats: self.edit_stats,
        }
    }

    /// Builds a world from a snapshot.
    pub fn from_snapshot(snapshot: WorldSnapshot) -> Result<Self, String> {
        let mut world = Self::new();
        world.import_snapshot(snapshot)?;
        Ok(world)
    }

    /// Imports a local snapshot, replacing current world truth.
    pub fn import_snapshot(&mut self, snapshot: WorldSnapshot) -> Result<(), String> {
        if snapshot.version != 1 {
            return Err(format!(
                "unsupported voxel snapshot version {}",
                snapshot.version
            ));
        }
        self.cells.clear();
        for cell in snapshot.cells {
            match (cell.normal, cell.refined) {
                (Some(normal), None) => {
                    self.cells
                        .insert(cell.macro_coord, CellData::Normal(normal));
                }
                (None, Some(refined)) => {
                    self.cells
                        .insert(cell.macro_coord, CellData::Refined(refined));
                }
                _ => return Err("snapshot cell must contain exactly one payload".to_string()),
            }
        }
        self.prefab_instances = snapshot
            .prefab_instances
            .into_iter()
            .map(|instance| (instance.instance_id, instance))
            .collect();
        self.next_instance_id = self
            .prefab_instances
            .keys()
            .next_back()
            .map(|value| value + 1)
            .unwrap_or(1);
        self.edit_stats = snapshot.edit_stats;
        Ok(())
    }

    /// Counts non-empty macro cells.
    pub fn total_solid_cells(&self) -> usize {
        self.cells.len()
    }

    /// Returns the set of all occupied macro coordinates.
    pub fn occupied_macro_set(&self) -> BTreeSet<MacroCoord> {
        self.cells.keys().copied().collect()
    }

    /// Returns deterministic summaries for CLI rendering.
    pub fn cell_summaries(&self) -> Vec<(MacroCoord, &'static str, u32)> {
        self.cells
            .iter()
            .map(|(coord, cell)| match cell {
                CellData::Normal(_) => (*coord, "normal", MICRO_GRID_SLOT_COUNT as u32),
                CellData::Refined(refined) => (*coord, "refined", refined.occupied_slot_count()),
            })
            .collect()
    }

    /// Returns all occupied render cells for the Bevy 3D presentation layer.
    ///
    /// Normal macro blocks are returned as one full macro cube. Refined cells
    /// return one cell per occupied micro slot so rendering, ray picking, and
    /// prefab preview all observe the same geometry truth as the browser
    /// client.
    pub fn render_cells_3d(&self) -> Vec<VoxelRenderCell> {
        let mut cells = Vec::new();
        for (macro_coord, cell) in &self.cells {
            match cell {
                CellData::Normal(block) => cells.push(VoxelRenderCell {
                    macro_coord: *macro_coord,
                    micro: None,
                    material_id: block.material_id,
                    refined: false,
                }),
                CellData::Refined(refined) => {
                    cells.extend(refined.micro_occupancy_mask.indices().filter_map(|index| {
                        let micro = micro_coord_from_index(index)?;
                        Some(VoxelRenderCell {
                            macro_coord: *macro_coord,
                            micro: Some(micro),
                            material_id: refined.micro_material_ids[index],
                            refined: true,
                        })
                    }));
                }
            }
        }
        cells
    }

    /// Returns top-down render cells for compatibility diagnostics.
    pub fn top_down_render_cells(&self) -> Vec<VoxelRenderCell> {
        let mut cells = Vec::new();
        for (macro_coord, cell) in &self.cells {
            match cell {
                CellData::Normal(block) => cells.push(VoxelRenderCell {
                    macro_coord: *macro_coord,
                    micro: None,
                    material_id: block.material_id,
                    refined: false,
                }),
                CellData::Refined(refined) => {
                    let mut top_by_column: BTreeMap<(i32, i32), (i32, usize)> = BTreeMap::new();
                    for index in refined.micro_occupancy_mask.indices() {
                        let Some(micro) = micro_coord_from_index(index) else {
                            continue;
                        };
                        top_by_column
                            .entry((micro.x, micro.z))
                            .and_modify(|(top_y, top_index)| {
                                if micro.y > *top_y {
                                    *top_y = micro.y;
                                    *top_index = index;
                                }
                            })
                            .or_insert((micro.y, index));
                    }
                    cells.extend(top_by_column.into_iter().filter_map(
                        |((_x, _z), (_y, index))| {
                            let micro = micro_coord_from_index(index)?;
                            Some(VoxelRenderCell {
                                macro_coord: *macro_coord,
                                micro: Some(micro),
                                material_id: refined.micro_material_ids[index],
                                refined: true,
                            })
                        },
                    ));
                }
            }
        }
        cells
    }

    fn commit_prefab_raster(
        &mut self,
        prefab_name: &str,
        rotation: Rotation,
        anchor_micro_coord: MicroCoord,
        raster: Vec<PrefabRasterCell>,
    ) -> PrefabPlaceResult {
        if raster.is_empty() {
            self.edit_stats.rejected += 1;
            return PrefabPlaceResult::rejected(false);
        }

        let conflict = raster.iter().any(|cell| {
            self.refined_cell(cell.macro_coord)
                .map(|existing| {
                    existing
                        .micro_occupancy_mask
                        .overlaps(cell.data.micro_occupancy_mask)
                })
                .unwrap_or(false)
        });
        if conflict {
            self.edit_stats.rejected += 1;
            self.edit_stats.conflicts += 1;
            return PrefabPlaceResult::rejected(true);
        }

        let instance_id = self.next_instance_id;
        self.next_instance_id += 1;

        for cell in &raster {
            let mut refined = match self.cells.remove(&cell.macro_coord) {
                Some(CellData::Normal(block)) => RefinedCellData::from_block(block),
                Some(CellData::Refined(existing)) => existing,
                None => RefinedCellData::empty(),
            };
            if refined.merge_prefab_cell(&cell.data, instance_id).is_err() {
                self.cells
                    .insert(cell.macro_coord, CellData::Refined(refined));
                self.edit_stats.rejected += 1;
                self.edit_stats.conflicts += 1;
                return PrefabPlaceResult::rejected(true);
            }
            self.cells
                .insert(cell.macro_coord, CellData::Refined(refined));
        }

        let covered_macro_min = raster
            .iter()
            .map(|cell| cell.macro_coord)
            .reduce(crate::voxel::core::coord::min_macro_coord)
            .unwrap_or(MacroCoord::new(0, 0, 0));
        let covered_macro_max = raster
            .iter()
            .map(|cell| cell.macro_coord)
            .reduce(crate::voxel::core::coord::max_macro_coord)
            .unwrap_or(MacroCoord::new(0, 0, 0));
        self.prefab_instances.insert(
            instance_id,
            PrefabInstanceData {
                instance_id,
                prefab_id: prefab_name.to_string(),
                anchor_micro_coord,
                rotation,
                covered_macro_min,
                covered_macro_max,
            },
        );

        self.edit_stats.prefab_placed += 1;
        PrefabPlaceResult {
            ok: true,
            placed: raster.len() as u32,
            instance_id: Some(instance_id),
            conflict: false,
        }
    }
}

impl Default for VoxelWorld {
    fn default() -> Self {
        Self::new()
    }
}
