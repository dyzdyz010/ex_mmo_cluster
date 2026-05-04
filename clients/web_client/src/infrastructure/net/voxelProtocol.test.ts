import { VoxelConstants } from "../../voxel/core/constants";
import { EVoxelCellMode } from "../../voxel/core/types";
import { VoxelDirtyFlags } from "../../voxel/storage/types";
import { VoxelIntentResult, VoxelOpcode } from "./opcodes";
import {
  decodeVoxelServerMessage,
  encodeVoxelBuildReservationIntent,
  encodeVoxelChunkSubscribe,
  encodeVoxelDebugProbe,
  encodeVoxelImpactIntent,
  encodeVoxelPrefabPlaceIntent,
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

  it("encodes voxel build reservation intent with big-endian fields and signed AabbI64 bounds", () => {
    const encoded = encodeVoxelBuildReservationIntent({
      requestId: 200,
      clientIntentSeq: 5,
      logicalSceneId: 555,
      parcelId: 9001,
      knownParcelBuildEpoch: 17,
      boundsWorldMicro: {
        minX: -100,
        minY: -50,
        minZ: -25,
        maxX: 200,
        maxY: 75,
        maxZ: 50,
      },
      intentHash: 0xdead_beef,
      ttlMs: 5000,
    });
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    // 1 (opcode) + 8 + 4 + 8 + 8 + 8 + 6 * 8 + 8 + 4 = 97 bytes.
    expect(encoded.byteLength).toBe(97);
    expect(view.getUint8(0)).toBe(VoxelOpcode.BuildReservationIntent);
    expect(Number(view.getBigUint64(1, false))).toBe(200);
    expect(view.getUint32(9, false)).toBe(5);
    expect(Number(view.getBigUint64(13, false))).toBe(555);
    expect(Number(view.getBigUint64(21, false))).toBe(9001);
    expect(Number(view.getBigUint64(29, false))).toBe(17);
    expect(Number(view.getBigInt64(37, false))).toBe(-100);
    expect(Number(view.getBigInt64(45, false))).toBe(-50);
    expect(Number(view.getBigInt64(53, false))).toBe(-25);
    expect(Number(view.getBigInt64(61, false))).toBe(200);
    expect(Number(view.getBigInt64(69, false))).toBe(75);
    expect(Number(view.getBigInt64(77, false))).toBe(50);
    expect(Number(view.getBigUint64(85, false))).toBe(0xdead_beef);
    expect(view.getUint32(93, false)).toBe(5000);
  });

  it("encodes voxel prefab place intent with known refs, objects and cell refs in big-endian order", () => {
    const encoded = encodeVoxelPrefabPlaceIntent({
      requestId: 300,
      clientIntentSeq: 6,
      logicalSceneId: 777,
      parcelId: 8888,
      knownParcelBuildEpoch: 21,
      blueprintId: 4242,
      blueprintVersion: 7,
      anchorWorldMicro: { x: 1000, y: -2000, z: 3000 },
      rotation: 90,
      knownRefs: [{ chunkCoord: { x: -1, y: 0, z: 1 }, chunkVersion: 11 }],
      knownObjects: [{ objectId: 9001, objectVersion: 1 }],
      knownCellRefs: [
        {
          chunkCoord: { x: -1, y: 0, z: 1 },
          macroIndex: 1234,
          cellVersion: 5,
          cellHash: 0xaabb_ccdd,
        },
      ],
      placementFlags: 0x0000_0001,
    });
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    // Header (74) + ref_count u16 (2) + 1 ref (20) + obj_count u16 (2) +
    // 1 obj (16) + cell_count u16 (2) + 1 cell ref (22) + flags u32 (4)
    // = 142 bytes total.
    expect(encoded.byteLength).toBe(142);
    expect(view.getUint8(0)).toBe(VoxelOpcode.PrefabPlaceIntent);
    expect(Number(view.getBigUint64(1, false))).toBe(300);
    expect(view.getUint32(9, false)).toBe(6);
    expect(Number(view.getBigUint64(13, false))).toBe(777);
    expect(Number(view.getBigUint64(21, false))).toBe(8888);
    expect(Number(view.getBigUint64(29, false))).toBe(21);
    expect(Number(view.getBigUint64(37, false))).toBe(4242);
    expect(view.getUint32(45, false)).toBe(7);
    expect(Number(view.getBigInt64(49, false))).toBe(1000);
    expect(Number(view.getBigInt64(57, false))).toBe(-2000);
    expect(Number(view.getBigInt64(65, false))).toBe(3000);
    expect(view.getUint8(73)).toBe(90);
    expect(view.getUint16(74, false)).toBe(1);

    // known_refs[0]
    expect(view.getInt32(76, false)).toBe(-1);
    expect(view.getInt32(80, false)).toBe(0);
    expect(view.getInt32(84, false)).toBe(1);
    expect(Number(view.getBigUint64(88, false))).toBe(11);

    // known_object_count + known_objects[0]
    expect(view.getUint16(96, false)).toBe(1);
    expect(Number(view.getBigUint64(98, false))).toBe(9001);
    expect(Number(view.getBigUint64(106, false))).toBe(1);

    // known_cell_ref_count + known_cell_refs[0]
    expect(view.getUint16(114, false)).toBe(1);
    expect(view.getInt32(116, false)).toBe(-1);
    expect(view.getInt32(120, false)).toBe(0);
    expect(view.getInt32(124, false)).toBe(1);
    expect(view.getUint16(128, false)).toBe(1234);
    expect(view.getUint32(130, false)).toBe(5);
    expect(view.getUint32(134, false)).toBe(0xaabb_ccdd);

    // placement_flags trailer
    expect(view.getUint32(138, false)).toBe(0x0000_0001);
  });

  it("encodes voxel prefab place intent with empty known arrays", () => {
    const encoded = encodeVoxelPrefabPlaceIntent({
      requestId: 1,
      clientIntentSeq: 2,
      logicalSceneId: 3,
      parcelId: 4,
      knownParcelBuildEpoch: 5,
      blueprintId: 6,
      blueprintVersion: 7,
      anchorWorldMicro: { x: 0, y: 0, z: 0 },
      rotation: 0,
    });
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    // Header 74 + 2 + 0 + 2 + 0 + 2 + 0 + 4 = 84 bytes.
    expect(encoded.byteLength).toBe(84);
    expect(view.getUint8(0)).toBe(VoxelOpcode.PrefabPlaceIntent);
    expect(view.getUint16(74, false)).toBe(0);
    expect(view.getUint16(76, false)).toBe(0);
    expect(view.getUint16(78, false)).toBe(0);
    expect(view.getUint32(80, false)).toBe(0);
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

  it("decodes a ChunkInvalidate payload from the 0x69 opcode", () => {
    const buffer = new ArrayBuffer(1 + 8 + 12 + 1);
    const view = new DataView(buffer);
    view.setUint8(0, VoxelOpcode.ChunkInvalidate);
    view.setBigUint64(1, 11n, false);
    view.setInt32(9, -2, false);
    view.setInt32(13, 3, false);
    view.setInt32(17, -4, false);
    view.setUint8(21, 0x01);

    const message = decodeVoxelServerMessage(buffer);

    expect(message?.type).toBe("voxel_chunk_invalidate");
    if (message?.type !== "voxel_chunk_invalidate") return;
    expect(message.logicalSceneId).toBe(11);
    expect(message.chunkCoord).toEqual({ x: -2, y: 3, z: -4 });
    expect(message.reason).toBe(0x01);
    expect(message.reasonName).toBe("migration_cutover");
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
    const [op] = message.ops;
    if (!op) throw new Error("expected one op");
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
