import { describe, expect, it } from "vitest";
import { VoxelMaterialId } from "../material/catalog";
import { EVoxelCellMode } from "./core/types";
import { LocalPrefabRegistry } from "./prefab";
import { WorldStore } from "./worldStore";

function block(materialId: number) {
  return {
    materialId,
    stateFlags: 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

describe("WorldStore snapshots", () => {
  it("exports and imports normal and refined prefab cells without losing occupancy", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 1, y: 2, z: 3 }, block(VoxelMaterialId.Stone));
    const prefabs = new LocalPrefabRegistry();
    prefabs.place("builtin_sphere", { x: 4, y: 5, z: 6 }, source);

    const snapshot = source.exportSnapshot();
    const imported = new WorldStore();
    imported.importSnapshot(snapshot);

    expect(imported.getNormalBlockWorld({ x: 1, y: 2, z: 3 })?.materialId).toBe(VoxelMaterialId.Stone);
    expect(imported.getNormalBlockWorld({ x: 4, y: 5, z: 6 })?.materialId).toBe(VoxelMaterialId.Ice);

    const refinedChunk = imported.getChunk({ x: 0, y: 0, z: 0 });
    const header = refinedChunk?.getHeaderAt({ x: 4, y: 5, z: 6 });
    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(refinedChunk?.data.refinedCells[header?.payloadIndex ?? -1]?.microOccupancyMask).not.toBe(0n);
  });
});
