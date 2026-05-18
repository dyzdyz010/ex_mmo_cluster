import { describe, expect, it } from "vitest";
import {
  materialAtlasTexelRgba,
  VoxelMaterialAtlasColumns,
  VoxelMaterialAtlasTileSize,
} from "./atlas";
import { listMaterialDefinitions, VoxelMaterialId } from "./catalog";

describe("material atlas", () => {
  it("renders power blocks with warm glowstone-like highlights", () => {
    const { x, y } = tileOrigin(VoxelMaterialId.PowerBlock);
    const center = materialAtlasTexelRgba(
      x + Math.floor(VoxelMaterialAtlasTileSize / 2),
      y + Math.floor(VoxelMaterialAtlasTileSize / 2),
    );
    const samples = [
      materialAtlasTexelRgba(x + 1, y + 1),
      materialAtlasTexelRgba(x + 4, y + 5),
      center,
      materialAtlasTexelRgba(x + 11, y + 7),
      materialAtlasTexelRgba(x + 14, y + 14),
    ];

    expect(center[0]).toBeGreaterThanOrEqual(230);
    expect(center[1]).toBeGreaterThanOrEqual(235);
    expect(center[2]).toBeLessThan(190);
    expect(Math.max(...samples.map(luminance))).toBeGreaterThanOrEqual(238);
    expect(new Set(samples.map((sample) => sample.slice(0, 3).join(","))).size).toBeGreaterThan(3);
  });
});

function tileOrigin(materialId: number): { x: number; y: number } {
  const index = listMaterialDefinitions().findIndex(
    (definition) => definition.materialId === materialId,
  );
  if (index < 0) {
    throw new Error(`missing material ${materialId}`);
  }
  return {
    x: (index % VoxelMaterialAtlasColumns) * VoxelMaterialAtlasTileSize,
    y: Math.floor(index / VoxelMaterialAtlasColumns) * VoxelMaterialAtlasTileSize,
  };
}

function luminance([r, g, b]: readonly [number, number, number, number]): number {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
