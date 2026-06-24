//! Client→server `VoxelSurfaceElementIntent` (opcode 0x66): place or clear a
//! **surface element** (torch / lever fixture, or a passive decal) bound to one
//! face of a host macro cell — the 形态轨 C5.2 construction channel.
//!
//! Fixed **56-byte** body (mirrors `GateServer.Codec` decode, big-endian):
//! `request_id u64 | client_intent_seq u32 | logical_scene_id u64 | action u8 |
//!  target_world_micro i64×3 | face u8 | surface_type_id u16 |
//!  attribute_set_ref u32 | tag_set_ref u32`.
//!
//! `target_world_micro` picks the HOST macro the element decorates (the gate
//! floor-divides by 8, no face_normal offset — you select the solid block + a
//! face of it, unlike a block edit which offsets to the adjacent cell). `face`
//! is the 0..5 ordinal (x_neg=0..z_pos=5, matching the server `SurfaceCatalog`
//! and the client `surface_decal` `FACE_GEOM`). `owner_actor_id` is NOT sent —
//! the gate injects the caller's `cid` (anti-spoof).
//!
//! Server side: gate decodes 0x66 → `ChunkDirectory.apply_surface_element_intent`
//! → `ChunkProcess.put/clear_surface_element` (zero-occupancy truth mutation,
//! durable-before-ack) → full chunk snapshot re-push. The decal then renders via
//! the existing `surface_decal` mesher. Server-authoritative: we send the intent
//! and render the resulting snapshot, never a local optimistic decal.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

/// `action` values (mirror `GateServer.Codec` `voxel_surface_element_action`):
/// **0 = place** (put/overwrite), **1 = clear** (remove). Other values rejected.
pub const ACTION_PLACE: u8 = 0;
pub const ACTION_CLEAR: u8 = 1;

/// Micros per macro edge (mirror server `Types.micro_resolution()`).
pub const MICRO_PER_MACRO: i64 = 8;

/// Server `SurfaceCatalog` append-only fixture ids (the player-placeable ones).
pub const SURFACE_TYPE_TORCH: u16 = 4;
pub const SURFACE_TYPE_LEVER: u16 = 5;

/// The fixed body length the server expects (opcode-stripped).
pub const VOXEL_SURFACE_ELEMENT_INTENT_BODY_LEN: usize = 56;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SurfaceElementIntent {
    pub request_id: u64,
    pub client_intent_seq: u32,
    pub logical_scene_id: u64,
    pub action: u8,
    /// World position in micro units landing inside the HOST macro cell.
    pub target_world_micro: [i64; 3],
    /// Face ordinal 0..5 (x_neg=0, x_pos=1, y_neg=2, y_pos=3, z_neg=4, z_pos=5).
    pub face: u8,
    pub surface_type_id: u16,
    pub attribute_set_ref: u32,
    pub tag_set_ref: u32,
}

impl SurfaceElementIntent {
    /// Builds a place/clear at a GLOBAL macro coord + face ordinal. The caller
    /// pre-resolves the host macro (the solid block being decorated); we send
    /// `target_world_micro = macro × 8` so the gate floor-divides back to exactly
    /// `host_macro`. Refs left 0 (fixtures derive their visual from the type).
    pub fn macro_place(
        request_id: u64,
        client_intent_seq: u32,
        logical_scene_id: u64,
        action: u8,
        host_macro: [i32; 3],
        face: u8,
        surface_type_id: u16,
    ) -> Self {
        Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            action,
            target_world_micro: [
                host_macro[0] as i64 * MICRO_PER_MACRO,
                host_macro[1] as i64 * MICRO_PER_MACRO,
                host_macro[2] as i64 * MICRO_PER_MACRO,
            ],
            face,
            surface_type_id,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        }
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u32(self.client_intent_seq);
        w.u64(self.logical_scene_id);
        w.u8(self.action);
        w.i64(self.target_world_micro[0]);
        w.i64(self.target_world_micro[1]);
        w.i64(self.target_world_micro[2]);
        w.u8(self.face);
        w.u16(self.surface_type_id);
        w.u32(self.attribute_set_ref);
        w.u32(self.tag_set_ref);
    }

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("surface.request_id")?;
        let client_intent_seq = r.u32("surface.client_intent_seq")?;
        let logical_scene_id = r.u64("surface.logical_scene_id")?;
        let action = r.u8("surface.action")?;
        let target_world_micro = [
            r.i64("surface.wx")?,
            r.i64("surface.wy")?,
            r.i64("surface.wz")?,
        ];
        let face = r.u8("surface.face")?;
        let surface_type_id = r.u16("surface.surface_type_id")?;
        let attribute_set_ref = r.u32("surface.attribute_set_ref")?;
        let tag_set_ref = r.u32("surface.tag_set_ref")?;
        Ok(Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            action,
            target_world_micro,
            face,
            surface_type_id,
            attribute_set_ref,
            tag_set_ref,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_is_exactly_56_bytes() {
        let mut w = Writer::new();
        SurfaceElementIntent::macro_place(1, 1, 1, ACTION_PLACE, [5, 4, 5], 1, SURFACE_TYPE_TORCH)
            .encode(&mut w);
        assert_eq!(w.into_bytes().len(), VOXEL_SURFACE_ELEMENT_INTENT_BODY_LEN);
    }

    #[test]
    fn macro_place_resolves_host_macro_to_world_micro_and_round_trips() {
        // Torch on the +X face (ordinal 1) of host macro (10, -2, 3).
        let intent = SurfaceElementIntent::macro_place(
            7,
            3,
            1,
            ACTION_PLACE,
            [10, -2, 3],
            1,
            SURFACE_TYPE_TORCH,
        );
        assert_eq!(intent.action, ACTION_PLACE);
        assert_eq!(intent.target_world_micro, [80, -16, 24]);
        assert_eq!(intent.face, 1);
        assert_eq!(intent.surface_type_id, SURFACE_TYPE_TORCH);

        let mut w = Writer::new();
        intent.encode(&mut w);
        let bytes = w.into_bytes();
        // First 8 bytes = request_id big-endian (offset/endianness spot-check).
        assert_eq!(&bytes[0..8], &7u64.to_be_bytes());
        // The gate recovers the host macro: floor_div(world_micro, 8) == host_macro.
        let recovered = [
            intent.target_world_micro[0].div_euclid(MICRO_PER_MACRO),
            intent.target_world_micro[1].div_euclid(MICRO_PER_MACRO),
            intent.target_world_micro[2].div_euclid(MICRO_PER_MACRO),
        ];
        assert_eq!(recovered, [10, -2, 3]);
        assert_eq!(
            SurfaceElementIntent::decode(&mut Reader::new(&bytes)).unwrap(),
            intent
        );
    }

    #[test]
    fn clear_action_round_trips() {
        let intent = SurfaceElementIntent::macro_place(
            2,
            2,
            9,
            ACTION_CLEAR,
            [0, 0, 0],
            5,
            SURFACE_TYPE_LEVER,
        );
        assert_eq!(intent.action, ACTION_CLEAR);
        let mut w = Writer::new();
        intent.encode(&mut w);
        let bytes = w.into_bytes();
        assert_eq!(
            SurfaceElementIntent::decode(&mut Reader::new(&bytes)).unwrap(),
            intent
        );
    }

    #[test]
    fn negative_world_micro_survives() {
        let mut intent = SurfaceElementIntent::macro_place(
            1,
            1,
            1,
            ACTION_PLACE,
            [0, 0, 0],
            4,
            SURFACE_TYPE_TORCH,
        );
        intent.target_world_micro = [-1, -999_999, 5];
        let mut w = Writer::new();
        intent.encode(&mut w);
        let bytes = w.into_bytes();
        let decoded = SurfaceElementIntent::decode(&mut Reader::new(&bytes)).unwrap();
        assert_eq!(decoded.target_world_micro, [-1, -999_999, 5]);
    }
}
