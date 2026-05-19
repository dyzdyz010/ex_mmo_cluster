import { describe, expect, it } from "vitest";
import {
  buildBlockStateView,
  getMaterialDefinition,
  listMaterialDefinitions,
  parseMaterialIdOrName,
  resolveVoxelVisual,
  VoxelMaterialId,
} from "./catalog";

describe("voxel material catalog", () => {
  it("exposes the physical power block as a placeable material", () => {
    expect(VoxelMaterialId.PowerBlock).toBe(6);
    expect(parseMaterialIdOrName("power_block")).toBe(VoxelMaterialId.PowerBlock);
    expect(parseMaterialIdOrName("6")).toBe(VoxelMaterialId.PowerBlock);
    expect(getMaterialDefinition(VoxelMaterialId.PowerBlock)).toMatchObject({
      materialId: VoxelMaterialId.PowerBlock,
      name: "power_block",
      flammable: false,
    });
    expect(listMaterialDefinitions().map((definition) => definition.name)).toContain("power_block");
  });

  it("does not tint the block body for plain heat", () => {
    const base = getMaterialDefinition(VoxelMaterialId.Stone);
    const visual = resolveVoxelVisual(
      buildBlockStateView({
        materialId: VoxelMaterialId.Stone,
        stateFlags: 0,
        health: base.maxHealth,
        temperatureDelta: 80,
        moistureDelta: 0,
      }),
    );

    expect(visual.displayColor.getHex()).toBe(base.baseColorHex);
  });
});
