// Phase 6: FieldProtocol unit tests — mirrors field_codec_test.exs round-trip logic.

import { describe, expect, it } from "vitest";
import {
  DestroyReason,
  FieldMask,
  decodeFieldRegionDestroyed,
  decodeFieldRegionSnapshot,
} from "./fieldProtocol";

// Helper: build a FieldRegionSnapshot binary matching field_codec.ex layout.
function buildSnapshotBuf(opts: {
  logicalSceneId?: number;
  cx?: number; cy?: number; cz?: number;
  regionId?: number;
  tickCount?: number;
  fieldMask?: number;
  macroIndices?: number[];
  temperatureValues?: number[];
  electricValues?: number[];
  ionizationValues?: number[];
}): ArrayBuffer {
  const {
    logicalSceneId = 1,
    cx = 0, cy = 0, cz = 0,
    regionId = 42,
    tickCount = 5,
    fieldMask = FieldMask.Temperature,
    macroIndices = [0, 1],
    temperatureValues = [25.5, 30.0],
    electricValues = [],
    ionizationValues = [],
  } = opts;

  const cellCount = macroIndices.length;
  let size = 1 + 8 + 12 + 8 + 4 + 1 + 2 + cellCount * 2;
  if (fieldMask & FieldMask.Temperature) size += cellCount * 4;
  if (fieldMask & FieldMask.ElectricPotential) size += cellCount * 4;
  if (fieldMask & FieldMask.Ionization) size += cellCount;

  const buf = new ArrayBuffer(size);
  const view = new DataView(buf);
  let offset = 0;

  view.setUint8(offset, 0x73); offset += 1;
  writeU64(view, offset, logicalSceneId); offset += 8;
  view.setInt32(offset, cx, false); offset += 4;
  view.setInt32(offset, cy, false); offset += 4;
  view.setInt32(offset, cz, false); offset += 4;
  writeU64(view, offset, regionId); offset += 8;
  view.setUint32(offset, tickCount, false); offset += 4;
  view.setUint8(offset, fieldMask); offset += 1;
  view.setUint16(offset, cellCount, false); offset += 2;

  for (const idx of macroIndices) {
    view.setUint16(offset, idx, false); offset += 2;
  }
  if (fieldMask & FieldMask.Temperature) {
    for (const v of temperatureValues) {
      view.setFloat32(offset, v, true); offset += 4; // little-endian
    }
  }
  if (fieldMask & FieldMask.ElectricPotential) {
    for (const v of electricValues) {
      view.setFloat32(offset, v, true); offset += 4;
    }
  }
  if (fieldMask & FieldMask.Ionization) {
    for (const v of ionizationValues) {
      view.setUint8(offset, v); offset += 1;
    }
  }

  return buf;
}

function buildDestroyedBuf(opts: {
  logicalSceneId?: number;
  cx?: number; cy?: number; cz?: number;
  regionId?: number;
  destroyReason?: number;
}): ArrayBuffer {
  const {
    logicalSceneId = 1,
    cx = 0, cy = 0, cz = 0,
    regionId = 42,
    destroyReason = DestroyReason.Expired,
  } = opts;

  const buf = new ArrayBuffer(30); // 1+8+12+8+1
  const view = new DataView(buf);
  let offset = 0;

  view.setUint8(offset, 0x74); offset += 1;
  writeU64(view, offset, logicalSceneId); offset += 8;
  view.setInt32(offset, cx, false); offset += 4;
  view.setInt32(offset, cy, false); offset += 4;
  view.setInt32(offset, cz, false); offset += 4;
  writeU64(view, offset, regionId); offset += 8;
  view.setUint8(offset, destroyReason);

  return buf;
}

function writeU64(view: DataView, offset: number, val: number): void {
  const hi = Math.floor(val / 0x1_0000_0000);
  const lo = val >>> 0;
  view.setUint32(offset, hi, false);
  view.setUint32(offset + 4, lo, false);
}

// ────────────────────────────────────────────────────────────────────────────
describe("decodeFieldRegionSnapshot", () => {
  it("decodes temperature-only snapshot", () => {
    const buf = buildSnapshotBuf({
      logicalSceneId: 1,
      cx: 2, cy: -1, cz: 3,
      regionId: 99,
      tickCount: 10,
      fieldMask: FieldMask.Temperature,
      macroIndices: [0, 256],
      temperatureValues: [25.5, 100.0],
    });

    const result = decodeFieldRegionSnapshot(buf);
    expect(result).not.toBeNull();
    expect(result!.logicalSceneId).toBe(1);
    expect(result!.chunkCoord).toEqual({ cx: 2, cy: -1, cz: 3 });
    expect(result!.regionId).toBe(99);
    expect(result!.tickCount).toBe(10);
    expect(result!.fieldMask).toBe(FieldMask.Temperature);
    expect(result!.cellCount).toBe(2);
    expect(Array.from(result!.macroIndices)).toEqual([0, 256]);
    expect(result!.temperatureValues[0]).toBeCloseTo(25.5, 3);
    expect(result!.temperatureValues[1]).toBeCloseTo(100.0, 3);
    expect(result!.electricValues.length).toBe(0);
    expect(result!.ionizationValues.length).toBe(0);
  });

  it("decodes three-field snapshot (temperature + electric + ionization)", () => {
    const buf = buildSnapshotBuf({
      fieldMask: FieldMask.Temperature | FieldMask.ElectricPotential | FieldMask.Ionization,
      macroIndices: [10, 20, 30],
      temperatureValues: [21.0, 50.0, 80.0],
      electricValues: [0.0, 150.5, 200.0],
      ionizationValues: [0, 100, 255],
    });

    const result = decodeFieldRegionSnapshot(buf);
    expect(result).not.toBeNull();
    expect(result!.cellCount).toBe(3);
    expect(result!.temperatureValues[2]).toBeCloseTo(80.0, 3);
    expect(result!.electricValues[1]).toBeCloseTo(150.5, 3);
    expect(result!.ionizationValues[2]).toBe(255);
  });

  it("returns null for truncated buffer", () => {
    const buf = new ArrayBuffer(10); // too short
    expect(decodeFieldRegionSnapshot(buf)).toBeNull();
  });

  it("decodes zero-cell snapshot", () => {
    const buf = buildSnapshotBuf({
      fieldMask: FieldMask.Temperature,
      macroIndices: [],
      temperatureValues: [],
    });
    const result = decodeFieldRegionSnapshot(buf);
    expect(result).not.toBeNull();
    expect(result!.cellCount).toBe(0);
    expect(result!.macroIndices.length).toBe(0);
  });
});

describe("decodeFieldRegionDestroyed", () => {
  it.each([
    [DestroyReason.Expired, "expired"],
    [DestroyReason.LeaseRevoked, "lease_revoked"],
    [DestroyReason.Explicit, "explicit"],
    [DestroyReason.ChunkCrash, "chunk_crash"],
  ] as const)("decodes destroy_reason %i", (reason, _label) => {
    const buf = buildDestroyedBuf({
      logicalSceneId: 5,
      cx: -3, cy: 0, cz: 7,
      regionId: 1234,
      destroyReason: reason,
    });

    const result = decodeFieldRegionDestroyed(buf);
    expect(result).not.toBeNull();
    expect(result!.logicalSceneId).toBe(5);
    expect(result!.chunkCoord).toEqual({ cx: -3, cy: 0, cz: 7 });
    expect(result!.regionId).toBe(1234);
    expect(result!.destroyReason).toBe(reason);
  });

  it("returns null for truncated buffer", () => {
    expect(decodeFieldRegionDestroyed(new ArrayBuffer(5))).toBeNull();
  });
});
