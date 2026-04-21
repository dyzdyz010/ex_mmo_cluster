// UE test1 Voxel/Core/VoxelTypes.h 的 TypeScript 镜像。
// 坐标使用 int32 语义（允许负象限）；byte layout 在 codec 层负责。

export interface FChunkCoord {
  x: number;
  y: number;
  z: number;
}

export interface FMacroCoord {
  x: number;
  y: number;
  z: number;
}

export interface FMicroCoord {
  x: number;
  y: number;
  z: number;
}

export enum EVoxelCellMode {
  Empty = 0,
  SolidBlock = 1,
  Refined = 2,
}

export enum EVoxelBlockStateFlags {
  None = 0,
  Burning = 1 << 0,
  Frozen = 1 << 1,
  Wet = 1 << 2,
  Charred = 1 << 3,
  Damaged = 1 << 4,
  MeltPending = 1 << 5,
}

export enum EVoxelRotation {
  Rot0 = 0,
  Rot90 = 1,
  Rot180 = 2,
  Rot270 = 3,
}

export function chunkCoordEquals(a: FChunkCoord, b: FChunkCoord): boolean {
  return a.x === b.x && a.y === b.y && a.z === b.z;
}

// 用作 Map<string, Chunk> 的 key；避免反复 JSON.stringify 开销。
export function chunkCoordKey(c: FChunkCoord): string {
  return `${c.x},${c.y},${c.z}`;
}

export function macroCoordEquals(a: FMacroCoord, b: FMacroCoord): boolean {
  return a.x === b.x && a.y === b.y && a.z === b.z;
}
