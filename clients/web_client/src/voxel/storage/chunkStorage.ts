// Chunk 真相层在客户端的运行时镜像。
// 对应 UE test1 的 FChunkStorageData + UVoxelChunkStorageComponent 的常用写入路径。
// 不保证所有 UE 端函数都 1:1 覆盖，优先实现前端交互和渲染需要的子集。

import { VoxelConstants } from "../core/constants";
import { EVoxelCellMode, type FChunkCoord, type FMacroCoord } from "../core/types";
import { macroLinearIndex } from "../core/gridUtils";
import {
  VoxelDirtyFlags,
  makeEmptyMacroHeader,
  makeEmptyNormalBlock,
  type FChunkStorageData,
  type FMacroCellHeader,
  type FNormalBlockData,
} from "./types";

export class ChunkStorage {
  readonly data: FChunkStorageData;

  private constructor(data: FChunkStorageData) {
    this.data = data;
  }

  static createEmpty(coord: FChunkCoord): ChunkStorage {
    const headers: FMacroCellHeader[] = new Array(VoxelConstants.MacroCountPerChunk);
    for (let i = 0; i < headers.length; i++) {
      headers[i] = makeEmptyMacroHeader();
    }
    const data: FChunkStorageData = {
      chunkCoord: { ...coord },
      macroHeaders: headers,
      normalBlocks: [],
      refinedCells: [],
      prefabInstances: [],
      environmentSummaries: [],
      freeNormalBlockIndices: [],
      freeEnvironmentSummaryIndices: [],
      dirtyMacroMin: { x: 0, y: 0, z: 0 },
      dirtyMacroMax: { x: 0, y: 0, z: 0 },
      dirtyFlags: 0,
    };
    return new ChunkStorage(data);
  }

  getHeaderAt(localMacro: FMacroCoord): FMacroCellHeader | null {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return null;
    }
    const header = this.data.macroHeaders[idx];
    return header ?? null;
  }

  getNormalBlock(localMacro: FMacroCoord): FNormalBlockData | null {
    const header = this.getHeaderAt(localMacro);
    if (!header || header.mode !== EVoxelCellMode.SolidBlock) {
      return null;
    }
    const block = this.data.normalBlocks[header.payloadIndex];
    return block ?? null;
  }

  // 向宏格写入一个普通块。复用 FreeNormalBlockIndices 栈，避免 normalBlocks 无限增长。
  trySetNormalBlock(localMacro: FMacroCoord, block: FNormalBlockData): boolean {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return false;
    }
    const header = this.data.macroHeaders[idx];
    if (!header) {
      return false;
    }

    if (header.mode === EVoxelCellMode.SolidBlock) {
      this.data.normalBlocks[header.payloadIndex] = { ...block };
    } else {
      const reuseIndex = this.data.freeNormalBlockIndices.pop();
      if (reuseIndex !== undefined) {
        this.data.normalBlocks[reuseIndex] = { ...block };
        header.payloadIndex = reuseIndex;
      } else {
        header.payloadIndex = this.data.normalBlocks.push({ ...block }) - 1;
      }
      header.mode = EVoxelCellMode.SolidBlock;
    }

    this.markDirty(localMacro, VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision);
    return true;
  }

  clearCell(localMacro: FMacroCoord): boolean {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return false;
    }
    const header = this.data.macroHeaders[idx];
    if (!header || header.mode === EVoxelCellMode.Empty) {
      return false;
    }

    if (header.mode === EVoxelCellMode.SolidBlock) {
      this.data.normalBlocks[header.payloadIndex] = makeEmptyNormalBlock();
      this.data.freeNormalBlockIndices.push(header.payloadIndex);
    }

    header.mode = EVoxelCellMode.Empty;
    header.payloadIndex = 0;
    header.flags = 0;

    this.markDirty(localMacro, VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision);
    return true;
  }

  private markDirty(localMacro: FMacroCoord, flags: number): void {
    const had = this.data.dirtyFlags !== 0;
    if (!had) {
      this.data.dirtyMacroMin = { ...localMacro };
      this.data.dirtyMacroMax = { ...localMacro };
    } else {
      const min = this.data.dirtyMacroMin;
      const max = this.data.dirtyMacroMax;
      if (localMacro.x < min.x) min.x = localMacro.x;
      if (localMacro.y < min.y) min.y = localMacro.y;
      if (localMacro.z < min.z) min.z = localMacro.z;
      if (localMacro.x > max.x) max.x = localMacro.x;
      if (localMacro.y > max.y) max.y = localMacro.y;
      if (localMacro.z > max.z) max.z = localMacro.z;
    }
    this.data.dirtyFlags |= flags;
  }

  clearDirty(): void {
    this.data.dirtyFlags = 0;
  }
}
