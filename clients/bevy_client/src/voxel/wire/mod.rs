//! Voxel wire protocol codec for the Bevy client.
//!
//! Mirrors `SceneServer.Voxel.Codec` (and the gate forwarding layer) 1:1 at
//! the byte level. This is the M1 foundation that lets the bevy client become
//! a renderer of **server-authoritative** voxel truth instead of an
//! offline-local sandbox.
//!
//! Discipline (ported from `web_client`, the reference oracle):
//! - explicit byte-offset reads/writes via [`cursor::Reader`]/[`cursor::Writer`],
//!   no derive magic that could hide layout drift;
//! - strict trailing-byte guard (`expect_end`) per message;
//! - **symmetric** decode/encode so the parity tests can decode a server
//!   `.golden` fixture, re-encode, and assert byte-for-byte equality.
//!
//! Opcodes live in the 0x60–0x75 range; the `.golden` fixtures under
//! `apps/scene_server/priv/fixtures/voxel/` are the canonical payloads
//! (no opcode byte, no `{packet,4}` length prefix).

pub mod blocks;
pub mod catalog_patch;
pub mod cursor;
pub mod delta;
pub mod invalidate;
pub mod object_state;
pub mod snapshot;

pub use blocks::{MaskWords, MicroLayer, NormalBlock, ObjectCoverRef, RefinedCell};
pub use catalog_patch::{CatalogPatch, CatalogPatchOp};
pub use cursor::{Reader, Writer};
pub use delta::{ChunkDelta, DeltaCell, DeltaOp};
pub use invalidate::ChunkInvalidate;
pub use object_state::ObjectStateDelta;
pub use snapshot::{
    AttributeEntry, AttributeSet, AttributeValue, ChunkObjectRef, ChunkSnapshot,
    EnvironmentSummary, MacroHeader, SnapshotSection, TagSet,
};

use crate::protocol::ProtocolError;

// ── Server → client opcodes ────────────────────────────────────────────────
pub const OP_CHUNK_SNAPSHOT: u8 = 0x62;
pub const OP_CHUNK_DELTA: u8 = 0x63;
pub const OP_VOXEL_INTENT_RESULT: u8 = 0x68;
pub const OP_CHUNK_INVALIDATE: u8 = 0x69;
pub const OP_OBJECT_STATE_DELTA: u8 = 0x6C;
pub const OP_CATALOG_PATCH: u8 = 0x71;
pub const OP_ENVIRONMENT_UPDATED: u8 = 0x72;
pub const OP_FIELD_REGION_SNAPSHOT: u8 = 0x73;
pub const OP_FIELD_REGION_DESTROYED: u8 = 0x74;

// ── Client → server opcodes ────────────────────────────────────────────────
pub const OP_CHUNK_SUBSCRIBE: u8 = 0x60;
pub const OP_CHUNK_UNSUBSCRIBE: u8 = 0x61;
pub const OP_VOXEL_EDIT_INTENT: u8 = 0x70;

/// Decoded server→client voxel message. Grows one variant per M1 sub-step.
#[derive(Debug, Clone, PartialEq)]
pub enum VoxelServerMessage {
    ChunkSnapshot(ChunkSnapshot),
    ChunkDelta(ChunkDelta),
    ChunkInvalidate(ChunkInvalidate),
    ObjectStateDelta(ObjectStateDelta),
    CatalogPatch(CatalogPatch),
}

/// Dispatches a voxel server payload (opcode already stripped by the net layer)
/// to the matching decoder, asserting the whole payload is consumed.
pub fn decode_voxel_server_message(
    opcode: u8,
    payload: &[u8],
) -> Result<VoxelServerMessage, ProtocolError> {
    let mut r = Reader::new(payload);
    let msg = match opcode {
        OP_CHUNK_SNAPSHOT => VoxelServerMessage::ChunkSnapshot(ChunkSnapshot::decode(&mut r)?),
        OP_CHUNK_DELTA => VoxelServerMessage::ChunkDelta(ChunkDelta::decode(&mut r)?),
        OP_CHUNK_INVALIDATE => {
            VoxelServerMessage::ChunkInvalidate(ChunkInvalidate::decode(&mut r)?)
        }
        OP_OBJECT_STATE_DELTA => {
            VoxelServerMessage::ObjectStateDelta(ObjectStateDelta::decode(&mut r)?)
        }
        OP_CATALOG_PATCH => VoxelServerMessage::CatalogPatch(CatalogPatch::decode(&mut r)?),
        other => {
            return Err(ProtocolError(format!(
                "voxel wire: unsupported server opcode 0x{other:02x}"
            )));
        }
    };
    r.expect_end("voxel server message")?;
    Ok(msg)
}

/// Re-encodes a [`VoxelServerMessage`] payload (opcode-stripped); the mirror of
/// [`decode_voxel_server_message`], used by the round-trip parity tests.
pub fn encode_voxel_server_message(msg: &VoxelServerMessage) -> Vec<u8> {
    let mut w = Writer::new();
    match msg {
        VoxelServerMessage::ChunkSnapshot(m) => m.encode(&mut w),
        VoxelServerMessage::ChunkDelta(m) => m.encode(&mut w),
        VoxelServerMessage::ChunkInvalidate(m) => m.encode(&mut w),
        VoxelServerMessage::ObjectStateDelta(m) => m.encode(&mut w),
        VoxelServerMessage::CatalogPatch(m) => m.encode(&mut w),
    }
    w.into_bytes()
}

#[cfg(test)]
pub(crate) mod fixtures {
    //! Cross-language golden-fixture harness: load a server-produced canonical
    //! payload and round-trip it through the bevy codec, asserting byte
    //! equality. Highest-leverage borrow from the web client.

    use std::path::PathBuf;

    /// Reads `apps/scene_server/priv/fixtures/voxel/<name>.golden` relative to
    /// this crate's manifest dir (`clients/bevy_client`).
    pub fn golden(name: &str) -> Vec<u8> {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.push("../../apps/scene_server/priv/fixtures/voxel");
        path.push(format!("{name}.golden"));
        std::fs::read(&path)
            .unwrap_or_else(|e| panic!("read golden fixture {}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip_invalidate(name: &str) {
        let golden = fixtures::golden(name);
        let decoded = ChunkInvalidate::decode(&mut Reader::new(&golden))
            .unwrap_or_else(|e| panic!("decode {name}: {}", e.0));
        let mut w = Writer::new();
        decoded.encode(&mut w);
        assert_eq!(
            w.into_bytes(),
            golden,
            "round-trip byte mismatch for fixture {name}"
        );
    }

    #[test]
    fn chunk_invalidate_golden_roundtrip() {
        for name in [
            "chunk_invalidate_unspecified",
            "chunk_invalidate_migration_cutover",
            "chunk_invalidate_region_removed",
            "chunk_invalidate_catalog_changed",
        ] {
            roundtrip_invalidate(name);
        }
    }

    fn roundtrip_delta(name: &str) {
        let golden = fixtures::golden(name);
        let decoded = ChunkDelta::decode(&mut Reader::new(&golden))
            .unwrap_or_else(|e| panic!("decode {name}: {}", e.0));
        let mut w = Writer::new();
        decoded.encode(&mut w);
        assert_eq!(
            w.into_bytes(),
            golden,
            "round-trip byte mismatch for fixture {name}"
        );
    }

    fn roundtrip_snapshot(name: &str) {
        let golden = fixtures::golden(name);
        let decoded = ChunkSnapshot::decode(&mut Reader::new(&golden))
            .unwrap_or_else(|e| panic!("decode {name}: {}", e.0));
        let mut w = Writer::new();
        decoded.encode(&mut w);
        assert_eq!(
            w.into_bytes(),
            golden,
            "round-trip byte mismatch for fixture {name}"
        );
    }

    #[test]
    fn chunk_snapshot_golden_roundtrip() {
        // Every section type, empty + populated.
        for name in [
            "snapshot_empty",
            "snapshot_macro_only",
            "snapshot_refined",
            "snapshot_attribute_pool",
            "snapshot_tag_pool",
            "snapshot_environment",
            "snapshot_object_refs",
            "snapshot_full",
        ] {
            roundtrip_snapshot(name);
        }
    }

    #[test]
    fn chunk_snapshot_empty_structure() {
        let golden = fixtures::golden("snapshot_empty");
        let snap = ChunkSnapshot::decode(&mut Reader::new(&golden)).unwrap();
        assert_eq!(snap.schema_version, 1);
        assert_eq!(snap.chunk_size_in_macro, 16);
        assert_eq!(snap.micro_resolution, 8);
        assert_eq!(snap.chunk_version, 1);
        assert_eq!(snap.chunk_hash, 0xE70921CDF143C5EE);
        assert_eq!(snap.sections.len(), 7);
        // 16^3 = 4096 macro headers, all empty mode.
        let headers = snap.macro_headers().expect("macro headers section");
        assert_eq!(headers.len(), 4096);
        assert!(headers.iter().all(|h| h.mode == 0));
        // All payload pools empty.
        assert_eq!(snap.normal_blocks().map(<[_]>::len), Some(0));
        assert_eq!(snap.refined_cells().map(<[_]>::len), Some(0));
    }

    #[test]
    fn chunk_delta_golden_roundtrip() {
        // Covers CellEmpty(0), CellSolid(1), CellRefined(2) op kinds + multi-op.
        for name in [
            "delta_cell_empty",
            "delta_cell_solid",
            "delta_cell_refined",
            "delta_multi_op",
        ] {
            roundtrip_delta(name);
        }
    }

    #[test]
    fn chunk_delta_solid_decode_values() {
        // delta_cell_solid: scene=10, base=1→new=2, one CellSolid op
        // (macro 1234, material 11, health 100).
        let golden = fixtures::golden("delta_cell_solid");
        let delta = ChunkDelta::decode(&mut Reader::new(&golden)).unwrap();
        assert_eq!(delta.logical_scene_id, 10);
        assert_eq!(delta.base_chunk_version, 1);
        assert_eq!(delta.new_chunk_version, 2);
        assert_eq!(delta.ops.len(), 1);
        let op = &delta.ops[0];
        assert_eq!(op.macro_index, 1234);
        match &op.cell {
            DeltaCell::Solid(block) => {
                assert_eq!(block.material_id, 11);
                assert_eq!(block.health, 100);
            }
            other => panic!("expected CellSolid, got {other:?}"),
        }
    }

    fn roundtrip_object_state(name: &str) {
        let golden = fixtures::golden(name);
        let decoded = ObjectStateDelta::decode(&mut Reader::new(&golden))
            .unwrap_or_else(|e| panic!("decode {name}: {}", e.0));
        let mut w = Writer::new();
        decoded.encode(&mut w);
        assert_eq!(
            w.into_bytes(),
            golden,
            "round-trip byte mismatch for fixture {name}"
        );
    }

    #[test]
    fn object_state_delta_golden_roundtrip() {
        for name in [
            "object_state_delta_damaged",
            "object_state_delta_destroyed",
            "object_state_delta_part_destroyed",
        ] {
            roundtrip_object_state(name);
        }
    }

    #[test]
    fn object_state_delta_part_destroyed_values() {
        let golden = fixtures::golden("object_state_delta_part_destroyed");
        let osd = ObjectStateDelta::decode(&mut Reader::new(&golden)).unwrap();
        assert_eq!(osd.logical_scene_id, 7);
        assert_eq!(osd.object_version, 42);
        assert_eq!(osd.state_flags, 0x04);
        assert_eq!(osd.affected_chunks, vec![[0, 0, 0], [1, 0, 0]]);
    }

    fn roundtrip_catalog_patch(name: &str) {
        let golden = fixtures::golden(name);
        let decoded = CatalogPatch::decode(&mut Reader::new(&golden))
            .unwrap_or_else(|e| panic!("decode {name}: {}", e.0));
        let mut w = Writer::new();
        decoded.encode(&mut w);
        assert_eq!(
            w.into_bytes(),
            golden,
            "round-trip byte mismatch for fixture {name}"
        );
    }

    #[test]
    fn catalog_patch_golden_roundtrip() {
        for name in [
            "catalog_patch_attribute_add",
            "catalog_patch_tag_remove",
            "catalog_patch_forward_compat_skip",
        ] {
            roundtrip_catalog_patch(name);
        }
    }

    #[test]
    fn catalog_patch_forward_compat_preserves_unknown_op_kind() {
        // forward_compat_skip carries an op with op_kind=0xFE + 4-byte payload.
        let golden = fixtures::golden("catalog_patch_forward_compat_skip");
        let patch = CatalogPatch::decode(&mut Reader::new(&golden)).unwrap();
        assert_eq!(patch.schema_kind, catalog_patch::SCHEMA_ATTRIBUTE);
        assert!(
            patch.ops.iter().any(|op| op.op_kind == 0xFE),
            "expected an unknown op_kind 0xFE preserved"
        );
    }

    #[test]
    fn catalog_patch_rejects_unknown_schema_kind() {
        // schema_kind=0x09 (reserved) must hard-error.
        let bytes = [0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let err = CatalogPatch::decode(&mut Reader::new(&bytes)).unwrap_err();
        assert!(err.0.contains("unknown schema_kind"), "{}", err.0);
    }

    #[test]
    fn chunk_invalidate_decode_values() {
        // unspecified fixture: logical_scene_id=50, coord=(1,2,3), reason=0.
        let golden = fixtures::golden("chunk_invalidate_unspecified");
        let decoded = ChunkInvalidate::decode(&mut Reader::new(&golden)).unwrap();
        assert_eq!(decoded.logical_scene_id, 50);
        assert_eq!(decoded.chunk_coord, [1, 2, 3]);
        assert_eq!(decoded.reason, 0);
    }

    #[test]
    fn dispatch_rejects_unknown_opcode() {
        let err = decode_voxel_server_message(0x01, &[]).unwrap_err();
        assert!(err.0.contains("unsupported server opcode"), "{}", err.0);
    }

    #[test]
    fn dispatch_rejects_trailing_bytes() {
        let mut golden = fixtures::golden("chunk_invalidate_unspecified");
        golden.push(0xFF); // extra trailing byte
        let err = decode_voxel_server_message(OP_CHUNK_INVALIDATE, &golden).unwrap_err();
        assert!(err.0.contains("trailing bytes"), "{}", err.0);
    }
}
