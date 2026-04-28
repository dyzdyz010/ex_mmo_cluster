import { chunkCoordFromMacro } from "../core/gridUtils";
import {
  chunkCoordKey,
  type EVoxelRotation,
  type FMacroCoord,
  type FMicroCoord,
} from "../core/types";
import { VoxelConstants } from "../core/constants";
import { MicroGridSlotCount } from "../microgrid/governance";
import type { FPrefabInstanceData } from "../storage/types";
import type { WorldStore } from "../worldStore";
import type { LocalPrefab, PrefabCell, PrefabRasterCell, RasterizedPrefab } from "./types";
import {
  MICRO_SLOT_BITS,
  MICRO_SLOT_COORDS,
  addMicroCoord,
  coordKey,
  countBits,
  getOrCreateWeakCachedMap,
  localMicroCoordFromWorldMicro,
  macroCoordFromMicro,
  microLinearIndex,
  rotateMicroPartIds,
  rotateOccupancyWord,
  rotateOffset,
} from "./math";

export interface LocalMicroPoint {
  localMicro: FMicroCoord;
}

export interface LocalOccupiedMicroPoint extends LocalMicroPoint {
  sourceIndex: number;
  materialId: number;
  stateFlags: number;
  partId: number;
}

const occupiedMicroPointCache = new WeakMap<
  LocalPrefab,
  Map<EVoxelRotation, LocalOccupiedMicroPoint[]>
>();

export function transformPrefabCells(cells: PrefabCell[], rotation: EVoxelRotation): PrefabCell[] {
  const rotated = cells.map((entry) => ({
    offset: rotateOffset(entry.offset, rotation),
    occupancyWord: rotateOccupancyWord(entry.occupancyWord, rotation),
    materialId: entry.materialId,
    stateFlags: entry.stateFlags,
    microPartIds: rotateMicroPartIds(entry.microPartIds, rotation),
  }));

  if (rotated.length === 0) {
    return rotated;
  }

  const min = rotated.reduce(
    (acc, entry) => ({
      x: Math.min(acc.x, entry.offset.x),
      y: Math.min(acc.y, entry.offset.y),
      z: Math.min(acc.z, entry.offset.z),
    }),
    { ...rotated[0]!.offset },
  );

  return rotated.map((entry) => ({
    offset: {
      x: entry.offset.x - min.x,
      y: entry.offset.y - min.y,
      z: entry.offset.z - min.z,
    },
    occupancyWord: entry.occupancyWord,
    materialId: entry.materialId,
    stateFlags: entry.stateFlags,
    microPartIds: entry.microPartIds,
  }));
}

export function rasterizePrefab(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
  anchorMicroCoord: FMicroCoord,
): PrefabRasterCell[] {
  return rasterizePrefabDetailed(prefab, rotation, anchorMicroCoord).cells;
}

export function rasterizePrefabDetailed(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
  anchorMicroCoord: FMicroCoord,
): RasterizedPrefab {
  const grouped = new Map<string, PrefabRasterCell>();
  const occupiedWorldMicro: FMicroCoord[] = [];
  for (const point of listPrefabOccupiedLocalPoints(prefab, rotation)) {
    const worldMicro = addMicroCoord(anchorMicroCoord, point.localMicro);
    occupiedWorldMicro.push(worldMicro);
    const macro = macroCoordFromMicro(worldMicro);
    const micro = localMicroCoordFromWorldMicro(worldMicro);
    const targetIndex = microLinearIndex(micro);
    const cell = getOrCreateRasterCell(grouped, macro);
    cell.microOccupancyMask |= MICRO_SLOT_BITS[targetIndex] ?? 0n;
    cell.microMaterialIds[targetIndex] = point.materialId;
    cell.microStateFlags[targetIndex] = point.stateFlags;
    cell.microPartIds[targetIndex] = point.partId;
  }

  return {
    cells: [...grouped.values()].sort((a, b) => coordKey(a.macro).localeCompare(coordKey(b.macro))),
    occupiedWorldMicro,
    incomingOccupiedSlots: occupiedWorldMicro.length,
  };
}

function getOrCreateRasterCell(
  grouped: Map<string, PrefabRasterCell>,
  macro: FMacroCoord,
): PrefabRasterCell {
  const key = coordKey(macro);
  const existing = grouped.get(key);
  if (existing) {
    return existing;
  }
  const cell: PrefabRasterCell = {
    macro,
    microOccupancyMask: 0n,
    microMaterialIds: new Array(MicroGridSlotCount).fill(0),
    microStateFlags: new Array(MicroGridSlotCount).fill(0),
    microPartIds: new Array(MicroGridSlotCount).fill(-1),
  };
  grouped.set(key, cell);
  return cell;
}

export function countOverlapSlots(cells: PrefabRasterCell[], world: WorldStore): number {
  return cells.reduce(
    (sum, cell) =>
      sum + countBits(world.getMicroOccupancyMaskWorld(cell.macro) & cell.microOccupancyMask),
    0,
  );
}

export function boundsFromRasterCells(
  cells: PrefabRasterCell[],
  fallback: FMacroCoord = { x: 0, y: 0, z: 0 },
): { min: FMacroCoord; max: FMacroCoord } {
  if (cells.length === 0) {
    return { min: { ...fallback }, max: { ...fallback } };
  }

  const first = cells[0]!.macro;
  return cells.reduce(
    (acc, entry) => ({
      min: {
        x: Math.min(acc.min.x, entry.macro.x),
        y: Math.min(acc.min.y, entry.macro.y),
        z: Math.min(acc.min.z, entry.macro.z),
      },
      max: {
        x: Math.max(acc.max.x, entry.macro.x),
        y: Math.max(acc.max.y, entry.macro.y),
        z: Math.max(acc.max.z, entry.macro.z),
      },
    }),
    { min: { ...first }, max: { ...first } },
  );
}

export function recordInstanceInCoveredChunks(
  cells: PrefabRasterCell[],
  world: WorldStore,
  instance: FPrefabInstanceData,
): void {
  const touched = new Set<string>();
  for (const entry of cells) {
    const chunkCoord = chunkCoordFromMacro(entry.macro);
    const key = chunkCoordKey(chunkCoord);
    if (touched.has(key)) {
      continue;
    }
    touched.add(key);
    world.ensureChunk(chunkCoord).addPrefabInstance(instance);
  }

  if (touched.size === 0) {
    world.ensureChunk(instance.ownerChunk).addPrefabInstance(instance);
  }
}

export function listPrefabOccupiedLocalPoints(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
): LocalOccupiedMicroPoint[] {
  const cachedByRotation = getOrCreateWeakCachedMap(occupiedMicroPointCache, prefab);
  const cached = cachedByRotation.get(rotation);
  if (cached) {
    return cached;
  }

  const points: LocalOccupiedMicroPoint[] = [];
  for (const entry of transformPrefabCells(prefab.cells, rotation)) {
    for (const [sourceIndex, micro] of MICRO_SLOT_COORDS.entries()) {
      if ((entry.occupancyWord & (MICRO_SLOT_BITS[sourceIndex] ?? 0n)) === 0n) {
        continue;
      }
      points.push({
        localMicro: {
          x: entry.offset.x * VoxelConstants.MicroPerMacro + micro.x,
          y: entry.offset.y * VoxelConstants.MicroPerMacro + micro.y,
          z: entry.offset.z * VoxelConstants.MicroPerMacro + micro.z,
        },
        sourceIndex,
        materialId: entry.materialId,
        stateFlags: entry.stateFlags,
        partId: entry.microPartIds[sourceIndex] ?? -1,
      });
    }
  }
  cachedByRotation.set(rotation, points);
  return points;
}
