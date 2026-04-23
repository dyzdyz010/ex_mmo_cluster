import { VoxelMaterialId } from "../../material/catalog";
import { MacroWorldSize } from "../core/constants";
import { EVoxelCellMode } from "../core/types";
import { buildChunkMeshData } from "./chunkMesher";

describe("buildChunkMeshData", () => {
  it("renders refined micro occupancy instead of treating it as a full macro cube", () => {
    const mesh = buildChunkMeshData(
      {
        chunkCoord: { x: 0, y: 0, z: 0 },
        dirtyMacroMin: { x: 0, y: 0, z: 0 },
        dirtyMacroMax: { x: 0, y: 0, z: 0 },
        dirtyFlags: 0,
        cells: [
          {
            localMacroCoord: { x: 0, y: 0, z: 0 },
            mode: EVoxelCellMode.Refined,
            materialId: VoxelMaterialId.Stone,
            stateFlags: 0,
            health: 100,
            microOccupancyMask: 1n,
            microMaterialIds: [VoxelMaterialId.Stone],
            microStateFlags: [0],
          },
        ],
      },
      { isSolidWorldMacroCoord: () => false },
    );

    expect(mesh.solidBlockCount).toBe(1);
    expect(mesh.triangleCount).toBe(12);
    expect(Math.max(...mesh.positions)).toBe(MacroWorldSize / 4);
  });
});
