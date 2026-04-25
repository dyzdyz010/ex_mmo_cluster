//! Prefab subsystem: definitions, registry, rotation, built-ins, and
//! socket-free boundary snapping.
//!
//! This module is pure — it does not depend on Bevy or async runtimes and
//! operates only on `voxel::core` primitives plus its own types.

pub mod boundary;
pub mod builtins;
pub mod definition;
pub mod registry;
pub mod rotation;

pub use boundary::{BoundarySnapPlaceResult, BoundarySnapPreview, BoundarySnapRequest};
pub use definition::{
    PrefabCellData, PrefabDefinitionCell, PrefabDefinitionData, PrefabPartDefinition,
    PrefabRasterCell,
};
pub use registry::{LocalPrefab, LocalPrefabRegistry};
