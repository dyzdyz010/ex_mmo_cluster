import { BufferGeometry, Mesh, MeshStandardMaterial, PerspectiveCamera, Vector3 } from "three";
import { describe, expect, it, vi } from "vitest";
import { VoxelMaterialId } from "../material/catalog";
import { MacroWorldSize } from "../voxel/core/constants";
import { EVoxelRotation } from "../voxel/core/types";
import { resolveSelectionOverlayProjection } from "../voxel/overlayTarget";
import { LocalPrefabRegistry } from "../voxel/prefab";
import { VoxelDirtyFlags } from "../voxel/storage/types";
import { WorldStore } from "../voxel/worldStore";
import type { ObserveLog } from "../observe/logger";
import {
  buildPrefabRasterMicroWireGeometry,
  buildPrefabRasterSurfaceOutlineGeometry,
} from "./prefabPreviewGeometry";
import { ChunkRenderController } from "./chunkRenderer";

function block(materialId: number) {
  return {
    materialId,
    stateFlags: 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

describe("ChunkRenderController hit-face outline", () => {
  it("skips mesh rebuilds for empty authoritative chunks", () => {
    const controller = new ChunkRenderController();
    const world = new WorldStore();
    const chunk = world.ensureChunk({ x: 0, y: 0, z: 0 });
    const logger = { emit: vi.fn() } as unknown as ObserveLog;

    expect(chunk.trySetNormalBlock({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Stone))).toBe(
      true,
    );
    expect(chunk.tryClearMacroCell({ x: 0, y: 0, z: 0 })).toBe(true);
    expect(chunk.hasRenderableCells()).toBe(false);

    controller.syncDirtyChunks(world, logger);

    expect(chunkMeshCount(controller)).toBe(0);
    expect(pendingMeshBuildCount(controller)).toBe(0);
    expect(chunk.data.dirtyFlags & (VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision)).toBe(0);
    expect((logger.emit as ReturnType<typeof vi.fn>)).not.toHaveBeenCalled();

    controller.syncDirtyChunks(world, logger);

    expect(chunkMeshCount(controller)).toBe(0);
    expect(pendingMeshBuildCount(controller)).toBe(0);
    expect((logger.emit as ReturnType<typeof vi.fn>)).not.toHaveBeenCalled();

    controller.dispose();
  });

  it("shows one outline on the hit face instead of break/place block boxes", () => {
    const controller = new ChunkRenderController();

    controller.setTargetHighlights({
      occupiedMacro: { x: 1, y: 2, z: 3 },
      adjacentMacro: { x: 2, y: 2, z: 3 },
      faceNormal: { x: 1, y: 0, z: 0 },
    });

    const snapshot = controller.getTargetHighlightSnapshot();
    expect(snapshot.visible).toBe(true);
    expect(snapshot.kind).toBe("macro-cell");
    expect(snapshot.faceNormal).toEqual({ x: 1, y: 0, z: 0 });
    expect(snapshot.occupiedMacro).toEqual({ x: 1, y: 2, z: 3 });
    expect(snapshot.occupiedMicro).toBeNull();
    expect(snapshot.position.x).toBeGreaterThan((1 + 0.5) * MacroWorldSize);
    expect(snapshot.position.x).toBeLessThan((1 + 0.6) * MacroWorldSize);
    expect(snapshot.position.y).toBeCloseTo((2 + 0.5) * MacroWorldSize);
    expect(snapshot.position.z).toBeCloseTo((3 + 0.5) * MacroWorldSize);

    controller.dispose();
  });

  it("shows a prefab outline when the hit refined micro belongs to a prefab", () => {
    const controller = new ChunkRenderController();
    const world = new WorldStore();
    const registry = new LocalPrefabRegistry();
    const macro = { x: 1, y: 2, z: 3 };
    const micro = { x: 0, y: 3, z: 3 };
    const placed = registry.place("builtin_conductor_wire_x", macro, world, EVoxelRotation.Rot0);
    expect(placed.ok).toBe(true);

    controller.setTargetHighlights(
      {
        occupiedMacro: macro,
        adjacentMacro: { x: 2, y: 2, z: 3 },
        faceNormal: { x: 1, y: 0, z: 0 },
        occupiedMicro: { macro, micro },
        adjacentMicro: { macro, micro: { x: 3, y: 3, z: 4 } },
      },
      world,
    );

    const snapshot = controller.getTargetHighlightSnapshot();
    expect(snapshot.kind).toBe("prefab");
    expect(snapshot.occupiedMicro).toEqual({ macro, micro });
    const projection = resolveSelectionOverlayProjection(world, { macro, micro }, macro);
    const surfaceOutline = buildPrefabRasterSurfaceOutlineGeometry(projection.cells);
    const denseWire = buildPrefabRasterMicroWireGeometry(projection.cells);
    const targetLineSegments =
      (
        controller as unknown as { targetHighlight: { geometry: BufferGeometry } }
      ).targetHighlight.geometry.getAttribute("position").count / 2;
    expect(targetLineSegments).toBe(surfaceOutline.wireSegmentCount);
    expect(surfaceOutline.wireSegmentCount).toBeLessThan(denseWire.wireSegmentCount);

    controller.dispose();
  });

  it("keeps the previous voxel selection for near-equal chunk seam ray hits", () => {
    const controller = new ChunkRenderController();
    const left = new Mesh(new BufferGeometry(), new MeshStandardMaterial());
    const right = new Mesh(new BufferGeometry(), new MeshStandardMaterial());
    const camera = new PerspectiveCamera();

    installFakeRaycaster(controller, [
      [makeTopHit(right, 16, 10)],
      [makeTopHit(left, 15, 10), makeTopHit(right, 16, 10.1)],
      [makeTopHit(left, 15, 10), makeTopHit(right, 16, 11)],
    ]);
    installChunkMeshes(controller, [left, right]);

    expect(controller.raycastFromCameraCenter(camera)?.occupiedMacro.x).toBe(16);
    expect(controller.raycastFromCameraCenter(camera)?.occupiedMacro.x).toBe(16);
    expect(controller.raycastFromCameraCenter(camera)?.occupiedMacro.x).toBe(15);

    controller.dispose();
    left.material.dispose();
    right.material.dispose();
  });

  it("shows a prefab micro-wire preview at the adjacent placement cells", () => {
    const controller = new ChunkRenderController();

    controller.setPrefabPreview(
      {
        occupiedMacro: { x: 1, y: 2, z: 3 },
        adjacentMacro: { x: 1, y: 3, z: 3 },
        faceNormal: { x: 0, y: 1, z: 0 },
      },
      {
        name: "builtin_sphere",
        cells: [
          { offset: { x: 0, y: 0, z: 0 }, occupancyWord: 0b1111n },
          { offset: { x: 1, y: 0, z: 0 }, occupancyWord: 0b1n },
        ],
      },
    );

    const snapshot = controller.getPrefabPreviewSnapshot();
    expect(snapshot).toMatchObject({
      visible: true,
      prefabName: "builtin_sphere",
      origin: { x: 1, y: 3, z: 3 },
      cellCount: 5,
      renderObjectCount: 1,
      renderStyle: "micro-wire",
    });
    expect(snapshot.wireSegmentCount).toBeGreaterThan(24);

    controller.setPrefabPreview(null, null);
    expect(controller.getPrefabPreviewSnapshot().visible).toBe(false);

    controller.dispose();
  });

  it("refreshes prefab micro-wire preview when micro occupancy changes within the same macro cells", () => {
    const controller = new ChunkRenderController();
    const selection = {
      occupiedMacro: { x: 1, y: 2, z: 3 },
      adjacentMacro: { x: 1, y: 3, z: 3 },
      faceNormal: { x: 0, y: 1, z: 0 },
    };

    controller.setPrefabPreview(selection, {
      name: "mutable_shape",
      cells: [{ offset: { x: 0, y: 0, z: 0 }, occupancyWord: 0b1n }],
    });
    expect(controller.getPrefabPreviewSnapshot().cellCount).toBe(1);

    controller.setPrefabPreview(selection, {
      name: "mutable_shape",
      cells: [{ offset: { x: 0, y: 0, z: 0 }, occupancyWord: 0b1111n }],
    });
    const snapshot = controller.getPrefabPreviewSnapshot();
    expect(snapshot.cellCount).toBe(4);
    expect(snapshot.renderStyle).toBe("micro-wire");

    controller.dispose();
  });

  it("renders a micro prefab ghost as one low-cost micro wire object", () => {
    const controller = new ChunkRenderController();

    controller.setPrefabRasterPreview("builtin_sphere", [
      {
        macro: { x: 2, y: 3, z: 4 },
        microOccupancyMask: 0b1111n,
        microMaterialIds: [],
        microStateFlags: [],
        microPartIds: [],
      },
    ]);

    const snapshot = controller.getPrefabPreviewSnapshot();
    expect(snapshot).toMatchObject({
      visible: true,
      prefabName: "builtin_sphere",
      origin: { x: 2, y: 3, z: 4 },
      cellCount: 4,
      renderObjectCount: 1,
      renderStyle: "micro-wire",
    });
    expect(snapshot.wireSegmentCount).toBeGreaterThan(12);

    controller.dispose();
  });

  // Phase A1-3:验证三个 builtin prefab 的 preview 真的沿 micro mask 描线框,
  // 不是退化成单 macro 方框。回归 Phase A1-1 之前的"像放置宏格一样只一个方框"
  // 的 bug(那时 SERVER_HOTBAR_ENTRIES 是 pillar/floor/cube,prefab.cells 没
  // occupancyWord,fallback 成 FullMicroOccupancyMask 整 macro 全填线框)。
  describe("Phase A1-3: builtin sphere/cylinder/stairs preview shape", () => {
    // Compile-time geometry produces:
    //   sphere ≈ 280 slots, cylinder ≈ 416 slots, stairs = 288 slots.
    // 上下界宽放,避免几何调参时小幅波动撞 boundary;主要 anchor 是
    // "至少 200(肯定不止单方框=1)" 跟"不超过整 macro 512"。
    it.each([
      ["builtin_sphere", 200, 480],
      ["builtin_cylinder", 200, 480],
      ["builtin_stairs", 200, 480],
    ])(
      "%s preview produces a non-trivial micro wire (cellCount in [%d, %d])",
      async (prefabName, minCellCount, maxCellCount) => {
        const { LocalPrefabRegistry } = await import("../voxel/prefab");
        const registry = new LocalPrefabRegistry();
        const prefab = registry.get(prefabName);
        expect(prefab, `${prefabName} should be registered`).not.toBeNull();

        const controller = new ChunkRenderController();

        controller.setPrefabPreview(
          {
            occupiedMacro: { x: 1, y: 2, z: 3 },
            adjacentMacro: { x: 1, y: 3, z: 3 },
            faceNormal: { x: 0, y: 1, z: 0 },
          },
          {
            name: prefab!.name,
            cells: prefab!.cells.map((cell) => ({
              offset: cell.offset,
              occupancyWord: cell.occupancyWord,
            })),
          },
        );

        const snapshot = controller.getPrefabPreviewSnapshot();
        expect(snapshot.visible).toBe(true);
        expect(snapshot.prefabName).toBe(prefabName);
        expect(snapshot.renderStyle).toBe("micro-wire");

        // The whole point of micro-wire preview: cellCount must reflect the
        // shape's micro mask, NOT a single macro outline (which would be 1).
        expect(snapshot.cellCount).toBeGreaterThanOrEqual(minCellCount);
        expect(snapshot.cellCount).toBeLessThanOrEqual(maxCellCount);

        // Wire segments scale with surface complexity; a single macro outline
        // is exactly 12 edges. Sphere/cylinder/stairs have hundreds.
        expect(snapshot.wireSegmentCount).toBeGreaterThan(100);

        controller.dispose();
      },
    );
  });
});

function installFakeRaycaster(
  controller: ChunkRenderController,
  hitBatches: ReturnType<typeof makeTopHit>[][],
): void {
  let callIndex = 0;
  Object.defineProperty(controller, "raycaster", {
    value: {
      setFromCamera(): void {},
      intersectObjects(): ReturnType<typeof makeTopHit>[] {
        const batch = hitBatches[Math.min(callIndex, hitBatches.length - 1)] ?? [];
        callIndex += 1;
        return batch;
      },
    },
  });
}

function installChunkMeshes(controller: ChunkRenderController, meshes: Mesh[]): void {
  Object.defineProperty(controller, "chunkMeshes", {
    value: new Map(meshes.map((mesh, index) => [`test-${index}`, mesh])),
  });
}

function chunkMeshCount(controller: ChunkRenderController): number {
  return (controller as unknown as { chunkMeshes: Map<string, unknown> }).chunkMeshes.size;
}

function pendingMeshBuildCount(controller: ChunkRenderController): number {
  return (controller as unknown as { pendingMeshBuilds: Map<string, unknown> }).pendingMeshBuilds
    .size;
}

function makeTopHit(object: Mesh, macroX: number, distance: number) {
  return {
    distance,
    point: new Vector3((macroX + 0.5) * MacroWorldSize, MacroWorldSize, MacroWorldSize / 2),
    face: {
      a: 0,
      b: 1,
      c: 2,
      materialIndex: 0,
      normal: new Vector3(0, 1, 0),
    },
    object,
  };
}
