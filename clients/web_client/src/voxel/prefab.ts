import { EVoxelRotation, chunkCoordKey, type FMacroCoord, type FMicroCoord } from "./core/types";
import { chunkCoordFromMacro } from "./core/gridUtils";
import { VoxelConstants } from "./core/constants";
import { FullMicroOccupancyMask, MicroGridSlotCount } from "./microgrid/governance";
import { VoxelMaterialId } from "../material/catalog";
import type {
  FNormalBlockData,
  FPrefabBoundaryFaceMasks,
  FPrefabDefinitionData,
  FPrefabInstanceData,
  FPrefabPartDefinition,
  FPrefabSocketDefinition,
} from "./storage/types";
import type { WorldStore } from "./worldStore";

export const FULL_MACRO_OCCUPANCY_WORD = FullMicroOccupancyMask;
const MICRO_SLOT_COORDS = buildMicroSlotCoords();
const MICRO_SLOT_BITS = MICRO_SLOT_COORDS.map((_, index) => 1n << BigInt(index));

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

export interface PrefabRasterCell {
  macro: FMacroCoord;
  microOccupancyMask: bigint;
  microMaterialIds: number[];
  microStateFlags: number[];
  microPartIds: number[];
}

interface RasterizedPrefab {
  cells: PrefabRasterCell[];
  occupiedWorldMicro: FMicroCoord[];
  incomingOccupiedSlots: number;
}

export interface PrefabSocketSnapRequest {
  prefabName: string;
  targetInstanceId: number;
  targetSocketId: string;
  incomingSocketId?: string;
  rotation?: EVoxelRotation;
}

export interface PrefabSocketSnapPreview {
  ok: boolean;
  prefabId: string;
  targetInstanceId: number;
  targetSocketId: string;
  socketId: string | null;
  anchorMicroCoord: FMicroCoord | null;
  affectedMacroCount: number;
  incomingOccupiedSlots: number;
  overlapSlots: number;
  contactSlots: number;
  cells: PrefabRasterCell[];
  rejectReason?: string;
}

export interface PrefabSocketSnapResult {
  ok: boolean;
  placed: number;
  instanceId?: number;
  conflict?: boolean;
  rejectReason?: string;
  preview?: PrefabSocketSnapPreview;
}

export interface PrefabBoundarySnapRequest {
  prefabName: string;
  hitMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  hitMicro?: FMicroCoord;
  rotation?: EVoxelRotation;
  searchRadius?: number;
}

export interface PrefabBoundarySnapPreview {
  ok: boolean;
  prefabId: string;
  hitMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  anchorMicroCoord: FMicroCoord | null;
  affectedMacroCount: number;
  incomingOccupiedSlots: number;
  overlapSlots: number;
  contactSlots: number;
  cells: PrefabRasterCell[];
  rejectReason?: string;
}

export interface PrefabBoundarySnapResult {
  ok: boolean;
  placed: number;
  instanceId?: number;
  conflict?: boolean;
  rejectReason?: string;
  preview?: PrefabBoundarySnapPreview;
}

export interface PrefabSocketSnapTarget {
  instanceId: number;
  socketId: string;
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
            microPartIds.push(...new Array(MicroGridSlotCount).fill(-1));
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
          microPartIds.push(...new Array(MicroGridSlotCount).fill(partIndex));
          cells.push({
            offset: {
              x: coord.x - boundsMin.x,
              y: coord.y - boundsMin.y,
              z: coord.z - boundsMin.z,
            },
            occupancyWord: FULL_MACRO_OCCUPANCY_WORD,
            materialId: block.materialId,
            stateFlags: block.stateFlags,
            microPartIds: new Array(MicroGridSlotCount).fill(partIndex),
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

    const boundsInMacroCells = {
      x: boundsMax.x - boundsMin.x + 1,
      y: boundsMax.y - boundsMin.y + 1,
      z: boundsMax.z - boundsMin.z + 1,
    };
    const boundaryFaceMasks = buildBoundaryFaceMasks(occupancyWords, boundsInMacroCells);
    const definition: FPrefabDefinitionData = {
      prefabId: name,
      boundsInMacroCells,
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
      boundarySignature: buildBoundarySignature(occupancyWords, boundsInMacroCells),
      boundaryFaceMasks,
      sockets: buildCapturedSockets(name, boundsInMacroCells, boundaryFaceMasks),
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

    const anchorMicroCoord = macroToMicroCoord(origin);
    const cells = rasterizePrefab(prefab, rotation, anchorMicroCoord);
    if (countOverlapSlots(cells, world) > 0) {
      world.markConflict();
      return { ok: false, placed: 0, conflict: true };
    }

    const instanceId = this.nextInstanceId;
    this.nextInstanceId += 1;

    let placed = 0;
    for (const entry of cells) {
      if (
        world.unionPrefabRefinedMicroCellWorld(
          entry.macro,
          entry.microOccupancyMask,
          entry.microMaterialIds,
          entry.microStateFlags,
          entry.microPartIds,
          instanceId,
        )
      ) {
        placed += 1;
      }
    }

    const { min: coveredMacroMin, max: coveredMacroMax } = boundsFromRasterCells(cells, origin);
    const ownerChunk = chunkCoordFromMacro(origin);
    const instance: FPrefabInstanceData = {
      instanceId,
      prefabId: prefab.definition.prefabId,
      anchorMicroCoord,
      rotation,
      ownerChunk,
      coveredMacroMin,
      coveredMacroMax,
      overrideSetIndex: 0,
    };
    recordInstanceInCoveredChunks(cells, world, instance);

    return { ok: true, placed, instanceId };
  }

  previewSocketSnap(request: PrefabSocketSnapRequest, world: WorldStore): PrefabSocketSnapPreview {
    return previewSocketSnap(this.prefabs, request, world);
  }

  placeSocketSnap(request: PrefabSocketSnapRequest, world: WorldStore): PrefabSocketSnapResult {
    const preview = this.previewSocketSnap(request, world);
    if (!preview.ok || !preview.anchorMicroCoord) {
      if (preview.rejectReason === "micro_overlap") {
        world.markConflict();
      }
      return {
        ok: false,
        placed: 0,
        conflict: preview.rejectReason === "micro_overlap",
        ...(preview.rejectReason ? { rejectReason: preview.rejectReason } : {}),
        preview,
      };
    }

    const instanceId = this.nextInstanceId;
    this.nextInstanceId += 1;
    let placed = 0;
    for (const entry of preview.cells) {
      if (
        world.unionPrefabRefinedMicroCellWorld(
          entry.macro,
          entry.microOccupancyMask,
          entry.microMaterialIds,
          entry.microStateFlags,
          entry.microPartIds,
          instanceId,
        )
      ) {
        placed += 1;
      }
    }

    const { min: coveredMacroMin, max: coveredMacroMax } = boundsFromRasterCells(preview.cells);
    const instance: FPrefabInstanceData = {
      instanceId,
      prefabId: preview.prefabId,
      anchorMicroCoord: { ...preview.anchorMicroCoord },
      rotation: request.rotation ?? EVoxelRotation.Rot0,
      ownerChunk: chunkCoordFromMicro(preview.anchorMicroCoord),
      coveredMacroMin,
      coveredMacroMax,
      overrideSetIndex: 0,
    };
    recordInstanceInCoveredChunks(preview.cells, world, instance);

    return { ok: true, placed, instanceId, preview };
  }

  previewBoundarySnap(
    request: PrefabBoundarySnapRequest,
    world: WorldStore,
  ): PrefabBoundarySnapPreview {
    return previewBoundarySnap(this.prefabs, request, world);
  }

  placeBoundarySnap(
    request: PrefabBoundarySnapRequest,
    world: WorldStore,
  ): PrefabBoundarySnapResult {
    const preview = this.previewBoundarySnap(request, world);
    if (!preview.ok || !preview.anchorMicroCoord) {
      if (preview.rejectReason === "micro_overlap") {
        world.markConflict();
      }
      return {
        ok: false,
        placed: 0,
        conflict: preview.rejectReason === "micro_overlap",
        ...(preview.rejectReason ? { rejectReason: preview.rejectReason } : {}),
        preview,
      };
    }

    const instanceId = this.nextInstanceId;
    this.nextInstanceId += 1;
    let placed = 0;
    for (const entry of preview.cells) {
      if (
        world.unionPrefabRefinedMicroCellWorld(
          entry.macro,
          entry.microOccupancyMask,
          entry.microMaterialIds,
          entry.microStateFlags,
          entry.microPartIds,
          instanceId,
        )
      ) {
        placed += 1;
      }
    }

    const { min: coveredMacroMin, max: coveredMacroMax } = boundsFromRasterCells(preview.cells);
    const instance: FPrefabInstanceData = {
      instanceId,
      prefabId: preview.prefabId,
      anchorMicroCoord: { ...preview.anchorMicroCoord },
      rotation: request.rotation ?? EVoxelRotation.Rot0,
      ownerChunk: chunkCoordFromMicro(preview.anchorMicroCoord),
      coveredMacroMin,
      coveredMacroMax,
      overrideSetIndex: 0,
    };
    recordInstanceInCoveredChunks(preview.cells, world, instance);

    return { ok: true, placed, instanceId, preview };
  }

  findSocketSnapTarget(
    world: WorldStore,
    macro: FMacroCoord,
    faceNormal: FMacroCoord,
  ): PrefabSocketSnapTarget | null {
    const candidates = new Map<number, FPrefabInstanceData>();
    for (const chunk of world.listChunks()) {
      for (const instance of chunk.data.prefabInstances) {
        if (candidates.has(instance.instanceId)) {
          continue;
        }
        if (macroWithinBounds(macro, instance.coveredMacroMin, instance.coveredMacroMax)) {
          candidates.set(instance.instanceId, instance);
        }
      }
    }

    for (const instance of candidates.values()) {
      const prefab = this.prefabs.get(instance.prefabId);
      if (!prefab) {
        continue;
      }
      const socket = prefab.definition.sockets
        .map((candidate) =>
          transformSocket(candidate, prefab.definition.boundsInMacroCells, instance.rotation),
        )
        .filter((candidate) => sameCoord(candidate.normal, faceNormal))
        .sort((a, b) => b.priority - a.priority || a.socketId.localeCompare(b.socketId))[0];
      if (socket) {
        return { instanceId: instance.instanceId, socketId: socket.socketId };
      }
    }
    return null;
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

function buildMicroSlotCoords(): FMicroCoord[] {
  const coords: FMicroCoord[] = [];
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        coords[microLinearIndex({ x, y, z })] = { x, y, z };
      }
    }
  }
  return coords;
}

function getOrCreateWeakCachedMap<K extends object, MK, MV>(
  cache: WeakMap<K, Map<MK, MV>>,
  key: K,
): Map<MK, MV> {
  const existing = cache.get(key);
  if (existing) {
    return existing;
  }
  const created = new Map<MK, MV>();
  cache.set(key, created);
  return created;
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

function buildBoundaryFaceMasks(
  occupancyWords: bigint[],
  bounds: FMacroCoord,
): FPrefabBoundaryFaceMasks {
  const masks: FPrefabBoundaryFaceMasks = {
    negX: 0n,
    posX: 0n,
    negY: 0n,
    posY: 0n,
    negZ: 0n,
    posZ: 0n,
  };

  for (let x = 0; x < bounds.x; x += 1) {
    for (let y = 0; y < bounds.y; y += 1) {
      for (let z = 0; z < bounds.z; z += 1) {
        const word = occupancyWords[prefabLinearIndex({ x, y, z }, bounds)] ?? 0n;
        if (word === 0n) {
          continue;
        }
        if (x === 0) masks.negX |= extractBoundaryFaceMask(word, "negX");
        if (x === bounds.x - 1) masks.posX |= extractBoundaryFaceMask(word, "posX");
        if (y === 0) masks.negY |= extractBoundaryFaceMask(word, "negY");
        if (y === bounds.y - 1) masks.posY |= extractBoundaryFaceMask(word, "posY");
        if (z === 0) masks.negZ |= extractBoundaryFaceMask(word, "negZ");
        if (z === bounds.z - 1) masks.posZ |= extractBoundaryFaceMask(word, "posZ");
      }
    }
  }

  return masks;
}

function extractBoundaryFaceMask(word: bigint, face: BoundaryFaceName): bigint {
  let mask = 0n;
  const max = VoxelConstants.MicroPerMacro - 1;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        if (!isCoordOnFace({ x, y, z }, face, max)) {
          continue;
        }
        const sourceIndex = microLinearIndex({ x, y, z });
        if ((word & (1n << BigInt(sourceIndex))) === 0n) {
          continue;
        }
        mask |= 1n << BigInt(boundaryFaceLinearIndex({ x, y, z }, face));
      }
    }
  }
  return mask;
}

type BoundaryFaceName = keyof FPrefabBoundaryFaceMasks;

function isCoordOnFace(coord: FMicroCoord, face: BoundaryFaceName, max: number): boolean {
  switch (face) {
    case "negX":
      return coord.x === 0;
    case "posX":
      return coord.x === max;
    case "negY":
      return coord.y === 0;
    case "posY":
      return coord.y === max;
    case "negZ":
      return coord.z === 0;
    case "posZ":
      return coord.z === max;
  }
}

function boundaryFaceLinearIndex(coord: FMicroCoord, face: BoundaryFaceName): number {
  switch (face) {
    case "negX":
    case "posX":
      return coord.y + coord.z * VoxelConstants.MicroPerMacro;
    case "negY":
    case "posY":
      return coord.x + coord.z * VoxelConstants.MicroPerMacro;
    case "negZ":
    case "posZ":
      return coord.x + coord.y * VoxelConstants.MicroPerMacro;
  }
}

function prefabLinearIndex(coord: FMacroCoord, bounds: FMacroCoord): number {
  return coord.z + coord.y * bounds.z + coord.x * bounds.y * bounds.z;
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

function rasterizePrefab(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
  anchorMicroCoord: FMicroCoord,
): PrefabRasterCell[] {
  return rasterizePrefabDetailed(prefab, rotation, anchorMicroCoord).cells;
}

function rasterizePrefabDetailed(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
  anchorMicroCoord: FMicroCoord,
): RasterizedPrefab {
  const grouped = new Map<string, PrefabRasterCell>();
  const occupiedWorldMicro: FMicroCoord[] = [];
  for (const point of listPrefabOccupiedLocalPoints(prefab, rotation)) {
    const worldMicro = addMicroCoord(anchorMicroCoord, point.localMicro);
    occupiedWorldMicro.push(worldMicro);
    const macro = macroCoordFromMicro(worldMicro);
    const micro = localMicroCoordFromWorldMicro(worldMicro);
    const targetIndex = microLinearIndex(micro);
    const cell = getOrCreateRasterCell(grouped, macro);
    cell.microOccupancyMask |= MICRO_SLOT_BITS[targetIndex] ?? 0n;
    cell.microMaterialIds[targetIndex] = point.materialId;
    cell.microStateFlags[targetIndex] = point.stateFlags;
    cell.microPartIds[targetIndex] = point.partId;
  }

  return {
    cells: [...grouped.values()].sort((a, b) => coordKey(a.macro).localeCompare(coordKey(b.macro))),
    occupiedWorldMicro,
    incomingOccupiedSlots: occupiedWorldMicro.length,
  };
}

function getOrCreateRasterCell(
  grouped: Map<string, PrefabRasterCell>,
  macro: FMacroCoord,
): PrefabRasterCell {
  const key = coordKey(macro);
  const existing = grouped.get(key);
  if (existing) {
    return existing;
  }
  const cell: PrefabRasterCell = {
    macro,
    microOccupancyMask: 0n,
    microMaterialIds: new Array(MicroGridSlotCount).fill(0),
    microStateFlags: new Array(MicroGridSlotCount).fill(0),
    microPartIds: new Array(MicroGridSlotCount).fill(-1),
  };
  grouped.set(key, cell);
  return cell;
}

function countOverlapSlots(cells: PrefabRasterCell[], world: WorldStore): number {
  return cells.reduce(
    (sum, cell) =>
      sum + countBits(world.getMicroOccupancyMaskWorld(cell.macro) & cell.microOccupancyMask),
    0,
  );
}

function boundsFromRasterCells(
  cells: PrefabRasterCell[],
  fallback: FMacroCoord = { x: 0, y: 0, z: 0 },
): { min: FMacroCoord; max: FMacroCoord } {
  if (cells.length === 0) {
    return { min: { ...fallback }, max: { ...fallback } };
  }

  const first = cells[0]!.macro;
  return cells.reduce(
    (acc, entry) => ({
      min: {
        x: Math.min(acc.min.x, entry.macro.x),
        y: Math.min(acc.min.y, entry.macro.y),
        z: Math.min(acc.min.z, entry.macro.z),
      },
      max: {
        x: Math.max(acc.max.x, entry.macro.x),
        y: Math.max(acc.max.y, entry.macro.y),
        z: Math.max(acc.max.z, entry.macro.z),
      },
    }),
    { min: { ...first }, max: { ...first } },
  );
}

function recordInstanceInCoveredChunks(
  cells: PrefabRasterCell[],
  world: WorldStore,
  instance: FPrefabInstanceData,
): void {
  const touched = new Set<string>();
  for (const entry of cells) {
    const chunkCoord = chunkCoordFromMacro(entry.macro);
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

interface LocalMicroPoint {
  localMicro: FMicroCoord;
}

interface LocalOccupiedMicroPoint extends LocalMicroPoint {
  sourceIndex: number;
  materialId: number;
  stateFlags: number;
  partId: number;
}

interface WorldBoundaryPoint {
  worldMicro: FMicroCoord;
  localMicro: FMicroCoord;
  hitDistance: number;
}

interface BoundaryCandidate {
  preview: PrefabBoundarySnapPreview;
  hitDistance: number;
  anchorDistance: number;
}

interface AnchorCandidate {
  anchorMicroCoord: FMicroCoord;
  hitDistance: number;
  anchorDistance: number;
}

const occupiedMicroPointCache = new WeakMap<LocalPrefab, Map<EVoxelRotation, LocalOccupiedMicroPoint[]>>();
const boundaryPointCache = new WeakMap<LocalPrefab, Map<string, LocalMicroPoint[]>>();

function previewBoundarySnap(
  prefabs: Map<string, LocalPrefab>,
  request: PrefabBoundarySnapRequest,
  world: WorldStore,
): PrefabBoundarySnapPreview {
  const incoming = prefabs.get(request.prefabName);
  if (!incoming) {
    return rejectedBoundaryPreview(request, "unknown_prefab");
  }
  if (!isUnitAxisNormal(request.faceNormal)) {
    return rejectedBoundaryPreview(request, "invalid_face_normal", incoming.definition.prefabId);
  }

  const rotation = request.rotation ?? EVoxelRotation.Rot0;
  const incomingBoundary = listPrefabBoundaryPoints(incoming, rotation, request.faceNormal);
  if (incomingBoundary.length === 0) {
    return rejectedBoundaryPreview(request, "empty_prefab", incoming.definition.prefabId);
  }

  const searchRadius = Math.max(0, request.searchRadius ?? VoxelConstants.MicroPerMacro - 1);
  const targetBoundary = listWorldBoundaryPoints(world, request, searchRadius);
  if (targetBoundary.length === 0) {
    return rejectedBoundaryPreview(request, "no_target_boundary", incoming.definition.prefabId);
  }

  const anchorCandidates = new Map<string, AnchorCandidate>();
  const anchorBaseline = macroToMicroCoord({
    x: request.hitMacro.x + request.faceNormal.x,
    y: request.hitMacro.y + request.faceNormal.y,
    z: request.hitMacro.z + request.faceNormal.z,
  });

  for (const target of targetBoundary) {
    for (const incomingPoint of incomingBoundary) {
      if (
        request.hitMicro &&
        tangentDistance(target.localMicro, incomingPoint.localMicro, request.faceNormal) >
          searchRadius
      ) {
        continue;
      }

      const anchorMicroCoord = subtractMicroCoord(
        addMicroCoord(target.worldMicro, request.faceNormal),
        incomingPoint.localMicro,
      );
      const candidate: AnchorCandidate = {
        anchorMicroCoord,
        hitDistance: target.hitDistance,
        anchorDistance: manhattanDistance(anchorMicroCoord, anchorBaseline),
      };
      const key = coordKey(anchorMicroCoord);
      const existing = anchorCandidates.get(key);
      if (!existing || compareAnchorCandidates(candidate, existing) < 0) {
        anchorCandidates.set(key, candidate);
      }
    }
  }

  const candidates: BoundaryCandidate[] = [];
  for (const anchor of anchorCandidates.values()) {
    const rasterized = rasterizePrefabDetailed(incoming, rotation, anchor.anchorMicroCoord);
    const { cells, incomingOccupiedSlots } = rasterized;
    if (incomingOccupiedSlots === 0) {
      continue;
    }

    const overlapSlots = countOverlapSlots(cells, world);
    const contactSlots = countBoundaryContactSlots(
      rasterized.occupiedWorldMicro,
      world,
      request.faceNormal,
    );
    candidates.push({
      preview: {
        ok: overlapSlots === 0 && contactSlots > 0,
        prefabId: incoming.definition.prefabId,
        hitMacro: { ...request.hitMacro },
        faceNormal: { ...request.faceNormal },
        anchorMicroCoord: anchor.anchorMicroCoord,
        affectedMacroCount: cells.length,
        incomingOccupiedSlots,
        overlapSlots,
        contactSlots,
        cells,
        ...(overlapSlots > 0 ? { rejectReason: "micro_overlap" } : {}),
      },
      hitDistance: anchor.hitDistance,
      anchorDistance: anchor.anchorDistance,
    });
  }

  const sorted = [...candidates.values()].sort(compareBoundaryCandidates);
  const valid = sorted.find(
    (candidate) =>
      candidate.preview.ok &&
      candidate.preview.overlapSlots === 0 &&
      candidate.preview.contactSlots > 0,
  );
  if (valid) {
    return valid.preview;
  }

  const overlapping = sorted.find(
    (candidate) => candidate.preview.overlapSlots > 0 && candidate.preview.contactSlots > 0,
  );
  if (overlapping) {
    return {
      ...overlapping.preview,
      ok: false,
      rejectReason: "micro_overlap",
    };
  }

  return rejectedBoundaryPreview(request, "no_contact", incoming.definition.prefabId);
}

function rejectedBoundaryPreview(
  request: PrefabBoundarySnapRequest,
  rejectReason: string,
  prefabId: string = request.prefabName,
): PrefabBoundarySnapPreview {
  return {
    ok: false,
    prefabId,
    hitMacro: { ...request.hitMacro },
    faceNormal: { ...request.faceNormal },
    anchorMicroCoord: null,
    affectedMacroCount: 0,
    incomingOccupiedSlots: 0,
    overlapSlots: 0,
    contactSlots: 0,
    cells: [],
    rejectReason,
  };
}

function listPrefabBoundaryPoints(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
  faceNormal: FMacroCoord,
): LocalMicroPoint[] {
  const cacheKey = `${rotation}:${coordKey(faceNormal)}`;
  const cachedByFace = getOrCreateWeakCachedMap(boundaryPointCache, prefab);
  const cached = cachedByFace.get(cacheKey);
  if (cached) {
    return cached;
  }

  const occupied = listPrefabOccupiedLocalPoints(prefab, rotation);
  const occupiedKeys = new Set(occupied.map((point) => coordKey(point.localMicro)));
  const points = occupied
    .filter((point) => {
      const neighbor = subtractMicroCoord(point.localMicro, faceNormal);
      return !occupiedKeys.has(coordKey(neighbor));
    })
    .sort((a, b) => coordKey(a.localMicro).localeCompare(coordKey(b.localMicro)));
  cachedByFace.set(cacheKey, points);
  return points;
}

function listPrefabOccupiedLocalPoints(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
): LocalOccupiedMicroPoint[] {
  const cachedByRotation = getOrCreateWeakCachedMap(occupiedMicroPointCache, prefab);
  const cached = cachedByRotation.get(rotation);
  if (cached) {
    return cached;
  }

  const points: LocalOccupiedMicroPoint[] = [];
  for (const entry of transformPrefabCells(prefab.cells, rotation)) {
    for (const [sourceIndex, micro] of MICRO_SLOT_COORDS.entries()) {
      if ((entry.occupancyWord & (MICRO_SLOT_BITS[sourceIndex] ?? 0n)) === 0n) {
        continue;
      }
      points.push({
        localMicro: {
          x: entry.offset.x * VoxelConstants.MicroPerMacro + micro.x,
          y: entry.offset.y * VoxelConstants.MicroPerMacro + micro.y,
          z: entry.offset.z * VoxelConstants.MicroPerMacro + micro.z,
        },
        sourceIndex,
        materialId: entry.materialId,
        stateFlags: entry.stateFlags,
        partId: entry.microPartIds[sourceIndex] ?? -1,
      });
    }
  }
  cachedByRotation.set(rotation, points);
  return points;
}

function listWorldBoundaryPoints(
  world: WorldStore,
  request: PrefabBoundarySnapRequest,
  searchRadius: number,
): WorldBoundaryPoint[] {
  const mask = world.getMicroOccupancyMaskWorld(request.hitMacro);
  if (mask === 0n) {
    return [];
  }

  const points: WorldBoundaryPoint[] = [];
  const macroOrigin = macroToMicroCoord(request.hitMacro);
  for (const [index, localMicro] of MICRO_SLOT_COORDS.entries()) {
    if ((mask & (MICRO_SLOT_BITS[index] ?? 0n)) === 0n) {
      continue;
    }
    if (request.hitMicro && chebyshevDistance(localMicro, request.hitMicro) > searchRadius) {
      continue;
    }

    const worldMicro = addMicroCoord(macroOrigin, localMicro);
    if (isWorldMicroOccupied(world, addMicroCoord(worldMicro, request.faceNormal))) {
      continue;
    }

    points.push({
      worldMicro,
      localMicro,
      hitDistance: request.hitMicro ? chebyshevDistance(localMicro, request.hitMicro) : 0,
    });
  }

  return points.sort(
    (a, b) =>
      a.hitDistance - b.hitDistance || coordKey(a.localMicro).localeCompare(coordKey(b.localMicro)),
  );
}

function countBoundaryContactSlots(
  occupiedWorldMicro: readonly FMicroCoord[],
  world: WorldStore,
  faceNormal: FMacroCoord,
): number {
  let count = 0;
  for (const worldMicro of occupiedWorldMicro) {
    if (isWorldMicroOccupied(world, subtractMicroCoord(worldMicro, faceNormal))) {
      count += 1;
    }
  }
  return count;
}

function isWorldMicroOccupied(world: WorldStore, worldMicro: FMicroCoord): boolean {
  const macro = macroCoordFromMicro(worldMicro);
  const micro = localMicroCoordFromWorldMicro(worldMicro);
  return isMaskMicroOccupied(world.getMicroOccupancyMaskWorld(macro), micro);
}

function isMaskMicroOccupied(mask: bigint, micro: FMicroCoord): boolean {
  return (mask & (1n << BigInt(microLinearIndex(micro)))) !== 0n;
}

function isUnitAxisNormal(normal: FMacroCoord): boolean {
  const magnitude = Math.abs(normal.x) + Math.abs(normal.y) + Math.abs(normal.z);
  return (
    magnitude === 1 &&
    Number.isInteger(normal.x) &&
    Number.isInteger(normal.y) &&
    Number.isInteger(normal.z)
  );
}

function compareBoundaryCandidates(a: BoundaryCandidate, b: BoundaryCandidate): number {
  return (
    b.preview.contactSlots - a.preview.contactSlots ||
    a.preview.overlapSlots - b.preview.overlapSlots ||
    a.hitDistance - b.hitDistance ||
    a.anchorDistance - b.anchorDistance ||
    coordKey(a.preview.anchorMicroCoord ?? { x: 0, y: 0, z: 0 }).localeCompare(
      coordKey(b.preview.anchorMicroCoord ?? { x: 0, y: 0, z: 0 }),
    )
  );
}

function compareAnchorCandidates(a: AnchorCandidate, b: AnchorCandidate): number {
  return (
    a.hitDistance - b.hitDistance ||
    a.anchorDistance - b.anchorDistance ||
    coordKey(a.anchorMicroCoord).localeCompare(coordKey(b.anchorMicroCoord))
  );
}

function tangentDistance(a: FMicroCoord, b: FMicroCoord, faceNormal: FMacroCoord): number {
  const dx = faceNormal.x === 0 ? Math.abs(a.x - b.x) : 0;
  const dy = faceNormal.y === 0 ? Math.abs(a.y - b.y) : 0;
  const dz = faceNormal.z === 0 ? Math.abs(a.z - b.z) : 0;
  return Math.max(dx, dy, dz);
}

function chebyshevDistance(a: FMicroCoord, b: FMicroCoord): number {
  return Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y), Math.abs(a.z - b.z));
}

function manhattanDistance(a: FMicroCoord, b: FMicroCoord): number {
  return Math.abs(a.x - b.x) + Math.abs(a.y - b.y) + Math.abs(a.z - b.z);
}

function previewSocketSnap(
  prefabs: Map<string, LocalPrefab>,
  request: PrefabSocketSnapRequest,
  world: WorldStore,
): PrefabSocketSnapPreview {
  const incoming = prefabs.get(request.prefabName);
  if (!incoming) {
    return rejectedPreview(request, "unknown_prefab");
  }

  const targetInstance = world.findPrefabInstance(request.targetInstanceId);
  if (!targetInstance) {
    return rejectedPreview(request, "unknown_target_instance", incoming.definition.prefabId);
  }

  const targetPrefab = prefabs.get(targetInstance.prefabId);
  if (!targetPrefab) {
    return rejectedPreview(request, "unknown_target_prefab", incoming.definition.prefabId);
  }

  const targetSocket = targetPrefab.definition.sockets.find(
    (socket) => socket.socketId === request.targetSocketId,
  );
  if (!targetSocket) {
    return rejectedPreview(request, "unknown_target_socket", incoming.definition.prefabId);
  }

  const target = transformSocket(
    targetSocket,
    targetPrefab.definition.boundsInMacroCells,
    targetInstance.rotation,
  );
  const rotation = request.rotation ?? EVoxelRotation.Rot0;
  const candidates = incoming.definition.sockets
    .filter((socket) => !request.incomingSocketId || socket.socketId === request.incomingSocketId)
    .map((socket) => transformSocket(socket, incoming.definition.boundsInMacroCells, rotation))
    .filter((socket) => socketsCompatible(target, socket))
    .filter((socket) => normalsOppose(target.normal, socket.normal))
    .map((socket) =>
      buildPreviewCandidate(incoming, targetInstance, target, socket, rotation, world),
    )
    .filter((preview) => preview.contactSlots > 0)
    .sort(
      (a, b) =>
        b.contactSlots - a.contactSlots ||
        (b.socketId ? getSocketPriority(incoming, b.socketId) : 0) -
          (a.socketId ? getSocketPriority(incoming, a.socketId) : 0) ||
        (a.socketId ?? "").localeCompare(b.socketId ?? ""),
    );

  const selected = candidates[0];
  if (!selected) {
    return rejectedPreview(request, "no_compatible_socket", incoming.definition.prefabId);
  }

  if (selected.overlapSlots > 0) {
    return { ...selected, ok: false, rejectReason: "micro_overlap" };
  }

  return selected;
}

function buildPreviewCandidate(
  incoming: LocalPrefab,
  targetInstance: FPrefabInstanceData,
  targetSocket: FPrefabSocketDefinition,
  incomingSocket: FPrefabSocketDefinition,
  rotation: EVoxelRotation,
  world: WorldStore,
): PrefabSocketSnapPreview {
  const targetWorldMicro = addMicroCoord(
    targetInstance.anchorMicroCoord,
    targetSocket.localMicroCoord,
  );
  const anchorMicroCoord = subtractMicroCoord(targetWorldMicro, incomingSocket.localMicroCoord);
  const rasterized = rasterizePrefabDetailed(incoming, rotation, anchorMicroCoord);
  const cells = rasterized.cells;
  const overlapSlots = countOverlapSlots(cells, world);
  return {
    ok: overlapSlots === 0,
    prefabId: incoming.definition.prefabId,
    targetInstanceId: targetInstance.instanceId,
    targetSocketId: targetSocket.socketId,
    socketId: incomingSocket.socketId,
    anchorMicroCoord,
    affectedMacroCount: cells.length,
    incomingOccupiedSlots: rasterized.incomingOccupiedSlots,
    overlapSlots,
    contactSlots: countSocketContactSlots(targetSocket, incomingSocket),
    cells,
    ...(overlapSlots > 0 ? { rejectReason: "micro_overlap" } : {}),
  };
}

function rejectedPreview(
  request: PrefabSocketSnapRequest,
  rejectReason: string,
  prefabId: string = request.prefabName,
): PrefabSocketSnapPreview {
  return {
    ok: false,
    prefabId,
    targetInstanceId: request.targetInstanceId,
    targetSocketId: request.targetSocketId,
    socketId: request.incomingSocketId ?? null,
    anchorMicroCoord: null,
    affectedMacroCount: 0,
    incomingOccupiedSlots: 0,
    overlapSlots: 0,
    contactSlots: 0,
    cells: [],
    rejectReason,
  };
}

function transformSocket(
  socket: FPrefabSocketDefinition,
  bounds: FMacroCoord,
  rotation: EVoxelRotation,
): FPrefabSocketDefinition {
  return {
    ...socket,
    localMicroCoord: rotateLocalMicroCoord(socket.localMicroCoord, bounds, rotation),
    normal: rotateNormal(socket.normal, rotation),
  };
}

function rotateLocalMicroCoord(
  coord: FMicroCoord,
  bounds: FMacroCoord,
  rotation: EVoxelRotation,
): FMicroCoord {
  const maxX = bounds.x * VoxelConstants.MicroPerMacro;
  const maxZ = bounds.z * VoxelConstants.MicroPerMacro;
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: maxZ - coord.z, y: coord.y, z: coord.x };
    case EVoxelRotation.Rot180:
      return { x: maxX - coord.x, y: coord.y, z: maxZ - coord.z };
    case EVoxelRotation.Rot270:
      return { x: coord.z, y: coord.y, z: maxX - coord.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...coord };
  }
}

function rotateNormal(normal: FMacroCoord, rotation: EVoxelRotation): FMacroCoord {
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: -normal.z, y: normal.y, z: normal.x };
    case EVoxelRotation.Rot180:
      return { x: -normal.x, y: normal.y, z: -normal.z };
    case EVoxelRotation.Rot270:
      return { x: normal.z, y: normal.y, z: -normal.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...normal };
  }
}

function socketsCompatible(
  target: FPrefabSocketDefinition,
  incoming: FPrefabSocketDefinition,
): boolean {
  return (
    target.allowedPeerClasses.includes(incoming.snapClass) &&
    incoming.allowedPeerClasses.includes(target.snapClass)
  );
}

function normalsOppose(a: FMacroCoord, b: FMacroCoord): boolean {
  return a.x + b.x === 0 && a.y + b.y === 0 && a.z + b.z === 0;
}

function countSocketContactSlots(
  target: FPrefabSocketDefinition,
  incoming: FPrefabSocketDefinition,
): number {
  return countBits((target.faceMask ?? 0n) & (incoming.faceMask ?? 0n));
}

function getSocketPriority(prefab: LocalPrefab, socketId: string): number {
  return prefab.definition.sockets.find((socket) => socket.socketId === socketId)?.priority ?? 0;
}

export function countBits(mask: bigint): number {
  let count = 0;
  let value = mask;
  while (value !== 0n) {
    value &= value - 1n;
    count += 1;
  }
  return count;
}

function macroCoordFromMicro(coord: FMicroCoord): FMacroCoord {
  return {
    x: floorDiv(coord.x, VoxelConstants.MicroPerMacro),
    y: floorDiv(coord.y, VoxelConstants.MicroPerMacro),
    z: floorDiv(coord.z, VoxelConstants.MicroPerMacro),
  };
}

function chunkCoordFromMicro(coord: FMicroCoord): FMacroCoord {
  return chunkCoordFromMacro(macroCoordFromMicro(coord));
}

function localMicroCoordFromWorldMicro(coord: FMicroCoord): FMicroCoord {
  return {
    x: positiveModulo(coord.x, VoxelConstants.MicroPerMacro),
    y: positiveModulo(coord.y, VoxelConstants.MicroPerMacro),
    z: positiveModulo(coord.z, VoxelConstants.MicroPerMacro),
  };
}

function floorDiv(value: number, divisor: number): number {
  return Math.floor(value / divisor);
}

function positiveModulo(value: number, divisor: number): number {
  return ((value % divisor) + divisor) % divisor;
}

function coordKey(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function addMicroCoord(a: FMicroCoord, b: FMicroCoord): FMicroCoord {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

function subtractMicroCoord(a: FMicroCoord, b: FMicroCoord): FMicroCoord {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

function sameCoord(a: FMacroCoord, b: FMacroCoord): boolean {
  return a.x === b.x && a.y === b.y && a.z === b.z;
}

function macroWithinBounds(macro: FMacroCoord, min: FMacroCoord, max: FMacroCoord): boolean {
  return (
    macro.x >= min.x &&
    macro.y >= min.y &&
    macro.z >= min.z &&
    macro.x <= max.x &&
    macro.y <= max.y &&
    macro.z <= max.z
  );
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

  const out = new Array(MicroGridSlotCount).fill(-1);
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
  const out = new Array(MicroGridSlotCount).fill(-1);
  for (let index = 0; index < Math.min(partIds.length, MicroGridSlotCount); index += 1) {
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
  return (
    coord.x +
    coord.y * VoxelConstants.MicroPerMacro +
    coord.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro
  );
}

function buildBuiltinPrefabs(): LocalPrefab[] {
  return [
    buildBuiltinPrefab("builtin_cylinder", makeCylinderOccupancy(), VoxelMaterialId.Stone, [
      "builtin",
      "cylinder",
      "curved",
    ]),
    buildBuiltinPrefab("builtin_sphere", makeSphereOccupancy(), VoxelMaterialId.Ice, [
      "builtin",
      "sphere",
      "curved",
    ]),
    buildBuiltinPrefab("builtin_stairs", makeStairsOccupancy(), VoxelMaterialId.Wood, [
      "builtin",
      "stairs",
    ]),
  ];
}

function buildBuiltinPrefab(
  name: string,
  occupancyWord: bigint,
  materialId: number,
  tags: string[],
): LocalPrefab {
  const partDefinitions: FPrefabPartDefinition[] = [
    {
      partId: "body",
      partTags: tags,
      defaultAffordances: builtinAffordances(tags),
      defaultHealth: 100,
      materialPolicy: "fixed",
    },
  ];
  const microPartIds = partIdsFromOccupancy(occupancyWord, 0);
  const boundsInMacroCells = { x: 1, y: 1, z: 1 };
  const boundaryFaceMasks = buildBoundaryFaceMasks([occupancyWord], boundsInMacroCells);
  const definition: FPrefabDefinitionData = {
    prefabId: name,
    boundsInMacroCells,
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
    boundarySignature: buildBoundarySignature([occupancyWord], boundsInMacroCells),
    boundaryFaceMasks,
    sockets: buildBuiltinSockets(name, boundsInMacroCells, boundaryFaceMasks),
    tags,
  };

  return {
    name,
    boundsMin: { x: 0, y: 0, z: 0 },
    boundsMax: { x: 0, y: 0, z: 0 },
    definition,
    blocks: [],
    cells: [
      { offset: { x: 0, y: 0, z: 0 }, occupancyWord, materialId, stateFlags: 0, microPartIds },
    ],
  };
}

function partIdsFromOccupancy(occupancyWord: bigint, partIndex: number): number[] {
  const ids = new Array(MicroGridSlotCount).fill(-1);
  for (let index = 0; index < MicroGridSlotCount; index += 1) {
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

function buildBuiltinSockets(
  name: string,
  bounds: FMacroCoord,
  masks: FPrefabBoundaryFaceMasks,
): FPrefabSocketDefinition[] {
  if (name !== "builtin_stairs") {
    return [];
  }

  const mid = Math.floor(VoxelConstants.MicroPerMacro / 2);
  return [
    {
      socketId: "stairs_high_pos_x",
      localMicroCoord: {
        x: bounds.x * VoxelConstants.MicroPerMacro,
        y: VoxelConstants.MicroPerMacro - 1,
        z: mid,
      },
      normal: { x: 1, y: 0, z: 0 },
      tags: ["stairs", "rise", "high"],
      snapClass: "stairs-rise",
      allowedPeerClasses: ["stairs-rise"],
      faceMask: masks.posX,
      priority: 100,
    },
    {
      socketId: "stairs_low_neg_x",
      localMicroCoord: { x: 0, y: 0, z: mid },
      normal: { x: -1, y: 0, z: 0 },
      tags: ["stairs", "rise", "low"],
      snapClass: "stairs-rise",
      allowedPeerClasses: ["stairs-rise"],
      faceMask: masks.negX,
      priority: 100,
    },
  ];
}

function buildCapturedSockets(
  name: string,
  bounds: FMacroCoord,
  masks: FPrefabBoundaryFaceMasks,
): FPrefabSocketDefinition[] {
  const center = {
    x: Math.floor((bounds.x * VoxelConstants.MicroPerMacro) / 2),
    y: Math.floor((bounds.y * VoxelConstants.MicroPerMacro) / 2),
    z: Math.floor((bounds.z * VoxelConstants.MicroPerMacro) / 2),
  };
  return [
    makeCapturedSocket(
      name,
      "neg_x",
      { x: 0, y: center.y, z: center.z },
      { x: -1, y: 0, z: 0 },
      masks.negX,
    ),
    makeCapturedSocket(
      name,
      "pos_x",
      { x: bounds.x * VoxelConstants.MicroPerMacro, y: center.y, z: center.z },
      { x: 1, y: 0, z: 0 },
      masks.posX,
    ),
    makeCapturedSocket(
      name,
      "neg_y",
      { x: center.x, y: 0, z: center.z },
      { x: 0, y: -1, z: 0 },
      masks.negY,
    ),
    makeCapturedSocket(
      name,
      "pos_y",
      { x: center.x, y: bounds.y * VoxelConstants.MicroPerMacro, z: center.z },
      { x: 0, y: 1, z: 0 },
      masks.posY,
    ),
    makeCapturedSocket(
      name,
      "neg_z",
      { x: center.x, y: center.y, z: 0 },
      { x: 0, y: 0, z: -1 },
      masks.negZ,
    ),
    makeCapturedSocket(
      name,
      "pos_z",
      { x: center.x, y: center.y, z: bounds.z * VoxelConstants.MicroPerMacro },
      { x: 0, y: 0, z: 1 },
      masks.posZ,
    ),
  ].filter((socket) => socket.faceMask !== 0n);
}

function makeCapturedSocket(
  prefabName: string,
  suffix: string,
  localMicroCoord: FMicroCoord,
  normal: FMacroCoord,
  faceMask: bigint,
): FPrefabSocketDefinition {
  return {
    socketId: `${prefabName}_${suffix}`,
    localMicroCoord,
    normal,
    tags: ["captured", "macro_face"],
    snapClass: "macro-face",
    allowedPeerClasses: ["macro-face"],
    faceMask,
    priority: 10,
  };
}

function makeSphereOccupancy(): bigint {
  let mask = 0n;
  const center = VoxelConstants.MicroPerMacro / 2;
  const radius = center - 0.1;
  const radiusSq = radius * radius;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const dx = x + 0.5 - center;
        const dy = y + 0.5 - center;
        const dz = z + 0.5 - center;
        if (dx * dx + dy * dy + dz * dz <= radiusSq) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

function makeCylinderOccupancy(): bigint {
  let mask = 0n;
  const center = VoxelConstants.MicroPerMacro / 2;
  const radius = center - 0.1;
  const radiusSq = radius * radius;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const dx = x + 0.5 - center;
        const dz = z + 0.5 - center;
        if (dx * dx + dz * dz <= radiusSq) {
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
