//! Client→server typed voxel edit: `VoxelEditIntent` (0x70) — the construction
//! system's single-cell place/break channel.
//!
//! Fixed **91-byte** body (mirrors `GateServer.Codec` decode, protocol §13.6.1):
//! `request_id u64 | client_intent_seq u32 | logical_scene_id u64 | action u8 |
//!  target_granularity u8 | target_world_micro i64×3 | face_normal i8×3 |
//!  material_id u16 | blueprint_ref u32 | object_ref u64 | part_ref u32 |
//!  attribute_patch_ref u32 | expected_chunk_version u64 | expected_cell_hash u32 |
//!  client_hint_hash u64`.
//!
//! The server side is complete (gate decodes 0x70 → `ChunkDirectory.apply_intent`
//! → truth mutation → `ChunkDelta` broadcast); this is the missing client encoder
//! that lets the live build UX send authoritative edits instead of mutating a
//! local-only world. Build is server-authoritative: we send the intent and render
//! the resulting `ChunkDelta`, never a local optimistic edit.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

/// `action` values (mirror `GateServer.Codec` `voxel_edit_intent_op`): **0 = place**
/// (put block), **1 = break** (clear). Server rejects 2/3/4 (damage/replace/attr).
pub const ACTION_PLACE: u8 = 0;
pub const ACTION_BREAK: u8 = 1;

/// `target_granularity` values: macro cell vs refined micro slot.
pub const GRANULARITY_MACRO: u8 = 0;
pub const GRANULARITY_MICRO: u8 = 1;

/// Micros per macro edge (mirrors server `Types.micro_resolution()` / client
/// `MICRO_PER_MACRO`). A macro cell at coord M spans `[M*8, (M+1)*8)` in micro.
pub const MICRO_PER_MACRO: i64 = 8;

/// The fixed body length the server expects (opcode-stripped).
pub const VOXEL_EDIT_INTENT_BODY_LEN: usize = 91;

/// Wire sentinel for "no `expected_chunk_version` pin" — mirrors the server
/// `@expected_chunk_version_unspecified` (`chunk_process.ex`), which the apply
/// path normalizes to `nil` (skip the optimistic-concurrency check). MUST be
/// sent for an infinite-resource build: sending `0` is read as "I expect chunk
/// version 0" and every edit is rejected `:stale_chunk_version` (live chunks
/// start at version ≥ 1).
pub const EXPECTED_CHUNK_VERSION_UNSPECIFIED: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Wire sentinel for "no `expected_cell_hash` pin" (server
/// `@expected_cell_hash_unspecified`). Same rationale as the version sentinel.
pub const EXPECTED_CELL_HASH_UNSPECIFIED: u32 = 0xFFFF_FFFF;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VoxelEditIntent {
    pub request_id: u64,
    pub client_intent_seq: u32,
    pub logical_scene_id: u64,
    pub action: u8,
    pub target_granularity: u8,
    /// World position in micro units (1 macro = micro_resolution micros).
    pub target_world_micro: [i64; 3],
    /// Hit face normal (components in {-1,0,1}); picks the adjacent cell for place.
    pub face_normal: [i8; 3],
    pub material_id: u16,
    pub blueprint_ref: u32,
    pub object_ref: u64,
    pub part_ref: u32,
    pub attribute_patch_ref: u32,
    pub expected_chunk_version: u64,
    pub expected_cell_hash: u32,
    pub client_hint_hash: u64,
}

impl VoxelEditIntent {
    /// Builds a **macro-cell** edit at a GLOBAL macro coord. The caller pre-resolves
    /// the target macro (the adjacent cell for place, the clicked cell for break),
    /// so we send a zero `face_normal`: the gate adds `face_normal` (0) then
    /// floor-divides world_micro by 8, landing exactly on `target_macro`. Refs left
    /// 0; `expected_chunk_version`/`expected_cell_hash` are sent as the UNSPECIFIED
    /// sentinels (not 0!) so the server skips the optimistic-concurrency gate —
    /// infinite-resource build. Sending 0 means "expect version 0" and every edit
    /// is rejected `:stale_chunk_version`.
    pub fn macro_edit(
        request_id: u64,
        client_intent_seq: u32,
        logical_scene_id: u64,
        action: u8,
        target_macro: [i32; 3],
        material_id: u16,
    ) -> Self {
        Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            action,
            target_granularity: GRANULARITY_MACRO,
            target_world_micro: [
                target_macro[0] as i64 * MICRO_PER_MACRO,
                target_macro[1] as i64 * MICRO_PER_MACRO,
                target_macro[2] as i64 * MICRO_PER_MACRO,
            ],
            face_normal: [0, 0, 0],
            material_id,
            blueprint_ref: 0,
            object_ref: 0,
            part_ref: 0,
            attribute_patch_ref: 0,
            expected_chunk_version: EXPECTED_CHUNK_VERSION_UNSPECIFIED,
            expected_cell_hash: EXPECTED_CELL_HASH_UNSPECIFIED,
            client_hint_hash: 0,
        }
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u32(self.client_intent_seq);
        w.u64(self.logical_scene_id);
        w.u8(self.action);
        w.u8(self.target_granularity);
        w.i64(self.target_world_micro[0]);
        w.i64(self.target_world_micro[1]);
        w.i64(self.target_world_micro[2]);
        // i8 face normals: write the raw byte (server reads them as 8-signed).
        w.u8(self.face_normal[0] as u8);
        w.u8(self.face_normal[1] as u8);
        w.u8(self.face_normal[2] as u8);
        w.u16(self.material_id);
        w.u32(self.blueprint_ref);
        w.u64(self.object_ref);
        w.u32(self.part_ref);
        w.u32(self.attribute_patch_ref);
        w.u64(self.expected_chunk_version);
        w.u32(self.expected_cell_hash);
        w.u64(self.client_hint_hash);
    }

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("edit.request_id")?;
        let client_intent_seq = r.u32("edit.client_intent_seq")?;
        let logical_scene_id = r.u64("edit.logical_scene_id")?;
        let action = r.u8("edit.action")?;
        let target_granularity = r.u8("edit.target_granularity")?;
        let target_world_micro = [
            r.i64("edit.wx")?,
            r.i64("edit.wy")?,
            r.i64("edit.wz")?,
        ];
        let face_normal = [
            r.u8("edit.fnx")? as i8,
            r.u8("edit.fny")? as i8,
            r.u8("edit.fnz")? as i8,
        ];
        let material_id = r.u16("edit.material_id")?;
        let blueprint_ref = r.u32("edit.blueprint_ref")?;
        let object_ref = r.u64("edit.object_ref")?;
        let part_ref = r.u32("edit.part_ref")?;
        let attribute_patch_ref = r.u32("edit.attribute_patch_ref")?;
        let expected_chunk_version = r.u64("edit.expected_chunk_version")?;
        let expected_cell_hash = r.u32("edit.expected_cell_hash")?;
        let client_hint_hash = r.u64("edit.client_hint_hash")?;

        Ok(Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            action,
            target_granularity,
            target_world_micro,
            face_normal,
            material_id,
            blueprint_ref,
            object_ref,
            part_ref,
            attribute_patch_ref,
            expected_chunk_version,
            expected_cell_hash,
            client_hint_hash,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> VoxelEditIntent {
        VoxelEditIntent {
            request_id: 0x0102_0304_0506_0708,
            client_intent_seq: 7,
            logical_scene_id: 1,
            action: ACTION_PLACE,
            target_granularity: GRANULARITY_MACRO,
            target_world_micro: [75_000, -3_200, 123_456],
            face_normal: [0, 1, 0],
            material_id: 2,
            blueprint_ref: 0,
            object_ref: 0,
            part_ref: 0,
            attribute_patch_ref: 0,
            expected_chunk_version: 0,
            expected_cell_hash: 0,
            client_hint_hash: 0xDEAD_BEEF_0000_0001,
        }
    }

    #[test]
    fn body_is_exactly_91_bytes() {
        let mut w = Writer::new();
        sample().encode(&mut w);
        assert_eq!(w.into_bytes().len(), VOXEL_EDIT_INTENT_BODY_LEN);
    }

    #[test]
    fn round_trips_through_server_field_order() {
        let intent = sample();
        let mut w = Writer::new();
        intent.encode(&mut w);
        let bytes = w.into_bytes();
        let mut r = Reader::new(&bytes);
        assert_eq!(VoxelEditIntent::decode(&mut r).unwrap(), intent);
    }

    #[test]
    fn macro_edit_resolves_global_macro_to_world_micro() {
        // Place at global macro (10, -2, 3): world_micro = macro*8, zero face_normal,
        // macro granularity, place action.
        let intent = VoxelEditIntent::macro_edit(1, 1, 1, ACTION_PLACE, [10, -2, 3], 2);
        assert_eq!(intent.action, ACTION_PLACE);
        assert_eq!(intent.target_granularity, GRANULARITY_MACRO);
        assert_eq!(intent.target_world_micro, [80, -16, 24]);
        assert_eq!(intent.face_normal, [0, 0, 0]);
        assert_eq!(intent.material_id, 2);
        // Infinite-resource build: no optimistic-concurrency pin — MUST be the
        // UNSPECIFIED sentinels, NOT 0 (0 = "expect version 0" → every live edit
        // rejected :stale_chunk_version, since live chunks start at version ≥ 1).
        assert_eq!(
            intent.expected_chunk_version,
            EXPECTED_CHUNK_VERSION_UNSPECIFIED
        );
        assert_eq!(intent.expected_cell_hash, EXPECTED_CELL_HASH_UNSPECIFIED);
        // The gate recovers the macro: floor_div(world_micro + 0, 8) == target_macro.
        let recovered = [
            intent.target_world_micro[0].div_euclid(MICRO_PER_MACRO),
            intent.target_world_micro[1].div_euclid(MICRO_PER_MACRO),
            intent.target_world_micro[2].div_euclid(MICRO_PER_MACRO),
        ];
        assert_eq!(recovered, [10, -2, 3]);

        // Break ignores material/face; action = 1.
        let brk = VoxelEditIntent::macro_edit(2, 2, 1, ACTION_BREAK, [10, -2, 3], 0);
        assert_eq!(brk.action, ACTION_BREAK);
    }

    #[test]
    fn negative_face_normal_and_world_micro_survive() {
        let mut intent = sample();
        intent.face_normal = [-1, 0, -1];
        intent.target_world_micro = [-1, -999_999, 5];
        let mut w = Writer::new();
        intent.encode(&mut w);
        let bytes = w.into_bytes();
        // First 8 bytes are request_id big-endian (spot-check field offset/endianness).
        assert_eq!(&bytes[0..8], &intent.request_id.to_be_bytes());
        let mut r = Reader::new(&bytes);
        let decoded = VoxelEditIntent::decode(&mut r).unwrap();
        assert_eq!(decoded.face_normal, [-1, 0, -1]);
        assert_eq!(decoded.target_world_micro, [-1, -999_999, 5]);
    }
}
