import { describe, expect, it } from "vitest";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import type { FMicroCoord } from "../voxel/core/types";
import type { PrefabRasterCell } from "../voxel/prefab";
import {
  buildPrefabRasterMicroWireGeometry,
  buildPrefabRasterSurfaceOutlineGeometry,
} from "./prefabPreviewGeometry";

describe("prefab raster outline geometry", () => {
  it("reduces a solid micro slab to its tight exterior outline instead of surface grid lines", () => {
    const cells = [
      rasterCell([
        { x: 0, y: 0, z: 0 },
        { x: 1, y: 0, z: 0 },
        { x: 0, y: 1, z: 0 },
        { x: 1, y: 1, z: 0 },
      ]),
    ];

    const denseWire = buildPrefabRasterMicroWireGeometry(cells);
    const surfaceOutline = buildPrefabRasterSurfaceOutlineGeometry(cells);

    expect(surfaceOutline.occupiedSlotCount).toBe(4);
    expect(surfaceOutline.wireSegmentCount).toBe(20);
    expect(denseWire.wireSegmentCount).toBeGreaterThan(surfaceOutline.wireSegmentCount);
  });

  it("keeps concave exterior edges so an L-shaped prefab does not collapse to a bounding box", () => {
    const outline = buildPrefabRasterSurfaceOutlineGeometry([
      rasterCell([
        { x: 0, y: 0, z: 0 },
        { x: 1, y: 0, z: 0 },
        { x: 0, y: 1, z: 0 },
      ]),
    ]);

    expect(outline.wireSegmentCount).toBeGreaterThan(12);
    expect(hasSegment(outline.positions, { x: 1, y: 1, z: 0 }, { x: 1, y: 1, z: 1 })).toBe(true);
  });
});

function rasterCell(slots: FMicroCoord[]): PrefabRasterCell {
  return {
    macro: { x: 0, y: 0, z: 0 },
    microOccupancyMask: slots.reduce((mask, slot) => mask | (1n << BigInt(microIndex(slot))), 0n),
    microMaterialIds: [],
    microStateFlags: [],
    microPartIds: [],
  };
}

function microIndex(coord: FMicroCoord): number {
  return (
    coord.x +
    coord.y * VoxelConstants.MicroPerMacro +
    coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro
  );
}

function hasSegment(positions: readonly number[], a: FMicroCoord, b: FMicroCoord): boolean {
  const from = microGridCornerWorld(a);
  const to = microGridCornerWorld(b);
  for (let index = 0; index < positions.length; index += 6) {
    const p0 = positions.slice(index, index + 3);
    const p1 = positions.slice(index + 3, index + 6);
    if ((samePoint(p0, from) && samePoint(p1, to)) || (samePoint(p0, to) && samePoint(p1, from))) {
      return true;
    }
  }
  return false;
}

function microGridCornerWorld(coord: FMicroCoord): [number, number, number] {
  return [cornerAxis(coord.x), cornerAxis(coord.y), cornerAxis(coord.z)];
}

function cornerAxis(value: number): number {
  return (value / VoxelConstants.MicroPerMacro) * MacroWorldSize;
}

function samePoint(values: number[], expected: readonly number[]): boolean {
  return (
    values.length === expected.length && values.every((value, index) => value === expected[index])
  );
}
