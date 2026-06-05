import { Vector3 } from "three";
import {
  encodeAuthRequest,
  decodeServerMessage,
  encodeChatSayScoped,
  encodeEnterScene,
  encodeHeartbeat,
  encodeMovementInput,
  encodeTimeSync,
} from "./gateProtocol";
import { PROTOCOL_VERSION } from "./protocolVersion";
import {
  decodeVoxelServerMessage,
  type VoxelCatalogPatchMessage,
  type VoxelChunkDeltaMessage,
  type VoxelChunkInvalidateMessage,
  encodeVoxelChunkAck,
  encodeVoxelChunkSubscribe,
  encodeVoxelChunkUnsubscribe,
  encodeVoxelDebugProbe,
  encodeVoxelFieldConductIntent,
  encodeVoxelImpactIntent,
  encodeVoxelPrefabPlaceIntent,
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
} from "./voxelProtocol";
import {
  encodeVoxelEditIntent,
  EXPECTED_CELL_HASH_UNSPECIFIED,
  EXPECTED_CHUNK_VERSION_UNSPECIFIED,
} from "./voxelEditIntent";
import type { ObserveLog } from "../../observe/logger";
import type { ChatMessage, ChatScope } from "@domain/chat/types";
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
const DEFAULT_AUTO_LOGIN_TIMEOUT_MS = 15_000;
const MIN_AUTO_LOGIN_TIMEOUT_MS = 1_000;
const DEFAULT_HANDSHAKE_TIMEOUT_MS = 20_000;
const MIN_HANDSHAKE_TIMEOUT_MS = 1_000;
const TIME_SYNC_INTERVAL_MS = 1_000;
const RECONNECT_INITIAL_DELAY_MS = 1_000;
const RECONNECT_MAX_DELAY_MS = 15_000;
const MAX_PENDING_VOXEL_CONTROL_REQUESTS = 512;

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
  private readonly chatMessages: ChatMessage[] = [];
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
  private readonly voxelFieldSnapshots: VoxelFieldRegionSnapshotMessage[] = [];
  private readonly voxelFieldDestroyeds: VoxelFieldRegionDestroyedMessage[] = [];
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
  private receivedResultErrorCount = 0;
  private lastResultError: {
    requestId: number;
    phase: ConnectionPhase;
    inFlightMovement: boolean;
  } | null = null;
  private receivedRemoteSnapshotCount = 0;
  private droppedSelfLoopSnapshotCount = 0;
  private lastAckSeq: number | null = null;
  private highestSentSeq: number | null = null;
  private lastAckReceivedAtMs: number | null = null;
  private lastAckDiagnostics: Record<string, unknown> | null = null;
  private lastRemoteTickByCid = new Map<number, number>();
  private receivedPlayerStateCount = 0;
  private lastPlayerState: { cid: number; hp: number; maxHp: number; alive: boolean } | null = null;
  private sentChatMessageCount = 0;
  private receivedChatMessageCount = 0;
  private lastChatSend: { requestId: number; scope: ChatScope; textLength: number } | null = null;
  private readonly pendingChatRequests = new Map<
    number,
    { scope: ChatScope; textLength: number }
  >();
  private lastAcceptedChatSend: { requestId: number; scope: ChatScope } | null = null;
  private lastChatMessage: ChatMessage | null = null;
  private blockedChatSendCount = 0;
  private lastBlockedChatSend: { scope: ChatScope; reason: string } | null = null;
  private lastTimeSyncOffsetMs: number | null = null;
  private lastTimeSyncSentAtMs = Number.NEGATIVE_INFINITY;
  private lastError: string | null = null;
  private blockedInputCount = 0;
  private lastBlockedInputReason: string | null = null;
  private lastBlockedInputSeq: number | null = null;
  private lastBlockedInputLogAtMs = Number.NEGATIVE_INFINITY;
  private bootstrapStartedAtMs: number | null = null;
  private phaseStartedAtMs: number | null = null;
  private lastAutoLoginDurationMs: number | null = null;
  private lastReadyDurationMs: number | null = null;
  private lastTickAtMs = 0;
  private reconnectAttemptCount = 0;
  private nextReconnectAtMs = Number.POSITIVE_INFINITY;
  private sentVoxelMessageCount = 0;
  private sentVoxelChunkAckCount = 0;
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
  private lastVoxelChunkAck: {
    requestId: number;
    logicalSceneId: number;
    ackCount: number;
    acks: string[];
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
  private readonly pendingVoxelControlRequests = new Map<number, string>();
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
    private readonly autoLoginTimeoutMs: number = resolveAutoLoginTimeoutMs(),
    private readonly handshakeTimeoutMs: number = resolveHandshakeTimeoutMs(),
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
      receivedResultErrorCount: this.receivedResultErrorCount,
      lastResultError: this.lastResultError,
      receivedRemoteSnapshotCount: this.receivedRemoteSnapshotCount,
      droppedSelfLoopSnapshotCount: this.droppedSelfLoopSnapshotCount,
      lastAckSeq: this.lastAckSeq,
      movement: this.movementDebugSnapshot(),
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
      reconnectAttemptCount: this.reconnectAttemptCount,
      nextReconnectInMs:
        this.connectionStatus === "disconnected" && Number.isFinite(this.nextReconnectAtMs)
          ? Math.max(0, Math.round(this.nextReconnectAtMs - this.lastTickAtMs))
          : null,
      blockedInputCount: this.blockedInputCount,
      lastBlockedInputReason: this.lastBlockedInputReason,
      lastBlockedInputSeq: this.lastBlockedInputSeq,
      chat: this.chatDebugSnapshot(),
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

  chatDebugSnapshot(): Record<string, unknown> {
    return {
      available: this.canUseServerChat(),
      queuedMessages: this.chatMessages.length,
      sentChatMessageCount: this.sentChatMessageCount,
      receivedChatMessageCount: this.receivedChatMessageCount,
      lastSend: this.lastChatSend,
      pendingSends: this.pendingChatRequests.size,
      lastAccepted: this.lastAcceptedChatSend,
      lastMessage: this.lastChatMessage,
      blockedSendCount: this.blockedChatSendCount,
      lastBlockedSend: this.lastBlockedChatSend,
    };
  }

  private movementDebugSnapshot(): Record<string, unknown> {
    const inFlightSeqs = [...this.sentAtBySeq.keys()];
    const oldestUnackedSeq = inFlightSeqs.length > 0 ? Math.min(...inFlightSeqs) : null;
    const clientInputSeqGap =
      this.highestSentSeq !== null && this.lastAckSeq !== null
        ? Math.max(0, this.highestSentSeq - this.lastAckSeq)
        : null;
    return {
      highestSentSeq: this.highestSentSeq,
      oldestUnackedSeq,
      pendingMoveCount: this.sentAtBySeq.size,
      clientInputSeqGap,
      wsBufferedAmount: this.socket?.bufferedAmount ?? null,
      queuedAcks: this.acknowledgements.length,
      lastAckSeq: this.lastAckSeq,
      lastAckReceivedAgeMs:
        this.lastAckReceivedAtMs === null
          ? null
          : Math.max(0, Math.round(performance.now() - this.lastAckReceivedAtMs)),
      lastAckDiagnostics: this.lastAckDiagnostics,
    };
  }

  sendChat(scope: ChatScope, text: string): number | null {
    const normalizedText = text.trim();
    if (normalizedText.length === 0) {
      return this.blockChatSend(scope, "empty_text");
    }

    if (!this.canUseServerChat() || !this.socket) {
      return this.blockChatSend(scope, this.unavailableReason());
    }

    const requestId = this.nextRequestId();
    const encoded = encodeChatSayScoped(requestId, scope, normalizedText);
    this.socket.send(encoded);
    this.sentChatMessageCount += 1;
    this.lastChatSend = {
      requestId,
      scope,
      textLength: encoded.byteLength - (1 + 8 + 1 + 2),
    };
    this.pendingChatRequests.set(requestId, {
      scope,
      textLength: this.lastChatSend.textLength,
    });
    this.logger.emit("chat", "chat_scoped_sent", {
      mode: this.mode,
      request_id: requestId,
      scope,
      text_length: this.lastChatSend.textLength,
    });
    return requestId;
  }

  drainChatMessages(): ChatMessage[] {
    return this.chatMessages.splice(0, this.chatMessages.length);
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
      pendingControlRequests: this.pendingVoxelControlRequests.size,
      sentVoxelMessageCount: this.sentVoxelMessageCount,
      sentVoxelChunkAckCount: this.sentVoxelChunkAckCount,
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
      lastChunkAck: this.lastVoxelChunkAck,
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
    this.rememberVoxelControlRequest(requestId, "debug_probe");
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
    this.rememberVoxelControlRequest(requestId, "chunk_subscribe");
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
    this.rememberVoxelControlRequest(requestId, "chunk_unsubscribe");
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

  sendVoxelChunkAck(request: {
    logicalSceneId: number;
    acks: readonly VoxelKnownChunk[];
  }): number | null {
    if (request.acks.length === 0) {
      this.lastVoxelError = "chunk_ack_empty";
      return null;
    }

    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("chunk_ack");
    }

    const requestId = this.nextRequestId();
    this.rememberVoxelControlRequest(requestId, "chunk_ack");
    this.socket.send(
      encodeVoxelChunkAck({
        requestId,
        logicalSceneId: request.logicalSceneId,
        acks: request.acks,
      }),
    );
    this.sentVoxelMessageCount += 1;
    this.sentVoxelChunkAckCount += 1;
    this.lastVoxelChunkAck = {
      requestId,
      logicalSceneId: request.logicalSceneId,
      ackCount: request.acks.length,
      acks: request.acks.map((ack) => `${chunkCoordKey(ack.chunkCoord)}@${ack.chunkVersion}`),
    };
    this.logger.emit("voxel", "chunk_ack_sent", {
      request_id: requestId,
      logical_scene_id: request.logicalSceneId,
      ack_count: request.acks.length,
      chunks: JSON.stringify(
        request.acks.map((ack) => `${chunkCoordKey(ack.chunkCoord)}@${ack.chunkVersion}`),
      ),
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

  sendVoxelFieldConductIntent(request: {
    logicalSceneId: number;
    sourceWorldMacro: FMacroCoord;
    targetWorldMacro: FMacroCoord;
    sourcePotential: number;
    maxTicks: number;
    conductionMode?: "conductive" | "discharge";
    outputMode?: "dc" | "ac" | "pulse";
    voltage?: number;
    currentLimitAmps?: number;
    frequencyHz?: number;
    loadCurrentAmps?: number;
    energyBudgetJoules?: number;
    clientIntentSeq: number;
  }): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      return this.blockVoxelSend("field_conduct_intent");
    }

    const requestId = this.nextRequestId();
    const fieldRequest: Parameters<typeof encodeVoxelFieldConductIntent>[0] = {
      requestId,
      clientIntentSeq: request.clientIntentSeq,
      logicalSceneId: request.logicalSceneId,
      sourceWorldMacro: request.sourceWorldMacro,
      targetWorldMacro: request.targetWorldMacro,
      sourcePotential: request.sourcePotential,
      maxTicks: request.maxTicks,
    };
    if (request.conductionMode !== undefined) {
      fieldRequest.conductionMode = request.conductionMode;
    }
    if (request.outputMode !== undefined) {
      fieldRequest.outputMode = request.outputMode;
    }
    if (request.voltage !== undefined) {
      fieldRequest.voltage = request.voltage;
    }
    if (request.currentLimitAmps !== undefined) {
      fieldRequest.currentLimitAmps = request.currentLimitAmps;
    }
    if (request.frequencyHz !== undefined) {
      fieldRequest.frequencyHz = request.frequencyHz;
    }
    if (request.loadCurrentAmps !== undefined) {
      fieldRequest.loadCurrentAmps = request.loadCurrentAmps;
    }
    if (request.energyBudgetJoules !== undefined) {
      fieldRequest.energyBudgetJoules = request.energyBudgetJoules;
    }
    this.socket.send(encodeVoxelFieldConductIntent(fieldRequest));
    this.sentVoxelMessageCount += 1;
    this.logger.emit("voxel", "field_conduct_intent_sent", {
      request_id: requestId,
      client_intent_seq: request.clientIntentSeq,
      logical_scene_id: request.logicalSceneId,
      source_coord: chunkCoordKey(request.sourceWorldMacro),
      target_coord: chunkCoordKey(request.targetWorldMacro),
      conduction_mode: request.conductionMode ?? "conductive",
      output_mode: request.outputMode ?? "",
      max_ticks: request.maxTicks,
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

  drainVoxelFieldSnapshots(): VoxelFieldRegionSnapshotMessage[] {
    return this.voxelFieldSnapshots.splice(0, this.voxelFieldSnapshots.length);
  }

  drainVoxelFieldDestroyeds(): VoxelFieldRegionDestroyedMessage[] {
    return this.voxelFieldDestroyeds.splice(0, this.voxelFieldDestroyeds.length);
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
    this.pendingVoxelControlRequests.clear();
    this.lastPlayerState = null;
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;
    this.highestSentSeq = null;
    this.lastAckReceivedAtMs = null;
    this.lastAckDiagnostics = null;
  }

  sendInput(frame: MoveInputFrame, nowMs: number): void {
    if (!this.isReady() || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      this.recordBlockedInput(frame, nowMs, this.unavailableReason());
      return;
    }

    this.socket.send(encodeMovementInput(frame));
    this.sentAtBySeq.set(frame.seq, nowMs);
    this.highestSentSeq =
      this.highestSentSeq === null ? frame.seq : Math.max(this.highestSentSeq, frame.seq);
    this.sentInputCount += 1;
    this.logger.emit("transport", "movement_sent", {
      seq: frame.seq,
      tick: frame.clientTick,
      mode: this.mode,
    });
  }

  tick(nowMs: number, _dtMs: number): MovementTransportTickResult {
    this.lastTickAtMs = nowMs;
    this.maybeReconnect(nowMs);
    this.maybeSendTimeSync(nowMs);

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

  private maybeSendTimeSync(nowMs: number): void {
    if (!this.isReady() || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return;
    }

    if (nowMs - this.lastTimeSyncSentAtMs < TIME_SYNC_INTERVAL_MS) {
      return;
    }

    const requestId = this.nextRequestId();
    const clientSendTs = Date.now();
    this.socket.send(encodeTimeSync(requestId, clientSendTs));
    this.lastTimeSyncSentAtMs = nowMs;
    this.logger.emit("transport", "time_sync_sent", {
      mode: SERVER_TRANSPORT_MODE,
      request_id: requestId,
      client_send_ts: clientSendTs,
    });
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
    this.lastTimeSyncSentAtMs = Number.NEGATIVE_INFINITY;
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
    const timer = window.setTimeout(() => controller.abort(), this.autoLoginTimeoutMs);
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
        throw new Error(`auto_login_timeout:${this.autoLoginTimeoutMs}ms`);
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
    let message: ReturnType<typeof decodeServerMessage>;
    try {
      message = decodeServerMessage(data);
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      const opcode = data.byteLength > 0 ? new DataView(data).getUint8(0) : null;
      this.lastError = `message_decode_failed:${reason}`;
      this.logger.emit("transport", "message_decode_failed", {
        mode: SERVER_TRANSPORT_MODE,
        opcode: opcode ?? -1,
        bytes: data.byteLength,
        reason,
      });
      return;
    }
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
      case "result_ok":
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
        } else if (this.pendingChatRequests.has(message.requestId)) {
          this.recordChatAccepted(message.requestId);
        }
        break;
      case "result_error": {
        const inFlightMovement = this.sentAtBySeq.has(message.requestId);
        const maxInFlightSeq = inFlightMovement ? maxNumberKey(this.sentAtBySeq) : null;
        this.receivedResultErrorCount += 1;
        this.lastResultError = {
          requestId: message.requestId,
          phase: this.connectionPhase,
          inFlightMovement,
        };
        this.lastError = `result_error:${message.requestId}`;
        this.logger.emit("transport", "result_error", {
          mode: SERVER_TRANSPORT_MODE,
          request_id: message.requestId,
          phase: this.connectionPhase,
          in_flight_movement: inFlightMovement,
          received_count: this.receivedResultErrorCount,
        });

        if (message.requestId === this.authRequestId && this.connectionPhase === "auth_request") {
          this.markDisconnected(`auth_result_error:${message.requestId}`);
          break;
        }

        if (this.pendingChatRequests.has(message.requestId)) {
          const pending = this.pendingChatRequests.get(message.requestId);
          this.pendingChatRequests.delete(message.requestId);
          this.logger.emit("chat", "chat_scoped_rejected", {
            mode: SERVER_TRANSPORT_MODE,
            request_id: message.requestId,
            scope: pending?.scope ?? "unknown",
          });
          break;
        }

        const voxelControlSource = this.pendingVoxelControlRequests.get(message.requestId);
        if (voxelControlSource) {
          this.pendingVoxelControlRequests.delete(message.requestId);
          this.lastVoxelError = `control_result_error:${voxelControlSource}:${message.requestId}`;
          this.logger.emit("voxel", "control_result_error", {
            mode: SERVER_TRANSPORT_MODE,
            request_id: message.requestId,
            source: voxelControlSource,
            in_flight_movement: inFlightMovement,
          });
          break;
        }

        if (inFlightMovement) {
          this.sentAtBySeq.delete(message.requestId);
          if (maxInFlightSeq !== null && message.requestId < maxInFlightSeq) {
            this.logger.emit("transport", "movement_result_error_superseded", {
              mode: SERVER_TRANSPORT_MODE,
              request_id: message.requestId,
              max_in_flight_seq: maxInFlightSeq,
            });
            break;
          }

          this.markDisconnected(`movement_result_error:${message.requestId}`);
        }
        break;
      }
      case "enter_scene_ok":
        if (message.requestId === this.enterSceneRequestId) {
          // Pillar 1.1: fail-fast if the server's wire protocol version does
          // not match what this client was compiled against. A mismatch means
          // the server was upgraded without a matching client deploy, which
          // would cause silent decode errors on every subsequent message.
          if (message.protocolVersion !== PROTOCOL_VERSION) {
            console.error(
              `[gate] protocol_version mismatch: server=${message.protocolVersion} client=${PROTOCOL_VERSION}`,
            );
            this.markDisconnected(
              `protocol_version_mismatch:server=${message.protocolVersion}:client=${PROTOCOL_VERSION}`,
            );
            break;
          }
          this.ready = true;
          this.connectionStatus = "connected";
          this.connectionPhase = "ready";
          this.phaseStartedAtMs = performance.now();
          this.lastReadyDurationMs =
            this.bootstrapStartedAtMs === null
              ? null
              : Math.round(this.phaseStartedAtMs - this.bootstrapStartedAtMs);
          this.connectionLostReason = null;
          this.reconnectAttemptCount = 0;
          this.nextReconnectAtMs = Number.POSITIVE_INFINITY;
          this.clearHandshakeTimer();
          this.spawnPosition = message.position;
          this.spawnExpectedSeq = message.expectedSeq;
          this.logger.emit("transport", "enter_scene_ok", {
            mode: SERVER_TRANSPORT_MODE,
            position: `${message.position.x.toFixed(1)},${message.position.y.toFixed(1)},${message.position.z.toFixed(1)}`,
            expected_seq: message.expectedSeq,
            protocol_version: message.protocolVersion,
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
        {
          const receivedAtMs = performance.now();
          const sentAtMs = this.sentAtBySeq.get(message.ack.ackSeq) ?? receivedAtMs;
          this.acknowledgements.push({
            ack: message.ack,
            sentAtMs,
            receivedAtMs,
          });
          this.lastAckReceivedAtMs = receivedAtMs;
          this.lastAckDiagnostics = {
            ackSeq: message.ack.ackSeq,
            authTick: message.ack.authTick,
            serverStateMs: message.ack.serverStateMs,
            serverSendMs: message.ack.serverSendMs,
            sceneAckMs: message.ack.sceneAckMs ?? null,
            sceneInputAgeMs: message.ack.sceneInputAgeMs ?? null,
            sceneQueueLen: message.ack.sceneQueueLen ?? null,
            sceneReplayCount: message.ack.sceneReplayCount ?? null,
            sceneDroppedInputCount: message.ack.sceneDroppedInputCount ?? null,
            sceneMailboxLen: message.ack.sceneMailboxLen ?? null,
            sceneTickDriftMs: message.ack.sceneTickDriftMs ?? null,
            gateSendDelayMs: message.ack.gateSendDelayMs ?? null,
          };
          this.dropSentThroughSeq(message.ack.ackSeq);
          this.receivedAckCount += 1;
          this.lastAckSeq = message.ack.ackSeq;
        }
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
      case "chat_message":
        this.chatMessages.push({
          cid: message.cid,
          username: message.username,
          text: message.text,
        });
        this.receivedChatMessageCount += 1;
        this.lastChatMessage = {
          cid: message.cid,
          username: message.username,
          text: message.text,
        };
        this.logger.emit("chat", "chat_message_received", {
          mode: SERVER_TRANSPORT_MODE,
          cid: message.cid,
          username: message.username,
          text_length: new TextEncoder().encode(message.text).length,
          received_count: this.receivedChatMessageCount,
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
      | VoxelCatalogPatchMessage
      | VoxelFieldRegionSnapshotMessage
      | VoxelFieldRegionDestroyedMessage
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
      case "voxel_catalog_patch":
        // Phase 1.6b: envelope-only forward-compat dispatch. We only log the
        // arrival here; Phase 5 will land the AttributeDefinition /
        // TagDefinition typed payload consumers.
        this.logger.emit("voxel", "catalog_patch_received", {
          mode: SERVER_TRANSPORT_MODE,
          schema_kind: `0x${message.patch.schemaKind.toString(16)}`,
          base_version: message.patch.baseVersion.toString(),
          new_version: message.patch.newVersion.toString(),
          op_count: message.patch.ops.length,
        });
        return true;
      case "voxel_field_region_snapshot":
        this.voxelFieldSnapshots.push(message);
        this.logger.emit("voxel", "field_region_snapshot_received", {
          mode: SERVER_TRANSPORT_MODE,
          region_id: message.snapshot.regionId,
          chunk_coord: `${message.snapshot.chunkCoord.cx},${message.snapshot.chunkCoord.cy},${message.snapshot.chunkCoord.cz}`,
          field_mask: `0x${message.snapshot.fieldMask.toString(16)}`,
          cell_count: message.snapshot.cellCount,
          tick_count: message.snapshot.tickCount,
        });
        return true;
      case "voxel_field_region_destroyed":
        this.voxelFieldDestroyeds.push(message);
        this.logger.emit("voxel", "field_region_destroyed_received", {
          mode: SERVER_TRANSPORT_MODE,
          region_id: message.destroyed.regionId,
          chunk_coord: `${message.destroyed.chunkCoord.cx},${message.destroyed.chunkCoord.cy},${message.destroyed.chunkCoord.cz}`,
          destroy_reason: message.destroyed.destroyReason,
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

  private canUseServerChat(): boolean {
    return (
      this.connectionStatus === "connected" &&
      this.ready &&
      this.socket?.readyState === WebSocket.OPEN
    );
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

  private blockChatSend(scope: ChatScope, reason: string): null {
    this.blockedChatSendCount += 1;
    this.lastBlockedChatSend = { scope, reason };
    this.logger.emit("chat", "send_blocked", {
      scope,
      reason,
      blocked_count: this.blockedChatSendCount,
      connection_status: this.connectionStatus,
      connection_lost_reason: this.connectionLostReason ?? "",
      socket_state: this.socket?.readyState ?? -1,
    });
    return null;
  }

  private recordChatAccepted(requestId: number): void {
    const pending = this.pendingChatRequests.get(requestId);
    if (!pending) {
      return;
    }
    this.pendingChatRequests.delete(requestId);
    this.lastAcceptedChatSend = { requestId, scope: pending.scope };
    this.logger.emit("chat", "chat_scoped_accepted", {
      mode: SERVER_TRANSPORT_MODE,
      request_id: requestId,
      scope: pending.scope,
      text_length: pending.textLength,
    });
  }

  private rememberVoxelControlRequest(requestId: number, source: string): void {
    this.pendingVoxelControlRequests.set(requestId, source);
    while (this.pendingVoxelControlRequests.size > MAX_PENDING_VOXEL_CONTROL_REQUESTS) {
      const oldest = this.pendingVoxelControlRequests.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      this.pendingVoxelControlRequests.delete(oldest);
    }
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
      this.markDisconnected(`${phase}_timeout:${this.handshakeTimeoutMs}ms`);
    }, this.handshakeTimeoutMs);
  }

  private clearHandshakeTimer(): void {
    if (this.handshakeTimer !== null) {
      window.clearTimeout(this.handshakeTimer);
      this.handshakeTimer = null;
    }
  }

  private maybeReconnect(nowMs: number): void {
    if (
      this.connectionStatus !== "disconnected" ||
      this.connecting ||
      !Number.isFinite(this.nextReconnectAtMs) ||
      nowMs < this.nextReconnectAtMs
    ) {
      return;
    }

    this.logger.emit("transport", "reconnect_start", {
      mode: SERVER_TRANSPORT_MODE,
      attempt: this.reconnectAttemptCount,
      reason: this.connectionLostReason ?? "unknown",
    });
    void this.bootstrap();
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
    if (this.canReconnect(reason)) {
      this.scheduleReconnect(reason);
    } else {
      this.reconnectAttemptCount = 0;
      this.nextReconnectAtMs = Number.POSITIVE_INFINITY;
      this.logger.emit("transport", "reconnect_suppressed", {
        mode: SERVER_TRANSPORT_MODE,
        reason,
      });
    }
    this.logger.emit("transport", "connection_lost", {
      mode: SERVER_TRANSPORT_MODE,
      reason,
    });
  }

  private canReconnect(reason: string): boolean {
    return (
      reason.startsWith("socket_closed:") ||
      reason.startsWith("bootstrap_error:") ||
      reason.startsWith("socket_connect_timeout:") ||
      reason.startsWith("auth_request_timeout:") ||
      reason.startsWith("enter_scene_timeout:")
    );
  }

  private scheduleReconnect(reason: string): void {
    this.reconnectAttemptCount += 1;
    const delayMs = Math.min(
      RECONNECT_INITIAL_DELAY_MS * 2 ** Math.max(0, this.reconnectAttemptCount - 1),
      RECONNECT_MAX_DELAY_MS,
    );
    this.nextReconnectAtMs = this.lastTickAtMs + delayMs;
    this.logger.emit("transport", "reconnect_scheduled", {
      mode: SERVER_TRANSPORT_MODE,
      attempt: this.reconnectAttemptCount,
      delay_ms: delayMs,
      next_reconnect_in_ms: Math.max(0, Math.round(this.nextReconnectAtMs - this.lastTickAtMs)),
      reason,
    });
  }

  private clearPendingMessages(): void {
    this.acknowledgements.splice(0, this.acknowledgements.length);
    this.remoteSnapshots.splice(0, this.remoteSnapshots.length);
    this.remoteEntityEnters.splice(0, this.remoteEntityEnters.length);
    this.remoteEntityLeaves.splice(0, this.remoteEntityLeaves.length);
    this.chatMessages.splice(0, this.chatMessages.length);
    this.timeSyncSamples.splice(0, this.timeSyncSamples.length);
    this.voxelSnapshots.splice(0, this.voxelSnapshots.length);
    this.voxelIntentResults.splice(0, this.voxelIntentResults.length);
    this.voxelDebugProbes.splice(0, this.voxelDebugProbes.length);
    this.voxelDeltas.splice(0, this.voxelDeltas.length);
    this.voxelInvalidates.splice(0, this.voxelInvalidates.length);
    this.voxelObjectStateDeltas.splice(0, this.voxelObjectStateDeltas.length);
    this.voxelFieldSnapshots.splice(0, this.voxelFieldSnapshots.length);
    this.voxelFieldDestroyeds.splice(0, this.voxelFieldDestroyeds.length);
    this.pendingVoxelPrefabRequests.clear();
    this.pendingVoxelControlRequests.clear();
    this.pendingChatRequests.clear();
    this.sentAtBySeq.clear();
    this.lastPlayerState = null;
    this.lastChatMessage = null;
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;
  }

  private dropSentThroughSeq(ackSeq: number): void {
    for (const seq of this.sentAtBySeq.keys()) {
      if (seq <= ackSeq) {
        this.sentAtBySeq.delete(seq);
      }
    }
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

export function resolveAutoLoginTimeoutMs(
  env: Record<string, string | undefined> = import.meta.env,
): number {
  return resolveTimeoutMs(
    firstNonBlank(env.VITE_GAME_AUTO_LOGIN_TIMEOUT_MS),
    DEFAULT_AUTO_LOGIN_TIMEOUT_MS,
    MIN_AUTO_LOGIN_TIMEOUT_MS,
  );
}

export function resolveHandshakeTimeoutMs(
  env: Record<string, string | undefined> = import.meta.env,
): number {
  return resolveTimeoutMs(
    firstNonBlank(env.VITE_GAME_HANDSHAKE_TIMEOUT_MS),
    DEFAULT_HANDSHAKE_TIMEOUT_MS,
    MIN_HANDSHAKE_TIMEOUT_MS,
  );
}

function firstNonBlank(...values: Array<string | undefined>): string | null {
  for (const value of values) {
    if (value && value.trim() !== "") {
      return value;
    }
  }
  return null;
}

function resolveTimeoutMs(
  configured: string | null,
  fallbackMs: number,
  minimumMs: number,
): number {
  if (!configured) {
    return fallbackMs;
  }

  const parsed = Number(configured);
  if (!Number.isFinite(parsed) || parsed < minimumMs) {
    return fallbackMs;
  }

  return Math.round(parsed);
}

function maxNumberKey(map: Map<number, unknown>): number | null {
  let max: number | null = null;
  for (const key of map.keys()) {
    if (max === null || key > max) {
      max = key;
    }
  }
  return max;
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}
