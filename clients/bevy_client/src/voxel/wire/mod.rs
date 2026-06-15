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

pub mod cursor;
pub mod invalidate;

pub use cursor::{Reader, Writer};
pub use invalidate::ChunkInvalidate;

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
    ChunkInvalidate(ChunkInvalidate),
}

/// Dispatches a voxel server payload (opcode already stripped by the net layer)
/// to the matching decoder, asserting the whole payload is consumed.
pub fn decode_voxel_server_message(
    opcode: u8,
    payload: &[u8],
) -> Result<VoxelServerMessage, ProtocolError> {
    let mut r = Reader::new(payload);
    let msg = match opcode {
        OP_CHUNK_INVALIDATE => {
            VoxelServerMessage::ChunkInvalidate(ChunkInvalidate::decode(&mut r)?)
        }
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
        VoxelServerMessage::ChunkInvalidate(m) => m.encode(&mut w),
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
