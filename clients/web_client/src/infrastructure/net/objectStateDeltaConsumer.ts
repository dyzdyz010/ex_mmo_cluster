// Phase 4-bis Step 4-bis-7: ObjectStateDeltaConsumer.
//
// Consumes decoded `ObjectStateDelta` messages produced by the wire
// decoder. Phase 4-bis 阶段 7 仅做:
//
//   * per-object_version 单调去重 (decision D3)
//   * console.log 通知(给浏览器手测看到 0x6C 到达)
//
// Phase 4-bis 后续 step:
//
//   * Step 4-bis-8 引入 ClearedSlotCache(ChunkDelta hook 端写入)
//   * Step 4-bis-9 引入 DebrisEffect(InstancedMesh 碎屑粒子)
//   * Step 4-bis-10 把 cache + effect 串到本 consumer 的 destroyed /
//     part_destroyed / damaged 分支,加 100ms delay 容忍 0x6C 先到、
//     ChunkDelta 后到的乱序;HUD 钩子也在那一步接入。
//
// 设计(D5):每条 0x6C 消息只表达 **这次事件** 触发的 flag,不做累计
// mask reduce。客户端按 object_version 单调递增去重(D3)。

import type { ObjectStateDelta } from "./objectStateDelta";

// PartState flag bits — must match server-side `SceneServer.Voxel.PartState`.
export const ObjectStateFlag = {
  Damaged: 0x01,
  Destroyed: 0x02,
  PartDestroyed: 0x04,
} as const;

export type ObjectStateFlagValue =
  (typeof ObjectStateFlag)[keyof typeof ObjectStateFlag];

export type ObjectStateFlagName = "damaged" | "part_destroyed" | "destroyed" | "unknown";

export function describeObjectStateFlag(stateFlags: number): ObjectStateFlagName {
  if ((stateFlags & ObjectStateFlag.Destroyed) !== 0) {
    return "destroyed";
  }
  if ((stateFlags & ObjectStateFlag.PartDestroyed) !== 0) {
    return "part_destroyed";
  }
  if ((stateFlags & ObjectStateFlag.Damaged) !== 0) {
    return "damaged";
  }
  return "unknown";
}

export interface ObjectStateDeltaConsumerOptions {
  // Hook called for every (non-deduped) delta. Defaults to a console.log
  // in dev / browser console; tests inject a spy.
  onDelta?: (delta: ObjectStateDelta, flagName: ObjectStateFlagName) => void;
  // Hook called when a delta is dropped because object_version <= last seen.
  onDuplicate?: (delta: ObjectStateDelta) => void;
}

export class ObjectStateDeltaConsumer {
  private readonly lastSeenVersionByObjectId = new Map<bigint, bigint>();
  private readonly onDelta: (delta: ObjectStateDelta, flagName: ObjectStateFlagName) => void;
  private readonly onDuplicate: (delta: ObjectStateDelta) => void;

  constructor(options: ObjectStateDeltaConsumerOptions = {}) {
    this.onDelta = options.onDelta ?? defaultLogDelta;
    this.onDuplicate = options.onDuplicate ?? defaultLogDuplicate;
  }

  consume(delta: ObjectStateDelta): boolean {
    const lastSeen = this.lastSeenVersionByObjectId.get(delta.objectId);

    if (lastSeen !== undefined && delta.objectVersion <= lastSeen) {
      this.onDuplicate(delta);
      return false;
    }

    this.lastSeenVersionByObjectId.set(delta.objectId, delta.objectVersion);
    this.onDelta(delta, describeObjectStateFlag(delta.stateFlags));
    return true;
  }

  reset(): void {
    this.lastSeenVersionByObjectId.clear();
  }

  // Test hatch: peek at the per-object dedupe state.
  knownObjectVersion(objectId: bigint): bigint | undefined {
    return this.lastSeenVersionByObjectId.get(objectId);
  }
}

function defaultLogDelta(delta: ObjectStateDelta, flagName: ObjectStateFlagName): void {
  // eslint-disable-next-line no-console
  console.log("[voxel] ObjectStateDelta", {
    flagName,
    objectId: delta.objectId.toString(),
    objectVersion: delta.objectVersion.toString(),
    logicalSceneId: delta.logicalSceneId.toString(),
    stateFlags: `0x${delta.stateFlags.toString(16)}`,
    affectedChunks: delta.affectedChunks,
  });
}

function defaultLogDuplicate(delta: ObjectStateDelta): void {
  // eslint-disable-next-line no-console
  console.debug("[voxel] ObjectStateDelta dropped(stale version)", {
    objectId: delta.objectId.toString(),
    objectVersion: delta.objectVersion.toString(),
  });
}
