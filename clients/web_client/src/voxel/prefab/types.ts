import type { EVoxelRotation, FMacroCoord, FMicroCoord } from "../core/types";
import { FullMicroOccupancyMask } from "../microgrid/governance";
import type { FNormalBlockData, FPrefabDefinitionData } from "../storage/types";

export const FULL_MACRO_OCCUPANCY_WORD = FullMicroOccupancyMask;

export interface PrefabBlock {
  offset: FMacroCoord;
  block: FNormalBlockData;
}

export interface PrefabCell {
  offset: FMacroCoord;
  occupancyWord: bigint;
  materialId: number;
  stateFlags: number;
  microPartIds: number[];
}

export interface PrefabRasterCell {
  macro: FMacroCoord;
  microOccupancyMask: bigint;
  microMaterialIds: number[];
  microStateFlags: number[];
  microPartIds: number[];
}

export interface RasterizedPrefab {
  cells: PrefabRasterCell[];
  occupiedWorldMicro: FMicroCoord[];
  incomingOccupiedSlots: number;
}

export interface PrefabSocketSnapRequest {
  prefabName: string;
  targetInstanceId: number;
  targetSocketId: string;
  incomingSocketId?: string;
  rotation?: EVoxelRotation;
}

export interface PrefabSocketSnapPreview {
  ok: boolean;
  prefabId: string;
  targetInstanceId: number;
  targetSocketId: string;
  socketId: string | null;
  anchorMicroCoord: FMicroCoord | null;
  affectedMacroCount: number;
  incomingOccupiedSlots: number;
  overlapSlots: number;
  contactSlots: number;
  cells: PrefabRasterCell[];
  rejectReason?: string;
}

export interface PrefabSocketSnapResult {
  ok: boolean;
  placed: number;
  instanceId?: number;
  conflict?: boolean;
  rejectReason?: string;
  preview?: PrefabSocketSnapPreview;
}

export interface PrefabBoundarySnapRequest {
  prefabName: string;
  hitMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  hitMicro?: FMicroCoord;
  rotation?: EVoxelRotation;
  searchRadius?: number;
}

export interface PrefabBoundarySnapPreview {
  ok: boolean;
  prefabId: string;
  hitMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  anchorMicroCoord: FMicroCoord | null;
  affectedMacroCount: number;
  incomingOccupiedSlots: number;
  overlapSlots: number;
  contactSlots: number;
  cells: PrefabRasterCell[];
  rejectReason?: string;
}

export interface PrefabBoundarySnapResult {
  ok: boolean;
  placed: number;
  instanceId?: number;
  conflict?: boolean;
  rejectReason?: string;
  preview?: PrefabBoundarySnapPreview;
}

export interface PrefabSocketSnapTarget {
  instanceId: number;
  socketId: string;
}

export interface LocalPrefab {
  name: string;
  boundsMin: FMacroCoord;
  boundsMax: FMacroCoord;
  definition: FPrefabDefinitionData;
  blocks: PrefabBlock[];
  cells: PrefabCell[];
}
