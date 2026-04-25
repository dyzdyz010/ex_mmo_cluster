//! Serializable voxel world snapshots.
//!
//! Snapshot payloads are wire- and disk-compatible with the browser client.
//! The `VoxelWorld` storage methods that consume / emit snapshots live in
//! [`super::store`].

use serde::{Deserialize, Serialize};

use crate::voxel::core::MacroCoord;

use super::store::{EditStats, NormalBlockData, PrefabInstanceData, RefinedCellData};

/// Serializable voxel world snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorldSnapshot {
    pub version: u32,
    pub cells: Vec<SnapshotCell>,
    pub prefab_instances: Vec<PrefabInstanceData>,
    pub edit_stats: EditStats,
}

/// Serializable non-empty world cell.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotCell {
    pub macro_coord: MacroCoord,
    pub normal: Option<NormalBlockData>,
    pub refined: Option<RefinedCellData>,
}
