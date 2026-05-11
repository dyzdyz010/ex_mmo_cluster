import { buildChunkMeshData } from "../voxel/meshing/chunkMesher";
import type { ChunkMeshBuildData } from "../voxel/meshing/chunkMesher";
import type { FMacroCoord } from "../voxel/core/types";
import type { FChunkMesherInputSnapshot } from "../voxel/meshing/types";

interface ChunkMeshWorkerRequest {
  id: number;
  key: string;
  snapshot: FChunkMesherInputSnapshot;
  solidWorldMacroKeys: string[];
}

interface ChunkMeshWorkerSuccess {
  id: number;
  key: string;
  ok: true;
  meshData: ChunkMeshBuildData;
  durationMs: number;
}

interface ChunkMeshWorkerFailure {
  id: number;
  key: string;
  ok: false;
  reason: string;
  durationMs: number;
}

type ChunkMeshWorkerResponse = ChunkMeshWorkerSuccess | ChunkMeshWorkerFailure;

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<ChunkMeshWorkerRequest>) => void) | null;
  postMessage(message: ChunkMeshWorkerResponse): void;
};

scope.onmessage = (event: MessageEvent<ChunkMeshWorkerRequest>) => {
  const startedAt = performance.now();
  const { id, key, snapshot, solidWorldMacroKeys } = event.data;
  const solidWorldMacros = new Set(solidWorldMacroKeys);

  try {
    const meshData = buildChunkMeshData(snapshot, {
      isSolidWorldMacroCoord(coord: FMacroCoord): boolean {
        return solidWorldMacros.has(macroKey(coord));
      },
      isSolidWorldMicroCoord(): boolean {
        return false;
      },
    });

    const response: ChunkMeshWorkerResponse = {
      id,
      key,
      ok: true,
      meshData,
      durationMs: Math.round(performance.now() - startedAt),
    };
    scope.postMessage(response);
  } catch (error) {
    const response: ChunkMeshWorkerResponse = {
      id,
      key,
      ok: false,
      reason: error instanceof Error ? error.message : "unknown",
      durationMs: Math.round(performance.now() - startedAt),
    };
    scope.postMessage(response);
  }
};

function macroKey(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

export {};
