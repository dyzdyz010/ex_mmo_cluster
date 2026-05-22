import { describe, expect, it } from "vitest";
import { EVoxelRotation } from "./core/types";
import { MicroGridSlotCount } from "./microgrid/governance";
import {
  createFieldOverlayProjector,
  resolveFieldOverlayProjection,
  resolveSelectionOverlayProjection,
} from "./overlayTarget";
import { LocalPrefabRegistry } from "./prefab";
import { WorldStore } from "./worldStore";

describe("voxel overlay target projection", () => {
  it("projects a prefab-owned refined hit as the smallest prefab selection target", () => {
    const world = new WorldStore();
    const registry = new LocalPrefabRegistry();
    const macro = { x: 1, y: 2, z: 3 };
    const micro = { x: 0, y: 3, z: 3 };
    const placed = registry.place("builtin_conductor_wire_x", macro, world, EVoxelRotation.Rot0);
    expect(placed.ok).toBe(true);

    const projection = resolveSelectionOverlayProjection(world, { macro, micro }, macro);

    expect(projection).toMatchObject({
      granularity: "prefab",
      macro,
      selectedMicro: micro,
      prefabInstanceId: placed.instanceId,
    });
    expect(projection.cells).toHaveLength(1);
    expect(countBits(projection.cells[0]!.microOccupancyMask)).toBeGreaterThan(1);
  });

  it("falls back standalone refined micro hits to the macro selection target", () => {
    const world = new WorldStore();
    const macro = { x: 1, y: 2, z: 3 };
    const micro = { x: 2, y: 3, z: 4 };
    world.setMicroBlockWorld(macro, micro, {
      materialId: 5,
      stateFlags: 0,
      health: 100,
      temperatureDelta: 0,
      moistureDelta: 0,
    });

    const projection = resolveSelectionOverlayProjection(world, { macro, micro }, macro);

    expect(projection).toMatchObject({
      granularity: "macro",
      macro,
      cells: [],
    });
  });

  it("projects field overlay to the whole local prefab instance", () => {
    const world = new WorldStore();
    const registry = new LocalPrefabRegistry();
    const placed = registry.place(
      "builtin_conductor_junction_xz",
      { x: 1, y: 2, z: 3 },
      world,
      EVoxelRotation.Rot0,
    );
    expect(placed.ok).toBe(true);

    const projection = resolveFieldOverlayProjection(world, { x: 1, y: 2, z: 3 });

    expect(projection.granularity).toBe("prefab");
    expect(projection.prefabInstanceId).toBe(placed.instanceId);
    expect(projection.cells).toHaveLength(1);
    expect(countBits(projection.cells[0]!.microOccupancyMask)).toBeGreaterThan(1);
    expect(countBits(projection.cells[0]!.microOccupancyMask)).toBeLessThan(MicroGridSlotCount);
  });

  it("creates snapshot-scoped field projectors for repeated overlay projection", () => {
    const world = new WorldStore();
    const registry = new LocalPrefabRegistry();
    const placed = registry.place(
      "builtin_conductor_junction_xz",
      { x: 1, y: 2, z: 3 },
      world,
      EVoxelRotation.Rot0,
    );
    expect(placed.ok).toBe(true);

    const projector = createFieldOverlayProjector(world);
    const snapshotProjector = projector.createSnapshotProjector?.();
    expect(snapshotProjector).toBeDefined();

    const first = snapshotProjector!({ x: 1, y: 2, z: 3 });
    const second = snapshotProjector!({ x: 1, y: 2, z: 3 });

    expect(first).toBe(second);
    expect(first.granularity).toBe("prefab");
    expect(first.prefabInstanceId).toBe(placed.instanceId);
  });

  it("keeps a normal solid block as a macro field target", () => {
    const world = new WorldStore();
    const macro = { x: 2, y: 0, z: 1 };
    world.setNormalBlockWorld(macro, {
      materialId: 1,
      stateFlags: 0,
      health: 100,
      temperatureDelta: 0,
      moistureDelta: 0,
    });

    expect(resolveFieldOverlayProjection(world, macro)).toMatchObject({
      granularity: "macro",
      macro,
      cells: [],
    });
  });
});

function countBits(mask: bigint): number {
  let count = 0;
  let remaining = mask;
  while (remaining !== 0n) {
    remaining &= remaining - 1n;
    count += 1;
  }
  return count;
}
