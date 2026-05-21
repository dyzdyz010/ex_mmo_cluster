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

class ServerAuthoritativeWorld extends LocalVoxelWorldAdapter {
  override readonly mode = "server-authoritative";
  readonly prefabPlaceCalls: Array<{ name: string; origin: FMacroCoord }> = [];
  readonly heatCalls: Array<{
    coord: FMacroCoord;
    targetTemperatureCelsius: number;
    maxTicks: number | undefined;
  }> = [];
  readonly conductionCalls: Array<{
    source: FMacroCoord;
    target: FMacroCoord;
    sourcePotential: number;
    maxTicks: number | undefined;
  }> = [];

  override placePrefabBoundarySnap() {
    return { ok: false, placed: 0, rejectReason: "server_authority_not_supported" as const };
  }

  override placePrefab(name: string, origin: FMacroCoord) {
    this.prefabPlaceCalls.push({ name, origin: { ...origin } });
    return { ok: true, placed: 3 };
  }

  requestDevHeatVoxel(
    coord: FMacroCoord,
    targetTemperatureCelsius: number,
    maxTicks?: number,
  ): boolean {
    this.heatCalls.push({ coord: { ...coord }, targetTemperatureCelsius, maxTicks });
    return true;
  }

  requestSetVoxelTemperature(
    coord: FMacroCoord,
    targetTemperatureCelsius: number,
    maxTicks?: number,
  ): boolean {
    this.heatCalls.push({ coord: { ...coord }, targetTemperatureCelsius, maxTicks });
    return true;
  }

  requestVoxelConductionPath(
    source: FMacroCoord,
    target: FMacroCoord,
    sourcePotential: number,
    maxTicks?: number,
  ): boolean {
    this.conductionCalls.push({
      source: { ...source },
      target: { ...target },
      sourcePotential,
      maxTicks,
    });
    return true;
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

    expect(edit.getHotbarState().entries).toEqual(
      expect.arrayContaining([
        { kind: "material", label: "power_block", materialId: VoxelMaterialId.PowerBlock },
      ]),
    );

    for (let i = 0; i < 6; i += 1) {
      bus.emit("input:hotbar-cycle", { direction: 1, source: "test" });
    }

    expect(edit.getHotbarState().selected).toMatchObject({
      kind: "prefab",
      prefabName: "builtin_conductor_wire_x",
    });

    bus.emit("input:place-block", { source: "mouse_right" });

    expect(world.store.getNormalBlockWorld(adjacentMacro)).not.toBeNull();
    expect(placedPrefabs).toEqual([
      {
        name: "builtin_conductor_wire_x",
        origin: adjacentMacro,
        placed: 1,
        source: "mouse_right",
      },
    ]);
  });

  it("keeps online right-click prefab placement on the boundary-snap contract", () => {
    const bus = new EventBus<AppEvents>();
    const world = new ServerAuthoritativeWorld();
    const adjacentMacro: FMacroCoord = { x: 8, y: 1, z: 8 };
    const selection = new StaticSelectionProvider({
      occupiedMacro: { x: 8, y: 0, z: 8 },
      adjacentMacro,
      faceNormal: { x: 0, y: 1, z: 0 },
    });
    const edit = new WorldEditController(bus, world, selection);
    const placedPrefabs: AppEvents["world:prefab-placed"][] = [];
    const fallbacks: AppEvents["world:prefab-boundary-snap-fallback"][] = [];
    const rejectedSnaps: AppEvents["world:prefab-boundary-snap-rejected"][] = [];
    const editRejected: AppEvents["world:edit-rejected"][] = [];
    bus.on("world:prefab-placed", (event) => placedPrefabs.push(event));
    bus.on("world:prefab-boundary-snap-fallback", (event) => fallbacks.push(event));
    bus.on("world:prefab-boundary-snap-rejected", (event) => rejectedSnaps.push(event));
    bus.on("world:edit-rejected", (event) => editRejected.push(event));

    expect(edit.getHotbarState().entries).toEqual(
      expect.arrayContaining([
        { kind: "material", label: "power_block", materialId: VoxelMaterialId.PowerBlock },
      ]),
    );

    for (let i = 0; i < 6; i += 1) {
      bus.emit("input:hotbar-cycle", { direction: 1, source: "test" });
    }

    expect(edit.getHotbarState().selected).toMatchObject({
      kind: "prefab",
      prefabName: "builtin_conductor_wire_x",
    });

    bus.emit("input:place-block", { source: "mouse_right" });

    expect(world.prefabPlaceCalls).toEqual([]);
    expect(fallbacks).toEqual([]);
    expect(placedPrefabs).toEqual([]);
    expect(rejectedSnaps).toEqual([
      {
        prefabId: "builtin_conductor_wire_x",
        hitMacro: { x: 8, y: 0, z: 8 },
        faceNormal: { x: 0, y: 1, z: 0 },
        anchorMicroCoord: null,
        affectedMacroCount: 0,
        incomingOccupiedSlots: 0,
        overlapSlots: 0,
        contactSlots: 0,
        rejectReason: "server_authority_not_supported",
        source: "mouse_right",
      },
    ]);
    expect(editRejected).toEqual([
      { reason: "prefab_boundary_snap_rejected", source: "mouse_right" },
    ]);
  });

  it("sets the occupied voxel to an 800C target through the server anomaly path", () => {
    const bus = new EventBus<AppEvents>();
    const world = new ServerAuthoritativeWorld();
    const occupiedMacro: FMacroCoord = { x: 6, y: 7, z: 8 };
    const selection = new StaticSelectionProvider({
      occupiedMacro,
      adjacentMacro: { x: 6, y: 8, z: 8 },
      faceNormal: { x: 0, y: 1, z: 0 },
    });
    const temperatureSet: AppEvents["world:voxel-temperature-set"][] = [];
    bus.on("world:voxel-temperature-set", (event) => temperatureSet.push(event));
    new WorldEditController(bus, world, selection);

    bus.emit("input:set-selected-voxel-temperature", {
      source: "keyboard",
      targetTemperatureCelsius: 800,
    });

    expect(world.heatCalls).toEqual([
      { coord: occupiedMacro, targetTemperatureCelsius: 800, maxTicks: undefined },
    ]);
    expect(temperatureSet).toEqual([
      { coord: occupiedMacro, targetTemperatureCelsius: 800, source: "keyboard" },
    ]);
  });

  it("cools the occupied voxel through the same target-temperature path", () => {
    const bus = new EventBus<AppEvents>();
    const world = new ServerAuthoritativeWorld();
    const occupiedMacro: FMacroCoord = { x: 6, y: 7, z: 8 };
    const selection = new StaticSelectionProvider({
      occupiedMacro,
      adjacentMacro: { x: 6, y: 8, z: 8 },
      faceNormal: { x: 0, y: 1, z: 0 },
    });
    const temperatureSet: AppEvents["world:voxel-temperature-set"][] = [];
    bus.on("world:voxel-temperature-set", (event) => temperatureSet.push(event));
    const edit = new WorldEditController(bus, world, selection);

    expect(edit.setTemperatureAtSelection("test", 0, 60)).toBe(true);

    expect(world.heatCalls).toEqual([
      { coord: occupiedMacro, targetTemperatureCelsius: 0, maxTicks: 60 },
    ]);
    expect(temperatureSet).toEqual([
      { coord: occupiedMacro, targetTemperatureCelsius: 0, source: "test" },
    ]);
  });

  it("requests a server-authoritative conduction path and emits a visible field event", () => {
    const bus = new EventBus<AppEvents>();
    const world = new ServerAuthoritativeWorld();
    const edit = new WorldEditController(
      bus,
      world,
      new StaticSelectionProvider({
        occupiedMacro: { x: 0, y: 1, z: 0 },
        adjacentMacro: { x: 1, y: 1, z: 0 },
        faceNormal: { x: 1, y: 0, z: 0 },
      }),
    );
    const conductionEvents: AppEvents["world:voxel-conduction-requested"][] = [];
    bus.on("world:voxel-conduction-requested", (event) => conductionEvents.push(event));

    expect(edit.conductBetween({ x: 0, y: 1, z: 0 }, { x: 3, y: 1, z: 0 }, 120, "test", 90)).toBe(
      true,
    );
    expect(edit.getSelectedOccupiedMacro()).toEqual({ x: 0, y: 1, z: 0 });
    expect(edit.getSelectedConductionPair()).toEqual({
      sourceCoord: { x: 0, y: 1, z: 0 },
      targetCoord: { x: 3, y: 1, z: 0 },
    });

    expect(world.conductionCalls).toEqual([
      {
        source: { x: 0, y: 1, z: 0 },
        target: { x: 3, y: 1, z: 0 },
        sourcePotential: 120,
        maxTicks: 90,
      },
    ]);
    expect(conductionEvents).toEqual([
      {
        sourceCoord: { x: 0, y: 1, z: 0 },
        targetCoord: { x: 3, y: 1, z: 0 },
        sourcePotential: 120,
        source: "test",
      },
    ]);
  });

  it("routes the keyboard selected-conduction intent through the aimed source-target pair", () => {
    const bus = new EventBus<AppEvents>();
    const world = new ServerAuthoritativeWorld();
    new WorldEditController(
      bus,
      world,
      new StaticSelectionProvider({
        occupiedMacro: { x: 2, y: 1, z: 0 },
        adjacentMacro: { x: 3, y: 1, z: 0 },
        faceNormal: { x: 1, y: 0, z: 0 },
      }),
    );
    const conductionEvents: AppEvents["world:voxel-conduction-requested"][] = [];
    bus.on("world:voxel-conduction-requested", (event) => conductionEvents.push(event));

    bus.emit("input:conduct-selected-voxel", {
      source: "keyboard",
      sourcePotential: 120,
      maxTicks: 90,
    });

    expect(world.conductionCalls).toEqual([
      {
        source: { x: 2, y: 1, z: 0 },
        target: { x: 5, y: 1, z: 0 },
        sourcePotential: 120,
        maxTicks: 90,
      },
    ]);
    expect(conductionEvents).toEqual([
      {
        sourceCoord: { x: 2, y: 1, z: 0 },
        targetCoord: { x: 5, y: 1, z: 0 },
        sourcePotential: 120,
        source: "keyboard",
      },
    ]);
  });

  it("rejects selected conduction when the aimed target would cross a chunk boundary", () => {
    const bus = new EventBus<AppEvents>();
    const world = new ServerAuthoritativeWorld();
    const edit = new WorldEditController(
      bus,
      world,
      new StaticSelectionProvider({
        occupiedMacro: { x: 14, y: 1, z: 0 },
        adjacentMacro: { x: 15, y: 1, z: 0 },
        faceNormal: { x: 1, y: 0, z: 0 },
      }),
    );
    const rejected: AppEvents["world:edit-rejected"][] = [];
    bus.on("world:edit-rejected", (event) => rejected.push(event));

    expect(edit.getSelectedConductionPair()).toBeNull();
    expect(edit.conductAtSelection("keyboard", 120, 90)).toBe(false);

    expect(world.conductionCalls).toEqual([]);
    expect(rejected).toEqual([
      { reason: "conduction_target_cross_chunk_not_supported", source: "keyboard" },
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
