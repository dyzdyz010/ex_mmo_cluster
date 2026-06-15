//! Client→server voxel AOI requests: `ChunkSubscribe` (0x60) and
//! `ChunkUnsubscribe` (0x61).
//!
//! `ChunkSubscribe` body (mirrors `GateServer.Codec`):
//! `request_id u64 | logical_scene_id u64 | center_chunk i32×3 |
//!  radius_l_inf u8 | want_snapshot u8 | known_count u16 |
//!  known[]{chunk_coord i32×3, chunk_version u64}`.
//!
//! `known[]` lets the client advertise the chunk versions it already holds so
//! the server can skip redundant snapshots and send deltas instead.
//!
//! `ChunkUnsubscribe` body:
//! `request_id u64 | logical_scene_id u64 | chunk_count u16 | chunks[]{i32×3}`.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KnownChunk {
    pub chunk_coord: [i32; 3],
    pub chunk_version: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkSubscribe {
    pub request_id: u64,
    pub logical_scene_id: u64,
    pub center_chunk: [i32; 3],
    pub radius_l_inf: u8,
    pub want_snapshot: bool,
    pub known: Vec<KnownChunk>,
}

impl ChunkSubscribe {
    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u64(self.logical_scene_id);
        w.i32(self.center_chunk[0]);
        w.i32(self.center_chunk[1]);
        w.i32(self.center_chunk[2]);
        w.u8(self.radius_l_inf);
        w.u8(self.want_snapshot as u8);
        w.u16(self.known.len() as u16);
        for known in &self.known {
            w.i32(known.chunk_coord[0]);
            w.i32(known.chunk_coord[1]);
            w.i32(known.chunk_coord[2]);
            w.u64(known.chunk_version);
        }
    }

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("subscribe.request_id")?;
        let logical_scene_id = r.u64("subscribe.logical_scene_id")?;
        let center_chunk = [
            r.i32("subscribe.cx")?,
            r.i32("subscribe.cy")?,
            r.i32("subscribe.cz")?,
        ];
        let radius_l_inf = r.u8("subscribe.radius_l_inf")?;
        let want_snapshot = r.u8("subscribe.want_snapshot")? != 0;
        let known_count = r.u16("subscribe.known_count")? as usize;
        let mut known = Vec::with_capacity(known_count);
        for _ in 0..known_count {
            known.push(KnownChunk {
                chunk_coord: [
                    r.i32("subscribe.known.cx")?,
                    r.i32("subscribe.known.cy")?,
                    r.i32("subscribe.known.cz")?,
                ],
                chunk_version: r.u64("subscribe.known.version")?,
            });
        }
        Ok(Self {
            request_id,
            logical_scene_id,
            center_chunk,
            radius_l_inf,
            want_snapshot,
            known,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkUnsubscribe {
    pub request_id: u64,
    pub logical_scene_id: u64,
    pub chunks: Vec<[i32; 3]>,
}

impl ChunkUnsubscribe {
    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u64(self.logical_scene_id);
        w.u16(self.chunks.len() as u16);
        for chunk in &self.chunks {
            w.i32(chunk[0]);
            w.i32(chunk[1]);
            w.i32(chunk[2]);
        }
    }

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("unsubscribe.request_id")?;
        let logical_scene_id = r.u64("unsubscribe.logical_scene_id")?;
        let chunk_count = r.u16("unsubscribe.chunk_count")? as usize;
        let mut chunks = Vec::with_capacity(chunk_count);
        for _ in 0..chunk_count {
            chunks.push([
                r.i32("unsubscribe.cx")?,
                r.i32("unsubscribe.cy")?,
                r.i32("unsubscribe.cz")?,
            ]);
        }
        Ok(Self {
            request_id,
            logical_scene_id,
            chunks,
        })
    }
}

/// A client→server voxel message with its opcode, for the net layer to frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoxelClientMessage {
    ChunkSubscribe(ChunkSubscribe),
    ChunkUnsubscribe(ChunkUnsubscribe),
}

impl VoxelClientMessage {
    pub fn opcode(&self) -> u8 {
        match self {
            VoxelClientMessage::ChunkSubscribe(_) => super::OP_CHUNK_SUBSCRIBE,
            VoxelClientMessage::ChunkUnsubscribe(_) => super::OP_CHUNK_UNSUBSCRIBE,
        }
    }

    /// Encodes the body (opcode-stripped); the net layer prepends `opcode()`.
    pub fn encode_body(&self) -> Vec<u8> {
        let mut w = Writer::new();
        match self {
            VoxelClientMessage::ChunkSubscribe(m) => m.encode(&mut w),
            VoxelClientMessage::ChunkUnsubscribe(m) => m.encode(&mut w),
        }
        w.into_bytes()
    }
}
