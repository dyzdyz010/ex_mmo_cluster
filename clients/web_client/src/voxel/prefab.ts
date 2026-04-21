import type { FMacroCoord } from "./core/types";
import type { FNormalBlockData } from "./storage/types";
import { WorldStore } from "./worldStore";

export interface PrefabBlock {
  offset: FMacroCoord;
  block: FNormalBlockData;
}

export interface LocalPrefab {
  name: string;
  boundsMin: FMacroCoord;
  boundsMax: FMacroCoord;
  blocks: PrefabBlock[];
}

export class LocalPrefabRegistry {
  private readonly prefabs = new Map<string, LocalPrefab>();

  capture(name: string, min: FMacroCoord, max: FMacroCoord, world: WorldStore): LocalPrefab {
    const boundsMin = normalizeBoundsMin(min, max);
    const boundsMax = normalizeBoundsMax(min, max);
    const blocks: PrefabBlock[] = [];

    for (let x = boundsMin.x; x <= boundsMax.x; x += 1) {
      for (let y = boundsMin.y; y <= boundsMax.y; y += 1) {
        for (let z = boundsMin.z; z <= boundsMax.z; z += 1) {
          const coord = { x, y, z };
          const block = world.getNormalBlockWorld(coord);
          if (!block) {
            continue;
          }

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

    const prefab: LocalPrefab = { name, boundsMin, boundsMax, blocks };
    this.prefabs.set(name, prefab);
    return prefab;
  }

  place(name: string, origin: FMacroCoord, world: WorldStore): { ok: boolean; placed: number } {
    const prefab = this.prefabs.get(name);
    if (!prefab) {
      return { ok: false, placed: 0 };
    }

    let placed = 0;
    for (const entry of prefab.blocks) {
      const coord = {
        x: origin.x + entry.offset.x,
        y: origin.y + entry.offset.y,
        z: origin.z + entry.offset.z,
      };

      if (world.setNormalBlockWorld(coord, entry.block)) {
        placed += 1;
      }
    }

    return { ok: true, placed };
  }

  list(): LocalPrefab[] {
    return [...this.prefabs.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  get(name: string): LocalPrefab | null {
    return this.prefabs.get(name) ?? null;
  }
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
