// 方块世界首版固定量化参数，与 UE test1 的 VoxelConstants 保持字节级一致。
// 修改任何一个值之前必须同步 UE 端 Voxel/Core/VoxelTypes.h 中的 VoxelConstants。
export const VoxelConstants = {
  MicroPerMacro: 4,
  ChunkSizeX: 16,
  ChunkSizeY: 16,
  ChunkSizeZ: 16,
  MacroCountPerChunk: 16 * 16 * 16,
  MicroCountPerMacro: 4 * 4 * 4,
  ChunkSizeInMacros: 16,
} as const;

// UE 默认 MacroWorldSize = 100 cm（1m 立方宏格）；此值只影响渲染尺度，不影响量化。
export const MacroWorldSize = 100.0;
