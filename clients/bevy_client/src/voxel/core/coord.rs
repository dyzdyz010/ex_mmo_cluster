//! Voxel coordinate types and conversions.
//!
//! Pure module: no Bevy or async dependencies. Owns the macro/micro
//! coordinate primitives, prefab rotation primitive, and the index-helpers
//! that both world storage and prefab logic depend on.

use serde::{Deserialize, Serialize};

/// Number of refined micro cells per macro-cell axis.
pub const MICRO_PER_MACRO: i32 = 8;
/// Total refined micro slots in one macro cell.
pub const MICRO_GRID_SLOT_COUNT: usize = 512;
/// Number of `u64` words used to back a [`super::mask::MicroMask`].
pub(crate) const MICRO_MASK_WORDS: usize = MICRO_GRID_SLOT_COUNT / 64;

/// Integer macro-cell coordinate.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
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

    pub(crate) fn offset(self, other: MacroCoord) -> Self {
        Self::new(self.x + other.x, self.y + other.y, self.z + other.z)
    }
}

/// Integer refined micro coordinate local to one macro cell.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
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

/// Supported prefab rotations around the vertical axis.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

pub(crate) fn min_macro_coord(a: MacroCoord, b: MacroCoord) -> MacroCoord {
    MacroCoord::new(a.x.min(b.x), a.y.min(b.y), a.z.min(b.z))
}

pub(crate) fn max_macro_coord(a: MacroCoord, b: MacroCoord) -> MacroCoord {
    MacroCoord::new(a.x.max(b.x), a.y.max(b.y), a.z.max(b.z))
}
