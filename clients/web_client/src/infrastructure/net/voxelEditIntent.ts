// VoxelEditIntent (0x70) — typed client edit channel.
// Mirrors docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md §13.6.1
// and apps/gate_server/lib/gate_server/codec.ex.
//
// Phase 1b: Gate decodes and emits observe only. Clients should NOT actually
// send VoxelEditIntent in 1b — there is no result message coming back.
// Encoders are exposed so test fixtures and observability tooling can build
// well-formed payloads, and so the wire form is locked under test before
// 1c wires this opcode into UI code paths.

import { VoxelOpcode } from "./opcodes";

export const VoxelEditAction = {
  Place: 0,
  Break: 1,
  Damage: 2,
  Replace: 3,
  AttributePatch: 4,
} as const;

export type VoxelEditActionValue = (typeof VoxelEditAction)[keyof typeof VoxelEditAction];

export const VoxelEditTargetGranularity = {
  Macro: 0,
  Micro: 1,
  ObjectPart: 2,
} as const;

export type VoxelEditTargetGranularityValue =
  (typeof VoxelEditTargetGranularity)[keyof typeof VoxelEditTargetGranularity];

/** Sentinel marking "no constraint" for `expected_chunk_version` (max u64). */
export const EXPECTED_CHUNK_VERSION_UNSPECIFIED = 0xffff_ffff_ffff_ffffn;

/** Sentinel marking "no constraint" for `expected_cell_hash` (max u32). */
export const EXPECTED_CELL_HASH_UNSPECIFIED = 0xffff_ffff;

export interface VoxelEditIntentInput {
  requestId: bigint;
  clientIntentSeq: number;
  logicalSceneId: bigint;
  action: number;
  targetGranularity: number;
  targetWorldMicro: { x: bigint; y: bigint; z: bigint };
  faceNormal: { x: number; y: number; z: number };
  materialId: number;
  blueprintRef: number;
  objectRef: bigint;
  partRef: number;
  attributePatchRef: number;
  expectedChunkVersion: bigint;
  expectedCellHash: number;
  clientHintHash: bigint;
}

/** Fixed payload size (without the 1-byte opcode prefix). */
export const VOXEL_EDIT_INTENT_PAYLOAD_BYTES = 91;
/** Total wire size including opcode. */
export const VOXEL_EDIT_INTENT_WIRE_BYTES = 1 + VOXEL_EDIT_INTENT_PAYLOAD_BYTES;

/**
 * Encodes a VoxelEditIntent message (opcode + 91-byte fixed payload).
 * All fields must be in range; out-of-range values throw RangeError.
 */
export function encodeVoxelEditIntent(input: VoxelEditIntentInput): Uint8Array {
  const buffer = new ArrayBuffer(VOXEL_EDIT_INTENT_WIRE_BYTES);
  const view = new DataView(buffer);

  let offset = 0;

  view.setUint8(offset, VoxelOpcode.VoxelEditIntent);
  offset += 1;

  setU64(view, offset, input.requestId, "request_id");
  offset += 8;
  setU32(view, offset, input.clientIntentSeq, "client_intent_seq");
  offset += 4;
  setU64(view, offset, input.logicalSceneId, "logical_scene_id");
  offset += 8;

  setU8(view, offset, input.action, "action");
  offset += 1;
  setU8(view, offset, input.targetGranularity, "target_granularity");
  offset += 1;

  setI64(view, offset, input.targetWorldMicro.x, "target_world_micro.x");
  offset += 8;
  setI64(view, offset, input.targetWorldMicro.y, "target_world_micro.y");
  offset += 8;
  setI64(view, offset, input.targetWorldMicro.z, "target_world_micro.z");
  offset += 8;

  setI8(view, offset, input.faceNormal.x, "face_normal.x");
  offset += 1;
  setI8(view, offset, input.faceNormal.y, "face_normal.y");
  offset += 1;
  setI8(view, offset, input.faceNormal.z, "face_normal.z");
  offset += 1;

  setU16(view, offset, input.materialId, "material_id");
  offset += 2;
  setU32(view, offset, input.blueprintRef, "blueprint_ref");
  offset += 4;
  setU64(view, offset, input.objectRef, "object_ref");
  offset += 8;
  setU32(view, offset, input.partRef, "part_ref");
  offset += 4;
  setU32(view, offset, input.attributePatchRef, "attribute_patch_ref");
  offset += 4;
  setU64(view, offset, input.expectedChunkVersion, "expected_chunk_version");
  offset += 8;
  setU32(view, offset, input.expectedCellHash, "expected_cell_hash");
  offset += 4;
  setU64(view, offset, input.clientHintHash, "client_hint_hash");
  offset += 8;

  if (offset !== VOXEL_EDIT_INTENT_WIRE_BYTES) {
    throw new Error(
      `voxel_edit_intent_wire_size_mismatch:${offset}_vs_${VOXEL_EDIT_INTENT_WIRE_BYTES}`,
    );
  }

  return new Uint8Array(buffer);
}

function setU8(view: DataView, offset: number, value: number, field: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xff) {
    throw new RangeError(`voxel_edit_intent.${field}_out_of_u8:${value}`);
  }
  view.setUint8(offset, value);
}

function setI8(view: DataView, offset: number, value: number, field: string): void {
  if (!Number.isInteger(value) || value < -128 || value > 127) {
    throw new RangeError(`voxel_edit_intent.${field}_out_of_i8:${value}`);
  }
  view.setInt8(offset, value);
}

function setU16(view: DataView, offset: number, value: number, field: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
    throw new RangeError(`voxel_edit_intent.${field}_out_of_u16:${value}`);
  }
  view.setUint16(offset, value, false);
}

function setU32(view: DataView, offset: number, value: number, field: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff_ffff) {
    throw new RangeError(`voxel_edit_intent.${field}_out_of_u32:${value}`);
  }
  view.setUint32(offset, value, false);
}

function setU64(view: DataView, offset: number, value: bigint, field: string): void {
  if (typeof value !== "bigint" || value < 0n || value > 0xffff_ffff_ffff_ffffn) {
    throw new RangeError(`voxel_edit_intent.${field}_out_of_u64:${value}`);
  }
  view.setBigUint64(offset, value, false);
}

function setI64(view: DataView, offset: number, value: bigint, field: string): void {
  if (
    typeof value !== "bigint" ||
    value < -0x8000_0000_0000_0000n ||
    value > 0x7fff_ffff_ffff_ffffn
  ) {
    throw new RangeError(`voxel_edit_intent.${field}_out_of_i64:${value}`);
  }
  view.setBigInt64(offset, value, false);
}
