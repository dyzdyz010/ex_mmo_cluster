import { describe, expect, it } from "vitest";
import { VoxelMaterialId } from "../../material/catalog";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FMacroCoord } from "../../voxel/core/types";
import { VoxelConstants } from "../../voxel/core/constants";
import { LocalVoxelWorldAdapter } from "../../voxel/worldAdapter";
import { WorldEditController, type SelectionProvider } from "./worldEditController";

class StaticSelectionProvider implements SelectionProvider {
  constructor(private readonly selection: ReturnType<SelectionProvider["getCurrentSelection"]>) {}

  getCurrentSelection(): ReturnType<SelectionProvider["getCurrentSelection"]> {
    return this.selection;
  }
}

describe("WorldEditController selection edits", () => {
  it("breaks the occupied block and places into the hit-face adjacent cell", () => {
    const bus = new EventBus<AppEvents>();
    const world = new LocalVoxelWorldAdapter();
    const occupiedMacro: FMacroCoord = { x: 1, y: 2, z: 3 };
    const adjacentMacro: FMacroCoord = { x: 2, y: 2, z: 3 };
    const selection = new StaticSelectionProvider({
      occupiedMacro,
      adjacentMacro,
      faceNormal: { x: 1, y: 0, z: 0 },
    });
    const edit = new WorldEditController(bus, world, selection);

    expect(edit.placeAt(occupiedMacro, VoxelMaterialId.Stone, "test_setup")).toBe(true);

    bus.emit("input:break-block", { source: "mouse_left" });
    expect(world.store.getNormalBlockWorld(occupiedMacro)).toBeNull();

    bus.emit("input:place-block", { source: "mouse_right" });
    expect(world.store.getNormalBlockWorld(adjacentMacro)?.materialId).toBe(VoxelMaterialId.Dirt);
  });

  it("cycles from materials into built-in prefabs and places the selected prefab at the adjacent cell", () => {
    const bus = new EventBus<AppEvents>();
    const world = new LocalVoxelWorldAdapter();
    const adjacentMacro: FMacroCoord = { x: 8, y: 4, z: 8 };
    const selection = new StaticSelectionProvider({
      occupiedMacro: { x: 8, y: 3, z: 8 },
      adjacentMacro,
      faceNormal: { x: 0, y: 1, z: 0 },
    });
    const edit = new WorldEditController(bus, world, selection);
    const placedPrefabs: AppEvents["world:prefab-placed"][] = [];
    bus.on("world:prefab-placed", (event) => placedPrefabs.push(event));

    for (let i = 0; i < 4; i += 1) {
      bus.emit("input:hotbar-cycle", { direction: 1, source: "test" });
    }

    expect(edit.getHotbarState().selected).toMatchObject({
      kind: "prefab",
      prefabName: "builtin_sphere",
    });

    bus.emit("input:place-block", { source: "mouse_right" });

    expect(world.store.getNormalBlockWorld(adjacentMacro)).not.toBeNull();
    expect(placedPrefabs).toEqual([
      {
        name: "builtin_sphere",
        origin: adjacentMacro,
        placed: 1,
        source: "mouse_right",
      },
    ]);
  });

  it("uses socket-free boundary snapping when right-click placing a prefab against a prefab surface", () => {
    const bus = new EventBus<AppEvents>();
    const world = new LocalVoxelWorldAdapter();
    world.placePrefab("builtin_sphere", { x: 0, y: 0, z: 0 });
    const selection = new StaticSelectionProvider({
      occupiedMacro: { x: 0, y: 0, z: 0 },
      adjacentMacro: { x: 1, y: 0, z: 0 },
      faceNormal: { x: 1, y: 0, z: 0 },
      occupiedMicro: {
        macro: { x: 0, y: 0, z: 0 },
        micro: {
          x: VoxelConstants.MicroPerMacro - 1,
          y: Math.floor(VoxelConstants.MicroPerMacro / 2),
          z: Math.floor(VoxelConstants.MicroPerMacro / 2),
        },
      },
    });
    const edit = new WorldEditController(bus, world, selection);
    const committed: AppEvents["world:prefab-boundary-snap-committed"][] = [];
    bus.on("world:prefab-boundary-snap-committed", (event) => committed.push(event));

    edit.selectPrefab("builtin_sphere", "test");
    bus.emit("input:place-block", { source: "mouse_right" });

    expect(committed).toHaveLength(1);
    expect(committed[0]).toMatchObject({
      prefabId: "builtin_sphere",
      instanceId: 2,
      anchorMicroCoord: {
        x: VoxelConstants.MicroPerMacro,
        y: 0,
        z: 0,
      },
      contactSlots: expect.any(Number),
      overlapSlots: 0,
      source: "mouse_right",
    });
    expect(
      world.store.getMicroBlockWorld({ x: 1, y: 0, z: 0 }, { x: 0, y: 4, z: 4 })?.materialId,
    ).toBe(VoxelMaterialId.Ice);
  });

  it("passes the aimed adjacent micro slot into prefab boundary snapping", () => {
    const bus = new EventBus<AppEvents>();
    const world = new LocalVoxelWorldAdapter();
    world.placePrefab("builtin_stairs", { x: 20, y: 10, z: 20 });
    const selection = new StaticSelectionProvider({
      occupiedMacro: { x: 20, y: 10, z: 20 },
      adjacentMacro: { x: 20, y: 11, z: 20 },
      faceNormal: { x: 0, y: 1, z: 0 },
      occupiedMicro: {
        macro: { x: 20, y: 10, z: 20 },
        micro: { x: 3, y: 3, z: 4 },
      },
      adjacentMicro: {
        macro: { x: 20, y: 10, z: 20 },
        micro: { x: 3, y: 4, z: 4 },
      },
    });
    const edit = new WorldEditController(bus, world, selection);
    const committed: AppEvents["world:prefab-boundary-snap-committed"][] = [];
    bus.on("world:prefab-boundary-snap-committed", (event) => committed.push(event));

    edit.selectPrefab("builtin_stairs", "test");
    bus.emit("input:place-block", { source: "mouse_right" });

    expect(committed).toHaveLength(1);
    expect(committed[0]).toMatchObject({
      prefabId: "builtin_stairs",
      anchorMicroCoord: { x: 156, y: 84, z: 160 },
      overlapSlots: 0,
      source: "mouse_right",
    });
  });
});
