//! End-to-end voxel pipeline integration test (server-data → renderable mesh).
//!
//! Drives the *whole* client voxel path on REAL server-produced bytes (the
//! `apps/scene_server/priv/fixtures/voxel/*.golden` canonical payloads), proving
//! client⇄server functional alignment without a running server:
//!
//!   server `.golden` payload  →  `decode_server_payload` (net frame decode)
//!   →  `VoxelServerMessage`    →  `VoxelAuthorityStore.ingest` (version-gated)
//!   →  `mesh_chunk`            →  indexed, interior-culled mesh data
//!
//! If any wire field, ingest rule, or mesh step drifted from the server, this
//! fails — it is the load-bearing "the client renders authoritative voxels"
//! proof at the integration level.

use std::path::PathBuf;

use bevy_client::protocol::{ServerMessage, decode_server_payload};
use bevy_client::voxel::authority::{CellState, IngestOutcome, VoxelAuthorityStore};
use bevy_client::voxel::mesher::mesh_chunk;
use bevy_client::voxel::wire::VoxelServerMessage;

const OP_CHUNK_SNAPSHOT: u8 = 0x62;
const OP_CHUNK_DELTA: u8 = 0x63;

/// Reads a server golden payload and frames it as the client would receive it:
/// `opcode + payload` (the net layer strips the `{packet,4}` length prefix).
fn server_frame(opcode: u8, fixture: &str) -> Vec<u8> {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("../../apps/scene_server/priv/fixtures/voxel");
    path.push(format!("{fixture}.golden"));
    let payload =
        std::fs::read(&path).unwrap_or_else(|e| panic!("read golden {}: {e}", path.display()));
    let mut frame = vec![opcode];
    frame.extend_from_slice(&payload);
    frame
}

fn decode_voxel(opcode: u8, fixture: &str) -> VoxelServerMessage {
    match decode_server_payload(&server_frame(opcode, fixture)).unwrap() {
        ServerMessage::Voxel(voxel) => voxel,
        other => panic!("expected ServerMessage::Voxel, got {other:?}"),
    }
}

#[test]
fn full_snapshot_decodes_ingests_and_meshes() {
    // 1. Net-layer decode of a real server snapshot frame.
    let snapshot = decode_voxel(OP_CHUNK_SNAPSHOT, "snapshot_full");
    let coord = match &snapshot {
        VoxelServerMessage::ChunkSnapshot(s) => s.chunk_coord,
        other => panic!("expected ChunkSnapshot, got {other:?}"),
    };

    // 2. Ingest into the authority store (version-gated, flattens to cells).
    let mut store = VoxelAuthorityStore::new();
    assert_eq!(store.ingest(&snapshot), Ok(IngestOutcome::Applied(coord)));
    assert_eq!(store.take_dirty(), vec![coord]);

    let chunk = store.chunk(coord).expect("chunk ingested");
    assert_eq!(chunk.cells.len(), 4096);
    assert!(chunk.cells.iter().any(|c| matches!(c, CellState::Solid(_))));

    // 3. Mesh it — a populated chunk must produce real, interior-culled geometry.
    let mesh = mesh_chunk(chunk, 1.0);
    assert!(!mesh.is_empty(), "populated chunk must mesh to geometry");
    assert!(mesh.quad_count() > 0);
    // Indexed quads: 4 verts + 6 indices per face.
    assert_eq!(mesh.vertex_count(), mesh.quad_count() * 4);
    assert_eq!(mesh.indices.len(), mesh.quad_count() * 6);
    assert_eq!(mesh.positions.len(), mesh.normals.len());
    assert_eq!(mesh.positions.len(), mesh.material_ids.len());
}

#[test]
fn empty_snapshot_meshes_to_nothing() {
    let snapshot = decode_voxel(OP_CHUNK_SNAPSHOT, "snapshot_empty");
    let coord = match &snapshot {
        VoxelServerMessage::ChunkSnapshot(s) => s.chunk_coord,
        _ => unreachable!(),
    };
    let mut store = VoxelAuthorityStore::new();
    store.ingest(&snapshot).unwrap();
    let mesh = mesh_chunk(store.chunk(coord).unwrap(), 1.0);
    assert!(mesh.is_empty(), "all-empty chunk produces no geometry");
}

#[test]
fn delta_for_unsynced_chunk_requests_resync() {
    // A delta arriving before any snapshot for that chunk must not corrupt
    // truth — the store asks for a resync.
    let delta = decode_voxel(OP_CHUNK_DELTA, "delta_cell_solid");
    let coord = match &delta {
        VoxelServerMessage::ChunkDelta(d) => d.chunk_coord,
        _ => unreachable!(),
    };
    let mut store = VoxelAuthorityStore::new();
    assert_eq!(store.ingest(&delta), Ok(IngestOutcome::Resync(coord)));
    assert!(store.chunk(coord).is_none());
}
