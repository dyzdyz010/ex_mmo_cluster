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

// 角色尺寸常量（cm 世界单位）。1.7m 全高、0.5m 厚度。详见 phase-A2 决策稿 D2。
// authorityAvatar / debrisRenderer / 相机 LOOK_HEIGHT 都从这里推导，避免 magic number。
export const AvatarConstants = {
  HeightCm: 170,
  HalfHeightCm: 85,
  WidthCm: 50,
  CapsuleRadiusCm: 30,
} as const;
