import { EVoxelRotation, chunkCoordKey, type FMacroCoord } from "./core/types";
import { chunkCoordFromMacro } from "./core/gridUtils";
import { VoxelConstants } from "./core/constants";
import { VoxelMaterialId } from "../material/catalog";
import type {
  FNormalBlockData,
  FPrefabDefinitionData,
  FPrefabInstanceData,
  FPrefabPartDefinition,
} from "./storage/types";
import type { WorldStore } from "./worldStore";

export const FULL_MACRO_OCCUPANCY_WORD = (1n << 64n) - 1n;

export interface PrefabBlock {
  offset: FMacroCoord;
  block: FNormalBlockData;
}

interface PrefabCell {
  offset: FMacroCoord;
  occupancyWord: bigint;
  materialId: number;
  stateFlags: number;
  microPartIds: number[];
}

export interface LocalPrefab {
  name: string;
  boundsMin: FMacroCoord;
  boundsMax: FMacroCoord;
  definition: FPrefabDefinitionData;
  blocks: PrefabBlock[];
  cells: PrefabCell[];
}

export class LocalPrefabRegistry {
  private readonly prefabs = new Map<string, LocalPrefab>();
  private nextInstanceId = 1;

  constructor() {
    for (const prefab of buildBuiltinPrefabs()) {
      this.prefabs.set(prefab.name, prefab);
    }
  }

  capture(name: string, min: FMacroCoord, max: FMacroCoord, world: WorldStore): LocalPrefab {
    const boundsMin = normalizeBoundsMin(min, max);
    const boundsMax = normalizeBoundsMax(min, max);
    const blocks: PrefabBlock[] = [];
    const cells: PrefabCell[] = [];
    const occupancyWords: bigint[] = [];
    const materialChannels: number[] = [];
    const partDefinitions: FPrefabPartDefinition[] = [];
    const microPartIds: number[] = [];

    for (let x = boundsMin.x; x <= boundsMax.x; x += 1) {
      for (let y = boundsMin.y; y <= boundsMax.y; y += 1) {
        for (let z = boundsMin.z; z <= boundsMax.z; z += 1) {
          const coord = { x, y, z };
          const block = world.getNormalBlockWorld(coord);
          if (!block) {
            occupancyWords.push(0n);
            materialChannels.push(0);
            microPartIds.push(...new Array(64).fill(-1));
            continue;
          }

          const partId = `${name}_part_${partDefinitions.length}`;
          partDefinitions.push({
            partId,
            partTags: ["captured", "macro_block"],
            defaultAffordances: ["break", "move"],
            defaultHealth: block.health,
            materialPolicy: "inherit",
          });
          const partIndex = partDefinitions.length - 1;
          occupancyWords.push(FULL_MACRO_OCCUPANCY_WORD);
          materialChannels.push(block.materialId);
          microPartIds.push(...new Array(64).fill(partIndex));
          cells.push({
            offset: {
              x: coord.x - boundsMin.x,
              y: coord.y - boundsMin.y,
              z: coord.z - boundsMin.z,
            },
            occupancyWord: FULL_MACRO_OCCUPANCY_WORD,
            materialId: block.materialId,
            stateFlags: block.stateFlags,
            microPartIds: new Array(64).fill(partIndex),
          });
          blocks.push({
            offset: {
              x: coord.x - boundsMin.x,
              y: coord.y - boundsMin.y,
              z: coord.z - boundsMin.z,
            },
            block: { ...block },
          });
        }
      }
    }

    const definition: FPrefabDefinitionData = {
      prefabId: name,
      boundsInMacroCells: {
        x: boundsMax.x - boundsMin.x + 1,
        y: boundsMax.y - boundsMin.y + 1,
        z: boundsMax.z - boundsMin.z + 1,
      },
      microResolution: VoxelConstants.MicroPerMacro,
      occupancyWords,
      materialChannels,
      partDefinitions,
      microPartIds,
      allowedRotations: [
        EVoxelRotation.Rot0,
        EVoxelRotation.Rot90,
        EVoxelRotation.Rot180,
        EVoxelRotation.Rot270,
      ],
      boundarySignature: buildBoundarySignature(occupancyWords, {
        x: boundsMax.x - boundsMin.x + 1,
        y: boundsMax.y - boundsMin.y + 1,
        z: boundsMax.z - boundsMin.z + 1,
      }),
      tags: [],
    };
    const prefab: LocalPrefab = { name, boundsMin, boundsMax, definition, blocks, cells };
    this.prefabs.set(name, prefab);
    return prefab;
  }

  place(
    name: string,
    origin: FMacroCoord,
    world: WorldStore,
    rotation: EVoxelRotation = EVoxelRotation.Rot0,
  ): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean } {
    const prefab = this.prefabs.get(name);
    if (!prefab) {
      return { ok: false, placed: 0 };
    }

    const transformedCells = transformPrefabCells(prefab.cells, rotation);
    if (wouldOverwriteExistingCells(transformedCells, origin, world)) {
      world.markConflict();
      return { ok: false, placed: 0, conflict: true };
    }

    const instanceId = this.nextInstanceId;
    this.nextInstanceId += 1;

    let placed = 0;
    for (const entry of transformedCells) {
      const coord = {
        x: origin.x + entry.offset.x,
        y: origin.y + entry.offset.y,
        z: origin.z + entry.offset.z,
      };

      if (world.setPrefabRefinedMicroCellWorld(
        coord,
        entry.occupancyWord,
        entry.materialId,
        entry.stateFlags,
        entry.microPartIds,
        instanceId,
      )) {
        placed += 1;
      }
    }

    const coveredMacroMin = { ...origin };
    const transformedBounds = boundsFromCells(transformedCells);
    const coveredMacroMax = {
      x: origin.x + transformedBounds.x,
      y: origin.y + transformedBounds.y,
      z: origin.z + transformedBounds.z,
    };
    const ownerChunk = chunkCoordFromMacro(origin);
    const instance: FPrefabInstanceData = {
      instanceId,
      prefabId: prefab.definition.prefabId,
      anchorMicroCoord: macroToMicroCoord(origin),
      rotation,
      ownerChunk,
      coveredMacroMin,
      coveredMacroMax,
      overrideSetIndex: 0,
    };
    recordInstanceInCoveredChunks(transformedCells, origin, world, instance);

    return { ok: true, placed, instanceId };
  }

  list(): LocalPrefab[] {
    return [...this.prefabs.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  get(name: string): LocalPrefab | null {
    return this.prefabs.get(name) ?? null;
  }
}

function macroToMicroCoord(coord: FMacroCoord): FMacroCoord {
  return {
    x: coord.x * VoxelConstants.MicroPerMacro,
    y: coord.y * VoxelConstants.MicroPerMacro,
    z: coord.z * VoxelConstants.MicroPerMacro,
  };
}

function buildBoundarySignature(occupancyWords: bigint[], bounds: FMacroCoord): number[] {
  const faces = [0, 0, 0, 0, 0, 0];
  for (let x = 0; x < bounds.x; x += 1) {
    for (let y = 0; y < bounds.y; y += 1) {
      for (let z = 0; z < bounds.z; z += 1) {
        const word = occupancyWords[prefabLinearIndex({ x, y, z }, bounds)] ?? 0n;
        if (word === 0n) {
          continue;
        }
        if (x === 0) faces[0] = (faces[0] ?? 0) + 1;
        if (x === bounds.x - 1) faces[1] = (faces[1] ?? 0) + 1;
        if (y === 0) faces[2] = (faces[2] ?? 0) + 1;
        if (y === bounds.y - 1) faces[3] = (faces[3] ?? 0) + 1;
        if (z === 0) faces[4] = (faces[4] ?? 0) + 1;
        if (z === bounds.z - 1) faces[5] = (faces[5] ?? 0) + 1;
      }
    }
  }
  return faces;
}

function prefabLinearIndex(coord: FMacroCoord, bounds: FMacroCoord): number {
  return coord.z + (coord.y * bounds.z) + (coord.x * bounds.y * bounds.z);
}

function transformPrefabCells(cells: PrefabCell[], rotation: EVoxelRotation): PrefabCell[] {
  const rotated = cells.map((entry) => ({
    offset: rotateOffset(entry.offset, rotation),
    occupancyWord: rotateOccupancyWord(entry.occupancyWord, rotation),
    materialId: entry.materialId,
    stateFlags: entry.stateFlags,
    microPartIds: rotateMicroPartIds(entry.microPartIds, rotation),
  }));

  if (rotated.length === 0) {
    return rotated;
  }

  const min = rotated.reduce(
    (acc, entry) => ({
      x: Math.min(acc.x, entry.offset.x),
      y: Math.min(acc.y, entry.offset.y),
      z: Math.min(acc.z, entry.offset.z),
    }),
    { ...rotated[0]!.offset },
  );

  return rotated.map((entry) => ({
    offset: {
      x: entry.offset.x - min.x,
      y: entry.offset.y - min.y,
      z: entry.offset.z - min.z,
    },
    occupancyWord: entry.occupancyWord,
    materialId: entry.materialId,
    stateFlags: entry.stateFlags,
    microPartIds: entry.microPartIds,
  }));
}

function rotateOffset(offset: FMacroCoord, rotation: EVoxelRotation): FMacroCoord {
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: -offset.z, y: offset.y, z: offset.x };
    case EVoxelRotation.Rot180:
      return { x: -offset.x, y: offset.y, z: -offset.z };
    case EVoxelRotation.Rot270:
      return { x: offset.z, y: offset.y, z: -offset.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...offset };
  }
}

function boundsFromCells(cells: PrefabCell[]): FMacroCoord {
  if (cells.length === 0) {
    return { x: 0, y: 0, z: 0 };
  }

  return cells.reduce(
    (acc, entry) => ({
      x: Math.max(acc.x, entry.offset.x),
      y: Math.max(acc.y, entry.offset.y),
      z: Math.max(acc.z, entry.offset.z),
    }),
    { ...cells[0]!.offset },
  );
}

function wouldOverwriteExistingCells(cells: PrefabCell[], origin: FMacroCoord, world: WorldStore): boolean {
  return cells.some((entry) =>
    world.getNormalBlockWorld({
      x: origin.x + entry.offset.x,
      y: origin.y + entry.offset.y,
      z: origin.z + entry.offset.z,
    }) !== null
  );
}

function recordInstanceInCoveredChunks(
  cells: PrefabCell[],
  origin: FMacroCoord,
  world: WorldStore,
  instance: FPrefabInstanceData,
): void {
  const touched = new Set<string>();
  for (const entry of cells) {
    const chunkCoord = chunkCoordFromMacro({
      x: origin.x + entry.offset.x,
      y: origin.y + entry.offset.y,
      z: origin.z + entry.offset.z,
    });
    const key = chunkCoordKey(chunkCoord);
    if (touched.has(key)) {
      continue;
    }
    touched.add(key);
    world.ensureChunk(chunkCoord).addPrefabInstance(instance);
  }

  if (touched.size === 0) {
    world.ensureChunk(instance.ownerChunk).addPrefabInstance(instance);
  }
}

function rotateOccupancyWord(word: bigint, rotation: EVoxelRotation): bigint {
  if (rotation === EVoxelRotation.Rot0 || word === 0n) {
    return word;
  }

  let out = 0n;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const from = microLinearIndex({ x, y, z });
        if ((word & (1n << BigInt(from))) === 0n) {
          continue;
        }
        const toCoord = rotateMicroCoord({ x, y, z }, rotation);
        out |= 1n << BigInt(microLinearIndex(toCoord));
      }
    }
  }
  return out;
}

function rotateMicroPartIds(partIds: number[], rotation: EVoxelRotation): number[] {
  const source = normalizedMicroPartIds(partIds);
  if (rotation === EVoxelRotation.Rot0) {
    return source;
  }

  const out = new Array(64).fill(-1);
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const from = microLinearIndex({ x, y, z });
        const to = microLinearIndex(rotateMicroCoord({ x, y, z }, rotation));
        out[to] = source[from] ?? -1;
      }
    }
  }
  return out;
}

function normalizedMicroPartIds(partIds: number[]): number[] {
  const out = new Array(64).fill(-1);
  for (let index = 0; index < Math.min(partIds.length, 64); index += 1) {
    out[index] = partIds[index] ?? -1;
  }
  return out;
}

function rotateMicroCoord(coord: FMacroCoord, rotation: EVoxelRotation): FMacroCoord {
  const max = VoxelConstants.MicroPerMacro - 1;
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: max - coord.z, y: coord.y, z: coord.x };
    case EVoxelRotation.Rot180:
      return { x: max - coord.x, y: coord.y, z: max - coord.z };
    case EVoxelRotation.Rot270:
      return { x: coord.z, y: coord.y, z: max - coord.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...coord };
  }
}

function microLinearIndex(coord: FMacroCoord): number {
  return coord.x
    + (coord.y * VoxelConstants.MicroPerMacro)
    + (coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro);
}

function buildBuiltinPrefabs(): LocalPrefab[] {
  return [
    buildBuiltinPrefab("builtin_cylinder", makeCylinderOccupancy(), VoxelMaterialId.Stone, ["builtin", "cylinder", "curved"]),
    buildBuiltinPrefab("builtin_sphere", makeSphereOccupancy(), VoxelMaterialId.Ice, ["builtin", "sphere", "curved"]),
    buildBuiltinPrefab("builtin_stairs", makeStairsOccupancy(), VoxelMaterialId.Wood, ["builtin", "stairs"]),
  ];
}

function buildBuiltinPrefab(
  name: string,
  occupancyWord: bigint,
  materialId: number,
  tags: string[],
): LocalPrefab {
  const partDefinitions: FPrefabPartDefinition[] = [{
    partId: "body",
    partTags: tags,
    defaultAffordances: builtinAffordances(tags),
    defaultHealth: 100,
    materialPolicy: "fixed",
  }];
  const microPartIds = partIdsFromOccupancy(occupancyWord, 0);
  const definition: FPrefabDefinitionData = {
    prefabId: name,
    boundsInMacroCells: { x: 1, y: 1, z: 1 },
    microResolution: VoxelConstants.MicroPerMacro,
    occupancyWords: [occupancyWord],
    materialChannels: [materialId],
    partDefinitions,
    microPartIds,
    allowedRotations: [
      EVoxelRotation.Rot0,
      EVoxelRotation.Rot90,
      EVoxelRotation.Rot180,
      EVoxelRotation.Rot270,
    ],
    boundarySignature: buildBoundarySignature([occupancyWord], { x: 1, y: 1, z: 1 }),
    tags,
  };

  return {
    name,
    boundsMin: { x: 0, y: 0, z: 0 },
    boundsMax: { x: 0, y: 0, z: 0 },
    definition,
    blocks: [],
    cells: [{ offset: { x: 0, y: 0, z: 0 }, occupancyWord, materialId, stateFlags: 0, microPartIds }],
  };
}

function partIdsFromOccupancy(occupancyWord: bigint, partIndex: number): number[] {
  const ids = new Array(64).fill(-1);
  for (let index = 0; index < 64; index += 1) {
    if ((occupancyWord & (1n << BigInt(index))) !== 0n) {
      ids[index] = partIndex;
    }
  }
  return ids;
}

function builtinAffordances(tags: string[]): string[] {
  if (tags.includes("sphere")) {
    return ["break", "freeze", "melt"];
  }
  if (tags.includes("stairs")) {
    return ["break", "climb"];
  }
  return ["break", "move"];
}

function makeSphereOccupancy(): bigint {
  let mask = 0n;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const dx = x + 0.5 - 2;
        const dy = y + 0.5 - 2;
        const dz = z + 0.5 - 2;
        if ((dx * dx) + (dy * dy) + (dz * dz) <= 3.05) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

function makeCylinderOccupancy(): bigint {
  let mask = 0n;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const dx = x + 0.5 - 2;
        const dz = z + 0.5 - 2;
        if ((dx * dx) + (dz * dz) <= 3.05) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

function makeStairsOccupancy(): bigint {
  let mask = 0n;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        if (y <= x) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

function normalizeBoundsMin(a: FMacroCoord, b: FMacroCoord): FMacroCoord {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    z: Math.min(a.z, b.z),
  };
}

function normalizeBoundsMax(a: FMacroCoord, b: FMacroCoord): FMacroCoord {
  return {
    x: Math.max(a.x, b.x),
    y: Math.max(a.y, b.y),
    z: Math.max(a.z, b.z),
  };
}
