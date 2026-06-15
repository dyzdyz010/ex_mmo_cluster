//! Socket-level voxel pipeline test: validates the real TCP `{packet,4}`
//! framing path that the live client uses, end to end.
//!
//! A mock "gate" streams a real server-golden `ChunkSnapshot` frame
//! (`<u32 len><0x62><snapshot_full.golden>`) over an actual TCP socket; the
//! client reassembles it with `take_frame` (the same function the network
//! thread uses), decodes it via `decode_server_payload`, ingests it into the
//! authority store, and meshes it. This covers the only layer the in-process
//! `voxel_pipeline` test skips: real socket transfer + length-prefix framing.
//!
//! Combined with the golden byte-parity tests (which prove the decoders match
//! the Elixir server byte-for-byte), this gives high confidence the client
//! renders authoritative voxels correctly against the live server.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::thread;

use bevy_client::protocol::{ServerMessage, decode_server_payload, take_frame};
use bevy_client::voxel::authority::{IngestOutcome, VoxelAuthorityStore};
use bevy_client::voxel::mesher::greedy_mesh_chunk;
use bevy_client::voxel::wire::VoxelServerMessage;

const OP_CHUNK_SNAPSHOT: u8 = 0x62;

fn golden(name: &str) -> Vec<u8> {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("../../apps/scene_server/priv/fixtures/voxel");
    path.push(format!("{name}.golden"));
    std::fs::read(&path).unwrap_or_else(|e| panic!("read golden {}: {e}", path.display()))
}

/// Frames a payload the way the gate's `{packet,4}` socket does: 4-byte
/// big-endian length prefix + payload.
fn framed(payload: &[u8]) -> Vec<u8> {
    let mut frame = (payload.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(payload);
    frame
}

#[test]
fn snapshot_streamed_over_tcp_decodes_ingests_and_meshes() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock gate");
    let addr = listener.local_addr().unwrap();

    // Mock gate: accept one client and stream a snapshot frame, split across two
    // writes to exercise frame reassembly across TCP segment boundaries.
    let snapshot_payload = {
        let mut p = vec![OP_CHUNK_SNAPSHOT];
        p.extend_from_slice(&golden("snapshot_full"));
        p
    };
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().expect("accept");
        let frame = framed(&snapshot_payload);
        let split = frame.len() / 2;
        socket.write_all(&frame[..split]).unwrap();
        socket.flush().unwrap();
        socket.write_all(&frame[split..]).unwrap();
        socket.flush().unwrap();
    });

    // Client side: read the stream and reassemble with the real `take_frame`.
    let mut stream = TcpStream::connect(addr).expect("connect mock gate");
    let mut buffer: Vec<u8> = Vec::new();
    let mut scratch = [0u8; 1024];
    let frame = loop {
        if let Some(frame) = take_frame(&mut buffer) {
            break frame;
        }
        let n = stream.read(&mut scratch).expect("read");
        assert!(n > 0, "stream closed before a full frame arrived");
        buffer.extend_from_slice(&scratch[..n]);
    };
    server.join().unwrap();

    // Real decode → ingest → mesh.
    let message = decode_server_payload(&frame).expect("decode frame");
    let snapshot = match message {
        ServerMessage::Voxel(VoxelServerMessage::ChunkSnapshot(s)) => s,
        other => panic!("expected Voxel(ChunkSnapshot), got {other:?}"),
    };
    let coord = snapshot.chunk_coord;

    let mut store = VoxelAuthorityStore::new();
    assert_eq!(
        store.ingest(&VoxelServerMessage::ChunkSnapshot(snapshot)),
        Ok(IngestOutcome::Applied(coord))
    );
    let mesh = greedy_mesh_chunk(store.chunk(coord).unwrap(), 1.0);
    assert!(
        !mesh.is_empty(),
        "a populated snapshot streamed over TCP must mesh to geometry"
    );
    assert!(mesh.quad_count() > 0);
}
