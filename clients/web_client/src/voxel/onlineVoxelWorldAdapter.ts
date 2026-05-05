import type { AppEventBus } from "../shared/events/events";
import { VoxelConstants } from "./core/constants";
import { chunkCoordKey, type FChunkCoord, type FMacroCoord, type FMicroCoord } from "./core/types";
import {
  decodeNormalBlockDataPayload,
  type VoxelChunkDeltaMessage,
  type VoxelChunkInvalidateMessage,
  type VoxelChunkSnapshotMessage,
  type VoxelDebugProbeMessage,
  type VoxelIntentResultMessage,
  type VoxelKnownChunk,
  type VoxelPrefabKnownCellRef,
  type VoxelPrefabKnownObject,
  type VoxelPrefabKnownRef,
} from "../infrastructure/net/voxelProtocol";
import { resolveBlueprint } from "./onlinePrefabCatalog";
import { macroCoordFromLinearIndex } from "./core/gridUtils";
import type { ObserveLog } from "../observe/logger";
import type { EVoxelRotation } from "./core/types";
import type { FNormalBlockData } from "./storage/types";
import type {
  LocalPrefab,
  PrefabBoundarySnapRequest,
  PrefabBoundarySnapResult,
  PrefabSocketSnapRequest,
  PrefabSocketSnapResult,
} from "./prefab";
import { LocalVoxelWorldAdapter } from "./worldAdapter";

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
  sendVoxelImpactIntent(request: {
    logicalSceneId: number;
    sourceSkillId: number;
    targetWorldMicro: FMacroCoord;
    impactKind: number;
    clientIntentSeq: number;
    clientHintHash?: number;
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
}

export interface OnlineVoxelWorldOptions {
  logicalSceneId?: number;
  defaultCenterChunk?: FChunkCoord;
  defaultRadiusLInf?: number;
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
    { blueprintId: number; blueprintName: string }
  >();
  private lastSeedAttemptMs = 0;
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
  private primeSent = false;

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
    this.devSeed = options.devSeed ?? true;
    this.primeDemoBlock = options.primeDemoBlock ?? true;
    this.sourceSkillId = options.sourceSkillId ?? 1;
    this.seedState = this.devSeed ? "idle" : "disabled";
  }

  onFrame(nowMs: number): void {
    this.drainVoxelMessages();

    if (!this.transport.canUseServerVoxel()) {
      return;
    }

    if (this.seedState === "disabled") {
      this.seedState = "ready";
    }
    if (this.seedState === "idle" || this.shouldRetrySeed(nowMs)) {
      this.ensureDevSeed(nowMs);
      return;
    }
    if (this.seedState !== "ready") {
      return;
    }
    if (this.subscriptionState === "idle") {
      this.subscribeDefaultChunk();
    }
  }

  override debugSnapshot(): Record<string, unknown> {
    return {
      ...super.debugSnapshot(),
      mode: this.mode,
      logicalSceneId: this.logicalSceneId,
      defaultCenterChunk: chunkCoordKey(this.defaultCenterChunk),
      defaultRadiusLInf: this.defaultRadiusLInf,
      seedState: this.seedState,
      subscriptionState: this.subscriptionState,
      subscriptionRequestId: this.subscriptionRequestId,
      pendingIntentCount: this.pendingIntentCount,
      pendingPrefabIntentCount: this.pendingPrefabIntents.size,
      clientIntentSeqNext: this.clientIntentSeq,
      lastSnapshot: this.lastSnapshot
        ? {
            ...this.lastSnapshot,
            chunkCoord: chunkCoordKey(this.lastSnapshot.chunkCoord),
          }
        : null,
      lastIntentResult: this.lastIntentResult,
      lastDebugProbe: this.lastDebugProbe,
      lastError: this.lastError,
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

  override breakBlock(_coord: FMacroCoord): boolean {
    this.rejectServerOnlyEdit("break_not_supported_by_server");
    return false;
  }

  override placeMicroBlock(
    _macro: FMacroCoord,
    _micro: FMicroCoord,
    _block: FNormalBlockData,
  ): boolean {
    this.rejectServerOnlyEdit("micro_place_not_supported_by_server");
    return false;
  }

  override breakMicroBlock(_macro: FMacroCoord, _micro: FMicroCoord): boolean {
    this.rejectServerOnlyEdit("micro_break_not_supported_by_server");
    return false;
  }

  override placePrefab(
    name: string,
    origin: FMacroCoord,
    _rotation?: EVoxelRotation,
  ): { ok: boolean; placed: number; instanceId?: number; conflict?: boolean } {
    const blueprint = resolveBlueprint(name);
    if (!blueprint) {
      const reason = `unknown_blueprint:${name}`;
      this.rejectServerOnlyEdit(reason);
      this.bus.emit("world:voxel-sync-error", { reason, source: "prefab_place" });
      return { ok: false, placed: 0 };
    }

    const clientIntentSeq = this.clientIntentSeq;
    // v1: rotation is intentionally pinned to 0 on the wire — the server
    // does not yet support arbitrary rotations and the local UI signature
    // accepts an EVoxelRotation purely for forward-compatibility.
    const requestId = this.transport.sendVoxelPrefabPlaceIntent({
      logicalSceneId: this.logicalSceneId,
      parcelId: 0,
      knownParcelBuildEpoch: 0,
      blueprintId: blueprint.id,
      blueprintVersion: blueprint.version,
      anchorWorldMicro: {
        x: origin.x * VoxelConstants.MicroPerMacro,
        y: origin.y * VoxelConstants.MicroPerMacro,
        z: origin.z * VoxelConstants.MicroPerMacro,
      },
      rotation: 0,
      clientIntentSeq,
    });

    if (requestId === null) {
      this.rejectServerOnlyEdit("voxel_transport_unavailable");
      return { ok: false, placed: 0 };
    }

    this.clientIntentSeq += 1;
    this.pendingIntentCount += 1;
    this.pendingPrefabIntents.set(requestId, {
      blueprintId: blueprint.id,
      blueprintName: name,
    });
    return { ok: true, placed: blueprint.expectedCellCount };
  }

  override placePrefabSocketSnap(_request: PrefabSocketSnapRequest): PrefabSocketSnapResult {
    this.rejectServerOnlyEdit("prefab_socket_snap_not_supported_by_server");
    return { ok: false, placed: 0, rejectReason: "server_authority_not_supported" };
  }

  override placePrefabBoundarySnap(_request: PrefabBoundarySnapRequest): PrefabBoundarySnapResult {
    this.rejectServerOnlyEdit("prefab_boundary_snap_not_supported_by_server");
    return { ok: false, placed: 0, rejectReason: "server_authority_not_supported" };
  }

  override importSnapshot(
    _snapshot: Parameters<LocalVoxelWorldAdapter["importSnapshot"]>[0],
  ): void {
    this.lastError = "world_import_disabled_in_server_authority_mode";
  }

  requestVoxelDebugProbe(command: string = "voxel_transport"): number | null {
    return this.transport.sendVoxelDebugProbe(command);
  }

  subscribeVoxelChunk(centerChunk: FChunkCoord, radiusLInf: number = 0): number | null {
    const requestId = this.transport.sendVoxelChunkSubscribe({
      logicalSceneId: this.logicalSceneId,
      centerChunk,
      radiusLInf,
      wantSnapshot: true,
      known: this.knownChunkVersions(),
    });
    if (requestId !== null) {
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
  }

  private applyInvalidate(invalidate: VoxelChunkInvalidateMessage): void {
    this.store.invalidateChunkAuthority(invalidate.chunkCoord);
    this.store.removeChunk(invalidate.chunkCoord);
    this.subscriptionState = "idle";

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
      if (op.deltaKind === 1) {
        const block = decodeNormalBlockDataPayload(op.payload);
        const localMacro = macroCoordFromLinearIndex(op.macroIndex);
        if (chunk.trySetNormalBlock(localMacro, block)) {
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
  }

  private applySnapshot(snapshot: VoxelChunkSnapshotMessage): void {
    const chunk = this.store.replaceChunkStorage(snapshot.storage, {
      requestId: snapshot.requestId,
      logicalSceneId: snapshot.logicalSceneId,
      schemaVersion: snapshot.schemaVersion,
      chunkVersion: snapshot.chunkVersion,
      chunkHash: snapshot.chunkHash,
      receivedAtMs: Math.round(performance.now()),
    });
    const solidBlocks = chunk.countSolidBlocks();
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
      this.bus.emit("world:voxel-prefab-result", {
        blueprintId: pendingPrefab.blueprintId,
        blueprintName: pendingPrefab.blueprintName,
        requestId: result.requestId,
        accepted: result.resultCodeName === "accepted",
        reason: result.reason,
      });
    }
  }

  private subscribeDefaultChunk(): void {
    const requestId = this.subscribeVoxelChunk(this.defaultCenterChunk, this.defaultRadiusLInf);
    if (requestId !== null) {
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
        this.logger.emit("voxel", "dev_seed_ready", {
          logical_scene_id: this.logicalSceneId,
          result: JSON.stringify(payload).slice(0, 240),
        });
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : String(error);
        this.seedState = "failed";
        this.lastError = reason;
        this.bus.emit("world:voxel-sync-error", { reason, source: "dev_seed" });
      });
  }

  private rejectServerOnlyEdit(reason: string): void {
    this.lastError = reason;
    this.store.editStats.rejected += 1;
  }
}

export function isServerVoxelTransportPort(value: unknown): value is ServerVoxelTransportPort {
  const candidate = value as Partial<ServerVoxelTransportPort>;
  return (
    typeof candidate.canUseServerVoxel === "function" &&
    typeof candidate.getAuthBaseUrl === "function" &&
    typeof candidate.voxelDebugSnapshot === "function" &&
    typeof candidate.sendVoxelChunkSubscribe === "function" &&
    typeof candidate.sendVoxelImpactIntent === "function" &&
    typeof candidate.sendVoxelPrefabPlaceIntent === "function" &&
    typeof candidate.drainVoxelSnapshots === "function" &&
    typeof candidate.drainVoxelDeltas === "function" &&
    typeof candidate.drainVoxelInvalidates === "function"
  );
}
