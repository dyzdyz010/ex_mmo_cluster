import { describe, expect, it } from "vitest";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import { createDualSceneDemoOverlay } from "./sceneRegionOverlay";

describe("scene region overlay", () => {
  it("builds visible scene1/scene2 regions with a boundary at chunk x=1", () => {
    const overlay = createDualSceneDemoOverlay();
    const snapshot = overlay.snapshot();
    const chunkWorld = VoxelConstants.ChunkSizeInMacros * MacroWorldSize;

    expect(snapshot.visible).toBe(true);
    expect(snapshot.regions).toEqual([
      expect.objectContaining({ label: "scene1", ownerSceneInstanceRef: 1 }),
      expect.objectContaining({ label: "scene2", ownerSceneInstanceRef: 2 }),
    ]);
    expect(snapshot.boundary.chunkX).toBe(1);
    expect(snapshot.boundary.worldX).toBe(chunkWorld);
    const scene1Fill = overlay.group.getObjectByName("scene-region-fill-scene1");
    const boundary = overlay.group.getObjectByName("scene-region-boundary-x1");
    expect(scene1Fill).toBeDefined();
    expect(scene1Fill?.position.y).toBeGreaterThan(MacroWorldSize);
    expect(scene1Fill?.renderOrder).toBeGreaterThan(0);
    expect(overlay.group.getObjectByName("scene-region-fill-scene2")).toBeDefined();
    expect(boundary).toBeDefined();
    expect(boundary?.renderOrder).toBeGreaterThan(scene1Fill?.renderOrder ?? 0);
  });

  it("can be toggled for screenshots without removing diagnostics", () => {
    const overlay = createDualSceneDemoOverlay();

    overlay.setVisible(false);
    expect(overlay.group.visible).toBe(false);
    expect(overlay.snapshot().visible).toBe(false);

    overlay.setVisible(true);
    expect(overlay.group.visible).toBe(true);
    expect(overlay.snapshot().visible).toBe(true);
  });
});
