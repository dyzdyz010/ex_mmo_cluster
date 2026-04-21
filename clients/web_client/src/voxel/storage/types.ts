// UE test1 Voxel/Storage/VoxelStorageTypes.h 的 TypeScript 镜像。
// 字段顺序与原 USTRUCT 保持一致，以便 codec 层做确定性序列化。

import type {
  FChunkCoord,
  FMacroCoord,
  FMicroCoord,
  EVoxelCellMode,
  EVoxelRotation,
} from "../core/types";

export const VoxelDirtyFlags = {
  None: 0,
  Storage: 1 << 0,
  Mesh: 1 << 1,
  Collision: 1 << 2,
} as const;

// 真实字节：u16 + i32 + u16 + i16 + i16 = 12 bytes（含 4B 对齐时可能为 16B；线格式按 12B 紧凑存）。
export interface FNormalBlockData {
  materialId: number;
  stateFlags: number;
  health: number;
  temperatureDelta: number;
  moistureDelta: number;
}

export interface FMacroCellHeader {
  mode: EVoxelCellMode;
  payloadIndex: number;
  environmentIndex: number;
  flags: number;
}

// UE 侧允许 EnvironmentIndex = MAX_uint16 表示未分配。
export const MACRO_ENV_INDEX_UNSET = 0xFFFF;

export interface FRefinedCellData {
  microOccupancyMask: bigint;
  microMaterialIds: number[];
  microStateFlags: number[];
  prefabInstanceIds: number[];
  boundaryCache: number;
}

export interface FPrefabInstanceData {
  instanceId: number;
  prefabId: string;
  anchorMicroCoord: FMicroCoord;
  rotation: EVoxelRotation;
  ownerChunk: FChunkCoord;
  coveredMacroMin: FMacroCoord;
  coveredMacroMax: FMacroCoord;
  overrideSetIndex: number;
}

export interface FMacroEnvironmentSummary {
  defaultTemperature: number;
  defaultMoisture: number;
  currentTemperature: number;
  currentMoisture: number;
  fieldMask: number;
}

export interface FChunkStorageData {
  chunkCoord: FChunkCoord;
  macroHeaders: FMacroCellHeader[];
  normalBlocks: FNormalBlockData[];
  refinedCells: FRefinedCellData[];
  prefabInstances: FPrefabInstanceData[];
  environmentSummaries: FMacroEnvironmentSummary[];
  freeNormalBlockIndices: number[];
  freeEnvironmentSummaryIndices: number[];
  dirtyMacroMin: FMacroCoord;
  dirtyMacroMax: FMacroCoord;
  dirtyFlags: number;
}

export function makeEmptyMacroHeader(): FMacroCellHeader {
  return {
    mode: 0,
    payloadIndex: 0,
    environmentIndex: MACRO_ENV_INDEX_UNSET,
    flags: 0,
  };
}

export function makeEmptyNormalBlock(): FNormalBlockData {
  return {
    materialId: 0,
    stateFlags: 0,
    health: 0,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}
