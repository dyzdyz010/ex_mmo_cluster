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
} from "../infrastructure/net/voxelProtocol";
import { OnlineVoxelWorldAdapter, type ServerVoxelTransportPort } from "./onlineVoxelWorldAdapter";
import { OnlinePrefabBlueprintVersion } from "./onlinePrefabCatalog";

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

class FakeServerVoxelTransport implements ServerVoxelTransportPort {
  readonly prefabCalls: PrefabPlaceCall[] = [];
  readonly impactCalls: ImpactCall[] = [];
  readonly editIntentCalls: EditIntentCall[] = [];
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

  sendVoxelChunkSubscribe(): number | null {
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
    return [];
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

  private allocateRequestId(): number {
    const value = this.nextRequestId;
    this.nextRequestId += 1;
    return value;
  }
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
  it("does not seed the offline showcase during bootstrap", () => {
    const { adapter } = createAdapter();

    adapter.bootstrap();

    expect(adapter.store.totalSolidBlocks()).toBe(0);
    expect(adapter.store.listChunks()).toHaveLength(0);
  });

  it("translates a known blueprint name into the expected prefab place intent", () => {
    const { adapter, transport } = createAdapter();

    const result = adapter.placePrefab("builtin_pillar_3", { x: 4, y: -2, z: 1 });

    expect(result).toEqual({ ok: true, placed: 3 });
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

    adapter.placePrefab("builtin_floor_3x3", { x: 0, y: 0, z: 0 }, 2);

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

    const result = adapter.placePrefab("builtin_cube_2x2x2", { x: 0, y: 0, z: 0 });

    expect(result).toEqual({ ok: false, placed: 0 });
    expect(adapter.store.editStats.rejected).toBe(1);
  });

  it("emits world:voxel-prefab-result with accepted=true when the matching intent result arrives", () => {
    const { adapter, transport, bus } = createAdapter();
    const prefabResults: AppEvents["world:voxel-prefab-result"][] = [];
    bus.on("world:voxel-prefab-result", (payload) => prefabResults.push(payload));

    const requestIdBefore = transport.nextRequestId;
    adapter.placePrefab("builtin_cube_2x2x2", { x: 1, y: 2, z: 3 });
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
        blueprintName: "builtin_cube_2x2x2",
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
    adapter.placePrefab("builtin_pillar_3", { x: 0, y: 0, z: 0 });

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
