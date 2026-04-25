//! Pure voxel primitives shared by world storage, prefab logic, and CLI.
//!
//! Nothing in `core/` depends on Bevy or async runtimes. Sub-modules:
//!
//! - `coord` — macro/micro coordinate types, rotation, parsing, indexing.
//! - `material` — voxel material identifiers and per-material defaults.
//! - `mask` — fixed-size 512-bit micro occupancy mask.

pub mod coord;
pub mod mask;
pub mod material;

pub use coord::{
    MICRO_GRID_SLOT_COUNT, MICRO_PER_MACRO, MacroCoord, MicroCoord, Rotation, format_macro_coord,
    format_micro_coord, is_micro_coord_in_bounds, micro_coord_from_index, micro_linear_index,
    parse_macro_coord, parse_micro_coord,
};
pub use mask::MicroMask;
pub use material::VoxelMaterialId;
