import { materialAtlasFaceUvs } from "../../material/atlas";
import { VoxelMaterialId } from "../../material/catalog";
import { MacroWorldSize, VoxelConstants } from "../core/constants";
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
    expect(Math.max(...mesh.positions)).toBe(MacroWorldSize / VoxelConstants.MicroPerMacro);
    expect(mesh.uvs).toHaveLength((mesh.positions.length / 3) * 2);
  });

  it("culls refined micro faces against occupied micro cells in adjacent macro cells", () => {
    const lookup = {
      isSolidWorldMacroCoord: () => false,
      isSolidWorldMicroCoord: (
        macro: { x: number; y: number; z: number },
        micro: { x: number; y: number; z: number },
      ) =>
        macro.x === 1 &&
        macro.y === 0 &&
        macro.z === 0 &&
        micro.x === 0 &&
        micro.y === 0 &&
        micro.z === 0,
    };
    const mesh = buildChunkMeshData(
      {
        chunkCoord: { x: 0, y: 0, z: 0 },
        dirtyMacroMin: { x: 0, y: 0, z: 0 },
        dirtyMacroMax: { x: 1, y: 0, z: 0 },
        dirtyFlags: 0,
        cells: [
          {
            localMacroCoord: { x: 0, y: 0, z: 0 },
            mode: EVoxelCellMode.Refined,
            materialId: VoxelMaterialId.Stone,
            stateFlags: 0,
            health: 100,
            microOccupancyMask: 1n << BigInt(VoxelConstants.MicroPerMacro - 1),
            microMaterialIds: new Array(VoxelConstants.MicroCountPerMacro).fill(
              VoxelMaterialId.Stone,
            ),
            microStateFlags: new Array(VoxelConstants.MicroCountPerMacro).fill(0),
          },
          {
            localMacroCoord: { x: 1, y: 0, z: 0 },
            mode: EVoxelCellMode.Refined,
            materialId: VoxelMaterialId.Wood,
            stateFlags: 0,
            health: 100,
            microOccupancyMask: 1n,
            microMaterialIds: new Array(VoxelConstants.MicroCountPerMacro).fill(
              VoxelMaterialId.Wood,
            ),
            microStateFlags: new Array(VoxelConstants.MicroCountPerMacro).fill(0),
          },
        ],
      },
      lookup,
    );

    expect(mesh.solidBlockCount).toBe(2);
    expect(mesh.triangleCount).toBe(20);
  });

  it("keeps a solid macro face visible beside a partially occupied refined prefab cell", () => {
    const mesh = buildChunkMeshData(
      {
        chunkCoord: { x: 0, y: 0, z: 0 },
        dirtyMacroMin: { x: 0, y: 0, z: 0 },
        dirtyMacroMax: { x: 1, y: 0, z: 0 },
        dirtyFlags: 0,
        cells: [
          {
            localMacroCoord: { x: 0, y: 0, z: 0 },
            mode: EVoxelCellMode.SolidBlock,
            materialId: VoxelMaterialId.Stone,
            stateFlags: 0,
            health: 100,
          },
          {
            localMacroCoord: { x: 1, y: 0, z: 0 },
            mode: EVoxelCellMode.Refined,
            materialId: VoxelMaterialId.Ice,
            stateFlags: 0,
            health: 100,
            microOccupancyMask: 1n,
            microMaterialIds: new Array(VoxelConstants.MicroCountPerMacro).fill(
              VoxelMaterialId.Ice,
            ),
            microStateFlags: new Array(VoxelConstants.MicroCountPerMacro).fill(0),
          },
        ],
      },
      {
        isSolidWorldMacroCoord: (coord) => coord.x === 1 && coord.y === 0 && coord.z === 0,
      },
    );

    expect(hasFullMacroFace(mesh, { x: 1, y: 0, z: 0 })).toBe(true);
  });

  it("assigns different mosaic atlas UV tiles for different block materials", () => {
    const dirtMesh = buildChunkMeshData(
      singleSolidBlockSnapshot(VoxelMaterialId.Dirt),
      { isSolidWorldMacroCoord: () => false },
    );
    const stoneMesh = buildChunkMeshData(
      singleSolidBlockSnapshot(VoxelMaterialId.Stone),
      { isSolidWorldMacroCoord: () => false },
    );

    expect(dirtMesh.uvs).toHaveLength((dirtMesh.positions.length / 3) * 2);
    expect(stoneMesh.uvs).toHaveLength((stoneMesh.positions.length / 3) * 2);
    expect(dirtMesh.uvs.slice(0, 8)).not.toEqual(stoneMesh.uvs.slice(0, 8));
  });

  it("maps refined micro UVs against the macro cell instead of repeating a full tile per micro cube", () => {
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
            materialId: VoxelMaterialId.Wood,
            stateFlags: 0,
            health: 100,
            microOccupancyMask: 1n,
            microMaterialIds: [VoxelMaterialId.Wood],
            microStateFlags: [0],
          },
        ],
      },
      { isSolidWorldMacroCoord: () => false },
    );

    const firstMicroFaceUvs = mesh.uvs.slice(0, 8);
    const fullMacroFaceUvs = materialAtlasFaceUvs(VoxelMaterialId.Wood);
    const microUs = [
      firstMicroFaceUvs[0]!,
      firstMicroFaceUvs[2]!,
      firstMicroFaceUvs[4]!,
      firstMicroFaceUvs[6]!,
    ];
    const macroUs = [fullMacroFaceUvs[0]!, fullMacroFaceUvs[2]!, fullMacroFaceUvs[4]!, fullMacroFaceUvs[6]!];
    const microUWidth = Math.max(...microUs) - Math.min(...microUs);
    const macroUWidth = Math.max(...macroUs) - Math.min(...macroUs);

    expect(firstMicroFaceUvs).not.toEqual(fullMacroFaceUvs);
    expect(microUWidth).toBeCloseTo(macroUWidth / VoxelConstants.MicroPerMacro);
  });

  it("projects non-zero refined micro UVs from macro-local coordinates on each face axis", () => {
    const micro = { x: 2, y: 3, z: 5 };
    const microIndex =
      micro.x +
      micro.y * VoxelConstants.MicroPerMacro +
      micro.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro;
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
            materialId: VoxelMaterialId.Ice,
            stateFlags: 0,
            health: 100,
            microOccupancyMask: 1n << BigInt(microIndex),
            microMaterialIds: new Array(VoxelConstants.MicroCountPerMacro).fill(VoxelMaterialId.Ice),
            microStateFlags: new Array(VoxelConstants.MicroCountPerMacro).fill(0),
          },
        ],
      },
      { isSolidWorldMacroCoord: () => false },
    );

    expectUvRangeForNormal(mesh, { x: 1, y: 0, z: 0 }, micro.z, micro.y);
    expectUvRangeForNormal(mesh, { x: 0, y: 1, z: 0 }, micro.x, micro.z);
    expectUvRangeForNormal(mesh, { x: 0, y: 0, z: 1 }, micro.x, micro.y);
  });
});

function singleSolidBlockSnapshot(materialId: number) {
  return {
    chunkCoord: { x: 0, y: 0, z: 0 },
    dirtyMacroMin: { x: 0, y: 0, z: 0 },
    dirtyMacroMax: { x: 0, y: 0, z: 0 },
    dirtyFlags: 0,
    cells: [
      {
        localMacroCoord: { x: 0, y: 0, z: 0 },
        mode: EVoxelCellMode.SolidBlock,
        materialId,
        stateFlags: 0,
        health: 100,
      },
    ],
  };
}

function hasFullMacroFace(
  mesh: ReturnType<typeof buildChunkMeshData>,
  normal: { x: number; y: number; z: number },
): boolean {
  for (let vertex = 0; vertex < mesh.positions.length / 3; vertex += 4) {
    const normalOffset = vertex * 3;
    if (
      mesh.normals[normalOffset] !== normal.x ||
      mesh.normals[normalOffset + 1] !== normal.y ||
      mesh.normals[normalOffset + 2] !== normal.z
    ) {
      continue;
    }

    const vertices = new Set<string>();
    for (let i = 0; i < 4; i += 1) {
      const positionOffset = (vertex + i) * 3;
      vertices.add(
        [
          mesh.positions[positionOffset],
          mesh.positions[positionOffset + 1],
          mesh.positions[positionOffset + 2],
        ].join(","),
      );
    }

    const expected = [
      [MacroWorldSize, 0, 0],
      [MacroWorldSize, MacroWorldSize, 0],
      [MacroWorldSize, MacroWorldSize, MacroWorldSize],
      [MacroWorldSize, 0, MacroWorldSize],
    ];
    if (expected.every((coord) => vertices.has(coord.join(",")))) {
      return true;
    }
  }

  return false;
}

function expectUvRangeForNormal(
  mesh: ReturnType<typeof buildChunkMeshData>,
  normal: { x: number; y: number; z: number },
  expectedUIndex: number,
  expectedVIndex: number,
): void {
  const fullMacroFaceUvs = materialAtlasFaceUvs(VoxelMaterialId.Ice);
  const macroUs = [fullMacroFaceUvs[0]!, fullMacroFaceUvs[2]!, fullMacroFaceUvs[4]!, fullMacroFaceUvs[6]!];
  const macroVs = [fullMacroFaceUvs[1]!, fullMacroFaceUvs[3]!, fullMacroFaceUvs[5]!, fullMacroFaceUvs[7]!];
  const macroUMin = Math.min(...macroUs);
  const macroVMin = Math.min(...macroVs);
  const macroUWidth = Math.max(...macroUs) - macroUMin;
  const macroVWidth = Math.max(...macroVs) - macroVMin;
  const faceUvs = uvsForNormal(mesh, normal);
  const faceUs = [faceUvs[0]!, faceUvs[2]!, faceUvs[4]!, faceUvs[6]!];
  const faceVs = [faceUvs[1]!, faceUvs[3]!, faceUvs[5]!, faceUvs[7]!];

  expect(Math.min(...faceUs)).toBeCloseTo(
    macroUMin + (macroUWidth * expectedUIndex) / VoxelConstants.MicroPerMacro,
  );
  expect(Math.max(...faceUs)).toBeCloseTo(
    macroUMin + (macroUWidth * (expectedUIndex + 1)) / VoxelConstants.MicroPerMacro,
  );
  expect(Math.min(...faceVs)).toBeCloseTo(
    macroVMin + (macroVWidth * expectedVIndex) / VoxelConstants.MicroPerMacro,
  );
  expect(Math.max(...faceVs)).toBeCloseTo(
    macroVMin + (macroVWidth * (expectedVIndex + 1)) / VoxelConstants.MicroPerMacro,
  );
}

function uvsForNormal(
  mesh: ReturnType<typeof buildChunkMeshData>,
  normal: { x: number; y: number; z: number },
): number[] {
  for (let vertex = 0; vertex < mesh.positions.length / 3; vertex += 4) {
    const normalOffset = vertex * 3;
    if (
      mesh.normals[normalOffset] === normal.x &&
      mesh.normals[normalOffset + 1] === normal.y &&
      mesh.normals[normalOffset + 2] === normal.z
    ) {
      return mesh.uvs.slice((vertex / 4) * 8, (vertex / 4 + 1) * 8);
    }
  }

  throw new Error(`missing face normal ${normal.x},${normal.y},${normal.z}`);
}
