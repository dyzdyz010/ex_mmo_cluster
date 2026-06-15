//! Shared voxel cell payload primitives used by both `ChunkSnapshot` sections
//! and `ChunkDelta` ops: `NormalBlock` (20B solid), and the refined-cell family
//! (`RefinedCell` / `MicroLayer` / `ObjectCoverRef`) built on 512-bit
//! (`[u64; 8]`) occupancy masks.
//!
//! Layouts mirror `SceneServer.Voxel.Codec` exactly (verified against the
//! refined-cell + normal-block encoders, not the survey's guessed sizes):
//! `MicroLayer` = mask(64) + 28 = 92B; `ObjectCoverRef` = 12 + mask(64) = 76B.

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

/// 512-bit occupancy/coverage mask as 8 big-endian u64 words.
pub type MaskWords = [u64; 8];

pub(crate) fn decode_mask(r: &mut Reader, what: &str) -> Result<MaskWords, ProtocolError> {
    let mut words = [0u64; 8];
    for word in words.iter_mut() {
        *word = r.u64(what)?;
    }
    Ok(words)
}

pub(crate) fn encode_mask(w: &mut Writer, mask: &MaskWords) {
    for word in mask {
        w.u64(*word);
    }
}

/// Fixed 20-byte solid-block payload (snapshot NormalBlocks pool entry and
/// `delta_kind = 1` op payload).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalBlock {
    pub material_id: u16,
    pub state_flags: u32,
    pub health: u16,
    pub temperature_delta: i16,
    pub moisture_delta: i16,
    pub attribute_set_ref: u32,
    pub tag_set_ref: u32,
}

impl NormalBlock {
    pub const WIRE_SIZE: usize = 20;

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(Self {
            material_id: r.u16("normal_block.material_id")?,
            state_flags: r.u32("normal_block.state_flags")?,
            health: r.u16("normal_block.health")?,
            temperature_delta: r.i16("normal_block.temperature_delta")?,
            moisture_delta: r.i16("normal_block.moisture_delta")?,
            attribute_set_ref: r.u32("normal_block.attribute_set_ref")?,
            tag_set_ref: r.u32("normal_block.tag_set_ref")?,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u16(self.material_id);
        w.u32(self.state_flags);
        w.u16(self.health);
        w.i16(self.temperature_delta);
        w.i16(self.moisture_delta);
        w.u32(self.attribute_set_ref);
        w.u32(self.tag_set_ref);
    }
}

/// One micro material layer of a refined cell (mask + per-layer attributes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MicroLayer {
    pub mask_words: MaskWords,
    pub material_id: u16,
    pub state_flags: u32,
    pub health: u16,
    pub attribute_set_ref: u32,
    pub tag_set_ref: u32,
    pub owner_object_id: u64,
    pub owner_part_id: u32,
}

impl MicroLayer {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(Self {
            mask_words: decode_mask(r, "micro_layer.mask")?,
            material_id: r.u16("micro_layer.material_id")?,
            state_flags: r.u32("micro_layer.state_flags")?,
            health: r.u16("micro_layer.health")?,
            attribute_set_ref: r.u32("micro_layer.attribute_set_ref")?,
            tag_set_ref: r.u32("micro_layer.tag_set_ref")?,
            owner_object_id: r.u64("micro_layer.owner_object_id")?,
            owner_part_id: r.u32("micro_layer.owner_part_id")?,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        encode_mask(w, &self.mask_words);
        w.u16(self.material_id);
        w.u32(self.state_flags);
        w.u16(self.health);
        w.u32(self.attribute_set_ref);
        w.u32(self.tag_set_ref);
        w.u64(self.owner_object_id);
        w.u32(self.owner_part_id);
    }
}

/// Object coverage reference inside a refined cell (which object/part owns
/// which micro slots).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectCoverRef {
    pub owner_object_id: u64,
    pub owner_part_id: u32,
    pub mask_words: MaskWords,
}

impl ObjectCoverRef {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(Self {
            owner_object_id: r.u64("object_cover_ref.owner_object_id")?,
            owner_part_id: r.u32("object_cover_ref.owner_part_id")?,
            mask_words: decode_mask(r, "object_cover_ref.mask")?,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.owner_object_id);
        w.u32(self.owner_part_id);
        encode_mask(w, &self.mask_words);
    }
}

/// A refined (sub-voxel) macro cell: 512-bit occupancy + boundary cache +
/// material layers + object coverage refs. Consumed directly in wire form
/// (no lossy intermediate, unlike the web client's `wireToRefinedCell`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefinedCell {
    pub occupancy_words: MaskWords,
    pub boundary_cache: u64,
    pub layers: Vec<MicroLayer>,
    pub object_refs: Vec<ObjectCoverRef>,
}

impl RefinedCell {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let occupancy_words = decode_mask(r, "refined_cell.occupancy")?;
        let boundary_cache = r.u64("refined_cell.boundary_cache")?;
        let layer_count = r.u16("refined_cell.layer_count")? as usize;
        let mut layers = Vec::with_capacity(layer_count);
        for _ in 0..layer_count {
            layers.push(MicroLayer::decode(r)?);
        }
        let object_ref_count = r.u16("refined_cell.object_ref_count")? as usize;
        let mut object_refs = Vec::with_capacity(object_ref_count);
        for _ in 0..object_ref_count {
            object_refs.push(ObjectCoverRef::decode(r)?);
        }
        Ok(Self {
            occupancy_words,
            boundary_cache,
            layers,
            object_refs,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        encode_mask(w, &self.occupancy_words);
        w.u64(self.boundary_cache);
        w.u16(self.layers.len() as u16);
        for layer in &self.layers {
            layer.encode(w);
        }
        w.u16(self.object_refs.len() as u16);
        for object_ref in &self.object_refs {
            object_ref.encode(w);
        }
    }
}
