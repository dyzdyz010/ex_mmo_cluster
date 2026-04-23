// UE test1 Voxel/Meshing/VoxelMeshingTypes.h 的 TypeScript 镜像。
// Mesher 输入快照刻意与真相层解耦，后续走 Web Worker 时可直接结构化克隆。

import { EVoxelCellMode, type FChunkCoord, type FMacroCoord } from "../core/types";
import { VoxelDirtyFlags } from "../storage/types";

export interface FChunkMesherCellSnapshot {
  localMacroCoord: FMacroCoord;
  mode: EVoxelCellMode;
  materialId: number;
  stateFlags: number;
  health: number;
  microOccupancyMask?: bigint;
  microMaterialIds?: number[];
  microStateFlags?: number[];
}

export interface FChunkMesherInputSnapshot {
  chunkCoord: FChunkCoord;
  dirtyMacroMin: FMacroCoord;
  dirtyMacroMax: FMacroCoord;
  dirtyFlags: number;
  cells: FChunkMesherCellSnapshot[];
}

export function isSolidBlock(cell: FChunkMesherCellSnapshot): boolean {
  if (cell.mode === EVoxelCellMode.Refined) {
    return (cell.microOccupancyMask ?? 0n) !== 0n;
  }
  return cell.mode === EVoxelCellMode.SolidBlock && cell.materialId !== 0;
}

export function hasDirtyMesh(snapshot: FChunkMesherInputSnapshot): boolean {
  return (snapshot.dirtyFlags & VoxelDirtyFlags.Mesh) !== 0;
}
