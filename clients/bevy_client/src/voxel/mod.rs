//! Offline-local voxel world for the Bevy client.
//!
//! This module mirrors the browser client's current voxel boundary: local
//! macro cells, refined `8x8x8` micro occupancy, built-in prefabs, hotbar
//! selection, and snapshot import/export. Server authority is intentionally
//! not mixed into this storage layer.

use bevy::prelude::Resource;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};

/// Number of refined micro cells per macro-cell axis.
pub const MICRO_PER_MACRO: i32 = 8;
/// Total refined micro slots in one macro cell.
pub const MICRO_GRID_SLOT_COUNT: usize = 512;
const MICRO_MASK_WORDS: usize = MICRO_GRID_SLOT_COUNT / 64;

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
/// Integer macro-cell coordinate.
pub struct MacroCoord {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

impl MacroCoord {
    /// Builds a macro coordinate.
    pub const fn new(x: i32, y: i32, z: i32) -> Self {
        Self { x, y, z }
    }

    fn offset(self, other: MacroCoord) -> Self {
        Self::new(self.x + other.x, self.y + other.y, self.z + other.z)
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
/// Integer refined micro coordinate local to one macro cell.
pub struct MicroCoord {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

impl MicroCoord {
    /// Builds a micro coordinate.
    pub const fn new(x: i32, y: i32, z: i32) -> Self {
        Self { x, y, z }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
/// Browser-compatible voxel material identifiers.
pub enum VoxelMaterialId {
    Dirt = 1,
    Stone = 2,
    Wood = 3,
    Ice = 4,
}

impl VoxelMaterialId {
    /// Parses a material id or browser CLI material name.
    pub fn parse(value: &str) -> Option<Self> {
        match value.to_ascii_lowercase().as_str() {
            "1" | "dirt" => Some(Self::Dirt),
            "2" | "stone" => Some(Self::Stone),
            "3" | "wood" => Some(Self::Wood),
            "4" | "ice" => Some(Self::Ice),
            _ => None,
        }
    }

    /// Returns the stable browser CLI material label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Dirt => "dirt",
            Self::Stone => "stone",
            Self::Wood => "wood",
            Self::Ice => "ice",
        }
    }

    fn max_health(self) -> u16 {
        match self {
            Self::Dirt => 80,
            Self::Stone => 160,
            Self::Wood => 100,
            Self::Ice => 70,
        }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Normal macro-cell block payload.
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

#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Supported prefab rotations around the vertical axis.
pub enum Rotation {
    Rot0 = 0,
    Rot90 = 1,
    Rot180 = 2,
    Rot270 = 3,
}

impl Rotation {
    /// Parses browser-style rotation arguments.
    pub fn parse(value: Option<&str>) -> Option<Self> {
        match value.map(str::to_ascii_lowercase).as_deref() {
            None | Some("0" | "rot0") => Some(Self::Rot0),
            Some("90" | "rot90") => Some(Self::Rot90),
            Some("180" | "rot180") => Some(Self::Rot180),
            Some("270" | "rot270") => Some(Self::Rot270),
            _ => None,
        }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Fixed 512-bit micro occupancy mask stored as eight little-endian u64 words.
pub struct MicroMask {
    words: [u64; MICRO_MASK_WORDS],
}

impl MicroMask {
    /// Empty occupancy.
    pub const fn empty() -> Self {
        Self {
            words: [0; MICRO_MASK_WORDS],
        }
    }

    /// Full macro occupancy.
    pub const fn full() -> Self {
        Self {
            words: [u64::MAX; MICRO_MASK_WORDS],
        }
    }

    /// Returns true when no micro slots are occupied.
    pub fn is_empty(self) -> bool {
        self.words.iter().all(|word| *word == 0)
    }

    /// Counts occupied micro slots.
    pub fn occupied_slot_count(self) -> u32 {
        self.words.iter().map(|word| word.count_ones()).sum()
    }

    /// Returns whether a local micro coord is occupied.
    pub fn contains(self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        self.contains_index(index)
    }

    fn contains_index(self, index: usize) -> bool {
        let word = index / 64;
        let bit = index % 64;
        (self.words[word] & (1_u64 << bit)) != 0
    }

    fn set(&mut self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        self.set_index(index);
        true
    }

    fn set_index(&mut self, index: usize) {
        let word = index / 64;
        let bit = index % 64;
        self.words[word] |= 1_u64 << bit;
    }

    fn clear(&mut self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        let word = index / 64;
        let bit = index % 64;
        self.words[word] &= !(1_u64 << bit);
        true
    }

    fn overlaps(self, other: Self) -> bool {
        self.words
            .iter()
            .zip(other.words)
            .any(|(left, right)| (*left & right) != 0)
    }

    fn overlap_count(self, other: Self) -> u32 {
        self.words
            .iter()
            .zip(other.words)
            .map(|(left, right)| (*left & right).count_ones())
            .sum()
    }

    fn union(self, other: Self) -> Self {
        let mut words = [0; MICRO_MASK_WORDS];
        for (index, word) in words.iter_mut().enumerate() {
            *word = self.words[index] | other.words[index];
        }
        Self { words }
    }

    fn indices(self) -> impl Iterator<Item = usize> {
        self.words
            .into_iter()
            .enumerate()
            .flat_map(|(word_index, word)| {
                (0..64).filter_map(move |bit| {
                    ((word & (1_u64 << bit)) != 0).then_some(word_index * 64 + bit)
                })
            })
    }
}

impl Default for MicroMask {
    fn default() -> Self {
        Self::empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Refined cell payload with per-slot material/state/part metadata.
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Placed prefab instance metadata.
pub struct PrefabInstanceData {
    pub instance_id: u32,
    pub prefab_id: String,
    pub anchor_micro_coord: MicroCoord,
    pub rotation: Rotation,
    pub covered_macro_min: MacroCoord,
    pub covered_macro_max: MacroCoord,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Serializable voxel world snapshot.
pub struct WorldSnapshot {
    pub version: u32,
    pub cells: Vec<SnapshotCell>,
    pub prefab_instances: Vec<PrefabInstanceData>,
    pub edit_stats: EditStats,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Serializable non-empty world cell.
pub struct SnapshotCell {
    pub macro_coord: MacroCoord,
    pub normal: Option<NormalBlockData>,
    pub refined: Option<RefinedCellData>,
}

#[derive(Debug, Copy, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
/// Local edit counters exposed through CLI snapshots.
pub struct EditStats {
    pub placed: u32,
    pub broken: u32,
    pub rejected: u32,
    pub conflicts: u32,
    pub prefab_placed: u32,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Hotbar entry class.
pub enum HotbarEntryKind {
    Material,
    Prefab,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Browser-compatible hotbar entry.
pub struct HotbarEntry {
    pub kind: HotbarEntryKind,
    pub label: String,
    pub material_id: Option<VoxelMaterialId>,
    pub prefab_name: Option<String>,
    pub rotation: Rotation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Current hotbar state.
pub struct HotbarState {
    pub entries: Vec<HotbarEntry>,
    pub selected_index: usize,
    pub selected: HotbarEntry,
}

#[derive(Debug, Clone, Resource)]
/// Local voxel world including storage, prefabs, hotbar, and edit stats.
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
        self.registry.capture(name, min, max, &self.cells)
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
        self.commit_prefab_raster(&prefab.name, rotation, raster)
    }

    /// Previews socket-free micro boundary snapping.
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
    /// prefab preview all observe the same geometry truth as the browser client.
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
            .reduce(min_macro_coord)
            .unwrap_or(MacroCoord::new(0, 0, 0));
        let covered_macro_max = raster
            .iter()
            .map(|cell| cell.macro_coord)
            .reduce(max_macro_coord)
            .unwrap_or(MacroCoord::new(0, 0, 0));
        self.prefab_instances.insert(
            instance_id,
            PrefabInstanceData {
                instance_id,
                prefab_id: prefab_name.to_string(),
                anchor_micro_coord: MicroCoord::new(0, 0, 0),
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

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
/// One occupied voxel render/picking cell for Bevy presentation.
pub struct VoxelRenderCell {
    pub macro_coord: MacroCoord,
    pub micro: Option<MicroCoord>,
    pub material_id: VoxelMaterialId,
    pub refined: bool,
}

impl Default for VoxelWorld {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Result of a prefab placement operation.
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Socket-free boundary snap request.
pub struct BoundarySnapRequest {
    pub prefab_name: String,
    pub hit_macro: MacroCoord,
    pub face_normal: MacroCoord,
    pub rotation: Rotation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Socket-free boundary snap preview.
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
    fn rejected(request: &BoundarySnapRequest, reason: &str) -> Self {
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Result of committing a boundary snap operation.
pub struct BoundarySnapPlaceResult {
    pub ok: bool,
    pub conflict: bool,
    pub instance_id: Option<u32>,
    pub preview: Option<BoundarySnapPreview>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Runtime prefab definition.
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

    fn rasterize(&self, origin: MacroCoord, rotation: Rotation) -> Vec<PrefabRasterCell> {
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Runtime prefab definition payload.
pub struct PrefabDefinitionData {
    pub prefab_id: String,
    pub bounds_in_macro_cells: MacroCoord,
    pub micro_resolution: i32,
    pub cells: Vec<PrefabDefinitionCell>,
    pub part_definitions: Vec<PrefabPartDefinition>,
    pub allowed_rotations: Vec<Rotation>,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// One prefab macro-cell payload.
pub struct PrefabDefinitionCell {
    pub offset: MacroCoord,
    pub micro_occupancy_mask: MicroMask,
    pub micro_material_ids: Vec<VoxelMaterialId>,
    pub micro_state_flags: Vec<u16>,
    pub micro_part_ids: Vec<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Prefab part metadata retained for future gameplay semantics.
pub struct PrefabPartDefinition {
    pub part_id: String,
    pub part_tags: Vec<String>,
    pub default_affordances: Vec<String>,
    pub default_health: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Rasterized prefab cell ready to merge into world storage.
pub struct PrefabRasterCell {
    pub macro_coord: MacroCoord,
    pub data: PrefabCellData,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Prefab cell payload ready for world storage.
pub struct PrefabCellData {
    pub micro_occupancy_mask: MicroMask,
    pub micro_material_ids: Vec<VoxelMaterialId>,
    pub micro_state_flags: Vec<u16>,
    pub micro_part_ids: Vec<i32>,
}

#[derive(Debug, Clone)]
/// Local prefab registry with built-ins and captured definitions.
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

    fn capture(
        &mut self,
        name: &str,
        min: MacroCoord,
        max: MacroCoord,
        cells: &BTreeMap<MacroCoord, CellData>,
    ) -> LocalPrefab {
        let mut prefab_cells = Vec::new();
        let mut part_index = 0;
        let low = min_macro_coord(min, max);
        let high = max_macro_coord(min, max);
        for x in low.x..=high.x {
            for y in low.y..=high.y {
                for z in low.z..=high.z {
                    let coord = MacroCoord::new(x, y, z);
                    let Some(CellData::Normal(block)) = cells.get(&coord) else {
                        continue;
                    };
                    prefab_cells.push(prefab_cell_from_mask(
                        MacroCoord::new(x - low.x, y - low.y, z - low.z),
                        MicroMask::full(),
                        block.material_id,
                        part_index,
                    ));
                    part_index += 1;
                }
            }
        }

        let prefab = LocalPrefab {
            name: name.to_string(),
            definition: PrefabDefinitionData {
                prefab_id: name.to_string(),
                bounds_in_macro_cells: MacroCoord::new(
                    high.x - low.x + 1,
                    high.y - low.y + 1,
                    high.z - low.z + 1,
                ),
                micro_resolution: MICRO_PER_MACRO,
                cells: prefab_cells,
                part_definitions: (0..part_index)
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
}

impl Default for LocalPrefabRegistry {
    fn default() -> Self {
        Self::with_builtins()
    }
}

/// Returns whether a micro coordinate is inside one macro cell.
pub fn is_micro_coord_in_bounds(coord: MicroCoord) -> bool {
    coord.x >= 0
        && coord.y >= 0
        && coord.z >= 0
        && coord.x < MICRO_PER_MACRO
        && coord.y < MICRO_PER_MACRO
        && coord.z < MICRO_PER_MACRO
}

/// Returns a browser-compatible micro slot index.
pub fn micro_linear_index(coord: MicroCoord) -> Option<usize> {
    is_micro_coord_in_bounds(coord).then_some(
        (coord.x + coord.y * MICRO_PER_MACRO + coord.z * MICRO_PER_MACRO * MICRO_PER_MACRO)
            as usize,
    )
}

/// Returns a micro coord from a browser-compatible slot index.
pub fn micro_coord_from_index(index: usize) -> Option<MicroCoord> {
    if index >= MICRO_GRID_SLOT_COUNT {
        return None;
    }
    let x = (index as i32) % MICRO_PER_MACRO;
    let y = ((index as i32) / MICRO_PER_MACRO) % MICRO_PER_MACRO;
    let z = (index as i32) / (MICRO_PER_MACRO * MICRO_PER_MACRO);
    Some(MicroCoord::new(x, y, z))
}

fn hotbar_entries() -> Vec<HotbarEntry> {
    vec![
        HotbarEntry {
            kind: HotbarEntryKind::Material,
            label: "dirt".to_string(),
            material_id: Some(VoxelMaterialId::Dirt),
            prefab_name: None,
            rotation: Rotation::Rot0,
        },
        HotbarEntry {
            kind: HotbarEntryKind::Material,
            label: "stone".to_string(),
            material_id: Some(VoxelMaterialId::Stone),
            prefab_name: None,
            rotation: Rotation::Rot0,
        },
        HotbarEntry {
            kind: HotbarEntryKind::Material,
            label: "wood".to_string(),
            material_id: Some(VoxelMaterialId::Wood),
            prefab_name: None,
            rotation: Rotation::Rot0,
        },
        HotbarEntry {
            kind: HotbarEntryKind::Material,
            label: "ice".to_string(),
            material_id: Some(VoxelMaterialId::Ice),
            prefab_name: None,
            rotation: Rotation::Rot0,
        },
        HotbarEntry {
            kind: HotbarEntryKind::Prefab,
            label: "sphere".to_string(),
            material_id: None,
            prefab_name: Some("builtin_sphere".to_string()),
            rotation: Rotation::Rot0,
        },
        HotbarEntry {
            kind: HotbarEntryKind::Prefab,
            label: "cylinder".to_string(),
            material_id: None,
            prefab_name: Some("builtin_cylinder".to_string()),
            rotation: Rotation::Rot0,
        },
        HotbarEntry {
            kind: HotbarEntryKind::Prefab,
            label: "stairs".to_string(),
            material_id: None,
            prefab_name: Some("builtin_stairs".to_string()),
            rotation: Rotation::Rot0,
        },
    ]
}

fn prefab_cell_from_mask(
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

fn sphere_mask() -> MicroMask {
    let mut mask = MicroMask::empty();
    let center = MICRO_PER_MACRO as f32 / 2.0;
    let radius = center - 0.1;
    for x in 0..MICRO_PER_MACRO {
        for y in 0..MICRO_PER_MACRO {
            for z in 0..MICRO_PER_MACRO {
                let dx = x as f32 + 0.5 - center;
                let dy = y as f32 + 0.5 - center;
                let dz = z as f32 + 0.5 - center;
                if (dx * dx + dy * dy + dz * dz).sqrt() <= radius {
                    mask.set(MicroCoord::new(x, y, z));
                }
            }
        }
    }
    mask
}

fn cylinder_mask() -> MicroMask {
    let mut mask = MicroMask::empty();
    let center = MICRO_PER_MACRO as f32 / 2.0;
    let radius = center - 0.1;
    for x in 0..MICRO_PER_MACRO {
        for y in 0..MICRO_PER_MACRO {
            for z in 0..MICRO_PER_MACRO {
                let dx = x as f32 + 0.5 - center;
                let dz = z as f32 + 0.5 - center;
                if (dx * dx + dz * dz).sqrt() <= radius {
                    mask.set(MicroCoord::new(x, y, z));
                }
            }
        }
    }
    mask
}

fn stairs_mask() -> MicroMask {
    let mut mask = MicroMask::empty();
    for x in 0..MICRO_PER_MACRO {
        for y in 0..MICRO_PER_MACRO {
            for z in 0..MICRO_PER_MACRO {
                let max_y = ((z + 1) * MICRO_PER_MACRO / MICRO_PER_MACRO).max(1);
                if y <= max_y && (1..=6).contains(&x) {
                    mask.set(MicroCoord::new(x, y, z));
                }
            }
        }
    }
    mask
}

fn rotate_macro_offset(offset: MacroCoord, bounds: MacroCoord, rotation: Rotation) -> MacroCoord {
    match rotation {
        Rotation::Rot0 => offset,
        Rotation::Rot90 => MacroCoord::new(bounds.z - 1 - offset.z, offset.y, offset.x),
        Rotation::Rot180 => {
            MacroCoord::new(bounds.x - 1 - offset.x, offset.y, bounds.z - 1 - offset.z)
        }
        Rotation::Rot270 => MacroCoord::new(offset.z, offset.y, bounds.x - 1 - offset.x),
    }
}

fn rotate_prefab_cell(cell: &PrefabDefinitionCell, rotation: Rotation) -> PrefabCellData {
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

fn rotate_micro(coord: MicroCoord, rotation: Rotation) -> MicroCoord {
    let max = MICRO_PER_MACRO - 1;
    match rotation {
        Rotation::Rot0 => coord,
        Rotation::Rot90 => MicroCoord::new(max - coord.z, coord.y, coord.x),
        Rotation::Rot180 => MicroCoord::new(max - coord.x, coord.y, max - coord.z),
        Rotation::Rot270 => MicroCoord::new(coord.z, coord.y, max - coord.x),
    }
}

fn contact_slots_for_face(prefab: &LocalPrefab, normal: MacroCoord) -> u32 {
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

fn is_axis_normal(normal: MacroCoord) -> bool {
    matches!(
        (normal.x, normal.y, normal.z),
        (-1, 0, 0) | (1, 0, 0) | (0, -1, 0) | (0, 1, 0) | (0, 0, -1) | (0, 0, 1)
    )
}

fn opposite_normal(normal: MacroCoord) -> MacroCoord {
    MacroCoord::new(-normal.x, -normal.y, -normal.z)
}

fn min_macro_coord(a: MacroCoord, b: MacroCoord) -> MacroCoord {
    MacroCoord::new(a.x.min(b.x), a.y.min(b.y), a.z.min(b.z))
}

fn max_macro_coord(a: MacroCoord, b: MacroCoord) -> MacroCoord {
    MacroCoord::new(a.x.max(b.x), a.y.max(b.y), a.z.max(b.z))
}

/// Parses a coordinate from three string slices.
pub fn parse_macro_coord(args: &[&str]) -> Option<MacroCoord> {
    let [x, y, z] = args else {
        return None;
    };
    Some(MacroCoord::new(
        x.parse().ok()?,
        y.parse().ok()?,
        z.parse().ok()?,
    ))
}

/// Parses a micro coordinate from three string slices.
pub fn parse_micro_coord(args: &[&str]) -> Option<MicroCoord> {
    let coord = parse_macro_coord(args)?;
    let micro = MicroCoord::new(coord.x, coord.y, coord.z);
    is_micro_coord_in_bounds(micro).then_some(micro)
}

/// Formats a macro coordinate for structured stdout.
pub fn format_macro_coord(coord: MacroCoord) -> String {
    format!("{},{},{}", coord.x, coord.y, coord.z)
}

/// Formats a micro coordinate for structured stdout.
pub fn format_micro_coord(coord: MicroCoord) -> String {
    format!("{},{},{}", coord.x, coord.y, coord.z)
}

/// Returns all occupied top-level cell coordinates.
pub fn occupied_macro_set(world: &VoxelWorld) -> BTreeSet<MacroCoord> {
    world.cells.keys().copied().collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Browser-compatible voxel CLI commands.
pub enum VoxelCliCommand {
    Snapshot,
    Chunks {
        limit: usize,
    },
    Cell {
        coord: MacroCoord,
    },
    MicroCell {
        macro_coord: MacroCoord,
        micro: MicroCoord,
    },
    Place {
        coord: MacroCoord,
        material: Option<VoxelMaterialId>,
    },
    Break {
        coord: MacroCoord,
    },
    Hotbar,
    HotbarSelect {
        index_one_based: usize,
    },
    SelectMaterial {
        material: VoxelMaterialId,
    },
    SelectPrefab {
        name: String,
    },
    Prefabs,
    PrefabBoundary {
        name: String,
    },
    PrefabCapture {
        name: String,
        min: MacroCoord,
        max: MacroCoord,
    },
    PrefabPlace {
        name: String,
        origin: MacroCoord,
        rotation: Rotation,
    },
    PrefabSnapPreview(BoundarySnapRequest),
    PrefabPlaceSnap(BoundarySnapRequest),
    WorldExport,
    WorldImport {
        json: String,
    },
    WorldSave {
        slot: String,
    },
    WorldLoad {
        slot: String,
    },
    EditStats,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Structured voxel CLI result emitted through stdio and observe logs.
pub struct VoxelCliResult {
    pub ok: bool,
    pub event: String,
    pub fields: Vec<(String, String)>,
}

impl VoxelCliResult {
    /// Returns a field value by key.
    pub fn field(&self, key: &str) -> Option<&str> {
        self.fields
            .iter()
            .find_map(|(field_key, value)| (field_key == key).then_some(value.as_str()))
    }

    fn ok(event: &str, fields: Vec<(String, String)>) -> Self {
        Self {
            ok: true,
            event: event.to_string(),
            fields,
        }
    }

    fn error(event: &str, reason: impl Into<String>) -> Self {
        Self {
            ok: false,
            event: event.to_string(),
            fields: vec![("reason".to_string(), reason.into())],
        }
    }
}

/// Parses a browser-style voxel CLI command. Returns `Ok(None)` for non-voxel
/// commands so the existing movement/chat stdio parser can continue handling
/// them.
pub fn parse_voxel_cli_command(line: &str) -> Result<Option<VoxelCliCommand>, String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    if let Some(json) = trimmed.strip_prefix("world_import ") {
        return Ok(Some(VoxelCliCommand::WorldImport {
            json: json.to_string(),
        }));
    }

    let parts = trimmed.split_whitespace().collect::<Vec<_>>();
    let Some(command) = parts.first().copied() else {
        return Ok(None);
    };

    match command {
        "snapshot" | "voxel_snapshot" => Ok(Some(VoxelCliCommand::Snapshot)),
        "chunks" => {
            let limit = parts
                .get(1)
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(12);
            Ok(Some(VoxelCliCommand::Chunks { limit }))
        }
        "cell" => Ok(Some(VoxelCliCommand::Cell {
            coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: cell <x> <y> <z>".to_string())?,
        })),
        "micro_cell" => Ok(Some(VoxelCliCommand::MicroCell {
            macro_coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: micro_cell <x> <y> <z> <mx> <my> <mz>".to_string())?,
            micro: parse_micro_coord(parts.get(4..7).unwrap_or(&[]))
                .ok_or_else(|| "usage: micro_cell <x> <y> <z> <mx> <my> <mz>".to_string())?,
        })),
        "place" => Ok(Some(VoxelCliCommand::Place {
            coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: place <x> <y> <z> [material]".to_string())?,
            material: parts
                .get(4)
                .map(|value| {
                    VoxelMaterialId::parse(value)
                        .ok_or_else(|| format!("unknown material: {value}"))
                })
                .transpose()?,
        })),
        "break" => Ok(Some(VoxelCliCommand::Break {
            coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: break <x> <y> <z>".to_string())?,
        })),
        "hotbar" => Ok(Some(VoxelCliCommand::Hotbar)),
        "hotbar_select" => Ok(Some(VoxelCliCommand::HotbarSelect {
            index_one_based: parts
                .get(1)
                .ok_or_else(|| "usage: hotbar_select <index>".to_string())?
                .parse::<usize>()
                .map_err(|error| format!("invalid hotbar index: {error}"))?,
        })),
        "select_material" => Ok(Some(VoxelCliCommand::SelectMaterial {
            material: VoxelMaterialId::parse(
                parts
                    .get(1)
                    .ok_or_else(|| "usage: select_material <id|name>".to_string())?,
            )
            .ok_or_else(|| format!("unknown material: {}", parts[1]))?,
        })),
        "select_prefab" => Ok(Some(VoxelCliCommand::SelectPrefab {
            name: parts
                .get(1)
                .ok_or_else(|| "usage: select_prefab <name>".to_string())?
                .to_string(),
        })),
        "prefabs" => Ok(Some(VoxelCliCommand::Prefabs)),
        "prefab_boundary" | "prefab_sockets" => Ok(Some(VoxelCliCommand::PrefabBoundary {
            name: parts
                .get(1)
                .ok_or_else(|| "usage: prefab_boundary <name>".to_string())?
                .to_string(),
        })),
        "prefab_capture" => Ok(Some(VoxelCliCommand::PrefabCapture {
            name: parts
                .get(1)
                .ok_or_else(|| {
                    "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>"
                        .to_string()
                })?
                .to_string(),
            min: parse_macro_coord(parts.get(2..5).unwrap_or(&[])).ok_or_else(|| {
                "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>".to_string()
            })?,
            max: parse_macro_coord(parts.get(5..8).unwrap_or(&[])).ok_or_else(|| {
                "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>".to_string()
            })?,
        })),
        "prefab_place" => Ok(Some(VoxelCliCommand::PrefabPlace {
            name: parts
                .get(1)
                .ok_or_else(|| {
                    "usage: prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]".to_string()
                })?
                .to_string(),
            origin: parse_macro_coord(parts.get(2..5).unwrap_or(&[])).ok_or_else(|| {
                "usage: prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]".to_string()
            })?,
            rotation: Rotation::parse(parts.get(5).copied()).ok_or_else(|| {
                format!("invalid rotation: {}", parts.get(5).copied().unwrap_or(""))
            })?,
        })),
        "prefab_snap_preview" => Ok(Some(VoxelCliCommand::PrefabSnapPreview(
            parse_boundary_snap_request(&parts[1..])?,
        ))),
        "prefab_place_snap" => Ok(Some(VoxelCliCommand::PrefabPlaceSnap(
            parse_boundary_snap_request(&parts[1..])?,
        ))),
        "world_export" => Ok(Some(VoxelCliCommand::WorldExport)),
        "world_save" => Ok(Some(VoxelCliCommand::WorldSave {
            slot: parts.get(1).copied().unwrap_or("default").to_string(),
        })),
        "world_load" => Ok(Some(VoxelCliCommand::WorldLoad {
            slot: parts.get(1).copied().unwrap_or("default").to_string(),
        })),
        "edit_stats" => Ok(Some(VoxelCliCommand::EditStats)),
        _ => Ok(None),
    }
}

/// Executes one voxel CLI command against local world truth.
pub fn execute_voxel_cli_command(
    world: &mut VoxelWorld,
    command: VoxelCliCommand,
    save_dir: Option<&Path>,
) -> VoxelCliResult {
    match command {
        VoxelCliCommand::Snapshot => VoxelCliResult::ok(
            "voxel_snapshot",
            vec![
                ("voxel_sync".to_string(), "offline-local".to_string()),
                (
                    "solid_cells".to_string(),
                    world.total_solid_cells().to_string(),
                ),
                (
                    "selected_hotbar".to_string(),
                    (world.hotbar().selected_index + 1).to_string(),
                ),
                (
                    "selected".to_string(),
                    world.hotbar().selected.label.to_string(),
                ),
                (
                    "edit_stats".to_string(),
                    format_edit_stats(world.edit_stats()),
                ),
            ],
        ),
        VoxelCliCommand::Chunks { limit } => {
            let chunks = world
                .cell_summaries()
                .into_iter()
                .take(limit)
                .map(|(coord, mode, slots)| {
                    format!("{}:{}:{}", format_macro_coord(coord), mode, slots)
                })
                .collect::<Vec<_>>()
                .join(";");
            VoxelCliResult::ok(
                "chunks",
                vec![("chunks".to_string(), format!("[{chunks}]"))],
            )
        }
        VoxelCliCommand::Cell { coord } => {
            if let Some(block) = world.normal_block(coord) {
                VoxelCliResult::ok(
                    "cell",
                    vec![
                        ("coord".to_string(), format_macro_coord(coord)),
                        ("mode".to_string(), "normal".to_string()),
                        (
                            "material".to_string(),
                            block.material_id.label().to_string(),
                        ),
                    ],
                )
            } else if let Some(refined) = world.refined_cell(coord) {
                VoxelCliResult::ok(
                    "cell",
                    vec![
                        ("coord".to_string(), format_macro_coord(coord)),
                        ("mode".to_string(), "refined".to_string()),
                        (
                            "occupied_slots".to_string(),
                            refined.occupied_slot_count().to_string(),
                        ),
                    ],
                )
            } else {
                VoxelCliResult::ok(
                    "cell",
                    vec![
                        ("coord".to_string(), format_macro_coord(coord)),
                        ("mode".to_string(), "empty".to_string()),
                    ],
                )
            }
        }
        VoxelCliCommand::MicroCell { macro_coord, micro } => {
            let block = world.micro_block(macro_coord, micro);
            VoxelCliResult::ok(
                "micro_cell",
                vec![
                    ("macro".to_string(), format_macro_coord(macro_coord)),
                    ("micro".to_string(), format_micro_coord(micro)),
                    ("occupied".to_string(), block.is_some().to_string()),
                    (
                        "material".to_string(),
                        block
                            .map(|block| block.material_id.label().to_string())
                            .unwrap_or_else(|| "none".to_string()),
                    ),
                ],
            )
        }
        VoxelCliCommand::Place { coord, material } => {
            let material = material.unwrap_or_else(|| selected_material(world));
            let ok = world.place_block(coord, NormalBlockData::new(material));
            VoxelCliResult {
                ok,
                event: "place".to_string(),
                fields: vec![
                    ("coord".to_string(), format_macro_coord(coord)),
                    ("material".to_string(), material.label().to_string()),
                    ("ok".to_string(), ok.to_string()),
                ],
            }
        }
        VoxelCliCommand::Break { coord } => {
            let ok = world.break_block(coord);
            VoxelCliResult {
                ok,
                event: "break".to_string(),
                fields: vec![
                    ("coord".to_string(), format_macro_coord(coord)),
                    ("ok".to_string(), ok.to_string()),
                ],
            }
        }
        VoxelCliCommand::Hotbar => {
            let hotbar = world.hotbar();
            VoxelCliResult::ok(
                "hotbar",
                vec![
                    (
                        "selected_index".to_string(),
                        (hotbar.selected_index + 1).to_string(),
                    ),
                    ("selected".to_string(), hotbar.selected.label),
                    (
                        "entries".to_string(),
                        hotbar
                            .entries
                            .iter()
                            .enumerate()
                            .map(|(index, entry)| format!("{}:{}", index + 1, entry.label))
                            .collect::<Vec<_>>()
                            .join(","),
                    ),
                ],
            )
        }
        VoxelCliCommand::HotbarSelect { index_one_based } => {
            let result = index_one_based
                .checked_sub(1)
                .ok_or_else(|| "hotbar index must be one-based".to_string())
                .and_then(|index| world.select_hotbar_index(index));
            match result {
                Ok(()) => VoxelCliResult::ok(
                    "hotbar_select",
                    vec![
                        ("selected_index".to_string(), index_one_based.to_string()),
                        ("selected".to_string(), world.hotbar().selected.label),
                    ],
                ),
                Err(error) => VoxelCliResult::error("hotbar_select", error),
            }
        }
        VoxelCliCommand::SelectMaterial { material } => {
            world.select_material(material);
            VoxelCliResult::ok(
                "select_material",
                vec![("material".to_string(), material.label().to_string())],
            )
        }
        VoxelCliCommand::SelectPrefab { name } => match world.select_prefab(&name) {
            Ok(()) => VoxelCliResult::ok("select_prefab", vec![("prefab".to_string(), name)]),
            Err(error) => VoxelCliResult::error("select_prefab", error),
        },
        VoxelCliCommand::Prefabs => {
            let prefabs = world
                .list_prefabs()
                .iter()
                .map(|prefab| {
                    format!(
                        "{}:{}:{}",
                        prefab.name,
                        prefab.definition.micro_resolution,
                        prefab.total_occupied_slots()
                    )
                })
                .collect::<Vec<_>>()
                .join(";");
            VoxelCliResult::ok(
                "prefabs",
                vec![("prefabs".to_string(), format!("[{prefabs}]"))],
            )
        }
        VoxelCliCommand::PrefabBoundary { name } => match world.prefab(&name) {
            Some(prefab) => VoxelCliResult::ok(
                "prefab_boundary",
                vec![
                    ("prefab".to_string(), name),
                    (
                        "occupied_slots".to_string(),
                        prefab.total_occupied_slots().to_string(),
                    ),
                    (
                        "micro_resolution".to_string(),
                        prefab.definition.micro_resolution.to_string(),
                    ),
                ],
            ),
            None => VoxelCliResult::error("prefab_boundary", format!("unknown prefab: {name}")),
        },
        VoxelCliCommand::PrefabCapture { name, min, max } => {
            let prefab = world.capture_prefab(&name, min, max);
            VoxelCliResult::ok(
                "prefab_capture",
                vec![
                    ("prefab".to_string(), name),
                    (
                        "cells".to_string(),
                        prefab.definition.cells.len().to_string(),
                    ),
                    (
                        "occupied_slots".to_string(),
                        prefab.total_occupied_slots().to_string(),
                    ),
                ],
            )
        }
        VoxelCliCommand::PrefabPlace {
            name,
            origin,
            rotation,
        } => {
            let result = world.place_prefab(&name, origin, rotation);
            VoxelCliResult {
                ok: result.ok,
                event: "prefab_place".to_string(),
                fields: vec![
                    ("prefab".to_string(), name),
                    ("origin".to_string(), format_macro_coord(origin)),
                    ("ok".to_string(), result.ok.to_string()),
                    ("placed".to_string(), result.placed.to_string()),
                    (
                        "instance_id".to_string(),
                        result
                            .instance_id
                            .map(|value| value.to_string())
                            .unwrap_or_else(|| "none".to_string()),
                    ),
                    ("conflict".to_string(), result.conflict.to_string()),
                ],
            }
        }
        VoxelCliCommand::PrefabSnapPreview(request) => {
            let preview = world.preview_prefab_boundary_snap(&request);
            boundary_preview_result("prefab_snap_preview", preview)
        }
        VoxelCliCommand::PrefabPlaceSnap(request) => {
            let result = world.place_prefab_boundary_snap(&request);
            let mut out = boundary_preview_result(
                "prefab_place_snap",
                result.preview.clone().unwrap_or_else(|| {
                    BoundarySnapPreview::rejected(&request, "preview_unavailable")
                }),
            );
            out.ok = result.ok;
            out.fields.push((
                "instance_id".to_string(),
                result.instance_id.unwrap_or(0).to_string(),
            ));
            out.fields
                .push(("conflict".to_string(), result.conflict.to_string()));
            out
        }
        VoxelCliCommand::WorldExport => match serde_json::to_string(&world.export_snapshot()) {
            Ok(json) => VoxelCliResult::ok(
                "world_export",
                vec![
                    ("bytes".to_string(), json.len().to_string()),
                    ("json".to_string(), json),
                ],
            ),
            Err(error) => VoxelCliResult::error("world_export", error.to_string()),
        },
        VoxelCliCommand::WorldImport { json } => {
            match serde_json::from_str::<WorldSnapshot>(&json)
                .map_err(|error| error.to_string())
                .and_then(|snapshot| world.import_snapshot(snapshot))
            {
                Ok(()) => VoxelCliResult::ok(
                    "world_import",
                    vec![(
                        "solid_cells".to_string(),
                        world.total_solid_cells().to_string(),
                    )],
                ),
                Err(error) => VoxelCliResult::error("world_import", error),
            }
        }
        VoxelCliCommand::WorldSave { slot } => {
            let Some(save_dir) = save_dir else {
                return VoxelCliResult::error("world_save", "world save directory unavailable");
            };
            match serde_json::to_string(&world.export_snapshot())
                .map_err(|error| error.to_string())
                .and_then(|json| {
                    fs::create_dir_all(save_dir).map_err(|error| error.to_string())?;
                    let path = save_dir.join(world_save_file_name(&slot));
                    fs::write(&path, &json).map_err(|error| error.to_string())?;
                    Ok((json.len(), path))
                }) {
                Ok((bytes, path)) => VoxelCliResult::ok(
                    "world_save",
                    vec![
                        ("slot".to_string(), slot),
                        ("bytes".to_string(), bytes.to_string()),
                        ("path".to_string(), path.display().to_string()),
                    ],
                ),
                Err(error) => VoxelCliResult::error("world_save", error),
            }
        }
        VoxelCliCommand::WorldLoad { slot } => {
            let Some(save_dir) = save_dir else {
                return VoxelCliResult::error("world_load", "world save directory unavailable");
            };
            let path = save_dir.join(world_save_file_name(&slot));
            match fs::read_to_string(&path)
                .map_err(|error| error.to_string())
                .and_then(|json| {
                    serde_json::from_str::<WorldSnapshot>(&json).map_err(|error| error.to_string())
                })
                .and_then(|snapshot| world.import_snapshot(snapshot))
            {
                Ok(()) => VoxelCliResult::ok(
                    "world_load",
                    vec![
                        ("slot".to_string(), slot),
                        (
                            "solid_cells".to_string(),
                            world.total_solid_cells().to_string(),
                        ),
                        ("path".to_string(), path.display().to_string()),
                    ],
                ),
                Err(error) => VoxelCliResult::error("world_load", error),
            }
        }
        VoxelCliCommand::EditStats => VoxelCliResult::ok(
            "edit_stats",
            vec![(
                "edit_stats".to_string(),
                format_edit_stats(world.edit_stats()),
            )],
        ),
    }
}

fn parse_boundary_snap_request(parts: &[&str]) -> Result<BoundarySnapRequest, String> {
    Ok(BoundarySnapRequest {
        prefab_name: parts
            .first()
            .ok_or_else(|| {
                "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]"
                    .to_string()
            })?
            .to_string(),
        hit_macro: parse_macro_coord(parts.get(1..4).unwrap_or(&[])).ok_or_else(|| {
            "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]".to_string()
        })?,
        face_normal: parse_macro_coord(parts.get(4..7).unwrap_or(&[])).ok_or_else(|| {
            "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]".to_string()
        })?,
        rotation: Rotation::parse(parts.get(7).copied())
            .ok_or_else(|| format!("invalid rotation: {}", parts.get(7).copied().unwrap_or("")))?,
    })
}

fn selected_material(world: &VoxelWorld) -> VoxelMaterialId {
    world
        .hotbar()
        .selected
        .material_id
        .unwrap_or(VoxelMaterialId::Dirt)
}

fn boundary_preview_result(event: &str, preview: BoundarySnapPreview) -> VoxelCliResult {
    VoxelCliResult {
        ok: preview.ok,
        event: event.to_string(),
        fields: vec![
            ("prefab".to_string(), preview.prefab_id),
            (
                "hit_macro".to_string(),
                format_macro_coord(preview.hit_macro),
            ),
            (
                "face_normal".to_string(),
                format_macro_coord(preview.face_normal),
            ),
            ("ok".to_string(), preview.ok.to_string()),
            (
                "affected_macro_count".to_string(),
                preview.affected_macro_count.to_string(),
            ),
            (
                "incoming_occupied_slots".to_string(),
                preview.incoming_occupied_slots.to_string(),
            ),
            (
                "overlap_slots".to_string(),
                preview.overlap_slots.to_string(),
            ),
            (
                "contact_slots".to_string(),
                preview.contact_slots.to_string(),
            ),
            (
                "reject_reason".to_string(),
                preview.reject_reason.unwrap_or_default(),
            ),
        ],
    }
}

fn format_edit_stats(stats: EditStats) -> String {
    format!(
        "placed={},broken={},rejected={},conflicts={},prefab_placed={}",
        stats.placed, stats.broken, stats.rejected, stats.conflicts, stats.prefab_placed
    )
}

fn world_save_file_name(slot: &str) -> String {
    let sanitized = slot
        .chars()
        .map(|chr| {
            if chr.is_ascii_alphanumeric() || chr == '-' || chr == '_' {
                chr
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("bevy-world-{sanitized}.json")
}
