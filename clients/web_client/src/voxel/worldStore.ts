import { MacroWorldSize, VoxelConstants } from "./core/constants";
import {
  chunkCoordKey,
  EVoxelCellMode,
  type FChunkCoord,
  type FMacroCoord,
  type FMicroCoord,
} from "./core/types";
import { chunkCoordFromMacro, localMacroInChunk } from "./core/gridUtils";
import { ChunkStorage } from "./storage/chunkStorage";
import {
  FullMicroOccupancyMask,
  MicroGridSlotCount,
  normalizeRefinedCell,
} from "./microgrid/governance";
import { seedRegionalShowcaseWorld } from "./worldShowcase";
import {
  clonePrefabInstance,
  exportWorldSnapshot,
  importWorldSnapshot,
  type SerializedWorldSnapshot,
  type WorldEditStats,
} from "./worldSnapshot";
import type {
  FChunkStorageData,
  FMacroEnvironmentSummary,
  FNormalBlockData,
  FPrefabInstanceData,
  FRefinedCellData,
} from "./storage/types";

export interface ChunkSummary {
  coord: FChunkCoord;
  key: string;
  solidBlocks: number;
  dirtyFlags: number;
  logicalSceneId?: number;
  chunkVersion?: number;
  chunkHash?: number;
}

export interface AuthoritativeChunkMetadata {
  requestId: number;
  logicalSceneId: number;
  schemaVersion: number;
  chunkVersion: number;
  chunkHash: number;
  receivedAtMs: number;
}

export type { SerializedWorldSnapshot, WorldEditStats } from "./worldSnapshot";

export class WorldStore {
  private readonly chunks = new Map<string, ChunkStorage>();
  private readonly authoritativeChunkMetadata = new Map<string, AuthoritativeChunkMetadata>();
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

  replaceChunkStorage(
    data: FChunkStorageData,
    metadata?: AuthoritativeChunkMetadata,
  ): ChunkStorage {
    const chunk = ChunkStorage.fromData(data);
    const key = chunkCoordKey(data.chunkCoord);
    this.chunks.set(key, chunk);
    if (metadata) {
      this.authoritativeChunkMetadata.set(key, { ...metadata });
    } else {
      this.authoritativeChunkMetadata.delete(key);
    }
    return chunk;
  }

  getChunkAuthorityMetadata(coord: FChunkCoord): AuthoritativeChunkMetadata | null {
    const metadata = this.authoritativeChunkMetadata.get(chunkCoordKey(coord));
    return metadata ? { ...metadata } : null;
  }

  bumpChunkAuthorityVersion(
    coord: FChunkCoord,
    update: { chunkVersion: number; chunkHash?: number; receivedAtMs?: number },
  ): AuthoritativeChunkMetadata | null {
    const key = chunkCoordKey(coord);
    const existing = this.authoritativeChunkMetadata.get(key);
    if (!existing) {
      return null;
    }
    const next: AuthoritativeChunkMetadata = {
      ...existing,
      chunkVersion: update.chunkVersion,
      chunkHash: update.chunkHash ?? existing.chunkHash,
      receivedAtMs: update.receivedAtMs ?? existing.receivedAtMs,
    };
    this.authoritativeChunkMetadata.set(key, next);
    return { ...next };
  }

  invalidateChunkAuthority(coord: FChunkCoord): boolean {
    return this.authoritativeChunkMetadata.delete(chunkCoordKey(coord));
  }

  removeChunk(coord: FChunkCoord): boolean {
    const key = chunkCoordKey(coord);
    const had = this.chunks.delete(key);
    this.authoritativeChunkMetadata.delete(key);
    return had;
  }

  authoritativeChunkSummaries(limit = 16): Array<AuthoritativeChunkMetadata & { coord: FChunkCoord; key: string }> {
    return this.listChunks()
      .slice(0, limit)
      .flatMap((chunk) => {
        const key = chunkCoordKey(chunk.data.chunkCoord);
        const metadata = this.authoritativeChunkMetadata.get(key);
        if (!metadata) {
          return [];
        }
        return [{ ...metadata, coord: { ...chunk.data.chunkCoord }, key }];
      });
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
        ...this.chunkAuthoritySummaryFields(chunk.data.chunkCoord),
      }));
  }

  totalSolidBlocks(): number {
    return this.listChunks().reduce((sum, chunk) => sum + chunk.countSolidBlocks(), 0);
  }

  totalRefinedCells(): number {
    return this.listChunks().reduce((sum, chunk) => sum + chunk.countRefinedCells(), 0);
  }

  exportSnapshot(): SerializedWorldSnapshot {
    return exportWorldSnapshot(this.listChunks(), this.editStats);
  }

  importSnapshot(snapshot: SerializedWorldSnapshot): void {
    importWorldSnapshot(snapshot, {
      editStats: this.editStats,
      clearChunks: () => this.chunks.clear(),
      ensureChunk: (coord) => this.ensureChunk(coord),
    });
    this.authoritativeChunkMetadata.clear();
  }

  isSolidWorldMacroCoord(worldMacro: FMacroCoord): boolean {
    return this.getNormalBlockWorld(worldMacro) !== null;
  }

  getNormalBlockWorld(worldMacro: FMacroCoord): FNormalBlockData | null {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    return chunk?.getNormalBlock(localMacro) ?? null;
  }

  getMicroBlockWorld(worldMacro: FMacroCoord, micro: FMicroCoord): FNormalBlockData | null {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    return chunk?.getMicroBlock(localMacro, micro) ?? null;
  }

  getRefinedCellWorld(worldMacro: FMacroCoord): FRefinedCellData | null {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    return chunk?.getRefinedCell(localMacro) ?? null;
  }

  getMicroOccupancyMaskWorld(worldMacro: FMacroCoord): bigint {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    const header = chunk?.getHeaderAt(localMacro);
    if (!chunk || !header) {
      return 0n;
    }
    if (header.mode === EVoxelCellMode.SolidBlock) {
      return FullMicroOccupancyMask;
    }
    if (header.mode !== EVoxelCellMode.Refined) {
      return 0n;
    }
    const refined = chunk.data.refinedCells[header.payloadIndex];
    return refined ? normalizeRefinedCell(refined).microOccupancyMask : 0n;
  }

  isSolidWorldMicroCoord(worldMacro: FMacroCoord, micro: FMicroCoord): boolean {
    return this.getMicroBlockWorld(worldMacro, micro) !== null;
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

  setMicroBlockWorld(
    worldMacro: FMacroCoord,
    micro: FMicroCoord,
    block: FNormalBlockData,
  ): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro, true);
    if (!chunk) {
      this.editStats.rejected += 1;
      return false;
    }
    const ok = chunk.setMicroBlock(localMacro, micro, block);
    if (ok) {
      this.editStats.placed += 1;
    } else {
      this.editStats.rejected += 1;
    }
    return ok;
  }

  clearMicroBlockWorld(worldMacro: FMacroCoord, micro: FMicroCoord): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro);
    if (!chunk) {
      this.editStats.rejected += 1;
      return false;
    }
    const ok = chunk.clearMicroBlock(localMacro, micro);
    if (ok) {
      this.editStats.broken += 1;
    } else {
      this.editStats.rejected += 1;
    }
    return ok;
  }

  setPrefabFullMacroBlockWorld(
    worldMacro: FMacroCoord,
    block: FNormalBlockData,
    instanceId: number,
  ): boolean {
    return this.setPrefabRefinedMicroCellWorld(
      worldMacro,
      FullMicroOccupancyMask,
      block.materialId,
      block.stateFlags,
      new Array(MicroGridSlotCount).fill(0),
      instanceId,
    );
  }

  setPrefabRefinedMicroCellWorld(
    worldMacro: FMacroCoord,
    microOccupancyMask: bigint,
    materialId: number,
    stateFlags: number,
    microPartIds: number[],
    instanceId: number,
  ): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro, true);
    if (!chunk) {
      this.editStats.rejected += 1;
      return false;
    }
    const ok = chunk.setPrefabRefinedMicroCell(
      localMacro,
      microOccupancyMask,
      materialId,
      stateFlags,
      microPartIds,
      instanceId,
    );
    if (ok) {
      this.editStats.placed += 1;
    } else {
      this.editStats.rejected += 1;
    }
    return ok;
  }

  unionPrefabRefinedMicroCellWorld(
    worldMacro: FMacroCoord,
    microOccupancyMask: bigint,
    microMaterialIds: number[],
    microStateFlags: number[],
    microPartIds: number[],
    instanceId: number,
  ): boolean {
    const { chunk, localMacro } = this.resolveChunkAndLocal(worldMacro, true);
    if (!chunk) {
      this.editStats.rejected += 1;
      return false;
    }
    const ok = chunk.unionPrefabRefinedMicroCell(
      localMacro,
      microOccupancyMask,
      microMaterialIds,
      microStateFlags,
      microPartIds,
      instanceId,
    );
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

  findPrefabInstance(instanceId: number): FPrefabInstanceData | null {
    for (const chunk of this.listChunks()) {
      const found = chunk.data.prefabInstances.find(
        (instance) => instance.instanceId === instanceId,
      );
      if (found) {
        return clonePrefabInstance(found);
      }
    }
    return null;
  }

  surfaceCenterYAtWorldXZ(
    worldX: number,
    worldZ: number,
    halfHeight: number,
    fallbackY: number,
  ): number {
    if (this.chunks.size === 0) {
      return fallbackY;
    }

    const macroX = Math.floor(worldX / MacroWorldSize);
    const macroZ = Math.floor(worldZ / MacroWorldSize);
    const chunkYs = this.listChunks().map((chunk) => chunk.data.chunkCoord.y);
    const maxChunkY = Math.max(...chunkYs, 0);
    const minChunkY = Math.min(...chunkYs, 0);
    const maxMacroY = (maxChunkY + 1) * VoxelConstants.ChunkSizeY - 1;
    const minMacroY = minChunkY * VoxelConstants.ChunkSizeY;

    for (let macroY = maxMacroY; macroY >= minMacroY; macroY -= 1) {
      if (this.getNormalBlockWorld({ x: macroX, y: macroY, z: macroZ })) {
        const groundedCenterY = (macroY + 1) * MacroWorldSize + halfHeight;
        return Math.max(groundedCenterY, fallbackY);
      }
    }

    return fallbackY;
  }

  seedRegionalShowcase(radius: number = 2): void {
    seedRegionalShowcaseWorld(this, radius);
  }

  private chunkAuthoritySummaryFields(
    coord: FChunkCoord,
  ): Pick<ChunkSummary, "logicalSceneId" | "chunkVersion" | "chunkHash"> {
    const metadata = this.getChunkAuthorityMetadata(coord);
    if (!metadata) {
      return {};
    }
    return {
      logicalSceneId: metadata.logicalSceneId,
      chunkVersion: metadata.chunkVersion,
      chunkHash: metadata.chunkHash,
    };
  }

  private resolveChunkAndLocal(
    worldMacro: FMacroCoord,
    createIfMissing = false,
  ): { chunk: ChunkStorage | null; localMacro: FMacroCoord } {
    const chunkCoord = chunkCoordFromMacro(worldMacro);
    const localMacro = localMacroInChunk(worldMacro);
    const chunk = createIfMissing ? this.ensureChunk(chunkCoord) : this.getChunk(chunkCoord);
    return { chunk, localMacro };
  }
}
