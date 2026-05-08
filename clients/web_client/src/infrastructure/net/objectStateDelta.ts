// Server-authoritative ObjectStateDelta wire decoder (Phase 4).
//
// Mirrors `apps/gate_server/lib/gate_server/codec.ex` payload layout for
// opcode 0x6C (without the leading opcode byte):
//
//   logical_scene_id     u64-be
//   object_id            u64-be
//   object_version       u64-be
//   state_flags          u32-be
//   attribute_patch_count u16-be   (Phase 4 always 0)
//   tag_patch_count       u16-be   (Phase 4 always 0)
//   affected_chunk_count  u16-be
//   affected_chunks[]    { i32-be x, i32-be y, i32-be z }
//
// Phase 4 only decodes + console.logs the message. Phase 5+ will introduce
// visual UI consumers (object damage indicators, destruction effects). The
// decoder is intentionally permissive about `attribute_patch_count` /
// `tag_patch_count` non-zero values for forwards compatibility — those
// bytes are skipped after the count is read.

export interface ChunkCoord {
  x: number;
  y: number;
  z: number;
}

export interface ObjectStateDelta {
  logicalSceneId: bigint;
  objectId: bigint;
  objectVersion: bigint;
  stateFlags: number;
  attributePatchCount: number;
  tagPatchCount: number;
  affectedChunks: ChunkCoord[];
}

const HEADER_BYTES = 8 + 8 + 8 + 4 + 2 + 2 + 2;
const CHUNK_COORD_BYTES = 12;

export function decodeObjectStateDelta(payload: Uint8Array): ObjectStateDelta {
  if (payload.byteLength < HEADER_BYTES) {
    throw new RangeError(
      `objectStateDelta: truncated header (got ${payload.byteLength} bytes, need >= ${HEADER_BYTES})`,
    );
  }

  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  let offset = 0;

  const logicalSceneId = view.getBigUint64(offset, false);
  offset += 8;
  const objectId = view.getBigUint64(offset, false);
  offset += 8;
  const objectVersion = view.getBigUint64(offset, false);
  offset += 8;
  const stateFlags = view.getUint32(offset, false);
  offset += 4;
  const attributePatchCount = view.getUint16(offset, false);
  offset += 2;
  const tagPatchCount = view.getUint16(offset, false);
  offset += 2;
  const affectedChunkCount = view.getUint16(offset, false);
  offset += 2;

  const expectedRemaining = affectedChunkCount * CHUNK_COORD_BYTES;
  if (payload.byteLength - offset < expectedRemaining) {
    throw new RangeError(
      `objectStateDelta: truncated affected_chunks (need ${expectedRemaining} more bytes, got ${
        payload.byteLength - offset
      })`,
    );
  }

  const affectedChunks: ChunkCoord[] = [];

  for (let i = 0; i < affectedChunkCount; i++) {
    const x = view.getInt32(offset, false);
    offset += 4;
    const y = view.getInt32(offset, false);
    offset += 4;
    const z = view.getInt32(offset, false);
    offset += 4;
    affectedChunks.push({ x, y, z });
  }

  return {
    logicalSceneId,
    objectId,
    objectVersion,
    stateFlags,
    attributePatchCount,
    tagPatchCount,
    affectedChunks,
  };
}

// Phase 4 stub consumer: log the decoded message so manual QA can spot
// damage / destruction events in DevTools. Phase 5+ replaces this with
// real UI hooks (object health bars, destruction VFX).
export function logObjectStateDelta(delta: ObjectStateDelta): void {
  // eslint-disable-next-line no-console
  console.log("[voxel] ObjectStateDelta", {
    logicalSceneId: delta.logicalSceneId.toString(),
    objectId: delta.objectId.toString(),
    objectVersion: delta.objectVersion.toString(),
    stateFlags: `0x${delta.stateFlags.toString(16)}`,
    affectedChunkCount: delta.affectedChunks.length,
    affectedChunks: delta.affectedChunks,
  });
}
