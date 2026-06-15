//! `ChunkDelta` (0x63) — incremental chunk mutations.
//!
//! Wire layout (mirrors `SceneServer.Voxel.Codec.encode_chunk_delta_payload`):
//! `logical_scene_id u64 | chunk_coord i32×3 | base_chunk_version u64 |
//!  new_chunk_version u64 | op_count u16 | ops[]`, where each op is
//! `delta_kind u8 | macro_index u16 | cell_version u32 | cell_hash u32 |
//!  payload_len u16 | payload[payload_len]`.
//!
//! `delta_kind`: 0 = CellEmpty (no payload), 1 = CellSolid (20B `NormalBlock`),
//! 2 = CellRefined (`RefinedCell`); unknown kinds round-trip as opaque bytes
//! (the `payload_len` prefix exists precisely so decoders can skip them).
//!
//! Version chaining: the client applies a delta only when `base_chunk_version`
//! equals its current chunk version, otherwise it requests a resync.

use super::blocks::{NormalBlock, RefinedCell};
use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeltaCell {
    Empty,
    Solid(NormalBlock),
    Refined(RefinedCell),
    /// Forward-compat: unknown `delta_kind` with its raw payload preserved.
    Opaque {
        kind: u8,
        bytes: Vec<u8>,
    },
}

impl DeltaCell {
    pub fn kind(&self) -> u8 {
        match self {
            DeltaCell::Empty => 0,
            DeltaCell::Solid(_) => 1,
            DeltaCell::Refined(_) => 2,
            DeltaCell::Opaque { kind, .. } => *kind,
        }
    }

    fn from_payload(kind: u8, payload: &[u8]) -> Result<Self, ProtocolError> {
        match kind {
            0 => {
                if !payload.is_empty() {
                    return Err(ProtocolError(format!(
                        "delta CellEmpty must have empty payload, got {} bytes",
                        payload.len()
                    )));
                }
                Ok(DeltaCell::Empty)
            }
            1 => {
                let mut r = Reader::new(payload);
                let block = NormalBlock::decode(&mut r)?;
                r.expect_end("delta CellSolid payload")?;
                Ok(DeltaCell::Solid(block))
            }
            2 => {
                let mut r = Reader::new(payload);
                let cell = RefinedCell::decode(&mut r)?;
                r.expect_end("delta CellRefined payload")?;
                Ok(DeltaCell::Refined(cell))
            }
            other => Ok(DeltaCell::Opaque {
                kind: other,
                bytes: payload.to_vec(),
            }),
        }
    }

    /// Encodes just the inner payload (no length prefix).
    fn encode_payload(&self) -> Vec<u8> {
        let mut w = Writer::new();
        match self {
            DeltaCell::Empty => {}
            DeltaCell::Solid(block) => block.encode(&mut w),
            DeltaCell::Refined(cell) => cell.encode(&mut w),
            DeltaCell::Opaque { bytes, .. } => w.bytes(bytes),
        }
        w.into_bytes()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeltaOp {
    pub macro_index: u16,
    pub cell_version: u32,
    pub cell_hash: u32,
    pub cell: DeltaCell,
}

impl DeltaOp {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let delta_kind = r.u8("delta_op.kind")?;
        let macro_index = r.u16("delta_op.macro_index")?;
        let cell_version = r.u32("delta_op.cell_version")?;
        let cell_hash = r.u32("delta_op.cell_hash")?;
        let payload_len = r.u16("delta_op.payload_len")? as usize;
        let payload = r.bytes(payload_len, "delta_op.payload")?;
        Ok(Self {
            macro_index,
            cell_version,
            cell_hash,
            cell: DeltaCell::from_payload(delta_kind, payload)?,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        let payload = self.cell.encode_payload();
        w.u8(self.cell.kind());
        w.u16(self.macro_index);
        w.u32(self.cell_version);
        w.u32(self.cell_hash);
        w.u16(payload.len() as u16);
        w.bytes(&payload);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkDelta {
    pub logical_scene_id: u64,
    pub chunk_coord: [i32; 3],
    pub base_chunk_version: u64,
    pub new_chunk_version: u64,
    pub ops: Vec<DeltaOp>,
}

impl ChunkDelta {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let logical_scene_id = r.u64("delta.logical_scene_id")?;
        let chunk_coord = [r.i32("delta.cx")?, r.i32("delta.cy")?, r.i32("delta.cz")?];
        let base_chunk_version = r.u64("delta.base_chunk_version")?;
        let new_chunk_version = r.u64("delta.new_chunk_version")?;
        let op_count = r.u16("delta.op_count")? as usize;
        let mut ops = Vec::with_capacity(op_count);
        for _ in 0..op_count {
            ops.push(DeltaOp::decode(r)?);
        }
        Ok(Self {
            logical_scene_id,
            chunk_coord,
            base_chunk_version,
            new_chunk_version,
            ops,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.logical_scene_id);
        w.i32(self.chunk_coord[0]);
        w.i32(self.chunk_coord[1]);
        w.i32(self.chunk_coord[2]);
        w.u64(self.base_chunk_version);
        w.u64(self.new_chunk_version);
        w.u16(self.ops.len() as u16);
        for op in &self.ops {
            op.encode(w);
        }
    }
}
