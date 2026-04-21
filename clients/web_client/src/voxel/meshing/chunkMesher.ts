import { MacroWorldSize } from "../core/constants";
import type { FMacroCoord } from "../core/types";
import { buildBlockStateView, resolveVoxelVisual } from "../../material/catalog";
import type { FChunkMesherInputSnapshot } from "./types";

export interface ChunkMeshBuildData {
  positions: number[];
  normals: number[];
  colors: number[];
  indices: number[];
  solidBlockCount: number;
  triangleCount: number;
}

interface ChunkWorldLookup {
  isSolidWorldMacroCoord(coord: FMacroCoord): boolean;
}

interface FaceDefinition {
  normal: FMacroCoord;
  corners: readonly [number, number, number][];
}

const FACE_DEFINITIONS: readonly FaceDefinition[] = [
  { normal: { x: 1, y: 0, z: 0 }, corners: [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]] },
  { normal: { x: -1, y: 0, z: 0 }, corners: [[0, 0, 1], [0, 1, 1], [0, 1, 0], [0, 0, 0]] },
  { normal: { x: 0, y: 1, z: 0 }, corners: [[0, 1, 1], [1, 1, 1], [1, 1, 0], [0, 1, 0]] },
  { normal: { x: 0, y: -1, z: 0 }, corners: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]] },
  { normal: { x: 0, y: 0, z: 1 }, corners: [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]] },
  { normal: { x: 0, y: 0, z: -1 }, corners: [[1, 0, 0], [0, 0, 0], [0, 1, 0], [1, 1, 0]] },
] as const;

export function buildChunkMeshData(snapshot: FChunkMesherInputSnapshot, lookup: ChunkWorldLookup): ChunkMeshBuildData {
  const positions: number[] = [];
  const normals: number[] = [];
  const colors: number[] = [];
  const indices: number[] = [];

  let solidBlockCount = 0;
  for (const cell of snapshot.cells) {
    if (cell.mode !== 1 || cell.materialId === 0) {
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
      if (lookup.isSolidWorldMacroCoord(neighbor)) {
        continue;
      }

      const baseVertex = positions.length / 3;
      for (const corner of face.corners) {
        positions.push(
          (cell.localMacroCoord.x + corner[0]) * MacroWorldSize,
          (cell.localMacroCoord.y + corner[1]) * MacroWorldSize,
          (cell.localMacroCoord.z + corner[2]) * MacroWorldSize,
        );
        normals.push(face.normal.x, face.normal.y, face.normal.z);
        colors.push(visual.displayColor.r, visual.displayColor.g, visual.displayColor.b);
      }

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
    indices,
    solidBlockCount,
    triangleCount: indices.length / 3,
  };
}
