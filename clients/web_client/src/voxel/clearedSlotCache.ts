// Phase 4-bis Step 4-bis-8: ClearedSlotCache.
//
// Short-lived per-object cache that records "this micro slot just got
// cleared by ChunkDelta and used to be owned by object_id". Step 4-bis-10
// will read from this cache when 0x6C ObjectStateDelta arrives, sample
// some entries, and use them as debris particle spawn anchors.
//
// Ordering(decision D6 时序兜底):
//
//   * ChunkDelta 先到(典型路径):apply 前 hook 把 cleared micro slots
//     按 owner_object_id 写入缓存 → 0x6C 来时 take。
//   * 0x6C 先到:consumer 等 100ms 再 take(Step 4-bis-10),缓存窗口内
//     可能填进来。
//   * 完全乱序 / cache miss:Step 4-bis-10 降级到 affected_chunks 中心点
//     播粒子。
//
// Hard limits(防止 prefab 极大或 0x6C 永远不来时内存涨):
//
//   * 单 object 缓存的 micro slot 上限 = MAX_SLOTS_PER_OBJECT(256)
//   * TTL = CACHE_TTL_MS(2000ms),sweep 时丢老的
//
// 不在范围:cache 不知道 part_id(协议 0x6C 也没 part_id 字段)。
// flag_part_destroyed / flag_damaged 时 Step 4-bis-10 在该 object 全部
// 缓存上做近似采样,精确 part 级别留 Phase 5+。

export interface ClearedSlot {
  worldX: number;
  worldY: number;
  worldZ: number;
  timestampMs: number;
}

export interface ClearedSlotCacheOptions {
  ttlMs?: number;
  maxSlotsPerObject?: number;
}

export const CLEARED_SLOT_CACHE_DEFAULTS = {
  ttlMs: 2_000,
  maxSlotsPerObject: 256,
} as const;

export class ClearedSlotCache {
  private readonly slotsByObjectId = new Map<bigint, ClearedSlot[]>();
  private readonly ttlMs: number;
  private readonly maxSlotsPerObject: number;

  constructor(options: ClearedSlotCacheOptions = {}) {
    this.ttlMs = options.ttlMs ?? CLEARED_SLOT_CACHE_DEFAULTS.ttlMs;
    this.maxSlotsPerObject =
      options.maxSlotsPerObject ?? CLEARED_SLOT_CACHE_DEFAULTS.maxSlotsPerObject;
  }

  put(objectId: bigint, slot: ClearedSlot): void {
    let bucket = this.slotsByObjectId.get(objectId);
    if (bucket === undefined) {
      bucket = [];
      this.slotsByObjectId.set(objectId, bucket);
    }
    bucket.push(slot);
    if (bucket.length > this.maxSlotsPerObject) {
      // Drop oldest entries (FIFO). Splice from the head — this stays cheap
      // because MAX_SLOTS_PER_OBJECT is small (256) so the rare overflow
      // path is O(maxSlotsPerObject) and only on hot prefab destruction.
      bucket.splice(0, bucket.length - this.maxSlotsPerObject);
    }
  }

  // Take the entire entry for an object_id (consumer reads this when 0x6C
  // arrives). The bucket is removed atomically — a follow-up 0x6C for the
  // same object_id sees an empty cache, which is correct because every
  // 0x6C represents a separate event window in the protocol(D5)。
  take(objectId: bigint): ClearedSlot[] {
    const bucket = this.slotsByObjectId.get(objectId);
    if (bucket === undefined) {
      return [];
    }
    this.slotsByObjectId.delete(objectId);
    return bucket;
  }

  // Drop entries older than ttlMs from now. Called periodically by Step
  // 4-bis-10 (or by tests directly).
  sweep(nowMs: number): number {
    let dropped = 0;
    const cutoff = nowMs - this.ttlMs;

    for (const [objectId, bucket] of this.slotsByObjectId) {
      const filtered = bucket.filter((slot) => slot.timestampMs >= cutoff);
      if (filtered.length === 0) {
        this.slotsByObjectId.delete(objectId);
        dropped += bucket.length;
        continue;
      }
      if (filtered.length !== bucket.length) {
        dropped += bucket.length - filtered.length;
        this.slotsByObjectId.set(objectId, filtered);
      }
    }

    return dropped;
  }

  // Test hatch:peek slot count for an object_id without consuming.
  peekCount(objectId: bigint): number {
    return this.slotsByObjectId.get(objectId)?.length ?? 0;
  }

  // Test hatch:total cached entries.
  totalCachedSlots(): number {
    let sum = 0;
    for (const bucket of this.slotsByObjectId.values()) {
      sum += bucket.length;
    }
    return sum;
  }

  reset(): void {
    this.slotsByObjectId.clear();
  }
}
