import { VoxelMaterialId } from "../material/catalog";
import { VoxelConstants } from "./core/constants";
import { EVoxelCellMode, EVoxelRotation } from "./core/types";
import { MicroGridSlotCount } from "./microgrid/governance";
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
    expect(registry.get("builtin_stairs")?.definition.allowedRotations).toContain(
      EVoxelRotation.Rot90,
    );
    expect(registry.get("builtin_sphere")?.definition.partDefinitions[0]).toMatchObject({
      partId: "body",
      partTags: ["builtin", "sphere", "curved"],
      defaultAffordances: ["break", "freeze", "melt"],
    });
  });

  it("uses high-resolution micro occupancy for curved built-in prefabs", () => {
    const registry = new LocalPrefabRegistry();
    const sphere = registry.get("builtin_sphere");
    const cylinder = registry.get("builtin_cylinder");

    expect(VoxelConstants.MicroPerMacro).toBeGreaterThanOrEqual(8);
    expect(sphere?.definition.microResolution).toBe(VoxelConstants.MicroPerMacro);
    expect(cylinder?.definition.microResolution).toBe(VoxelConstants.MicroPerMacro);
    expect(sphere?.definition.microPartIds).toHaveLength(MicroGridSlotCount);
    expect(cylinder?.definition.microPartIds).toHaveLength(MicroGridSlotCount);
    expect(countOccupied(sphere?.definition.occupancyWords[0] ?? 0n)).toBeGreaterThan(200);
    expect(countOccupied(cylinder?.definition.occupancyWords[0] ?? 0n)).toBeGreaterThan(300);
    expect(sphere?.definition.occupancyWords[0]).not.toBe(FULL_MACRO_OCCUPANCY_WORD);
    expect(cylinder?.definition.occupancyWords[0]).not.toBe(FULL_MACRO_OCCUPANCY_WORD);
  });

  it("generates boundary face masks and authored sockets for built-in stairs", () => {
    const registry = new LocalPrefabRegistry();
    const stairs = registry.get("builtin_stairs");

    expect(typeof stairs?.definition.boundaryFaceMasks?.negX).toBe("bigint");
    expect(typeof stairs?.definition.boundaryFaceMasks?.posX).toBe("bigint");
    expect(typeof stairs?.definition.boundaryFaceMasks?.negY).toBe("bigint");
    expect(typeof stairs?.definition.boundaryFaceMasks?.posY).toBe("bigint");
    expect(typeof stairs?.definition.boundaryFaceMasks?.negZ).toBe("bigint");
    expect(typeof stairs?.definition.boundaryFaceMasks?.posZ).toBe("bigint");
    expect(countOccupied(stairs?.definition.boundaryFaceMasks?.posX ?? 0n)).toBe(64);
    expect(countOccupied(stairs?.definition.boundaryFaceMasks?.negX ?? 0n)).toBe(8);
    expect(stairs?.definition.sockets).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          socketId: "stairs_high_pos_x",
          snapClass: "stairs-rise",
          allowedPeerClasses: ["stairs-rise"],
          localMicroCoord: {
            x: VoxelConstants.MicroPerMacro,
            y: VoxelConstants.MicroPerMacro - 1,
            z: 4,
          },
          normal: { x: 1, y: 0, z: 0 },
        }),
        expect.objectContaining({
          socketId: "stairs_low_neg_x",
          snapClass: "stairs-rise",
          allowedPeerClasses: ["stairs-rise"],
          localMicroCoord: { x: 0, y: 0, z: 4 },
          normal: { x: -1, y: 0, z: 0 },
        }),
      ]),
    );
  });

  it("previews a socket snap with a world micro anchor and affected macro cells", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();
    registry.place("builtin_stairs", { x: 0, y: 0, z: 0 }, world);

    const preview = registry.previewSocketSnap(
      {
        prefabName: "builtin_stairs",
        targetInstanceId: 1,
        targetSocketId: "stairs_high_pos_x",
        incomingSocketId: "stairs_low_neg_x",
        rotation: EVoxelRotation.Rot0,
      },
      world,
    );

    expect(preview).toMatchObject({
      ok: true,
      prefabId: "builtin_stairs",
      targetInstanceId: 1,
      targetSocketId: "stairs_high_pos_x",
      socketId: "stairs_low_neg_x",
      anchorMicroCoord: {
        x: VoxelConstants.MicroPerMacro,
        y: VoxelConstants.MicroPerMacro - 1,
        z: 0,
      },
      overlapSlots: 0,
    });
    expect(preview.affectedMacroCount).toBeGreaterThan(1);
    expect(preview.incomingOccupiedSlots).toBeGreaterThan(0);
    expect(preview.cells.some((cell) => cell.macro.y === 1)).toBe(true);
  });

  it("commits socket snaps transactionally while preserving disjoint refined slots", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();
    world.setMicroBlockWorld(
      { x: 1, y: 0, z: 0 },
      { x: 0, y: 0, z: 0 },
      block(VoxelMaterialId.Dirt),
    );
    registry.place("builtin_stairs", { x: 0, y: 0, z: 0 }, world);

    const result = registry.placeSocketSnap(
      {
        prefabName: "builtin_stairs",
        targetInstanceId: 1,
        targetSocketId: "stairs_high_pos_x",
        incomingSocketId: "stairs_low_neg_x",
        rotation: EVoxelRotation.Rot0,
      },
      world,
    );

    expect(result.ok).toBe(true);
    expect(result.instanceId).toBe(2);
    expect(world.getMicroBlockWorld({ x: 1, y: 0, z: 0 }, { x: 0, y: 0, z: 0 })?.materialId).toBe(
      VoxelMaterialId.Dirt,
    );
    expect(world.getMicroBlockWorld({ x: 1, y: 0, z: 0 }, { x: 0, y: 7, z: 0 })?.materialId).toBe(
      VoxelMaterialId.Wood,
    );

    const rejected = registry.placeSocketSnap(
      {
        prefabName: "builtin_stairs",
        targetInstanceId: 1,
        targetSocketId: "stairs_high_pos_x",
        incomingSocketId: "stairs_low_neg_x",
        rotation: EVoxelRotation.Rot0,
      },
      world,
    );

    expect(rejected).toMatchObject({
      ok: false,
      placed: 0,
      conflict: true,
      rejectReason: "micro_overlap",
    });
    expect(world.editStats.conflicts).toBe(1);
    expect(world.getChunk({ x: 0, y: 0, z: 0 })?.data.prefabInstances).toHaveLength(2);
    expect(
      world
        .getChunk({ x: 0, y: 0, z: 0 })
        ?.data.prefabInstances.map((instance) => instance.instanceId),
    ).toEqual([1, 2]);
  });

  it("previews socket-free micro boundary snaps for built-in sphere prefabs", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();
    registry.place("builtin_sphere", { x: 0, y: 0, z: 0 }, world);

    const preview = registry.previewBoundarySnap(
      {
        prefabName: "builtin_sphere",
        hitMacro: { x: 0, y: 0, z: 0 },
        hitMicro: {
          x: VoxelConstants.MicroPerMacro - 1,
          y: Math.floor(VoxelConstants.MicroPerMacro / 2),
          z: Math.floor(VoxelConstants.MicroPerMacro / 2),
        },
        faceNormal: { x: 1, y: 0, z: 0 },
        rotation: EVoxelRotation.Rot0,
        searchRadius: 0,
      },
      world,
    );

    expect(registry.get("builtin_sphere")?.definition.sockets).toEqual([]);
    expect(preview).toMatchObject({
      ok: true,
      prefabId: "builtin_sphere",
      anchorMicroCoord: {
        x: VoxelConstants.MicroPerMacro,
        y: 0,
        z: 0,
      },
      overlapSlots: 0,
    });
    expect(preview.contactSlots).toBeGreaterThan(0);
    expect(preview.affectedMacroCount).toBeGreaterThan(0);
    expect(preview.incomingOccupiedSlots).toBeGreaterThan(0);
    expect(preview.cells).not.toHaveLength(0);
  });

  it("anchors boundary snap candidates to the aimed adjacent micro slot for responsive stair placement", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();
    registry.place("builtin_stairs", { x: 20, y: 10, z: 20 }, world);

    const preview = registry.previewBoundarySnap(
      {
        prefabName: "builtin_stairs",
        hitMacro: { x: 20, y: 10, z: 20 },
        hitMicro: { x: 3, y: 3, z: 4 },
        anchorMicroCoord: { x: 20 * VoxelConstants.MicroPerMacro + 3, y: 84, z: 164 },
        faceNormal: { x: 0, y: 1, z: 0 },
        rotation: EVoxelRotation.Rot0,
      },
      world,
    );

    expect(preview).toMatchObject({
      ok: true,
      prefabId: "builtin_stairs",
      anchorMicroCoord: { x: 156, y: 84, z: 160 },
      overlapSlots: 0,
      debug: expect.objectContaining({
        mode: "anchored",
        incomingBoundaryCount: 64,
        targetBoundaryCount: 1,
      }),
    });
    expect(preview.debug?.anchorCandidateCount).toBeLessThanOrEqual(64);
    expect(preview.debug?.rasterizeCount).toBeLessThanOrEqual(64);
    expect(preview.contactSlots).toBeGreaterThan(0);
    expect(preview.cells.length).toBeGreaterThan(0);
  });

  it("commits micro boundary snaps and rejects overlap candidates transactionally", () => {
    const registry = new LocalPrefabRegistry();
    const world = new WorldStore();
    registry.place("builtin_sphere", { x: 0, y: 0, z: 0 }, world);

    const result = registry.placeBoundarySnap(
      {
        prefabName: "builtin_sphere",
        hitMacro: { x: 0, y: 0, z: 0 },
        hitMicro: {
          x: VoxelConstants.MicroPerMacro - 1,
          y: Math.floor(VoxelConstants.MicroPerMacro / 2),
          z: Math.floor(VoxelConstants.MicroPerMacro / 2),
        },
        faceNormal: { x: 1, y: 0, z: 0 },
        rotation: EVoxelRotation.Rot0,
        searchRadius: 0,
      },
      world,
    );

    expect(result).toMatchObject({
      ok: true,
      placed: expect.any(Number),
      instanceId: 2,
      preview: expect.objectContaining({
        contactSlots: expect.any(Number),
        overlapSlots: 0,
      }),
    });
    expect(result.preview?.contactSlots).toBeGreaterThan(0);

    world.setMicroBlockWorld(
      { x: 0, y: 0, z: 1 },
      {
        x: Math.floor(VoxelConstants.MicroPerMacro / 2),
        y: Math.floor(VoxelConstants.MicroPerMacro / 2),
        z: 1,
      },
      block(VoxelMaterialId.Dirt),
    );

    const rejected = registry.placeBoundarySnap(
      {
        prefabName: "builtin_sphere",
        hitMacro: { x: 0, y: 0, z: 0 },
        hitMicro: {
          x: Math.floor(VoxelConstants.MicroPerMacro / 2),
          y: Math.floor(VoxelConstants.MicroPerMacro / 2),
          z: VoxelConstants.MicroPerMacro - 1,
        },
        faceNormal: { x: 0, y: 0, z: 1 },
        rotation: EVoxelRotation.Rot0,
        searchRadius: 0,
      },
      world,
    );

    expect(rejected).toMatchObject({
      ok: false,
      placed: 0,
      conflict: true,
      rejectReason: "micro_overlap",
    });
    expect(world.editStats.conflicts).toBe(1);
    expect(
      world
        .getChunk({ x: 0, y: 0, z: 0 })
        ?.data.prefabInstances.map((instance) => instance.instanceId),
    ).toEqual([1, 2]);
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
    expect(refined?.microOccupancyMask).not.toBe(
      registry.get("builtin_stairs")?.definition.occupancyWords[0],
    );
    expect(
      hasMicro(refined?.microOccupancyMask ?? 0n, {
        x: 0,
        y: VoxelConstants.MicroPerMacro - 1,
        z: VoxelConstants.MicroPerMacro - 1,
      }),
    ).toBe(true);
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
    expect(prefab.definition.microResolution).toBe(VoxelConstants.MicroPerMacro);
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
    expect(prefab.definition.microPartIds.filter((partId) => partId === 0)).toHaveLength(
      MicroGridSlotCount,
    );
    expect(prefab.definition.microPartIds.filter((partId) => partId === 1)).toHaveLength(
      MicroGridSlotCount,
    );
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
    expect(target.getNormalBlockWorld({ x: 16, y: 2, z: -1 })?.materialId).toBe(
      VoxelMaterialId.Ice,
    );
    expect(target.getNormalBlockWorld({ x: 16, y: 3, z: -1 })?.materialId).toBe(
      VoxelMaterialId.Wood,
    );

    const ownerChunk = target.getChunk({ x: 1, y: 0, z: -1 });
    expect(ownerChunk?.data.prefabInstances).toHaveLength(1);
    expect(ownerChunk?.data.prefabInstances[0]).toMatchObject({
      instanceId: 1,
      prefabId: "pillar",
      anchorMicroCoord: {
        x: 16 * VoxelConstants.MicroPerMacro,
        y: 2 * VoxelConstants.MicroPerMacro,
        z: -1 * VoxelConstants.MicroPerMacro,
      },
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
    expect(target.getNormalBlockWorld({ x: 4, y: 1, z: 8 })?.materialId).toBe(
      VoxelMaterialId.Stone,
    );
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
  const index =
    coord.x +
    coord.y * VoxelConstants.MicroPerMacro +
    coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro;
  return (mask & (1n << BigInt(index))) !== 0n;
}

function countOccupied(mask: bigint): number {
  let count = 0;
  for (let index = 0; index < MicroGridSlotCount; index += 1) {
    if ((mask & (1n << BigInt(index))) !== 0n) {
      count += 1;
    }
  }
  return count;
}
