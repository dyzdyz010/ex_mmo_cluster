import { Vector3 } from "three";
import {
  encodeAuthRequest,
  decodeServerMessage,
  encodeEnterScene,
  encodeHeartbeat,
  encodeMovementInput,
} from "./gateProtocol";
import {
  decodeVoxelServerMessage,
  type VoxelChunkDeltaMessage,
  type VoxelChunkInvalidateMessage,
  encodeVoxelChunkSubscribe,
  encodeVoxelChunkUnsubscribe,
  encodeVoxelDebugProbe,
  encodeVoxelImpactIntent,
  encodeVoxelPrefabPlaceIntent,
  type VoxelChunkSnapshotMessage,
  type VoxelDebugProbeMessage,
  type VoxelIntentResultMessage,
  type VoxelKnownChunk,
  type VoxelObjectStateDeltaMessage,
  type VoxelPrefabKnownCellRef,
  type VoxelPrefabKnownObject,
  type VoxelPrefabKnownRef,
} from "./voxelProtocol";
import {
  encodeVoxelEditIntent,
  EXPECTED_CELL_HASH_UNSPECIFIED,
  EXPECTED_CHUNK_VERSION_UNSPECIFIED,
} from "./voxelEditIntent";
import type { ObserveLog } from "../../observe/logger";
import type { MoveInputFrame, RemoteMoveSnapshot } from "@domain/movement/types";
import type {
  MovementTransport,
  MovementTransportTickResult,
  PendingMovementAck,
} from "@domain/movement/transport";
import { chunkCoordKey, type FChunkCoord, type FMacroCoord } from "../../voxel/core/types";

interface AutoLoginResponse {
  token: string;
  cid: number;
  username: string;
}

const SERVER_TRANSPORT_MODE = "server-ws";
const AUTO_LOGIN_TIMEOUT_MS = 5_000;
const HANDSHAKE_TIMEOUT_MS = 8_000;

/**
 * Connection lifecycle as observed by the rest of the app.
 *
 * The transport never silently downgrades to a simulated/local lane. When
 * something fails (auth, socket, enter-scene, late drop), it transitions to
 * `disconnected`, surfaces the reason, and stops sending. Callers see
 * `isReady() === false` and a stable `mode` of `server-ws` with the failure
 * reason in `debugSnapshot()`.
 */
type ConnectionStatus = "connecting" | "connected" | "disconnected";
type ConnectionPhase =
  | "init"
  | "auto_login"
  | "socket_connect"
  | "auth_request"
  | "enter_scene"
  | "ready"
  | "disconnected";

export class ServerMovementTransport implements MovementTransport {
  private socket: WebSocket | null = null;
  private ready = false;
  private connecting = false;
  private heartbeatTimer: number | null = null;
  private handshakeTimer: number | null = null;
  private requestId = 1;
  private authRequestId = 0;
  private enterSceneRequestId = 0;
  private cid: number | null = null;
  private username: string;
  private token: string | null = null;
  private readonly acknowledgements: PendingMovementAck[] = [];
  private readonly remoteSnapshots: RemoteMoveSnapshot[] = [];
  private readonly remoteEntityEnters: { cid: number; position: Vector3 }[] = [];
  private readonly remoteEntityLeaves: number[] = [];
  private readonly timeSyncSamples: {
    requestId: number;
    clientSendTs: number;
    serverRecvTs: number;
    serverSendTs: number;
  }[] = [];
  private readonly voxelSnapshots: VoxelChunkSnapshotMessage[] = [];
  private readonly voxelDeltas: VoxelChunkDeltaMessage[] = [];
  private receivedVoxelDeltaCount = 0;
  private readonly voxelInvalidates: VoxelChunkInvalidateMessage[] = [];
  private receivedVoxelInvalidateCount = 0;
  private readonly voxelIntentResults: VoxelIntentResultMessage[] = [];
  private readonly voxelDebugProbes: VoxelDebugProbeMessage[] = [];
  private readonly voxelObjectStateDeltas: VoxelObjectStateDeltaMessage[] = [];
  private receivedVoxelObjectStateDeltaCount = 0;
  private readonly voxelKnownVersions = new Map<string, number>();
  private readonly sentAtBySeq = new Map<number, number>();
  private spawnPosition: Vector3 | null = null;
  // Audit B-S1 / B-SRV2: server-reported next-input seq for the upcoming
  // spawn. Consumed alongside spawnPosition by the transport pump.
  private spawnExpectedSeq: number | null = null;
  private readonly lastResetPosition = new Vector3(-350, 650, -280);
  private connectionStatus: ConnectionStatus = "connecting";
  private connectionPhase: ConnectionPhase = "init";
  private connectionLostReason: string | null = null;
  private sentInputCount = 0;
  private receivedMessageCount = 0;
  private receivedAckCount = 0;
  private receivedRemoteSnapshotCount = 0;
  private droppedSelfLoopSnapshotCount = 0;
  private lastAckSeq: number | null = null;
  private lastRemoteTickByCid = new Map<number, number>();
  private receivedPlayerStateCount = 0;
  private lastPlayerState: { cid: number; hp: number; maxHp: number; alive: boolean } | null = null;
  private lastTimeSyncOffsetMs: number | null = null;
  private lastError: string | null = null;
  private blockedInputCount = 0;
  private lastBlockedInputReason: string | null = null;
  private lastBlockedInputSeq: number | null = null;
  private lastBlockedInputLogAtMs = Number.NEGATIVE_INFINITY;
  private bootstrapStartedAtMs: number | null = null;
  private phaseStartedAtMs: number | null = null;
  private lastAutoLoginDurationMs: number | null = null;
  private lastReadyDurationMs: number | null = null;
  private sentVoxelMessageCount = 0;
  private receivedVoxelSnapshotCount = 0;
  private receivedVoxelIntentResultCount = 0;
  private receivedVoxelDebugProbeCount = 0;
  private lastVoxelSnapshot: {
    requestId: number;
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    chunkVersion: number;
    chunkHash: number;
  } | null = null;
  private lastVoxelDelta: {
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    baseChunkVersion: number;
    newChunkVersion: number;
    opCount: number;
  } | null = null;
  private lastVoxelIntentResult: {
    requestId: number;
    clientIntentSeq: number;
    logicalSceneId: number;
    resultCodeName: string;
    resultRef: number;
    reason: string;
  } | null = null;
  private readonly pendingVoxelPrefabRequests = new Set<number>();
  private lastVoxelPrefabRequest: {
    requestId: number;
    clientIntentSeq: number;
    logicalSceneId: number;
    blueprintId: number;
    blueprintVersion: number;
    rotation: number;
  } | null = null;
  private lastVoxelError: string | null = null;
  private blockedVoxelSendCount = 0;
  private lastBlockedVoxelSend: { source: string; reason: string } | null = null;

  constructor(
    private readonly logger: ObserveLog,
    private readonly authBaseUrl: string = resolveAuthBaseUrl(),
    private readonly webSocketUrl: string = resolveGameWsUrl(),
    username: string = resolveDefaultUsername(),
  ) {
    this.username = username;
    void this.bootstrap();
  }

  get mode(): string {
    return SERVER_TRANSPORT_MODE;
  }

  isReady(): boolean {
    return this.connectionStatus === "connected" && this.ready;
  }

  debugSnapshot(): Record<string, unknown> {
    return {
      mode: this.mode,
      connectionStatus: this.connectionStatus,
      connectionPhase: this.connectionPhase,
      connectionLostReason: this.connectionLostReason,
      ready: this.ready,
      connecting: this.connecting,
      cid: this.cid,
      username: this.username,
      socketState: this.socket?.readyState ?? null,
      hasToken: this.token !== null,
      authRequestId: this.authRequestId,
      enterSceneRequestId: this.enterSceneRequestId,
      queuedAcks: this.acknowledgements.length,
      queuedRemoteSnapshots: this.remoteSnapshots.length,
      queuedRemoteEnters: this.remoteEntityEnters.length,
      queuedRemoteLeaves: this.remoteEntityLeaves.length,
      queuedTimeSyncSamples: this.timeSyncSamples.length,
      sentInputCount: this.sentInputCount,
      receivedMessageCount: this.receivedMessageCount,
      receivedAckCount: this.receivedAckCount,
      receivedRemoteSnapshotCount: this.receivedRemoteSnapshotCount,
      droppedSelfLoopSnapshotCount: this.droppedSelfLoopSnapshotCount,
      lastAckSeq: this.lastAckSeq,
      lastRemoteTickByCid: Object.fromEntries(this.lastRemoteTickByCid),
      receivedPlayerStateCount: this.receivedPlayerStateCount,
      lastPlayerState: this.lastPlayerState,
      lastTimeSyncOffsetMs: this.lastTimeSyncOffsetMs,
      lastError: this.lastError,
      bootstrapElapsedMs:
        this.bootstrapStartedAtMs === null
          ? null
          : Math.round(performance.now() - this.bootstrapStartedAtMs),
      phaseElapsedMs:
        this.phaseStartedAtMs === null
          ? null
          : Math.round(performance.now() - this.phaseStartedAtMs),
      lastAutoLoginDurationMs: this.lastAutoLoginDurationMs,
      lastReadyDurationMs: this.lastReadyDurationMs,
      blockedInputCount: this.blockedInputCount,
      lastBlockedInputReason: this.lastBlockedInputReason,
      lastBlockedInputSeq: this.lastBlockedInputSeq,
      authBaseUrl: this.authBaseUrl,
      webSocketUrl: this.webSocketUrl,
      voxel: this.voxelDebugSnapshot(),
    };
  }

  canUseServerVoxel(): boolean {
    return (
      this.connectionStatus === "connected" &&
      this.ready &&
      this.socket?.readyState === WebSocket.OPEN
    );
  }

  getAuthBaseUrl(): string {
    return this.authBaseUrl;
  }

  voxelDebugSnapshot(): Record<string, unknown> {
    return {
      available: this.canUseServerVoxel(),
      connectionStatus: this.connectionStatus,
      connectionPhase: this.connectionPhase,
      connectionLostReason: this.connectionLostReason,
      ready: this.ready,
      socketState: this.socket?.readyState ?? null,
      authBaseUrl: this.authBaseUrl,
      webSocketUrl: this.webSocketUrl,
      queuedSnapshots: this.voxelSnapshots.length,
      queuedIntentResults: this.voxelIntentResults.length,
      queuedDebugProbes: this.voxelDebugProbes.length,
      knownChunks: this.voxelKnownVersions.size,
      pendingPrefabRequests: this.pendingVoxelPrefabRequests.size,
      sentVoxelMessageCount: this.sentVoxelMessageCount,
      receivedVoxelSnapshotCount: this.receivedVoxelSnapshotCount,
      receivedVoxelDeltaCount: this.receivedVoxelDeltaCount,
      receivedVoxelInvalidateCount: this.receivedVoxelInvalidateCount,
      receivedVoxelIntentResultCount: this.receivedVoxelIntentResultCount,
      receivedVoxelDebugProbeCount: this.receivedVoxelDebugProbeCount,
      lastSnapshot: this.lastVoxelSnapshot
        ? {
            ...this.lastVoxelSnapshot,
            chunkCoord: chunkCoordKey(this.lastVoxelSnapshot.chunkCoord),
          }
        : null,
      lastDelta: this.lastVoxelDelta
        ? {
            ...this.lastVoxelDelta,
            chunkCoord: chunkCoordKey(this.lastVoxelDelta.chunkCoord),
          }
        : null,
      lastIntentResult: this.lastVoxelIntentResult,
      lastPrefabRequest: this.lastVoxelPrefabRequest,
      lastError: this.lastVoxelError,
      blockedSendCount: this.blockedVoxelSendCount,
      lastBlockedSend: this.lastBlockedVoxelSend,
    };
  }

  sendVoxelDebugProbe(command: string = "voxel_transport"): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("debug_probe");
    }

    const requestId = this.nextRequestId();
    this.socket.send(encodeVoxelDebugProbe(requestId, command));
    this.sentVoxelMessageCount += 1;
    this.logger.emit("voxel", "debug_probe_sent", {
      request_id: requestId,
      command,
      mode: this.mode,
    });
    return requestId;
  }

  sendVoxelChunkSubscribe(request: {
    logicalSceneId: number;
    centerChunk: FChunkCoord;
    radiusLInf?: number;
    wantSnapshot?: boolean;
    known?: readonly VoxelKnownChunk[];
  }): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("chunk_subscribe");
    }

    const requestId = this.nextRequestId();
    this.socket.send(
      encodeVoxelChunkSubscribe({
        requestId,
        logicalSceneId: request.logicalSceneId,
        centerChunk: request.centerChunk,
        radiusLInf: request.radiusLInf ?? 0,
        wantSnapshot: request.wantSnapshot ?? true,
        known: request.known ?? [],
      }),
    );
    this.sentVoxelMessageCount += 1;
    this.logger.emit("voxel", "chunk_subscribe_sent", {
      request_id: requestId,
      logical_scene_id: request.logicalSceneId,
      center_chunk: chunkCoordKey(request.centerChunk),
      radius_l_inf: request.radiusLInf ?? 0,
      want_snapshot: request.wantSnapshot ?? true,
      known_count: request.known?.length ?? 0,
    });
    return requestId;
  }

  sendVoxelChunkUnsubscribe(request: {
    logicalSceneId: number;
    chunks: readonly FChunkCoord[];
  }): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("chunk_unsubscribe");
    }

    const requestId = this.nextRequestId();
    this.socket.send(
      encodeVoxelChunkUnsubscribe({
        requestId,
        logicalSceneId: request.logicalSceneId,
        chunks: request.chunks,
      }),
    );
    this.sentVoxelMessageCount += 1;
    this.logger.emit("voxel", "chunk_unsubscribe_sent", {
      request_id: requestId,
      logical_scene_id: request.logicalSceneId,
      chunk_count: request.chunks.length,
    });
    return requestId;
  }

  sendVoxelImpactIntent(request: {
    logicalSceneId: number;
    sourceSkillId: number;
    targetWorldMicro: FMacroCoord;
    impactKind: number;
    clientIntentSeq: number;
    clientHintHash?: number;
  }): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("impact_intent");
    }

    const requestId = this.nextRequestId();
    this.socket.send(
      encodeVoxelImpactIntent({
        requestId,
        clientIntentSeq: request.clientIntentSeq,
        logicalSceneId: request.logicalSceneId,
        sourceSkillId: request.sourceSkillId,
        targetWorldMicro: request.targetWorldMicro,
        impactKind: request.impactKind,
        clientHintHash: request.clientHintHash ?? 0,
      }),
    );
    this.sentVoxelMessageCount += 1;
    this.logger.emit("voxel", "impact_intent_sent", {
      request_id: requestId,
      client_intent_seq: request.clientIntentSeq,
      logical_scene_id: request.logicalSceneId,
      target_world_micro: `${request.targetWorldMicro.x},${request.targetWorldMicro.y},${request.targetWorldMicro.z}`,
      impact_kind: request.impactKind,
    });
    return requestId;
  }

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
  }): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("edit_intent");
    }

    const requestId = this.nextRequestId();
    this.socket.send(
      encodeVoxelEditIntent({
        requestId: BigInt(requestId),
        clientIntentSeq: request.clientIntentSeq,
        logicalSceneId: BigInt(request.logicalSceneId),
        action: request.action,
        targetGranularity: request.targetGranularity,
        targetWorldMicro: {
          x: BigInt(request.targetWorldMicro.x),
          y: BigInt(request.targetWorldMicro.y),
          z: BigInt(request.targetWorldMicro.z),
        },
        faceNormal: request.faceNormal,
        materialId: request.materialId,
        blueprintRef: request.blueprintRef ?? 0,
        objectRef: request.objectRef ?? 0n,
        partRef: request.partRef ?? 0,
        attributePatchRef: request.attributePatchRef ?? 0,
        expectedChunkVersion: request.expectedChunkVersion ?? EXPECTED_CHUNK_VERSION_UNSPECIFIED,
        expectedCellHash: request.expectedCellHash ?? EXPECTED_CELL_HASH_UNSPECIFIED,
        clientHintHash: request.clientHintHash ?? 0n,
      }),
    );
    this.sentVoxelMessageCount += 1;
    this.logger.emit("voxel", "edit_intent_sent", {
      request_id: requestId,
      client_intent_seq: request.clientIntentSeq,
      logical_scene_id: request.logicalSceneId,
      action: request.action,
      target_granularity: request.targetGranularity,
      target_world_micro: `${request.targetWorldMicro.x},${request.targetWorldMicro.y},${request.targetWorldMicro.z}`,
      face_normal: `${request.faceNormal.x},${request.faceNormal.y},${request.faceNormal.z}`,
      material_id: request.materialId,
    });
    return requestId;
  }

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
  }): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("prefab_place_intent");
    }

    const requestId = this.nextRequestId();
    this.socket.send(
      encodeVoxelPrefabPlaceIntent({
        requestId,
        clientIntentSeq: request.clientIntentSeq,
        logicalSceneId: request.logicalSceneId,
        parcelId: request.parcelId,
        knownParcelBuildEpoch: request.knownParcelBuildEpoch,
        blueprintId: request.blueprintId,
        blueprintVersion: request.blueprintVersion,
        anchorWorldMicro: request.anchorWorldMicro,
        rotation: request.rotation,
        knownRefs: request.knownRefs ?? [],
        knownObjects: request.knownObjects ?? [],
        knownCellRefs: request.knownCellRefs ?? [],
        placementFlags: request.placementFlags ?? 0,
      }),
    );
    this.sentVoxelMessageCount += 1;
    this.pendingVoxelPrefabRequests.add(requestId);
    this.lastVoxelPrefabRequest = {
      requestId,
      clientIntentSeq: request.clientIntentSeq,
      logicalSceneId: request.logicalSceneId,
      blueprintId: request.blueprintId,
      blueprintVersion: request.blueprintVersion,
      rotation: request.rotation,
    };
    this.logger.emit("voxel", "prefab_place_intent_sent", {
      request_id: requestId,
      client_intent_seq: request.clientIntentSeq,
      logical_scene_id: request.logicalSceneId,
      blueprint_id: request.blueprintId,
      blueprint_version: request.blueprintVersion,
      anchor_world_micro: `${request.anchorWorldMicro.x},${request.anchorWorldMicro.y},${request.anchorWorldMicro.z}`,
      rotation: request.rotation,
    });
    return requestId;
  }

  drainVoxelSnapshots(): VoxelChunkSnapshotMessage[] {
    return this.voxelSnapshots.splice(0, this.voxelSnapshots.length);
  }

  drainVoxelDeltas(): VoxelChunkDeltaMessage[] {
    return this.voxelDeltas.splice(0, this.voxelDeltas.length);
  }

  drainVoxelInvalidates(): VoxelChunkInvalidateMessage[] {
    return this.voxelInvalidates.splice(0, this.voxelInvalidates.length);
  }

  drainVoxelIntentResults(): VoxelIntentResultMessage[] {
    return this.voxelIntentResults.splice(0, this.voxelIntentResults.length);
  }

  drainVoxelDebugProbes(): VoxelDebugProbeMessage[] {
    return this.voxelDebugProbes.splice(0, this.voxelDebugProbes.length);
  }

  drainVoxelObjectStateDeltas(): VoxelObjectStateDeltaMessage[] {
    return this.voxelObjectStateDeltas.splice(0, this.voxelObjectStateDeltas.length);
  }

  reset(position: Vector3): void {
    this.lastResetPosition.copy(position);
    this.acknowledgements.splice(0, this.acknowledgements.length);
    this.remoteSnapshots.splice(0, this.remoteSnapshots.length);
    this.remoteEntityEnters.splice(0, this.remoteEntityEnters.length);
    this.remoteEntityLeaves.splice(0, this.remoteEntityLeaves.length);
    this.timeSyncSamples.splice(0, this.timeSyncSamples.length);
    this.voxelSnapshots.splice(0, this.voxelSnapshots.length);
    this.voxelIntentResults.splice(0, this.voxelIntentResults.length);
    this.voxelDebugProbes.splice(0, this.voxelDebugProbes.length);
    this.voxelObjectStateDeltas.splice(0, this.voxelObjectStateDeltas.length);
    this.pendingVoxelPrefabRequests.clear();
    this.lastPlayerState = null;
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;
  }

  sendInput(frame: MoveInputFrame, nowMs: number): void {
    if (!this.isReady() || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      this.recordBlockedInput(frame, nowMs, this.unavailableReason());
      return;
    }

    this.socket.send(encodeMovementInput(frame));
    this.sentAtBySeq.set(frame.seq, nowMs);
    this.sentInputCount += 1;
    this.logger.emit("transport", "movement_sent", {
      seq: frame.seq,
      tick: frame.clientTick,
      mode: this.mode,
    });
  }

  tick(_nowMs: number, _dtMs: number): MovementTransportTickResult {
    const acknowledgements = this.acknowledgements.splice(0, this.acknowledgements.length);
    const remoteSnapshots = this.remoteSnapshots.splice(0, this.remoteSnapshots.length);
    const remoteEntityEnters = this.remoteEntityEnters.splice(0, this.remoteEntityEnters.length);
    const remoteEntityLeaves = this.remoteEntityLeaves.splice(0, this.remoteEntityLeaves.length);
    const timeSyncSamples = this.timeSyncSamples.splice(0, this.timeSyncSamples.length);
    const spawn =
      this.spawnPosition && this.spawnExpectedSeq !== null
        ? {
            position: this.spawnPosition,
            expectedSeq: this.spawnExpectedSeq,
          }
        : null;
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;
    return {
      acknowledgements,
      remoteSnapshots,
      spawn,
      remoteEntityEnters,
      remoteEntityLeaves,
      timeSyncSamples,
    };
  }

  private async bootstrap(): Promise<void> {
    if (this.connecting) {
      return;
    }

    this.connecting = true;
    this.connectionStatus = "connecting";
    this.connectionPhase = "auto_login";
    this.bootstrapStartedAtMs = performance.now();
    this.phaseStartedAtMs = this.bootstrapStartedAtMs;
    this.lastAutoLoginDurationMs = null;
    this.lastReadyDurationMs = null;
    this.connectionLostReason = null;
    this.logger.emit("transport", "bootstrap_start", {
      mode: SERVER_TRANSPORT_MODE,
      url: this.webSocketUrl,
      auth_base_url: this.authBaseUrl || "(vite /ingame proxy)",
    });

    try {
      const login = await this.autoLogin();
      this.token = login.token;
      this.cid = login.cid;
      this.username = login.username;
      this.connectionPhase = "socket_connect";
      this.phaseStartedAtMs = performance.now();
      this.openSocket();
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown";
      this.lastError = reason;
      this.logger.emit("transport", "bootstrap_error", {
        mode: SERVER_TRANSPORT_MODE,
        reason,
      });
      this.markDisconnected(`bootstrap_error:${reason}`);
    }
  }

  private async autoLogin(): Promise<AutoLoginResponse> {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), AUTO_LOGIN_TIMEOUT_MS);
    const startedAtMs = performance.now();
    let response: Response;

    try {
      response = await fetch(`${this.authBaseUrl}/ingame/auto_login`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ username: this.username }),
        signal: controller.signal,
      });
    } catch (error) {
      if (isAbortError(error)) {
        throw new Error(`auto_login_timeout:${AUTO_LOGIN_TIMEOUT_MS}ms`);
      }
      throw error;
    } finally {
      window.clearTimeout(timer);
    }

    if (!response.ok) {
      throw new Error(`auto_login_failed:${response.status}`);
    }

    const login = (await response.json()) as AutoLoginResponse;
    this.lastAutoLoginDurationMs = Math.round(performance.now() - startedAtMs);
    this.logger.emit("transport", "auto_login_ok", {
      mode: SERVER_TRANSPORT_MODE,
      duration_ms: this.lastAutoLoginDurationMs,
      cid: login.cid,
    });
    return login;
  }

  private openSocket(): void {
    const socket = new WebSocket(this.webSocketUrl);
    socket.binaryType = "arraybuffer";
    socket.onopen = () => this.handleOpen(socket);
    socket.onmessage = (event) => this.handleMessage(event.data);
    socket.onerror = () => {
      this.lastError = "socket_error";
      this.logger.emit("transport", "socket_error", { mode: SERVER_TRANSPORT_MODE });
    };
    socket.onclose = (event) => {
      this.ready = false;
      this.connecting = false;
      this.clearHeartbeat();
      this.logger.emit("transport", "socket_closed", {
        mode: SERVER_TRANSPORT_MODE,
        code: event.code,
        reason: event.reason || "closed",
      });
      this.markDisconnected(`socket_closed:${event.code}:${event.reason || "closed"}`);
    };
    this.socket = socket;
    this.startHandshakeTimer("socket_connect");
  }

  private handleOpen(socket: WebSocket): void {
    if (!this.token) {
      return;
    }

    this.connecting = false;
    this.connectionPhase = "auth_request";
    this.phaseStartedAtMs = performance.now();
    this.startHandshakeTimer("auth_request");
    this.authRequestId = this.nextRequestId();
    socket.send(encodeAuthRequest(this.authRequestId, this.username, this.token));
    this.logger.emit("transport", "socket_open", {
      mode: SERVER_TRANSPORT_MODE,
      auth_request_id: this.authRequestId,
    });
    this.heartbeatTimer = window.setInterval(() => {
      if (this.socket?.readyState === WebSocket.OPEN) {
        this.socket.send(encodeHeartbeat(Date.now()));
      }
    }, 10_000);
  }

  private handleMessage(data: unknown): void {
    if (!(data instanceof ArrayBuffer)) {
      return;
    }

    this.receivedMessageCount += 1;
    const message = decodeServerMessage(data);
    if (!message) {
      if (this.handleVoxelMessage(data)) {
        return;
      }

      const opcode = data.byteLength > 0 ? new DataView(data).getUint8(0) : null;
      this.lastError = `message_ignored:${opcode === null ? "empty" : `0x${opcode.toString(16)}`}:${data.byteLength}`;
      this.logger.emit("transport", "message_ignored", {
        mode: SERVER_TRANSPORT_MODE,
        opcode: opcode ?? -1,
        bytes: data.byteLength,
      });
      return;
    }

    switch (message.type) {
      case "auth_ok":
        if (message.requestId === this.authRequestId && this.socket && this.cid !== null) {
          this.connectionPhase = "enter_scene";
          this.phaseStartedAtMs = performance.now();
          this.startHandshakeTimer("enter_scene");
          this.enterSceneRequestId = this.nextRequestId();
          this.socket.send(encodeEnterScene(this.enterSceneRequestId, this.cid));
          this.logger.emit("transport", "auth_ok", {
            mode: SERVER_TRANSPORT_MODE,
            cid: this.cid,
            enter_scene_request_id: this.enterSceneRequestId,
          });
        }
        break;
      case "enter_scene_ok":
        if (message.requestId === this.enterSceneRequestId) {
          this.ready = true;
          this.connectionStatus = "connected";
          this.connectionPhase = "ready";
          this.phaseStartedAtMs = performance.now();
          this.lastReadyDurationMs =
            this.bootstrapStartedAtMs === null
              ? null
              : Math.round(this.phaseStartedAtMs - this.bootstrapStartedAtMs);
          this.connectionLostReason = null;
          this.clearHandshakeTimer();
          this.spawnPosition = message.position;
          this.spawnExpectedSeq = message.expectedSeq;
          this.logger.emit("transport", "enter_scene_ok", {
            mode: SERVER_TRANSPORT_MODE,
            position: `${message.position.x.toFixed(1)},${message.position.y.toFixed(1)},${message.position.z.toFixed(1)}`,
            expected_seq: message.expectedSeq,
            ready_ms: this.lastReadyDurationMs ?? -1,
          });
        }
        break;
      case "enter_scene_error":
        this.logger.emit("transport", "enter_scene_error", {
          mode: SERVER_TRANSPORT_MODE,
          request_id: message.requestId,
        });
        this.markDisconnected(`enter_scene_error:${message.requestId}`);
        break;
      case "movement_ack":
        this.acknowledgements.push({
          ack: message.ack,
          sentAtMs: this.sentAtBySeq.get(message.ack.ackSeq) ?? performance.now(),
        });
        this.sentAtBySeq.delete(message.ack.ackSeq);
        this.receivedAckCount += 1;
        this.lastAckSeq = message.ack.ackSeq;
        break;
      case "player_move":
        // Defense-in-depth: AOI broadcast on the server side is supposed to
        // exclude the moving player itself (Octree.get_in_bound_except), but
        // if that filter ever fails — or if a same-cid actor (NPC reusing a
        // player cid, double-bound connection, etc.) leaks one through —
        // the client would create a "remote" mesh keyed by its own cid and
        // happily update it from every self-move snapshot, producing the
        // "remote cube follows me" symptom. Drop the snapshot here and emit
        // a structured observe so we can see post-mortem if the server is
        // actually self-looping.
        if (this.cid !== null && message.snapshot.cid === this.cid) {
          this.droppedSelfLoopSnapshotCount += 1;
          this.logger.emit("transport", "remote_snapshot_self_loop_dropped", {
            mode: SERVER_TRANSPORT_MODE,
            cid: this.cid,
            tick: message.snapshot.serverTick,
            dropped_count: this.droppedSelfLoopSnapshotCount,
          });
          break;
        }

        this.remoteSnapshots.push(message.snapshot);
        this.receivedRemoteSnapshotCount += 1;
        this.lastRemoteTickByCid.set(message.snapshot.cid, message.snapshot.serverTick);
        this.logger.emit("transport", "remote_snapshot_received", {
          mode: SERVER_TRANSPORT_MODE,
          cid: message.snapshot.cid,
          tick: message.snapshot.serverTick,
          priority_band: message.snapshot.priorityBand ?? "unknown",
          priority_score: message.snapshot.priorityScore ?? -1,
          observer_distance: message.snapshot.observerDistance ?? -1,
          delivery_interval: message.snapshot.deliveryInterval ?? -1,
        });
        break;
      case "player_enter":
        if (this.cid !== null && message.cid === this.cid) {
          this.droppedSelfLoopSnapshotCount += 1;
          this.logger.emit("transport", "remote_enter_self_loop_dropped", {
            mode: SERVER_TRANSPORT_MODE,
            cid: this.cid,
            dropped_count: this.droppedSelfLoopSnapshotCount,
          });
          break;
        }
        this.remoteEntityEnters.push({ cid: message.cid, position: message.position });
        break;
      case "player_leave":
        if (this.cid !== null && message.cid === this.cid) {
          this.droppedSelfLoopSnapshotCount += 1;
          this.logger.emit("transport", "remote_leave_self_loop_dropped", {
            mode: SERVER_TRANSPORT_MODE,
            cid: this.cid,
            dropped_count: this.droppedSelfLoopSnapshotCount,
          });
          break;
        }
        this.remoteEntityLeaves.push(message.cid);
        break;
      case "time_sync_reply":
        this.timeSyncSamples.push({
          requestId: message.requestId,
          clientSendTs: message.clientSendTs,
          serverRecvTs: message.serverRecvTs,
          serverSendTs: message.serverSendTs,
        });
        this.lastTimeSyncOffsetMs = (message.serverRecvTs + message.serverSendTs) / 2 - Date.now();
        break;
      case "heartbeat_reply":
        this.logger.emit("transport", "heartbeat_reply", { mode: SERVER_TRANSPORT_MODE });
        break;
      case "player_state":
        this.receivedPlayerStateCount += 1;
        this.lastPlayerState = {
          cid: message.cid,
          hp: message.hp,
          maxHp: message.maxHp,
          alive: message.alive,
        };
        this.logger.emit("transport", "player_state_received", {
          mode: SERVER_TRANSPORT_MODE,
          cid: message.cid,
          hp: message.hp,
          max_hp: message.maxHp,
          alive: message.alive,
          received_count: this.receivedPlayerStateCount,
        });
        break;
      case "known_unhandled_downlink":
        this.logger.emit("transport", "known_downlink_unhandled", {
          mode: SERVER_TRANSPORT_MODE,
          opcode: `0x${message.opcode.toString(16)}`,
          name: message.name,
          bytes: message.byteLength,
        });
        break;
    }
  }

  private handleVoxelMessage(data: ArrayBuffer): boolean {
    let message:
      | VoxelChunkSnapshotMessage
      | VoxelChunkDeltaMessage
      | VoxelChunkInvalidateMessage
      | VoxelIntentResultMessage
      | VoxelDebugProbeMessage
      | VoxelObjectStateDeltaMessage
      | null = null;
    try {
      message = decodeVoxelServerMessage(data);
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown";
      this.lastVoxelError = reason;
      this.logger.emit("voxel", "message_decode_error", {
        mode: SERVER_TRANSPORT_MODE,
        bytes: data.byteLength,
        reason,
      });
      return true;
    }

    if (!message) {
      return false;
    }

    switch (message.type) {
      case "voxel_chunk_snapshot":
        this.voxelSnapshots.push(message);
        this.receivedVoxelSnapshotCount += 1;
        this.voxelKnownVersions.set(chunkCoordKey(message.chunkCoord), message.chunkVersion);
        this.lastVoxelSnapshot = {
          requestId: message.requestId,
          logicalSceneId: message.logicalSceneId,
          chunkCoord: { ...message.chunkCoord },
          chunkVersion: message.chunkVersion,
          chunkHash: message.chunkHash,
        };
        this.logger.emit("voxel", "chunk_snapshot_received", {
          request_id: message.requestId,
          logical_scene_id: message.logicalSceneId,
          chunk_coord: chunkCoordKey(message.chunkCoord),
          chunk_version: message.chunkVersion,
          chunk_hash: message.chunkHash,
          normal_blocks: message.storage.normalBlocks.length,
        });
        return true;
      case "voxel_chunk_delta":
        this.voxelDeltas.push(message);
        this.receivedVoxelDeltaCount += 1;
        this.voxelKnownVersions.set(chunkCoordKey(message.chunkCoord), message.newChunkVersion);
        this.lastVoxelDelta = {
          logicalSceneId: message.logicalSceneId,
          chunkCoord: { ...message.chunkCoord },
          baseChunkVersion: message.baseChunkVersion,
          newChunkVersion: message.newChunkVersion,
          opCount: message.ops.length,
        };
        this.logger.emit("voxel", "chunk_delta_received", {
          mode: SERVER_TRANSPORT_MODE,
          logical_scene_id: message.logicalSceneId,
          chunk_coord: chunkCoordKey(message.chunkCoord),
          base_chunk_version: message.baseChunkVersion,
          new_chunk_version: message.newChunkVersion,
          op_count: message.ops.length,
        });
        return true;
      case "voxel_chunk_invalidate":
        this.voxelInvalidates.push(message);
        this.receivedVoxelInvalidateCount += 1;
        this.voxelKnownVersions.delete(chunkCoordKey(message.chunkCoord));
        this.logger.emit("voxel", "chunk_invalidate_received", {
          mode: SERVER_TRANSPORT_MODE,
          logical_scene_id: message.logicalSceneId,
          chunk_coord: chunkCoordKey(message.chunkCoord),
          reason: message.reasonName,
        });
        return true;
      case "voxel_intent_result":
        this.voxelIntentResults.push(message);
        this.receivedVoxelIntentResultCount += 1;
        this.pendingVoxelPrefabRequests.delete(message.requestId);
        this.lastVoxelIntentResult = {
          requestId: message.requestId,
          clientIntentSeq: message.clientIntentSeq,
          logicalSceneId: message.logicalSceneId,
          resultCodeName: message.resultCodeName,
          resultRef: message.resultRef,
          reason: message.reason,
        };
        this.logger.emit("voxel", "intent_result_received", {
          request_id: message.requestId,
          client_intent_seq: message.clientIntentSeq,
          logical_scene_id: message.logicalSceneId,
          result_code: message.resultCodeName,
          result_ref: message.resultRef,
          reason: message.reason,
        });
        return true;
      case "voxel_debug_probe":
        this.voxelDebugProbes.push(message);
        this.receivedVoxelDebugProbeCount += 1;
        this.logger.emit("voxel", "debug_probe_received", {
          request_id: message.requestId,
          result: message.result.slice(0, 240),
        });
        return true;
      case "voxel_object_state_delta":
        this.voxelObjectStateDeltas.push(message);
        this.receivedVoxelObjectStateDeltaCount += 1;
        this.logger.emit("voxel", "object_state_delta_received", {
          mode: SERVER_TRANSPORT_MODE,
          object_id: message.delta.objectId.toString(),
          object_version: message.delta.objectVersion.toString(),
          state_flags: `0x${message.delta.stateFlags.toString(16)}`,
          affected_chunk_count: message.delta.affectedChunks.length,
        });
        return true;
    }
  }

  private unavailableReason(): string {
    if (this.connectionStatus !== "connected") {
      return this.connectionLostReason
        ? `${this.connectionStatus}:${this.connectionLostReason}`
        : this.connectionStatus;
    }

    if (!this.ready) {
      return "not_ready";
    }

    if (!this.socket) {
      return "socket_missing";
    }

    if (this.socket.readyState !== WebSocket.OPEN) {
      return `socket_state_${this.socket.readyState}`;
    }

    return "unknown";
  }

  private recordBlockedInput(frame: MoveInputFrame, nowMs: number, reason: string): void {
    this.blockedInputCount += 1;
    this.lastBlockedInputReason = reason;
    this.lastBlockedInputSeq = frame.seq;

    if (nowMs - this.lastBlockedInputLogAtMs < 1_000) {
      return;
    }

    this.lastBlockedInputLogAtMs = nowMs;
    this.logger.emit("transport", "movement_input_blocked", {
      mode: SERVER_TRANSPORT_MODE,
      reason,
      seq: frame.seq,
      tick: frame.clientTick,
      blocked_count: this.blockedInputCount,
      connection_status: this.connectionStatus,
      connection_lost_reason: this.connectionLostReason ?? "",
      socket_state: this.socket?.readyState ?? -1,
    });
  }

  private blockVoxelSend(source: string): null {
    const reason = this.unavailableReason();
    this.blockedVoxelSendCount += 1;
    this.lastBlockedVoxelSend = { source, reason };
    this.lastVoxelError = `${source}_blocked:${reason}`;
    this.logger.emit("voxel", "send_blocked", {
      source,
      reason,
      blocked_count: this.blockedVoxelSendCount,
      connection_status: this.connectionStatus,
      connection_lost_reason: this.connectionLostReason ?? "",
      socket_state: this.socket?.readyState ?? -1,
    });
    return null;
  }

  private nextRequestId(): number {
    const current = this.requestId;
    this.requestId += 1;
    return current;
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer !== null) {
      window.clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private startHandshakeTimer(phase: ConnectionPhase): void {
    this.clearHandshakeTimer();
    this.handshakeTimer = window.setTimeout(() => {
      this.markDisconnected(`${phase}_timeout:${HANDSHAKE_TIMEOUT_MS}ms`);
    }, HANDSHAKE_TIMEOUT_MS);
  }

  private clearHandshakeTimer(): void {
    if (this.handshakeTimer !== null) {
      window.clearTimeout(this.handshakeTimer);
      this.handshakeTimer = null;
    }
  }

  private markDisconnected(reason: string): void {
    if (this.connectionStatus === "disconnected") {
      return;
    }

    this.ready = false;
    this.connecting = false;
    this.clearHeartbeat();
    this.clearHandshakeTimer();
    this.clearPendingMessages();

    if (this.socket) {
      this.socket.onopen = null;
      this.socket.onmessage = null;
      this.socket.onerror = null;
      this.socket.onclose = null;

      if (
        this.socket.readyState === WebSocket.OPEN ||
        this.socket.readyState === WebSocket.CONNECTING
      ) {
        try {
          this.socket.close(1000, "transport_disconnect");
        } catch {
          // Ignore close failures while cleaning up.
        }
      }
    }

    this.socket = null;
    this.connectionStatus = "disconnected";
    this.connectionPhase = "disconnected";
    this.connectionLostReason = reason;
    this.logger.emit("transport", "connection_lost", {
      mode: SERVER_TRANSPORT_MODE,
      reason,
    });
  }

  private clearPendingMessages(): void {
    this.acknowledgements.splice(0, this.acknowledgements.length);
    this.remoteSnapshots.splice(0, this.remoteSnapshots.length);
    this.remoteEntityEnters.splice(0, this.remoteEntityEnters.length);
    this.remoteEntityLeaves.splice(0, this.remoteEntityLeaves.length);
    this.timeSyncSamples.splice(0, this.timeSyncSamples.length);
    this.voxelSnapshots.splice(0, this.voxelSnapshots.length);
    this.voxelIntentResults.splice(0, this.voxelIntentResults.length);
    this.voxelDebugProbes.splice(0, this.voxelDebugProbes.length);
    this.voxelObjectStateDeltas.splice(0, this.voxelObjectStateDeltas.length);
    this.pendingVoxelPrefabRequests.clear();
    this.sentAtBySeq.clear();
    this.lastPlayerState = null;
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;
  }
}

export function resolveDefaultUsername(
  env: Record<string, string | undefined> = import.meta.env,
  // `storage` is kept for API compatibility but no longer used. See
  // the rationale block below.
  _storage: Storage | null = null,
): string {
  const configured = firstNonBlank(env.VITE_GAME_CLIENT_USERNAME, env.VITE_GAME_USERNAME);
  if (configured) {
    return configured;
  }

  // Phase A4-bis follow-up: dev `auth_server.AuthServer.Accounts.upsert_dev/1`
  // maps `username → cid` deterministically (same name returns same cid).
  // Earlier versions persisted a generated username in `sessionStorage`,
  // but Chrome COPIES `sessionStorage` when a tab is duplicated or when a
  // link is opened with "Open in new tab" — both common ways to launch
  // multiple game windows for multiplayer testing. Two tabs sharing
  // `sessionStorage` ⇒ two tabs share the same cid ⇒ the server treats
  // them as a single player, which manifests on the client as "remote
  // player cube follows me", "characters disappear", and "wrong remote
  // position" all at once.
  //
  // Generate a fresh username per page load instead. Each tab — duplicated
  // or not — gets its own cid. This costs us username-stability across
  // refresh, which is fine for dev demos; production logins go through
  // a real auth flow that overrides this default.
  return generateFreshUsername();
}

function generateFreshUsername(): string {
  const cryptoRef: Crypto | undefined = typeof crypto !== "undefined" ? crypto : undefined;
  if (cryptoRef && typeof cryptoRef.randomUUID === "function") {
    return `web_${cryptoRef.randomUUID().slice(0, 8)}`;
  }
  return `web_${Math.random().toString(36).slice(2, 10)}`;
}

export function resolveAuthBaseUrl(
  env: Record<string, string | undefined> = import.meta.env,
  _location: Pick<Location, "protocol" | "host" | "origin"> = window.location,
): string {
  return firstNonBlank(env.VITE_GAME_AUTH_BASE_URL, env.VITE_AUTH_BASE_URL) ?? "";
}

export function resolveGameWsUrl(
  env: Record<string, string | undefined> = import.meta.env,
  location: Pick<Location, "protocol" | "host" | "origin"> = window.location,
): string {
  const configured = firstNonBlank(env.VITE_GAME_WS_URL, env.VITE_WS_URL);
  if (configured) {
    return configured;
  }

  const authBaseUrl = resolveAuthBaseUrl(env, location);
  if (authBaseUrl === "") {
    const wsProtocol = location.protocol === "https:" ? "wss:" : "ws:";
    return `${wsProtocol}//${location.host}/ingame/ws`;
  }

  const url = new URL(authBaseUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/ingame/ws";
  url.search = "";
  url.hash = "";
  return url.toString();
}

function firstNonBlank(...values: Array<string | undefined>): string | null {
  for (const value of values) {
    if (value && value.trim() !== "") {
      return value;
    }
  }
  return null;
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}
