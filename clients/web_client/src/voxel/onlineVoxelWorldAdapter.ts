import type { AppEventBus, ElectricPowerDraw } from "../shared/events/events";
import { VoxelConstants } from "./core/constants";
import {
  chunkCoordKey,
  EVoxelRotation,
  type FChunkCoord,
  type FMacroCoord,
  type FMicroCoord,
} from "./core/types";
import {
  decodeNormalBlockDataPayload,
  VoxelChunkDeltaKind,
  type VoxelChunkDeltaMessage,
  type VoxelChunkInvalidateMessage,
  type VoxelChunkSnapshotMessage,
  type VoxelDebugProbeMessage,
  type VoxelFieldRegionDestroyedMessage,
  type VoxelFieldRegionSnapshotMessage,
  type VoxelIntentResultMessage,
  type VoxelKnownChunk,
  type VoxelObjectStateDeltaMessage,
  type VoxelPrefabKnownCellRef,
  type VoxelPrefabKnownObject,
  type VoxelPrefabKnownRef,
} from "../infrastructure/net/voxelProtocol";
import {
  ObjectStateDeltaConsumer,
  type ObjectStateFlagName,
} from "../infrastructure/net/objectStateDeltaConsumer";
import type { ObjectStateDelta } from "../infrastructure/net/objectStateDelta";
import { ClearedSlotCache } from "./clearedSlotCache";
import { DebrisSimulation, type DebrisSpawnPoint } from "./debrisEffect";
import { MacroWorldSize } from "./core/constants";

// Phase 4-bis Step 4-bis-10 timing / sampling constants.
const OBJECT_STATE_DELTA_RETRY_DELAY_MS = 100;
const MOVEMENT_PREWARM_RETRY_DELAY_MS = 750;
const MOVEMENT_PREWARM_FLUSH_INTERVAL_MS = 100;
const MOVEMENT_PREWARM_MAX_SUBSCRIPTIONS_PER_FLUSH = 1;
const MOVEMENT_PREWARM_MAX_QUEUE_ITEMS = 128;
const CHUNK_SUBSCRIPTION_PENDING_RETRY_DELAY_MS = 10_000;

type PendingChunkAck = {
  logicalSceneId: number;
  chunkCoord: FChunkCoord;
  chunkVersion: number;
  source: "snapshot" | "delta";
};

const DEBRIS_SAMPLE_LIMITS: Record<ObjectStateFlagName, number> = {
  destroyed: 20,
  part_destroyed: 10,
  damaged: 5,
  unknown: 0,
};

function sampleDebrisPoints(
  points: readonly DebrisSpawnPoint[],
  flagName: ObjectStateFlagName,
): DebrisSpawnPoint[] {
  const limit = DEBRIS_SAMPLE_LIMITS[flagName];
  if (limit <= 0 || points.length === 0) {
    return [];
  }
  if (points.length <= limit) {
    return points.slice();
  }
  // Even-stride downsampling — deterministic and cheap.
  const out: DebrisSpawnPoint[] = [];
  const stride = points.length / limit;
  for (let i = 0; i < limit; i++) {
    out.push(points[Math.floor(i * stride)]!);
  }
  return out;
}
import {
  EXPECTED_CELL_HASH_UNSPECIFIED,
  EXPECTED_CHUNK_VERSION_UNSPECIFIED,
  VoxelEditAction,
  VoxelEditTargetGranularity,
} from "../infrastructure/net/voxelEditIntent";
import { resolveBlueprint } from "./onlinePrefabCatalog";
import { macroCoordFromLinearIndex } from "./core/gridUtils";
import { wireToRefinedCell } from "./wireToRefinedCell";
import type { ObserveLog } from "../observe/logger";
import type { FNormalBlockData } from "./storage/types";
import type {
  LocalPrefab,
  PrefabBoundarySnapRequest,
  PrefabBoundarySnapResult,
  PrefabSocketSnapRequest,
  PrefabSocketSnapResult,
} from "./prefab";
import {
  LocalVoxelWorldAdapter,
  type ElectricConductionMode,
  type ElectricPowerSourceRequest,
} from "./worldAdapter";

export interface ServerVoxelTransportPort {
  canUseServerVoxel(): boolean;
  getAuthBaseUrl(): string;
  voxelDebugSnapshot(): Record<string, unknown>;
  sendVoxelDebugProbe(command?: string): number | null;
  sendVoxelChunkSubscribe(request: {
    logicalSceneId: number;
    centerChunk: FChunkCoord;
    radiusLInf?: number;
    wantSnapshot?: boolean;
    known?: readonly VoxelKnownChunk[];
  }): number | null;
  sendVoxelChunkUnsubscribe(request: {
    logicalSceneId: number;
    chunks: readonly FChunkCoord[];
  }): number | null;
  sendVoxelChunkAck(request: {
    logicalSceneId: number;
    acks: readonly VoxelKnownChunk[];
  }): number | null;
  sendVoxelImpactIntent(request: {
    logicalSceneId: number;
    sourceSkillId: number;
    targetWorldMicro: FMacroCoord;
    impactKind: number;
    clientIntentSeq: number;
    clientHintHash?: number;
  }): number | null;
  sendVoxelEditIntent(request: {
    logicalSceneId: number;
    action: number;
    targetGranularity: number;
    targetWorldMicro: FMacroCoord;
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
  }): number | null;
  sendVoxelFieldConductIntent?(request: {
    logicalSceneId: number;
    sourceWorldMacro: FMacroCoord;
    targetWorldMacro: FMacroCoord;
    sourcePotential: number;
    maxTicks: number;
    conductionMode?: ElectricConductionMode;
    outputMode?: ElectricPowerSourceRequest["outputMode"];
    voltage?: number;
    currentLimitAmps?: number;
    frequencyHz?: number;
    loadCurrentAmps?: number;
    energyBudgetJoules?: number;
    clientIntentSeq: number;
  }): number | null;
  sendVoxelPrefabPlaceIntent(request: {
    logicalSceneId: number;
    parcelId: number;
    knownParcelBuildEpoch: number;
    blueprintId: number;
    blueprintVersion: number;
    anchorWorldMicro: FMacroCoord;
    rotation: number;
    clientIntentSeq: number;
    knownRefs?: readonly VoxelPrefabKnownRef[];
    knownObjects?: readonly VoxelPrefabKnownObject[];
    knownCellRefs?: readonly VoxelPrefabKnownCellRef[];
    placementFlags?: number;
  }): number | null;
  drainVoxelSnapshots(): VoxelChunkSnapshotMessage[];
  drainVoxelDeltas(): VoxelChunkDeltaMessage[];
  drainVoxelInvalidates(): VoxelChunkInvalidateMessage[];
  drainVoxelIntentResults(): VoxelIntentResultMessage[];
  drainVoxelDebugProbes(): VoxelDebugProbeMessage[];
  drainVoxelObjectStateDeltas(): VoxelObjectStateDeltaMessage[];
  drainVoxelFieldSnapshots(): VoxelFieldRegionSnapshotMessage[];
  drainVoxelFieldDestroyeds(): VoxelFieldRegionDestroyedMessage[];
}

export interface OnlineVoxelWorldOptions {
  logicalSceneId?: number;
  defaultCenterChunk?: FChunkCoord;
  defaultRadiusLInf?: number;
  initialSubscriptions?: readonly { centerChunk: FChunkCoord; radiusLInf?: number }[];
  devSeed?: boolean;
  primeDemoBlock?: boolean;
  sourceSkillId?: number;
}

type SeedState = "disabled" | "idle" | "pending" | "ready" | "failed";
type SubscriptionState = "idle" | "requested" | "active";

export class OnlineVoxelWorldAdapter extends LocalVoxelWorldAdapter {
  override readonly mode = "server-authoritative";
  private readonly logicalSceneId: number;
  private readonly defaultCenterChunk: FChunkCoord;
  private readonly defaultRadiusLInf: number;
  private readonly initialSubscriptions: readonly {
    centerChunk: FChunkCoord;
    radiusLInf: number;
  }[];
  private readonly devSeed: boolean;
  private readonly primeDemoBlock: boolean;
  private readonly sourceSkillId: number;
  private seedState: SeedState;
  private subscriptionState: SubscriptionState = "idle";
  private subscriptionRequestId: number | null = null;
  private pendingIntentCount = 0;
  private clientIntentSeq = 1;
  private readonly pendingPrefabIntents = new Map<
    number,
    { blueprintId: number; blueprintName: string; sentAtMs: number }
  >();
  private lastSeedAttemptMs = 0;
  private lastSeedDurationMs: number | null = null;
  private lastSeedSummary: Record<string, unknown> | null = null;
  private lastSnapshot: {
    requestId: number;
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    chunkVersion: number;
    chunkHash: number;
    solidBlocks: number;
  } | null = null;
  private lastIntentResult: {
    requestId: number;
    clientIntentSeq: number;
    logicalSceneId: number;
    resultCodeName: string;
    resultRef: number;
    reason: string;
  } | null = null;
  private lastDebugProbe: string | null = null;
  private lastError: string | null = null;
  private initialSubscriptionsSent = false;
  private primeSent = false;
  private readonly movementPrewarmRequests = new Map<
    string,
    { coord: FChunkCoord; requestId: number; sentAtMs: number; source: string }
  >();
  private readonly pendingMovementPrewarmQueue = new Map<
    string,
    { coord: FChunkCoord; queuedAtMs: number; source: string }
  >();
  private lastMovementPrewarmFlushMs = -MOVEMENT_PREWARM_FLUSH_INTERVAL_MS;
  private readonly pendingChunkSubscriptions = new Map<
    string,
    { coord: FChunkCoord; requestId: number; sentAtMs: number; source: string }
  >();
  private lastMovementPrewarm: {
    requestId: number;
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    source: string;
  } | null = null;
  private appliedChunkAckCount = 0;
  private lastAppliedChunkAck: {
    requestId: number;
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    chunkVersion: number;
    source: "snapshot" | "delta";
  } | null = null;
  private readonly pendingChunkAcks = new Map<string, PendingChunkAck>();
  // Phase 4-bis 0x6C ObjectStateDelta processing.
  private readonly objectStateDeltaConsumer: ObjectStateDeltaConsumer;
  private readonly clearedSlotCache: ClearedSlotCache;
  private readonly debrisSimulation: DebrisSimulation;
  private readonly objectStateDeltaRetryQueue: {
    delta: ObjectStateDelta;
    flagName: ObjectStateFlagName;
    retryAtMs: number;
  }[] = [];
  private receivedObjectStateDeltaCount = 0;
  private dedupedObjectStateDeltaCount = 0;
  private lastObjectStateFrameMs: number | null = null;
  private readonly fieldSnapshots: VoxelFieldRegionSnapshotMessage[] = [];
  private readonly fieldDestroyeds: VoxelFieldRegionDestroyedMessage[] = [];

  constructor(
    private readonly transport: ServerVoxelTransportPort,
    private readonly bus: AppEventBus,
    private readonly logger: ObserveLog,
    options: OnlineVoxelWorldOptions = {},
  ) {
    super();
    this.logicalSceneId = options.logicalSceneId ?? 1;
    this.defaultCenterChunk = options.defaultCenterChunk ?? { x: 0, y: 0, z: 0 };
    this.defaultRadiusLInf = options.defaultRadiusLInf ?? 0;
    this.initialSubscriptions = normalizeInitialSubscriptions(
      options.initialSubscriptions ?? [
        { centerChunk: this.defaultCenterChunk, radiusLInf: this.defaultRadiusLInf },
      ],
    );
    this.devSeed = options.devSeed ?? true;
    this.primeDemoBlock = options.primeDemoBlock ?? false;
    this.sourceSkillId = options.sourceSkillId ?? 1;
    this.seedState = this.devSeed ? "idle" : "disabled";

    this.clearedSlotCache = new ClearedSlotCache();
    this.debrisSimulation = new DebrisSimulation();

    this.objectStateDeltaConsumer = new ObjectStateDeltaConsumer({
      onDelta: (delta, flagName) => {
        this.logger.emit("voxel", "object_state_delta_consumed", {
          flag_name: flagName,
          object_id: delta.objectId.toString(),
          object_version: delta.objectVersion.toString(),
          state_flags: `0x${delta.stateFlags.toString(16)}`,
          affected_chunks: delta.affectedChunks.length,
        });
        this.handleObjectStateDeltaForDebris(delta, flagName);
      },
      onDuplicate: (delta) => {
        this.dedupedObjectStateDeltaCount += 1;
        this.logger.emit("voxel", "object_state_delta_deduped", {
          object_id: delta.objectId.toString(),
          object_version: delta.objectVersion.toString(),
        });
      },
    });
  }

  override bootstrap(): void {
    // Server-authoritative mode must start empty locally. Authoritative
    // terrain arrives from server snapshots; seeding the offline showcase here
    // would make CLI/render observations mix local-only and server-owned cells.
  }

  onFrame(nowMs: number): void {
    // Update lastObjectStateFrameMs first so handleObjectStateDeltaForDebris
    // (called from drainVoxelMessages) can timestamp retry-queue entries
    // against the *current* frame instead of falling back to performance.now().
    this.tickDebris(nowMs);
    this.drainVoxelMessages();
    this.processObjectStateDeltaRetryQueue(nowMs);

    if (!this.transport.canUseServerVoxel()) {
      return;
    }

    if (this.seedState === "disabled") {
      this.seedState = "ready";
    }
    if (this.seedState === "idle" || this.shouldRetrySeed(nowMs)) {
      this.ensureDevSeed(nowMs);
    }
    if (this.subscriptionState === "idle") {
      this.subscribeInitialChunks();
    }
    this.flushMovementPrewarmQueue(nowMs);
  }

  flushServerMessagesForCli(): void {
    this.drainVoxelMessages();
  }

  override debugSnapshot(): Record<string, unknown> {
    return {
      ...super.debugSnapshot(),
      mode: this.mode,
      logicalSceneId: this.logicalSceneId,
      defaultCenterChunk: chunkCoordKey(this.defaultCenterChunk),
      defaultRadiusLInf: this.defaultRadiusLInf,
      initialSubscriptions: this.initialSubscriptions.map((subscription) => ({
        centerChunk: chunkCoordKey(subscription.centerChunk),
        radiusLInf: subscription.radiusLInf,
      })),
      seedState: this.seedState,
      subscriptionState: this.subscriptionState,
      subscriptionRequestId: this.subscriptionRequestId,
      pendingIntentCount: this.pendingIntentCount,
      pendingPrefabIntentCount: this.pendingPrefabIntents.size,
      clientIntentSeqNext: this.clientIntentSeq,
      // Phase 1c-5: surface refined-cell counts so the HUD can confirm that
      // micro edits actually landed (CellRefined deltas write here).
      totalSolidBlocks: this.store.totalSolidBlocks(),
      totalRefinedCells: this.store.totalRefinedCells(),
      lastSnapshot: this.lastSnapshot
        ? {
            ...this.lastSnapshot,
            chunkCoord: chunkCoordKey(this.lastSnapshot.chunkCoord),
          }
        : null,
      lastIntentResult: this.lastIntentResult,
      lastDebugProbe: this.lastDebugProbe,
      lastError: this.lastError,
      movementPrewarm: {
        pendingCount: this.movementPrewarmRequests.size,
        pendingChunks: [...this.movementPrewarmRequests.values()].map((request) =>
          chunkCoordKey(request.coord),
        ),
        queuedCount: this.pendingMovementPrewarmQueue.size,
        queuedChunks: [...this.pendingMovementPrewarmQueue.values()].map((request) =>
          chunkCoordKey(request.coord),
        ),
        pendingSubscriptionCount: this.pendingChunkSubscriptions.size,
        pendingSubscriptionChunks: [...this.pendingChunkSubscriptions.values()].map((request) =>
          chunkCoordKey(request.coord),
        ),
        last: this.lastMovementPrewarm
          ? {
              ...this.lastMovementPrewarm,
              chunkCoord: chunkCoordKey(this.lastMovementPrewarm.chunkCoord),
            }
          : null,
      },
      appliedChunkAckCount: this.appliedChunkAckCount,
      lastAppliedChunkAck: this.lastAppliedChunkAck
        ? {
            ...this.lastAppliedChunkAck,
            chunkCoord: chunkCoordKey(this.lastAppliedChunkAck.chunkCoord),
          }
        : null,
      lastSeedDurationMs: this.lastSeedDurationMs,
      lastSeedSummary: this.lastSeedSummary,
      objectStateDeltas: {
        received: this.receivedObjectStateDeltaCount,
        deduped: this.dedupedObjectStateDeltaCount,
      },
      transport: this.transport.voxelDebugSnapshot(),
    };
  }

  override placeBlock(coord: FMacroCoord, block: FNormalBlockData): boolean {
    const requestId = this.sendVoxelImpactMacro(coord, block.materialId);
    if (requestId === null) {
      this.store.editStats.rejected += 1;
      return false;
    }
    return true;
  }

  override breakBlock(coord: FMacroCoord): boolean {
    // Wire convention: impactKind === 0 is the break sentinel. The server
    // gate translates that to a `:break_block` operation that clears the
    // macro cell to empty mode and emits a delta_kind = 0 (CellEmpty)
    // ChunkDelta. Local state is server-authoritative — the change only
    // takes effect when that delta arrives back via applyDelta.
    const requestId = this.sendVoxelImpactMacro(coord, 0);
    if (requestId === null) {
      this.store.editStats.rejected += 1;
      return false;
    }
    return true;
  }

  override placeMicroBlock(
    macro: FMacroCoord,
    micro: FMicroCoord,
    block: FNormalBlockData,
  ): boolean {
    const requestId = this.sendVoxelEditMicro({
      action: VoxelEditAction.Place,
      macro,
      micro,
      materialId: block.materialId,
    });
    if (requestId === null) {
      this.store.editStats.rejected += 1;
      return false;
    }
    return true;
  }

  override breakMicroBlock(macro: FMacroCoord, micro: FMicroCoord): boolean {
    const requestId = this.sendVoxelEditMicro({
      action: VoxelEditAction.Break,
      macro,
      micro,
      materialId: 0,
    });
    if (requestId === null) {
      this.store.editStats.rejected += 1;
      return false;
    }
    return true;
  }

  // Convert macro+micro coordinates into a world-micro target and dispatch a
  // typed VoxelEditIntent (0x70). Phase 1c-5 keeps `face_normal = (0,0,0)`
  // because the caller has already resolved the targeted slot — the server
  // will treat the literal world-micro as the cell to mutate (decision 6).
  private sendVoxelEditMicro(request: {
    action: number;
    macro: FMacroCoord;
    micro: FMicroCoord;
    materialId: number;
  }): number | null {
    const targetWorldMicro = {
      x: request.macro.x * VoxelConstants.MicroPerMacro + request.micro.x,
      y: request.macro.y * VoxelConstants.MicroPerMacro + request.micro.y,
      z: request.macro.z * VoxelConstants.MicroPerMacro + request.micro.z,
    };
    const clientIntentSeq = this.clientIntentSeq;
    const requestId = this.transport.sendVoxelEditIntent({
      logicalSceneId: this.logicalSceneId,
      action: request.action,
      targetGranularity: VoxelEditTargetGranularity.Micro,
      targetWorldMicro,
      faceNormal: { x: 0, y: 0, z: 0 },
      materialId: request.materialId,
      expectedChunkVersion: EXPECTED_CHUNK_VERSION_UNSPECIFIED,
      expectedCellHash: EXPECTED_CELL_HASH_UNSPECIFIED,
      clientIntentSeq,
    });
    if (requestId === null) {
      this.lastError = "voxel_transport_unavailable";
      return null;
    }
    this.clientIntentSeq += 1;
    this.pendingIntentCount += 1;
    return requestId;
  }

  override placePrefab(
    name: string,
    origin: FMacroCoord,
    rotation: EVoxelRotation = EVoxelRotation.Rot0,
  ): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean } {
    const blueprint = resolveBlueprint(name);
    if (!blueprint) {
      const reason = `unknown_blueprint:${name}`;
      this.rejectServerOnlyEdit(reason);
      this.bus.emit("world:voxel-sync-error", { reason, source: "prefab_place" });
      return { ok: false, placed: 0 };
    }

    const submitted = this.submitPrefabPlaceIntent(
      name,
      blueprint,
      {
        x: origin.x * VoxelConstants.MicroPerMacro,
        y: origin.y * VoxelConstants.MicroPerMacro,
        z: origin.z * VoxelConstants.MicroPerMacro,
      },
      rotation,
    );

    if (!submitted) {
      this.rejectServerOnlyEdit("voxel_transport_unavailable");
      return { ok: false, placed: 0 };
    }

    return { ok: true, placed: blueprint.expectedCellCount };
  }

  override placePrefabSocketSnap(_request: PrefabSocketSnapRequest): PrefabSocketSnapResult {
    this.rejectServerOnlyEdit("prefab_socket_snap_not_supported_by_server");
    return { ok: false, placed: 0, rejectReason: "server_authority_not_supported" };
  }

  // Boundary snap is split into two authority layers:
  //   1. the browser computes an ergonomic anchor proposal from the aimed face
  //      and the local subscribed voxel truth;
  //   2. the server owns the final result by re-rasterizing that blueprint +
  //      anchor through 0x67 and committing it with the chunk transaction path.
  override placePrefabBoundarySnap(request: PrefabBoundarySnapRequest): PrefabBoundarySnapResult {
    const preview = this.previewPrefabBoundarySnap(request);

    if (!preview.ok || !preview.anchorMicroCoord) {
      return {
        ok: false,
        placed: 0,
        conflict: preview.overlapSlots > 0,
        rejectReason: preview.rejectReason ?? "prefab_boundary_snap_rejected",
        preview,
      };
    }

    const blueprint = resolveBlueprint(request.prefabName);
    if (!blueprint) {
      const reason = `unknown_blueprint:${request.prefabName}`;
      this.rejectServerOnlyEdit(reason);
      this.bus.emit("world:voxel-sync-error", { reason, source: "prefab_place_snap" });
      return {
        ok: false,
        placed: 0,
        rejectReason: reason,
        preview,
      };
    }

    const submitted = this.submitPrefabPlaceIntent(
      request.prefabName,
      blueprint,
      preview.anchorMicroCoord,
      request.rotation ?? EVoxelRotation.Rot0,
    );

    if (submitted) {
      return {
        ok: true,
        placed: preview.incomingOccupiedSlots,
        instanceId: 0,
        preview,
      };
    }

    this.rejectServerOnlyEdit("voxel_transport_unavailable");
    return {
      ok: false,
      placed: 0,
      rejectReason: "voxel_transport_unavailable",
      preview,
    };
  }

  private submitPrefabPlaceIntent(
    blueprintName: string,
    blueprint: { id: number; version: number },
    anchorWorldMicro: FMacroCoord,
    rotation: EVoxelRotation = EVoxelRotation.Rot0,
  ): boolean {
    const clientIntentSeq = this.clientIntentSeq;
    const requestId = this.transport.sendVoxelPrefabPlaceIntent({
      logicalSceneId: this.logicalSceneId,
      parcelId: 0,
      knownParcelBuildEpoch: 0,
      blueprintId: blueprint.id,
      blueprintVersion: blueprint.version,
      anchorWorldMicro,
      rotation,
      clientIntentSeq,
    });

    if (requestId === null) {
      return false;
    }

    this.clientIntentSeq += 1;
    this.pendingIntentCount += 1;
    this.pendingPrefabIntents.set(requestId, {
      blueprintId: blueprint.id,
      blueprintName,
      sentAtMs: performance.now(),
    });
    return true;
  }

  override importSnapshot(
    _snapshot: Parameters<LocalVoxelWorldAdapter["importSnapshot"]>[0],
  ): void {
    this.lastError = "world_import_disabled_in_server_authority_mode";
  }

  requestVoxelDebugProbe(command: string = "voxel_transport"): number | null {
    return this.transport.sendVoxelDebugProbe(command);
  }

  subscribeVoxelChunk(
    centerChunk: FChunkCoord,
    radiusLInf: number = 0,
    source = "manual",
  ): number | null {
    const requestId = this.transport.sendVoxelChunkSubscribe({
      logicalSceneId: this.logicalSceneId,
      centerChunk,
      radiusLInf,
      wantSnapshot: true,
      known: this.knownChunkVersions(),
    });
    if (requestId !== null) {
      this.trackPendingChunkSubscription(
        centerChunk,
        radiusLInf,
        requestId,
        Math.round(performance.now()),
        source,
      );
      this.subscriptionState = "requested";
      this.subscriptionRequestId = requestId;
      this.bus.emit("world:chunk-subscribed", {
        requestId,
        logicalSceneId: this.logicalSceneId,
        centerChunk,
        radiusLInf,
      });
    }
    return requestId;
  }

  prewarmAuthoritativeChunks(
    chunks: readonly FChunkCoord[],
    source = "movement_collision",
  ): number {
    if (chunks.length === 0 || !this.transport.canUseServerVoxel()) {
      return 0;
    }

    const nowMs = Math.round(performance.now());
    const seen = new Set<string>();
    let queued = 0;

    for (const chunk of chunks) {
      const chunkCoord = { ...chunk };
      const key = chunkCoordKey(chunkCoord);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);

      if (this.store.getChunkAuthorityMetadata(chunkCoord)) {
        this.clearPendingChunkRequest(chunkCoord);
        continue;
      }

      if (this.hasActivePendingChunkSubscription(chunkCoord, nowMs)) {
        continue;
      }

      const pending = this.movementPrewarmRequests.get(key);
      if (pending && nowMs - pending.sentAtMs < MOVEMENT_PREWARM_RETRY_DELAY_MS) {
        continue;
      }

      if (this.pendingMovementPrewarmQueue.has(key)) {
        continue;
      }

      this.enqueueMovementPrewarm(chunkCoord, nowMs, source);
      queued += 1;
    }

    return queued;
  }

  private enqueueMovementPrewarm(chunkCoord: FChunkCoord, queuedAtMs: number, source: string): void {
    const key = chunkCoordKey(chunkCoord);

    if (this.pendingMovementPrewarmQueue.size >= MOVEMENT_PREWARM_MAX_QUEUE_ITEMS) {
      const oldestKey = this.pendingMovementPrewarmQueue.keys().next().value as string | undefined;
      if (oldestKey !== undefined) {
        this.pendingMovementPrewarmQueue.delete(oldestKey);
        this.logger.emit("voxel", "movement_prewarm_queue_pruned", {
          dropped_chunk: oldestKey,
          queued_count: this.pendingMovementPrewarmQueue.size,
        });
      }
    }

    const request = {
      coord: { ...chunkCoord },
      queuedAtMs,
      source,
    };

    if (source === "collision_query") {
      this.pendingMovementPrewarmQueue.delete(key);
      const prioritizedQueue = new Map([
        [key, request],
        ...this.pendingMovementPrewarmQueue,
      ]);
      this.pendingMovementPrewarmQueue.clear();
      for (const [queuedKey, queuedRequest] of prioritizedQueue) {
        this.pendingMovementPrewarmQueue.set(queuedKey, queuedRequest);
      }
      return;
    }

    this.pendingMovementPrewarmQueue.set(key, request);
  }

  private flushMovementPrewarmQueue(nowMs: number): void {
    if (this.pendingMovementPrewarmQueue.size === 0) {
      return;
    }
    const hasCollisionQuery = [...this.pendingMovementPrewarmQueue.values()].some(
      (queued) => queued.source === "collision_query",
    );
    if (
      !hasCollisionQuery &&
      nowMs - this.lastMovementPrewarmFlushMs < MOVEMENT_PREWARM_FLUSH_INTERVAL_MS
    ) {
      return;
    }

    this.lastMovementPrewarmFlushMs = nowMs;
    let sent = 0;

    for (const [key, queued] of this.pendingMovementPrewarmQueue) {
      if (sent >= MOVEMENT_PREWARM_MAX_SUBSCRIPTIONS_PER_FLUSH) {
        break;
      }

      const chunkCoord = { ...queued.coord };

      if (this.store.getChunkAuthorityMetadata(chunkCoord)) {
        this.clearPendingChunkRequest(chunkCoord);
        continue;
      }

      if (this.hasActivePendingChunkSubscription(chunkCoord, nowMs)) {
        this.pendingMovementPrewarmQueue.delete(key);
        continue;
      }

      const pending = this.movementPrewarmRequests.get(key);
      if (pending && nowMs - pending.sentAtMs < MOVEMENT_PREWARM_RETRY_DELAY_MS) {
        this.pendingMovementPrewarmQueue.delete(key);
        continue;
      }

      const requestId = this.subscribeVoxelChunk(chunkCoord, 0, queued.source);
      if (requestId === null) {
        return;
      }

      this.pendingMovementPrewarmQueue.delete(key);
      this.movementPrewarmRequests.set(key, {
        coord: chunkCoord,
        requestId,
        sentAtMs: nowMs,
        source: queued.source,
      });
      this.lastMovementPrewarm = {
        requestId,
        logicalSceneId: this.logicalSceneId,
        chunkCoord,
        source: queued.source,
      };
      this.bus.emit("world:chunk-prewarm-requested", {
        requestId,
        logicalSceneId: this.logicalSceneId,
        chunkCoord,
        source: queued.source,
      });
      sent += 1;
    }
  }

  unsubscribeVoxelChunk(chunk: FChunkCoord): number | null {
    return this.transport.sendVoxelChunkUnsubscribe({
      logicalSceneId: this.logicalSceneId,
      chunks: [chunk],
    });
  }

  sendVoxelImpactMacro(coord: FMacroCoord, materialId: number): number | null {
    const clientIntentSeq = this.clientIntentSeq;
    const requestId = this.transport.sendVoxelImpactIntent({
      logicalSceneId: this.logicalSceneId,
      sourceSkillId: this.sourceSkillId,
      targetWorldMicro: {
        x: coord.x * VoxelConstants.MicroPerMacro,
        y: coord.y * VoxelConstants.MicroPerMacro,
        z: coord.z * VoxelConstants.MicroPerMacro,
      },
      impactKind: materialId,
      clientIntentSeq,
      clientHintHash: 0,
    });
    if (requestId === null) {
      this.lastError = "voxel_transport_unavailable";
      return null;
    }

    this.clientIntentSeq += 1;
    this.pendingIntentCount += 1;
    return requestId;
  }

  override capturePrefab(name: string, min: FMacroCoord, max: FMacroCoord): LocalPrefab {
    return super.capturePrefab(name, min, max);
  }

  private drainVoxelMessages(): void {
    for (const snapshot of this.transport.drainVoxelSnapshots()) {
      this.applySnapshot(snapshot);
    }
    for (const delta of this.transport.drainVoxelDeltas()) {
      this.applyDelta(delta);
    }
    for (const invalidate of this.transport.drainVoxelInvalidates()) {
      this.applyInvalidate(invalidate);
    }
    for (const result of this.transport.drainVoxelIntentResults()) {
      this.applyIntentResult(result);
    }
    for (const probe of this.transport.drainVoxelDebugProbes()) {
      this.lastDebugProbe = probe.result;
    }
    for (const message of this.transport.drainVoxelObjectStateDeltas()) {
      this.applyObjectStateDelta(message);
    }
    for (const msg of this.transport.drainVoxelFieldSnapshots()) {
      this.fieldSnapshots.push(msg);
    }
    for (const msg of this.transport.drainVoxelFieldDestroyeds()) {
      this.fieldDestroyeds.push(msg);
    }
    this.flushPendingChunkAcks();
  }

  drainVoxelFieldSnapshots(): VoxelFieldRegionSnapshotMessage[] {
    return this.fieldSnapshots.splice(0, this.fieldSnapshots.length);
  }

  drainVoxelFieldDestroyeds(): VoxelFieldRegionDestroyedMessage[] {
    return this.fieldDestroyeds.splice(0, this.fieldDestroyeds.length);
  }

  requestDevHeatVoxel(coord: FMacroCoord, targetTemperatureCelsius = 800, maxTicks = 600): boolean {
    return this.requestSetVoxelTemperature(coord, targetTemperatureCelsius, maxTicks);
  }

  requestSetVoxelTemperature(
    coord: FMacroCoord,
    targetTemperatureCelsius = 800,
    maxTicks = 600,
  ): boolean {
    const url = `${this.transport.getAuthBaseUrl()}/ingame/voxel/set_temperature`;
    void fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        logical_scene_id: this.logicalSceneId,
        x: coord.x,
        y: coord.y,
        z: coord.z,
        target_temperature_celsius: targetTemperatureCelsius,
        max_ticks: maxTicks,
      }),
    })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`set_temperature_failed:${response.status}`);
        }
        return response.json() as Promise<Record<string, unknown>>;
      })
      .then((payload) => {
        this.logger.emit("voxel", "set_temperature_ok", {
          logical_scene_id: this.logicalSceneId,
          coord: `${coord.x},${coord.y},${coord.z}`,
          target_temperature_celsius: targetTemperatureCelsius,
          heat_energy_joules: String(
            (payload["attribute_write"] as Record<string, unknown> | undefined)?.[
              "heat_energy_joules"
            ] ?? "unknown",
          ),
          region_id: String(payload["region_id"] ?? "none"),
          created: String(payload["created"] ?? "unknown"),
          max_ticks: maxTicks,
        });
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : String(error);
        this.lastError = reason;
        this.bus.emit("world:voxel-sync-error", { reason, source: "set_temperature" });
      });
    return true;
  }

  requestVoxelConductionPath(
    source: FMacroCoord,
    target: FMacroCoord,
    sourcePotential = 120,
    maxTicks = 120,
    powerSource?: ElectricPowerSourceRequest,
  ): boolean {
    if (powerSource?.conductionMode === "discharge") {
      return this.requestVoxelFieldConductionIntent(
        source,
        target,
        sourcePotential,
        maxTicks,
        powerSource,
      );
    }

    return this.requestVoxelConductionPathViaHttp(
      source,
      target,
      sourcePotential,
      maxTicks,
      powerSource,
    );
  }

  private requestVoxelFieldConductionIntent(
    source: FMacroCoord,
    target: FMacroCoord,
    sourcePotential: number,
    maxTicks: number,
    powerSource: ElectricPowerSourceRequest,
  ): boolean {
    const send = this.transport.sendVoxelFieldConductIntent?.bind(this.transport);
    if (typeof send !== "function") {
      return this.requestVoxelConductionPathViaHttp(
        source,
        target,
        sourcePotential,
        maxTicks,
        powerSource,
      );
    }

    const clientIntentSeq = this.clientIntentSeq;
    const fieldRequest: Parameters<
      NonNullable<ServerVoxelTransportPort["sendVoxelFieldConductIntent"]>
    >[0] = {
      logicalSceneId: this.logicalSceneId,
      sourceWorldMacro: source,
      targetWorldMacro: target,
      sourcePotential,
      maxTicks,
      conductionMode: powerSource.conductionMode ?? "discharge",
      clientIntentSeq,
    };
    if (powerSource.outputMode !== undefined) {
      fieldRequest.outputMode = powerSource.outputMode;
    }
    if (powerSource.voltage !== undefined) {
      fieldRequest.voltage = powerSource.voltage;
    }
    if (powerSource.currentLimitAmps !== undefined) {
      fieldRequest.currentLimitAmps = powerSource.currentLimitAmps;
    }
    if (powerSource.frequencyHz !== undefined) {
      fieldRequest.frequencyHz = powerSource.frequencyHz;
    }
    if (powerSource.loadCurrentAmps !== undefined) {
      fieldRequest.loadCurrentAmps = powerSource.loadCurrentAmps;
    }
    if (powerSource.energyBudgetJoules !== undefined) {
      fieldRequest.energyBudgetJoules = powerSource.energyBudgetJoules;
    }

    const requestId = send(fieldRequest);
    if (requestId === null) {
      this.lastError = "voxel_transport_unavailable";
      this.bus.emit("world:voxel-sync-error", {
        reason: this.lastError,
        source: "field_conduct_intent",
      });
      return false;
    }
    this.clientIntentSeq += 1;
    this.pendingIntentCount += 1;
    this.logger.emit("voxel", "field_conduct_intent_submitted", {
      request_id: requestId,
      client_intent_seq: clientIntentSeq,
      logical_scene_id: this.logicalSceneId,
      source_coord: `${source.x},${source.y},${source.z}`,
      target_coord: `${target.x},${target.y},${target.z}`,
      source_potential: sourcePotential,
      conduction_mode: powerSource.conductionMode ?? "conductive",
      max_ticks: maxTicks,
    });
    return true;
  }

  private requestVoxelConductionPathViaHttp(
    source: FMacroCoord,
    target: FMacroCoord,
    sourcePotential: number,
    maxTicks: number,
    powerSource?: ElectricPowerSourceRequest,
  ): boolean {
    const url = `${this.transport.getAuthBaseUrl()}/ingame/voxel/conduct`;
    void fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        logical_scene_id: this.logicalSceneId,
        source_x: source.x,
        source_y: source.y,
        source_z: source.z,
        target_x: target.x,
        target_y: target.y,
        target_z: target.z,
        source_potential: sourcePotential,
        max_ticks: maxTicks,
        ...(powerSource?.conductionMode ? { conduction_mode: powerSource.conductionMode } : {}),
        ...(powerSource?.outputMode ? { output_mode: powerSource.outputMode } : {}),
        ...(powerSource?.voltage !== undefined ? { voltage: powerSource.voltage } : {}),
        ...(powerSource?.currentLimitAmps !== undefined
          ? { current_limit_amps: powerSource.currentLimitAmps }
          : {}),
        ...(powerSource?.frequencyHz !== undefined
          ? { frequency_hz: powerSource.frequencyHz }
          : {}),
        ...(powerSource?.loadCurrentAmps !== undefined
          ? { load_current_amps: powerSource.loadCurrentAmps }
          : {}),
        ...(powerSource?.energyBudgetJoules !== undefined
          ? { energy_budget_joules: powerSource.energyBudgetJoules }
          : {}),
      }),
    })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(await responseErrorReason(response, "conduction_path_failed"));
        }
        return response.json() as Promise<Record<string, unknown>>;
      })
      .then((payload) => {
        this.acceptVoxelConductionPath(
          source,
          target,
          sourcePotential,
          maxTicks,
          powerSource,
          payload,
        );
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : String(error);
        this.lastError = reason;
        this.bus.emit("world:voxel-sync-error", { reason, source: "conduction_path" });
      });
    return true;
  }

  private acceptVoxelConductionPath(
    source: FMacroCoord,
    target: FMacroCoord,
    sourcePotential: number,
    maxTicks: number,
    powerSource: ElectricPowerSourceRequest | undefined,
    payload: Record<string, unknown>,
  ): void {
    const regionId = String(payload["region_id"] ?? "none");
    const fieldRegionCreated = Boolean(payload["field_region_created"]);
    const conductionMode = normalizeConductionMode(
      payload["conduction_mode"] ?? powerSource?.conductionMode,
    );
    const powerDraw = normalizePowerDraw(payload["power_draw"]);
    this.logger.emit("voxel", "conduction_ok", {
      logical_scene_id: this.logicalSceneId,
      source_coord: `${source.x},${source.y},${source.z}`,
      target_coord: `${target.x},${target.y},${target.z}`,
      source_potential: sourcePotential,
      conduction_mode: conductionMode,
      region_id: regionId,
      created: String(payload["created"] ?? "unknown"),
      field_region_created: String(fieldRegionCreated),
      max_ticks: maxTicks,
      power_draw: JSON.stringify(payload["power_draw"] ?? null),
      heat_energy_joules_per_tick: String(powerDraw?.estimatedTickEnergyJoules ?? ""),
    });
    this.bus.emit("world:voxel-conduction-accepted", {
      sourceCoord: source,
      targetCoord: target,
      sourcePotential,
      source: "server",
      conductionMode,
      regionId,
      fieldRegionCreated,
      ...(powerDraw ? { powerDraw } : {}),
    });
  }

  requestVoxelAutoCircuit(coord: FMacroCoord, maxTicks?: number): boolean {
    const url = `${this.transport.getAuthBaseUrl()}/ingame/voxel/auto_circuit`;
    void fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        logical_scene_id: this.logicalSceneId,
        x: coord.x,
        y: coord.y,
        z: coord.z,
        ...(maxTicks !== undefined ? { max_ticks: maxTicks } : {}),
      }),
    })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(await responseErrorReason(response, "auto_circuit_failed"));
        }
        return response.json() as Promise<Record<string, unknown>>;
      })
      .then((payload) => {
        const regionId = String(payload["region_id"] ?? "none");
        const fieldRegionCreated = Boolean(payload["field_region_created"]);
        const sourceCount = finiteNumber(payload["source_count"]);
        const loadCount = finiteNumber(payload["load_count"]);
        const powerDraw = normalizePowerDraw(payload["power_draw"]);
        this.logger.emit("voxel", "auto_circuit_ok", {
          logical_scene_id: this.logicalSceneId,
          coord: `${coord.x},${coord.y},${coord.z}`,
          region_id: regionId,
          created: String(payload["created"] ?? "unknown"),
          field_region_created: String(fieldRegionCreated),
          source_count: String(sourceCount ?? "unknown"),
          load_count: String(loadCount ?? "unknown"),
          waiting_for_load: String(payload["waiting_for_load"] ?? "unknown"),
          power_draw: JSON.stringify(payload["power_draw"] ?? null),
          heat_energy_joules_per_tick: String(powerDraw?.estimatedTickEnergyJoules ?? ""),
        });
        this.bus.emit("world:voxel-auto-circuit-accepted", {
          coord,
          source: "server",
          regionId,
          fieldRegionCreated,
          ...(sourceCount !== undefined ? { sourceCount } : {}),
          ...(loadCount !== undefined ? { loadCount } : {}),
          ...(powerDraw ? { powerDraw } : {}),
        });
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : String(error);
        this.lastError = reason;
        this.bus.emit("world:voxel-sync-error", { reason, source: "auto_circuit" });
      });
    return true;
  }

  private applyObjectStateDelta(message: VoxelObjectStateDeltaMessage): void {
    this.receivedObjectStateDeltaCount += 1;
    this.objectStateDeltaConsumer.consume(message.delta);
  }

  // Phase 4-bis Step 4-bis-10:每帧 advance debris simulation + 流出过期
  // 粒子;先用 lastObjectStateFrameMs 计算 dt 补偿 GameLoop 不传 dtMs 的
  // 接口缺口。
  private tickDebris(nowMs: number): void {
    if (this.lastObjectStateFrameMs === null) {
      this.lastObjectStateFrameMs = nowMs;
      return;
    }
    const dtMs = Math.max(0, nowMs - this.lastObjectStateFrameMs);
    this.lastObjectStateFrameMs = nowMs;

    if (dtMs > 0) {
      this.debrisSimulation.update(dtMs);
      // Sweep stale ClearedSlotCache entries to bound memory.
      this.clearedSlotCache.sweep(nowMs);
    }
  }

  // Phase 4-bis Step 4-bis-10 / Decision D6:0x6C 来时 take ClearedSlotCache
  // 拿粒子起点;若空(典型场景:0x6C 比 ChunkDelta 先到,或者 cache hook
  // 还没接 owner_object_id provenance — 见 step commit message)入重试队列,
  // 100ms 后再尝试,仍空降级到 affected_chunks 中心点。
  private handleObjectStateDeltaForDebris(
    delta: ObjectStateDelta,
    flagName: ObjectStateFlagName,
  ): void {
    if (flagName === "unknown") {
      // Don't waste a retry / fallback for empty / unknown flag bits.
      return;
    }

    const slots = this.clearedSlotCache.take(delta.objectId);
    if (slots.length > 0) {
      this.spawnDebrisAndEmit(delta, flagName, slots, "cleared_slot_cache");
      return;
    }

    // Cache miss → defer 100ms (retry from queue) before falling back.
    this.objectStateDeltaRetryQueue.push({
      delta,
      flagName,
      retryAtMs: this.currentFrameTimeMs() + OBJECT_STATE_DELTA_RETRY_DELAY_MS,
    });
  }

  private processObjectStateDeltaRetryQueue(nowMs: number): void {
    if (this.objectStateDeltaRetryQueue.length === 0) {
      return;
    }
    let writeIdx = 0;
    for (let readIdx = 0; readIdx < this.objectStateDeltaRetryQueue.length; readIdx++) {
      const item = this.objectStateDeltaRetryQueue[readIdx]!;
      if (nowMs < item.retryAtMs) {
        if (writeIdx !== readIdx) {
          this.objectStateDeltaRetryQueue[writeIdx] = item;
        }
        writeIdx += 1;
        continue;
      }

      // Time to fire.
      const slots = this.clearedSlotCache.take(item.delta.objectId);
      if (slots.length > 0) {
        this.spawnDebrisAndEmit(item.delta, item.flagName, slots, "delayed_retry");
      } else {
        this.spawnDebrisFromAffectedChunks(item.delta, item.flagName);
      }
    }
    if (writeIdx !== this.objectStateDeltaRetryQueue.length) {
      this.objectStateDeltaRetryQueue.length = writeIdx;
    }
  }

  private spawnDebrisFromAffectedChunks(
    delta: ObjectStateDelta,
    flagName: ObjectStateFlagName,
  ): void {
    if (delta.affectedChunks.length === 0) {
      this.emitObjectStateDeltaEvent(delta, flagName, 0, "none");
      return;
    }

    const halfChunkM = (VoxelConstants.ChunkSizeInMacros * MacroWorldSize) / 2 / 100; // 100 cm per macro
    const chunkSizeM = (VoxelConstants.ChunkSizeInMacros * MacroWorldSize) / 100;
    const points: DebrisSpawnPoint[] = delta.affectedChunks.map((coord) => ({
      worldX: coord.x * chunkSizeM + halfChunkM,
      worldY: coord.y * chunkSizeM + halfChunkM,
      worldZ: coord.z * chunkSizeM + halfChunkM,
    }));

    if (flagName === "unknown") {
      this.emitObjectStateDeltaEvent(delta, flagName, 0, "affected_chunks_fallback");
      return;
    }
    const limited = sampleDebrisPoints(points, flagName);
    const spawned = this.debrisSimulation.spawn(limited, flagName);
    this.emitObjectStateDeltaEvent(delta, flagName, spawned, "affected_chunks_fallback");
  }

  private spawnDebrisAndEmit(
    delta: ObjectStateDelta,
    flagName: ObjectStateFlagName,
    slots: { worldX: number; worldY: number; worldZ: number }[],
    source: "cleared_slot_cache" | "delayed_retry",
  ): void {
    const points: DebrisSpawnPoint[] = slots.map((s) => ({
      worldX: s.worldX,
      worldY: s.worldY,
      worldZ: s.worldZ,
    }));
    const limited = sampleDebrisPoints(points, flagName);
    if (flagName === "unknown") {
      this.emitObjectStateDeltaEvent(delta, flagName, 0, source);
      return;
    }
    const spawned = this.debrisSimulation.spawn(limited, flagName);
    this.emitObjectStateDeltaEvent(delta, flagName, spawned, source);
  }

  private emitObjectStateDeltaEvent(
    delta: ObjectStateDelta,
    flagName: ObjectStateFlagName,
    debrisSpawned: number,
    source: "cleared_slot_cache" | "delayed_retry" | "affected_chunks_fallback" | "none",
  ): void {
    this.bus.emit("world:object-state-delta", {
      objectId: delta.objectId.toString(),
      objectVersion: delta.objectVersion.toString(),
      flagName,
      affectedChunkCount: delta.affectedChunks.length,
      debrisSpawned,
      debrisSource: source,
    });
  }

  private currentFrameTimeMs(): number {
    return this.lastObjectStateFrameMs ?? Math.round(performance.now());
  }

  private trackPendingChunkSubscription(
    centerChunk: FChunkCoord,
    radiusLInf: number,
    requestId: number,
    sentAtMs: number,
    source: string,
  ): void {
    for (const coord of chunksCoveredBySubscription(centerChunk, radiusLInf)) {
      this.pendingChunkSubscriptions.set(chunkCoordKey(coord), {
        coord,
        requestId,
        sentAtMs,
        source,
      });
    }
  }

  private hasActivePendingChunkSubscription(chunkCoord: FChunkCoord, nowMs: number): boolean {
    const key = chunkCoordKey(chunkCoord);
    const pending = this.pendingChunkSubscriptions.get(key);
    if (!pending) {
      return false;
    }

    if (nowMs - pending.sentAtMs >= CHUNK_SUBSCRIPTION_PENDING_RETRY_DELAY_MS) {
      this.pendingChunkSubscriptions.delete(key);
      return false;
    }

    return true;
  }

  private clearPendingChunkRequest(chunkCoord: FChunkCoord): void {
    const key = chunkCoordKey(chunkCoord);
    this.movementPrewarmRequests.delete(key);
    this.pendingMovementPrewarmQueue.delete(key);
    this.pendingChunkSubscriptions.delete(key);
  }

  // Phase 4-bis Step 4-bis-12 production hook:RenderOrchestrator picks
  // this up via duck typing to wire the DebrisRenderer InstancedMesh into
  // the scene root group.
  getDebrisSimulation(): DebrisSimulation {
    return this.debrisSimulation;
  }

  // Phase 4-bis Step 4-bis-10 test hatches.
  debrisSimulationForTest(): DebrisSimulation {
    return this.debrisSimulation;
  }

  clearedSlotCacheForTest(): ClearedSlotCache {
    return this.clearedSlotCache;
  }

  private applyInvalidate(invalidate: VoxelChunkInvalidateMessage): void {
    this.clearPendingChunkRequest(invalidate.chunkCoord);
    this.store.invalidateChunkAuthority(invalidate.chunkCoord);
    this.store.removeChunk(invalidate.chunkCoord);
    this.subscriptionState = "idle";
    this.initialSubscriptionsSent = false;

    this.bus.emit("world:chunk-invalidated", {
      logicalSceneId: invalidate.logicalSceneId,
      chunkCoord: invalidate.chunkCoord,
      reason: invalidate.reasonName,
    });
  }

  private applyDelta(delta: VoxelChunkDeltaMessage): void {
    const chunk = this.store.getChunk(delta.chunkCoord);
    const metadata = this.store.getChunkAuthorityMetadata(delta.chunkCoord);

    if (!chunk || !metadata) {
      this.bus.emit("world:chunk-delta-skipped", {
        logicalSceneId: delta.logicalSceneId,
        chunkCoord: delta.chunkCoord,
        baseChunkVersion: delta.baseChunkVersion,
        newChunkVersion: delta.newChunkVersion,
        reason: "chunk_not_loaded",
      });
      return;
    }

    if (metadata.chunkVersion !== delta.baseChunkVersion) {
      this.store.invalidateChunkAuthority(delta.chunkCoord);
      this.bus.emit("world:chunk-delta-skipped", {
        logicalSceneId: delta.logicalSceneId,
        chunkCoord: delta.chunkCoord,
        baseChunkVersion: delta.baseChunkVersion,
        newChunkVersion: delta.newChunkVersion,
        reason: "stale_base_version",
        knownChunkVersion: metadata.chunkVersion,
      });
      return;
    }

    let appliedOps = 0;

    for (const op of delta.ops) {
      const localMacro = macroCoordFromLinearIndex(op.macroIndex);

      if (op.deltaKind === VoxelChunkDeltaKind.CellSolid) {
        const block = decodeNormalBlockDataPayload(op.payload);
        if (chunk.trySetNormalBlock(localMacro, block)) {
          appliedOps += 1;
        }
      } else if (op.deltaKind === VoxelChunkDeltaKind.CellEmpty) {
        if (chunk.tryClearMacroCell(localMacro)) {
          appliedOps += 1;
        }
      } else if (op.deltaKind === VoxelChunkDeltaKind.CellRefined && op.refinedCell) {
        const refined = wireToRefinedCell(op.refinedCell);
        if (chunk.applyRefinedCellFromWire(localMacro, refined)) {
          appliedOps += 1;
        }
      }
    }

    this.store.bumpChunkAuthorityVersion(delta.chunkCoord, {
      chunkVersion: delta.newChunkVersion,
      receivedAtMs: Math.round(performance.now()),
    });

    this.bus.emit("world:chunk-delta-applied", {
      logicalSceneId: delta.logicalSceneId,
      chunkCoord: delta.chunkCoord,
      baseChunkVersion: delta.baseChunkVersion,
      newChunkVersion: delta.newChunkVersion,
      opCount: delta.ops.length,
      appliedOps,
    });
    this.ackAppliedChunk(delta.logicalSceneId, delta.chunkCoord, delta.newChunkVersion, "delta");
  }

  private applySnapshot(snapshot: VoxelChunkSnapshotMessage): void {
    // Materialize the wire-form refined cells into FRefinedCellData so the
    // mesher / collision / debug consumers (which still read the legacy
    // shape) reflect refined macros after a snapshot. Decision 5 of
    // phase-1c-refined-mutation.md keeps the wire form canonical; this is a
    // 1c-5 lossy bridge until the renderer learns to read the wire form
    // directly. The macroHeaders pool keeps using the refined-cell indices
    // shipped in the same snapshot.
    const storage = {
      ...snapshot.storage,
      refinedCells: snapshot.refinedCellsWire.map(wireToRefinedCell),
    };

    const chunk = this.store.replaceChunkStorage(storage, {
      requestId: snapshot.requestId,
      logicalSceneId: snapshot.logicalSceneId,
      schemaVersion: snapshot.schemaVersion,
      chunkVersion: snapshot.chunkVersion,
      chunkHash: snapshot.chunkHash,
      receivedAtMs: Math.round(performance.now()),
    });
    const solidBlocks = chunk.countSolidBlocks();
    this.clearPendingChunkRequest(snapshot.chunkCoord);
    this.lastSnapshot = {
      requestId: snapshot.requestId,
      logicalSceneId: snapshot.logicalSceneId,
      chunkCoord: { ...snapshot.chunkCoord },
      chunkVersion: snapshot.chunkVersion,
      chunkHash: snapshot.chunkHash,
      solidBlocks,
    };
    this.subscriptionState = "active";
    this.bus.emit("world:chunk-snapshot-applied", {
      requestId: snapshot.requestId,
      logicalSceneId: snapshot.logicalSceneId,
      chunkCoord: snapshot.chunkCoord,
      chunkVersion: snapshot.chunkVersion,
      chunkHash: snapshot.chunkHash,
      solidBlocks,
    });
    this.ackAppliedChunk(
      snapshot.logicalSceneId,
      snapshot.chunkCoord,
      snapshot.chunkVersion,
      "snapshot",
    );

    // Demo-only fallback for empty servers. Triggered when an authoritative
    // snapshot arrives with zero solid blocks AND the operator has explicitly
    // opted in via `VITE_VOXEL_PRIME_DEMO_BLOCK=1`. Defaults to off because
    // production demos rely on the server to seed the
    // starter terrain server-side; client-side priming is a relic kept only
    // for emergency local debugging when the seed path is unavailable.
    if (this.primeDemoBlock && !this.primeSent && solidBlocks === 0) {
      this.primeSent = true;
      this.sendVoxelImpactMacro(
        {
          x: snapshot.chunkCoord.x * VoxelConstants.ChunkSizeX,
          y: snapshot.chunkCoord.y * VoxelConstants.ChunkSizeY,
          z: snapshot.chunkCoord.z * VoxelConstants.ChunkSizeZ,
        },
        1,
      );
    }
  }

  private applyIntentResult(result: VoxelIntentResultMessage): void {
    this.pendingIntentCount = Math.max(0, this.pendingIntentCount - 1);
    this.lastIntentResult = {
      requestId: result.requestId,
      clientIntentSeq: result.clientIntentSeq,
      logicalSceneId: result.logicalSceneId,
      resultCodeName: result.resultCodeName,
      resultRef: result.resultRef,
      reason: result.reason,
    };
    if (result.resultCodeName === "rejected" || result.resultCodeName === "stale") {
      this.store.editStats.rejected += 1;
      this.lastError = result.reason;
    } else if (result.resultCodeName === "accepted") {
      this.lastError = null;
    }
    this.bus.emit("world:voxel-intent-result", {
      requestId: result.requestId,
      clientIntentSeq: result.clientIntentSeq,
      logicalSceneId: result.logicalSceneId,
      resultCodeName: result.resultCodeName,
      resultRef: result.resultRef,
      reason: result.reason,
    });

    const pendingPrefab = this.pendingPrefabIntents.get(result.requestId);
    if (pendingPrefab) {
      this.pendingPrefabIntents.delete(result.requestId);

      // Phase A4-bis follow-up: surface end-to-end client-side RTT for
      // prefab intents so we can tell whether the user-perceived
      // "prefab placement is slow" stall is on the server (long RTT)
      // or on the client (RTT short, but mesh rebuild blocks the main
      // thread afterwards). Logged through the same logger every other
      // voxel observe uses, so it shows up in the existing CLI sink.
      const elapsedMs = Math.round(performance.now() - pendingPrefab.sentAtMs);
      this.logger.emit("voxel", "prefab_intent_rtt", {
        request_id: result.requestId,
        blueprint_id: pendingPrefab.blueprintId,
        blueprint_name: pendingPrefab.blueprintName,
        result_code: result.resultCodeName,
        elapsed_ms: elapsedMs,
      });

      this.bus.emit("world:voxel-prefab-result", {
        blueprintId: pendingPrefab.blueprintId,
        blueprintName: pendingPrefab.blueprintName,
        requestId: result.requestId,
        accepted: result.resultCodeName === "accepted",
        reason: result.reason,
      });
    }
  }

  private subscribeInitialChunks(): void {
    if (this.initialSubscriptionsSent) {
      return;
    }

    this.initialSubscriptionsSent = true;
    let lastRequestId: number | null = null;

    for (const subscription of this.initialSubscriptions) {
      const requestId = this.subscribeVoxelChunk(
        subscription.centerChunk,
        subscription.radiusLInf,
        "startup",
      );
      if (requestId !== null) {
        lastRequestId = requestId;
      }
    }

    if (lastRequestId !== null) {
      this.transport.sendVoxelDebugProbe("voxel_transport");
    }
  }

  private knownChunkVersions(): VoxelKnownChunk[] {
    return this.store.authoritativeChunkSummaries(128).map((summary) => ({
      chunkCoord: summary.coord,
      chunkVersion: summary.chunkVersion,
    }));
  }

  private shouldRetrySeed(nowMs: number): boolean {
    return this.seedState === "failed" && nowMs - this.lastSeedAttemptMs > 2_500;
  }

  private ensureDevSeed(nowMs: number): void {
    if (!this.devSeed || this.seedState === "pending") {
      return;
    }
    this.seedState = "pending";
    this.lastSeedAttemptMs = nowMs;
    const startedAtMs = performance.now();
    const url = `${this.transport.getAuthBaseUrl()}/ingame/voxel/dev_seed`;
    void fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ logical_scene_id: this.logicalSceneId }),
    })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`dev_seed_failed:${response.status}`);
        }
        return response.json() as Promise<Record<string, unknown>>;
      })
      .then((payload) => {
        this.seedState = "ready";
        this.lastError = null;
        this.lastSeedDurationMs = Math.round(performance.now() - startedAtMs);
        this.lastSeedSummary = seedSummary(payload);
        this.logger.emit("voxel", "dev_seed_ready", {
          logical_scene_id: this.logicalSceneId,
          duration_ms: this.lastSeedDurationMs,
          terrain: JSON.stringify(this.lastSeedSummary),
          result: JSON.stringify(payload).slice(0, 240),
        });
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : String(error);
        this.seedState = "failed";
        this.lastError = reason;
        this.lastSeedDurationMs = Math.round(performance.now() - startedAtMs);
        this.bus.emit("world:voxel-sync-error", { reason, source: "dev_seed" });
      });
  }

  private rejectServerOnlyEdit(reason: string): void {
    this.lastError = reason;
    this.store.editStats.rejected += 1;
  }

  private ackAppliedChunk(
    logicalSceneId: number,
    chunkCoord: FChunkCoord,
    chunkVersion: number,
    source: "snapshot" | "delta",
  ): void {
    this.pendingChunkAcks.set(`${logicalSceneId}:${chunkCoordKey(chunkCoord)}`, {
      logicalSceneId,
      chunkCoord: { ...chunkCoord },
      chunkVersion,
      source,
    });
  }

  private flushPendingChunkAcks(): void {
    if (this.pendingChunkAcks.size === 0) {
      return;
    }

    const pending = [...this.pendingChunkAcks.values()];
    this.pendingChunkAcks.clear();

    const byScene = new Map<number, PendingChunkAck[]>();
    for (const ack of pending) {
      const sceneAcks = byScene.get(ack.logicalSceneId);
      if (sceneAcks) {
        sceneAcks.push(ack);
      } else {
        byScene.set(ack.logicalSceneId, [ack]);
      }
    }

    for (const [logicalSceneId, acks] of byScene) {
      this.flushPendingChunkAckGroup(logicalSceneId, acks);
    }
  }

  private flushPendingChunkAckGroup(logicalSceneId: number, acks: PendingChunkAck[]): void {
    const requestId = this.transport.sendVoxelChunkAck({
      logicalSceneId,
      acks: acks.map((ack) => ({
        chunkCoord: ack.chunkCoord,
        chunkVersion: ack.chunkVersion,
      })),
    });

    if (requestId === null) {
      this.lastError = "chunk_ack_blocked";
      this.logger.emit("voxel", "chunk_ack_blocked", {
        logical_scene_id: logicalSceneId,
        ack_count: acks.length,
        chunks: JSON.stringify(
          acks.map((ack) => `${chunkCoordKey(ack.chunkCoord)}@${ack.chunkVersion}`),
        ),
        sources: JSON.stringify(acks.map((ack) => ack.source)),
      });
      return;
    }

    const lastAck = acks[acks.length - 1]!;
    this.appliedChunkAckCount += acks.length;
    this.lastAppliedChunkAck = {
      requestId,
      logicalSceneId,
      chunkCoord: { ...lastAck.chunkCoord },
      chunkVersion: lastAck.chunkVersion,
      source: lastAck.source,
    };
    this.logger.emit("voxel", "chunk_ack_applied", {
      request_id: requestId,
      logical_scene_id: logicalSceneId,
      ack_count: acks.length,
      chunks: JSON.stringify(
        acks.map((ack) => `${chunkCoordKey(ack.chunkCoord)}@${ack.chunkVersion}`),
      ),
      sources: JSON.stringify(acks.map((ack) => ack.source)),
      applied_ack_count: this.appliedChunkAckCount,
    });
  }
}

export function isServerVoxelTransportPort(value: unknown): value is ServerVoxelTransportPort {
  const candidate = value as Partial<ServerVoxelTransportPort>;
  return (
    typeof candidate.canUseServerVoxel === "function" &&
    typeof candidate.getAuthBaseUrl === "function" &&
    typeof candidate.voxelDebugSnapshot === "function" &&
    typeof candidate.sendVoxelChunkSubscribe === "function" &&
    typeof candidate.sendVoxelChunkAck === "function" &&
    typeof candidate.sendVoxelImpactIntent === "function" &&
    typeof candidate.sendVoxelPrefabPlaceIntent === "function" &&
    typeof candidate.drainVoxelSnapshots === "function" &&
    typeof candidate.drainVoxelDeltas === "function" &&
    typeof candidate.drainVoxelInvalidates === "function" &&
    typeof candidate.drainVoxelObjectStateDeltas === "function" &&
    typeof candidate.drainVoxelFieldSnapshots === "function" &&
    typeof candidate.drainVoxelFieldDestroyeds === "function"
  );
}

async function responseErrorReason(response: Response, prefix: string): Promise<string> {
  try {
    const payload = (await response.json()) as Record<string, unknown>;
    const code = String(payload["reason_code"] ?? payload["error"] ?? "unknown");
    const reason = String(payload["reason"] ?? "");
    return `${prefix}:${response.status}:${code}${reason ? `:${reason}` : ""}`;
  } catch {
    return `${prefix}:${response.status}`;
  }
}

function seedSummary(payload: Record<string, unknown>): Record<string, unknown> {
  const terrain = payload["terrain"];
  if (!terrain || typeof terrain !== "object" || Array.isArray(terrain)) {
    return {};
  }

  const source = terrain as Record<string, unknown>;
  return {
    attempted: source["attempted"] ?? 0,
    written: source["written"] ?? 0,
    skipped: source["skipped"] ?? 0,
    errors: source["errors"] ?? 0,
    maxChunkVersion: source["max_chunk_version"] ?? 0,
  };
}

function normalizePowerDraw(value: unknown): ElectricPowerDraw | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  const source = value as Record<string, unknown>;
  const outputMode = normalizeOutputMode(source["output_mode"]);
  const voltage = finiteNumber(source["voltage"]);
  const currentLimitAmps = finiteNumber(source["current_limit_amps"]);
  const frequencyHz = finiteNumber(source["frequency_hz"]);
  const loadCurrentAmps = finiteNumber(source["load_current_amps"]);
  const estimatedTickEnergyJoules = finiteNumber(source["estimated_tick_energy_joules"]);
  const overCurrent =
    typeof source["over_current"] === "boolean" ? source["over_current"] : undefined;

  const result: ElectricPowerDraw = {
    ...(outputMode ? { outputMode } : {}),
    ...(voltage !== undefined ? { voltage } : {}),
    ...(currentLimitAmps !== undefined ? { currentLimitAmps } : {}),
    ...(frequencyHz !== undefined ? { frequencyHz } : {}),
    ...(loadCurrentAmps !== undefined ? { loadCurrentAmps } : {}),
    ...(estimatedTickEnergyJoules !== undefined ? { estimatedTickEnergyJoules } : {}),
    ...(overCurrent !== undefined ? { overCurrent } : {}),
  };
  return Object.keys(result).length > 0 ? result : undefined;
}

function normalizeOutputMode(value: unknown): ElectricPowerDraw["outputMode"] | undefined {
  return value === "dc" || value === "ac" || value === "pulse" ? value : undefined;
}

function normalizeConductionMode(value: unknown): ElectricConductionMode {
  return value === "discharge" ? "discharge" : "conductive";
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function normalizeInitialSubscriptions(
  subscriptions: readonly { centerChunk: FChunkCoord; radiusLInf?: number }[],
): readonly { centerChunk: FChunkCoord; radiusLInf: number }[] {
  return subscriptions.map((subscription) => ({
    centerChunk: { ...subscription.centerChunk },
    radiusLInf: Math.max(0, Math.floor(subscription.radiusLInf ?? 0)),
  }));
}

function chunksCoveredBySubscription(centerChunk: FChunkCoord, radiusLInf: number): FChunkCoord[] {
  const radius = Math.max(0, Math.trunc(radiusLInf));
  const chunks: FChunkCoord[] = [];

  for (let x = centerChunk.x - radius; x <= centerChunk.x + radius; x += 1) {
    for (let y = centerChunk.y - radius; y <= centerChunk.y + radius; y += 1) {
      for (let z = centerChunk.z - radius; z <= centerChunk.z + radius; z += 1) {
        chunks.push({ x, y, z });
      }
    }
  }

  return chunks;
}
