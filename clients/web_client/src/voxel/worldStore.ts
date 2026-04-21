import { VoxelMaterialId } from "../material/catalog";
import { MacroWorldSize, VoxelConstants } from "./core/constants";
import { chunkCoordKey, EVoxelBlockStateFlags, type FChunkCoord, type FMacroCoord } from "./core/types";
import { chunkCoordFromMacro, localMacroInChunk } from "./core/gridUtils";
import { ChunkStorage } from "./storage/chunkStorage";
import type { FMacroEnvironmentSummary, FNormalBlockData } from "./storage/types";

export interface WorldEditStats {
  placed: number;
  broken: number;
  rejected: number;
  conflicts: number;
}

export interface ChunkSummary {
  coord: FChunkCoord;
  key: string;
  solidBlocks: number;
  dirtyFlags: number;
}

type ShowcaseRegion = "wetland" | "stone_ridge" | "wood_terrace" | "ice_shelf";

export class WorldStore {
  private readonly chunks = new Map<string, ChunkStorage>();
  readonly editStats: WorldEditStats = {
    placed: 0,
    broken: 0,
    rejected: 0,
    conflicts: 0,
  };

  ensureChunk(coord: FChunkCoord): ChunkStorage {
    const key = chunkCoordKey(coord);
    const existing = this.chunks.get(key);
    if (existing) {
      return existing;
    }
    const chunk = ChunkStorage.createEmpty(coord);
    this.chunks.set(key, chunk);
    return chunk;
  }

  getChunk(coord: FChunkCoord): ChunkStorage | null {
    return this.chunks.get(chunkCoordKey(coord)) ?? null;
  }

  listChunks(): ChunkStorage[] {
    return [...this.chunks.values()].sort((a, b) =>
      chunkCoordKey(a.data.chunkCoord).localeCompare(chunkCoordKey(b.data.chunkCoord)),
    );
  }

  chunkSummaries(limit = 16): ChunkSummary[] {
    return this.listChunks()
      .slice(0, limit)
      .map((chunk) => ({
        coord: { ...chunk.data.chunkCoord },
        key: chunkCoordKey(chunk.data.chunkCoord),
        solidBlocks: chunk.countSolidBlocks(),
        dirtyFlags: chunk.data.dirtyFlags,
      }));
  }

  totalSolidBlocks(): number {
    return this.listChunks().reduce((sum, chunk) => sum + chunk.countSolidBlocks(), 0);
  }

  isSolidWorldMacroCoord(worldMacro: FMacroCoord): boolean {
    return this.getNormalBlockWorld(worldMacro) !== null;
  }

  getNormalBlockWorld(worldMacro: FMacroCoord): FNormalBlockData | null {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    return chunk?.getNormalBlock(localMacro) ?? null;
  }

  getEnvironmentSummaryWorld(worldMacro: FMacroCoord): FMacroEnvironmentSummary | null {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    return chunk?.getEnvironmentSummary(localMacro) ?? null;
  }

  setNormalBlockWorld(worldMacro: FMacroCoord, block: FNormalBlockData): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro, true);
    if (!chunk) {
      this.editStats.rejected += 1;
      return false;
    }
    const ok = chunk.trySetNormalBlock(localMacro, block);
    if (ok) {
      this.editStats.placed += 1;
    } else {
      this.editStats.rejected += 1;
    }
    return ok;
  }

  clearCellWorld(worldMacro: FMacroCoord): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    if (!chunk) {
      this.editStats.rejected += 1;
      return false;
    }
    const ok = chunk.clearCell(localMacro);
    if (ok) {
      this.editStats.broken += 1;
    } else {
      this.editStats.rejected += 1;
    }
    return ok;
  }

  setEnvironmentSummaryWorld(worldMacro: FMacroCoord, summary: FMacroEnvironmentSummary): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro, true);
    if (!chunk) {
      return false;
    }
    return chunk.setMacroEnvironmentSummary(localMacro, summary);
  }

  markConflict(): void {
    this.editStats.conflicts += 1;
  }

  surfaceCenterYAtWorldXZ(worldX: number, worldZ: number, halfHeight: number, fallbackY: number): number {
    if (this.chunks.size === 0) {
      return fallbackY;
    }

    const macroX = Math.floor(worldX / MacroWorldSize);
    const macroZ = Math.floor(worldZ / MacroWorldSize);
    const chunkYs = this.listChunks().map((chunk) => chunk.data.chunkCoord.y);
    const maxChunkY = Math.max(...chunkYs, 0);
    const minChunkY = Math.min(...chunkYs, 0);
    const maxMacroY = ((maxChunkY + 1) * VoxelConstants.ChunkSizeY) - 1;
    const minMacroY = minChunkY * VoxelConstants.ChunkSizeY;

    for (let macroY = maxMacroY; macroY >= minMacroY; macroY -= 1) {
      if (this.getNormalBlockWorld({ x: macroX, y: macroY, z: macroZ })) {
        const groundedCenterY = ((macroY + 1) * MacroWorldSize) + halfHeight;
        return Math.max(groundedCenterY, fallbackY);
      }
    }

    return fallbackY;
  }

  seedRegionalShowcase(radius: number = 2): void {
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
          this.setNormalBlockWorld({ x, y, z }, block);
          if (top) {
            this.setEnvironmentSummaryWorld({ x, y, z }, {
              defaultTemperature: getTemperatureDelta(region, top),
              defaultMoisture: getMoistureDelta(region, top),
              currentTemperature: getTemperatureDelta(region, top),
              currentMoisture: getMoistureDelta(region, top),
              fieldMask: block.stateFlags !== 0 ? 1 : 0,
            });
          }
        }
      }
    }

    this.editStats.placed = 0;
    this.editStats.broken = 0;
    this.editStats.rejected = 0;
    this.editStats.conflicts = 0;
  }

  private resolveChunkAndLocal(worldMacro: FMacroCoord, createIfMissing = false): { chunk: ChunkStorage | null; localMacro: FMacroCoord } {
    const chunkCoord = chunkCoordFromMacro(worldMacro);
    const localMacro = localMacroInChunk(worldMacro);
    const chunk = createIfMissing ? this.ensureChunk(chunkCoord) : this.getChunk(chunkCoord);
    return { chunk, localMacro };
  }
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

function getStateFlags(region: ShowcaseRegion, x: number, z: number, y: number, top: boolean): number {
  let flags = 0;
  if (!top) {
    return flags;
  }

  if (region === "wetland" && (Math.abs(x + z) % 3 === 0)) {
    flags |= EVoxelBlockStateFlags.Wet;
  }
  if (region === "wetland" && (Math.abs(x - z) % 7 === 0)) {
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
