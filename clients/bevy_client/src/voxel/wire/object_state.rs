//! `ObjectStateDelta` (0x6C) — per-event object state change.
//!
//! Wire layout (mirrors `SceneServer.Voxel.Codec.encode_voxel_object_state_delta_payload`):
//! `logical_scene_id u64 | object_id u64 | object_version u64 | state_flags u32 |
//!  attribute_patch_count u16 | tag_patch_count u16 | affected_count u16 |
//!  affected_chunks[] {i32 cx, i32 cy, i32 cz}`.
//!
//! `state_flags` carries the bits triggered by *this* event (not the cumulative
//! instance mask); the client dedupes by monotonic `object_version`. The patch
//! counts are hardcoded `0` at Phase 4-bis (no bodies); preserved for exact
//! round-trip and future use. Drives debris / part-destroyed effects (M5).

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectStateDelta {
    pub logical_scene_id: u64,
    pub object_id: u64,
    pub object_version: u64,
    pub state_flags: u32,
    /// Phase 4-bis: always 0 (no body yet).
    pub attribute_patch_count: u16,
    /// Phase 4-bis: always 0 (no body yet).
    pub tag_patch_count: u16,
    pub affected_chunks: Vec<[i32; 3]>,
}

impl ObjectStateDelta {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let logical_scene_id = r.u64("object_state.logical_scene_id")?;
        let object_id = r.u64("object_state.object_id")?;
        let object_version = r.u64("object_state.object_version")?;
        let state_flags = r.u32("object_state.state_flags")?;
        let attribute_patch_count = r.u16("object_state.attribute_patch_count")?;
        let tag_patch_count = r.u16("object_state.tag_patch_count")?;
        let affected_count = r.u16("object_state.affected_count")? as usize;
        let mut affected_chunks = Vec::with_capacity(affected_count);
        for _ in 0..affected_count {
            affected_chunks.push([
                r.i32("object_state.cx")?,
                r.i32("object_state.cy")?,
                r.i32("object_state.cz")?,
            ]);
        }
        Ok(Self {
            logical_scene_id,
            object_id,
            object_version,
            state_flags,
            attribute_patch_count,
            tag_patch_count,
            affected_chunks,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.logical_scene_id);
        w.u64(self.object_id);
        w.u64(self.object_version);
        w.u32(self.state_flags);
        w.u16(self.attribute_patch_count);
        w.u16(self.tag_patch_count);
        w.u16(self.affected_chunks.len() as u16);
        for chunk in &self.affected_chunks {
            w.i32(chunk[0]);
            w.i32(chunk[1]);
            w.i32(chunk[2]);
        }
    }
}
