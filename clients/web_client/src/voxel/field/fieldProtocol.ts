// Phase 6: FieldRegionSnapshot (0x73) and FieldRegionDestroyed (0x74) decoder.
//
// Wire format mirrors the Elixir FieldCodec (field_codec.ex). All multi-byte
// integer fields are big-endian; f32 values are little-endian (matching the
// Elixir float-32-little encoding).

export const FieldMask = {
  Temperature: 0x01,
  ElectricPotential: 0x02,
  Ionization: 0x04,
} as const;

export const DestroyReason = {
  Expired: 0x00,
  LeaseRevoked: 0x01,
  Explicit: 0x02,
  ChunkCrash: 0x03,
} as const;
export type DestroyReasonValue = (typeof DestroyReason)[keyof typeof DestroyReason];

export interface FFieldRegionSnapshot {
  /** Opcode byte 0x73 already consumed by caller. */
  logicalSceneId: number;
  chunkCoord: { cx: number; cy: number; cz: number };
  regionId: number;
  tickCount: number;
  fieldMask: number;
  cellCount: number;
  macroIndices: Uint16Array;
  /** Present when fieldMask & 0x01; parallel to macroIndices. */
  temperatureValues: Float32Array;
  /** Present when fieldMask & 0x02; parallel to macroIndices. */
  electricValues: Float32Array;
  /** Present when fieldMask & 0x04; parallel to macroIndices. */
  ionizationValues: Uint8Array;
}

export interface FFieldRegionDestroyed {
  logicalSceneId: number;
  chunkCoord: { cx: number; cy: number; cz: number };
  regionId: number;
  destroyReason: DestroyReasonValue;
}

/**
 * Decodes a FieldRegionSnapshot payload (ArrayBuffer starting at opcode byte 0x73).
 * Returns null if the buffer is too short or malformed.
 */
export function decodeFieldRegionSnapshot(buf: ArrayBuffer): FFieldRegionSnapshot | null {
  // minimum: 1+8+12+8+4+1+2 = 36 bytes
  if (buf.byteLength < 36) return null;
  const view = new DataView(buf);
  let offset = 1; // skip opcode

  const logicalSceneId = readU64(view, offset);
  offset += 8;
  const cx = view.getInt32(offset, false);
  offset += 4;
  const cy = view.getInt32(offset, false);
  offset += 4;
  const cz = view.getInt32(offset, false);
  offset += 4;
  const regionId = readU64(view, offset);
  offset += 8;
  const tickCount = view.getUint32(offset, false);
  offset += 4;
  const fieldMask = view.getUint8(offset);
  offset += 1;
  const cellCount = view.getUint16(offset, false);
  offset += 2;

  const requiredBytes = offset + cellCount * 2;
  if (buf.byteLength < requiredBytes) return null;

  // macro_indices: u16[cellCount]
  const macroIndices = new Uint16Array(cellCount);
  for (let i = 0; i < cellCount; i++) {
    macroIndices[i] = view.getUint16(offset, false);
    offset += 2;
  }

  // temperature: f32[cellCount] (little-endian) — only if field_mask & 0x01
  let temperatureValues = new Float32Array(0);
  if (fieldMask & FieldMask.Temperature) {
    if (buf.byteLength < offset + cellCount * 4) return null;
    temperatureValues = new Float32Array(cellCount);
    for (let i = 0; i < cellCount; i++) {
      temperatureValues[i] = view.getFloat32(offset, true); // little-endian
      offset += 4;
    }
  }

  // electric_potential: f32[cellCount] — only if field_mask & 0x02
  let electricValues = new Float32Array(0);
  if (fieldMask & FieldMask.ElectricPotential) {
    if (buf.byteLength < offset + cellCount * 4) return null;
    electricValues = new Float32Array(cellCount);
    for (let i = 0; i < cellCount; i++) {
      electricValues[i] = view.getFloat32(offset, true);
      offset += 4;
    }
  }

  // ionization: u8[cellCount] — only if field_mask & 0x04
  let ionizationValues = new Uint8Array(0);
  if (fieldMask & FieldMask.Ionization) {
    if (buf.byteLength < offset + cellCount) return null;
    ionizationValues = new Uint8Array(cellCount);
    for (let i = 0; i < cellCount; i++) {
      ionizationValues[i] = view.getUint8(offset);
      offset += 1;
    }
  }

  return {
    logicalSceneId,
    chunkCoord: { cx, cy, cz },
    regionId,
    tickCount,
    fieldMask,
    cellCount,
    macroIndices,
    temperatureValues,
    electricValues,
    ionizationValues,
  };
}

/**
 * Decodes a FieldRegionDestroyed payload (ArrayBuffer starting at opcode byte 0x74).
 */
export function decodeFieldRegionDestroyed(buf: ArrayBuffer): FFieldRegionDestroyed | null {
  // 1+8+12+8+1 = 30 bytes
  if (buf.byteLength < 30) return null;
  const view = new DataView(buf);
  let offset = 1; // skip opcode

  const logicalSceneId = readU64(view, offset);
  offset += 8;
  const cx = view.getInt32(offset, false);
  offset += 4;
  const cy = view.getInt32(offset, false);
  offset += 4;
  const cz = view.getInt32(offset, false);
  offset += 4;
  const regionId = readU64(view, offset);
  offset += 8;
  const destroyReason = view.getUint8(offset) as DestroyReasonValue;

  return { logicalSceneId, chunkCoord: { cx, cy, cz }, regionId, destroyReason };
}

// u64 read as JS number (safe for IDs up to 2^53, sufficient for region_id)
function readU64(view: DataView, offset: number): number {
  const hi = view.getUint32(offset, false);
  const lo = view.getUint32(offset + 4, false);
  return hi * 0x1_0000_0000 + lo;
}
