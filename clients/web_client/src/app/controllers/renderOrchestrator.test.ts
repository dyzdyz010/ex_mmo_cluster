import { afterEach, describe, expect, it, vi } from "vitest";
import { Group, PerspectiveCamera, Scene, Vector3 } from "three";
import type { VoxelFieldRegionSnapshotMessage } from "../../infrastructure/net/voxelProtocol";
import { VoxelMaterialId } from "../../material/catalog";
import { ObserveLog } from "../../observe/logger";
import type { SceneHandles } from "../../render/scene";
import type { VoxelRaySelection } from "../../render/chunkRenderer";
import { VoxelConstants } from "../../voxel/core/constants";
import { EVoxelRotation } from "../../voxel/core/types";
import type { FMacroCoord } from "../../voxel/core/types";
import { FieldMask, type FFieldRegionSnapshot } from "../../voxel/field/fieldProtocol";
import type { FieldDebugOverlay } from "../../voxel/field/fieldDebugOverlay";
import type {
  PrefabBoundarySnapPreview,
  PrefabBoundarySnapRequest,
  PrefabRasterCell,
} from "../../voxel/prefab";
import { LocalVoxelWorldAdapter } from "../../voxel/worldAdapter";
import { RenderOrchestrator, resolveActorDisplayY } from "./renderOrchestrator";

describe("resolveActorDisplayY", () => {
  it("adds airborne movement offset above the grounded surface center", () => {
    expect(
      resolveActorDisplayY({
        movementY: 172,
        movementGroundY: 100,
        surfaceCenterY: 160,
      }),
    ).toBe(232);
  });

  it("keeps grounded actors on the surface center when movement y is below the center", () => {
    expect(
      resolveActorDisplayY({
        movementY: 100,
        movementGroundY: 100,
        surfaceCenterY: 160,
      }),
    ).toBe(160);
  });
});

class ServerAuthoritativePreviewWorld extends LocalVoxelWorldAdapter {
  override readonly mode = "server-authoritative";
  readonly previewRequests: PrefabBoundarySnapRequest[] = [];

  override previewPrefabBoundarySnap(request: PrefabBoundarySnapRequest): PrefabBoundarySnapPreview {
    this.previewRequests.push(request);
    const cell = singleMicroSlotCell({ x: 8, y: 1, z: 8 });
    return {
      ok: true,
      prefabId: request.prefabName,
      hitMacro: request.hitMacro,
      faceNormal: request.faceNormal,
      anchorMicroCoord: { x: 64, y: 8, z: 64 },
      affectedMacroCount: 1,
      incomingOccupiedSlots: 1,
      overlapSlots: 0,
      contactSlots: 1,
      cells: [cell],
    };
  }
}

class FieldSnapshotWorld extends LocalVoxelWorldAdapter {
  readonly fieldSnapshots: VoxelFieldRegionSnapshotMessage[] = [];

  pushFieldSnapshot(snapshot: FFieldRegionSnapshot): void {
    this.fieldSnapshots.push({ type: "voxel_field_region_snapshot", snapshot });
  }

  drainVoxelFieldSnapshots(): VoxelFieldRegionSnapshotMessage[] {
    return this.fieldSnapshots.splice(0, this.fieldSnapshots.length);
  }
}

describe("RenderOrchestrator prefab preview", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps server-authoritative prefab aiming on the micro boundary preview path", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const world = new ServerAuthoritativePreviewWorld();
    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      world,
      {} as never,
      {} as never,
      new ObserveLog(8),
    );
    const selection: VoxelRaySelection = {
      occupiedMacro: { x: 8, y: 0, z: 8 },
      adjacentMacro: { x: 8, y: 1, z: 8 },
      faceNormal: { x: 0, y: 1, z: 0 },
      occupiedMicro: {
        macro: { x: 8, y: 0, z: 8 },
        micro: { x: 4, y: VoxelConstants.MicroPerMacro - 1, z: 4 },
      },
      adjacentMicro: {
        macro: { x: 8, y: 1, z: 8 },
        micro: { x: 4, y: 0, z: 4 },
      },
    };
    render.setEditPreviewProvider({
      getHotbarState: () => ({
        entries: [],
        selectedIndex: 0,
        selected: {
          kind: "prefab",
          label: "wire-x",
          prefabName: "builtin_conductor_wire_x",
          rotation: EVoxelRotation.Rot0,
        },
      }),
    });

    const internals = render as unknown as {
      currentSelection: VoxelRaySelection;
      updatePrefabPreview(): void;
    };
    internals.currentSelection = selection;
    internals.updatePrefabPreview();

    expect(world.previewRequests).toEqual([
      {
        prefabName: "builtin_conductor_wire_x",
        hitMacro: selection.occupiedMacro,
        hitMicro: selection.occupiedMicro?.micro,
        anchorMicroCoord: { x: 68, y: 8, z: 68 },
        faceNormal: selection.faceNormal,
        rotation: EVoxelRotation.Rot0,
      },
    ]);
    expect(render.getPrefabPreviewSnapshot()).toMatchObject({
      visible: true,
      prefabName: "builtin_conductor_wire_x",
      origin: { x: 8, y: 1, z: 8 },
      cellCount: 1,
      renderStyle: "micro-wire",
    });

    render.dispose();
  });
});

describe("RenderOrchestrator field overlay runtime", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("keeps field overlay render work cold while hidden and materializes the latest snapshot on show", () => {
    vi.spyOn(console, "info").mockImplementation(() => undefined);
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const world = new FieldSnapshotWorld();
    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      world,
      createTestLocalPlayer(),
      createTestRemotePlayer(),
      new ObserveLog(8),
    );
    render.setFieldHeatSmokeSource(77, 2400);

    world.pushFieldSnapshot(makeCurrentFieldSnapshot({ tickCount: 1 }));
    render.onFrame(0, 16);

    const overlay = fieldOverlayOf(render);
    expect(overlay.snapshot()).toMatchObject({ visible: false, regionCount: 0 });
    expect(overlay.rootGroup.getObjectByName("field-region-77")).toBeUndefined();

    world.pushFieldSnapshot(makeCurrentFieldSnapshot({ tickCount: 2 }));
    render.onFrame(16, 16);
    expect(overlay.snapshot()).toMatchObject({ visible: false, regionCount: 0 });

    render.setFieldDebugOverlayVisible(true);

    expect(overlay.snapshot().regions[0]).toMatchObject({
      regionId: 77,
      currentCells: 1,
    });
    expect(overlay.snapshot().regions[0]?.smokeParticles).toBeGreaterThan(0);
    expect(overlay.rootGroup.getObjectByName("field-region-77")).toBeDefined();

    render.dispose();
  });
});

function singleMicroSlotCell(macro: FMacroCoord): PrefabRasterCell {
  const slotCount = VoxelConstants.MicroPerMacro ** 3;
  return {
    macro,
    microOccupancyMask: 1n,
    microMaterialIds: new Array(slotCount).fill(VoxelMaterialId.Iron),
    microStateFlags: new Array(slotCount).fill(0),
    microPartIds: new Array(slotCount).fill(0),
  };
}

function createTestLocalPlayer() {
  return {
    getRenderedPosition: () => new Vector3(0, 0, 0),
    getAuthoritativePosition: () => new Vector3(0, 0, 0),
    getCurrentState: () => ({ groundY: 0 }),
  } as never;
}

function createTestRemotePlayer() {
  return {
    getRenderedPosition: () => new Vector3(0, 0, 0),
    getRenderedEntities: () => [],
    getRenderedGroundY: () => undefined,
  } as never;
}

function fieldOverlayOf(render: RenderOrchestrator): FieldDebugOverlay {
  return (render as unknown as { fieldDebugOverlay: FieldDebugOverlay }).fieldDebugOverlay;
}

function makeCurrentFieldSnapshot({ tickCount }: { tickCount: number }): FFieldRegionSnapshot {
  return {
    logicalSceneId: 1,
    chunkCoord: { cx: 0, cy: 0, cz: 0 },
    regionId: 77,
    tickCount,
    fieldMask: FieldMask.ElectricCurrent,
    cellCount: 1,
    macroIndices: Uint16Array.of(7 + 7 * 16 + 7 * 256),
    temperatureValues: new Float32Array(0),
    electricValues: new Float32Array(0),
    electricCurrentValues: Float32Array.of(20),
    ionizationValues: new Uint8Array(0),
  };
}

function createTestSceneHandles(): SceneHandles {
  const camera = new PerspectiveCamera();
  return {
    renderer: {} as SceneHandles["renderer"],
    scene: new Scene(),
    camera,
    worldRoot: new Group(),
    getRendererDebugSnapshot: () => ({
      requested: "webgl",
      active: "webgl",
      renderer: "WebGLRenderer",
      backend: "test",
      webgpuAvailable: false,
      fallbackReason: null,
    }),
    getMovementYawRadians: () => 0,
    isCameraInteracting: () => false,
    setCameraFollow: () => {},
    update: () => {},
    render: () => {},
    dispose: () => {},
    applyCameraYawPitchDelta: () => {},
    setDisableCanvasInput: () => {},
  };
}
