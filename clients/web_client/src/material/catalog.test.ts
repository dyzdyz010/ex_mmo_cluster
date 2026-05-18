import { describe, expect, it } from "vitest";
import {
  getMaterialDefinition,
  listMaterialDefinitions,
  parseMaterialIdOrName,
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
});
