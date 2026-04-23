import type { FMacroCoord } from "./core/types";
import type { EVoxelRotation } from "./core/types";
import type { FNormalBlockData } from "./storage/types";
import { LocalPrefabRegistry, type LocalPrefab } from "./prefab";
import { WorldStore, type SerializedWorldSnapshot } from "./worldStore";

export interface VoxelWorldAdapter {
  readonly mode: string;
  readonly store: WorldStore;
  bootstrap(): void;
  placeBlock(coord: FMacroCoord, block: FNormalBlockData): boolean;
  breakBlock(coord: FMacroCoord): boolean;
  capturePrefab(name: string, min: FMacroCoord, max: FMacroCoord): LocalPrefab;
  placePrefab(name: string, origin: FMacroCoord, rotation?: EVoxelRotation): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean };
  getPrefab(name: string): LocalPrefab | null;
  listPrefabs(): LocalPrefab[];
  exportSnapshot(): SerializedWorldSnapshot;
  importSnapshot(snapshot: SerializedWorldSnapshot): void;
}

export class LocalVoxelWorldAdapter implements VoxelWorldAdapter {
  readonly mode = "offline-local";
  readonly store = new WorldStore();
  private readonly prefabs = new LocalPrefabRegistry();

  bootstrap(): void {
    this.store.seedRegionalShowcase(2);
  }

  placeBlock(coord: FMacroCoord, block: FNormalBlockData): boolean {
    return this.store.setNormalBlockWorld(coord, block);
  }

  breakBlock(coord: FMacroCoord): boolean {
    return this.store.clearCellWorld(coord);
  }

  capturePrefab(name: string, min: FMacroCoord, max: FMacroCoord): LocalPrefab {
    return this.prefabs.capture(name, min, max, this.store);
  }

  placePrefab(name: string, origin: FMacroCoord, rotation?: EVoxelRotation): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean } {
    return this.prefabs.place(name, origin, this.store, rotation);
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
