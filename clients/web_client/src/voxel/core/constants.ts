// 方块世界客户端本地量化参数。服务端/UE 同步接入 refined payload 前必须做协议协商，
// 不要再假设 prefab/refined micro payload 只有 64 槽。
export const VoxelConstants = {
  MicroPerMacro: 8,
  ChunkSizeX: 16,
  ChunkSizeY: 16,
  ChunkSizeZ: 16,
  MacroCountPerChunk: 16 * 16 * 16,
  MicroCountPerMacro: 8 * 8 * 8,
  ChunkSizeInMacros: 16,
} as const;

// UE 默认 MacroWorldSize = 100 cm（1m 立方宏格）；此值只影响渲染尺度，不影响量化。
export const MacroWorldSize = 100.0;
