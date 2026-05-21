import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import type { FMacroCoord, FMicroCoord } from "../voxel/core/types";
import type { PrefabRasterCell } from "../voxel/prefab";

interface MicroGridCorner {
  x: number;
  y: number;
  z: number;
}

interface EdgeAccumulator {
  edge: [MicroGridCorner, MicroGridCorner];
  normalCounts: Map<string, number>;
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

export function buildPrefabRasterSurfaceOutlineGeometry(
  cells: readonly PrefabRasterCell[],
): PrefabRasterMicroWireGeometry {
  const occupied = collectOccupiedMicroSlots(cells);
  const edges = new Map<string, EdgeAccumulator>();

  for (const key of occupied) {
    const slot = parseMicroGridCornerKey(key);
    for (const face of exposedFacesForSlot(slot, occupied)) {
      appendExposedFaceEdges(edges, face.normalKey, face.corners);
    }
  }

  const positions: number[] = [];
  let wireSegmentCount = 0;
  for (const entry of edges.values()) {
    const totalFaceCount = [...entry.normalCounts.values()].reduce((sum, count) => sum + count, 0);
    if (totalFaceCount > 1 && entry.normalCounts.size === 1) {
      continue;
    }
    appendMicroGridEdgeWorldPositions(positions, entry.edge[0], entry.edge[1]);
    wireSegmentCount += 1;
  }

  return {
    positions,
    occupiedSlotCount: occupied.size,
    wireSegmentCount,
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

function collectOccupiedMicroSlots(cells: readonly PrefabRasterCell[]): Set<string> {
  const occupied = new Set<string>();
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
          occupied.add(
            microGridCornerKey({
              x: cell.macro.x * VoxelConstants.MicroPerMacro + x,
              y: cell.macro.y * VoxelConstants.MicroPerMacro + y,
              z: cell.macro.z * VoxelConstants.MicroPerMacro + z,
            }),
          );
        }
      }
    }
  }
  return occupied;
}

function exposedFacesForSlot(
  slot: MicroGridCorner,
  occupied: Set<string>,
): Array<{ normalKey: string; corners: MicroGridCorner[] }> {
  const { x, y, z } = slot;
  return [
    {
      normalKey: "1,0,0",
      neighbor: { x: x + 1, y, z },
      corners: [
        { x: x + 1, y, z },
        { x: x + 1, y: y + 1, z },
        { x: x + 1, y: y + 1, z: z + 1 },
        { x: x + 1, y, z: z + 1 },
      ],
    },
    {
      normalKey: "-1,0,0",
      neighbor: { x: x - 1, y, z },
      corners: [
        { x, y, z },
        { x, y, z: z + 1 },
        { x, y: y + 1, z: z + 1 },
        { x, y: y + 1, z },
      ],
    },
    {
      normalKey: "0,1,0",
      neighbor: { x, y: y + 1, z },
      corners: [
        { x, y: y + 1, z },
        { x, y: y + 1, z: z + 1 },
        { x: x + 1, y: y + 1, z: z + 1 },
        { x: x + 1, y: y + 1, z },
      ],
    },
    {
      normalKey: "0,-1,0",
      neighbor: { x, y: y - 1, z },
      corners: [
        { x, y, z },
        { x: x + 1, y, z },
        { x: x + 1, y, z: z + 1 },
        { x, y, z: z + 1 },
      ],
    },
    {
      normalKey: "0,0,1",
      neighbor: { x, y, z: z + 1 },
      corners: [
        { x, y, z: z + 1 },
        { x: x + 1, y, z: z + 1 },
        { x: x + 1, y: y + 1, z: z + 1 },
        { x, y: y + 1, z: z + 1 },
      ],
    },
    {
      normalKey: "0,0,-1",
      neighbor: { x, y, z: z - 1 },
      corners: [
        { x, y, z },
        { x, y: y + 1, z },
        { x: x + 1, y: y + 1, z },
        { x: x + 1, y, z },
      ],
    },
  ].flatMap((face) =>
    occupied.has(microGridCornerKey(face.neighbor))
      ? []
      : [{ normalKey: face.normalKey, corners: face.corners }],
  );
}

function appendExposedFaceEdges(
  edges: Map<string, EdgeAccumulator>,
  normalKey: string,
  corners: MicroGridCorner[],
): void {
  const edgeIndices: Array<[number, number]> = [
    [0, 1],
    [1, 2],
    [2, 3],
    [3, 0],
  ];
  for (const [fromIndex, toIndex] of edgeIndices) {
    addCanonicalExposedFaceEdge(edges, corners[fromIndex]!, corners[toIndex]!, normalKey);
  }
}

function addCanonicalExposedFaceEdge(
  edges: Map<string, EdgeAccumulator>,
  a: MicroGridCorner,
  b: MicroGridCorner,
  normalKey: string,
): void {
  const [from, to] = compareMicroGridCorners(a, b) <= 0 ? [a, b] : [b, a];
  const key = `${microGridCornerKey(from)}|${microGridCornerKey(to)}`;
  const existing = edges.get(key);
  if (existing) {
    existing.normalCounts.set(normalKey, (existing.normalCounts.get(normalKey) ?? 0) + 1);
    return;
  }
  edges.set(key, {
    edge: [from, to],
    normalCounts: new Map([[normalKey, 1]]),
  });
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

function parseMicroGridCornerKey(key: string): MicroGridCorner {
  const [x = "0", y = "0", z = "0"] = key.split(",");
  return {
    x: Number.parseInt(x, 10) || 0,
    y: Number.parseInt(y, 10) || 0,
    z: Number.parseInt(z, 10) || 0,
  };
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
