import { describe, expect, it, vi } from "vitest";

import {
  decodeObjectStateDelta,
  logObjectStateDelta,
  type ObjectStateDelta,
} from "./objectStateDelta";

function buildDelta(
  options: {
    logicalSceneId?: bigint;
    objectId?: bigint;
    objectVersion?: bigint;
    stateFlags?: number;
    attributePatchCount?: number;
    tagPatchCount?: number;
    affectedChunks?: { x: number; y: number; z: number }[];
  } = {},
): Uint8Array {
  const logicalSceneId = options.logicalSceneId ?? 1n;
  const objectId = options.objectId ?? 42n;
  const objectVersion = options.objectVersion ?? 7n;
  const stateFlags = options.stateFlags ?? 0;
  const attributePatchCount = options.attributePatchCount ?? 0;
  const tagPatchCount = options.tagPatchCount ?? 0;
  const affectedChunks = options.affectedChunks ?? [{ x: 0, y: 0, z: 0 }];

  const headerBytes = 8 + 8 + 8 + 4 + 2 + 2 + 2;
  const chunkBytes = affectedChunks.length * 12;
  const buffer = new ArrayBuffer(headerBytes + chunkBytes);
  const view = new DataView(buffer);
  let offset = 0;

  view.setBigUint64(offset, logicalSceneId, false);
  offset += 8;
  view.setBigUint64(offset, objectId, false);
  offset += 8;
  view.setBigUint64(offset, objectVersion, false);
  offset += 8;
  view.setUint32(offset, stateFlags, false);
  offset += 4;
  view.setUint16(offset, attributePatchCount, false);
  offset += 2;
  view.setUint16(offset, tagPatchCount, false);
  offset += 2;
  view.setUint16(offset, affectedChunks.length, false);
  offset += 2;

  for (const chunk of affectedChunks) {
    view.setInt32(offset, chunk.x, false);
    offset += 4;
    view.setInt32(offset, chunk.y, false);
    offset += 4;
    view.setInt32(offset, chunk.z, false);
    offset += 4;
  }

  return new Uint8Array(buffer);
}

describe("decodeObjectStateDelta", () => {
  it("decodes the canonical Phase 4 payload", () => {
    const payload = buildDelta({
      logicalSceneId: 1n,
      objectId: 42n,
      objectVersion: 7n,
      stateFlags: 0x3,
      affectedChunks: [{ x: 0, y: 0, z: 0 }],
    });

    const decoded: ObjectStateDelta = decodeObjectStateDelta(payload);

    expect(decoded.logicalSceneId).toBe(1n);
    expect(decoded.objectId).toBe(42n);
    expect(decoded.objectVersion).toBe(7n);
    expect(decoded.stateFlags).toBe(0x3);
    expect(decoded.attributePatchCount).toBe(0);
    expect(decoded.tagPatchCount).toBe(0);
    expect(decoded.affectedChunks).toEqual([{ x: 0, y: 0, z: 0 }]);
  });

  it("decodes multiple affected chunks with negative coords", () => {
    const payload = buildDelta({
      affectedChunks: [
        { x: -1, y: 0, z: 0 },
        { x: 0, y: 0, z: 0 },
        { x: 0, y: -2, z: 3 },
      ],
    });

    const decoded = decodeObjectStateDelta(payload);

    expect(decoded.affectedChunks).toEqual([
      { x: -1, y: 0, z: 0 },
      { x: 0, y: 0, z: 0 },
      { x: 0, y: -2, z: 3 },
    ]);
  });

  it("throws on a truncated header", () => {
    const truncated = new Uint8Array(4);

    expect(() => decodeObjectStateDelta(truncated)).toThrow(/truncated header/);
  });

  it("throws on a truncated affected_chunks block", () => {
    const payload = buildDelta({
      affectedChunks: [
        { x: 0, y: 0, z: 0 },
        { x: 1, y: 0, z: 0 },
      ],
    });

    // Strip the last chunk's bytes from the tail
    const truncated = payload.slice(0, payload.byteLength - 12);

    expect(() => decodeObjectStateDelta(truncated)).toThrow(/truncated affected_chunks/);
  });

  it("preserves unknown attribute_patch_count / tag_patch_count for forwards compatibility", () => {
    // Phase 4 always emits 0; this test guards against future patch additions
    // breaking the read path before web_client adopts patches.
    const payload = buildDelta({
      attributePatchCount: 7,
      tagPatchCount: 11,
    });

    const decoded = decodeObjectStateDelta(payload);
    expect(decoded.attributePatchCount).toBe(7);
    expect(decoded.tagPatchCount).toBe(11);
  });
});

describe("logObjectStateDelta", () => {
  it("emits a console.log entry tagged with [voxel]", () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => {});

    try {
      logObjectStateDelta({
        logicalSceneId: 1n,
        objectId: 42n,
        objectVersion: 1n,
        stateFlags: 0x3,
        attributePatchCount: 0,
        tagPatchCount: 0,
        affectedChunks: [{ x: 0, y: 0, z: 0 }],
      });

      expect(spy).toHaveBeenCalledTimes(1);
      const [tag, payload] = spy.mock.calls[0] as [string, Record<string, unknown>];
      expect(tag).toBe("[voxel] ObjectStateDelta");
      expect(payload).toMatchObject({
        objectId: "42",
        affectedChunkCount: 1,
        stateFlags: "0x3",
      });
    } finally {
      spy.mockRestore();
    }
  });
});
