import { describe, expect, it } from "vitest";
import { VoxelMaterialId } from "../../material/catalog";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FMacroCoord } from "../../voxel/core/types";
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
});
