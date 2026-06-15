//! `ChunkSnapshot` (0x62) — full authoritative chunk state.
//!
//! Wire layout (mirrors `SceneServer.Voxel.Codec.encode_chunk_snapshot_payload`):
//!
//! ```text
//! request_id u64 | logical_scene_id u64 | chunk_coord i32×3 |
//! schema_version u16 | chunk_size_in_macro u8 | micro_resolution u8 |
//! chunk_version u64 | chunk_hash u64 | section_count u16 | sections[]
//! ```
//!
//! Each section is a TLV: `section_type u8 | section_len u32 | data[len]`.
//! Canonical section order is 0x01..0x07; unknown section types round-trip
//! opaque (forward-compat). The count-prefixed pools (NormalBlocks, RefinedCells,
//! AttributeSets, TagSets, EnvironmentSummaries, ObjectRefs) all use a `u32`
//! length prefix, so an empty pool is exactly `<<0u32>>`.
//!
//! `chunk_hash` is the server's value; the client preserves (does not recompute)
//! it for round-trip and dedupe.

use super::blocks::{NormalBlock, RefinedCell};
use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

// Section type tags.
pub const SECTION_MACRO_HEADERS: u8 = 0x01;
pub const SECTION_NORMAL_BLOCKS: u8 = 0x02;
pub const SECTION_REFINED_CELLS: u8 = 0x03;
pub const SECTION_ATTRIBUTE_SETS: u8 = 0x04;
pub const SECTION_TAG_SETS: u8 = 0x05;
pub const SECTION_ENVIRONMENT_SUMMARIES: u8 = 0x06;
pub const SECTION_OBJECT_REFS: u8 = 0x07;

/// One 19-byte macro cell header. `payload_index`/`environment_index` use the
/// `0xffffffff` sentinel for empty cells.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacroHeader {
    pub mode: u8,
    pub flags: u16,
    pub payload_index: u32,
    pub environment_index: u32,
    pub cell_version: u32,
    pub cell_hash: u32,
}

impl MacroHeader {
    pub const WIRE_SIZE: usize = 19;

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(Self {
            mode: r.u8("macro_header.mode")?,
            flags: r.u16("macro_header.flags")?,
            payload_index: r.u32("macro_header.payload_index")?,
            environment_index: r.u32("macro_header.environment_index")?,
            cell_version: r.u32("macro_header.cell_version")?,
            cell_hash: r.u32("macro_header.cell_hash")?,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u8(self.mode);
        w.u16(self.flags);
        w.u32(self.payload_index);
        w.u32(self.environment_index);
        w.u32(self.cell_version);
        w.u32(self.cell_hash);
    }
}

/// Typed attribute value tagged by `value_type` (0x01..0x05).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttributeValue {
    I16(i16),
    U16(u16),
    /// Q16.16 fixed-point stored as i32.
    Fixed32(i32),
    Enum8(u8),
    Bitset32(u32),
}

impl AttributeValue {
    pub fn value_type(&self) -> u8 {
        match self {
            AttributeValue::I16(_) => 0x01,
            AttributeValue::U16(_) => 0x02,
            AttributeValue::Fixed32(_) => 0x03,
            AttributeValue::Enum8(_) => 0x04,
            AttributeValue::Bitset32(_) => 0x05,
        }
    }

    fn decode(value_type: u8, r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(match value_type {
            0x01 => AttributeValue::I16(r.i16("attr.i16")?),
            0x02 => AttributeValue::U16(r.u16("attr.u16")?),
            0x03 => AttributeValue::Fixed32(r.i32("attr.fixed32")?),
            0x04 => AttributeValue::Enum8(r.u8("attr.enum8")?),
            0x05 => AttributeValue::Bitset32(r.u32("attr.bitset32")?),
            other => {
                return Err(ProtocolError(format!(
                    "attribute entry: unknown value_type 0x{other:02x}"
                )));
            }
        })
    }

    fn encode(&self, w: &mut Writer) {
        match self {
            AttributeValue::I16(v) => w.i16(*v),
            AttributeValue::U16(v) => w.u16(*v),
            AttributeValue::Fixed32(v) => w.i32(*v),
            AttributeValue::Enum8(v) => w.u8(*v),
            AttributeValue::Bitset32(v) => w.u32(*v),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttributeEntry {
    pub key_id: u32,
    pub value: AttributeValue,
}

impl AttributeEntry {
    fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let key_id = r.u32("attr_entry.key_id")?;
        let value_type = r.u8("attr_entry.value_type")?;
        let value = AttributeValue::decode(value_type, r)?;
        Ok(Self { key_id, value })
    }

    fn encode(&self, w: &mut Writer) {
        w.u32(self.key_id);
        w.u8(self.value.value_type());
        self.value.encode(w);
    }
}

/// A pooled attribute "value bag": ordered `(key_id, value)` entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttributeSet {
    pub entries: Vec<AttributeEntry>,
}

impl AttributeSet {
    fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let entry_count = r.u16("attr_set.entry_count")? as usize;
        let mut entries = Vec::with_capacity(entry_count);
        for _ in 0..entry_count {
            entries.push(AttributeEntry::decode(r)?);
        }
        Ok(Self { entries })
    }

    fn encode(&self, w: &mut Writer) {
        w.u16(self.entries.len() as u16);
        for entry in &self.entries {
            entry.encode(w);
        }
    }
}

/// A pooled tag set: flat ascending u32 tag ids.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagSet {
    pub tag_ids: Vec<u32>,
}

impl TagSet {
    fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let tag_count = r.u16("tag_set.tag_count")? as usize;
        let mut tag_ids = Vec::with_capacity(tag_count);
        for _ in 0..tag_count {
            tag_ids.push(r.u32("tag_set.tag_id")?);
        }
        Ok(Self { tag_ids })
    }

    fn encode(&self, w: &mut Writer) {
        w.u16(self.tag_ids.len() as u16);
        for id in &self.tag_ids {
            w.u32(*id);
        }
    }
}

/// 14-byte macro environment summary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnvironmentSummary {
    pub default_temperature: i16,
    pub default_moisture: i16,
    pub current_temperature: i16,
    pub current_moisture: i16,
    pub field_mask: u16,
    pub source_hash: u32,
}

impl EnvironmentSummary {
    fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        Ok(Self {
            default_temperature: r.i16("env.default_temperature")?,
            default_moisture: r.i16("env.default_moisture")?,
            current_temperature: r.i16("env.current_temperature")?,
            current_moisture: r.i16("env.current_moisture")?,
            field_mask: r.u16("env.field_mask")?,
            source_hash: r.u32("env.source_hash")?,
        })
    }

    fn encode(&self, w: &mut Writer) {
        w.i16(self.default_temperature);
        w.i16(self.default_moisture);
        w.i16(self.current_temperature);
        w.i16(self.current_moisture);
        w.u16(self.field_mask);
        w.u32(self.source_hash);
    }
}

/// 30-byte chunk object reference (which objects cover this chunk + their AABB).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChunkObjectRef {
    pub object_id: u64,
    pub object_version: u64,
    pub covered_macro_min: [u8; 3],
    pub covered_macro_max: [u8; 3],
    pub cover_hash: u64,
}

impl ChunkObjectRef {
    fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let object_id = r.u64("object_ref.object_id")?;
        let object_version = r.u64("object_ref.object_version")?;
        let covered_macro_min = [
            r.u8("object_ref.min_x")?,
            r.u8("object_ref.min_y")?,
            r.u8("object_ref.min_z")?,
        ];
        let covered_macro_max = [
            r.u8("object_ref.max_x")?,
            r.u8("object_ref.max_y")?,
            r.u8("object_ref.max_z")?,
        ];
        let cover_hash = r.u64("object_ref.cover_hash")?;
        Ok(Self {
            object_id,
            object_version,
            covered_macro_min,
            covered_macro_max,
            cover_hash,
        })
    }

    fn encode(&self, w: &mut Writer) {
        w.u64(self.object_id);
        w.u64(self.object_version);
        w.bytes(&self.covered_macro_min);
        w.bytes(&self.covered_macro_max);
        w.u64(self.cover_hash);
    }
}

/// One decoded snapshot section, preserving wire order for exact round-trip.
#[derive(Debug, Clone, PartialEq)]
pub enum SnapshotSection {
    MacroHeaders(Vec<MacroHeader>),
    NormalBlocks(Vec<NormalBlock>),
    RefinedCells(Vec<RefinedCell>),
    AttributeSets(Vec<AttributeSet>),
    TagSets(Vec<TagSet>),
    EnvironmentSummaries(Vec<EnvironmentSummary>),
    ObjectRefs(Vec<ChunkObjectRef>),
    /// Forward-compat: unknown section type with its raw bytes preserved.
    Unknown {
        section_type: u8,
        bytes: Vec<u8>,
    },
}

impl SnapshotSection {
    fn section_type(&self) -> u8 {
        match self {
            SnapshotSection::MacroHeaders(_) => SECTION_MACRO_HEADERS,
            SnapshotSection::NormalBlocks(_) => SECTION_NORMAL_BLOCKS,
            SnapshotSection::RefinedCells(_) => SECTION_REFINED_CELLS,
            SnapshotSection::AttributeSets(_) => SECTION_ATTRIBUTE_SETS,
            SnapshotSection::TagSets(_) => SECTION_TAG_SETS,
            SnapshotSection::EnvironmentSummaries(_) => SECTION_ENVIRONMENT_SUMMARIES,
            SnapshotSection::ObjectRefs(_) => SECTION_OBJECT_REFS,
            SnapshotSection::Unknown { section_type, .. } => *section_type,
        }
    }

    fn decode(section_type: u8, data: &[u8]) -> Result<Self, ProtocolError> {
        let mut r = Reader::new(data);
        let section = match section_type {
            SECTION_MACRO_HEADERS => {
                // The macro-headers section is a flat array of 19-byte headers
                // (no count prefix); decode until the section is exhausted.
                let mut headers = Vec::new();
                while r.remaining() > 0 {
                    headers.push(MacroHeader::decode(&mut r)?);
                }
                SnapshotSection::MacroHeaders(headers)
            }
            SECTION_NORMAL_BLOCKS => {
                SnapshotSection::NormalBlocks(decode_pool(&mut r, NormalBlock::decode)?)
            }
            SECTION_REFINED_CELLS => {
                SnapshotSection::RefinedCells(decode_pool(&mut r, RefinedCell::decode)?)
            }
            SECTION_ATTRIBUTE_SETS => {
                SnapshotSection::AttributeSets(decode_pool(&mut r, AttributeSet::decode)?)
            }
            SECTION_TAG_SETS => SnapshotSection::TagSets(decode_pool(&mut r, TagSet::decode)?),
            SECTION_ENVIRONMENT_SUMMARIES => SnapshotSection::EnvironmentSummaries(decode_pool(
                &mut r,
                EnvironmentSummary::decode,
            )?),
            SECTION_OBJECT_REFS => {
                SnapshotSection::ObjectRefs(decode_pool(&mut r, ChunkObjectRef::decode)?)
            }
            other => {
                return Ok(SnapshotSection::Unknown {
                    section_type: other,
                    bytes: data.to_vec(),
                });
            }
        };
        r.expect_end("snapshot section")?;
        Ok(section)
    }

    /// Encodes the section's inner data bytes (no type/length header).
    fn encode_data(&self) -> Vec<u8> {
        let mut w = Writer::new();
        match self {
            SnapshotSection::MacroHeaders(headers) => {
                for h in headers {
                    h.encode(&mut w);
                }
            }
            SnapshotSection::NormalBlocks(v) => encode_pool(&mut w, v, NormalBlock::encode),
            SnapshotSection::RefinedCells(v) => encode_pool(&mut w, v, RefinedCell::encode),
            SnapshotSection::AttributeSets(v) => encode_pool(&mut w, v, AttributeSet::encode),
            SnapshotSection::TagSets(v) => encode_pool(&mut w, v, TagSet::encode),
            SnapshotSection::EnvironmentSummaries(v) => {
                encode_pool(&mut w, v, EnvironmentSummary::encode)
            }
            SnapshotSection::ObjectRefs(v) => encode_pool(&mut w, v, ChunkObjectRef::encode),
            SnapshotSection::Unknown { bytes, .. } => w.bytes(bytes),
        }
        w.into_bytes()
    }
}

/// Decodes a `u32`-count-prefixed pool (empty pool = `<<0u32>>`).
fn decode_pool<T>(
    r: &mut Reader,
    mut decode_one: impl FnMut(&mut Reader) -> Result<T, ProtocolError>,
) -> Result<Vec<T>, ProtocolError> {
    let count = r.u32("pool.count")? as usize;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        items.push(decode_one(r)?);
    }
    Ok(items)
}

fn encode_pool<T>(w: &mut Writer, items: &[T], encode_one: impl Fn(&T, &mut Writer)) {
    w.u32(items.len() as u32);
    for item in items {
        encode_one(item, w);
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChunkSnapshot {
    pub request_id: u64,
    pub logical_scene_id: u64,
    pub chunk_coord: [i32; 3],
    pub schema_version: u16,
    pub chunk_size_in_macro: u8,
    pub micro_resolution: u8,
    pub chunk_version: u64,
    pub chunk_hash: u64,
    pub sections: Vec<SnapshotSection>,
}

impl ChunkSnapshot {
    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("snapshot.request_id")?;
        let logical_scene_id = r.u64("snapshot.logical_scene_id")?;
        let chunk_coord = [
            r.i32("snapshot.cx")?,
            r.i32("snapshot.cy")?,
            r.i32("snapshot.cz")?,
        ];
        let schema_version = r.u16("snapshot.schema_version")?;
        let chunk_size_in_macro = r.u8("snapshot.chunk_size_in_macro")?;
        let micro_resolution = r.u8("snapshot.micro_resolution")?;
        let chunk_version = r.u64("snapshot.chunk_version")?;
        let chunk_hash = r.u64("snapshot.chunk_hash")?;
        let section_count = r.u16("snapshot.section_count")? as usize;
        let mut sections = Vec::with_capacity(section_count);
        for _ in 0..section_count {
            let section_type = r.u8("snapshot.section_type")?;
            let section_len = r.u32("snapshot.section_len")? as usize;
            let data = r.bytes(section_len, "snapshot.section_data")?;
            sections.push(SnapshotSection::decode(section_type, data)?);
        }
        Ok(Self {
            request_id,
            logical_scene_id,
            chunk_coord,
            schema_version,
            chunk_size_in_macro,
            micro_resolution,
            chunk_version,
            chunk_hash,
            sections,
        })
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u64(self.logical_scene_id);
        w.i32(self.chunk_coord[0]);
        w.i32(self.chunk_coord[1]);
        w.i32(self.chunk_coord[2]);
        w.u16(self.schema_version);
        w.u8(self.chunk_size_in_macro);
        w.u8(self.micro_resolution);
        w.u64(self.chunk_version);
        w.u64(self.chunk_hash);
        w.u16(self.sections.len() as u16);
        for section in &self.sections {
            let data = section.encode_data();
            w.u8(section.section_type());
            w.u32(data.len() as u32);
            w.bytes(&data);
        }
    }

    /// Returns the macro headers section (the only always-present payload),
    /// if any. Typed accessor for the VoxelWorld ingestion (M1.8).
    pub fn macro_headers(&self) -> Option<&[MacroHeader]> {
        self.sections.iter().find_map(|s| match s {
            SnapshotSection::MacroHeaders(v) => Some(v.as_slice()),
            _ => None,
        })
    }

    pub fn normal_blocks(&self) -> Option<&[NormalBlock]> {
        self.sections.iter().find_map(|s| match s {
            SnapshotSection::NormalBlocks(v) => Some(v.as_slice()),
            _ => None,
        })
    }

    pub fn refined_cells(&self) -> Option<&[RefinedCell]> {
        self.sections.iter().find_map(|s| match s {
            SnapshotSection::RefinedCells(v) => Some(v.as_slice()),
            _ => None,
        })
    }
}
