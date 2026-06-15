//! `FieldRegionSnapshot` (0x73) + `FieldRegionDestroyed` (0x74) — the Phase 6
//! local-field stream carrying the R1–R8 electric / thermal / ionization data
//! the涌现 reaction layer produces.
//!
//! **Endianness quirk:** the whole voxel protocol is big-endian EXCEPT the
//! field value arrays here, which are **little-endian f32** (matching the
//! server's `FieldLayer` storage). The `f32_le` cursor methods exist for this.
//!
//! `FieldRegionSnapshot` body (the opcode byte is the frame msg-type, stripped
//! by the net layer before this decoder, same as every other message):
//! `logical_scene_id u64 | chunk_coord i32×3 | region_id u64 | tick_count u32 |
//!  field_mask u8 | cell_count u16 | macro_indices u16×n |
//!  temperature f32le×n (bit0) | electric_potential f32le×n (bit1) |
//!  electric_current f32le×n (bit3) | ionization u8×n (bit2)`.
//!
//! Value arrays appear in wire order temp→potential→current→ionization (NOT
//! bit order — current/bit3 precedes ionization/bit2), each present iff its
//! `field_mask` bit is set and length `cell_count`.
//!
//! Note: the gate does not yet forward 0x73/0x74 to clients in all paths; this
//! decoder is wired ahead so field visuals (M5) can consume it.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

pub const FIELD_MASK_TEMPERATURE: u8 = 0x01;
pub const FIELD_MASK_ELECTRIC_POTENTIAL: u8 = 0x02;
pub const FIELD_MASK_IONIZATION: u8 = 0x04;
pub const FIELD_MASK_ELECTRIC_CURRENT: u8 = 0x08;

pub const DESTROY_REASON_EXPIRED: u8 = 0x00;
pub const DESTROY_REASON_LEASE_REVOKED: u8 = 0x01;
pub const DESTROY_REASON_EXPLICIT: u8 = 0x02;
pub const DESTROY_REASON_CHUNK_CRASH: u8 = 0x03;

fn read_f32_array(
    r: &mut Reader,
    present: bool,
    cell_count: usize,
    what: &str,
) -> Result<Vec<f32>, ProtocolError> {
    if !present {
        return Ok(Vec::new());
    }
    let mut values = Vec::with_capacity(cell_count);
    for _ in 0..cell_count {
        values.push(r.f32_le(what)?);
    }
    Ok(values)
}

#[derive(Debug, Clone, PartialEq)]
pub struct FieldRegionSnapshot {
    pub logical_scene_id: u64,
    pub chunk_coord: [i32; 3],
    pub region_id: u64,
    pub tick_count: u32,
    pub field_mask: u8,
    pub macro_indices: Vec<u16>,
    /// Present (length `cell_count`) iff `field_mask & FIELD_MASK_TEMPERATURE`.
    pub temperature: Vec<f32>,
    /// Present iff `field_mask & FIELD_MASK_ELECTRIC_POTENTIAL`.
    pub electric_potential: Vec<f32>,
    /// Present iff `field_mask & FIELD_MASK_ELECTRIC_CURRENT`.
    pub electric_current: Vec<f32>,
    /// Present iff `field_mask & FIELD_MASK_IONIZATION`.
    pub ionization: Vec<u8>,
}

impl FieldRegionSnapshot {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let logical_scene_id = r.u64("field_snapshot.logical_scene_id")?;
        let chunk_coord = [
            r.i32("field_snapshot.cx")?,
            r.i32("field_snapshot.cy")?,
            r.i32("field_snapshot.cz")?,
        ];
        let region_id = r.u64("field_snapshot.region_id")?;
        let tick_count = r.u32("field_snapshot.tick_count")?;
        let field_mask = r.u8("field_snapshot.field_mask")?;
        let cell_count = r.u16("field_snapshot.cell_count")? as usize;

        let mut macro_indices = Vec::with_capacity(cell_count);
        for _ in 0..cell_count {
            macro_indices.push(r.u16("field_snapshot.macro_index")?);
        }

        // Wire order: temp, potential, current, ionization.
        let temperature = read_f32_array(
            r,
            field_mask & FIELD_MASK_TEMPERATURE != 0,
            cell_count,
            "field.temperature",
        )?;
        let electric_potential = read_f32_array(
            r,
            field_mask & FIELD_MASK_ELECTRIC_POTENTIAL != 0,
            cell_count,
            "field.electric_potential",
        )?;
        let electric_current = read_f32_array(
            r,
            field_mask & FIELD_MASK_ELECTRIC_CURRENT != 0,
            cell_count,
            "field.electric_current",
        )?;
        let ionization = if field_mask & FIELD_MASK_IONIZATION != 0 {
            let mut v = Vec::with_capacity(cell_count);
            for _ in 0..cell_count {
                v.push(r.u8("field.ionization")?);
            }
            v
        } else {
            Vec::new()
        };

        Ok(Self {
            logical_scene_id,
            chunk_coord,
            region_id,
            tick_count,
            field_mask,
            macro_indices,
            temperature,
            electric_potential,
            electric_current,
            ionization,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.logical_scene_id);
        w.i32(self.chunk_coord[0]);
        w.i32(self.chunk_coord[1]);
        w.i32(self.chunk_coord[2]);
        w.u64(self.region_id);
        w.u32(self.tick_count);
        w.u8(self.field_mask);
        w.u16(self.macro_indices.len() as u16);
        for index in &self.macro_indices {
            w.u16(*index);
        }
        if self.field_mask & FIELD_MASK_TEMPERATURE != 0 {
            for v in &self.temperature {
                w.f32_le(*v);
            }
        }
        if self.field_mask & FIELD_MASK_ELECTRIC_POTENTIAL != 0 {
            for v in &self.electric_potential {
                w.f32_le(*v);
            }
        }
        if self.field_mask & FIELD_MASK_ELECTRIC_CURRENT != 0 {
            for v in &self.electric_current {
                w.f32_le(*v);
            }
        }
        if self.field_mask & FIELD_MASK_IONIZATION != 0 {
            for v in &self.ionization {
                w.u8(*v);
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldRegionDestroyed {
    pub logical_scene_id: u64,
    pub chunk_coord: [i32; 3],
    pub region_id: u64,
    pub destroy_reason: u8,
}

impl FieldRegionDestroyed {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(Self {
            logical_scene_id: r.u64("field_destroyed.logical_scene_id")?,
            chunk_coord: [
                r.i32("field_destroyed.cx")?,
                r.i32("field_destroyed.cy")?,
                r.i32("field_destroyed.cz")?,
            ],
            region_id: r.u64("field_destroyed.region_id")?,
            destroy_reason: r.u8("field_destroyed.destroy_reason")?,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.logical_scene_id);
        w.i32(self.chunk_coord[0]);
        w.i32(self.chunk_coord[1]);
        w.i32(self.chunk_coord[2]);
        w.u64(self.region_id);
        w.u8(self.destroy_reason);
    }
}
