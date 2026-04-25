//! Voxel material identifiers and per-material defaults.

use serde::{Deserialize, Serialize};

/// Browser-compatible voxel material identifiers.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
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

    pub(crate) fn max_health(self) -> u16 {
        match self {
            Self::Dirt => 80,
            Self::Stone => 160,
            Self::Wood => 100,
            Self::Ice => 70,
        }
    }
}
