// 与 docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md 保持一致。
// 所有多字节字段统一 big-endian / network byte order，帧层使用 {packet, 4} 长度前缀。

export const VoxelOpcode = {
  ChunkSubscribe: 0x60,
  ChunkUnsubscribe: 0x61,
  ChunkSnapshot: 0x62,
  ChunkDelta: 0x63,
  BlockBreak: 0x64,
  BlockPlace: 0x65,
  PrefabCreate: 0x66,
  PrefabPlace: 0x67,
  EditAck: 0x68,
  ChunkInvalidate: 0x69,
} as const;

export type VoxelOpcodeValue = (typeof VoxelOpcode)[keyof typeof VoxelOpcode];

export const EditAckResult = {
  Applied: 0,
  Conflict: 1,
  Rejected: 2,
} as const;

export type EditAckResultValue = (typeof EditAckResult)[keyof typeof EditAckResult];
