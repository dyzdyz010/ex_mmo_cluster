import { VoxelMaterialId } from "../material/catalog";
import { EVoxelBlockStateFlags, type FMacroCoord } from "./core/types";
import type { FMacroEnvironmentSummary, FNormalBlockData } from "./storage/types";

type ShowcaseRegion = "wetland" | "stone_ridge" | "wood_terrace" | "ice_shelf";

interface ShowcaseEditStats {
  placed: number;
  broken: number;
  rejected: number;
  conflicts: number;
}

interface ShowcaseWorldWriter {
  readonly editStats: ShowcaseEditStats;
  setNormalBlockWorld(worldMacro: FMacroCoord, block: FNormalBlockData): boolean;
  setEnvironmentSummaryWorld(worldMacro: FMacroCoord, summary: FMacroEnvironmentSummary): boolean;
}

export function seedRegionalShowcaseWorld(world: ShowcaseWorldWriter, radius: number = 2): void {
  for (let x = -radius * 16; x < radius * 16; x += 1) {
    for (let z = -radius * 16; z < radius * 16; z += 1) {
      const region = getShowcaseRegion(x, z);
      const height = getBaseHeight(x, z, region);
      const materialId = getBaseMaterialId(x, z, region);

      for (let y = 0; y <= height; y += 1) {
        const top = y === height;
        const block: FNormalBlockData = {
          materialId,
          stateFlags: getStateFlags(region, x, z, y, top),
          health: getHealthForMaterial(materialId),
          temperatureDelta: getTemperatureDelta(region, top),
          moistureDelta: getMoistureDelta(region, top),
        };
        world.setNormalBlockWorld({ x, y, z }, block);
        if (top) {
          world.setEnvironmentSummaryWorld(
            { x, y, z },
            {
              defaultTemperature: getTemperatureDelta(region, top),
              defaultMoisture: getMoistureDelta(region, top),
              currentTemperature: getTemperatureDelta(region, top),
              currentMoisture: getMoistureDelta(region, top),
              fieldMask: block.stateFlags !== 0 ? 1 : 0,
            },
          );
        }
      }
    }
  }

  world.editStats.placed = 0;
  world.editStats.broken = 0;
  world.editStats.rejected = 0;
  world.editStats.conflicts = 0;
}

function getShowcaseRegion(x: number, z: number): ShowcaseRegion {
  if (x < 0 && z < 0) {
    return "wetland";
  }
  if (x >= 0 && z < 0) {
    return "stone_ridge";
  }
  if (x < 0) {
    return "wood_terrace";
  }
  return "ice_shelf";
}

function getBaseHeight(x: number, z: number, region: ShowcaseRegion): number {
  switch (region) {
    case "wetland":
      return 1 + (Math.abs(x + z) % 4 === 0 ? 1 : 0);
    case "stone_ridge":
      return 2 + (Math.abs(z) % 5 === 0 ? 2 : 0);
    case "wood_terrace":
      return 1 + (Math.abs(x) % 6 === 0 ? 2 : 0);
    case "ice_shelf":
      return 2 + (Math.abs(x - z) % 6 === 0 ? 1 : 0);
  }
}

function getBaseMaterialId(x: number, z: number, region: ShowcaseRegion): number {
  switch (region) {
    case "wetland":
      return Math.abs(x - z) % 9 === 0 ? VoxelMaterialId.Stone : VoxelMaterialId.Dirt;
    case "stone_ridge":
      return VoxelMaterialId.Stone;
    case "wood_terrace":
      return z % 4 === 0 ? VoxelMaterialId.Stone : VoxelMaterialId.Wood;
    case "ice_shelf":
      return VoxelMaterialId.Ice;
  }
}

function getStateFlags(
  region: ShowcaseRegion,
  x: number,
  z: number,
  y: number,
  top: boolean,
): number {
  let flags = 0;
  if (!top) {
    return flags;
  }

  if (region === "wetland" && Math.abs(x + z) % 3 === 0) {
    flags |= EVoxelBlockStateFlags.Wet;
  }
  if (region === "wetland" && Math.abs(x - z) % 7 === 0) {
    flags |= EVoxelBlockStateFlags.Frozen;
  }
  if (region === "wood_terrace" && y >= 2 && Math.abs(x + z) % 5 === 0) {
    flags |= EVoxelBlockStateFlags.Burning;
  }
  if (region === "ice_shelf" && Math.abs(x * 2 + z) % 5 === 0) {
    flags |= EVoxelBlockStateFlags.MeltPending;
  }
  if (region === "stone_ridge" && Math.abs(x + z) % 11 === 0) {
    flags |= EVoxelBlockStateFlags.Damaged;
  }
  return flags;
}

function getTemperatureDelta(region: ShowcaseRegion, top: boolean): number {
  if (!top) {
    return 0;
  }
  switch (region) {
    case "wetland":
      return -18;
    case "stone_ridge":
      return 0;
    case "wood_terrace":
      return 46;
    case "ice_shelf":
      return -42;
  }
}

function getMoistureDelta(region: ShowcaseRegion, top: boolean): number {
  if (!top) {
    return 0;
  }
  switch (region) {
    case "wetland":
      return 38;
    case "stone_ridge":
      return 0;
    case "wood_terrace":
      return -10;
    case "ice_shelf":
      return 12;
  }
}

function getHealthForMaterial(materialId: number): number {
  switch (materialId) {
    case VoxelMaterialId.Stone:
      return 180;
    case VoxelMaterialId.Wood:
      return 95;
    case VoxelMaterialId.Ice:
      return 70;
    case VoxelMaterialId.Dirt:
    default:
      return 110;
  }
}
