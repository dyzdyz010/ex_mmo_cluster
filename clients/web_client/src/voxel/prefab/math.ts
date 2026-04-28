import { EVoxelRotation, type FMacroCoord, type FMicroCoord } from "../core/types";
import { chunkCoordFromMacro } from "../core/gridUtils";
import { VoxelConstants } from "../core/constants";
import { MicroGridSlotCount } from "../microgrid/governance";

export const MICRO_SLOT_COORDS = buildMicroSlotCoords();
export const MICRO_SLOT_BITS = MICRO_SLOT_COORDS.map((_, index) => 1n << BigInt(index));

export function macroToMicroCoord(coord: FMacroCoord): FMacroCoord {
  return {
    x: coord.x * VoxelConstants.MicroPerMacro,
    y: coord.y * VoxelConstants.MicroPerMacro,
    z: coord.z * VoxelConstants.MicroPerMacro,
  };
}

function buildMicroSlotCoords(): FMicroCoord[] {
  const coords: FMicroCoord[] = [];
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        coords[microLinearIndex({ x, y, z })] = { x, y, z };
      }
    }
  }
  return coords;
}

export function getOrCreateWeakCachedMap<K extends object, MK, MV>(
  cache: WeakMap<K, Map<MK, MV>>,
  key: K,
): Map<MK, MV> {
  const existing = cache.get(key);
  if (existing) {
    return existing;
  }
  const created = new Map<MK, MV>();
  cache.set(key, created);
  return created;
}

export function prefabLinearIndex(coord: FMacroCoord, bounds: FMacroCoord): number {
  return coord.z + coord.y * bounds.z + coord.x * bounds.y * bounds.z;
}

export function rotateOffset(offset: FMacroCoord, rotation: EVoxelRotation): FMacroCoord {
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: -offset.z, y: offset.y, z: offset.x };
    case EVoxelRotation.Rot180:
      return { x: -offset.x, y: offset.y, z: -offset.z };
    case EVoxelRotation.Rot270:
      return { x: offset.z, y: offset.y, z: -offset.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...offset };
  }
}

export function countBits(mask: bigint): number {
  let count = 0;
  let value = mask;
  while (value !== 0n) {
    value &= value - 1n;
    count += 1;
  }
  return count;
}

export function macroCoordFromMicro(coord: FMicroCoord): FMacroCoord {
  return {
    x: floorDiv(coord.x, VoxelConstants.MicroPerMacro),
    y: floorDiv(coord.y, VoxelConstants.MicroPerMacro),
    z: floorDiv(coord.z, VoxelConstants.MicroPerMacro),
  };
}

export function chunkCoordFromMicro(coord: FMicroCoord): FMacroCoord {
  return chunkCoordFromMacro(macroCoordFromMicro(coord));
}

export function localMicroCoordFromWorldMicro(coord: FMicroCoord): FMicroCoord {
  return {
    x: positiveModulo(coord.x, VoxelConstants.MicroPerMacro),
    y: positiveModulo(coord.y, VoxelConstants.MicroPerMacro),
    z: positiveModulo(coord.z, VoxelConstants.MicroPerMacro),
  };
}

function floorDiv(value: number, divisor: number): number {
  return Math.floor(value / divisor);
}

function positiveModulo(value: number, divisor: number): number {
  return ((value % divisor) + divisor) % divisor;
}

export function coordKey(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

export function addMicroCoord(a: FMicroCoord, b: FMicroCoord): FMicroCoord {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

export function subtractMicroCoord(a: FMicroCoord, b: FMicroCoord): FMicroCoord {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

export function sameCoord(a: FMacroCoord, b: FMacroCoord): boolean {
  return a.x === b.x && a.y === b.y && a.z === b.z;
}

export function macroWithinBounds(macro: FMacroCoord, min: FMacroCoord, max: FMacroCoord): boolean {
  return (
    macro.x >= min.x &&
    macro.y >= min.y &&
    macro.z >= min.z &&
    macro.x <= max.x &&
    macro.y <= max.y &&
    macro.z <= max.z
  );
}

export function rotateOccupancyWord(word: bigint, rotation: EVoxelRotation): bigint {
  if (rotation === EVoxelRotation.Rot0 || word === 0n) {
    return word;
  }

  let out = 0n;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const from = microLinearIndex({ x, y, z });
        if ((word & (1n << BigInt(from))) === 0n) {
          continue;
        }
        const toCoord = rotateMicroCoord({ x, y, z }, rotation);
        out |= 1n << BigInt(microLinearIndex(toCoord));
      }
    }
  }
  return out;
}

export function rotateMicroPartIds(partIds: number[], rotation: EVoxelRotation): number[] {
  const source = normalizedMicroPartIds(partIds);
  if (rotation === EVoxelRotation.Rot0) {
    return source;
  }

  const out = new Array(MicroGridSlotCount).fill(-1);
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const from = microLinearIndex({ x, y, z });
        const to = microLinearIndex(rotateMicroCoord({ x, y, z }, rotation));
        out[to] = source[from] ?? -1;
      }
    }
  }
  return out;
}

function normalizedMicroPartIds(partIds: number[]): number[] {
  const out = new Array(MicroGridSlotCount).fill(-1);
  for (let index = 0; index < Math.min(partIds.length, MicroGridSlotCount); index += 1) {
    out[index] = partIds[index] ?? -1;
  }
  return out;
}

export function rotateMicroCoord(coord: FMacroCoord, rotation: EVoxelRotation): FMacroCoord {
  const max = VoxelConstants.MicroPerMacro - 1;
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: max - coord.z, y: coord.y, z: coord.x };
    case EVoxelRotation.Rot180:
      return { x: max - coord.x, y: coord.y, z: max - coord.z };
    case EVoxelRotation.Rot270:
      return { x: coord.z, y: coord.y, z: max - coord.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...coord };
  }
}

export function microLinearIndex(coord: FMacroCoord): number {
  return (
    coord.x +
    coord.y * VoxelConstants.MicroPerMacro +
    coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro
  );
}
