import { EVoxelRotation, type FMacroCoord } from "./core/types";
import { chunkCoordFromMacro } from "./core/gridUtils";
import { VoxelConstants } from "./core/constants";
import { MicroGridSlotCount } from "./microgrid/governance";
import type {
  FPrefabDefinitionData,
  FPrefabInstanceData,
  FPrefabPartDefinition,
} from "./storage/types";
import type { WorldStore } from "./worldStore";
import {
  FULL_MACRO_OCCUPANCY_WORD,
  type LocalPrefab,
  type PrefabBlock,
  type PrefabBoundarySnapPreview,
  type PrefabBoundarySnapRequest,
  type PrefabBoundarySnapResult,
  type PrefabCell,
  type PrefabSocketSnapPreview,
  type PrefabSocketSnapRequest,
  type PrefabSocketSnapResult,
  type PrefabSocketSnapTarget,
} from "./prefab/types";
import {
  boundsFromRasterCells,
  buildBoundaryFaceMasks,
  buildBoundarySignature,
  buildBuiltinPrefabs,
  buildCapturedSockets,
  chunkCoordFromMicro,
  countOverlapSlots,
  macroToMicroCoord,
  macroWithinBounds,
  normalizeBoundsMax,
  normalizeBoundsMin,
  previewBoundarySnap,
  previewSocketSnap,
  rasterizePrefab,
  recordInstanceInCoveredChunks,
  sameCoord,
  transformSocket,
} from "./prefab/runtime";

export { FULL_MACRO_OCCUPANCY_WORD } from "./prefab/types";
export { countBits } from "./prefab/runtime";
export type {
  LocalPrefab,
  PrefabBlock,
  PrefabBoundarySnapPreview,
  PrefabBoundarySnapRequest,
  PrefabBoundarySnapResult,
  PrefabRasterCell,
  PrefabSocketSnapPreview,
  PrefabSocketSnapRequest,
  PrefabSocketSnapResult,
  PrefabSocketSnapTarget,
} from "./prefab/types";
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
