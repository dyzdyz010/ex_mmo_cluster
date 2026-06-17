//! Offline-local voxel world for the Bevy client.
//!
//! Mirrors the browser client's local boundary: macro cells, refined
//! `8x8x8` micro occupancy, built-in prefabs, hotbar selection, and snapshot
//! import/export. Server authority is intentionally not mixed into this
//! storage layer.
//!
//! Sub-modules:
//!
//! - `core` — pure coordinate / mask / material primitives
//! - `world` — `VoxelWorld` storage, snapshots, hotbar
//! - `prefab` — definitions, registry, rotation, built-ins, boundary snap
//! - `cli` — browser-compatible CLI parsing + execution
//!
//! `voxel/mod.rs` itself is just a re-export shell so callers can keep using
//! `bevy_client::voxel::Type` paths while the implementation lives in
//! sub-modules.

pub mod authority;
pub mod authority_plugin;
pub mod chunk_render;
pub mod cli;
pub mod core;
pub mod mesher;
pub mod plugin;
pub mod prefab;
pub mod surface_decal;
pub mod wire;
pub mod world;

pub use authority_plugin::{VoxelAuthority, VoxelAuthorityPlugin};
pub use chunk_render::VoxelChunkRenderPlugin;
pub use plugin::VoxelPlugin;

pub use cli::{
    VoxelCliCommand, VoxelCliResult, execute_voxel_cli_command, parse_voxel_cli_command,
};
pub use core::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCellTarget, MicroCoord, MicroMask,
    Rotation, VoxelMaterialId, format_macro_coord, format_micro_coord, is_micro_coord_in_bounds,
    micro_coord_from_index, micro_linear_index, parse_macro_coord, parse_micro_coord,
};
pub use prefab::{
    BoundarySnapPlaceResult, BoundarySnapPreview, BoundarySnapRequest, LocalPrefab,
    LocalPrefabRegistry, PrefabCellData, PrefabDefinitionCell, PrefabDefinitionData,
    PrefabPartDefinition, PrefabRasterCell,
};
pub use world::{
    EditStats, HotbarEntry, HotbarEntryKind, HotbarState, NormalBlockData, PrefabInstanceData,
    PrefabPlaceResult, RefinedCellData, SnapshotCell, VoxelRenderCell, VoxelWorld, WorldSnapshot,
};

use std::collections::BTreeSet;

/// Returns all occupied top-level cell coordinates.
///
/// Thin wrapper around [`VoxelWorld::occupied_macro_set`] kept for
/// historical CLI/diagnostic call sites.
pub fn occupied_macro_set(world: &VoxelWorld) -> BTreeSet<MacroCoord> {
    world.occupied_macro_set()
}
