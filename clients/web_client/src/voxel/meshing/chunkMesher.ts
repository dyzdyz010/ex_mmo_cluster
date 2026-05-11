import { MacroWorldSize, VoxelConstants } from "../core/constants";
import { EVoxelCellMode, type FMacroCoord, type FMicroCoord } from "../core/types";
import { buildBlockStateView, resolveVoxelVisual } from "../../material/catalog";
import { materialAtlasFaceUvs } from "../../material/atlas";
import type { FChunkMesherCellSnapshot, FChunkMesherInputSnapshot } from "./types";

export interface ChunkMeshBuildData {
  positions: number[];
  normals: number[];
  colors: number[];
  uvs: number[];
  indices: number[];
  solidBlockCount: number;
  triangleCount: number;
}

interface ChunkWorldLookup {
  isSolidWorldMacroCoord(coord: FMacroCoord): boolean;
  isSolidWorldMicroCoord?(macro: FMacroCoord, micro: FMicroCoord): boolean;
}

interface FaceDefinition {
  normal: FMacroCoord;
  corners: readonly [number, number, number][];
}

const FACE_DEFINITIONS: readonly FaceDefinition[] = [
  {
    normal: { x: 1, y: 0, z: 0 },
    corners: [
      [1, 0, 0],
      [1, 1, 0],
      [1, 1, 1],
      [1, 0, 1],
    ],
  },
  {
    normal: { x: -1, y: 0, z: 0 },
    corners: [
      [0, 0, 1],
      [0, 1, 1],
      [0, 1, 0],
      [0, 0, 0],
    ],
  },
  {
    normal: { x: 0, y: 1, z: 0 },
    corners: [
      [0, 1, 1],
      [1, 1, 1],
      [1, 1, 0],
      [0, 1, 0],
    ],
  },
  {
    normal: { x: 0, y: -1, z: 0 },
    corners: [
      [0, 0, 0],
      [1, 0, 0],
      [1, 0, 1],
      [0, 0, 1],
    ],
  },
  {
    normal: { x: 0, y: 0, z: 1 },
    corners: [
      [0, 0, 1],
      [1, 0, 1],
      [1, 1, 1],
      [0, 1, 1],
    ],
  },
  {
    normal: { x: 0, y: 0, z: -1 },
    corners: [
      [1, 0, 0],
      [0, 0, 0],
      [0, 1, 0],
      [1, 1, 0],
    ],
  },
] as const;

export function buildChunkMeshData(
  snapshot: FChunkMesherInputSnapshot,
  lookup: ChunkWorldLookup,
): ChunkMeshBuildData {
  const positions: number[] = [];
  const normals: number[] = [];
  const colors: number[] = [];
  const uvs: number[] = [];
  const indices: number[] = [];

  let solidBlockCount = 0;
  const snapshotCellsByWorldMacro = buildSnapshotCellMap(snapshot);
  for (const cell of snapshot.cells) {
    if (cell.mode === EVoxelCellMode.Refined) {
      solidBlockCount += appendRefinedCellMesh(
        snapshot,
        snapshotCellsByWorldMacro,
        lookup,
        cell,
        positions,
        normals,
        colors,
        uvs,
        indices,
      );
      continue;
    }

    if (cell.mode !== EVoxelCellMode.SolidBlock || cell.materialId === 0) {
      continue;
    }

    solidBlockCount += 1;
    const worldMacro = {
      x: snapshot.chunkCoord.x * 16 + cell.localMacroCoord.x,
      y: snapshot.chunkCoord.y * 16 + cell.localMacroCoord.y,
      z: snapshot.chunkCoord.z * 16 + cell.localMacroCoord.z,
    };

    const visual = resolveVoxelVisual(
      buildBlockStateView({
        materialId: cell.materialId,
        stateFlags: cell.stateFlags,
        health: cell.health,
        temperatureDelta: 0,
        moistureDelta: 0,
      }),
    );

    for (const face of FACE_DEFINITIONS) {
      const neighbor = {
        x: worldMacro.x + face.normal.x,
        y: worldMacro.y + face.normal.y,
        z: worldMacro.z + face.normal.z,
      };
      if (isMacroFaceOccluded(snapshotCellsByWorldMacro, lookup, neighbor, face.normal)) {
        continue;
      }

      const baseVertex = positions.length / 3;
      const faceUvs = materialAtlasFaceUvs(cell.materialId);
      for (const corner of face.corners) {
        positions.push(
          (cell.localMacroCoord.x + corner[0]) * MacroWorldSize,
          (cell.localMacroCoord.y + corner[1]) * MacroWorldSize,
          (cell.localMacroCoord.z + corner[2]) * MacroWorldSize,
        );
        normals.push(face.normal.x, face.normal.y, face.normal.z);
        colors.push(visual.displayColor.r, visual.displayColor.g, visual.displayColor.b);
      }
      uvs.push(...faceUvs);

      indices.push(
        baseVertex,
        baseVertex + 1,
        baseVertex + 2,
        baseVertex,
        baseVertex + 2,
        baseVertex + 3,
      );
    }
  }

  return {
    positions,
    normals,
    colors,
    uvs,
    indices,
    solidBlockCount,
    triangleCount: indices.length / 3,
  };
}

function appendRefinedCellMesh(
  snapshot: FChunkMesherInputSnapshot,
  snapshotCellsByWorldMacro: Map<string, FChunkMesherCellSnapshot>,
  lookup: ChunkWorldLookup,
  cell: FChunkMesherCellSnapshot,
  positions: number[],
  normals: number[],
  colors: number[],
  uvs: number[],
  indices: number[],
): number {
  const occupancy = cell.microOccupancyMask ?? 0n;
  if (occupancy === 0n) {
    return 0;
  }

  let occupiedCount = 0;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const microIndex = microLinearIndex({ x, y, z });
        if (!isMicroOccupied(occupancy, microIndex)) {
          continue;
        }
        occupiedCount += 1;
        appendMicroCube(
          snapshot,
          snapshotCellsByWorldMacro,
          lookup,
          cell,
          { x, y, z },
          microIndex,
          occupancy,
          positions,
          normals,
          colors,
          uvs,
          indices,
        );
      }
    }
  }
  return occupiedCount;
}

function appendMicroCube(
  snapshot: FChunkMesherInputSnapshot,
  snapshotCellsByWorldMacro: Map<string, FChunkMesherCellSnapshot>,
  lookup: ChunkWorldLookup,
  cell: FChunkMesherCellSnapshot,
  micro: FMicroCoord,
  microIndex: number,
  occupancy: bigint,
  positions: number[],
  normals: number[],
  colors: number[],
  uvs: number[],
  indices: number[],
): void {
  const materialId = cell.microMaterialIds?.[microIndex] ?? cell.materialId;
  const stateFlags = cell.microStateFlags?.[microIndex] ?? cell.stateFlags;
  const visual = resolveVoxelVisual(
    buildBlockStateView({
      materialId,
      stateFlags,
      health: cell.health,
      temperatureDelta: 0,
      moistureDelta: 0,
    }),
  );

  for (const face of FACE_DEFINITIONS) {
    if (
      isMicroFaceOccluded(snapshot, snapshotCellsByWorldMacro, lookup, cell, micro, occupancy, face)
    ) {
      continue;
    }

    const baseVertex = positions.length / 3;
    const faceUvs = materialAtlasFaceUvs(materialId);
    for (const corner of face.corners) {
      positions.push(
        (cell.localMacroCoord.x + (micro.x + corner[0]) / VoxelConstants.MicroPerMacro) *
          MacroWorldSize,
        (cell.localMacroCoord.y + (micro.y + corner[1]) / VoxelConstants.MicroPerMacro) *
          MacroWorldSize,
        (cell.localMacroCoord.z + (micro.z + corner[2]) / VoxelConstants.MicroPerMacro) *
          MacroWorldSize,
      );
      normals.push(face.normal.x, face.normal.y, face.normal.z);
      colors.push(visual.displayColor.r, visual.displayColor.g, visual.displayColor.b);
    }
    uvs.push(...faceUvs);

    indices.push(
      baseVertex,
      baseVertex + 1,
      baseVertex + 2,
      baseVertex,
      baseVertex + 2,
      baseVertex + 3,
    );
  }
}

function isMicroFaceOccluded(
  snapshot: FChunkMesherInputSnapshot,
  snapshotCellsByWorldMacro: Map<string, FChunkMesherCellSnapshot>,
  lookup: ChunkWorldLookup,
  cell: FChunkMesherCellSnapshot,
  micro: FMicroCoord,
  occupancy: bigint,
  face: FaceDefinition,
): boolean {
  const neighborMicro = {
    x: micro.x + face.normal.x,
    y: micro.y + face.normal.y,
    z: micro.z + face.normal.z,
  };

  if (microInBounds(neighborMicro)) {
    return isMicroOccupied(occupancy, microLinearIndex(neighborMicro));
  }

  const worldMacro = cellWorldMacro(snapshot, cell);
  const target = wrapNeighborMicro(worldMacro, neighborMicro);
  const snapshotOccupancy = isSnapshotMicroOccupied(
    snapshotCellsByWorldMacro,
    target.macro,
    target.micro,
  );
  if (snapshotOccupancy !== null) {
    return snapshotOccupancy;
  }

  if (lookup.isSolidWorldMicroCoord) {
    return lookup.isSolidWorldMicroCoord(target.macro, target.micro);
  }

  return lookup.isSolidWorldMacroCoord(target.macro);
}

function isMacroFaceOccluded(
  snapshotCellsByWorldMacro: Map<string, FChunkMesherCellSnapshot>,
  lookup: ChunkWorldLookup,
  neighborMacro: FMacroCoord,
  faceNormal: FMacroCoord,
): boolean {
  const snapshotCell = snapshotCellsByWorldMacro.get(macroKey(neighborMacro));
  if (snapshotCell) {
    return isSnapshotMacroBoundaryFaceFullyOccupied(snapshotCell, faceNormal);
  }

  if (lookup.isSolidWorldMicroCoord) {
    return allBoundaryFaceMicroCoords(faceNormal).every((micro) =>
      lookup.isSolidWorldMicroCoord?.(neighborMacro, micro),
    );
  }

  return lookup.isSolidWorldMacroCoord(neighborMacro);
}

function isSnapshotMacroBoundaryFaceFullyOccupied(
  cell: FChunkMesherCellSnapshot,
  faceNormal: FMacroCoord,
): boolean {
  if (cell.mode === EVoxelCellMode.SolidBlock) {
    return cell.materialId !== 0;
  }

  if (cell.mode !== EVoxelCellMode.Refined) {
    return false;
  }

  const occupancy = cell.microOccupancyMask ?? 0n;
  return allBoundaryFaceMicroCoords(faceNormal).every((micro) =>
    isMicroOccupied(occupancy, microLinearIndex(micro)),
  );
}

function allBoundaryFaceMicroCoords(faceNormal: FMacroCoord): FMicroCoord[] {
  const max = VoxelConstants.MicroPerMacro - 1;
  const coords: FMicroCoord[] = [];

  if (faceNormal.x !== 0) {
    const x = faceNormal.x > 0 ? 0 : max;
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        coords.push({ x, y, z });
      }
    }
    return coords;
  }

  if (faceNormal.y !== 0) {
    const y = faceNormal.y > 0 ? 0 : max;
    for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        coords.push({ x, y, z });
      }
    }
    return coords;
  }

  const z = faceNormal.z > 0 ? 0 : max;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      coords.push({ x, y, z });
    }
  }
  return coords;
}

function buildSnapshotCellMap(
  snapshot: FChunkMesherInputSnapshot,
): Map<string, FChunkMesherCellSnapshot> {
  const cells = new Map<string, FChunkMesherCellSnapshot>();
  for (const cell of snapshot.cells) {
    cells.set(macroKey(cellWorldMacro(snapshot, cell)), cell);
  }
  return cells;
}

function isSnapshotMicroOccupied(
  snapshotCellsByWorldMacro: Map<string, FChunkMesherCellSnapshot>,
  worldMacro: FMacroCoord,
  micro: FMicroCoord,
): boolean | null {
  const cell = snapshotCellsByWorldMacro.get(macroKey(worldMacro));
  if (!cell) {
    return null;
  }

  if (cell.mode === EVoxelCellMode.SolidBlock) {
    return cell.materialId !== 0;
  }

  if (cell.mode === EVoxelCellMode.Refined) {
    const occupancy = cell.microOccupancyMask ?? 0n;
    return isMicroOccupied(occupancy, microLinearIndex(micro));
  }

  return false;
}

function cellWorldMacro(
  snapshot: FChunkMesherInputSnapshot,
  cell: FChunkMesherCellSnapshot,
): FMacroCoord {
  return {
    x: snapshot.chunkCoord.x * VoxelConstants.ChunkSizeX + cell.localMacroCoord.x,
    y: snapshot.chunkCoord.y * VoxelConstants.ChunkSizeY + cell.localMacroCoord.y,
    z: snapshot.chunkCoord.z * VoxelConstants.ChunkSizeZ + cell.localMacroCoord.z,
  };
}

function wrapNeighborMicro(
  macro: FMacroCoord,
  micro: FMicroCoord,
): { macro: FMacroCoord; micro: FMicroCoord } {
  const nextMacro = { ...macro };
  const nextMicro = { ...micro };

  if (nextMicro.x < 0) {
    nextMacro.x -= 1;
    nextMicro.x = VoxelConstants.MicroPerMacro - 1;
  } else if (nextMicro.x >= VoxelConstants.MicroPerMacro) {
    nextMacro.x += 1;
    nextMicro.x = 0;
  }

  if (nextMicro.y < 0) {
    nextMacro.y -= 1;
    nextMicro.y = VoxelConstants.MicroPerMacro - 1;
  } else if (nextMicro.y >= VoxelConstants.MicroPerMacro) {
    nextMacro.y += 1;
    nextMicro.y = 0;
  }

  if (nextMicro.z < 0) {
    nextMacro.z -= 1;
    nextMicro.z = VoxelConstants.MicroPerMacro - 1;
  } else if (nextMicro.z >= VoxelConstants.MicroPerMacro) {
    nextMacro.z += 1;
    nextMicro.z = 0;
  }

  return { macro: nextMacro, micro: nextMicro };
}

function macroKey(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function microLinearIndex(coord: FMicroCoord): number {
  return (
    coord.x +
    coord.y * VoxelConstants.MicroPerMacro +
    coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro
  );
}

function isMicroOccupied(occupancy: bigint, microIndex: number): boolean {
  return (occupancy & (1n << BigInt(microIndex))) !== 0n;
}

function microInBounds(coord: FMicroCoord): boolean {
  return (
    coord.x >= 0 &&
    coord.y >= 0 &&
    coord.z >= 0 &&
    coord.x < VoxelConstants.MicroPerMacro &&
    coord.y < VoxelConstants.MicroPerMacro &&
    coord.z < VoxelConstants.MicroPerMacro
  );
}
