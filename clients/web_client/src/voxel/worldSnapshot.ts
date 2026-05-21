import { VoxelConstants } from "./core/constants";
import { localMacroInChunk, macroCoordFromLinearIndex } from "./core/gridUtils";
import { EVoxelCellMode, type FChunkCoord, type FMacroCoord, type FMicroCoord } from "./core/types";
import { normalizeRefinedCell } from "./microgrid/governance";
import type { ChunkStorage } from "./storage/chunkStorage";
import {
  createSurfaceAttachment,
  type SurfaceAttachment,
  type SurfaceAttachmentFace,
  type SurfaceAttachmentVisibilityPolicy,
} from "./surfaceAttachment";
import {
  MACRO_ENV_INDEX_UNSET,
  VoxelDirtyFlags,
  type FMacroEnvironmentSummary,
  type FNormalBlockData,
  type FPrefabInstanceData,
  type FRefinedCellData,
} from "./storage/types";

export interface WorldEditStats {
  placed: number;
  broken: number;
  rejected: number;
  conflicts: number;
}

export interface SerializedRefinedCellData {
  microOccupancyMask: string;
  microMaterialIds: number[];
  microStateFlags: number[];
  microPartIds: number[];
  prefabInstanceIds: number[];
  boundaryCache: number;
  attributeSetRefsBySlot?: number[];
  tagSetRefsBySlot?: number[];
  ownerObjectIdsBySlot?: string[];
}

export interface SerializedChunkStorageSnapshot {
  chunkCoord: FChunkCoord;
  cells: SerializedWorldCellSnapshot[];
  prefabInstances: FPrefabInstanceData[];
  surfaceAttachments: SerializedSurfaceAttachment[];
}

export interface SerializedWorldCellSnapshot {
  coord: FMacroCoord;
  mode: EVoxelCellMode;
  normalBlock?: FNormalBlockData;
  refinedCell?: SerializedRefinedCellData;
  environment?: FMacroEnvironmentSummary;
}

export interface SerializedWorldSnapshot {
  version: 1;
  chunks: SerializedChunkStorageSnapshot[];
  editStats: WorldEditStats;
}

export interface SerializedSurfaceAttachment {
  id: string;
  anchorMacro: FMacroCoord;
  anchorMicro: FMicroCoord;
  face: SurfaceAttachmentFace;
  materialId: number;
  faceMask: string;
  ownerObjectId: string;
  ownerPartId: number;
  visibilityPolicy: SurfaceAttachmentVisibilityPolicy;
}

interface WorldSnapshotImportTarget {
  readonly editStats: WorldEditStats;
  clearChunks(): void;
  ensureChunk(coord: FChunkCoord): ChunkStorage;
}

export function exportWorldSnapshot(
  chunks: readonly ChunkStorage[],
  editStats: WorldEditStats,
): SerializedWorldSnapshot {
  return {
    version: 1,
    chunks: chunks.map((chunk) => ({
      chunkCoord: cloneChunkCoord(chunk.data.chunkCoord),
      cells: serializeChunkCells(chunk),
      prefabInstances: chunk.data.prefabInstances.map(clonePrefabInstance),
      surfaceAttachments: (chunk.data.surfaceAttachments ?? []).map(serializeSurfaceAttachment),
    })),
    editStats: { ...editStats },
  };
}

export function importWorldSnapshot(
  snapshot: SerializedWorldSnapshot,
  target: WorldSnapshotImportTarget,
): void {
  if (snapshot.version !== 1) {
    throw new Error(`Unsupported world snapshot version: ${String(snapshot.version)}`);
  }

  target.clearChunks();
  for (const chunkSnapshot of snapshot.chunks) {
    const chunk = target.ensureChunk(chunkSnapshot.chunkCoord);
    chunk.data.prefabInstances = chunkSnapshot.prefabInstances.map(clonePrefabInstance);
    chunk.data.surfaceAttachments = (chunkSnapshot.surfaceAttachments ?? []).map(
      deserializeSurfaceAttachment,
    );
    for (const cell of chunkSnapshot.cells) {
      restoreSnapshotCell(chunk, cell);
    }
    chunk.data.dirtyMacroMin = { x: 0, y: 0, z: 0 };
    chunk.data.dirtyMacroMax = {
      x: VoxelConstants.ChunkSizeX - 1,
      y: VoxelConstants.ChunkSizeY - 1,
      z: VoxelConstants.ChunkSizeZ - 1,
    };
    chunk.data.dirtyFlags =
      VoxelDirtyFlags.Storage | VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision;
  }

  target.editStats.placed = snapshot.editStats.placed;
  target.editStats.broken = snapshot.editStats.broken;
  target.editStats.rejected = snapshot.editStats.rejected;
  target.editStats.conflicts = snapshot.editStats.conflicts;
}

export function clonePrefabInstance(instance: FPrefabInstanceData): FPrefabInstanceData {
  return {
    instanceId: instance.instanceId,
    prefabId: instance.prefabId,
    anchorMicroCoord: cloneMacroCoord(instance.anchorMicroCoord),
    rotation: instance.rotation,
    ownerChunk: cloneChunkCoord(instance.ownerChunk),
    coveredMacroMin: cloneMacroCoord(instance.coveredMacroMin),
    coveredMacroMax: cloneMacroCoord(instance.coveredMacroMax),
    overrideSetIndex: instance.overrideSetIndex,
  };
}

function cloneChunkCoord(coord: FChunkCoord): FChunkCoord {
  return { x: coord.x, y: coord.y, z: coord.z };
}

function cloneMacroCoord(coord: FMacroCoord): FMacroCoord {
  return { x: coord.x, y: coord.y, z: coord.z };
}

function cloneMicroCoord(coord: FMicroCoord): FMicroCoord {
  return { x: coord.x, y: coord.y, z: coord.z };
}

function cloneNormalBlock(block: FNormalBlockData): FNormalBlockData {
  return {
    materialId: block.materialId,
    stateFlags: block.stateFlags,
    health: block.health,
    temperatureDelta: block.temperatureDelta,
    moistureDelta: block.moistureDelta,
  };
}

function serializeChunkCells(chunk: ChunkStorage): SerializedWorldCellSnapshot[] {
  const cells: SerializedWorldCellSnapshot[] = [];
  for (let index = 0; index < chunk.data.macroHeaders.length; index += 1) {
    const header = chunk.data.macroHeaders[index];
    if (
      !header ||
      (header.mode === EVoxelCellMode.Empty && header.environmentIndex === MACRO_ENV_INDEX_UNSET)
    ) {
      continue;
    }

    const local = macroCoordFromLinearIndex(index);
    const coord = {
      x: chunk.data.chunkCoord.x * VoxelConstants.ChunkSizeX + local.x,
      y: chunk.data.chunkCoord.y * VoxelConstants.ChunkSizeY + local.y,
      z: chunk.data.chunkCoord.z * VoxelConstants.ChunkSizeZ + local.z,
    };
    const cell: SerializedWorldCellSnapshot = {
      coord,
      mode: header.mode,
    };
    if (header.mode === EVoxelCellMode.SolidBlock) {
      const block = chunk.data.normalBlocks[header.payloadIndex];
      if (block) {
        cell.normalBlock = cloneNormalBlock(block);
      }
    }
    if (header.mode === EVoxelCellMode.Refined) {
      const refined = chunk.data.refinedCells[header.payloadIndex];
      if (refined) {
        cell.refinedCell = serializeRefinedCell(refined);
      }
    }
    if (header.environmentIndex !== MACRO_ENV_INDEX_UNSET) {
      const environment = chunk.data.environmentSummaries[header.environmentIndex];
      if (environment) {
        cell.environment = cloneEnvironmentSummary(environment);
      }
    }
    cells.push(cell);
  }
  return cells;
}

function restoreSnapshotCell(chunk: ChunkStorage, cell: SerializedWorldCellSnapshot): void {
  const local = localMacroInChunk(cell.coord);
  const header = chunk.getHeaderAt(local);
  if (!header) {
    return;
  }

  if (cell.mode === EVoxelCellMode.SolidBlock && cell.normalBlock) {
    header.mode = EVoxelCellMode.SolidBlock;
    header.payloadIndex = chunk.data.normalBlocks.push(cloneNormalBlock(cell.normalBlock)) - 1;
  } else if (cell.mode === EVoxelCellMode.Refined && cell.refinedCell) {
    header.mode = EVoxelCellMode.Refined;
    header.payloadIndex =
      chunk.data.refinedCells.push(deserializeRefinedCell(cell.refinedCell)) - 1;
  } else {
    header.mode = EVoxelCellMode.Empty;
    header.payloadIndex = 0;
  }

  if (cell.environment) {
    header.environmentIndex =
      chunk.data.environmentSummaries.push(cloneEnvironmentSummary(cell.environment)) - 1;
  }
}

function serializeRefinedCell(cell: FRefinedCellData): SerializedRefinedCellData {
  const normalized = normalizeRefinedCell(cell);
  const serialized: SerializedRefinedCellData = {
    microOccupancyMask: normalized.microOccupancyMask.toString(),
    microMaterialIds: [...normalized.microMaterialIds],
    microStateFlags: [...normalized.microStateFlags],
    microPartIds: [...normalized.microPartIds],
    prefabInstanceIds: [...normalized.prefabInstanceIds],
    boundaryCache: normalized.boundaryCache,
  };
  if (normalized.attributeSetRefsBySlot) {
    serialized.attributeSetRefsBySlot = [...normalized.attributeSetRefsBySlot];
  }
  if (normalized.tagSetRefsBySlot) {
    serialized.tagSetRefsBySlot = [...normalized.tagSetRefsBySlot];
  }
  if (normalized.ownerObjectIdsBySlot) {
    serialized.ownerObjectIdsBySlot = [...normalized.ownerObjectIdsBySlot].map((value) =>
      value.toString(),
    );
  }
  return serialized;
}

function deserializeRefinedCell(cell: SerializedRefinedCellData): FRefinedCellData {
  return normalizeRefinedCell({
    microOccupancyMask: BigInt(cell.microOccupancyMask),
    microMaterialIds: [...cell.microMaterialIds],
    microStateFlags: [...cell.microStateFlags],
    microPartIds: [...cell.microPartIds],
    prefabInstanceIds: [...cell.prefabInstanceIds],
    boundaryCache: cell.boundaryCache,
    ...(cell.attributeSetRefsBySlot
      ? { attributeSetRefsBySlot: Uint32Array.from(cell.attributeSetRefsBySlot) }
      : {}),
    ...(cell.tagSetRefsBySlot ? { tagSetRefsBySlot: Uint32Array.from(cell.tagSetRefsBySlot) } : {}),
    ...(cell.ownerObjectIdsBySlot
      ? { ownerObjectIdsBySlot: BigUint64Array.from(cell.ownerObjectIdsBySlot.map(BigInt)) }
      : {}),
  });
}

function cloneEnvironmentSummary(summary: FMacroEnvironmentSummary): FMacroEnvironmentSummary {
  return {
    defaultTemperature: summary.defaultTemperature,
    defaultMoisture: summary.defaultMoisture,
    currentTemperature: summary.currentTemperature,
    currentMoisture: summary.currentMoisture,
    fieldMask: summary.fieldMask,
  };
}

function serializeSurfaceAttachment(attachment: SurfaceAttachment): SerializedSurfaceAttachment {
  return {
    id: attachment.id,
    anchorMacro: cloneMacroCoord(attachment.anchorMacro),
    anchorMicro: cloneMicroCoord(attachment.anchorMicro),
    face: attachment.face,
    materialId: attachment.materialId,
    faceMask: attachment.faceMask.toString(),
    ownerObjectId: attachment.ownerObjectId.toString(),
    ownerPartId: attachment.ownerPartId,
    visibilityPolicy: attachment.visibilityPolicy,
  };
}

function deserializeSurfaceAttachment(
  attachment: SerializedSurfaceAttachment,
): SurfaceAttachment {
  return createSurfaceAttachment({
    id: attachment.id,
    anchorMacro: cloneMacroCoord(attachment.anchorMacro),
    anchorMicro: cloneMicroCoord(attachment.anchorMicro),
    face: attachment.face,
    materialId: attachment.materialId,
    faceMask: BigInt(attachment.faceMask),
    ownerObjectId: BigInt(attachment.ownerObjectId),
    ownerPartId: attachment.ownerPartId,
    visibilityPolicy: attachment.visibilityPolicy,
  });
}
