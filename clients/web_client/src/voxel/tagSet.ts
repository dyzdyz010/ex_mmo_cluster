// Phase 1.6b: TS decoder for the chunk-local TagSet pool (section 0x05).
//
// Mirrors `apps/scene_server/lib/scene_server/voxel/tag_set.ex`. Wire layout
// (one set):
//
//   tag_count: u16
//   tag_ids[tag_count]: u32       (ascending, no duplicates)
//
// Pool section (the payload carried by SnapshotSection.TagSets, 0x05):
//
//   set_count: u32
//   sets[set_count] (each one as above)
//
// Empty pool emits exactly `<<0u32>>` (4 bytes), byte-equivalent to the legacy
// empty-pool encoding so chunk_hash stays stable for storages whose
// `tag_sets` is `[]`.
//
// The decoder is permissive on `tag_id` ordering — server-side normalize!/1
// already sorts ascending + rejects duplicates, so a malformed feed is a
// server bug. We re-validate ascending-and-unique here as a cheap drift
// detector (Phase 1.6b: throw on disorder).

export interface TagSet {
  tagIds: readonly number[]; // u32 ascending, no duplicates
}

/**
 * Decode the entire TagSets section payload. Returns the (possibly empty)
 * array of sets.
 */
export function decodeTagSetPool(section: DataView): TagSet[] {
  if (section.byteLength < 4) {
    throw new Error(`invalid_tag_sets_section:${section.byteLength}`);
  }
  const count = section.getUint32(0, false);
  if (count === 0) {
    if (section.byteLength !== 4) {
      throw new Error(`trailing_tag_sets_bytes:${section.byteLength - 4}`);
    }
    return [];
  }

  const cursor: Cursor = { view: section, offset: 4 };
  const sets: TagSet[] = [];
  for (let i = 0; i < count; i += 1) {
    sets.push(readTagSet(cursor));
  }
  if (cursor.offset !== section.byteLength) {
    throw new Error(`trailing_tag_sets_bytes:${section.byteLength - cursor.offset}`);
  }
  return sets;
}

interface Cursor {
  view: DataView;
  offset: number;
}

function readTagSet(cursor: Cursor): TagSet {
  const tagCount = readU16(cursor);
  const expectedBytes = tagCount * 4;
  ensureRemaining(cursor, expectedBytes);

  const tagIds: number[] = new Array(tagCount);
  let prev = -1;
  for (let i = 0; i < tagCount; i += 1) {
    const id = cursor.view.getUint32(cursor.offset, false);
    cursor.offset += 4;
    if (id <= prev) {
      throw new Error(
        `tag_set_tag_ids_not_ascending_or_unique:prev_${prev}_got_${id}_at_index_${i}`,
      );
    }
    prev = id;
    tagIds[i] = id;
  }
  return { tagIds };
}

function readU16(cursor: Cursor): number {
  ensureRemaining(cursor, 2);
  const v = cursor.view.getUint16(cursor.offset, false);
  cursor.offset += 2;
  return v;
}

function ensureRemaining(cursor: Cursor, bytes: number): void {
  if (cursor.offset + bytes > cursor.view.byteLength) {
    throw new Error(
      `truncated_tag_sets_section:need_${bytes}_at_${cursor.offset}_have_${
        cursor.view.byteLength - cursor.offset
      }`,
    );
  }
}
