import { VoxelMaterialId } from "../material/catalog";
import { EVoxelCellMode, EVoxelRotation } from "./core/types";
import { LocalPrefabRegistry, FULL_MACRO_OCCUPANCY_WORD } from "./prefab";
import { WorldStore } from "./worldStore";

function block(materialId: number) {
  return {
    materialId,
    stateFlags: 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

describe("LocalPrefabRegistry", () => {
  it("preloads built-in sphere, cylinder, and stairs prefabs", () => {
    const registry = new LocalPrefabRegistry();
    const prefabs = registry.list();

    expect(prefabs.map((prefab) => prefab.name)).toEqual([
      "builtin_cylinder",
      "builtin_sphere",
      "builtin_stairs",
    ]);
    expect(registry.get("builtin_sphere")?.definition.tags).toContain("builtin");
    expect(registry.get("builtin_cylinder")?.definition.occupancyWords[0]).not.toBe(0n);
    expect(registry.get("builtin_stairs")?.definition.allowedRotations).toContain(EVoxelRotation.Rot90);
    expect(registry.get("builtin_sphere")?.definition.partDefinitions[0]).toMatchObject({
      partId: "body",
      partTags: ["builtin", "sphere", "curved"],
      defaultAffordances: ["break", "freeze", "melt"],
    });
  });

  it("places built-in curved prefabs as refined micro occupancy without full macro fill", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();

    const result = registry.place("builtin_sphere", { x: 0, y: 0, z: 0 }, world);

    expect(result).toEqual({ ok: true, placed: 1, instanceId: 1 });
    const chunk = world.getChunk({ x: 0, y: 0, z: 0 });
    const header = chunk?.getHeaderAt({ x: 0, y: 0, z: 0 });
    const refined = chunk?.data.refinedCells[header?.payloadIndex ?? -1];
    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(refined?.microOccupancyMask).not.toBe(FULL_MACRO_OCCUPANCY_WORD);
    expect(refined?.prefabInstanceIds).toEqual([1]);
    expect(refined?.microPartIds.some((partId) => partId === 0)).toBe(true);
  });

  it("rotates built-in stairs micro occupancy when placing with rot90", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();

    registry.place("builtin_stairs", { x: 0, y: 0, z: 0 }, world, EVoxelRotation.Rot90);

    const chunk = world.getChunk({ x: 0, y: 0, z: 0 });
    const header = chunk?.getHeaderAt({ x: 0, y: 0, z: 0 });
    const refined = chunk?.data.refinedCells[header?.payloadIndex ?? -1];
    expect(refined?.microOccupancyMask).not.toBe(registry.get("builtin_stairs")?.definition.occupancyWords[0]);
    expect(hasMicro(refined?.microOccupancyMask ?? 0n, { x: 0, y: 3, z: 3 })).toBe(true);
    expect(refined?.microOccupancyMask).not.toBe(FULL_MACRO_OCCUPANCY_WORD);
  });

  it("captures a UE-style prefab definition from occupied macro cells", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 2, y: 3, z: 4 }, block(VoxelMaterialId.Stone));
    world.setNormalBlockWorld({ x: 3, y: 3, z: 4 }, block(VoxelMaterialId.Wood));

    const registry = new LocalPrefabRegistry();
    const prefab = registry.capture("bridge", { x: 2, y: 3, z: 4 }, { x: 3, y: 3, z: 4 }, world);

    expect(prefab.definition.prefabId).toBe("bridge");
    expect(prefab.definition.boundsInMacroCells).toEqual({ x: 2, y: 1, z: 1 });
    expect(prefab.definition.microResolution).toBe(4);
    expect(prefab.definition.occupancyWords).toEqual([
      FULL_MACRO_OCCUPANCY_WORD,
      FULL_MACRO_OCCUPANCY_WORD,
    ]);
    expect(prefab.definition.materialChannels).toEqual([
      VoxelMaterialId.Stone,
      VoxelMaterialId.Wood,
    ]);
    expect(prefab.definition.allowedRotations).toEqual([
      EVoxelRotation.Rot0,
      EVoxelRotation.Rot90,
      EVoxelRotation.Rot180,
      EVoxelRotation.Rot270,
    ]);
    expect(prefab.definition.boundarySignature).toHaveLength(6);
    expect(prefab.definition.partDefinitions).toHaveLength(2);
    expect(prefab.definition.partDefinitions[0]).toMatchObject({
      partId: "bridge_part_0",
      partTags: ["captured", "macro_block"],
      defaultAffordances: ["break", "move"],
    });
    expect(prefab.definition.microPartIds.filter((partId) => partId === 0)).toHaveLength(64);
    expect(prefab.definition.microPartIds.filter((partId) => partId === 1)).toHaveLength(64);
    expect(prefab.blocks).toHaveLength(2);
  });

  it("places a prefab as a chunk instance while materializing blocks for the current mesher", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Ice));
    source.setNormalBlockWorld({ x: 0, y: 1, z: 0 }, block(VoxelMaterialId.Wood));

    const registry = new LocalPrefabRegistry();
    registry.capture("pillar", { x: 0, y: 0, z: 0 }, { x: 0, y: 1, z: 0 }, source);

    const target = new WorldStore();
    const result = registry.place("pillar", { x: 16, y: 2, z: -1 }, target);

    expect(result).toEqual({ ok: true, placed: 2, instanceId: 1 });
    expect(target.getNormalBlockWorld({ x: 16, y: 2, z: -1 })?.materialId).toBe(VoxelMaterialId.Ice);
    expect(target.getNormalBlockWorld({ x: 16, y: 3, z: -1 })?.materialId).toBe(VoxelMaterialId.Wood);

    const ownerChunk = target.getChunk({ x: 1, y: 0, z: -1 });
    expect(ownerChunk?.data.prefabInstances).toHaveLength(1);
    expect(ownerChunk?.data.prefabInstances[0]).toMatchObject({
      instanceId: 1,
      prefabId: "pillar",
      anchorMicroCoord: { x: 64, y: 8, z: -4 },
      rotation: EVoxelRotation.Rot0,
      ownerChunk: { x: 1, y: 0, z: -1 },
      coveredMacroMin: { x: 16, y: 2, z: -1 },
      coveredMacroMax: { x: 16, y: 3, z: -1 },
      overrideSetIndex: 0,
    });

    const localHeader = ownerChunk?.getHeaderAt({ x: 0, y: 2, z: 15 });
    expect(localHeader?.mode).toBe(EVoxelCellMode.Refined);
    const refined = ownerChunk?.data.refinedCells[localHeader?.payloadIndex ?? -1];
    expect(refined?.prefabInstanceIds).toEqual([1]);
    expect(refined?.microOccupancyMask).toBe(FULL_MACRO_OCCUPANCY_WORD);
    expect(refined?.microPartIds.every((partId) => partId === 0)).toBe(true);
  });

  it("applies quantized yaw rotation when placing a prefab", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Stone));
    source.setNormalBlockWorld({ x: 1, y: 0, z: 0 }, block(VoxelMaterialId.Wood));

    const registry = new LocalPrefabRegistry();
    registry.capture("walkway", { x: 0, y: 0, z: 0 }, { x: 1, y: 0, z: 0 }, source);

    const target = new WorldStore();
    const result = registry.place("walkway", { x: 4, y: 1, z: 8 }, target, EVoxelRotation.Rot90);

    expect(result).toEqual({ ok: true, placed: 2, instanceId: 1 });
    expect(target.getNormalBlockWorld({ x: 4, y: 1, z: 8 })?.materialId).toBe(VoxelMaterialId.Stone);
    expect(target.getNormalBlockWorld({ x: 4, y: 1, z: 9 })?.materialId).toBe(VoxelMaterialId.Wood);
    expect(target.getNormalBlockWorld({ x: 5, y: 1, z: 8 })).toBeNull();

    const ownerChunk = target.getChunk({ x: 0, y: 0, z: 0 });
    expect(ownerChunk?.data.prefabInstances[0]).toMatchObject({
      rotation: EVoxelRotation.Rot90,
      coveredMacroMin: { x: 4, y: 1, z: 8 },
      coveredMacroMax: { x: 4, y: 1, z: 9 },
    });
  });

  it("rejects prefab placement that would overwrite existing world truth", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Stone));

    const registry = new LocalPrefabRegistry();
    registry.capture("single", { x: 0, y: 0, z: 0 }, { x: 0, y: 0, z: 0 }, source);

    const target = new WorldStore();
    target.setNormalBlockWorld({ x: 5, y: 0, z: 0 }, block(VoxelMaterialId.Dirt));

    const result = registry.place("single", { x: 5, y: 0, z: 0 }, target);

    expect(result).toEqual({ ok: false, placed: 0, conflict: true });
    expect(target.getNormalBlockWorld({ x: 5, y: 0, z: 0 })?.materialId).toBe(VoxelMaterialId.Dirt);
    expect(target.getChunk({ x: 0, y: 0, z: 0 })?.data.prefabInstances).toHaveLength(0);
    expect(target.editStats.conflicts).toBe(1);
  });

  it("records a cross-chunk prefab instance in every covered chunk", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Stone));
    source.setNormalBlockWorld({ x: 1, y: 0, z: 0 }, block(VoxelMaterialId.Wood));

    const registry = new LocalPrefabRegistry();
    registry.capture("cross_chunk", { x: 0, y: 0, z: 0 }, { x: 1, y: 0, z: 0 }, source);

    const target = new WorldStore();
    const result = registry.place("cross_chunk", { x: 15, y: 0, z: 0 }, target);

    expect(result).toEqual({ ok: true, placed: 2, instanceId: 1 });
    expect(target.getChunk({ x: 0, y: 0, z: 0 })?.data.prefabInstances).toHaveLength(1);
    expect(target.getChunk({ x: 1, y: 0, z: 0 })?.data.prefabInstances).toHaveLength(1);
    expect(target.getChunk({ x: 1, y: 0, z: 0 })?.data.prefabInstances[0]?.ownerChunk).toEqual({
      x: 0,
      y: 0,
      z: 0,
    });
  });
});

function hasMicro(mask: bigint, coord: { x: number; y: number; z: number }): boolean {
  const index = coord.x + (coord.y * 4) + (coord.z * 16);
  return (mask & (1n << BigInt(index))) !== 0n;
}
