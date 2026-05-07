// 与 docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md 保持一致。
// 所有多字节字段统一 big-endian / network byte order，帧层使用 {packet, 4} 长度前缀。

export const VoxelOpcode = {
  ChunkSubscribe: 0x60,
  ChunkUnsubscribe: 0x61,
  ChunkSnapshot: 0x62,
  ChunkDelta: 0x63,
  VoxelImpactIntent: 0x64,
  BuildReservationIntent: 0x65,
  BlueprintCreate: 0x66,
  PrefabPlaceIntent: 0x67,
  VoxelIntentResult: 0x68,
  ChunkInvalidate: 0x69,
  ParcelQuery: 0x6a,
  ObjectAction: 0x6b,
  ObjectStateDelta: 0x6c,
  TagCatalogSnapshot: 0x6d,
  AttributeCatalogSnapshot: 0x6e,
  VoxelDebugProbe: 0x6f,
  VoxelEditIntent: 0x70,
} as const;

export type VoxelOpcodeValue = (typeof VoxelOpcode)[keyof typeof VoxelOpcode];

export const VoxelIntentResult = {
  Accepted: 0,
  Deferred: 1,
  Rejected: 2,
  Stale: 3,
} as const;

export type VoxelIntentResultValue = (typeof VoxelIntentResult)[keyof typeof VoxelIntentResult];
