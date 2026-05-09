import { describe, expect, it } from "vitest";
import { MacroWorldSize } from "../voxel/core/constants";
import { ChunkRenderController } from "./chunkRenderer";

describe("ChunkRenderController hit-face outline", () => {
  it("shows one outline on the hit face instead of break/place block boxes", () => {
    const controller = new ChunkRenderController();

    controller.setTargetHighlights({
      occupiedMacro: { x: 1, y: 2, z: 3 },
      adjacentMacro: { x: 2, y: 2, z: 3 },
      faceNormal: { x: 1, y: 0, z: 0 },
    });

    const snapshot = controller.getTargetHighlightSnapshot();
    expect(snapshot.visible).toBe(true);
    expect(snapshot.kind).toBe("hit-face");
    expect(snapshot.faceNormal).toEqual({ x: 1, y: 0, z: 0 });
    expect(snapshot.position.x).toBeGreaterThan((1 + 1) * MacroWorldSize);
    expect(snapshot.position.y).toBeCloseTo((2 + 0.5) * MacroWorldSize);
    expect(snapshot.position.z).toBeCloseTo((3 + 0.5) * MacroWorldSize);

    controller.dispose();
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
