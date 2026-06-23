//! `VoxelIntentResult` (opcode 0x68): the authoritative ACK the gate sends in
//! reply to every client `VoxelEditIntent` (0x70) / prefab / build intent, on
//! BOTH success and failure.
//!
//! Mirrors `GateServer.Codec` `{:voxel_intent_result}` 1:1 at the byte level
//! (see `apps/gate_server/lib/gate_server/codec.ex` encode arm + the
//! `encode_voxel_authoritative` ref layout). Big-endian throughout.
//!
//! Before this existed the client routed 0x68 (inside the 0x60..=0x75 voxel
//! range) to the voxel dispatcher, which had no arm and returned an `Err`, so
//! every edit produced a spurious "decode error: unsupported server opcode
//! 0x68" log line and the ACK (accepted / deferred / rejected / stale + reason)
//! was silently dropped — the client could not react to a rejected/stale edit.

use crate::protocol::ProtocolError;

use super::cursor::{Reader, Writer};

/// One authoritative cell the server reports as the post-edit truth for the
/// affected macro (so a client could apply it without waiting for the broadcast
/// `ChunkDelta`). `cell_payload` is the opaque mode-specific blob (`payload_kind`
/// selects how to interpret it); we preserve it verbatim for byte-exact
/// round-trips rather than eagerly materializing a typed cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthoritativeCell {
    pub chunk_coord: [i32; 3],
    pub chunk_version: u64,
    pub macro_index: u16,
    pub cell_version: u32,
    pub cell_hash: u32,
    pub payload_kind: u8,
    pub cell_payload: Vec<u8>,
}

/// Decoded 0x68 ACK. `client_intent_seq` echoes the monotonic seq the client
/// stamped on the originating `VoxelEditIntent`, so the edit UX can correlate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoxelIntentResult {
    pub request_id: u64,
    pub client_intent_seq: u32,
    pub logical_scene_id: u64,
    /// 0 = accepted, 1 = deferred, 2 = rejected, 3 = stale (see `result_label`).
    pub result_code: u8,
    pub result_ref: u64,
    pub authoritative: Vec<AuthoritativeCell>,
    pub reason: String,
}

impl VoxelIntentResult {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("intent_result.request_id")?;
        let client_intent_seq = r.u32("intent_result.client_intent_seq")?;
        let logical_scene_id = r.u64("intent_result.logical_scene_id")?;
        let result_code = r.u8("intent_result.result_code")?;
        let result_ref = r.u64("intent_result.result_ref")?;
        let count = r.u16("intent_result.authoritative_count")? as usize;
        let mut authoritative = Vec::with_capacity(count);
        for _ in 0..count {
            let cx = r.i32("intent_result.auth.cx")?;
            let cy = r.i32("intent_result.auth.cy")?;
            let cz = r.i32("intent_result.auth.cz")?;
            let chunk_version = r.u64("intent_result.auth.chunk_version")?;
            let macro_index = r.u16("intent_result.auth.macro_index")?;
            let cell_version = r.u32("intent_result.auth.cell_version")?;
            let cell_hash = r.u32("intent_result.auth.cell_hash")?;
            let payload_kind = r.u8("intent_result.auth.payload_kind")?;
            let payload_len = r.u32("intent_result.auth.cell_payload_len")? as usize;
            let cell_payload = r
                .bytes(payload_len, "intent_result.auth.cell_payload")?
                .to_vec();
            authoritative.push(AuthoritativeCell {
                chunk_coord: [cx, cy, cz],
                chunk_version,
                macro_index,
                cell_version,
                cell_hash,
                payload_kind,
                cell_payload,
            });
        }
        let reason_len = r.u16("intent_result.reason_len")? as usize;
        let reason_bytes = r.bytes(reason_len, "intent_result.reason")?;
        let reason = String::from_utf8_lossy(reason_bytes).into_owned();
        Ok(Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            result_code,
            result_ref,
            authoritative,
            reason,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u32(self.client_intent_seq);
        w.u64(self.logical_scene_id);
        w.u8(self.result_code);
        w.u64(self.result_ref);
        w.u16(self.authoritative.len() as u16);
        for a in &self.authoritative {
            w.i32(a.chunk_coord[0]);
            w.i32(a.chunk_coord[1]);
            w.i32(a.chunk_coord[2]);
            w.u64(a.chunk_version);
            w.u16(a.macro_index);
            w.u32(a.cell_version);
            w.u32(a.cell_hash);
            w.u8(a.payload_kind);
            w.u32(a.cell_payload.len() as u32);
            w.bytes(&a.cell_payload);
        }
        w.u16(self.reason.len() as u16);
        w.bytes(self.reason.as_bytes());
    }

    /// Human/observer label for `result_code` (mirrors the server atoms).
    pub fn result_label(&self) -> &'static str {
        match self.result_code {
            0 => "accepted",
            1 => "deferred",
            2 => "rejected",
            3 => "stale",
            _ => "unknown",
        }
    }

    /// Whether the edit was NOT applied (rejected/stale/unknown) — the cases the
    /// edit UX should surface to the player.
    pub fn is_failure(&self) -> bool {
        !matches!(self.result_code, 0 | 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(result_code: u8) -> VoxelIntentResult {
        VoxelIntentResult {
            request_id: 0xDEAD_BEEF_0000_0001,
            client_intent_seq: 42,
            logical_scene_id: 1,
            result_code,
            result_ref: 0xCAFE,
            authoritative: vec![AuthoritativeCell {
                chunk_coord: [1, -2, 3],
                chunk_version: 7,
                macro_index: 1234,
                cell_version: 9,
                cell_hash: 0x1122_3344,
                payload_kind: 1,
                cell_payload: vec![0xAA, 0xBB, 0xCC],
            }],
            reason: "ok".to_string(),
        }
    }

    #[test]
    fn round_trips_byte_exact() {
        for code in 0..=4u8 {
            let msg = sample(code);
            let mut w = Writer::new();
            msg.encode(&mut w);
            let bytes = w.into_bytes();
            let decoded = VoxelIntentResult::decode(&mut Reader::new(&bytes)).unwrap();
            assert_eq!(decoded, msg);
            // Re-encode is byte-stable.
            let mut w2 = Writer::new();
            decoded.encode(&mut w2);
            assert_eq!(w2.into_bytes(), bytes);
        }
    }

    #[test]
    fn result_labels_and_failure_classification() {
        assert_eq!(sample(0).result_label(), "accepted");
        assert!(!sample(0).is_failure());
        assert!(!sample(1).is_failure()); // deferred still applied authoritatively
        assert_eq!(sample(2).result_label(), "rejected");
        assert!(sample(2).is_failure());
        assert_eq!(sample(3).result_label(), "stale");
        assert!(sample(3).is_failure());
    }

    #[test]
    fn decodes_empty_authoritative_and_reason() {
        let msg = VoxelIntentResult {
            request_id: 1,
            client_intent_seq: 0,
            logical_scene_id: 1,
            result_code: 2,
            result_ref: 0,
            authoritative: vec![],
            reason: String::new(),
        };
        let mut w = Writer::new();
        msg.encode(&mut w);
        let decoded = VoxelIntentResult::decode(&mut Reader::new(&w.into_bytes())).unwrap();
        assert_eq!(decoded, msg);
    }
}
