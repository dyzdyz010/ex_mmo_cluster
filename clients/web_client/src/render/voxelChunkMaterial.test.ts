import { MeshStandardMaterial } from "three";
import { describe, expect, it } from "vitest";
import { VoxelMaterialId } from "../material/catalog";
import { createVoxelChunkMaterial } from "./voxelChunkMaterial";

describe("voxel chunk material", () => {
  it("adds a shader-local glow only for the power block atlas tile", () => {
    const material = createVoxelChunkMaterial();

    expect(material).toBeInstanceOf(MeshStandardMaterial);
    expect(material.vertexColors).toBe(true);
    expect(material.userData["powerBlockGlow"]).toMatchObject({
      materialId: VoxelMaterialId.PowerBlock,
      atlasTile: expect.objectContaining({ columns: 4, tileSize: 16 }),
    });
    expect(material.customProgramCacheKey()).toContain("power-block-glow");

    const shader = {
      uniforms: {},
      vertexShader: "",
      fragmentShader: [
        "void main() {",
        "  vec3 totalEmissiveRadiance = emissive;",
        "  #include <map_fragment>",
        "  #include <emissivemap_fragment>",
        "}",
      ].join("\n"),
    };

    material.onBeforeCompile(
      shader as Parameters<MeshStandardMaterial["onBeforeCompile"]>[0],
      {} as Parameters<MeshStandardMaterial["onBeforeCompile"]>[1],
    );

    expect(shader.fragmentShader).toContain("powerBlockGlowMask");
    expect(shader.fragmentShader).toContain("totalEmissiveRadiance += powerBlockGlowColor");
    expect(shader.fragmentShader).toContain("vMapUv");
  });
});
