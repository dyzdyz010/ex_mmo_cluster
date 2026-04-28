import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import type { FMacroCoord, FMicroCoord } from "../voxel/core/types";
import type { PrefabRasterCell } from "../voxel/prefab";

interface MicroGridCorner {
  x: number;
  y: number;
  z: number;
}

export interface PrefabRasterMicroWireGeometry {
  positions: number[];
  occupiedSlotCount: number;
  wireSegmentCount: number;
}

export function buildPrefabRasterMicroWireGeometry(
  cells: readonly PrefabRasterCell[],
): PrefabRasterMicroWireGeometry {
  const edges = new Map<string, [MicroGridCorner, MicroGridCorner]>();
  let occupiedSlotCount = 0;

  for (const cell of cells) {
    for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
      for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
        for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
          const index =
            x +
            y * VoxelConstants.MicroPerMacro +
            z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro;
          if ((cell.microOccupancyMask & (1n << BigInt(index))) === 0n) {
            continue;
          }
          occupiedSlotCount += 1;
          appendMicroSlotWireEdges(edges, cell.macro, { x, y, z });
        }
      }
    }
  }

  const positions: number[] = [];
  for (const [from, to] of edges.values()) {
    appendMicroGridEdgeWorldPositions(positions, from, to);
  }

  return {
    positions,
    occupiedSlotCount,
    wireSegmentCount: edges.size,
  };
}

function appendMicroSlotWireEdges(
  edges: Map<string, [MicroGridCorner, MicroGridCorner]>,
  macro: FMacroCoord,
  micro: FMicroCoord,
): void {
  const base = {
    x: macro.x * VoxelConstants.MicroPerMacro + micro.x,
    y: macro.y * VoxelConstants.MicroPerMacro + micro.y,
    z: macro.z * VoxelConstants.MicroPerMacro + micro.z,
  };
  const corners: MicroGridCorner[] = [
    { x: base.x, y: base.y, z: base.z },
    { x: base.x + 1, y: base.y, z: base.z },
    { x: base.x + 1, y: base.y + 1, z: base.z },
    { x: base.x, y: base.y + 1, z: base.z },
    { x: base.x, y: base.y, z: base.z + 1 },
    { x: base.x + 1, y: base.y, z: base.z + 1 },
    { x: base.x + 1, y: base.y + 1, z: base.z + 1 },
    { x: base.x, y: base.y + 1, z: base.z + 1 },
  ];
  const edgeIndices: Array<[number, number]> = [
    [0, 1],
    [1, 2],
    [2, 3],
    [3, 0],
    [4, 5],
    [5, 6],
    [6, 7],
    [7, 4],
    [0, 4],
    [1, 5],
    [2, 6],
    [3, 7],
  ];

  for (const [fromIndex, toIndex] of edgeIndices) {
    addCanonicalMicroGridEdge(edges, corners[fromIndex]!, corners[toIndex]!);
  }
}

function addCanonicalMicroGridEdge(
  edges: Map<string, [MicroGridCorner, MicroGridCorner]>,
  a: MicroGridCorner,
  b: MicroGridCorner,
): void {
  const [from, to] = compareMicroGridCorners(a, b) <= 0 ? [a, b] : [b, a];
  edges.set(`${microGridCornerKey(from)}|${microGridCornerKey(to)}`, [from, to]);
}

function compareMicroGridCorners(a: MicroGridCorner, b: MicroGridCorner): number {
  if (a.x !== b.x) {
    return a.x - b.x;
  }
  if (a.y !== b.y) {
    return a.y - b.y;
  }
  return a.z - b.z;
}

function microGridCornerKey(corner: MicroGridCorner): string {
  return `${corner.x},${corner.y},${corner.z}`;
}

function appendMicroGridEdgeWorldPositions(
  positions: number[],
  from: MicroGridCorner,
  to: MicroGridCorner,
): void {
  positions.push(
    microGridCornerWorldAxis(from.x),
    microGridCornerWorldAxis(from.y),
    microGridCornerWorldAxis(from.z),
    microGridCornerWorldAxis(to.x),
    microGridCornerWorldAxis(to.y),
    microGridCornerWorldAxis(to.z),
  );
}

function microGridCornerWorldAxis(value: number): number {
  return (value / VoxelConstants.MicroPerMacro) * MacroWorldSize;
}
