//! Hotbar state and the static browser-compatible default entries.

use serde::{Deserialize, Serialize};

use crate::voxel::core::{Rotation, VoxelMaterialId};

/// Hotbar entry class.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum HotbarEntryKind {
    Material,
    Prefab,
}

/// Browser-compatible hotbar entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotbarEntry {
    pub kind: HotbarEntryKind,
    pub label: String,
    pub material_id: Option<VoxelMaterialId>,
    pub prefab_name: Option<String>,
    pub rotation: Rotation,
}

/// Current hotbar state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotbarState {
    pub entries: Vec<HotbarEntry>,
    pub selected_index: usize,
    pub selected: HotbarEntry,
}

pub(crate) fn hotbar_entries() -> Vec<HotbarEntry> {
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
