// Chunk 真相层在客户端的运行时镜像。
// 对应 UE test1 的 FChunkStorageData + UVoxelChunkStorageComponent 的常用写入路径。
// 不保证所有 UE 端函数都 1:1 覆盖，优先实现前端交互和渲染需要的子集。

import { VoxelConstants } from "../core/constants";
import {
  EVoxelCellMode,
  type FChunkCoord,
  type FMacroCoord,
  type FMicroCoord,
} from "../core/types";
import { macroLinearIndex } from "../core/gridUtils";
import {
  clearMicroBlock,
  FullMicroOccupancyMask,
  getMicroBlock,
  isMicroOccupied as isRefinedMicroOccupied,
  isRefinedCellEmpty,
  makeEmptyRefinedCell as makeEmptyRefinedMicroCell,
  makeRefinedCellFromBlock,
  makeSingleMicroRefinedCell,
  MicroGridSlotCount,
  normalizeRefinedCell,
  setMicroBlock,
} from "../microgrid/governance";
import {
  VoxelDirtyFlags,
  makeEmptyMacroHeader,
  makeEmptyNormalBlock,
  type FChunkStorageData,
  type FMacroEnvironmentSummary,
  type FMacroCellHeader,
  type FNormalBlockData,
  type FRefinedCellData,
  type FPrefabInstanceData,
} from "./types";
import type { FChunkMesherCellSnapshot, FChunkMesherInputSnapshot } from "../meshing/types";

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
    if (!header) {
      return null;
    }

    if (header.mode === EVoxelCellMode.SolidBlock) {
      const block = this.data.normalBlocks[header.payloadIndex];
      return block ?? null;
    }

    if (header.mode === EVoxelCellMode.Refined) {
      const refined = this.data.refinedCells[header.payloadIndex];
      return refined ? refinedFullMacroAsBlock(refined) : null;
    }

    return null;
  }

  getRefinedCell(localMacro: FMacroCoord): FRefinedCellData | null {
    const header = this.getHeaderAt(localMacro);
    if (!header || header.mode !== EVoxelCellMode.Refined) {
      return null;
    }

    const refined = this.data.refinedCells[header.payloadIndex];
    return refined ? normalizeRefinedCell(refined) : null;
  }

  getMicroBlock(localMacro: FMacroCoord, micro: FMicroCoord): FNormalBlockData | null {
    const header = this.getHeaderAt(localMacro);
    if (!header) {
      return null;
    }

    if (header.mode === EVoxelCellMode.SolidBlock) {
      return this.getNormalBlock(localMacro);
    }

    if (header.mode === EVoxelCellMode.Refined) {
      const refined = this.data.refinedCells[header.payloadIndex];
      return refined ? getMicroBlock(refined, micro) : null;
    }

    return null;
  }

  isMicroOccupied(localMacro: FMacroCoord, micro: FMicroCoord): boolean {
    const header = this.getHeaderAt(localMacro);
    if (!header) {
      return false;
    }

    if (header.mode === EVoxelCellMode.SolidBlock) {
      return this.getMicroBlock(localMacro, micro) !== null;
    }

    if (header.mode === EVoxelCellMode.Refined) {
      const refined = this.data.refinedCells[header.payloadIndex];
      return refined ? isRefinedMicroOccupied(refined, micro) : false;
    }

    return false;
  }

  getEnvironmentSummary(localMacro: FMacroCoord): FMacroEnvironmentSummary | null {
    const header = this.getHeaderAt(localMacro);
    if (!header || header.environmentIndex === 0xffff) {
      return null;
    }
    const summary = this.data.environmentSummaries[header.environmentIndex];
    return summary ?? null;
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

    this.markDirty(
      localMacro,
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
    return true;
  }

  setMicroBlock(localMacro: FMacroCoord, micro: FMicroCoord, block: FNormalBlockData): boolean {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return false;
    }
    const header = this.data.macroHeaders[idx];
    if (!header) {
      return false;
    }

    if (header.mode === EVoxelCellMode.Empty) {
      const refined = makeSingleMicroRefinedCell(micro, block);
      if (!refined) {
        return false;
      }
      header.payloadIndex = this.data.refinedCells.push(refined) - 1;
      header.mode = EVoxelCellMode.Refined;
    } else if (header.mode === EVoxelCellMode.SolidBlock) {
      const existingBlock = this.data.normalBlocks[header.payloadIndex];
      if (!existingBlock) {
        return false;
      }
      const refined = setMicroBlock(makeRefinedCellFromBlock(existingBlock), micro, block);
      if (!refined) {
        return false;
      }
      this.data.normalBlocks[header.payloadIndex] = makeEmptyNormalBlock();
      this.data.freeNormalBlockIndices.push(header.payloadIndex);
      header.payloadIndex = this.data.refinedCells.push(refined) - 1;
      header.mode = EVoxelCellMode.Refined;
    } else {
      const current = this.data.refinedCells[header.payloadIndex] ?? makeEmptyRefinedMicroCell();
      const refined = setMicroBlock(current, micro, block);
      if (!refined) {
        return false;
      }
      this.data.refinedCells[header.payloadIndex] = refined;
    }

    this.markDirty(
      localMacro,
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
    return true;
  }

  clearMicroBlock(localMacro: FMacroCoord, micro: FMicroCoord): boolean {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return false;
    }
    const header = this.data.macroHeaders[idx];
    if (!header || header.mode === EVoxelCellMode.Empty) {
      return false;
    }

    let refined: FRefinedCellData | null = null;
    if (header.mode === EVoxelCellMode.SolidBlock) {
      const block = this.data.normalBlocks[header.payloadIndex];
      if (!block) {
        return false;
      }
      refined = clearMicroBlock(makeRefinedCellFromBlock(block), micro);
      if (!refined) {
        return false;
      }
      this.data.normalBlocks[header.payloadIndex] = makeEmptyNormalBlock();
      this.data.freeNormalBlockIndices.push(header.payloadIndex);
      header.payloadIndex = this.data.refinedCells.push(refined) - 1;
      header.mode = EVoxelCellMode.Refined;
    } else {
      const current = this.data.refinedCells[header.payloadIndex];
      if (!current || !isRefinedMicroOccupied(current, micro)) {
        return false;
      }
      refined = clearMicroBlock(current, micro);
      if (!refined) {
        return false;
      }
      this.data.refinedCells[header.payloadIndex] = refined;
    }

    if (isRefinedCellEmpty(refined)) {
      this.data.refinedCells[header.payloadIndex] = makeEmptyRefinedMicroCell();
      header.mode = EVoxelCellMode.Empty;
      header.payloadIndex = 0;
      header.flags = 0;
    }

    this.markDirty(
      localMacro,
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
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
    if (header.mode === EVoxelCellMode.Refined) {
      this.data.refinedCells[header.payloadIndex] = makeEmptyRefinedCell();
    }

    header.mode = EVoxelCellMode.Empty;
    header.payloadIndex = 0;
    header.flags = 0;

    this.markDirty(
      localMacro,
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
    return true;
  }

  setMacroEnvironmentSummary(localMacro: FMacroCoord, summary: FMacroEnvironmentSummary): boolean {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return false;
    }
    const header = this.data.macroHeaders[idx];
    if (!header) {
      return false;
    }

    if (header.environmentIndex !== 0xffff) {
      this.data.environmentSummaries[header.environmentIndex] = { ...summary };
    } else {
      const reuseIndex = this.data.freeEnvironmentSummaryIndices.pop();
      if (reuseIndex !== undefined) {
        this.data.environmentSummaries[reuseIndex] = { ...summary };
        header.environmentIndex = reuseIndex;
      } else {
        header.environmentIndex = this.data.environmentSummaries.push({ ...summary }) - 1;
      }
    }

    this.markDirty(localMacro, VoxelDirtyFlags.Storage);
    return true;
  }

  setPrefabFullMacroBlock(
    localMacro: FMacroCoord,
    block: FNormalBlockData,
    instanceId: number,
  ): boolean {
    return this.setPrefabRefinedMicroCell(
      localMacro,
      FullMicroOccupancyMask,
      block.materialId,
      block.stateFlags,
      new Array(MicroGridSlotCount).fill(0),
      instanceId,
    );
  }

  setPrefabRefinedMicroCell(
    localMacro: FMacroCoord,
    microOccupancyMask: bigint,
    materialId: number,
    stateFlags: number,
    microPartIds: number[],
    instanceId: number,
  ): boolean {
    return this.unionPrefabRefinedMicroCell(
      localMacro,
      microOccupancyMask,
      new Array(MicroGridSlotCount).fill(materialId),
      new Array(MicroGridSlotCount).fill(stateFlags),
      microPartIds,
      instanceId,
    );
  }

  unionPrefabRefinedMicroCell(
    localMacro: FMacroCoord,
    microOccupancyMask: bigint,
    microMaterialIds: number[],
    microStateFlags: number[],
    microPartIds: number[],
    instanceId: number,
  ): boolean {
    const idx = macroLinearIndex(localMacro);
    if (idx < 0) {
      return false;
    }
    const header = this.data.macroHeaders[idx];
    if (!header) {
      return false;
    }

    if (header.mode === EVoxelCellMode.SolidBlock) {
      this.data.normalBlocks[header.payloadIndex] = makeEmptyNormalBlock();
      this.data.freeNormalBlockIndices.push(header.payloadIndex);
    }

    const refined = makePrefabRefinedCell(
      microOccupancyMask,
      microMaterialIds,
      microStateFlags,
      microPartIds,
      instanceId,
    );
    if (header.mode === EVoxelCellMode.Refined) {
      this.data.refinedCells[header.payloadIndex] = mergePrefabRefinedCell(
        this.data.refinedCells[header.payloadIndex] ?? makeEmptyRefinedCell(),
        refined,
      );
    } else {
      header.payloadIndex = this.data.refinedCells.push(refined) - 1;
      header.mode = EVoxelCellMode.Refined;
    }

    this.markDirty(
      localMacro,
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
    return true;
  }

  addPrefabInstance(instance: FPrefabInstanceData): FPrefabInstanceData {
    const stored = clonePrefabInstance(instance);
    this.data.prefabInstances.push(stored);
    this.markDirty(
      {
        x: clampLocalMacroX(
          instance.coveredMacroMin.x - this.data.chunkCoord.x * VoxelConstants.ChunkSizeX,
        ),
        y: clampLocalMacroY(
          instance.coveredMacroMin.y - this.data.chunkCoord.y * VoxelConstants.ChunkSizeY,
        ),
        z: clampLocalMacroZ(
          instance.coveredMacroMin.z - this.data.chunkCoord.z * VoxelConstants.ChunkSizeZ,
        ),
      },
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
    this.markDirty(
      {
        x: clampLocalMacroX(
          instance.coveredMacroMax.x - this.data.chunkCoord.x * VoxelConstants.ChunkSizeX,
        ),
        y: clampLocalMacroY(
          instance.coveredMacroMax.y - this.data.chunkCoord.y * VoxelConstants.ChunkSizeY,
        ),
        z: clampLocalMacroZ(
          instance.coveredMacroMax.z - this.data.chunkCoord.z * VoxelConstants.ChunkSizeZ,
        ),
      },
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
    );
    return stored;
  }

  buildMesherSnapshot(): FChunkMesherInputSnapshot {
    const cells: FChunkMesherCellSnapshot[] = [];

    for (let index = 0; index < this.data.macroHeaders.length; index += 1) {
      const header = this.data.macroHeaders[index];
      if (!header) {
        continue;
      }

      const localMacroCoord = {
        x: index % VoxelConstants.ChunkSizeX,
        y: Math.floor(index / VoxelConstants.ChunkSizeX) % VoxelConstants.ChunkSizeY,
        z: Math.floor(index / (VoxelConstants.ChunkSizeX * VoxelConstants.ChunkSizeY)),
      };

      let materialId = 0;
      let stateFlags = 0;
      let health = 0;
      let microOccupancyMask: bigint | undefined;
      let microMaterialIds: number[] | undefined;
      let microStateFlags: number[] | undefined;
      if (header.mode === EVoxelCellMode.SolidBlock || header.mode === EVoxelCellMode.Refined) {
        const block = this.getNormalBlock(localMacroCoord);
        if (block) {
          materialId = block.materialId;
          stateFlags = block.stateFlags;
          health = block.health;
        }
        if (header.mode === EVoxelCellMode.Refined) {
          const refined = this.data.refinedCells[header.payloadIndex];
          if (refined) {
            microOccupancyMask = refined.microOccupancyMask;
            microMaterialIds = [...refined.microMaterialIds];
            microStateFlags = [...refined.microStateFlags];
          }
        }
      }

      const cell: FChunkMesherCellSnapshot = {
        localMacroCoord,
        mode: header.mode,
        materialId,
        stateFlags,
        health,
      };
      if (microOccupancyMask !== undefined) {
        cell.microOccupancyMask = microOccupancyMask;
      }
      if (microMaterialIds !== undefined) {
        cell.microMaterialIds = microMaterialIds;
      }
      if (microStateFlags !== undefined) {
        cell.microStateFlags = microStateFlags;
      }
      cells.push(cell);
    }

    return {
      chunkCoord: { ...this.data.chunkCoord },
      dirtyMacroMin: { ...this.data.dirtyMacroMin },
      dirtyMacroMax: { ...this.data.dirtyMacroMax },
      dirtyFlags: this.data.dirtyFlags,
      cells,
    };
  }

  countSolidBlocks(): number {
    let count = 0;
    for (const header of this.data.macroHeaders) {
      if (header?.mode === EVoxelCellMode.SolidBlock || header?.mode === EVoxelCellMode.Refined) {
        count += 1;
      }
    }
    return count;
  }

  countStateFlag(flag: number): number {
    let count = 0;
    for (let index = 0; index < this.data.macroHeaders.length; index += 1) {
      const header = this.data.macroHeaders[index];
      if (
        !header ||
        (header.mode !== EVoxelCellMode.SolidBlock && header.mode !== EVoxelCellMode.Refined)
      ) {
        continue;
      }
      const localMacroCoord = {
        x: index % VoxelConstants.ChunkSizeX,
        y: Math.floor(index / VoxelConstants.ChunkSizeX) % VoxelConstants.ChunkSizeY,
        z: Math.floor(index / (VoxelConstants.ChunkSizeX * VoxelConstants.ChunkSizeY)),
      };
      const block = this.getNormalBlock({
        x: localMacroCoord.x,
        y: localMacroCoord.y,
        z: localMacroCoord.z,
      });
      if (block && (block.stateFlags & flag) !== 0) {
        count += 1;
      }
    }
    return count;
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

  consumeDirtyFlags(
    mask: number = VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision,
  ): number {
    const current = this.data.dirtyFlags;
    this.data.dirtyFlags &= ~mask;
    if (this.data.dirtyFlags === 0) {
      this.data.dirtyMacroMin = { x: 0, y: 0, z: 0 };
      this.data.dirtyMacroMax = { x: 0, y: 0, z: 0 };
    }
    return current & mask;
  }
}

function makeEmptyRefinedCell(): FRefinedCellData {
  return makeEmptyRefinedMicroCell();
}

function makePrefabRefinedCell(
  microOccupancyMask: bigint,
  microMaterialIds: number[],
  microStateFlags: number[],
  microPartIds: number[],
  instanceId: number,
): FRefinedCellData {
  return normalizeRefinedCell({
    microOccupancyMask,
    microMaterialIds: normalizeNumberSlots(microMaterialIds, 0),
    microStateFlags: normalizeNumberSlots(microStateFlags, 0),
    microPartIds: normalizedPartIds(microPartIds),
    prefabInstanceIds: [instanceId],
    boundaryCache: 0,
  });
}

function mergePrefabRefinedCell(
  existing: FRefinedCellData,
  next: FRefinedCellData,
): FRefinedCellData {
  const out = normalizeRefinedCell(existing);
  const incoming = normalizeRefinedCell(next);
  out.microOccupancyMask |= incoming.microOccupancyMask;

  for (let index = 0; index < MicroGridSlotCount; index += 1) {
    const bit = 1n << BigInt(index);
    if ((incoming.microOccupancyMask & bit) === 0n) {
      continue;
    }
    out.microMaterialIds[index] = incoming.microMaterialIds[index] ?? 0;
    out.microStateFlags[index] = incoming.microStateFlags[index] ?? 0;
    out.microPartIds[index] = incoming.microPartIds[index] ?? -1;
  }

  out.prefabInstanceIds = [
    ...new Set([...out.prefabInstanceIds, ...incoming.prefabInstanceIds]),
  ].sort((a, b) => a - b);
  out.boundaryCache = 0;
  return out;
}

function normalizedPartIds(partIds: number[]): number[] {
  const out = new Array(MicroGridSlotCount).fill(-1);
  for (let index = 0; index < Math.min(partIds.length, MicroGridSlotCount); index += 1) {
    out[index] = partIds[index] ?? -1;
  }
  return out;
}

function normalizeNumberSlots(values: number[], fallback: number): number[] {
  const out = new Array(MicroGridSlotCount).fill(fallback);
  for (let index = 0; index < Math.min(values.length, MicroGridSlotCount); index += 1) {
    out[index] = values[index] ?? fallback;
  }
  return out;
}

function refinedFullMacroAsBlock(refined: FRefinedCellData): FNormalBlockData | null {
  if (refined.microOccupancyMask === 0n || refined.microMaterialIds.length === 0) {
    return null;
  }
  const normalized = normalizeRefinedCell(refined);
  const firstOccupiedIndex = firstOccupiedSlotIndex(normalized.microOccupancyMask);
  if (firstOccupiedIndex === -1) {
    return null;
  }

  return {
    materialId: normalized.microMaterialIds[firstOccupiedIndex] ?? 0,
    stateFlags: normalized.microStateFlags.reduce((acc, value) => acc | value, 0),
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

function firstOccupiedSlotIndex(mask: bigint): number {
  for (let index = 0; index < MicroGridSlotCount; index += 1) {
    if ((mask & (1n << BigInt(index))) !== 0n) {
      return index;
    }
  }
  return -1;
}

function clonePrefabInstance(instance: FPrefabInstanceData): FPrefabInstanceData {
  return {
    instanceId: instance.instanceId,
    prefabId: instance.prefabId,
    anchorMicroCoord: { ...instance.anchorMicroCoord },
    rotation: instance.rotation,
    ownerChunk: { ...instance.ownerChunk },
    coveredMacroMin: { ...instance.coveredMacroMin },
    coveredMacroMax: { ...instance.coveredMacroMax },
    overrideSetIndex: instance.overrideSetIndex,
  };
}

function clampLocalMacroX(value: number): number {
  return Math.max(0, Math.min(VoxelConstants.ChunkSizeX - 1, value));
}

function clampLocalMacroY(value: number): number {
  return Math.max(0, Math.min(VoxelConstants.ChunkSizeY - 1, value));
}

function clampLocalMacroZ(value: number): number {
  return Math.max(0, Math.min(VoxelConstants.ChunkSizeZ - 1, value));
}
