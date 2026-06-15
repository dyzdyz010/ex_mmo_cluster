//! `CatalogPatch` (0x71) — versioned attribute/tag catalog increment.
//!
//! Wire layout (mirrors `SceneServer.Voxel.CatalogPatch.encode_for_wire`):
//! `schema_kind u8 | base_version u64 | new_version u64 | op_count u16 | ops[]`,
//! each op `op_kind u8 | entry_id u32 | payload_len u16 | payload[payload_len]`.
//!
//! Forward-compat discipline (matching the Elixir codec):
//! - unknown `op_kind` (0x04..0xFF) is preserved with its raw payload — the
//!   `payload_len` prefix exists precisely so middle nodes round-trip future
//!   ops without understanding them. At Phase 1.4 ALL op payloads are opaque.
//! - unknown `schema_kind` is a **hard error** (envelope-level dispatch tag;
//!   silently swallowing would corrupt the catalog stream).
//!
//! Note: the gate does not yet forward 0x71 to clients (Phase 5 pending), so
//! this decoder is wired ahead of runtime delivery.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

pub const SCHEMA_ATTRIBUTE: u8 = 0x01;
pub const SCHEMA_TAG: u8 = 0x02;

pub const OP_ADD: u8 = 0x01;
pub const OP_REMOVE: u8 = 0x02;
pub const OP_UPDATE: u8 = 0x03;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogPatchOp {
    pub op_kind: u8,
    pub entry_id: u32,
    /// Opaque at Phase 1.4 (typed in Phase 5); preserved verbatim.
    pub payload: Vec<u8>,
}

impl CatalogPatchOp {
    fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let op_kind = r.u8("catalog_patch_op.op_kind")?;
        let entry_id = r.u32("catalog_patch_op.entry_id")?;
        let payload_len = r.u16("catalog_patch_op.payload_len")? as usize;
        let payload = r.bytes(payload_len, "catalog_patch_op.payload")?.to_vec();
        Ok(Self {
            op_kind,
            entry_id,
            payload,
        })
    }

    fn encode(&self, w: &mut Writer) {
        w.u8(self.op_kind);
        w.u32(self.entry_id);
        w.u16(self.payload.len() as u16);
        w.bytes(&self.payload);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogPatch {
    pub schema_kind: u8,
    pub base_version: u64,
    pub new_version: u64,
    pub ops: Vec<CatalogPatchOp>,
}

impl CatalogPatch {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let schema_kind = r.u8("catalog_patch.schema_kind")?;
        if schema_kind != SCHEMA_ATTRIBUTE && schema_kind != SCHEMA_TAG {
            return Err(ProtocolError(format!(
                "catalog patch: unknown schema_kind 0x{schema_kind:02x}"
            )));
        }
        let base_version = r.u64("catalog_patch.base_version")?;
        let new_version = r.u64("catalog_patch.new_version")?;
        let op_count = r.u16("catalog_patch.op_count")? as usize;
        let mut ops = Vec::with_capacity(op_count);
        for _ in 0..op_count {
            ops.push(CatalogPatchOp::decode(r)?);
        }
        Ok(Self {
            schema_kind,
            base_version,
            new_version,
            ops,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u8(self.schema_kind);
        w.u64(self.base_version);
        w.u64(self.new_version);
        w.u16(self.ops.len() as u16);
        for op in &self.ops {
            op.encode(w);
        }
    }
}
