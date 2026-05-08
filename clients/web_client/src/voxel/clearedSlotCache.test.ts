import { describe, expect, it } from "vitest";

import { CLEARED_SLOT_CACHE_DEFAULTS, ClearedSlotCache } from "./clearedSlotCache";

function slot(x: number, y: number, z: number, ts: number) {
  return { worldX: x, worldY: y, worldZ: z, timestampMs: ts };
}

describe("ClearedSlotCache", () => {
  it("put + take returns the inserted slots in insertion order", () => {
    const cache = new ClearedSlotCache();
    cache.put(1n, slot(0, 0, 0, 100));
    cache.put(1n, slot(1, 0, 0, 101));

    const taken = cache.take(1n);
    expect(taken).toEqual([slot(0, 0, 0, 100), slot(1, 0, 0, 101)]);
  });

  it("take consumes the bucket so a follow-up take returns empty", () => {
    const cache = new ClearedSlotCache();
    cache.put(1n, slot(0, 0, 0, 100));
    expect(cache.take(1n)).toHaveLength(1);
    expect(cache.take(1n)).toHaveLength(0);
  });

  it("take returns empty array for an unknown object_id", () => {
    const cache = new ClearedSlotCache();
    expect(cache.take(99n)).toEqual([]);
  });

  it("tracks each object_id independently", () => {
    const cache = new ClearedSlotCache();
    cache.put(1n, slot(0, 0, 0, 100));
    cache.put(2n, slot(5, 5, 5, 100));
    cache.put(2n, slot(6, 5, 5, 100));

    expect(cache.peekCount(1n)).toBe(1);
    expect(cache.peekCount(2n)).toBe(2);
    expect(cache.totalCachedSlots()).toBe(3);
  });

  it("sweep drops entries older than ttlMs", () => {
    const cache = new ClearedSlotCache({ ttlMs: 1_000 });

    cache.put(1n, slot(0, 0, 0, 100));
    cache.put(1n, slot(1, 0, 0, 1_500));
    cache.put(2n, slot(0, 0, 0, 200));

    // now=1_600 ms → cutoff=600 ms.  ts=100 / 200 are stale; ts=1500 stays.
    const dropped = cache.sweep(1_600);

    expect(dropped).toBe(2);
    expect(cache.peekCount(1n)).toBe(1);
    expect(cache.peekCount(2n)).toBe(0);
  });

  it("sweep removes the bucket entirely when all entries are stale", () => {
    const cache = new ClearedSlotCache({ ttlMs: 1_000 });

    cache.put(1n, slot(0, 0, 0, 100));
    cache.put(1n, slot(1, 0, 0, 200));

    cache.sweep(2_000);

    // The map entry for 1n should be gone.
    expect(cache.totalCachedSlots()).toBe(0);
    expect(cache.take(1n)).toEqual([]);
  });

  it("enforces single-object capacity by dropping oldest entries", () => {
    const cache = new ClearedSlotCache({ maxSlotsPerObject: 3 });

    for (let i = 0; i < 5; i++) {
      cache.put(1n, slot(i, 0, 0, 100));
    }

    const taken = cache.take(1n);
    // Only the last 3 inserted slots should remain.
    expect(taken).toEqual([
      slot(2, 0, 0, 100),
      slot(3, 0, 0, 100),
      slot(4, 0, 0, 100),
    ]);
  });

  it("uses sane default TTL and capacity", () => {
    expect(CLEARED_SLOT_CACHE_DEFAULTS.ttlMs).toBe(2_000);
    expect(CLEARED_SLOT_CACHE_DEFAULTS.maxSlotsPerObject).toBe(256);
  });

  it("reset clears all buckets", () => {
    const cache = new ClearedSlotCache();
    cache.put(1n, slot(0, 0, 0, 100));
    cache.put(2n, slot(1, 0, 0, 100));

    cache.reset();

    expect(cache.totalCachedSlots()).toBe(0);
    expect(cache.take(1n)).toEqual([]);
    expect(cache.take(2n)).toEqual([]);
  });
});
