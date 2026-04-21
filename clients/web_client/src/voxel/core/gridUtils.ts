// 与 UE test1 VoxelGridUtils 字节级一致的坐标换算。
// 核心目标：在负象限保持 DivideFloor 与 PositiveModulo 的一致语义。

import { VoxelConstants } from "./constants";
import type { FChunkCoord, FMacroCoord, FMicroCoord } from "./types";

export function divideFloor(value: number, divisor: number): number {
  if (divisor <= 0) {
    throw new Error(`divideFloor: divisor must be positive, got ${divisor}`);
  }
  if (value >= 0) {
    return Math.floor(value / divisor);
  }
  return -Math.floor(((-value) + divisor - 1) / divisor);
}

export function positiveModulo(value: number, divisor: number): number {
  if (divisor <= 0) {
    throw new Error(`positiveModulo: divisor must be positive, got ${divisor}`);
  }
  const r = value % divisor;
  return r < 0 ? r + divisor : r;
}

export function chunkCoordFromMacro(mc: FMacroCoord): FChunkCoord {
  return {
    x: divideFloor(mc.x, VoxelConstants.ChunkSizeX),
    y: divideFloor(mc.y, VoxelConstants.ChunkSizeY),
    z: divideFloor(mc.z, VoxelConstants.ChunkSizeZ),
  };
}

export function localMacroInChunk(mc: FMacroCoord): FMacroCoord {
  return {
    x: positiveModulo(mc.x, VoxelConstants.ChunkSizeX),
    y: positiveModulo(mc.y, VoxelConstants.ChunkSizeY),
    z: positiveModulo(mc.z, VoxelConstants.ChunkSizeZ),
  };
}

export function macroLinearIndex(local: FMacroCoord): number {
  const { ChunkSizeX, ChunkSizeY, ChunkSizeZ } = VoxelConstants;
  if (
    local.x < 0 || local.x >= ChunkSizeX ||
    local.y < 0 || local.y >= ChunkSizeY ||
    local.z < 0 || local.z >= ChunkSizeZ
  ) {
    return -1;
  }
  return local.x + local.y * ChunkSizeX + local.z * ChunkSizeX * ChunkSizeY;
}

export function macroCoordFromLinearIndex(index: number): FMacroCoord {
  const { ChunkSizeX, ChunkSizeY } = VoxelConstants;
  const z = Math.floor(index / (ChunkSizeX * ChunkSizeY));
  const rem = index - z * ChunkSizeX * ChunkSizeY;
  const y = Math.floor(rem / ChunkSizeX);
  const x = rem - y * ChunkSizeX;
  return { x, y, z };
}

export function microCoordFromMacro(mc: FMacroCoord): FMicroCoord {
  const n = VoxelConstants.MicroPerMacro;
  return { x: mc.x * n, y: mc.y * n, z: mc.z * n };
}

export function macroCoordFromMicro(mc: FMicroCoord): FMacroCoord {
  const n = VoxelConstants.MicroPerMacro;
  return {
    x: divideFloor(mc.x, n),
    y: divideFloor(mc.y, n),
    z: divideFloor(mc.z, n),
  };
}
