import { VoxelConstants } from "../core/constants";
import type { FMacroCoord, FMicroCoord } from "../core/types";
import type { FPrefabBoundaryFaceMasks } from "../storage/types";
import { microLinearIndex, prefabLinearIndex } from "./math";

export type BoundaryFaceName = keyof FPrefabBoundaryFaceMasks;

export function buildBoundarySignature(occupancyWords: bigint[], bounds: FMacroCoord): number[] {
  const faces = [0, 0, 0, 0, 0, 0];
  for (let x = 0; x < bounds.x; x += 1) {
    for (let y = 0; y < bounds.y; y += 1) {
      for (let z = 0; z < bounds.z; z += 1) {
        const word = occupancyWords[prefabLinearIndex({ x, y, z }, bounds)] ?? 0n;
        if (word === 0n) {
          continue;
        }
        if (x === 0) faces[0] = (faces[0] ?? 0) + 1;
        if (x === bounds.x - 1) faces[1] = (faces[1] ?? 0) + 1;
        if (y === 0) faces[2] = (faces[2] ?? 0) + 1;
        if (y === bounds.y - 1) faces[3] = (faces[3] ?? 0) + 1;
        if (z === 0) faces[4] = (faces[4] ?? 0) + 1;
        if (z === bounds.z - 1) faces[5] = (faces[5] ?? 0) + 1;
      }
    }
  }
  return faces;
}

export function buildBoundaryFaceMasks(
  occupancyWords: bigint[],
  bounds: FMacroCoord,
): FPrefabBoundaryFaceMasks {
  const masks: FPrefabBoundaryFaceMasks = {
    negX: 0n,
    posX: 0n,
    negY: 0n,
    posY: 0n,
    negZ: 0n,
    posZ: 0n,
  };

  for (let x = 0; x < bounds.x; x += 1) {
    for (let y = 0; y < bounds.y; y += 1) {
      for (let z = 0; z < bounds.z; z += 1) {
        const word = occupancyWords[prefabLinearIndex({ x, y, z }, bounds)] ?? 0n;
        if (word === 0n) {
          continue;
        }
        if (x === 0) masks.negX |= extractBoundaryFaceMask(word, "negX");
        if (x === bounds.x - 1) masks.posX |= extractBoundaryFaceMask(word, "posX");
        if (y === 0) masks.negY |= extractBoundaryFaceMask(word, "negY");
        if (y === bounds.y - 1) masks.posY |= extractBoundaryFaceMask(word, "posY");
        if (z === 0) masks.negZ |= extractBoundaryFaceMask(word, "negZ");
        if (z === bounds.z - 1) masks.posZ |= extractBoundaryFaceMask(word, "posZ");
      }
    }
  }

  return masks;
}

export function extractBoundaryFaceMask(word: bigint, face: BoundaryFaceName): bigint {
  let mask = 0n;
  const max = VoxelConstants.MicroPerMacro - 1;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        if (!isCoordOnFace({ x, y, z }, face, max)) {
          continue;
        }
        const sourceIndex = microLinearIndex({ x, y, z });
        if ((word & (1n << BigInt(sourceIndex))) === 0n) {
          continue;
        }
        mask |= 1n << BigInt(boundaryFaceLinearIndex({ x, y, z }, face));
      }
    }
  }
  return mask;
}

function isCoordOnFace(coord: FMicroCoord, face: BoundaryFaceName, max: number): boolean {
  switch (face) {
    case "negX":
      return coord.x === 0;
    case "posX":
      return coord.x === max;
    case "negY":
      return coord.y === 0;
    case "posY":
      return coord.y === max;
    case "negZ":
      return coord.z === 0;
    case "posZ":
      return coord.z === max;
  }
}

function boundaryFaceLinearIndex(coord: FMicroCoord, face: BoundaryFaceName): number {
  switch (face) {
    case "negX":
    case "posX":
      return coord.y + coord.z * VoxelConstants.MicroPerMacro;
    case "negY":
    case "posY":
      return coord.x + coord.z * VoxelConstants.MicroPerMacro;
    case "negZ":
    case "posZ":
      return coord.x + coord.y * VoxelConstants.MicroPerMacro;
  }
}
