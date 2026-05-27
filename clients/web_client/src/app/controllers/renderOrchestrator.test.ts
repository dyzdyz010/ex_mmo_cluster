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
import { RenderOrchestrator, resolveEntityTargetFromCamera } from "./renderOrchestrator";

describe("RenderOrchestrator actor display", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("does not snap the local actor onto an overhead voxel column", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const world = new LocalVoxelWorldAdapter();
    const localPosition = new Vector3(50, 185, 50);
    world.store.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, normalBlock());
    world.store.setNormalBlockWorld({ x: 0, y: 4, z: 0 }, normalBlock());

    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      world,
      createTestLocalPlayer({
        renderedPosition: localPosition,
        authoritativePosition: localPosition,
        groundY: localPosition.y,
      }),
      createTestRemotePlayer(),
      new ObserveLog(8),
    );

    render.onFrame(0, 16);

    expect(render.getActorDisplaySnapshot().local.y).toBe(localPosition.y);
    render.dispose();
  });

  it("renders the authoritative actor at its synced 3D height", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const world = new LocalVoxelWorldAdapter();
    world.store.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, normalBlock());
    world.store.setNormalBlockWorld({ x: 0, y: 4, z: 0 }, normalBlock());
    const renderedPosition = new Vector3(50, 185, 50);
    const authoritativePosition = new Vector3(50, 250, 50);

    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      world,
      createTestLocalPlayer({
        renderedPosition,
        authoritativePosition,
        groundY: renderedPosition.y,
      }),
      createTestRemotePlayer(),
      new ObserveLog(8),
    );

    render.onFrame(0, 16);

    expect(render.getActorDisplaySnapshot().authority.y).toBe(authoritativePosition.y);
    render.dispose();
  });

  it("smooths authority display jumps between server movement acks", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const world = new LocalVoxelWorldAdapter();
    const renderedPosition = new Vector3(50, 185, 50);
    let authoritativePosition = new Vector3(50, 185, 50);
    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      world,
      {
        getRenderedPosition: () => renderedPosition.clone(),
        getAuthoritativePosition: () => authoritativePosition.clone(),
        getAuthoritativeRenderPosition: () => authoritativePosition.clone(),
        getCurrentState: () => ({ groundY: renderedPosition.y }),
      } as never,
      createTestRemotePlayer(),
      new ObserveLog(8),
    );

    render.onFrame(0, 16);
    authoritativePosition = new Vector3(50, 285, 50);
    render.onFrame(16, 16);

    const displayedY = render.getActorDisplaySnapshot().authority.y;
    expect(displayedY).toBeGreaterThan(185);
    expect(displayedY).toBeLessThan(285);
    render.dispose();
  });
});

class ServerAuthoritativePreviewWorld extends LocalVoxelWorldAdapter {
  override readonly mode = "server-authoritative";
  readonly previewRequests: PrefabBoundarySnapRequest[] = [];

  override previewPrefabBoundarySnap(
    request: PrefabBoundarySnapRequest,
  ): PrefabBoundarySnapPreview {
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

  it("waits for a matching server field snapshot before rendering pending discharge lightning", () => {
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
      new ObserveLog(16),
    );
    const sourceCoord = { x: 2, y: 7, z: 4 };
    const targetCoord = { x: 2, y: 3, z: 4 };

    render.queueLightningBoltOnFieldSnapshot(sourceCoord, targetCoord);
    render.onFrame(0, 16);

    expect(render.getLightningBoltSnapshot().visibleSegments).toBe(0);

    world.pushFieldSnapshot(makeCurrentFieldSnapshot({ tickCount: 1 }));
    render.onFrame(16, 16);

    expect(render.getLightningBoltSnapshot().visibleSegments).toBe(0);

    world.pushFieldSnapshot(makeDischargeFieldSnapshot({ sourceCoord, targetCoord, tickCount: 2 }));
    render.onFrame(32, 16);

    expect(render.getLightningBoltSnapshot().visibleSegments).toBeGreaterThan(0);
    render.dispose();
  });
});

describe("RenderOrchestrator entity targeting", () => {
  it("selects only a remote entity close to the camera center", () => {
    const camera = new PerspectiveCamera(70, 1, 1, 5000);
    camera.position.set(0, 0, 0);
    camera.lookAt(0, 0, -1000);
    camera.updateMatrixWorld(true);
    camera.updateProjectionMatrix();

    const target = resolveEntityTargetFromCamera(
      [remoteEntity(41, new Vector3(900, 0, -800)), remoteEntity(42, new Vector3(0, 0, -800))],
      camera,
    );

    expect(target).toMatchObject({
      entityId: 42,
      macroCoord: { x: 0, y: 0, z: -8 },
    });
  });

  it("does not select an entity outside the crosshair target radius", () => {
    const camera = new PerspectiveCamera(70, 1, 1, 5000);
    camera.position.set(0, 0, 0);
    camera.lookAt(0, 0, -1000);
    camera.updateMatrixWorld(true);
    camera.updateProjectionMatrix();

    expect(
      resolveEntityTargetFromCamera([remoteEntity(42, new Vector3(400, 0, -800))], camera),
    ).toBeNull();
  });

  it("exposes the local actor as the fallback entity target for single-client testing", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const world = new LocalVoxelWorldAdapter();
    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      world,
      createTestLocalPlayer({
        renderedPosition: new Vector3(150, 250, 350),
        authoritativePosition: new Vector3(150, 250, 350),
      }),
      createTestRemotePlayer(),
      new ObserveLog(8),
    );

    render.onFrame(0, 16);

    expect(render.getFallbackEntityTarget()).toMatchObject({
      entityId: -1,
      macroCoord: { x: 1, y: 2, z: 3 },
      renderedPosition: { x: 150, y: 250, z: 350 },
    });
    expect(render.getTargetOverlaySnapshot().fallbackEntityTarget).toMatchObject({
      entityId: -1,
      macroCoord: { x: 1, y: 2, z: 3 },
    });

    render.dispose();
  });

  it("materializes lightning line buffers immediately when a strike is spawned", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    });
    const render = new RenderOrchestrator(
      createTestSceneHandles(),
      new LocalVoxelWorldAdapter(),
      createTestLocalPlayer(),
      createTestRemotePlayer(),
      new ObserveLog(8),
    );

    render.spawnLightningBolt({ x: 2, y: 7, z: 4 }, { x: 2, y: 3, z: 4 });

    expect(render.getLightningBoltSnapshot().visibleSegments).toBeGreaterThan(0);
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

function createTestLocalPlayer(
  options: {
    renderedPosition?: Vector3;
    authoritativePosition?: Vector3;
    groundY?: number;
  } = {},
) {
  const renderedPosition = options.renderedPosition ?? new Vector3(0, 0, 0);
  const authoritativePosition = options.authoritativePosition ?? new Vector3(0, 0, 0);
  return {
    getRenderedPosition: () => renderedPosition.clone(),
    getAuthoritativePosition: () => authoritativePosition.clone(),
    getAuthoritativeRenderPosition: () => authoritativePosition.clone(),
    getCurrentState: () => ({ groundY: options.groundY ?? renderedPosition.y }),
  } as never;
}

function normalBlock() {
  return {
    materialId: VoxelMaterialId.Stone,
    stateFlags: 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

function createTestRemotePlayer() {
  return {
    getRenderedPosition: () => new Vector3(0, 0, 0),
    getRenderedEntities: () => [],
    getRenderedGroundY: () => undefined,
  } as never;
}

function remoteEntity(cid: number, position: Vector3) {
  return {
    cid,
    position,
    movementMode: "walking",
    movementGroundY: null,
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

function makeDischargeFieldSnapshot({
  sourceCoord,
  targetCoord,
  tickCount,
}: {
  sourceCoord: FMacroCoord;
  targetCoord: FMacroCoord;
  tickCount: number;
}): FFieldRegionSnapshot {
  return {
    logicalSceneId: 1,
    chunkCoord: { cx: 0, cy: 0, cz: 0 },
    regionId: 78,
    tickCount,
    fieldMask: FieldMask.ElectricPotential | FieldMask.Ionization,
    cellCount: 2,
    macroIndices: Uint16Array.of(macroIndex(sourceCoord), macroIndex(targetCoord)),
    temperatureValues: new Float32Array(0),
    electricValues: Float32Array.of(120, 12),
    electricCurrentValues: new Float32Array(0),
    ionizationValues: Uint8Array.of(255, 128),
  };
}

function macroIndex(coord: FMacroCoord): number {
  return coord.x + coord.y * 16 + coord.z * 256;
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
