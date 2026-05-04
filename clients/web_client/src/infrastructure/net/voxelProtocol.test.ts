import { VoxelConstants } from "../../voxel/core/constants";
import { EVoxelCellMode } from "../../voxel/core/types";
import { VoxelDirtyFlags } from "../../voxel/storage/types";
import { VoxelIntentResult, VoxelOpcode } from "./opcodes";
import {
  decodeVoxelServerMessage,
  encodeVoxelChunkSubscribe,
  encodeVoxelDebugProbe,
  encodeVoxelImpactIntent,
} from "./voxelProtocol";

describe("voxel gate protocol", () => {
  it("encodes debug probes with the shared voxel opcode", () => {
    const encoded = encodeVoxelDebugProbe(7, "voxel_transport");
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    expect(view.getUint8(0)).toBe(VoxelOpcode.VoxelDebugProbe);
    expect(Number(view.getBigUint64(1, false))).toBe(7);
    expect(view.getUint16(9, false)).toBe("voxel_transport".length);
  });

  it("encodes chunk subscribe with big-endian chunk and known version fields", () => {
    const encoded = encodeVoxelChunkSubscribe({
      requestId: 9,
      logicalSceneId: 3,
      centerChunk: { x: -1, y: 2, z: 4 },
      radiusLInf: 1,
      known: [{ chunkCoord: { x: 1, y: 0, z: -2 }, chunkVersion: 99 }],
    });
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    expect(view.getUint8(0)).toBe(VoxelOpcode.ChunkSubscribe);
    expect(Number(view.getBigUint64(1, false))).toBe(9);
    expect(Number(view.getBigUint64(9, false))).toBe(3);
    expect(view.getInt32(17, false)).toBe(-1);
    expect(view.getInt32(21, false)).toBe(2);
    expect(view.getInt32(25, false)).toBe(4);
    expect(view.getUint8(29)).toBe(1);
    expect(view.getUint8(30)).toBe(1);
    expect(view.getUint16(31, false)).toBe(1);
    expect(view.getInt32(33, false)).toBe(1);
    expect(view.getInt32(41, false)).toBe(-2);
    expect(Number(view.getBigUint64(45, false))).toBe(99);
  });

  it("encodes voxel impact intents without swapping voxel axes", () => {
    const encoded = encodeVoxelImpactIntent({
      requestId: 10,
      clientIntentSeq: 11,
      logicalSceneId: 12,
      sourceSkillId: 1,
      targetWorldMicro: { x: 16, y: -8, z: 24 },
      impactKind: 2,
      clientHintHash: 123,
    });
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    expect(view.getUint8(0)).toBe(VoxelOpcode.VoxelImpactIntent);
    expect(view.getUint32(9, false)).toBe(11);
    expect(Number(view.getBigUint64(13, false))).toBe(12);
    expect(Number(view.getBigInt64(25, false))).toBe(16);
    expect(Number(view.getBigInt64(33, false))).toBe(-8);
    expect(Number(view.getBigInt64(41, false))).toBe(24);
    expect(view.getUint16(49, false)).toBe(2);
  });

  it("decodes server chunk snapshots into storage truth", () => {
    const payload = buildSnapshotFrame();
    const message = decodeVoxelServerMessage(payload);

    expect(message?.type).toBe("voxel_chunk_snapshot");
    if (message?.type !== "voxel_chunk_snapshot") return;
    expect(message.logicalSceneId).toBe(5);
    expect(message.chunkCoord).toEqual({ x: 0, y: 0, z: 0 });
    expect(message.chunkVersion).toBe(77);
    expect(message.storage.macroHeaders).toHaveLength(VoxelConstants.MacroCountPerChunk);
    expect(message.storage.normalBlocks[0]).toMatchObject({
      materialId: 2,
      stateFlags: 1,
      health: 100,
      attributeSetRef: 1234,
      tagSetRef: 5678,
    });
    expect(message.storage.macroHeaders[801]).toMatchObject({
      mode: EVoxelCellMode.SolidBlock,
      payloadIndex: 0,
      environmentIndex: 0xffff,
      cellVersion: 13,
      cellHash: 14,
    });
    expect(message.storage.dirtyFlags).toBe(
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
  });

  it("decodes voxel intent results with result code names", () => {
    const reason = new TextEncoder().encode("ok");
    const buffer = new ArrayBuffer(1 + 8 + 4 + 8 + 1 + 8 + 2 + 2 + reason.length);
    const view = new DataView(buffer);
    view.setUint8(0, VoxelOpcode.VoxelIntentResult);
    view.setBigUint64(1, 9n, false);
    view.setUint32(9, 4, false);
    view.setBigUint64(13, 5n, false);
    view.setUint8(21, VoxelIntentResult.Accepted);
    view.setBigUint64(22, 77n, false);
    view.setUint16(30, 0, false);
    view.setUint16(32, reason.length, false);
    new Uint8Array(buffer, 34).set(reason);

    const message = decodeVoxelServerMessage(buffer);

    expect(message?.type).toBe("voxel_intent_result");
    if (message?.type !== "voxel_intent_result") return;
    expect(message.resultCodeName).toBe("accepted");
    expect(message.resultRef).toBe(77);
    expect(message.reason).toBe("ok");
  });

  it("decodes a CellSolid ChunkDelta payload from the 0x63 opcode", () => {
    // 20-byte NormalBlockData payload (materialId=42, health=80, default zeros)
    const blockPayload = new Uint8Array(20);
    const blockView = new DataView(blockPayload.buffer);
    blockView.setUint16(0, 42, false);
    blockView.setUint32(2, 0, false);
    blockView.setUint16(6, 80, false);
    // remaining bytes (temperatureDelta i16 +2, moistureDelta i16 +2,
    // attributeSetRef u32 +4, tagSetRef u32 +4) stay zero.

    const headerSize = 1 + 8 + 12 + 8 + 8 + 2;
    const opSize = 1 + 2 + 4 + 4 + 2 + blockPayload.length;
    const buffer = new ArrayBuffer(headerSize + opSize);
    const view = new DataView(buffer);
    let offset = 0;
    view.setUint8(offset, VoxelOpcode.ChunkDelta);
    offset += 1;
    view.setBigUint64(offset, 7n, false);
    offset += 8;
    view.setInt32(offset, 1, false);
    view.setInt32(offset + 4, 2, false);
    view.setInt32(offset + 8, 3, false);
    offset += 12;
    view.setBigUint64(offset, 4n, false);
    offset += 8;
    view.setBigUint64(offset, 5n, false);
    offset += 8;
    view.setUint16(offset, 1, false);
    offset += 2;
    view.setUint8(offset, 1);
    offset += 1;
    view.setUint16(offset, 1234, false);
    offset += 2;
    view.setUint32(offset, 5, false);
    offset += 4;
    view.setUint32(offset, 0xcafe, false);
    offset += 4;
    view.setUint16(offset, blockPayload.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, blockPayload.length).set(blockPayload);

    const message = decodeVoxelServerMessage(buffer);

    expect(message?.type).toBe("voxel_chunk_delta");
    if (message?.type !== "voxel_chunk_delta") return;
    expect(message.logicalSceneId).toBe(7);
    expect(message.chunkCoord).toEqual({ x: 1, y: 2, z: 3 });
    expect(message.baseChunkVersion).toBe(4);
    expect(message.newChunkVersion).toBe(5);
    expect(message.ops).toHaveLength(1);
    const op = message.ops[0];
    expect(op.deltaKind).toBe(1);
    expect(op.macroIndex).toBe(1234);
    expect(op.cellVersion).toBe(5);
    expect(op.cellHash).toBe(0xcafe);
    expect(Array.from(op.payload)).toEqual(Array.from(blockPayload));
  });
});

function buildSnapshotFrame(): ArrayBuffer {
  const sections = [
    section(0x01, macroHeadersSection()),
    section(0x02, normalBlocksSection()),
    section(0x03, emptyPoolSection()),
    section(0x04, emptyPoolSection()),
    section(0x05, emptyPoolSection()),
    section(0x06, emptyPoolSection()),
    section(0x07, emptyPoolSection()),
  ];
  const sectionsBytes = concat(sections);
  const buffer = new ArrayBuffer(1 + 8 + 8 + 12 + 2 + 1 + 1 + 8 + 8 + 2 + sectionsBytes.length);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.ChunkSnapshot);
  offset += 1;
  view.setBigUint64(offset, 42n, false);
  offset += 8;
  view.setBigUint64(offset, 5n, false);
  offset += 8;
  view.setInt32(offset, 0, false);
  view.setInt32(offset + 4, 0, false);
  view.setInt32(offset + 8, 0, false);
  offset += 12;
  view.setUint16(offset, 1, false);
  offset += 2;
  view.setUint8(offset, VoxelConstants.ChunkSizeInMacros);
  offset += 1;
  view.setUint8(offset, VoxelConstants.MicroPerMacro);
  offset += 1;
  view.setBigUint64(offset, 77n, false);
  offset += 8;
  view.setBigUint64(offset, 88n, false);
  offset += 8;
  view.setUint16(offset, sections.length, false);
  offset += 2;
  new Uint8Array(buffer, offset).set(sectionsBytes);
  return buffer;
}

function macroHeadersSection(): Uint8Array {
  const buffer = new ArrayBuffer(VoxelConstants.MacroCountPerChunk * 19);
  const view = new DataView(buffer);
  for (let index = 0; index < VoxelConstants.MacroCountPerChunk; index += 1) {
    const offset = index * 19;
    view.setUint8(offset, EVoxelCellMode.Empty);
    view.setUint32(offset + 7, 0xffff_ffff, false);
  }
  const solidOffset = 801 * 19;
  view.setUint8(solidOffset, EVoxelCellMode.SolidBlock);
  view.setUint16(solidOffset + 1, 7, false);
  view.setUint32(solidOffset + 3, 0, false);
  view.setUint32(solidOffset + 7, 0xffff_ffff, false);
  view.setUint32(solidOffset + 11, 13, false);
  view.setUint32(solidOffset + 15, 14, false);
  return new Uint8Array(buffer);
}

function normalBlocksSection(): Uint8Array {
  const buffer = new ArrayBuffer(4 + 20);
  const view = new DataView(buffer);
  view.setUint32(0, 1, false);
  view.setUint16(4, 2, false);
  view.setUint32(6, 1, false);
  view.setUint16(10, 100, false);
  view.setInt16(12, -3, false);
  view.setInt16(14, 4, false);
  view.setUint32(16, 1234, false);
  view.setUint32(20, 5678, false);
  return new Uint8Array(buffer);
}

function emptyPoolSection(): Uint8Array {
  const buffer = new ArrayBuffer(4);
  new DataView(buffer).setUint32(0, 0, false);
  return new Uint8Array(buffer);
}

function section(sectionType: number, data: Uint8Array): Uint8Array {
  const buffer = new ArrayBuffer(1 + 4 + data.length);
  const view = new DataView(buffer);
  view.setUint8(0, sectionType);
  view.setUint32(1, data.length, false);
  new Uint8Array(buffer, 5).set(data);
  return new Uint8Array(buffer);
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
