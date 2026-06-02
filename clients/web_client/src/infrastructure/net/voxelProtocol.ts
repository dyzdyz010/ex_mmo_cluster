import { decodeAttributeSetPool, type AttributeSet } from "../../voxel/attributeSet";
import { decodeCatalogPatchPayload, type CatalogPatch } from "../../voxel/catalogPatch";
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
import { decodeTagSetPool, type TagSet } from "../../voxel/tagSet";
import { decodeObjectStateDelta, type ObjectStateDelta } from "./objectStateDelta";
import {
  decodeFieldRegionDestroyed,
  decodeFieldRegionSnapshot,
  type FFieldRegionDestroyed,
  type FFieldRegionSnapshot,
} from "../../voxel/field/fieldProtocol";
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
  SparseMacroHeaders: 0x08,
} as const;

export interface VoxelKnownChunk {
  chunkCoord: FChunkCoord;
  chunkVersion: number;
}

/**
 * Phase 1.6b: typed ChunkObjectRef decoded from snapshot section 0x07.
 *
 * Mirrors `apps/scene_server/lib/scene_server/voxel/chunk_object_ref.ex`:
 *
 *   object_id:        u64
 *   object_version:   u64
 *   covered_macro_min: { x, y, z } each u8
 *   covered_macro_max: { x, y, z } each u8
 *   cover_hash:       u64
 *
 * 30 bytes per record. Was previously length-only validated (FullCompat-OK);
 * Phase 1.6b lifts it to full field decoding so consumers (audit / explosion
 * provenance / future prefab rollback queries) can read the structured form
 * without re-parsing wire bytes.
 */
export interface ChunkObjectRef {
  objectId: bigint;
  objectVersion: bigint;
  coveredMacroMin: { x: number; y: number; z: number };
  coveredMacroMax: { x: number; y: number; z: number };
  coverHash: bigint;
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
  // Phase 1.6b: typed sections previously dropped at decode time.
  attributeSets: AttributeSet[];
  tagSets: TagSet[];
  objectRefs: ChunkObjectRef[];
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
  reasonName:
    | "unspecified"
    | "migration_cutover"
    | "region_removed"
    | "catalog_changed"
    | "unknown";
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

// Phase 1.6b: 0x71 CatalogPatch — envelope-only forward-compat dispatch.
// Payload `ops[*].payload` bytes are opaque until Phase 5 introduces the
// AttributeDefinition / TagDefinition typed payloads. The decoder is a
// byte-stable pass-through (unknown op_kinds are preserved).
export interface VoxelCatalogPatchMessage {
  type: "voxel_catalog_patch";
  patch: CatalogPatch;
}

export interface VoxelFieldRegionSnapshotMessage {
  type: "voxel_field_region_snapshot";
  snapshot: FFieldRegionSnapshot;
}

export interface VoxelFieldRegionDestroyedMessage {
  type: "voxel_field_region_destroyed";
  destroyed: FFieldRegionDestroyed;
}

export type VoxelServerMessage =
  | VoxelChunkSnapshotMessage
  | VoxelChunkDeltaMessage
  | VoxelChunkInvalidateMessage
  | VoxelIntentResultMessage
  | VoxelDebugProbeMessage
  | VoxelObjectStateDeltaMessage
  | VoxelCatalogPatchMessage
  | VoxelFieldRegionSnapshotMessage
  | VoxelFieldRegionDestroyedMessage;

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

export function encodeVoxelChunkAck(request: {
  requestId: number;
  logicalSceneId: number;
  acks: readonly VoxelKnownChunk[];
}): Uint8Array {
  const buffer = new ArrayBuffer(1 + 8 + 8 + 2 + request.acks.length * 20);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, VoxelOpcode.VoxelChunkAck);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  view.setUint16(offset, request.acks.length, false);
  offset += 2;
  for (const ack of request.acks) {
    writeChunkCoord(view, offset, ack.chunkCoord);
    offset += 12;
    writeU64(view, offset, ack.chunkVersion);
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

const FieldConductModeCode = {
  conductive: 0,
  discharge: 1,
} as const;

const FieldConductOutputModeCode = {
  dc: 1,
  ac: 2,
  pulse: 3,
} as const;

const FieldConductPowerFlags = {
  OutputMode: 0x0001,
  Voltage: 0x0002,
  CurrentLimitAmps: 0x0004,
  FrequencyHz: 0x0008,
  LoadCurrentAmps: 0x0010,
  EnergyBudgetJoules: 0x0020,
} as const;

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

export function encodeVoxelFieldConductIntent(request: {
  requestId: number;
  clientIntentSeq: number;
  logicalSceneId: number;
  sourceWorldMacro: FMacroCoord;
  targetWorldMacro: FMacroCoord;
  sourcePotential: number;
  maxTicks: number;
  conductionMode?: "conductive" | "discharge";
  outputMode?: "dc" | "ac" | "pulse";
  voltage?: number;
  currentLimitAmps?: number;
  frequencyHz?: number;
  loadCurrentAmps?: number;
  energyBudgetJoules?: number;
}): Uint8Array {
  const buffer = new ArrayBuffer(125);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint8(offset, VoxelOpcode.FieldConductIntent);
  offset += 1;
  writeU64(view, offset, request.requestId);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.clientIntentSeq)), false);
  offset += 4;
  writeU64(view, offset, request.logicalSceneId);
  offset += 8;
  writeI64(view, offset, request.sourceWorldMacro.x);
  offset += 8;
  writeI64(view, offset, request.sourceWorldMacro.y);
  offset += 8;
  writeI64(view, offset, request.sourceWorldMacro.z);
  offset += 8;
  writeI64(view, offset, request.targetWorldMacro.x);
  offset += 8;
  writeI64(view, offset, request.targetWorldMacro.y);
  offset += 8;
  writeI64(view, offset, request.targetWorldMacro.z);
  offset += 8;
  view.setFloat64(offset, finiteFieldNumber(request.sourcePotential, 120), false);
  offset += 8;
  view.setUint32(offset, Math.max(0, Math.trunc(request.maxTicks)), false);
  offset += 4;
  view.setUint8(offset, FieldConductModeCode[request.conductionMode ?? "conductive"]);
  offset += 1;
  view.setUint8(offset, request.outputMode ? FieldConductOutputModeCode[request.outputMode] : 0);
  offset += 1;

  const flags = fieldConductPowerFlags(request);
  view.setUint16(offset, flags, false);
  offset += 2;
  view.setFloat64(offset, finiteFieldNumber(request.voltage, 0), false);
  offset += 8;
  view.setFloat64(offset, finiteFieldNumber(request.currentLimitAmps, 0), false);
  offset += 8;
  view.setFloat64(offset, finiteFieldNumber(request.frequencyHz, 0), false);
  offset += 8;
  view.setFloat64(offset, finiteFieldNumber(request.loadCurrentAmps, 0), false);
  offset += 8;
  view.setFloat64(offset, finiteFieldNumber(request.energyBudgetJoules, 0), false);
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
    case VoxelOpcode.CatalogPatch:
      return decodeCatalogPatchMessage(payload);
    case VoxelOpcode.FieldRegionSnapshot:
      return decodeFieldRegionSnapshotMessage(payload);
    case VoxelOpcode.FieldRegionDestroyed:
      return decodeFieldRegionDestroyedMessage(payload);
    default:
      return null;
  }
}

function decodeCatalogPatchMessage(payload: ArrayBuffer): VoxelCatalogPatchMessage {
  // Skip the leading opcode byte; the envelope decoder consumes the body
  // without the opcode prefix (mirrors decodeObjectStateDeltaMessage above).
  const body = new DataView(payload, 1);
  const patch = decodeCatalogPatchPayload(body);
  return { type: "voxel_catalog_patch", patch };
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

function invalidateReasonName(reason: number): VoxelChunkInvalidateMessage["reasonName"] {
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
  const compactEmpty = sectionCount === 0;
  const macroHeaders = compactEmpty
    ? buildEmptyMacroHeaders()
    : decodeSnapshotMacroHeaders(sections);
  const normalBlocks = compactEmpty
    ? []
    : decodeNormalBlocks(requireSection(sections, SnapshotSection.NormalBlocks));
  const refinedCellsWire = compactEmpty
    ? []
    : decodeRefinedCellPool(requireSection(sections, SnapshotSection.RefinedCells));
  const attributeSets = compactEmpty
    ? []
    : decodeAttributeSetPool(requireSection(sections, SnapshotSection.AttributeSets));
  const tagSets = compactEmpty
    ? []
    : decodeTagSetPool(requireSection(sections, SnapshotSection.TagSets));
  const environmentSummaries = compactEmpty
    ? []
    : decodeEnvironmentSummaries(requireSection(sections, SnapshotSection.EnvironmentSummaries));
  const objectRefs = compactEmpty
    ? []
    : decodeObjectRefsSection(requireSection(sections, SnapshotSection.ObjectRefs));

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
    attributeSets,
    tagSets,
    objectRefs,
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

function buildEmptyMacroHeaders(): FMacroCellHeader[] {
  return Array.from({ length: VoxelConstants.MacroCountPerChunk }, () => ({
    mode: EVoxelCellMode.Empty,
    flags: 0,
    payloadIndex: SERVER_ENV_INDEX_UNSET,
    environmentIndex: MACRO_ENV_INDEX_UNSET,
    cellVersion: 0,
    cellHash: 0,
  }));
}

function decodeSnapshotMacroHeaders(sections: Map<number, DataView>): FMacroCellHeader[] {
  const full = sections.get(SnapshotSection.MacroHeaders);
  const sparse = sections.get(SnapshotSection.SparseMacroHeaders);
  if (full && sparse) {
    throw new Error("duplicate_voxel_snapshot_macro_headers");
  }
  if (full) {
    return decodeMacroHeaders(full);
  }
  if (sparse) {
    return decodeSparseMacroHeaders(sparse);
  }
  throw new Error("missing_voxel_snapshot_macro_headers");
}

function decodeMacroHeaders(section: DataView): FMacroCellHeader[] {
  const wireSize = 19;
  const expectedLength = VoxelConstants.MacroCountPerChunk * wireSize;
  if (section.byteLength !== expectedLength) {
    throw new Error(`invalid_macro_header_section:${section.byteLength}`);
  }
  const headers: FMacroCellHeader[] = [];
  for (let offset = 0; offset < section.byteLength; offset += wireSize) {
    headers.push(readMacroHeaderAt(section, offset));
  }
  return headers;
}

function decodeSparseMacroHeaders(section: DataView): FMacroCellHeader[] {
  const wireSize = 2 + 19;
  if (section.byteLength < 2) {
    throw new Error(`invalid_sparse_macro_header_section:${section.byteLength}`);
  }
  const count = section.getUint16(0, false);
  if (section.byteLength !== 2 + count * wireSize) {
    throw new Error(`invalid_sparse_macro_header_section:${section.byteLength}`);
  }

  const headers = buildEmptyMacroHeaders();
  const seen = new Set<number>();
  let offset = 2;
  for (let entryIndex = 0; entryIndex < count; entryIndex += 1) {
    const macroIndex = section.getUint16(offset, false);
    offset += 2;
    if (macroIndex >= VoxelConstants.MacroCountPerChunk) {
      throw new Error(`sparse_macro_header_index_out_of_range:${macroIndex}`);
    }
    if (seen.has(macroIndex)) {
      throw new Error(`duplicate_sparse_macro_header:${macroIndex}`);
    }
    seen.add(macroIndex);
    headers[macroIndex] = readMacroHeaderAt(section, offset);
    offset += 19;
  }
  return headers;
}

function readMacroHeaderAt(section: DataView, offset: number): FMacroCellHeader {
  const environmentIndex = section.getUint32(offset + 7, false);
  return {
    mode: decodeCellMode(section.getUint8(offset)),
    flags: section.getUint16(offset + 1, false),
    payloadIndex: section.getUint32(offset + 3, false),
    environmentIndex:
      environmentIndex === SERVER_ENV_INDEX_UNSET ? MACRO_ENV_INDEX_UNSET : environmentIndex,
    cellVersion: section.getUint32(offset + 11, false),
    cellHash: section.getUint32(offset + 15, false),
  };
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

function decodeObjectRefsSection(section: DataView): ChunkObjectRef[] {
  const count = section.getUint32(0, false);
  const wireSize = 30;
  if (section.byteLength !== 4 + count * wireSize) {
    throw new Error(`invalid_object_ref_section:${section.byteLength}`);
  }
  // Mirrors decode_object_refs!/1 in apps/scene_server/lib/scene_server/voxel/codec.ex:
  //   object_id:        u64-be   (8 bytes)
  //   object_version:   u64-be   (8 bytes)
  //   covered_macro_min: u8 x, u8 y, u8 z   (3 bytes)
  //   covered_macro_max: u8 x, u8 y, u8 z   (3 bytes)
  //   cover_hash:       u64-be   (8 bytes)
  // Total 30 bytes per record.
  const refs: ChunkObjectRef[] = [];
  let offset = 4;
  for (let i = 0; i < count; i += 1) {
    const objectId = section.getBigUint64(offset, false);
    offset += 8;
    const objectVersion = section.getBigUint64(offset, false);
    offset += 8;
    const minX = section.getUint8(offset);
    offset += 1;
    const minY = section.getUint8(offset);
    offset += 1;
    const minZ = section.getUint8(offset);
    offset += 1;
    const maxX = section.getUint8(offset);
    offset += 1;
    const maxY = section.getUint8(offset);
    offset += 1;
    const maxZ = section.getUint8(offset);
    offset += 1;
    const coverHash = section.getBigUint64(offset, false);
    offset += 8;
    refs.push({
      objectId,
      objectVersion,
      coveredMacroMin: { x: minX, y: minY, z: minZ },
      coveredMacroMax: { x: maxX, y: maxY, z: maxZ },
      coverHash,
    });
  }
  return refs;
}

function writeChunkCoord(view: DataView, offset: number, coord: FChunkCoord): void {
  view.setInt32(offset, Math.trunc(coord.x), false);
  view.setInt32(offset + 4, Math.trunc(coord.y), false);
  view.setInt32(offset + 8, Math.trunc(coord.z), false);
}

function fieldConductPowerFlags(request: {
  outputMode?: "dc" | "ac" | "pulse";
  voltage?: number;
  currentLimitAmps?: number;
  frequencyHz?: number;
  loadCurrentAmps?: number;
  energyBudgetJoules?: number;
}): number {
  let flags = 0;
  if (request.outputMode !== undefined) flags |= FieldConductPowerFlags.OutputMode;
  if (request.voltage !== undefined) flags |= FieldConductPowerFlags.Voltage;
  if (request.currentLimitAmps !== undefined) flags |= FieldConductPowerFlags.CurrentLimitAmps;
  if (request.frequencyHz !== undefined) flags |= FieldConductPowerFlags.FrequencyHz;
  if (request.loadCurrentAmps !== undefined) flags |= FieldConductPowerFlags.LoadCurrentAmps;
  if (request.energyBudgetJoules !== undefined) flags |= FieldConductPowerFlags.EnergyBudgetJoules;
  return flags;
}

function finiteFieldNumber(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
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

// Phase 6: FieldRegionSnapshot (0x73) decoder
function decodeFieldRegionSnapshotMessage(
  payload: ArrayBuffer,
): VoxelFieldRegionSnapshotMessage | null {
  const snapshot = decodeFieldRegionSnapshot(payload);
  if (!snapshot) return null;
  return { type: "voxel_field_region_snapshot", snapshot };
}

// Phase 6: FieldRegionDestroyed (0x74) decoder
function decodeFieldRegionDestroyedMessage(
  payload: ArrayBuffer,
): VoxelFieldRegionDestroyedMessage | null {
  const destroyed = decodeFieldRegionDestroyed(payload);
  if (!destroyed) return null;
  return { type: "voxel_field_region_destroyed", destroyed };
}
