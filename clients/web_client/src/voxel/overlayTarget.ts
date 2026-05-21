import { VoxelConstants } from "./core/constants";
import { macroCoordFromLinearIndex } from "./core/gridUtils";
import { EVoxelCellMode, type FMacroCoord, type FMicroCoord } from "./core/types";
import { MicroGridSlotCount, normalizeRefinedCell } from "./microgrid/governance";
import { MICRO_SLOT_BITS, microLinearIndex } from "./prefab/math";
import type { PrefabRasterCell } from "./prefab";
import type { WorldStore } from "./worldStore";
import type { FRefinedCellData } from "./storage/types";

export type VoxelOverlayGranularity = "macro" | "micro" | "prefab";

export interface VoxelOverlayProjection {
  granularity: VoxelOverlayGranularity;
  key: string;
  label: string;
  macro: FMacroCoord;
  cells: PrefabRasterCell[];
  selectedMicro?: FMicroCoord;
  ownerObjectId?: string;
  prefabInstanceId?: number;
}

export interface MicroTargetLike {
  macro: FMacroCoord;
  micro: FMicroCoord;
}

export function resolveSelectionOverlayProjection(
  world: WorldStore,
  target: MicroTargetLike | null | undefined,
  fallbackMacro: FMacroCoord,
): VoxelOverlayProjection {
  if (!target) {
    return macroProjection(fallbackMacro);
  }

  const refined = world.getRefinedCellWorld(target.macro);
  if (!refined) {
    return macroProjection(fallbackMacro);
  }

  const normalized = normalizeRefinedCell(refined);
  const index = microLinearIndex(target.micro);
  const bit = MICRO_SLOT_BITS[index] ?? 0n;
  if (bit === 0n || (normalized.microOccupancyMask & bit) === 0n) {
    return macroProjection(fallbackMacro);
  }

  const ownerObjectId = ownerObjectIdAt(normalized, index);
  if (ownerObjectId !== null) {
    const cells = collectOwnerObjectCells(world, ownerObjectId);
    if (cells.length > 0) {
      return {
        granularity: "prefab",
        key: `owner:${ownerObjectId.toString()}`,
        label: `object ${ownerObjectId.toString()}`,
        macro: { ...target.macro },
        selectedMicro: { ...target.micro },
        cells,
        ownerObjectId: ownerObjectId.toString(),
      };
    }
  }

  const instanceId = normalized.prefabInstanceIds[0];
  if (instanceId !== undefined) {
    const instance = world.findPrefabInstance(instanceId);
    const cells = instance
      ? collectPrefabInstanceCells(
          world,
          instanceId,
          instance.coveredMacroMin,
          instance.coveredMacroMax,
        )
      : [];
    if (cells.length > 0) {
      return {
        granularity: "prefab",
        key: `prefab:${instanceId}`,
        label: `prefab ${instanceId}`,
        macro: { ...target.macro },
        selectedMicro: { ...target.micro },
        cells,
        prefabInstanceId: instanceId,
      };
    }
  }

  return macroProjection(fallbackMacro);
}

export function resolveFieldOverlayProjection(
  world: WorldStore,
  macro: FMacroCoord,
): VoxelOverlayProjection {
  const refined = world.getRefinedCellWorld(macro);
  if (!refined) {
    return macroProjection(macro);
  }

  const normalized = normalizeRefinedCell(refined);
  if (normalized.microOccupancyMask === 0n) {
    return macroProjection(macro);
  }

  const ownerObjectId = firstOwnerObjectId(normalized);
  if (ownerObjectId !== null) {
    const cells = collectOwnerObjectCells(world, ownerObjectId);
    if (cells.length > 0) {
      return {
        granularity: "prefab",
        key: `owner:${ownerObjectId.toString()}`,
        label: `object ${ownerObjectId.toString()}`,
        macro: { ...macro },
        cells,
        ownerObjectId: ownerObjectId.toString(),
      };
    }
  }

  const instanceId = normalized.prefabInstanceIds[0];
  if (instanceId !== undefined) {
    const instance = world.findPrefabInstance(instanceId);
    const cells = instance
      ? collectPrefabInstanceCells(
          world,
          instanceId,
          instance.coveredMacroMin,
          instance.coveredMacroMax,
        )
      : [];
    if (cells.length > 0) {
      return {
        granularity: "prefab",
        key: `prefab:${instanceId}`,
        label: `prefab ${instanceId}`,
        macro: { ...macro },
        cells,
        prefabInstanceId: instanceId,
      };
    }
  }

  return {
    granularity: "micro",
    key: `refined:${coordKey(macro)}`,
    label: `refined ${coordKey(macro)}`,
    macro: { ...macro },
    cells: [rasterCellForMask(macro, normalized.microOccupancyMask, normalized)],
  };
}

export function macroProjection(macro: FMacroCoord): VoxelOverlayProjection {
  return {
    granularity: "macro",
    key: `macro:${coordKey(macro)}`,
    label: `macro ${coordKey(macro)}`,
    macro: { ...macro },
    cells: [],
  };
}

function collectOwnerObjectCells(world: WorldStore, ownerObjectId: bigint): PrefabRasterCell[] {
  const cells: PrefabRasterCell[] = [];
  for (const chunk of world.listChunks()) {
    for (const [index, header] of chunk.data.macroHeaders.entries()) {
      if (header.mode !== EVoxelCellMode.Refined) {
        continue;
      }
      const refined = chunk.data.refinedCells[header.payloadIndex];
      if (!refined || !refined.ownerObjectIdsBySlot) {
        continue;
      }
      const mask = maskForOwnerObject(refined, ownerObjectId);
      if (mask === 0n) {
        continue;
      }
      cells.push(
        rasterCellForMask(worldMacroFromChunkLocal(chunk.data.chunkCoord, index), mask, refined),
      );
    }
  }
  return cells.sort((a, b) => coordKey(a.macro).localeCompare(coordKey(b.macro)));
}

function collectPrefabInstanceCells(
  world: WorldStore,
  instanceId: number,
  min: FMacroCoord,
  max: FMacroCoord,
): PrefabRasterCell[] {
  const cells: PrefabRasterCell[] = [];
  for (let x = min.x; x <= max.x; x += 1) {
    for (let y = min.y; y <= max.y; y += 1) {
      for (let z = min.z; z <= max.z; z += 1) {
        const macro = { x, y, z };
        const refined = world.getRefinedCellWorld(macro);
        if (!refined?.prefabInstanceIds.includes(instanceId)) {
          continue;
        }
        const normalized = normalizeRefinedCell(refined);
        if (normalized.microOccupancyMask !== 0n) {
          cells.push(rasterCellForMask(macro, normalized.microOccupancyMask, normalized));
        }
      }
    }
  }
  return cells;
}

function firstOwnerObjectId(refined: FRefinedCellData): bigint | null {
  const owners = refined.ownerObjectIdsBySlot;
  if (!owners) {
    return null;
  }
  const normalized = normalizeRefinedCell(refined);
  let remaining = normalized.microOccupancyMask;
  while (remaining !== 0n) {
    const slot = trailingZeros(remaining);
    const owner = owners[slot] ?? 0n;
    if (owner !== 0n) {
      return owner;
    }
    remaining &= remaining - 1n;
  }
  return null;
}

function ownerObjectIdAt(refined: FRefinedCellData, slotIndex: number): bigint | null {
  const owner = refined.ownerObjectIdsBySlot?.[slotIndex] ?? 0n;
  return owner === 0n ? null : owner;
}

function maskForOwnerObject(refined: FRefinedCellData, ownerObjectId: bigint): bigint {
  const owners = refined.ownerObjectIdsBySlot;
  if (!owners) {
    return 0n;
  }
  const normalized = normalizeRefinedCell(refined);
  let mask = 0n;
  let remaining = normalized.microOccupancyMask;
  while (remaining !== 0n) {
    const slot = trailingZeros(remaining);
    if ((owners[slot] ?? 0n) === ownerObjectId) {
      mask |= MICRO_SLOT_BITS[slot] ?? 0n;
    }
    remaining &= remaining - 1n;
  }
  return mask;
}

function rasterCellForMask(
  macro: FMacroCoord,
  microOccupancyMask: bigint,
  refined: FRefinedCellData,
): PrefabRasterCell {
  return {
    macro: { ...macro },
    microOccupancyMask,
    microMaterialIds: [...refined.microMaterialIds],
    microStateFlags: [...refined.microStateFlags],
    microPartIds: [...refined.microPartIds],
  };
}

function worldMacroFromChunkLocal(chunkCoord: FMacroCoord, localMacroIndex: number): FMacroCoord {
  const local = macroCoordFromLinearIndex(localMacroIndex);
  return {
    x: chunkCoord.x * VoxelConstants.ChunkSizeX + local.x,
    y: chunkCoord.y * VoxelConstants.ChunkSizeY + local.y,
    z: chunkCoord.z * VoxelConstants.ChunkSizeZ + local.z,
  };
}

function trailingZeros(value: bigint): number {
  let count = 0;
  let remaining = value;
  while ((remaining & 0xffffffffn) === 0n) {
    remaining >>= 32n;
    count += 32;
  }
  while ((remaining & 1n) === 0n) {
    remaining >>= 1n;
    count += 1;
  }
  return Math.min(count, MicroGridSlotCount - 1);
}

function coordKey(coord: { x: number; y: number; z: number }): string {
  return `${coord.x},${coord.y},${coord.z}`;
}
