import { VoxelConstants } from "../../voxel/core/constants";
import { EVoxelCellMode, type FChunkCoord, type FMacroCoord } from "../../voxel/core/types";
import {
  MACRO_ENV_INDEX_UNSET,
  VoxelDirtyFlags,
  type FChunkStorageData,
  type FMacroCellHeader,
  type FMacroEnvironmentSummary,
  type FNormalBlockData,
} from "../../voxel/storage/types";
import { decodeObjectStateDelta, type ObjectStateDelta } from "./objectStateDelta";
import { VoxelIntentResult, VoxelOpcode } from "./opcodes";
import {
  decodeRefinedCellPayload,
  decodeRefinedCellPool,
  type RefinedCellWireData,
} from "./refinedCellWire";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const SERVER_ENV_INDEX_UNSET = 0xffff_ffff;

const SnapshotSection = {
  MacroHeaders: 0x01,
  NormalBlocks: 0x02,
  RefinedCells: 0x03,
  AttributeSets: 0x04,
  TagSets: 0x05,
  EnvironmentSummaries: 0x06,
  ObjectRefs: 0x07,
} as const;

export interface VoxelKnownChunk {
  chunkCoord: FChunkCoord;
  chunkVersion: number;
}

export interface VoxelChunkSnapshotMessage {
  type: "voxel_chunk_snapshot";
  requestId: number;
  logicalSceneId: number;
  chunkCoord: FChunkCoord;
  schemaVersion: number;
  chunkSizeInMacro: number;
  microResolution: number;
  chunkVersion: number;
  chunkHash: number;
  storage: FChunkStorageData;
  // Phase 1a: server-authoritative refined-cell wire data, parallel to the
  // legacy `storage.refinedCells` (which stays empty in online mode and is
  // owned by browser offline path). 1c will lift this into storage proper.
  refinedCellsWire: RefinedCellWireData[];
}

export interface VoxelAuthoritativeCell {
  chunkCoord: FChunkCoord;
  chunkVersion: number;
  macroIndex: number;
  cellVersion: number;
  cellHash: number;
  payloadKind: number;
  cellPayload: Uint8Array;
}

export interface VoxelChunkDeltaOp {
  deltaKind: number;
  macroIndex: number;
  cellVersion: number;
  cellHash: number;
  payload: Uint8Array;
  // Phase 1c-3 / 1c-5: pre-decoded payload for `delta_kind = 2 (CellRefined)`
  // ops, so consumers can apply the wire-form refined cell without each
  // touching `decodeRefinedCellPayload` themselves. Other delta kinds leave
  // this `null` and continue to inspect `payload` directly.
  refinedCell: RefinedCellWireData | null;
}

export interface VoxelChunkDeltaMessage {
  type: "voxel_chunk_delta";
  logicalSceneId: number;
  chunkCoord: FChunkCoord;
  baseChunkVersion: number;
  newChunkVersion: number;
  ops: VoxelChunkDeltaOp[];
}

export const VoxelChunkDeltaKind = {
  CellEmpty: 0,
  CellSolid: 1,
  CellRefined: 2,
  EnvironmentUpdated: 3,
  ObjectRefUpdated: 4,
  CatalogPatch: 5,
} as const;

export type VoxelChunkDeltaKindValue =
  (typeof VoxelChunkDeltaKind)[keyof typeof VoxelChunkDeltaKind];

export const VoxelChunkInvalidateReason = {
  Unspecified: 0,
  MigrationCutover: 1,
  RegionRemoved: 2,
  CatalogChanged: 3,
} as const;

export type VoxelChunkInvalidateReasonValue =
  (typeof VoxelChunkInvalidateReason)[keyof typeof VoxelChunkInvalidateReason];

export interface VoxelChunkInvalidateMessage {
  type: "voxel_chunk_invalidate";
  logicalSceneId: number;
  chunkCoord: FChunkCoord;
  reason: number;
  reasonName: "unspecified" | "migration_cutover" | "region_removed" | "catalog_changed" | "unknown";
}

export interface VoxelIntentResultMessage {
  type: "voxel_intent_result";
  requestId: number;
  clientIntentSeq: number;
  logicalSceneId: number;
  resultCode: number;
  resultCodeName: "accepted" | "deferred" | "rejected" | "stale" | "unknown";
  resultRef: number;
  authoritative: VoxelAuthoritativeCell[];
  reason: string;
}

export interface VoxelDebugProbeMessage {
  type: "voxel_debug_probe";
  requestId: number;
  result: string;
}

// Phase 4-bis: 0x6C ObjectStateDelta — server-authoritative object state
// change (created / damaged / part_destroyed / destroyed). Mirrors the
// scene-side encoder in `apps/scene_server/lib/scene_server/voxel/codec.ex`.
// `delta` carries bigint-typed scalars (the underlying decoder lives in
// objectStateDelta.ts and is shared with cross-codec roundtrip tests).
export interface VoxelObjectStateDeltaMessage {
  type: "voxel_object_state_delta";
  delta: ObjectStateDelta;
}

export type VoxelServerMessage =
  | VoxelChunkSnapshotMessage
  | VoxelChunkDeltaMessage
  | VoxelChunkInvalidateMessage
  | VoxelIntentResultMessage
  | VoxelDebugProbeMessage
  | VoxelObjectStateDeltaMessage;

export function encodeVoxelDebugProbe(
  requestId: number,
  command: string = "voxel_transport",
): Uint8Array {
  const commandBytes = textEncoder.encode(command);
  const buffer = new ArrayBuffer(1 + 8 + 2 + commandBytes.length);
  const view = new DataView(buffer);
  view.setUint8(0, VoxelOpcode.VoxelDebugProbe);
  writeU64(view, 1, requestId);
  view.setUint16(9, commandBytes.length, false);
  new Uint8Array(buffer, 11, commandBytes.length).set(commandBytes);
  return new Uint8Array(buffer);
}

export function encodeVoxelChunkSubscribe(request: {
  requestId: number;
  logicalSceneId: number;
  centerChunk: FChunkCoord;
  radiusLInf?: number;
  wantSnapshot?: boolean;
  known?: readonly VoxelKnownChunk[];
}): Uint8Array {
  const known = request.known ?? [];
  const buffer = new ArrayBuffer(1 + 8 + 8 + 12 + 1 + 1 + 2 + known.length * 20);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.ChunkSubscribe);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  writeChunkCoord(view, offset, request.centerChunk);
  offset += 12;
  view.setUint8(offset, Math.max(0, Math.trunc(request.radiusLInf ?? 0)));
  offset += 1;
  view.setUint8(offset, request.wantSnapshot === false ? 0 : 1);
  offset += 1;
  view.setUint16(offset, known.length, false);
  offset += 2;
  for (const entry of known) {
    writeChunkCoord(view, offset, entry.chunkCoord);
    offset += 12;
    writeU64(view, offset, entry.chunkVersion);
    offset += 8;
  }
  return new Uint8Array(buffer);
}

export function encodeVoxelChunkUnsubscribe(request: {
  requestId: number;
  logicalSceneId: number;
  chunks: readonly FChunkCoord[];
}): Uint8Array {
  const buffer = new ArrayBuffer(1 + 8 + 8 + 2 + request.chunks.length * 12);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.ChunkUnsubscribe);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  view.setUint16(offset, request.chunks.length, false);
  offset += 2;
  for (const chunk of request.chunks) {
    writeChunkCoord(view, offset, chunk);
    offset += 12;
  }
  return new Uint8Array(buffer);
}

export interface VoxelAabbI64 {
  minX: number;
  minY: number;
  minZ: number;
  maxX: number;
  maxY: number;
  maxZ: number;
}

export interface VoxelPrefabKnownRef {
  chunkCoord: FChunkCoord;
  chunkVersion: number;
}

export interface VoxelPrefabKnownObject {
  objectId: number;
  objectVersion: number;
}

export interface VoxelPrefabKnownCellRef {
  chunkCoord: FChunkCoord;
  macroIndex: number;
  cellVersion: number;
  cellHash: number;
}

export function encodeVoxelBuildReservationIntent(request: {
  requestId: number;
  clientIntentSeq: number;
  logicalSceneId: number;
  parcelId: number;
  knownParcelBuildEpoch: number;
  boundsWorldMicro: VoxelAabbI64;
  intentHash?: number;
  ttlMs: number;
}): Uint8Array {
  // 1 (opcode) + 8 (request_id) + 4 (client_intent_seq) + 8 (logical_scene_id) +
  // 8 (parcel_id) + 8 (known_parcel_build_epoch) + 6 * 8 (AabbI64) +
  // 8 (intent_hash) + 4 (ttl_ms) = 97 bytes total.
  const buffer = new ArrayBuffer(1 + 8 + 4 + 8 + 8 + 8 + 6 * 8 + 8 + 4);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.BuildReservationIntent);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.clientIntentSeq)), false);
  offset += 4;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  writeU64(view, offset, request.parcelId);
  offset += 8;
  writeU64(view, offset, request.knownParcelBuildEpoch);
  offset += 8;
  writeI64(view, offset, request.boundsWorldMicro.minX);
  offset += 8;
  writeI64(view, offset, request.boundsWorldMicro.minY);
  offset += 8;
  writeI64(view, offset, request.boundsWorldMicro.minZ);
  offset += 8;
  writeI64(view, offset, request.boundsWorldMicro.maxX);
  offset += 8;
  writeI64(view, offset, request.boundsWorldMicro.maxY);
  offset += 8;
  writeI64(view, offset, request.boundsWorldMicro.maxZ);
  offset += 8;
  writeU64(view, offset, request.intentHash ?? 0);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.ttlMs)), false);
  return new Uint8Array(buffer);
}

export function encodeVoxelPrefabPlaceIntent(request: {
  requestId: number;
  clientIntentSeq: number;
  logicalSceneId: number;
  parcelId: number;
  knownParcelBuildEpoch: number;
  blueprintId: number;
  blueprintVersion: number;
  anchorWorldMicro: FMacroCoord;
  rotation: number;
  knownRefs?: readonly VoxelPrefabKnownRef[];
  knownObjects?: readonly VoxelPrefabKnownObject[];
  knownCellRefs?: readonly VoxelPrefabKnownCellRef[];
  placementFlags?: number;
}): Uint8Array {
  const knownRefs = request.knownRefs ?? [];
  const knownObjects = request.knownObjects ?? [];
  const knownCellRefs = request.knownCellRefs ?? [];

  // Header (fixed): 1 (opcode) + 8 (request_id) + 4 (client_intent_seq) +
  // 8 (logical_scene_id) + 8 (parcel_id) + 8 (epoch) + 8 (blueprint_id) +
  // 4 (blueprint_version) + 24 (anchor) + 1 (rotation) = 74 bytes.
  // known_refs[]: 12 (chunk_coord) + 8 (chunk_version) = 20 bytes per ref.
  // known_objects[]: 8 + 8 = 16 bytes per object.
  // known_cell_refs[]: 12 + 2 + 4 + 4 = 22 bytes per cell ref.
  // Plus three u16 counts (6 bytes) and one u32 placement_flags trailer.
  const totalLength =
    74 +
    2 +
    knownRefs.length * 20 +
    2 +
    knownObjects.length * 16 +
    2 +
    knownCellRefs.length * 22 +
    4;

  const buffer = new ArrayBuffer(totalLength);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.PrefabPlaceIntent);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.clientIntentSeq)), false);
  offset += 4;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  writeU64(view, offset, request.parcelId);
  offset += 8;
  writeU64(view, offset, request.knownParcelBuildEpoch);
  offset += 8;
  writeU64(view, offset, request.blueprintId);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.blueprintVersion)), false);
  offset += 4;
  writeI64(view, offset, request.anchorWorldMicro.x);
  offset += 8;
  writeI64(view, offset, request.anchorWorldMicro.y);
  offset += 8;
  writeI64(view, offset, request.anchorWorldMicro.z);
  offset += 8;
  view.setUint8(offset, Math.max(0, Math.min(0xff, Math.trunc(request.rotation))));
  offset += 1;
  view.setUint16(offset, knownRefs.length, false);
  offset += 2;
  for (const ref of knownRefs) {
    writeChunkCoord(view, offset, ref.chunkCoord);
    offset += 12;
    writeU64(view, offset, ref.chunkVersion);
    offset += 8;
  }
  view.setUint16(offset, knownObjects.length, false);
  offset += 2;
  for (const object of knownObjects) {
    writeU64(view, offset, object.objectId);
    offset += 8;
    writeU64(view, offset, object.objectVersion);
    offset += 8;
  }
  view.setUint16(offset, knownCellRefs.length, false);
  offset += 2;
  for (const cellRef of knownCellRefs) {
    writeChunkCoord(view, offset, cellRef.chunkCoord);
    offset += 12;
    view.setUint16(offset, Math.max(0, Math.min(0xffff, Math.trunc(cellRef.macroIndex))), false);
    offset += 2;
    view.setUint32(offset, Math.max(0, Math.trunc(cellRef.cellVersion)), false);
    offset += 4;
    view.setUint32(offset, Math.max(0, Math.trunc(cellRef.cellHash)), false);
    offset += 4;
  }
  view.setUint32(offset, Math.max(0, Math.trunc(request.placementFlags ?? 0)), false);
  return new Uint8Array(buffer);
}

/**
 * @deprecated Use `encodeVoxelEditIntent` (opcode 0x70) for client-side direct
 * edits. `VoxelImpactIntent` (0x64) is now reserved for the skill/tool-system
 * flow per protocol §13.6 / §13.6.1. Phase 1c will fully take over with the
 * typed intent; until then this function stays callable to avoid breaking
 * existing wiring.
 */
export function encodeVoxelImpactIntent(request: {
  requestId: number;
  clientIntentSeq: number;
  logicalSceneId: number;
  sourceSkillId: number;
  targetWorldMicro: FMacroCoord;
  impactKind: number;
  clientHintHash?: number;
}): Uint8Array {
  const buffer = new ArrayBuffer(1 + 8 + 4 + 8 + 4 + 24 + 2 + 8);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.VoxelImpactIntent);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.clientIntentSeq)), false);
  offset += 4;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.sourceSkillId)), false);
  offset += 4;
  writeI64(view, offset, request.targetWorldMicro.x);
  offset += 8;
  writeI64(view, offset, request.targetWorldMicro.y);
  offset += 8;
  writeI64(view, offset, request.targetWorldMicro.z);
  offset += 8;
  view.setUint16(offset, Math.max(0, Math.trunc(request.impactKind)), false);
  offset += 2;
  writeU64(view, offset, request.clientHintHash ?? 0);
  return new Uint8Array(buffer);
}

export function decodeVoxelServerMessage(payload: ArrayBuffer): VoxelServerMessage | null {
  if (payload.byteLength < 1) {
    return null;
  }
  const view = new DataView(payload);
  const opcode = view.getUint8(0);
  switch (opcode) {
    case VoxelOpcode.ChunkSnapshot:
      return decodeChunkSnapshot(view);
    case VoxelOpcode.ChunkDelta:
      return decodeChunkDelta(view);
    case VoxelOpcode.ChunkInvalidate:
      return decodeChunkInvalidate(view);
    case VoxelOpcode.VoxelIntentResult:
      return decodeIntentResult(view);
    case VoxelOpcode.VoxelDebugProbe:
      return decodeDebugProbe(view);
    case VoxelOpcode.ObjectStateDelta:
      return decodeObjectStateDeltaMessage(payload);
    default:
      return null;
  }
}

function decodeObjectStateDeltaMessage(payload: ArrayBuffer): VoxelObjectStateDeltaMessage {
  // Skip the leading opcode byte; the shared decoder consumes the payload
  // body without the opcode prefix.
  const body = new Uint8Array(payload, 1);
  const delta = decodeObjectStateDelta(body);
  return { type: "voxel_object_state_delta", delta };
}

function decodeChunkInvalidate(view: DataView): VoxelChunkInvalidateMessage {
  let offset = 1;
  const logicalSceneId = readU64(view, offset);
  offset += 8;
  const chunkCoord = readChunkCoord(view, offset);
  offset += 12;
  const reason = view.getUint8(offset);

  return {
    type: "voxel_chunk_invalidate",
    logicalSceneId,
    chunkCoord,
    reason,
    reasonName: invalidateReasonName(reason),
  };
}

function invalidateReasonName(
  reason: number,
): VoxelChunkInvalidateMessage["reasonName"] {
  switch (reason) {
    case VoxelChunkInvalidateReason.Unspecified:
      return "unspecified";
    case VoxelChunkInvalidateReason.MigrationCutover:
      return "migration_cutover";
    case VoxelChunkInvalidateReason.RegionRemoved:
      return "region_removed";
    case VoxelChunkInvalidateReason.CatalogChanged:
      return "catalog_changed";
    default:
      return "unknown";
  }
}

function decodeChunkDelta(view: DataView): VoxelChunkDeltaMessage {
  let offset = 1;
  const logicalSceneId = readU64(view, offset);
  offset += 8;
  const chunkCoord = readChunkCoord(view, offset);
  offset += 12;
  const baseChunkVersion = readU64(view, offset);
  offset += 8;
  const newChunkVersion = readU64(view, offset);
  offset += 8;
  const opCount = view.getUint16(offset, false);
  offset += 2;

  const ops: VoxelChunkDeltaOp[] = [];
  const buffer = view.buffer;
  for (let i = 0; i < opCount; i += 1) {
    const deltaKind = view.getUint8(offset);
    offset += 1;
    const macroIndex = view.getUint16(offset, false);
    offset += 2;
    const cellVersion = view.getUint32(offset, false);
    offset += 4;
    const cellHash = view.getUint32(offset, false);
    offset += 4;
    const payloadLen = view.getUint16(offset, false);
    offset += 2;
    const payload = new Uint8Array(buffer, view.byteOffset + offset, payloadLen);
    offset += payloadLen;
    const payloadCopy = new Uint8Array(payload);
    const refinedCell =
      deltaKind === VoxelChunkDeltaKind.CellRefined && payloadCopy.length > 0
        ? decodeRefinedCellPayload(
            new DataView(payloadCopy.buffer, payloadCopy.byteOffset, payloadCopy.byteLength),
          )
        : null;
    ops.push({
      deltaKind,
      macroIndex,
      cellVersion,
      cellHash,
      payload: payloadCopy,
      refinedCell,
    });
  }

  return {
    type: "voxel_chunk_delta",
    logicalSceneId,
    chunkCoord,
    baseChunkVersion,
    newChunkVersion,
    ops,
  };
}

function decodeChunkSnapshot(view: DataView): VoxelChunkSnapshotMessage {
  let offset = 1;
  const requestId = readU64(view, offset);
  offset += 8;
  const logicalSceneId = readU64(view, offset);
  offset += 8;
  const chunkCoord = readChunkCoord(view, offset);
  offset += 12;
  const schemaVersion = view.getUint16(offset, false);
  offset += 2;
  const chunkSizeInMacro = view.getUint8(offset);
  offset += 1;
  const microResolution = view.getUint8(offset);
  offset += 1;
  const chunkVersion = readU64(view, offset);
  offset += 8;
  const chunkHash = readU64(view, offset);
  offset += 8;
  const sectionCount = view.getUint16(offset, false);
  offset += 2;

  const sections = readSections(view, offset, sectionCount);
  const macroHeaders = decodeMacroHeaders(requireSection(sections, SnapshotSection.MacroHeaders));
  const normalBlocks = decodeNormalBlocks(requireSection(sections, SnapshotSection.NormalBlocks));
  const refinedCellsWire = decodeRefinedCellPool(
    requireSection(sections, SnapshotSection.RefinedCells),
  );
  ensureEmptyPool(requireSection(sections, SnapshotSection.AttributeSets), "attribute_sets");
  ensureEmptyPool(requireSection(sections, SnapshotSection.TagSets), "tag_sets");
  const environmentSummaries = decodeEnvironmentSummaries(
    requireSection(sections, SnapshotSection.EnvironmentSummaries),
  );
  ensureObjectRefsSection(requireSection(sections, SnapshotSection.ObjectRefs));

  const max = Math.max(0, chunkSizeInMacro - 1);
  return {
    type: "voxel_chunk_snapshot",
    requestId,
    logicalSceneId,
    chunkCoord,
    schemaVersion,
    chunkSizeInMacro,
    microResolution,
    chunkVersion,
    chunkHash,
    storage: {
      chunkCoord,
      macroHeaders,
      normalBlocks,
      refinedCells: [],
      prefabInstances: [],
      environmentSummaries,
      freeNormalBlockIndices: [],
      freeEnvironmentSummaryIndices: [],
      dirtyMacroMin: { x: 0, y: 0, z: 0 },
      dirtyMacroMax: { x: max, y: max, z: max },
      dirtyFlags: VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    },
    refinedCellsWire,
  };
}

function decodeIntentResult(view: DataView): VoxelIntentResultMessage {
  let offset = 1;
  const requestId = readU64(view, offset);
  offset += 8;
  const clientIntentSeq = view.getUint32(offset, false);
  offset += 4;
  const logicalSceneId = readU64(view, offset);
  offset += 8;
  const resultCode = view.getUint8(offset);
  offset += 1;
  const resultRef = readU64(view, offset);
  offset += 8;
  const authoritativeCount = view.getUint16(offset, false);
  offset += 2;

  const authoritative: VoxelAuthoritativeCell[] = [];
  for (let index = 0; index < authoritativeCount; index += 1) {
    const chunkCoord = readChunkCoord(view, offset);
    offset += 12;
    const chunkVersion = readU64(view, offset);
    offset += 8;
    const macroIndex = view.getUint16(offset, false);
    offset += 2;
    const cellVersion = view.getUint32(offset, false);
    offset += 4;
    const cellHash = view.getUint32(offset, false);
    offset += 4;
    const payloadKind = view.getUint8(offset);
    offset += 1;
    const payloadLength = view.getUint32(offset, false);
    offset += 4;
    authoritative.push({
      chunkCoord,
      chunkVersion,
      macroIndex,
      cellVersion,
      cellHash,
      payloadKind,
      cellPayload: new Uint8Array(view.buffer, view.byteOffset + offset, payloadLength).slice(),
    });
    offset += payloadLength;
  }

  const reasonLength = view.getUint16(offset, false);
  offset += 2;
  const reason = textDecoder.decode(
    new Uint8Array(view.buffer, view.byteOffset + offset, reasonLength),
  );

  return {
    type: "voxel_intent_result",
    requestId,
    clientIntentSeq,
    logicalSceneId,
    resultCode,
    resultCodeName: decodeResultCodeName(resultCode),
    resultRef,
    authoritative,
    reason,
  };
}

function decodeDebugProbe(view: DataView): VoxelDebugProbeMessage {
  const requestId = readU64(view, 1);
  const resultLength = view.getUint16(9, false);
  const result = textDecoder.decode(
    new Uint8Array(view.buffer, view.byteOffset + 11, resultLength),
  );
  return { type: "voxel_debug_probe", requestId, result };
}

function readSections(view: DataView, startOffset: number, count: number): Map<number, DataView> {
  const sections = new Map<number, DataView>();
  let offset = startOffset;
  for (let index = 0; index < count; index += 1) {
    const sectionType = view.getUint8(offset);
    offset += 1;
    const sectionLength = view.getUint32(offset, false);
    offset += 4;
    if (sections.has(sectionType)) {
      throw new Error(`duplicate_voxel_snapshot_section:${sectionType}`);
    }
    sections.set(sectionType, sliceView(view, offset, sectionLength));
    offset += sectionLength;
  }
  if (offset !== view.byteLength) {
    throw new Error(`trailing_voxel_snapshot_bytes:${view.byteLength - offset}`);
  }
  return sections;
}

function requireSection(sections: Map<number, DataView>, sectionType: number): DataView {
  const section = sections.get(sectionType);
  if (!section) {
    throw new Error(`missing_voxel_snapshot_section:${sectionType}`);
  }
  return section;
}

function decodeMacroHeaders(section: DataView): FMacroCellHeader[] {
  const wireSize = 19;
  const expectedLength = VoxelConstants.MacroCountPerChunk * wireSize;
  if (section.byteLength !== expectedLength) {
    throw new Error(`invalid_macro_header_section:${section.byteLength}`);
  }
  const headers: FMacroCellHeader[] = [];
  for (let offset = 0; offset < section.byteLength; offset += wireSize) {
    const environmentIndex = section.getUint32(offset + 7, false);
    headers.push({
      mode: decodeCellMode(section.getUint8(offset)),
      flags: section.getUint16(offset + 1, false),
      payloadIndex: section.getUint32(offset + 3, false),
      environmentIndex:
        environmentIndex === SERVER_ENV_INDEX_UNSET ? MACRO_ENV_INDEX_UNSET : environmentIndex,
      cellVersion: section.getUint32(offset + 11, false),
      cellHash: section.getUint32(offset + 15, false),
    });
  }
  return headers;
}

function decodeNormalBlocks(section: DataView): FNormalBlockData[] {
  const count = section.getUint32(0, false);
  const wireSize = 20;
  if (section.byteLength !== 4 + count * wireSize) {
    throw new Error(`invalid_normal_block_section:${section.byteLength}`);
  }
  const blocks: FNormalBlockData[] = [];
  let offset = 4;
  for (let index = 0; index < count; index += 1) {
    blocks.push(readNormalBlockAt(section, offset));
    offset += wireSize;
  }
  return blocks;
}

const NORMAL_BLOCK_WIRE_SIZE = 20;

function readNormalBlockAt(view: DataView, offset: number): FNormalBlockData {
  return {
    materialId: view.getUint16(offset, false),
    stateFlags: view.getUint32(offset + 2, false),
    health: view.getUint16(offset + 6, false),
    temperatureDelta: view.getInt16(offset + 8, false),
    moistureDelta: view.getInt16(offset + 10, false),
    attributeSetRef: view.getUint32(offset + 12, false),
    tagSetRef: view.getUint32(offset + 16, false),
  };
}

export function decodeNormalBlockDataPayload(payload: Uint8Array): FNormalBlockData {
  if (payload.byteLength !== NORMAL_BLOCK_WIRE_SIZE) {
    throw new Error(`invalid_normal_block_payload:${payload.byteLength}`);
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return readNormalBlockAt(view, 0);
}

function decodeEnvironmentSummaries(section: DataView): FMacroEnvironmentSummary[] {
  const count = section.getUint32(0, false);
  const wireSize = 14;
  if (section.byteLength !== 4 + count * wireSize) {
    throw new Error(`invalid_environment_section:${section.byteLength}`);
  }
  const summaries: FMacroEnvironmentSummary[] = [];
  let offset = 4;
  for (let index = 0; index < count; index += 1) {
    summaries.push({
      defaultTemperature: section.getInt16(offset, false),
      defaultMoisture: section.getInt16(offset + 2, false),
      currentTemperature: section.getInt16(offset + 4, false),
      currentMoisture: section.getInt16(offset + 6, false),
      fieldMask: section.getUint16(offset + 8, false),
      sourceHash: section.getUint32(offset + 10, false),
    });
    offset += wireSize;
  }
  return summaries;
}

function ensureEmptyPool(section: DataView, label: string): void {
  if (section.byteLength !== 4 || section.getUint32(0, false) !== 0) {
    throw new Error(`unsupported_voxel_${label}_section:${section.byteLength}`);
  }
}

function ensureObjectRefsSection(section: DataView): void {
  const count = section.getUint32(0, false);
  const wireSize = 30;
  if (section.byteLength !== 4 + count * wireSize) {
    throw new Error(`invalid_object_ref_section:${section.byteLength}`);
  }
}

function writeChunkCoord(view: DataView, offset: number, coord: FChunkCoord): void {
  view.setInt32(offset, Math.trunc(coord.x), false);
  view.setInt32(offset + 4, Math.trunc(coord.y), false);
  view.setInt32(offset + 8, Math.trunc(coord.z), false);
}

function readChunkCoord(view: DataView, offset: number): FChunkCoord {
  return {
    x: view.getInt32(offset, false),
    y: view.getInt32(offset + 4, false),
    z: view.getInt32(offset + 8, false),
  };
}

function writeU64(view: DataView, offset: number, value: number): void {
  view.setBigUint64(offset, BigInt(Math.max(0, Math.trunc(value))), false);
}

function writeI64(view: DataView, offset: number, value: number): void {
  view.setBigInt64(offset, BigInt(Math.trunc(value)), false);
}

function readU64(view: DataView, offset: number): number {
  return Number(view.getBigUint64(offset, false));
}

function sliceView(view: DataView, offset: number, length: number): DataView {
  return new DataView(view.buffer, view.byteOffset + offset, length);
}

function decodeCellMode(raw: number): EVoxelCellMode {
  if (raw === EVoxelCellMode.SolidBlock) {
    return EVoxelCellMode.SolidBlock;
  }
  if (raw === EVoxelCellMode.Refined) {
    return EVoxelCellMode.Refined;
  }
  return EVoxelCellMode.Empty;
}

function decodeResultCodeName(
  code: number,
): "accepted" | "deferred" | "rejected" | "stale" | "unknown" {
  switch (code) {
    case VoxelIntentResult.Accepted:
      return "accepted";
    case VoxelIntentResult.Deferred:
      return "deferred";
    case VoxelIntentResult.Rejected:
      return "rejected";
    case VoxelIntentResult.Stale:
      return "stale";
    default:
      return "unknown";
  }
}
