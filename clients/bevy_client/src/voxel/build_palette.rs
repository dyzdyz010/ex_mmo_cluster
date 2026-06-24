//! Construction-system build palette: the fixed material + component list a player
//! places in a live scene. Decoupled from the offline `VoxelMaterialId` enum (which
//! only knows the 4 showcase materials) — entries carry the **server id** directly,
//! so the full confirmed list (materials + electrical components + prefab runs +
//! surface fixtures) places authoritatively and renders via the chunk material
//! palette / prefab raster / surface decal layers.
//!
//! Fixed list (confirmed 2026-06-23): plain blocks, electrical conduits/components,
//! light/photo, semiconductors (resistor/comparator), **prefab runs** (sphere /
//! cylinder / stairs / wire / junction / power / load), and **surface fixtures**
//! (torch / lever). No resource cost — infinite-resource build.
//!
//! C5.1: one palette now spans all three placement paths. Selecting an entry and
//! pressing place dispatches the matching server-authoritative intent — a block
//! `VoxelEditIntent` (0x70), a `PrefabPlaceIntent` (0x67), or a
//! `SurfaceElementIntent` (0x66) — via [`build_place_command`].

use bevy::prelude::Resource;

use crate::net::NetworkCommand;
use crate::voxel::authority_plugin::VOXEL_LOGICAL_SCENE_ID;
use crate::voxel::live_pick::LivePick;
use crate::voxel::wire::edit_intent::ACTION_PLACE;
use crate::voxel::wire::surface_element_intent::ACTION_PLACE as SURFACE_ACTION_PLACE;

/// What a palette entry places, and the server id it carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildKind {
    /// A solid block of this server `MaterialCatalog` id (VoxelEditIntent 0x70),
    /// placed at the air cell adjacent to the picked face.
    Material(u16),
    /// A catalog blueprint prefab by `BlueprintCatalog` id (PrefabPlaceIntent
    /// 0x67), anchored at the air cell adjacent to the picked face.
    Prefab(u64),
    /// A surface element (torch/lever) of this `SurfaceCatalog` surface_type_id
    /// (SurfaceElementIntent 0x66), bound to the picked face of the solid host.
    Surface(u16),
}

/// One placeable entry: what it places + a short label.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuildPaletteEntry {
    pub kind: BuildKind,
    pub label: &'static str,
}

const fn block(material_id: u16, label: &'static str) -> BuildPaletteEntry {
    BuildPaletteEntry {
        kind: BuildKind::Material(material_id),
        label,
    }
}

const fn prefab(blueprint_id: u64, label: &'static str) -> BuildPaletteEntry {
    BuildPaletteEntry {
        kind: BuildKind::Prefab(blueprint_id),
        label,
    }
}

const fn surface(surface_type_id: u16, label: &'static str) -> BuildPaletteEntry {
    BuildPaletteEntry {
        kind: BuildKind::Surface(surface_type_id),
        label,
    }
}

/// The confirmed fixed construction palette across all three placement paths.
const FIXED_PALETTE: &[BuildPaletteEntry] = &[
    // ① 材质方块
    block(2, "stone"),
    block(1, "dirt"),
    block(3, "wood"),
    block(5, "iron"), // also the electrical conductor / wire
    block(4, "ice"),
    block(16, "obsidian"),  // translucent (glass-like)
    block(19, "glowstone"), // light block
    // ② 电路件
    block(6, "power_block"),
    block(7, "electric_load"), // heater (I²R)
    block(11, "door"),         // powered → open actuator
    // ③ 光敏件
    block(17, "photo_sensor"),
    // ④ 半导体(梯队 a):被动电阻(限流/分压)+ 比较器/阈值门(电位≥阈→:signal_high)。
    block(20, "resistor"),
    block(21, "comparator"),
    // C4b 深半导体:二极管(单向导通,默认 +x 轴)+ 三极管/逻辑门(base 门控开关)。
    block(22, "diode"),
    block(23, "transistor"),
    // ⑤ prefab 预制(BlueprintCatalog id 1..7,放空支撑格 → refined cells / 多 chunk 事务)。
    prefab(1, "prefab:sphere"),
    prefab(2, "prefab:cylinder"),
    prefab(3, "prefab:stairs"),
    prefab(4, "prefab:wire"),
    prefab(5, "prefab:junction"),
    prefab(6, "prefab:power"),
    prefab(7, "prefab:load"),
    // ⑥ 贴面元件(SurfaceCatalog fixture,绑宿主实心块的面,零 occupancy)。
    surface(4, "torch"),
    surface(5, "lever"),
];

/// Maps the picked face normal (components in {-1,0,1}) to the server
/// `SurfaceCatalog` face ordinal (x_neg=0, x_pos=1, y_neg=2, y_pos=3, z_neg=4,
/// z_pos=5). The ray's entry-face normal points outward from the host toward the
/// camera, so the decal lands on exactly the face the player is aiming at.
/// A zero/degenerate normal defaults to y_pos (top).
pub fn face_ordinal_from_normal(normal: [i32; 3]) -> u8 {
    match normal {
        [n, 0, 0] if n < 0 => 0,
        [n, 0, 0] if n > 0 => 1,
        [0, n, 0] if n < 0 => 2,
        [0, n, 0] if n > 0 => 3,
        [0, 0, n] if n < 0 => 4,
        [0, 0, n] if n > 0 => 5,
        _ => 3,
    }
}

/// Maps the selected build entry + the current pick to the server-authoritative
/// network command that places it. Block/prefab land at the air cell adjacent to
/// the picked face; a surface element binds to the picked face of the solid host.
pub fn build_place_command(kind: BuildKind, pick: &LivePick) -> NetworkCommand {
    match kind {
        BuildKind::Material(material_id) => NetworkCommand::EditVoxel {
            logical_scene_id: VOXEL_LOGICAL_SCENE_ID,
            action: ACTION_PLACE,
            target_macro: pick.adjacent_macro(),
            material_id,
        },
        BuildKind::Prefab(blueprint_id) => NetworkCommand::PlacePrefab {
            logical_scene_id: VOXEL_LOGICAL_SCENE_ID,
            blueprint_id,
            anchor_macro: pick.adjacent_macro(),
            rotation: 0,
        },
        BuildKind::Surface(surface_type_id) => NetworkCommand::PlaceSurfaceElement {
            logical_scene_id: VOXEL_LOGICAL_SCENE_ID,
            action: SURFACE_ACTION_PLACE,
            host_macro: pick.occupied_macro,
            face: face_ordinal_from_normal(pick.face_normal),
            surface_type_id,
        },
    }
}

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

    pub fn selected_kind(&self) -> BuildKind {
        self.entries[self.selected].kind
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
        assert_eq!(p.selected_kind(), BuildKind::Material(2));
        // Confirmed list: 15 block-form (7 material + 3 circuit + 1 photo + 2 semi
        // + C4b 2 deep-semi diode/transistor) + 7 prefab + 2 surface fixtures.
        assert_eq!(p.entries().len(), 24);
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Material(6) && e.label == "power_block")
        );
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Material(20) && e.label == "resistor")
        );
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Material(22) && e.label == "diode")
        );
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Material(23) && e.label == "transistor")
        );
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Prefab(1) && e.label == "prefab:sphere")
        );
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Surface(4) && e.label == "torch")
        );
        assert!(
            p.entries()
                .iter()
                .any(|e| e.kind == BuildKind::Surface(5) && e.label == "lever")
        );
    }

    #[test]
    fn select_by_index_and_kind() {
        let mut p = BuildPalette::default();
        assert!(p.select(3)); // iron
        assert_eq!(p.selected_kind(), BuildKind::Material(5));
        assert!(!p.select(3)); // already selected → no change
        assert!(!p.select(9999)); // out of range → no change
        assert_eq!(p.selected_kind(), BuildKind::Material(5));
    }

    #[test]
    fn cycle_wraps_both_directions() {
        let mut p = BuildPalette::default();
        let n = p.entries().len();
        p.cycle(-1);
        assert_eq!(p.selected_index(), n - 1); // wrapped to last (lever)
        assert_eq!(p.selected().label, "lever");
        p.cycle(1);
        assert_eq!(p.selected_index(), 0); // wrapped back to first
    }

    #[test]
    fn face_ordinal_covers_all_six_axes() {
        assert_eq!(face_ordinal_from_normal([-1, 0, 0]), 0);
        assert_eq!(face_ordinal_from_normal([1, 0, 0]), 1);
        assert_eq!(face_ordinal_from_normal([0, -1, 0]), 2);
        assert_eq!(face_ordinal_from_normal([0, 1, 0]), 3);
        assert_eq!(face_ordinal_from_normal([0, 0, -1]), 4);
        assert_eq!(face_ordinal_from_normal([0, 0, 1]), 5);
        // Degenerate normal defaults to y_pos (top).
        assert_eq!(face_ordinal_from_normal([0, 0, 0]), 3);
    }

    fn pick(occupied: [i32; 3], face_normal: [i32; 3]) -> LivePick {
        LivePick {
            occupied_macro: occupied,
            face_normal,
        }
    }

    #[test]
    fn material_entry_places_block_at_adjacent_cell() {
        let p = pick([3, 0, 0], [-1, 0, 0]); // looking at the -X face
        match build_place_command(BuildKind::Material(5), &p) {
            NetworkCommand::EditVoxel {
                action,
                target_macro,
                material_id,
                ..
            } => {
                assert_eq!(action, ACTION_PLACE);
                assert_eq!(target_macro, [2, 0, 0]); // adjacent across the -X face
                assert_eq!(material_id, 5);
            }
            other => panic!("expected EditVoxel, got {other:?}"),
        }
    }

    #[test]
    fn prefab_entry_anchors_at_adjacent_cell() {
        let p = pick([5, 4, 5], [0, 1, 0]); // looking at the top face
        match build_place_command(BuildKind::Prefab(3), &p) {
            NetworkCommand::PlacePrefab {
                blueprint_id,
                anchor_macro,
                rotation,
                ..
            } => {
                assert_eq!(blueprint_id, 3);
                assert_eq!(anchor_macro, [5, 5, 5]); // one cell up from the host top
                assert_eq!(rotation, 0);
            }
            other => panic!("expected PlacePrefab, got {other:?}"),
        }
    }

    #[test]
    fn surface_entry_binds_to_picked_face_of_host() {
        let p = pick([5, 3, 5], [1, 0, 0]); // looking at the +X face of a wall
        match build_place_command(BuildKind::Surface(4), &p) {
            NetworkCommand::PlaceSurfaceElement {
                action,
                host_macro,
                face,
                surface_type_id,
                ..
            } => {
                assert_eq!(action, SURFACE_ACTION_PLACE);
                assert_eq!(host_macro, [5, 3, 5]); // the solid host, NOT the adjacent air
                assert_eq!(face, 1); // x_pos ordinal
                assert_eq!(surface_type_id, 4); // torch
            }
            other => panic!("expected PlaceSurfaceElement, got {other:?}"),
        }
    }
}
