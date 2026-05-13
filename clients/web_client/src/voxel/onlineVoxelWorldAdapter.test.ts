import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EventBus } from "../shared/events/eventBus";
import type { AppEvents } from "../shared/events/events";
import { ObserveLog } from "../observe/logger";
import { VoxelOpcode } from "../infrastructure/net/opcodes";
import type {
  VoxelChunkDeltaMessage,
  VoxelChunkInvalidateMessage,
  VoxelChunkSnapshotMessage,
  VoxelDebugProbeMessage,
  VoxelIntentResultMessage,
  VoxelObjectStateDeltaMessage,
} from "../infrastructure/net/voxelProtocol";
import { OnlineVoxelWorldAdapter, type ServerVoxelTransportPort } from "./onlineVoxelWorldAdapter";
import { OnlinePrefabBlueprintVersion } from "./onlinePrefabCatalog";
import { VoxelConstants } from "./core/constants";
import { ChunkStorage } from "./storage/chunkStorage";

interface PrefabPlaceCall {
  logicalSceneId: number;
  parcelId: number;
  knownParcelBuildEpoch: number;
  blueprintId: number;
  blueprintVersion: number;
  anchorWorldMicro: { x: number; y: number; z: number };
  rotation: number;
  clientIntentSeq: number;
}

interface ImpactCall {
  logicalSceneId: number;
  sourceSkillId: number;
  impactKind: number;
  clientIntentSeq: number;
}

interface EditIntentCall {
  logicalSceneId: number;
  action: number;
  targetGranularity: number;
  targetWorldMicro: { x: number; y: number; z: number };
  faceNormal: { x: number; y: number; z: number };
  materialId: number;
  expectedChunkVersion: bigint;
  expectedCellHash: number;
  clientIntentSeq: number;
}

interface SubscribeCall {
  logicalSceneId: number;
  centerChunk: { x: number; y: number; z: number };
  radiusLInf: number;
  wantSnapshot: boolean;
}

class FakeServerVoxelTransport implements ServerVoxelTransportPort {
  readonly prefabCalls: PrefabPlaceCall[] = [];
  readonly impactCalls: ImpactCall[] = [];
  readonly editIntentCalls: EditIntentCall[] = [];
  readonly subscribeCalls: SubscribeCall[] = [];
  readonly queuedSnapshots: VoxelChunkSnapshotMessage[] = [];
  available = true;
  nextRequestId = 100;

  canUseServerVoxel(): boolean {
    return this.available;
  }

  getAuthBaseUrl(): string {
    return "http://localhost";
  }

  voxelDebugSnapshot(): Record<string, unknown> {
    return {};
  }

  sendVoxelDebugProbe(): number | null {
    return this.allocateRequestId();
  }

  sendVoxelChunkSubscribe(request: SubscribeCall): number | null {
    this.subscribeCalls.push({
      logicalSceneId: request.logicalSceneId,
      centerChunk: { ...request.centerChunk },
      radiusLInf: request.radiusLInf,
      wantSnapshot: request.wantSnapshot,
    });
    return this.allocateRequestId();
  }

  sendVoxelChunkUnsubscribe(): number | null {
    return this.allocateRequestId();
  }

  sendVoxelImpactIntent(
    request: ImpactCall & {
      targetWorldMicro: { x: number; y: number; z: number };
      impactKind: number;
      clientHintHash?: number;
    },
  ): number | null {
    if (!this.available) return null;
    this.impactCalls.push({
      logicalSceneId: request.logicalSceneId,
      sourceSkillId: request.sourceSkillId,
      impactKind: request.impactKind,
      clientIntentSeq: request.clientIntentSeq,
    });
    return this.allocateRequestId();
  }

  sendVoxelEditIntent(request: {
    logicalSceneId: number;
    action: number;
    targetGranularity: number;
    targetWorldMicro: { x: number; y: number; z: number };
    faceNormal: { x: number; y: number; z: number };
    materialId: number;
    blueprintRef?: number;
    objectRef?: bigint;
    partRef?: number;
    attributePatchRef?: number;
    expectedChunkVersion?: bigint;
    expectedCellHash?: number;
    clientIntentSeq: number;
    clientHintHash?: bigint;
  }): number | null {
    if (!this.available) return null;
    this.editIntentCalls.push({
      logicalSceneId: request.logicalSceneId,
      action: request.action,
      targetGranularity: request.targetGranularity,
      targetWorldMicro: { ...request.targetWorldMicro },
      faceNormal: { ...request.faceNormal },
      materialId: request.materialId,
      expectedChunkVersion:
        request.expectedChunkVersion ?? 0xffff_ffff_ffff_ffffn,
      expectedCellHash: request.expectedCellHash ?? 0xffff_ffff,
      clientIntentSeq: request.clientIntentSeq,
    });
    return this.allocateRequestId();
  }

  sendVoxelPrefabPlaceIntent(request: PrefabPlaceCall): number | null {
    if (!this.available) return null;
    this.prefabCalls.push({
      logicalSceneId: request.logicalSceneId,
      parcelId: request.parcelId,
      knownParcelBuildEpoch: request.knownParcelBuildEpoch,
      blueprintId: request.blueprintId,
      blueprintVersion: request.blueprintVersion,
      anchorWorldMicro: { ...request.anchorWorldMicro },
      rotation: request.rotation,
      clientIntentSeq: request.clientIntentSeq,
    });
    return this.allocateRequestId();
  }

  drainVoxelSnapshots(): VoxelChunkSnapshotMessage[] {
    return this.queuedSnapshots.splice(0, this.queuedSnapshots.length);
  }

  drainVoxelDeltas(): VoxelChunkDeltaMessage[] {
    return [];
  }

  drainVoxelInvalidates(): VoxelChunkInvalidateMessage[] {
    return [];
  }

  drainVoxelIntentResults(): VoxelIntentResultMessage[] {
    return [];
  }

  drainVoxelDebugProbes(): VoxelDebugProbeMessage[] {
    return [];
  }

  readonly queuedObjectStateDeltas: VoxelObjectStateDeltaMessage[] = [];

  drainVoxelObjectStateDeltas(): VoxelObjectStateDeltaMessage[] {
    return this.queuedObjectStateDeltas.splice(0, this.queuedObjectStateDeltas.length);
  }

  private allocateRequestId(): number {
    const value = this.nextRequestId;
    this.nextRequestId += 1;
    return value;
  }
}

function emptySnapshot(chunkCoord: { x: number; y: number; z: number }): VoxelChunkSnapshotMessage {
  return {
    type: "voxel_chunk_snapshot",
    requestId: 10,
    logicalSceneId: 7,
    chunkCoord,
    schemaVersion: 1,
    chunkSizeInMacro: VoxelConstants.ChunkSizeInMacros,
    microResolution: VoxelConstants.MicroPerMacro,
    chunkVersion: 0,
    chunkHash: 0,
    storage: ChunkStorage.createEmpty(chunkCoord).data,
    refinedCellsWire: [],
    attributeSets: [],
    tagSets: [],
    objectRefs: [],
  };
}

function createAdapter() {
  const transport = new FakeServerVoxelTransport();
  const bus = new EventBus<AppEvents>();
  const logger = new ObserveLog();
  const adapter = new OnlineVoxelWorldAdapter(transport, bus, logger, {
    logicalSceneId: 7,
    devSeed: false,
    primeDemoBlock: false,
  });
  return { adapter, transport, bus, logger };
}

beforeEach(() => {
  // Silence the ObserveLog console.info side effects so the test output stays clean.
  vi.spyOn(console, "info").mockImplementation(() => undefined);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("OnlineVoxelWorldAdapter#placePrefab", () => {
  it("subscribes all configured startup chunks with their exact radii", () => {
    const transport = new FakeServerVoxelTransport();
    const bus = new EventBus<AppEvents>();
    const logger = new ObserveLog();
    const adapter = new OnlineVoxelWorldAdapter(transport, bus, logger, {
      logicalSceneId: 7,
      devSeed: false,
      primeDemoBlock: false,
      initialSubscriptions: [
        { centerChunk: { x: 0, y: 0, z: 0 }, radiusLInf: 0 },
        { centerChunk: { x: 1, y: 0, z: 0 }, radiusLInf: 0 },
      ],
    });

    adapter.onFrame(0);
    adapter.onFrame(16);

    expect(transport.subscribeCalls).toEqual([
      {
        logicalSceneId: 7,
        centerChunk: { x: 0, y: 0, z: 0 },
        radiusLInf: 0,
        wantSnapshot: true,
      },
      {
        logicalSceneId: 7,
        centerChunk: { x: 1, y: 0, z: 0 },
        radiusLInf: 0,
        wantSnapshot: true,
      },
    ]);
  });

  it("does not seed the offline showcase during bootstrap", () => {
    const { adapter } = createAdapter();

    adapter.bootstrap();

    expect(adapter.store.totalSolidBlocks()).toBe(0);
    expect(adapter.store.listChunks()).toHaveLength(0);
  });

  it("translates a known blueprint name into the expected prefab place intent", () => {
    const { adapter, transport } = createAdapter();

    const result = adapter.placePrefab("builtin_sphere", { x: 4, y: -2, z: 1 });

    expect(result).toEqual({ ok: true, placed: 248 });
    expect(transport.prefabCalls).toHaveLength(1);
    const [call] = transport.prefabCalls;
    if (!call) throw new Error("expected one prefab call");
    expect(call.blueprintId).toBe(1);
    expect(call.blueprintVersion).toBe(OnlinePrefabBlueprintVersion);
    // Anchor must be macro -> micro (multiply by VoxelConstants.MicroPerMacro = 8).
    expect(call.anchorWorldMicro).toEqual({ x: 32, y: -16, z: 8 });
    expect(call.rotation).toBe(0);
    expect(call.clientIntentSeq).toBe(1);
    expect(call.logicalSceneId).toBe(7);
    expect(call.parcelId).toBe(0);
    expect(call.knownParcelBuildEpoch).toBe(0);
  });

  it("ignores the rotation argument in v1 and pins rotation to 0", () => {
    const { adapter, transport } = createAdapter();

    adapter.placePrefab("builtin_cylinder", { x: 0, y: 0, z: 0 }, 2);

    const [call] = transport.prefabCalls;
    if (!call) throw new Error("expected one prefab call");
    expect(call.rotation).toBe(0);
    expect(call.blueprintId).toBe(2);
  });

  it("rejects unknown blueprint names without contacting the transport", () => {
    const { adapter, transport, bus } = createAdapter();
    const errorEvents: { reason: string; source: string }[] = [];
    bus.on("world:voxel-sync-error", (payload) => errorEvents.push(payload));

    const result = adapter.placePrefab("not_a_real_prefab", { x: 0, y: 0, z: 0 });

    expect(result).toEqual({ ok: false, placed: 0 });
    expect(transport.prefabCalls).toHaveLength(0);
    expect(errorEvents).toEqual([
      { reason: "unknown_blueprint:not_a_real_prefab", source: "prefab_place" },
    ]);
    expect(adapter.store.editStats.rejected).toBe(1);
  });

  it("returns ok: false when the transport refuses to send the intent", () => {
    const { adapter, transport } = createAdapter();
    transport.available = false;

    const result = adapter.placePrefab("builtin_stairs", { x: 0, y: 0, z: 0 });

    expect(result).toEqual({ ok: false, placed: 0 });
    expect(adapter.store.editStats.rejected).toBe(1);
  });

  it("emits world:voxel-prefab-result with accepted=true when the matching intent result arrives", () => {
    const { adapter, transport, bus } = createAdapter();
    const prefabResults: AppEvents["world:voxel-prefab-result"][] = [];
    bus.on("world:voxel-prefab-result", (payload) => prefabResults.push(payload));

    const requestIdBefore = transport.nextRequestId;
    adapter.placePrefab("builtin_stairs", { x: 1, y: 2, z: 3 });
    const requestId = requestIdBefore;

    const acceptedResult: VoxelIntentResultMessage = {
      type: "voxel_intent_result",
      requestId,
      clientIntentSeq: 1,
      logicalSceneId: 7,
      resultCode: 0,
      resultCodeName: "accepted",
      resultRef: 0,
      authoritative: [],
      reason: "ok",
    };

    transport.drainVoxelIntentResults = vi.fn(() => [acceptedResult]);
    adapter.onFrame(0);

    expect(prefabResults).toEqual([
      {
        blueprintId: 3,
        blueprintName: "builtin_stairs",
        requestId,
        accepted: true,
        reason: "ok",
      },
    ]);
  });

  it("emits world:voxel-prefab-result with accepted=false when the result is rejected", () => {
    const { adapter, transport, bus } = createAdapter();
    const prefabResults: AppEvents["world:voxel-prefab-result"][] = [];
    bus.on("world:voxel-prefab-result", (payload) => prefabResults.push(payload));

    const requestId = transport.nextRequestId;
    adapter.placePrefab("builtin_sphere", { x: 0, y: 0, z: 0 });

    const rejectedResult: VoxelIntentResultMessage = {
      type: "voxel_intent_result",
      requestId,
      clientIntentSeq: 1,
      logicalSceneId: 7,
      resultCode: 2,
      resultCodeName: "rejected",
      resultRef: 0,
      authoritative: [],
      reason: "blueprint_collision",
    };

    transport.drainVoxelIntentResults = vi.fn(() => [rejectedResult]);
    adapter.onFrame(0);

    expect(prefabResults).toHaveLength(1);
    const event = prefabResults[0];
    if (!event) throw new Error("expected prefab result");
    expect(event.accepted).toBe(false);
    expect(event.blueprintId).toBe(1);
    expect(event.reason).toBe("blueprint_collision");
  });
});

describe("OnlineVoxelWorldAdapter startup priming", () => {
  it("does not send a demo priming impact for empty snapshots unless explicitly enabled", () => {
    const transport = new FakeServerVoxelTransport();
    const bus = new EventBus<AppEvents>();
    const logger = new ObserveLog();
    const adapter = new OnlineVoxelWorldAdapter(transport, bus, logger, {
      logicalSceneId: 7,
      devSeed: false,
    });

    transport.queuedSnapshots.push(emptySnapshot({ x: 1, y: 0, z: 0 }));
    adapter.onFrame(100);

    expect(transport.impactCalls).toHaveLength(0);
  });

  it("keeps the demo priming fallback available when explicitly enabled", () => {
    const transport = new FakeServerVoxelTransport();
    const bus = new EventBus<AppEvents>();
    const logger = new ObserveLog();
    const adapter = new OnlineVoxelWorldAdapter(transport, bus, logger, {
      logicalSceneId: 7,
      devSeed: false,
      primeDemoBlock: true,
    });

    transport.queuedSnapshots.push(emptySnapshot({ x: 1, y: 0, z: 0 }));
    adapter.onFrame(100);

    expect(transport.impactCalls).toHaveLength(1);
    expect(transport.impactCalls[0]?.impactKind).toBe(1);
  });
});

describe("OnlineVoxelWorldAdapter#placePrefabBoundarySnap", () => {
  function seedSolidMacroAtOrigin(adapter: OnlineVoxelWorldAdapter): void {
    adapter.store.setNormalBlockWorld(
      { x: 0, y: 0, z: 0 },
      { materialId: 1, stateFlags: 0, health: 100, temperatureDelta: 0, moistureDelta: 0 },
    );
  }

  it("sends the wire intent with the boundary-snap micro anchor (not the macro origin)", () => {
    const { adapter, transport } = createAdapter();
    seedSolidMacroAtOrigin(adapter);

    const request = {
      prefabName: "builtin_sphere",
      hitMacro: { x: 0, y: 0, z: 0 },
      hitMicro: { x: 5, y: 7, z: 5 },
      anchorMicroCoord: { x: 5, y: 8, z: 5 },
      faceNormal: { x: 0, y: 1, z: 0 },
    };

    const preview = adapter.previewPrefabBoundarySnap(request);
    expect(preview.ok).toBe(true);
    expect(preview.anchorMicroCoord).not.toBeNull();

    const result = adapter.placePrefabBoundarySnap(request);
    expect(result.ok).toBe(true);
    expect(transport.prefabCalls).toHaveLength(1);

    const [call] = transport.prefabCalls;
    if (!call) throw new Error("expected one prefab call");
    expect(call.blueprintId).toBe(1);
    expect(call.blueprintVersion).toBe(OnlinePrefabBlueprintVersion);
    expect(call.anchorWorldMicro).toEqual(preview.anchorMicroCoord);
    // The boundary snap searches around the request anchor and shifts by the
    // best incoming boundary point, so at least one axis must come out
    // non-zero modulo 8 (otherwise it collapses to a macro origin and the
    // server-side placement diverges from the client wireframe).
    const anchor = call.anchorWorldMicro;
    expect(
      anchor.x % 8 !== 0 || anchor.y % 8 !== 0 || anchor.z % 8 !== 0,
    ).toBe(true);
  });

  it("returns the preview rejection when boundary snap finds no target", () => {
    const { adapter, transport } = createAdapter();
    // No seed: the world is empty, so previewBoundarySnap rejects with
    // no_target_boundary.
    const request = {
      prefabName: "builtin_sphere",
      hitMacro: { x: 0, y: 0, z: 0 },
      anchorMicroCoord: { x: 5, y: 8, z: 5 },
      faceNormal: { x: 0, y: 1, z: 0 },
    };

    const result = adapter.placePrefabBoundarySnap(request);
    expect(result.ok).toBe(false);
    expect(result.rejectReason).toBe("no_target_boundary");
    expect(transport.prefabCalls).toHaveLength(0);
  });
});

describe("OnlineVoxelWorldAdapter wire opcode coverage", () => {
  it("routes prefab placement through the 0x67 opcode constant the transport encodes", () => {
    // Defensive sanity check so accidental constant drift surfaces in this test
    // file rather than at the network boundary.
    expect(VoxelOpcode.PrefabPlaceIntent).toBe(0x67);
    expect(VoxelOpcode.VoxelIntentResult).toBe(0x68);
    expect(VoxelOpcode.VoxelEditIntent).toBe(0x70);
  });
});

describe("OnlineVoxelWorldAdapter#placeMicroBlock / #breakMicroBlock (Phase 1c-5)", () => {
  it("placeMicroBlock dispatches a typed VoxelEditIntent with action=Place + Micro granularity", () => {
    const { adapter, transport } = createAdapter();

    const ok = adapter.placeMicroBlock(
      { x: 1, y: 2, z: 3 },
      { x: 4, y: 5, z: 6 },
      { materialId: 17, stateFlags: 0, health: 0, temperatureDelta: 0, moistureDelta: 0 },
    );

    expect(ok).toBe(true);
    expect(transport.editIntentCalls).toHaveLength(1);
    const [call] = transport.editIntentCalls;
    if (!call) throw new Error("expected one edit intent call");
    expect(call.action).toBe(0); // Place
    expect(call.targetGranularity).toBe(1); // Micro
    // macro=(1,2,3) micro=(4,5,6) → world_micro=(1*8+4, 2*8+5, 3*8+6)=(12, 21, 30).
    expect(call.targetWorldMicro).toEqual({ x: 12, y: 21, z: 30 });
    expect(call.faceNormal).toEqual({ x: 0, y: 0, z: 0 });
    expect(call.materialId).toBe(17);
    expect(call.expectedChunkVersion).toBe(0xffff_ffff_ffff_ffffn);
    expect(call.expectedCellHash).toBe(0xffff_ffff);
    expect(call.clientIntentSeq).toBe(1);
  });

  it("breakMicroBlock dispatches a typed VoxelEditIntent with action=Break + Micro granularity", () => {
    const { adapter, transport } = createAdapter();

    const ok = adapter.breakMicroBlock({ x: 0, y: 0, z: 0 }, { x: 7, y: 0, z: 0 });

    expect(ok).toBe(true);
    expect(transport.editIntentCalls).toHaveLength(1);
    const [call] = transport.editIntentCalls;
    if (!call) throw new Error("expected one edit intent call");
    expect(call.action).toBe(1); // Break
    expect(call.targetGranularity).toBe(1); // Micro
    expect(call.targetWorldMicro).toEqual({ x: 7, y: 0, z: 0 });
    expect(call.materialId).toBe(0);
  });

  it("placeMicroBlock returns false and increments rejected stats when transport refuses", () => {
    const { adapter, transport } = createAdapter();
    transport.available = false;

    const ok = adapter.placeMicroBlock(
      { x: 0, y: 0, z: 0 },
      { x: 0, y: 0, z: 0 },
      { materialId: 1, stateFlags: 0, health: 0, temperatureDelta: 0, moistureDelta: 0 },
    );

    expect(ok).toBe(false);
    expect(transport.editIntentCalls).toHaveLength(0);
    expect(adapter.store.editStats.rejected).toBe(1);
  });
});

describe("OnlineVoxelWorldAdapter ObjectStateDelta pipeline (Phase 4-bis-10)", () => {
  function buildOsd(overrides: Partial<{
    logicalSceneId: bigint;
    objectId: bigint;
    objectVersion: bigint;
    stateFlags: number;
    affectedChunks: { x: number; y: number; z: number }[];
  }> = {}): VoxelObjectStateDeltaMessage {
    return {
      type: "voxel_object_state_delta",
      delta: {
        logicalSceneId: overrides.logicalSceneId ?? 7n,
        objectId: overrides.objectId ?? 100n,
        objectVersion: overrides.objectVersion ?? 1n,
        stateFlags: overrides.stateFlags ?? 0x02, // destroyed
        attributePatchCount: 0,
        tagPatchCount: 0,
        affectedChunks: overrides.affectedChunks ?? [{ x: 0, y: 0, z: 0 }],
      },
    };
  }

  it("cache hit → spawn debris with cleared_slot_cache source", () => {
    const { adapter, transport, bus } = createAdapter();
    const events: { source: string; spawned: number; flag: string }[] = [];
    bus.on("world:object-state-delta", (e) =>
      events.push({ source: e.debrisSource, spawned: e.debrisSpawned, flag: e.flagName }),
    );

    // Pre-populate cache with one slot for object 100.
    adapter
      .clearedSlotCacheForTest()
      .put(100n, { worldX: 12, worldY: 34, worldZ: 56, timestampMs: 0 });

    transport.queuedObjectStateDeltas.push(
      buildOsd({ stateFlags: 0x02 /* destroyed */ }),
    );

    adapter.onFrame(0);

    expect(events).toHaveLength(1);
    expect(events[0]!.source).toBe("cleared_slot_cache");
    expect(events[0]!.flag).toBe("destroyed");
    expect(events[0]!.spawned).toBeGreaterThan(0);
    expect(adapter.debrisSimulationForTest().activeCount()).toBeGreaterThan(0);
  });

  it("cache miss → 100ms retry → still empty → affected_chunks fallback", () => {
    const { adapter, transport, bus } = createAdapter();
    const events: { source: string; spawned: number }[] = [];
    bus.on("world:object-state-delta", (e) =>
      events.push({ source: e.debrisSource, spawned: e.debrisSpawned }),
    );

    transport.queuedObjectStateDeltas.push(
      buildOsd({ stateFlags: 0x02, affectedChunks: [{ x: 1, y: 0, z: 0 }] }),
    );

    // Frame 1: receives 0x6C, cache empty → enters retry queue.
    adapter.onFrame(0);
    expect(events).toHaveLength(0);

    // Frame 2: 50 ms later — still inside retry window.
    adapter.onFrame(50);
    expect(events).toHaveLength(0);

    // Frame 3: 120 ms later — past retry window, cache still empty → fallback.
    adapter.onFrame(120);

    expect(events).toHaveLength(1);
    expect(events[0]!.source).toBe("affected_chunks_fallback");
    expect(events[0]!.spawned).toBeGreaterThan(0);
  });

  it("cache miss → cache filled within 100ms window → delayed_retry hits", () => {
    const { adapter, transport, bus } = createAdapter();
    const events: { source: string }[] = [];
    bus.on("world:object-state-delta", (e) => events.push({ source: e.debrisSource }));

    transport.queuedObjectStateDeltas.push(
      buildOsd({ stateFlags: 0x04 /* part_destroyed */ }),
    );

    adapter.onFrame(0); // cache empty → retry queued

    // Within delay window, ChunkDelta hook would fill cache (simulated here):
    adapter
      .clearedSlotCacheForTest()
      .put(100n, { worldX: 7, worldY: 8, worldZ: 9, timestampMs: 50 });

    // Past 100 ms threshold — retry pulls from cache.
    adapter.onFrame(150);

    expect(events).toHaveLength(1);
    expect(events[0]!.source).toBe("delayed_retry");
  });

  it("unknown flag is dropped without spawning or queuing", () => {
    const { adapter, transport, bus } = createAdapter();
    const events: unknown[] = [];
    bus.on("world:object-state-delta", (e) => events.push(e));

    transport.queuedObjectStateDeltas.push(buildOsd({ stateFlags: 0x00 /* unknown */ }));
    adapter.onFrame(0);
    adapter.onFrame(200);

    expect(events).toHaveLength(0);
    expect(adapter.debrisSimulationForTest().activeCount()).toBe(0);
  });

  it("dedupes a stale-version 0x6C and does not spawn", () => {
    const { adapter, transport, bus } = createAdapter();
    const events: unknown[] = [];
    bus.on("world:object-state-delta", (e) => events.push(e));

    adapter
      .clearedSlotCacheForTest()
      .put(100n, { worldX: 0, worldY: 0, worldZ: 0, timestampMs: 0 });

    transport.queuedObjectStateDeltas.push(
      buildOsd({ objectVersion: 5n, stateFlags: 0x02 }),
    );
    adapter.onFrame(0);
    expect(events).toHaveLength(1);

    // Same object_version → dedupe path,no second emit.
    transport.queuedObjectStateDeltas.push(
      buildOsd({ objectVersion: 5n, stateFlags: 0x02 }),
    );
    adapter.onFrame(10);
    expect(events).toHaveLength(1);
  });

  it("debris simulation advances frame-by-frame and ages out", () => {
    const { adapter, transport } = createAdapter();
    adapter
      .clearedSlotCacheForTest()
      .put(100n, { worldX: 0, worldY: 0, worldZ: 0, timestampMs: 0 });

    transport.queuedObjectStateDeltas.push(buildOsd({ stateFlags: 0x02 }));
    adapter.onFrame(0);

    const initialCount = adapter.debrisSimulationForTest().activeCount();
    expect(initialCount).toBeGreaterThan(0);

    // Advance > particleLifetimeMs (default 800ms) → particles age out.
    adapter.onFrame(50);
    adapter.onFrame(900);

    expect(adapter.debrisSimulationForTest().activeCount()).toBeLessThan(initialCount);
  });
});
