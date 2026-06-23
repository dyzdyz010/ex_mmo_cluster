//! Construction-system build palette: the fixed material + component list a player
//! places in a live scene. Decoupled from the offline `VoxelMaterialId` enum (which
//! only knows the 4 showcase materials) — entries carry the **server material id**
//! (u16) directly, so the full confirmed list (materials + electrical components)
//! places authoritatively and renders via the chunk material palette.
//!
//! Fixed list (confirmed 2026-06-23): plain blocks + electrical conduits/components
//! + light/photo. Semiconductors (resistor/comparator/diode/transistor) append here
//! as their materials land (C3/C4). No resource cost — infinite-resource build.

use bevy::prelude::Resource;

/// One placeable entry: a server material id + a short label.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuildPaletteEntry {
    /// Server `MaterialCatalog` id (matches the chunk render palette).
    pub material_id: u16,
    pub label: &'static str,
}

const fn entry(material_id: u16, label: &'static str) -> BuildPaletteEntry {
    BuildPaletteEntry { material_id, label }
}

/// The confirmed fixed construction palette (block-form). Surface fixtures
/// (torch/lever) and prefab runs are placed via separate paths (C5).
const FIXED_PALETTE: &[BuildPaletteEntry] = &[
    // ① 材质方块
    entry(2, "stone"),
    entry(1, "dirt"),
    entry(3, "wood"),
    entry(5, "iron"), // also the electrical conductor / wire
    entry(4, "ice"),
    entry(16, "obsidian"), // translucent (glass-like)
    entry(19, "glowstone"), // light block
    // ② 电路件
    entry(6, "power_block"),
    entry(7, "electric_load"), // heater (I²R)
    entry(11, "door"),         // powered → open actuator
    // ③ 光敏件
    entry(17, "photo_sensor"),
];

/// Selected build component for the live (server-authoritative) build path.
#[derive(Resource, Debug, Clone)]
pub struct BuildPalette {
    entries: Vec<BuildPaletteEntry>,
    selected: usize,
}

impl Default for BuildPalette {
    fn default() -> Self {
        Self {
            entries: FIXED_PALETTE.to_vec(),
            selected: 0,
        }
    }
}

impl BuildPalette {
    pub fn entries(&self) -> &[BuildPaletteEntry] {
        &self.entries
    }

    pub fn selected_index(&self) -> usize {
        self.selected
    }

    pub fn selected(&self) -> BuildPaletteEntry {
        self.entries[self.selected]
    }

    pub fn selected_material(&self) -> u16 {
        self.entries[self.selected].material_id
    }

    /// Selects by index (no-op if out of range). Returns whether it changed.
    pub fn select(&mut self, index: usize) -> bool {
        if index < self.entries.len() && index != self.selected {
            self.selected = index;
            true
        } else {
            false
        }
    }

    /// Cycles the selection by `delta` (wraps). `delta` may be negative.
    pub fn cycle(&mut self, delta: i32) {
        let len = self.entries.len() as i32;
        if len == 0 {
            return;
        }
        let next = (self.selected as i32 + delta).rem_euclid(len);
        self.selected = next as usize;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_starts_on_first_entry_with_full_fixed_list() {
        let p = BuildPalette::default();
        assert_eq!(p.selected_index(), 0);
        assert_eq!(p.selected().label, "stone");
        assert_eq!(p.selected_material(), 2);
        // The confirmed fixed list (block-form): 7 materials + 3 circuit + 1 photo.
        assert_eq!(p.entries().len(), 11);
        // Electrical components are present with their server ids.
        assert!(p.entries().iter().any(|e| e.material_id == 6 && e.label == "power_block"));
        assert!(p.entries().iter().any(|e| e.material_id == 17 && e.label == "photo_sensor"));
    }

    #[test]
    fn select_by_index_and_material() {
        let mut p = BuildPalette::default();
        assert!(p.select(3)); // iron
        assert_eq!(p.selected_material(), 5);
        assert!(!p.select(3)); // already selected → no change
        assert!(!p.select(999)); // out of range → no change
        assert_eq!(p.selected_material(), 5);
    }

    #[test]
    fn cycle_wraps_both_directions() {
        let mut p = BuildPalette::default();
        let n = p.entries().len();
        p.cycle(-1);
        assert_eq!(p.selected_index(), n - 1); // wrapped to last
        p.cycle(1);
        assert_eq!(p.selected_index(), 0); // wrapped back to first
    }
}
