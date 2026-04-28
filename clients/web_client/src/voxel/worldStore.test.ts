import { describe, expect, it } from "vitest";
import { VoxelMaterialId } from "../material/catalog";
import { VoxelConstants } from "./core/constants";
import { EVoxelCellMode } from "./core/types";
import { FullMicroOccupancyMask, MicroGridSlotCount } from "./microgrid/governance";
import { LocalPrefabRegistry } from "./prefab";
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

describe("WorldStore snapshots", () => {
  it("exports and imports normal and refined prefab cells without losing occupancy", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 1, y: 2, z: 3 }, block(VoxelMaterialId.Stone));
    const prefabs = new LocalPrefabRegistry();
    prefabs.place("builtin_sphere", { x: 4, y: 5, z: 6 }, source);

    const snapshot = source.exportSnapshot();
    const imported = new WorldStore();
    imported.importSnapshot(snapshot);

    expect(imported.getNormalBlockWorld({ x: 1, y: 2, z: 3 })?.materialId).toBe(
      VoxelMaterialId.Stone,
    );
    expect(imported.getNormalBlockWorld({ x: 4, y: 5, z: 6 })?.materialId).toBe(
      VoxelMaterialId.Ice,
    );

    const refinedChunk = imported.getChunk({ x: 0, y: 0, z: 0 });
    const header = refinedChunk?.getHeaderAt({ x: 4, y: 5, z: 6 });
    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(
      refinedChunk?.data.refinedCells[header?.payloadIndex ?? -1]?.microOccupancyMask,
    ).not.toBe(0n);
  });
});

describe("WorldStore microgrid governance", () => {
  it("stores a single occupied micro cell as a high-resolution refined payload", () => {
    const world = new WorldStore();
    const macro = { x: 1, y: 2, z: 3 };
    const micro = { x: 0, y: 1, z: 2 };

    expect(world.setMicroBlockWorld(macro, micro, block(VoxelMaterialId.Wood))).toBe(true);
    expect(world.getMicroBlockWorld(macro, micro)?.materialId).toBe(VoxelMaterialId.Wood);
    expect(
      world.setMicroBlockWorld(
        macro,
        { x: VoxelConstants.MicroPerMacro, y: 0, z: 0 },
        block(VoxelMaterialId.Wood),
      ),
    ).toBe(false);

    const chunk = world.getChunk({ x: 0, y: 0, z: 0 });
    const header = chunk?.getHeaderAt(macro);
    const refined = chunk?.data.refinedCells[header?.payloadIndex ?? -1];

    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(VoxelConstants.MicroPerMacro).toBeGreaterThanOrEqual(8);
    expect(refined?.microOccupancyMask).toBe(
      1n <<
        BigInt(
          micro.x +
            micro.y * VoxelConstants.MicroPerMacro +
            micro.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro,
        ),
    );
    expect(refined?.microMaterialIds).toHaveLength(MicroGridSlotCount);
    expect(refined?.microStateFlags).toHaveLength(MicroGridSlotCount);
    expect(refined?.microPartIds).toHaveLength(MicroGridSlotCount);
    expect(world.editStats.rejected).toBe(1);
  });

  it("chisels one micro cell out of a solid macro without dropping the rest of the block", () => {
    const world = new WorldStore();
    const macro = { x: 0, y: 0, z: 0 };

    world.setNormalBlockWorld(macro, block(VoxelMaterialId.Stone));

    expect(world.clearMicroBlockWorld(macro, { x: 0, y: 0, z: 0 })).toBe(true);
    expect(world.getMicroBlockWorld(macro, { x: 0, y: 0, z: 0 })).toBeNull();
    expect(world.getMicroBlockWorld(macro, { x: 1, y: 0, z: 0 })?.materialId).toBe(
      VoxelMaterialId.Stone,
    );

    const chunk = world.getChunk({ x: 0, y: 0, z: 0 });
    const header = chunk?.getHeaderAt(macro);
    const refined = chunk?.data.refinedCells[header?.payloadIndex ?? -1];

    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(refined?.microOccupancyMask).toBe(FullMicroOccupancyMask & ~1n);
  });
});

describe("WorldStore showcase seed", () => {
  it("builds the regional demo terrain and resets edit counters", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Stone));
    world.markConflict();

    world.seedRegionalShowcase(1);

    expect(world.totalSolidBlocks()).toBeGreaterThan(0);
    expect(world.getNormalBlockWorld({ x: 0, y: 3, z: 0 })?.materialId).toBe(VoxelMaterialId.Ice);
    expect(world.getEnvironmentSummaryWorld({ x: 0, y: 3, z: 0 })?.currentTemperature).toBe(-42);
    expect(world.editStats).toEqual({ placed: 0, broken: 0, rejected: 0, conflicts: 0 });
  });
});
