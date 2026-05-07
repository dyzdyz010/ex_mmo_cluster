// Phase 1c-5 lossy adapter: server-authoritative `RefinedCellWireData`
// (occupancy + parallel layer attribute pools, `apps/scene_server/lib/scene_server/voxel/codec.ex`)
// → browser-side `FRefinedCellData` (single 512-bit occupancy bigint + flat
// per-slot arrays, `clients/web_client/src/voxel/storage/types.ts`).
//
// Decision 5 of `docs/voxel-server-authority/phase-1c-refined-mutation.md`
// pins online-mode truth at the wire form. The renderer / mesher / collision
// path still consumes `FRefinedCellData`, so we materialize on demand here.
// The conversion is lossy in two directions:
//
//   - `tagSetRef`, `attributeSetRef`, `ownerObjectId`, `objectRefs` and
//     `boundaryCache` (full u64) are dropped or narrowed; the renderer does
//     not read them today.
//   - When two layers cover the same slot (the wire format guarantees they
//     do not, but the adapter must be defensive) the layer that appears
//     later in `wire.layers` wins.
//
// The result is *not* written back to the wire. Authoritative state is
// re-derived from each subsequent `ChunkSnapshot` / `ChunkDelta`.
import type { RefinedCellWireData } from "../infrastructure/net/refinedCellWire";
import { VoxelConstants } from "./core/constants";
import type { FRefinedCellData } from "./storage/types";

const SLOT_COUNT = VoxelConstants.MicroCountPerMacro;
const WORD_BIT_WIDTH = 64;

export function wireToRefinedCell(wire: RefinedCellWireData): FRefinedCellData {
  return {
    microOccupancyMask: combineMaskWords(wire.occupancyWords),
    microMaterialIds: assembleSlotArray(wire.layers, (layer) => layer.materialId, 0),
    microStateFlags: assembleSlotArray(wire.layers, (layer) => layer.stateFlags, 0),
    microPartIds: assembleSlotArray(wire.layers, (layer) => layer.ownerPartId, -1),
    prefabInstanceIds: [],
    boundaryCache: Number(wire.boundaryCache & 0xffff_ffffn),
  };
}

function combineMaskWords(words: readonly bigint[]): bigint {
  let mask = 0n;
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i] ?? 0n;
    mask |= word << BigInt(i * WORD_BIT_WIDTH);
  }
  return mask;
}

function assembleSlotArray<T extends { maskWords: readonly bigint[] }>(
  layers: readonly T[],
  pick: (layer: T) => number,
  fallback: number,
): number[] {
  const out = new Array<number>(SLOT_COUNT).fill(fallback);
  for (const layer of layers) {
    const layerMask = combineMaskWords(layer.maskWords);
    if (layerMask === 0n) {
      continue;
    }
    const value = pick(layer);
    let remaining = layerMask;
    while (remaining !== 0n) {
      const slot = trailingZeros(remaining);
      out[slot] = value;
      remaining &= remaining - 1n;
    }
  }
  return out;
}

function trailingZeros(value: bigint): number {
  // Mask is non-zero by precondition. BigInt has no clz, so step by hex
  // digits to find the lowest bit cheaply.
  let count = 0;
  let v = value;
  while ((v & 0xffffffffn) === 0n) {
    v >>= 32n;
    count += 32;
  }
  while ((v & 1n) === 0n) {
    v >>= 1n;
    count += 1;
  }
  return count;
}
