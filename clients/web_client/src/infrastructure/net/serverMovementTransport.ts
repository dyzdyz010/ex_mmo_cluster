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
  type VoxelPrefabKnownCellRef,
  type VoxelPrefabKnownObject,
  type VoxelPrefabKnownRef,
} from "./voxelProtocol";
import type { ObserveLog } from "../../observe/logger";
import type { MoveInputFrame, RemoteMoveSnapshot } from "@domain/movement/types";
import type {
  MovementTransport,
  MovementTransportTickResult,
  PendingMovementAck,
} from "@domain/movement/transport";
import { SimulatedLocalMovementTransport } from "./simulatedMovementTransport";
import { chunkCoordKey, type FChunkCoord, type FMacroCoord } from "../../voxel/core/types";

interface AutoLoginResponse {
  token: string;
  cid: number;
  username: string;
}

const SERVER_TRANSPORT_MODE = "server-ws";

export class ServerMovementTransport implements MovementTransport {
  private socket: WebSocket | null = null;
  private ready = false;
  private connecting = false;
  private heartbeatTimer: number | null = null;
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
  private readonly voxelKnownVersions = new Map<string, number>();
  private readonly sentAtBySeq = new Map<number, number>();
  private spawnPosition: Vector3 | null = null;
  // Audit B-S1 / B-SRV2: server-reported next-input seq for the upcoming
  // spawn. Consumed alongside spawnPosition by the transport pump.
  private spawnExpectedSeq: number | null = null;
  private readonly fallbackTransport = new SimulatedLocalMovementTransport();
  private fallbackReason: string | null = null;
  private readonly lastResetPosition = new Vector3(-350, 650, -280);
  private sentInputCount = 0;
  private receivedMessageCount = 0;
  private receivedAckCount = 0;
  private receivedRemoteSnapshotCount = 0;
  private lastAckSeq: number | null = null;
  private lastRemoteTickByCid = new Map<number, number>();
  private lastTimeSyncOffsetMs: number | null = null;
  private lastError: string | null = null;
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
    return this.usingFallback() ? this.fallbackTransport.mode : SERVER_TRANSPORT_MODE;
  }

  isReady(): boolean {
    if (this.usingFallback()) {
      return this.fallbackTransport.isReady();
    }

    return this.ready;
  }

  debugSnapshot(): Record<string, unknown> {
    if (this.usingFallback()) {
      return {
        mode: this.mode,
        fallbackFrom: SERVER_TRANSPORT_MODE,
        fallbackReason: this.fallbackReason,
        authBaseUrl: this.authBaseUrl,
        webSocketUrl: this.webSocketUrl,
        serverState: {
          ready: this.ready,
          connecting: this.connecting,
          cid: this.cid,
          username: this.username,
          socketState: this.socket?.readyState ?? null,
          hasToken: this.token !== null,
          authRequestId: this.authRequestId,
          enterSceneRequestId: this.enterSceneRequestId,
          voxel: this.voxelDebugSnapshot(),
        },
        fallbackTransport: this.fallbackTransport.debugSnapshot(),
      };
    }

    return {
      mode: this.mode,
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
      lastAckSeq: this.lastAckSeq,
      lastRemoteTickByCid: Object.fromEntries(this.lastRemoteTickByCid),
      lastTimeSyncOffsetMs: this.lastTimeSyncOffsetMs,
      lastError: this.lastError,
      authBaseUrl: this.authBaseUrl,
      webSocketUrl: this.webSocketUrl,
      voxel: this.voxelDebugSnapshot(),
    };
  }

  canUseServerVoxel(): boolean {
    return !this.usingFallback() && this.ready && this.socket?.readyState === WebSocket.OPEN;
  }

  getAuthBaseUrl(): string {
    return this.authBaseUrl;
  }

  voxelDebugSnapshot(): Record<string, unknown> {
    return {
      available: this.canUseServerVoxel(),
      queuedSnapshots: this.voxelSnapshots.length,
      queuedIntentResults: this.voxelIntentResults.length,
      queuedDebugProbes: this.voxelDebugProbes.length,
      knownChunks: this.voxelKnownVersions.size,
      pendingPrefabRequests: this.pendingVoxelPrefabRequests.size,
      sentVoxelMessageCount: this.sentVoxelMessageCount,
      receivedVoxelSnapshotCount: this.receivedVoxelSnapshotCount,
      receivedVoxelIntentResultCount: this.receivedVoxelIntentResultCount,
      receivedVoxelDebugProbeCount: this.receivedVoxelDebugProbeCount,
      lastSnapshot: this.lastVoxelSnapshot
        ? {
            ...this.lastVoxelSnapshot,
            chunkCoord: chunkCoordKey(this.lastVoxelSnapshot.chunkCoord),
          }
        : null,
      lastIntentResult: this.lastVoxelIntentResult,
      lastPrefabRequest: this.lastVoxelPrefabRequest,
      lastError: this.lastVoxelError,
    };
  }

  sendVoxelDebugProbe(command: string = "voxel_transport"): number | null {
    if (!this.canUseServerVoxel() || !this.socket) {
      this.lastVoxelError = "voxel_transport_unavailable";
      return null;
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
      this.lastVoxelError = "voxel_transport_unavailable";
      return null;
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
      this.lastVoxelError = "voxel_transport_unavailable";
      return null;
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
      this.lastVoxelError = "voxel_transport_unavailable";
      return null;
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
      this.lastVoxelError = "voxel_transport_unavailable";
      return null;
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
    this.pendingVoxelPrefabRequests.clear();
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;

    if (this.usingFallback()) {
      this.fallbackTransport.reset(position);
    }
  }

  sendInput(frame: MoveInputFrame, nowMs: number): void {
    if (this.usingFallback()) {
      this.fallbackTransport.sendInput(frame, nowMs);
      return;
    }

    if (!this.ready || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
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

  tick(nowMs: number, dtMs: number): MovementTransportTickResult {
    if (this.usingFallback()) {
      return this.fallbackTransport.tick(nowMs, dtMs);
    }

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
    this.logger.emit("transport", "bootstrap_start", {
      mode: SERVER_TRANSPORT_MODE,
      url: this.webSocketUrl,
    });

    try {
      const login = await this.autoLogin();
      this.token = login.token;
      this.cid = login.cid;
      this.username = login.username;
      this.openSocket();
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown";
      this.lastError = reason;
      this.logger.emit("transport", "bootstrap_error", {
        mode: SERVER_TRANSPORT_MODE,
        reason,
      });
      this.activateFallback(reason);
    }
  }

  private async autoLogin(): Promise<AutoLoginResponse> {
    const response = await fetch(`${this.authBaseUrl}/ingame/auto_login`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ username: this.username }),
    });

    if (!response.ok) {
      throw new Error(`auto_login_failed:${response.status}`);
    }

    return response.json() as Promise<AutoLoginResponse>;
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
      const closedBeforeReady = !this.ready;
      this.ready = false;
      this.connecting = false;
      this.clearHeartbeat();
      this.logger.emit("transport", "socket_closed", {
        mode: SERVER_TRANSPORT_MODE,
        code: event.code,
        reason: event.reason || "closed",
      });

      if (closedBeforeReady) {
        this.activateFallback(`socket_closed:${event.code}:${event.reason || "closed"}`);
      }
    };
    this.socket = socket;
  }

  private handleOpen(socket: WebSocket): void {
    if (!this.token) {
      return;
    }

    this.connecting = false;
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

      this.lastError = `message_ignored:${data.byteLength}`;
      this.logger.emit("transport", "message_ignored", {
        mode: SERVER_TRANSPORT_MODE,
        bytes: data.byteLength,
      });
      return;
    }

    switch (message.type) {
      case "auth_ok":
        if (message.requestId === this.authRequestId && this.socket && this.cid !== null) {
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
          this.spawnPosition = message.position;
          this.spawnExpectedSeq = message.expectedSeq;
          this.logger.emit("transport", "enter_scene_ok", {
            mode: SERVER_TRANSPORT_MODE,
            position: `${message.position.x.toFixed(1)},${message.position.y.toFixed(1)},${message.position.z.toFixed(1)}`,
            expected_seq: message.expectedSeq,
          });
        }
        break;
      case "enter_scene_error":
        this.logger.emit("transport", "enter_scene_error", {
          mode: SERVER_TRANSPORT_MODE,
          request_id: message.requestId,
        });
        this.activateFallback(`enter_scene_error:${message.requestId}`);
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
        this.remoteEntityEnters.push({ cid: message.cid, position: message.position });
        break;
      case "player_leave":
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
    }
  }

  private handleVoxelMessage(data: ArrayBuffer): boolean {
    let message:
      | VoxelChunkSnapshotMessage
      | VoxelChunkDeltaMessage
      | VoxelChunkInvalidateMessage
      | VoxelIntentResultMessage
      | VoxelDebugProbeMessage
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

  private usingFallback(): boolean {
    return this.fallbackReason !== null;
  }

  private activateFallback(reason: string): void {
    if (this.usingFallback()) {
      return;
    }

    this.ready = false;
    this.connecting = false;
    this.clearHeartbeat();
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
          this.socket.close(1000, "fallback_to_simulated");
        } catch {
          // Ignore cleanup failures while switching to offline simulation.
        }
      }
    }

    this.socket = null;
    this.fallbackReason = reason;
    this.fallbackTransport.reset(this.lastResetPosition);
    this.logger.emit("transport", "fallback_to_simulated", {
      from: SERVER_TRANSPORT_MODE,
      reason,
      start: `${this.lastResetPosition.x.toFixed(1)},${this.lastResetPosition.y.toFixed(1)},${this.lastResetPosition.z.toFixed(1)}`,
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
    this.pendingVoxelPrefabRequests.clear();
    this.sentAtBySeq.clear();
    this.spawnPosition = null;
    this.spawnExpectedSeq = null;
  }
}

function resolveDefaultUsername(): string {
  if (import.meta.env.VITE_GAME_USERNAME) {
    return import.meta.env.VITE_GAME_USERNAME;
  }

  try {
    const key = "ex_mmo_web_client.runtime_username";
    const existing = window.sessionStorage.getItem(key);
    if (existing && existing.trim() !== "") {
      return existing;
    }

    const generated = `web_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    window.sessionStorage.setItem(key, generated);
    return generated;
  } catch {
    return `web_${Math.random().toString(36).slice(2, 10)}`;
  }
}

function resolveAuthBaseUrl(): string {
  return import.meta.env.VITE_AUTH_BASE_URL || "";
}

function resolveGameWsUrl(): string {
  if (import.meta.env.VITE_GAME_WS_URL) {
    return import.meta.env.VITE_GAME_WS_URL;
  }

  const wsProtocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${wsProtocol}//${window.location.host}/ingame/ws`;
}
