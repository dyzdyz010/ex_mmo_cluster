import type { FMacroCoord, FMicroCoord } from "./core/types";
import type { EVoxelRotation } from "./core/types";
import type { FNormalBlockData } from "./storage/types";
import {
  LocalPrefabRegistry,
  type LocalPrefab,
  type PrefabBoundarySnapPreview,
  type PrefabBoundarySnapRequest,
  type PrefabBoundarySnapResult,
  type PrefabSocketSnapPreview,
  type PrefabSocketSnapRequest,
  type PrefabSocketSnapResult,
  type PrefabSocketSnapTarget,
} from "./prefab";
import { WorldStore, type SerializedWorldSnapshot } from "./worldStore";

export interface VoxelWorldAdapter {
  readonly mode: string;
  readonly store: WorldStore;
  bootstrap(): void;
  debugSnapshot(): Record<string, unknown>;
  requestDevHeatVoxel?(
    coord: FMacroCoord,
    targetTemperatureCelsius: number,
    maxTicks?: number,
  ): boolean;
  requestSetVoxelTemperature?(
    coord: FMacroCoord,
    targetTemperatureCelsius: number,
    maxTicks?: number,
  ): boolean;
  requestVoxelConductionPath?(
    source: FMacroCoord,
    target: FMacroCoord,
    sourcePotential: number,
    maxTicks?: number,
  ): boolean;
  placeBlock(coord: FMacroCoord, block: FNormalBlockData): boolean;
  breakBlock(coord: FMacroCoord): boolean;
  placeMicroBlock(macro: FMacroCoord, micro: FMicroCoord, block: FNormalBlockData): boolean;
  breakMicroBlock(macro: FMacroCoord, micro: FMicroCoord): boolean;
  capturePrefab(name: string, min: FMacroCoord, max: FMacroCoord): LocalPrefab;
  placePrefab(
    name: string,
    origin: FMacroCoord,
    rotation?: EVoxelRotation,
  ): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean };
  previewPrefabSocketSnap(request: PrefabSocketSnapRequest): PrefabSocketSnapPreview;
  placePrefabSocketSnap(request: PrefabSocketSnapRequest): PrefabSocketSnapResult;
  previewPrefabBoundarySnap(request: PrefabBoundarySnapRequest): PrefabBoundarySnapPreview;
  placePrefabBoundarySnap(request: PrefabBoundarySnapRequest): PrefabBoundarySnapResult;
  findPrefabSocketSnapTarget(
    macro: FMacroCoord,
    faceNormal: FMacroCoord,
  ): PrefabSocketSnapTarget | null;
  getPrefab(name: string): LocalPrefab | null;
  listPrefabs(): LocalPrefab[];
  exportSnapshot(): SerializedWorldSnapshot;
  importSnapshot(snapshot: SerializedWorldSnapshot): void;
}

export class LocalVoxelWorldAdapter implements VoxelWorldAdapter {
  readonly mode: string = "offline-local";
  readonly store = new WorldStore();
  private readonly prefabs = new LocalPrefabRegistry();

  bootstrap(): void {
    this.store.seedRegionalShowcase(2);
  }

  debugSnapshot(): Record<string, unknown> {
    return {
      mode: this.mode,
      chunks: this.store.listChunks().length,
      solidBlocks: this.store.totalSolidBlocks(),
      editStats: { ...this.store.editStats },
      authoritativeChunks: this.store.authoritativeChunkSummaries(16),
    };
  }

  placeBlock(coord: FMacroCoord, block: FNormalBlockData): boolean {
    return this.store.setNormalBlockWorld(coord, block);
  }

  breakBlock(coord: FMacroCoord): boolean {
    return this.store.clearCellWorld(coord);
  }

  placeMicroBlock(macro: FMacroCoord, micro: FMicroCoord, block: FNormalBlockData): boolean {
    return this.store.setMicroBlockWorld(macro, micro, block);
  }

  breakMicroBlock(macro: FMacroCoord, micro: FMicroCoord): boolean {
    return this.store.clearMicroBlockWorld(macro, micro);
  }

  capturePrefab(name: string, min: FMacroCoord, max: FMacroCoord): LocalPrefab {
    return this.prefabs.capture(name, min, max, this.store);
  }

  placePrefab(
    name: string,
    origin: FMacroCoord,
    rotation?: EVoxelRotation,
  ): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean } {
    return this.prefabs.place(name, origin, this.store, rotation);
  }

  previewPrefabSocketSnap(request: PrefabSocketSnapRequest): PrefabSocketSnapPreview {
    return this.prefabs.previewSocketSnap(request, this.store);
  }

  placePrefabSocketSnap(request: PrefabSocketSnapRequest): PrefabSocketSnapResult {
    return this.prefabs.placeSocketSnap(request, this.store);
  }

  previewPrefabBoundarySnap(request: PrefabBoundarySnapRequest): PrefabBoundarySnapPreview {
    return this.prefabs.previewBoundarySnap(request, this.store);
  }

  placePrefabBoundarySnap(request: PrefabBoundarySnapRequest): PrefabBoundarySnapResult {
    return this.prefabs.placeBoundarySnap(request, this.store);
  }

  findPrefabSocketSnapTarget(
    macro: FMacroCoord,
    faceNormal: FMacroCoord,
  ): PrefabSocketSnapTarget | null {
    return this.prefabs.findSocketSnapTarget(this.store, macro, faceNormal);
  }

  getPrefab(name: string): LocalPrefab | null {
    return this.prefabs.get(name);
  }

  listPrefabs(): LocalPrefab[] {
    return this.prefabs.list();
  }

  exportSnapshot(): SerializedWorldSnapshot {
    return this.store.exportSnapshot();
  }

  importSnapshot(snapshot: SerializedWorldSnapshot): void {
    this.store.importSnapshot(snapshot);
  }
}
