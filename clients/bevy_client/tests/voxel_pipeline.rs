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
use bevy_client::voxel::field_view::{DEFAULT_HEAT_THRESHOLD_C, temperature_overlay_mesh};
use bevy_client::voxel::mesher::mesh_chunk;
use bevy_client::voxel::wire::{FIELD_MASK_TEMPERATURE, VoxelServerMessage};

const OP_CHUNK_SNAPSHOT: u8 = 0x62;
const OP_CHUNK_DELTA: u8 = 0x63;
const OP_FIELD_REGION_SNAPSHOT: u8 = 0x73;
const OP_FIELD_REGION_DESTROYED: u8 = 0x74;

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
fn field_region_snapshot_decodes_and_overlays_on_real_server_bytes() {
    // C3 cross-language parity: the bevy 0x73 decoder consumes REAL server bytes
    // (FieldCodec.encode_snapshot_payload via gen_voxel_golden_fixtures), proving
    // the field wire format (incl. the little-endian f32 temperature quirk) is
    // byte-identical across Elixir↔Rust — not just bevy self-roundtrip.
    let message = decode_voxel(OP_FIELD_REGION_SNAPSHOT, "field_region_snapshot");
    let snapshot = match message {
        VoxelServerMessage::FieldRegionSnapshot(s) => s,
        other => panic!("expected FieldRegionSnapshot, got {other:?}"),
    };

    // Pinned values, identical to the server golden_fixture_test assertions.
    assert_eq!(snapshot.logical_scene_id, 1);
    assert_eq!(snapshot.chunk_coord, [2, 0, -3]);
    assert_eq!(snapshot.region_id, 42);
    assert_eq!(snapshot.tick_count, 7);
    assert_eq!(
        snapshot.field_mask & FIELD_MASK_TEMPERATURE,
        FIELD_MASK_TEMPERATURE
    );
    assert_eq!(snapshot.macro_indices, vec![0, 17, 273]);
    assert_eq!(snapshot.temperature, vec![120.0, 300.0, 60.0]);
    assert!(snapshot.electric_potential.is_empty());

    // End-to-end: the decoded field truth drives the FieldView overlay. All three
    // cells are above the 40°C threshold → one marker cube each (6 faces = 6
    // quads), so 18 quads total, all in the reserved heat-material range.
    let overlay = temperature_overlay_mesh(&snapshot, 100.0, DEFAULT_HEAT_THRESHOLD_C);
    let summary = overlay.summary();
    assert_eq!(summary.quad_count, 18);
    assert!(summary.structural_ok);
    // 300°C and 60/120°C land in different heat buckets → more than one material.
    assert!(summary.area_by_material.len() >= 2);
}

#[test]
fn field_region_destroyed_decodes_on_real_server_bytes() {
    let message = decode_voxel(OP_FIELD_REGION_DESTROYED, "field_region_destroyed");
    let destroyed = match message {
        VoxelServerMessage::FieldRegionDestroyed(d) => d,
        other => panic!("expected FieldRegionDestroyed, got {other:?}"),
    };
    assert_eq!(destroyed.logical_scene_id, 1);
    assert_eq!(destroyed.chunk_coord, [2, 0, -3]);
    assert_eq!(destroyed.region_id, 42);
    // reason byte 0x02 = explicit (DESTROY_REASON_EXPLICIT).
    assert_eq!(destroyed.destroy_reason, 0x02);
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
