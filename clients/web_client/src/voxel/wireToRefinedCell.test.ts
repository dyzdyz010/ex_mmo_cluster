import { describe, expect, it } from "vitest";
import type { RefinedCellWireData } from "../infrastructure/net/refinedCellWire";
import { VoxelConstants } from "./core/constants";
import { wireToRefinedCell } from "./wireToRefinedCell";

const SLOT_COUNT = VoxelConstants.MicroCountPerMacro;

function emptyMaskWords(): bigint[] {
  return [0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];
}

function maskWordsForSlots(...slots: number[]): bigint[] {
  const words = emptyMaskWords();
  for (const slot of slots) {
    if (slot < 0 || slot >= SLOT_COUNT) {
      throw new Error(`bad_slot:${slot}`);
    }
    const wordIndex = Math.floor(slot / 64);
    const bitIndex = slot % 64;
    const word = words[wordIndex] ?? 0n;
    words[wordIndex] = word | (1n << BigInt(bitIndex));
  }
  return words;
}

function emptyWireCell(): RefinedCellWireData {
  return {
    occupancyWords: emptyMaskWords(),
    boundaryCache: 0n,
    layers: [],
    objectRefs: [],
  };
}

describe("wireToRefinedCell", () => {
  it("returns an empty refined cell when no layers are present", () => {
    const refined = wireToRefinedCell(emptyWireCell());

    expect(refined.microOccupancyMask).toBe(0n);
    expect(refined.microMaterialIds).toHaveLength(SLOT_COUNT);
    expect(refined.microMaterialIds.every((m) => m === 0)).toBe(true);
    expect(refined.microStateFlags.every((f) => f === 0)).toBe(true);
    expect(refined.microPartIds.every((id) => id === -1)).toBe(true);
    expect(refined.prefabInstanceIds).toEqual([]);
  });

  it("combines occupancyWords into a single 512-bit mask using 64-bit shifts", () => {
    const wire: RefinedCellWireData = {
      occupancyWords: [1n, 0n, 1n, 0n, 0n, 0n, 0n, 0n],
      boundaryCache: 0n,
      layers: [],
      objectRefs: [],
    };

    const refined = wireToRefinedCell(wire);

    // Bits at slot 0 and slot 128 should be set.
    expect(refined.microOccupancyMask & 1n).toBe(1n);
    expect((refined.microOccupancyMask >> 128n) & 1n).toBe(1n);
    // Other slots stay zero.
    expect((refined.microOccupancyMask >> 64n) & 1n).toBe(0n);
  });

  it("assembles per-slot material/state/partId arrays from layered masks", () => {
    const wire: RefinedCellWireData = {
      occupancyWords: maskWordsForSlots(0, 5, 9),
      boundaryCache: 0n,
      layers: [
        {
          maskWords: maskWordsForSlots(0, 5),
          materialId: 17,
          stateFlags: 0xff,
          health: 100,
          attributeSetRef: 0,
          tagSetRef: 0,
          ownerObjectId: 0n,
          ownerPartId: 3,
        },
        {
          maskWords: maskWordsForSlots(9),
          materialId: 42,
          stateFlags: 0,
          health: 50,
          attributeSetRef: 0,
          tagSetRef: 0,
          ownerObjectId: 0n,
          ownerPartId: 7,
        },
      ],
      objectRefs: [],
    };

    const refined = wireToRefinedCell(wire);

    expect(refined.microMaterialIds[0]).toBe(17);
    expect(refined.microMaterialIds[5]).toBe(17);
    expect(refined.microMaterialIds[9]).toBe(42);
    expect(refined.microStateFlags[0]).toBe(0xff);
    expect(refined.microStateFlags[9]).toBe(0);
    expect(refined.microPartIds[5]).toBe(3);
    expect(refined.microPartIds[9]).toBe(7);
    // Unset slots stay at the fallback values.
    expect(refined.microMaterialIds[1]).toBe(0);
    expect(refined.microPartIds[1]).toBe(-1);
  });

  it("narrows boundaryCache to a 32-bit number", () => {
    const wire: RefinedCellWireData = {
      occupancyWords: emptyMaskWords(),
      boundaryCache: 0xdead_beefn,
      layers: [],
      objectRefs: [],
    };

    const refined = wireToRefinedCell(wire);

    expect(refined.boundaryCache).toBe(0xdead_beef);
  });
});
