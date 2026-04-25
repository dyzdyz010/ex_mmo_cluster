//! Local voxel world truth: `VoxelWorld` storage, hotbar state, and the
//! serializable snapshot envelope used for save/load and JSON export.
//!
//! This sub-module owns runtime mutation of voxel cells and prefab instances.
//! Pure prefab geometry, snap previewing, and rotation primitives live in
//! `voxel::prefab`; coordinate / mask / material primitives in `voxel::core`.

pub mod hotbar;
pub mod snapshot;
pub mod store;

pub use hotbar::{HotbarEntry, HotbarEntryKind, HotbarState};
pub use snapshot::{SnapshotCell, WorldSnapshot};
pub use store::{
    EditStats, NormalBlockData, PrefabInstanceData, PrefabPlaceResult, RefinedCellData,
    VoxelRenderCell, VoxelWorld,
};
