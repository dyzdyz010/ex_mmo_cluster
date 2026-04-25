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

  it("shows a prefab ghost preview at the adjacent macro cells", () => {
    const controller = new ChunkRenderController();

    controller.setPrefabPreview(
      {
        occupiedMacro: { x: 1, y: 2, z: 3 },
        adjacentMacro: { x: 1, y: 3, z: 3 },
        faceNormal: { x: 0, y: 1, z: 0 },
      },
      {
        name: "builtin_sphere",
        cells: [{ offset: { x: 0, y: 0, z: 0 } }, { offset: { x: 1, y: 0, z: 0 } }],
      },
    );

    expect(controller.getPrefabPreviewSnapshot()).toEqual({
      visible: true,
      prefabName: "builtin_sphere",
      origin: { x: 1, y: 3, z: 3 },
      cellCount: 2,
      renderObjectCount: 1,
      renderStyle: "wire-bounds",
      wireSegmentCount: 24,
    });

    controller.setPrefabPreview(null, null);
    expect(controller.getPrefabPreviewSnapshot().visible).toBe(false);

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
});
