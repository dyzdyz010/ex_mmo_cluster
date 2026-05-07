// Server-authoritative RefinedCellData wire decoder (Phase 1a).
//
// Mirrors `apps/scene_server/lib/scene_server/voxel/codec.ex` per-cell layout:
//
//   occupancy_words    u64 × 8           (64 bytes)
//   boundary_cache     u64               (8 bytes)
//   layer_count        u16
//   layers[layer_count] {
//     mask_words           u64 × 8
//     material_id          u16
//     state_flags          u32
//     health               u16
//     attribute_set_ref    u32
//     tag_set_ref          u32
//     owner_object_id      u64
//     owner_part_id        u32
//   }
//   object_ref_count   u16
//   object_refs[object_ref_count] {
//     owner_object_id  u64
//     owner_part_id    u32
//     mask_words       u64 × 8
//   }
//
// Empty list (count=0) emits exactly 4 bytes `<<0u32>>`, byte-for-byte
// compatible with the legacy empty-pool encoding so chunk_hash stays stable
// for storages whose `refined_cells` is `[]`.
//
// This decoder is read-only: the server is the only producer of these
// records. Browser offline mode keeps using the legacy `FRefinedCellData`
// shape in `clients/web_client/src/voxel/storage/types.ts`; do not conflate
// the two.

const MASK_WORD_COUNT = 8;
const MASK_WORDS_BYTES = MASK_WORD_COUNT * 8; // 64

export interface MicroLayerWire {
  maskWords: bigint[]; // length === 8
  materialId: number;
  stateFlags: number;
  health: number;
  attributeSetRef: number;
  tagSetRef: number;
  ownerObjectId: bigint;
  ownerPartId: number;
}

export interface ObjectCoverRefWire {
  ownerObjectId: bigint;
  ownerPartId: number;
  maskWords: bigint[]; // length === 8
}

export interface RefinedCellWireData {
  occupancyWords: bigint[]; // length === 8
  boundaryCache: bigint;
  layers: MicroLayerWire[];
  objectRefs: ObjectCoverRefWire[];
}

/**
 * Decode the entire RefinedCells section payload (the bytes carried by
 * SnapshotSection.RefinedCells, i.e. starting at the u32 count). Returns
 * the (possibly empty) array of cells.
 */
export function decodeRefinedCellPool(section: DataView): RefinedCellWireData[] {
  if (section.byteLength < 4) {
    throw new Error(`invalid_refined_cells_section:${section.byteLength}`);
  }
  const count = section.getUint32(0, false);
  if (count === 0) {
    if (section.byteLength !== 4) {
      throw new Error(`trailing_refined_cells_bytes:${section.byteLength - 4}`);
    }
    return [];
  }

  const cursor: Cursor = { view: section, offset: 4 };
  const cells: RefinedCellWireData[] = [];
  for (let index = 0; index < count; index += 1) {
    cells.push(readRefinedCell(cursor));
  }
  if (cursor.offset !== section.byteLength) {
    throw new Error(
      `trailing_refined_cells_bytes:${section.byteLength - cursor.offset}`,
    );
  }
  return cells;
}

/**
 * Encode a list of refined cells back to the wire form. Symmetrical with
 * `decodeRefinedCellPool` and matches the Elixir codec byte-for-byte; used
 * primarily by tests that round-trip cells through the wire.
 */
export function encodeRefinedCellPool(cells: RefinedCellWireData[]): Uint8Array {
  if (cells.length === 0) {
    return new Uint8Array([0, 0, 0, 0]);
  }

  if (cells.length > 0xffff_ffff) {
    throw new Error(`refined_cells_count_exceeds_u32:${cells.length}`);
  }

  const totalBytes = 4 + cells.reduce((acc, cell) => acc + cellByteSize(cell), 0);
  const buffer = new ArrayBuffer(totalBytes);
  const view = new DataView(buffer);
  view.setUint32(0, cells.length, false);

  let offset = 4;
  for (const cell of cells) {
    offset = writeRefinedCell(view, offset, cell);
  }
  return new Uint8Array(buffer);
}

/**
 * Decode a single RefinedCellData from a standalone payload (no count
 * prefix). This is the form used by ChunkDelta op payloads when
 * `delta_kind = 2 (CellRefined)` (Phase 1c-3). Bytes match a single entry
 * inside `decodeRefinedCellPool`, so a 1-cell pool payload is exactly
 * `<<1::u32>> <> encodeRefinedCellPayload(cell)`.
 */
export function decodeRefinedCellPayload(payload: DataView): RefinedCellWireData {
  const cursor: Cursor = { view: payload, offset: 0 };
  const cell = readRefinedCell(cursor);
  if (cursor.offset !== payload.byteLength) {
    throw new Error(
      `trailing_refined_cell_payload_bytes:${payload.byteLength - cursor.offset}`,
    );
  }
  return cell;
}

/**
 * Encode a single RefinedCellData as a standalone payload (no count prefix).
 */
export function encodeRefinedCellPayload(cell: RefinedCellWireData): Uint8Array {
  const totalBytes = cellByteSize(cell);
  const buffer = new ArrayBuffer(totalBytes);
  const view = new DataView(buffer);
  const written = writeRefinedCell(view, 0, cell);
  if (written !== totalBytes) {
    throw new Error(`refined_cell_payload_size_mismatch:${written}_vs_${totalBytes}`);
  }
  return new Uint8Array(buffer);
}

interface Cursor {
  view: DataView;
  offset: number;
}

function readRefinedCell(cursor: Cursor): RefinedCellWireData {
  const occupancyWords = readMaskWords(cursor);
  const boundaryCache = readU64(cursor);
  const layerCount = readU16(cursor);

  const layers: MicroLayerWire[] = [];
  for (let i = 0; i < layerCount; i += 1) {
    layers.push(readMicroLayer(cursor));
  }

  const objectRefCount = readU16(cursor);
  const objectRefs: ObjectCoverRefWire[] = [];
  for (let i = 0; i < objectRefCount; i += 1) {
    objectRefs.push(readObjectCoverRef(cursor));
  }

  return {
    occupancyWords,
    boundaryCache,
    layers,
    objectRefs,
  };
}

function readMicroLayer(cursor: Cursor): MicroLayerWire {
  const maskWords = readMaskWords(cursor);
  const materialId = readU16(cursor);
  const stateFlags = readU32(cursor);
  const health = readU16(cursor);
  const attributeSetRef = readU32(cursor);
  const tagSetRef = readU32(cursor);
  const ownerObjectId = readU64(cursor);
  const ownerPartId = readU32(cursor);

  return {
    maskWords,
    materialId,
    stateFlags,
    health,
    attributeSetRef,
    tagSetRef,
    ownerObjectId,
    ownerPartId,
  };
}

function readObjectCoverRef(cursor: Cursor): ObjectCoverRefWire {
  const ownerObjectId = readU64(cursor);
  const ownerPartId = readU32(cursor);
  const maskWords = readMaskWords(cursor);
  return { ownerObjectId, ownerPartId, maskWords };
}

function readMaskWords(cursor: Cursor): bigint[] {
  ensureRemaining(cursor, MASK_WORDS_BYTES);
  const words: bigint[] = new Array(MASK_WORD_COUNT);
  for (let i = 0; i < MASK_WORD_COUNT; i += 1) {
    words[i] = cursor.view.getBigUint64(cursor.offset, false);
    cursor.offset += 8;
  }
  return words;
}

function readU64(cursor: Cursor): bigint {
  ensureRemaining(cursor, 8);
  const value = cursor.view.getBigUint64(cursor.offset, false);
  cursor.offset += 8;
  return value;
}

function readU32(cursor: Cursor): number {
  ensureRemaining(cursor, 4);
  const value = cursor.view.getUint32(cursor.offset, false);
  cursor.offset += 4;
  return value;
}

function readU16(cursor: Cursor): number {
  ensureRemaining(cursor, 2);
  const value = cursor.view.getUint16(cursor.offset, false);
  cursor.offset += 2;
  return value;
}

function ensureRemaining(cursor: Cursor, bytes: number): void {
  if (cursor.offset + bytes > cursor.view.byteLength) {
    throw new Error(
      `truncated_refined_cells_section:need_${bytes}_at_${cursor.offset}_have_${
        cursor.view.byteLength - cursor.offset
      }`,
    );
  }
}

function cellByteSize(cell: RefinedCellWireData): number {
  // occupancy_words 64 + boundary_cache 8 + layer_count 2 + object_ref_count 2
  let size = MASK_WORDS_BYTES + 8 + 2 + 2;
  // each layer: mask 64 + 2 + 4 + 2 + 4 + 4 + 8 + 4 = 92
  size += cell.layers.length * (MASK_WORDS_BYTES + 2 + 4 + 2 + 4 + 4 + 8 + 4);
  // each object ref: 8 + 4 + mask 64 = 76
  size += cell.objectRefs.length * (8 + 4 + MASK_WORDS_BYTES);
  return size;
}

function writeRefinedCell(view: DataView, offset: number, cell: RefinedCellWireData): number {
  offset = writeMaskWords(view, offset, cell.occupancyWords);
  view.setBigUint64(offset, cell.boundaryCache, false);
  offset += 8;

  if (cell.layers.length > 0xffff) {
    throw new Error(`refined_cell_layer_count_exceeds_u16:${cell.layers.length}`);
  }
  view.setUint16(offset, cell.layers.length, false);
  offset += 2;
  for (const layer of cell.layers) {
    offset = writeMicroLayer(view, offset, layer);
  }

  if (cell.objectRefs.length > 0xffff) {
    throw new Error(`refined_cell_object_ref_count_exceeds_u16:${cell.objectRefs.length}`);
  }
  view.setUint16(offset, cell.objectRefs.length, false);
  offset += 2;
  for (const ref of cell.objectRefs) {
    offset = writeObjectCoverRef(view, offset, ref);
  }

  return offset;
}

function writeMicroLayer(view: DataView, offset: number, layer: MicroLayerWire): number {
  offset = writeMaskWords(view, offset, layer.maskWords);
  view.setUint16(offset, layer.materialId, false);
  offset += 2;
  view.setUint32(offset, layer.stateFlags, false);
  offset += 4;
  view.setUint16(offset, layer.health, false);
  offset += 2;
  view.setUint32(offset, layer.attributeSetRef, false);
  offset += 4;
  view.setUint32(offset, layer.tagSetRef, false);
  offset += 4;
  view.setBigUint64(offset, layer.ownerObjectId, false);
  offset += 8;
  view.setUint32(offset, layer.ownerPartId, false);
  offset += 4;
  return offset;
}

function writeObjectCoverRef(view: DataView, offset: number, ref: ObjectCoverRefWire): number {
  view.setBigUint64(offset, ref.ownerObjectId, false);
  offset += 8;
  view.setUint32(offset, ref.ownerPartId, false);
  offset += 4;
  return writeMaskWords(view, offset, ref.maskWords);
}

function writeMaskWords(view: DataView, offset: number, words: bigint[]): number {
  if (words.length !== MASK_WORD_COUNT) {
    throw new Error(`invalid_mask_words_length:${words.length}`);
  }
  for (const word of words) {
    view.setBigUint64(offset, word, false);
    offset += 8;
  }
  return offset;
}
