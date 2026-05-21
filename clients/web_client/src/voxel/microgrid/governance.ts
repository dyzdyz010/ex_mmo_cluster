import { VoxelConstants } from "../core/constants";
import type { FMicroCoord } from "../core/types";
import type { FNormalBlockData, FRefinedCellData } from "../storage/types";

export const MicroGridSlotCount = VoxelConstants.MicroCountPerMacro;
export const FullMicroOccupancyMask = (1n << BigInt(MicroGridSlotCount)) - 1n;

export function isMicroCoordInBounds(coord: FMicroCoord): boolean {
  return (
    Number.isInteger(coord.x) &&
    Number.isInteger(coord.y) &&
    Number.isInteger(coord.z) &&
    coord.x >= 0 &&
    coord.y >= 0 &&
    coord.z >= 0 &&
    coord.x < VoxelConstants.MicroPerMacro &&
    coord.y < VoxelConstants.MicroPerMacro &&
    coord.z < VoxelConstants.MicroPerMacro
  );
}

export function microLinearIndex(coord: FMicroCoord): number {
  if (!isMicroCoordInBounds(coord)) {
    return -1;
  }

  return (
    coord.x +
    coord.y * VoxelConstants.MicroPerMacro +
    coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro
  );
}

export function microMaskBit(coord: FMicroCoord): bigint {
  const index = microLinearIndex(coord);
  return index < 0 ? 0n : 1n << BigInt(index);
}

export function normalizeRefinedCell(cell: FRefinedCellData): FRefinedCellData {
  const normalized: FRefinedCellData = {
    microOccupancyMask: cell.microOccupancyMask & FullMicroOccupancyMask,
    microMaterialIds: normalizeNumberSlots(cell.microMaterialIds, 0),
    microStateFlags: normalizeNumberSlots(cell.microStateFlags, 0),
    microPartIds: normalizeNumberSlots(cell.microPartIds, -1),
    prefabInstanceIds: [...new Set(cell.prefabInstanceIds)].sort((a, b) => a - b),
    boundaryCache: cell.boundaryCache,
  };
  if (cell.attributeSetRefsBySlot) {
    normalized.attributeSetRefsBySlot = normalizeUint32Slots(cell.attributeSetRefsBySlot);
  }
  if (cell.tagSetRefsBySlot) {
    normalized.tagSetRefsBySlot = normalizeUint32Slots(cell.tagSetRefsBySlot);
  }
  if (cell.ownerObjectIdsBySlot) {
    normalized.ownerObjectIdsBySlot = normalizeBigUint64Slots(cell.ownerObjectIdsBySlot);
  }
  return normalized;
}

export function makeRefinedCellFromBlock(block: FNormalBlockData): FRefinedCellData {
  return {
    microOccupancyMask: FullMicroOccupancyMask,
    microMaterialIds: new Array(MicroGridSlotCount).fill(block.materialId),
    microStateFlags: new Array(MicroGridSlotCount).fill(block.stateFlags),
    microPartIds: new Array(MicroGridSlotCount).fill(-1),
    prefabInstanceIds: [],
    boundaryCache: 0,
  };
}

export function makeSingleMicroRefinedCell(
  micro: FMicroCoord,
  block: FNormalBlockData,
): FRefinedCellData | null {
  const bit = microMaskBit(micro);
  if (bit === 0n) {
    return null;
  }

  const cell = makeEmptyRefinedCell();
  return setMicroBlock(cell, micro, block);
}

export function makeEmptyRefinedCell(): FRefinedCellData {
  return {
    microOccupancyMask: 0n,
    microMaterialIds: new Array(MicroGridSlotCount).fill(0),
    microStateFlags: new Array(MicroGridSlotCount).fill(0),
    microPartIds: new Array(MicroGridSlotCount).fill(-1),
    prefabInstanceIds: [],
    boundaryCache: 0,
  };
}

export function getMicroBlock(cell: FRefinedCellData, micro: FMicroCoord): FNormalBlockData | null {
  const normalized = normalizeRefinedCell(cell);
  const index = microLinearIndex(micro);
  if (index < 0 || (normalized.microOccupancyMask & (1n << BigInt(index))) === 0n) {
    return null;
  }

  return {
    materialId: normalized.microMaterialIds[index] ?? 0,
    stateFlags: normalized.microStateFlags[index] ?? 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

export function isMicroOccupied(cell: FRefinedCellData, micro: FMicroCoord): boolean {
  const index = microLinearIndex(micro);
  return index >= 0 && (cell.microOccupancyMask & (1n << BigInt(index))) !== 0n;
}

export function setMicroBlock(
  cell: FRefinedCellData,
  micro: FMicroCoord,
  block: FNormalBlockData,
): FRefinedCellData | null {
  const index = microLinearIndex(micro);
  if (index < 0) {
    return null;
  }

  const next = normalizeRefinedCell(cell);
  next.microOccupancyMask |= 1n << BigInt(index);
  next.microMaterialIds[index] = block.materialId;
  next.microStateFlags[index] = block.stateFlags;
  return next;
}

export function clearMicroBlock(
  cell: FRefinedCellData,
  micro: FMicroCoord,
): FRefinedCellData | null {
  const index = microLinearIndex(micro);
  if (index < 0) {
    return null;
  }

  const next = normalizeRefinedCell(cell);
  next.microOccupancyMask &= ~(1n << BigInt(index));
  next.microMaterialIds[index] = 0;
  next.microStateFlags[index] = 0;
  next.microPartIds[index] = -1;
  if (next.attributeSetRefsBySlot) {
    next.attributeSetRefsBySlot[index] = 0;
  }
  if (next.tagSetRefsBySlot) {
    next.tagSetRefsBySlot[index] = 0;
  }
  if (next.ownerObjectIdsBySlot) {
    next.ownerObjectIdsBySlot[index] = 0n;
  }
  return next;
}

export function isRefinedCellEmpty(cell: FRefinedCellData): boolean {
  return (cell.microOccupancyMask & FullMicroOccupancyMask) === 0n;
}

function normalizeNumberSlots(values: number[], fallback: number): number[] {
  const out = new Array(MicroGridSlotCount).fill(fallback);
  for (let index = 0; index < Math.min(values.length, MicroGridSlotCount); index += 1) {
    out[index] = values[index] ?? fallback;
  }
  return out;
}

function normalizeUint32Slots(values: Uint32Array): Uint32Array {
  const out = new Uint32Array(MicroGridSlotCount);
  out.set(values.subarray(0, Math.min(values.length, MicroGridSlotCount)));
  return out;
}

function normalizeBigUint64Slots(values: BigUint64Array): BigUint64Array {
  const out = new BigUint64Array(MicroGridSlotCount);
  out.set(values.subarray(0, Math.min(values.length, MicroGridSlotCount)));
  return out;
}
