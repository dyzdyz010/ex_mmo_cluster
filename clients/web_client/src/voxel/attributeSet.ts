// Phase 1.6b: TS decoder for the chunk-local AttributeSet pool (section 0x04).
//
// Mirrors `apps/scene_server/lib/scene_server/voxel/attribute_set.ex` +
// `attribute_entry.ex`. Wire layout (one set):
//
//   entry_count: u16
//   entries[entry_count] {
//     key_id:     u32
//     value_type: u8     (0x01 i16 / 0x02 u16 / 0x03 fixed32 Q16.16 /
//                          0x04 enum8 / 0x05 bitset32)
//     value:      <var>   (size determined by value_type)
//   }
//
// Pool section (the payload carried by SnapshotSection.AttributeSets, 0x04):
//
//   set_count: u32
//   sets[set_count] (each one as above)
//
// Forward-compat policy:
//   - Unknown value_type tag → throw. Phase 5 expects to bump opcode or
//     extend section in a versioned way; silently swallowing unknown value
//     types would corrupt downstream readers.
//   - Empty pool emits exactly `<<0u32>>` (4 bytes), byte-equivalent to the
//     legacy empty-pool encoding so chunk_hash stays stable for storages
//     whose `attribute_sets` is `[]`.
//
// Q16.16 representation:
//   - The wire carries the raw signed 32-bit integer. Decoder keeps `raw`
//     (the byte-stable int32) so re-encoders / hash recomputation match the
//     server. `asFloat = raw / 65536` is exposed alongside for renderer
//     consumers that want a float.

export const AttributeValueType = {
  I16: 0x01,
  U16: 0x02,
  Fixed32: 0x03,
  Enum8: 0x04,
  Bitset32: 0x05,
} as const;

export type AttributeValueTypeTag =
  (typeof AttributeValueType)[keyof typeof AttributeValueType];

export type AttributeValue =
  | { type: 0x01; value: number /* i16 */ }
  | { type: 0x02; value: number /* u16 */ }
  | { type: 0x03; raw: number; asFloat: number /* Q16.16 → float */ }
  | { type: 0x04; value: number /* enum u8 */ }
  | { type: 0x05; bits: number /* u32 */ };

export interface AttributeEntry {
  keyId: number; // u32
  value: AttributeValue;
}

export interface AttributeSet {
  entries: readonly AttributeEntry[];
}

/**
 * Decode the entire AttributeSets section payload (the bytes carried by
 * SnapshotSection.AttributeSets, i.e. starting at the u32 set_count).
 * Returns the (possibly empty) array of sets.
 */
export function decodeAttributeSetPool(section: DataView): AttributeSet[] {
  if (section.byteLength < 4) {
    throw new Error(`invalid_attribute_sets_section:${section.byteLength}`);
  }
  const count = section.getUint32(0, false);
  if (count === 0) {
    if (section.byteLength !== 4) {
      throw new Error(
        `trailing_attribute_sets_bytes:${section.byteLength - 4}`,
      );
    }
    return [];
  }

  const cursor: Cursor = { view: section, offset: 4 };
  const sets: AttributeSet[] = [];
  for (let i = 0; i < count; i += 1) {
    sets.push(readAttributeSet(cursor));
  }
  if (cursor.offset !== section.byteLength) {
    throw new Error(
      `trailing_attribute_sets_bytes:${section.byteLength - cursor.offset}`,
    );
  }
  return sets;
}

interface Cursor {
  view: DataView;
  offset: number;
}

function readAttributeSet(cursor: Cursor): AttributeSet {
  const entryCount = readU16(cursor);
  const entries: AttributeEntry[] = [];
  for (let i = 0; i < entryCount; i += 1) {
    entries.push(readAttributeEntry(cursor));
  }
  return { entries };
}

function readAttributeEntry(cursor: Cursor): AttributeEntry {
  const keyId = readU32(cursor);
  const valueType = readU8(cursor);
  const value = readAttributeValue(cursor, valueType);
  return { keyId, value };
}

function readAttributeValue(cursor: Cursor, valueType: number): AttributeValue {
  switch (valueType) {
    case AttributeValueType.I16: {
      ensureRemaining(cursor, 2);
      const value = cursor.view.getInt16(cursor.offset, false);
      cursor.offset += 2;
      return { type: AttributeValueType.I16, value };
    }
    case AttributeValueType.U16: {
      ensureRemaining(cursor, 2);
      const value = cursor.view.getUint16(cursor.offset, false);
      cursor.offset += 2;
      return { type: AttributeValueType.U16, value };
    }
    case AttributeValueType.Fixed32: {
      ensureRemaining(cursor, 4);
      const raw = cursor.view.getInt32(cursor.offset, false);
      cursor.offset += 4;
      return { type: AttributeValueType.Fixed32, raw, asFloat: raw / 65536 };
    }
    case AttributeValueType.Enum8: {
      ensureRemaining(cursor, 1);
      const value = cursor.view.getUint8(cursor.offset);
      cursor.offset += 1;
      return { type: AttributeValueType.Enum8, value };
    }
    case AttributeValueType.Bitset32: {
      ensureRemaining(cursor, 4);
      const bits = cursor.view.getUint32(cursor.offset, false);
      cursor.offset += 4;
      return { type: AttributeValueType.Bitset32, bits };
    }
    default:
      throw new Error(`unknown_attribute_value_type:0x${valueType.toString(16)}`);
  }
}

function readU8(cursor: Cursor): number {
  ensureRemaining(cursor, 1);
  const v = cursor.view.getUint8(cursor.offset);
  cursor.offset += 1;
  return v;
}

function readU16(cursor: Cursor): number {
  ensureRemaining(cursor, 2);
  const v = cursor.view.getUint16(cursor.offset, false);
  cursor.offset += 2;
  return v;
}

function readU32(cursor: Cursor): number {
  ensureRemaining(cursor, 4);
  const v = cursor.view.getUint32(cursor.offset, false);
  cursor.offset += 4;
  return v;
}

function ensureRemaining(cursor: Cursor, bytes: number): void {
  if (cursor.offset + bytes > cursor.view.byteLength) {
    throw new Error(
      `truncated_attribute_sets_section:need_${bytes}_at_${cursor.offset}_have_${
        cursor.view.byteLength - cursor.offset
      }`,
    );
  }
}
