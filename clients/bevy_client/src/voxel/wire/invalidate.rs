//! `ChunkInvalidate` (0x69) — server tells the client to drop a chunk.
//!
//! Wire layout (mirrors `SceneServer.Voxel.Codec`):
//! `logical_scene_id u64 | chunk_coord i32×3 | reason u8` = 21 bytes.
//! Reasons: 0 unspecified, 1 migration_cutover, 2 region_removed,
//! 3 catalog_changed; unknown reasons round-trip as the raw byte.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkInvalidate {
    pub logical_scene_id: u64,
    pub chunk_coord: [i32; 3],
    pub reason: u8,
}

impl ChunkInvalidate {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let logical_scene_id = r.u64("invalidate.logical_scene_id")?;
        let chunk_coord = [
            r.i32("invalidate.cx")?,
            r.i32("invalidate.cy")?,
            r.i32("invalidate.cz")?,
        ];
        let reason = r.u8("invalidate.reason")?;
        Ok(Self {
            logical_scene_id,
            chunk_coord,
            reason,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.logical_scene_id);
        w.i32(self.chunk_coord[0]);
        w.i32(self.chunk_coord[1]);
        w.i32(self.chunk_coord[2]);
        w.u8(self.reason);
    }
}
