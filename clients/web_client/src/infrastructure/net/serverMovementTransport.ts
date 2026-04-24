import { Vector3 } from "three";
import {
  encodeAuthRequest,
  decodeServerMessage,
  encodeEnterScene,
  encodeHeartbeat,
  encodeMovementInput,
} from "./gateProtocol";
import type { ObserveLog } from "../../observe/logger";
import type { MoveInputFrame, RemoteMoveSnapshot } from "@domain/movement/types";
import type {
  MovementTransport,
  MovementTransportTickResult,
  PendingMovementAck,
} from "@domain/movement/transport";
import { SimulatedLocalMovementTransport } from "./simulatedMovementTransport";

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
  private readonly sentAtBySeq = new Map<number, number>();
  private spawnPosition: Vector3 | null = null;
  private readonly fallbackTransport = new SimulatedLocalMovementTransport();
  private fallbackReason: string | null = null;
  private readonly lastResetPosition = new Vector3(-350, 650, -280);

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
      authBaseUrl: this.authBaseUrl,
      webSocketUrl: this.webSocketUrl,
    };
  }

  reset(position: Vector3): void {
    this.lastResetPosition.copy(position);
    this.acknowledgements.splice(0, this.acknowledgements.length);
    this.remoteSnapshots.splice(0, this.remoteSnapshots.length);
    this.spawnPosition = null;

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
    const spawnPosition = this.spawnPosition;
    this.spawnPosition = null;
    return { acknowledgements, remoteSnapshots, spawnPosition };
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

    const message = decodeServerMessage(data);
    if (!message) {
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
          this.logger.emit("transport", "enter_scene_ok", {
            mode: SERVER_TRANSPORT_MODE,
            position: `${message.position.x.toFixed(1)},${message.position.y.toFixed(1)},${message.position.z.toFixed(1)}`,
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
        break;
      case "player_move":
        this.remoteSnapshots.push(message.snapshot);
        break;
      case "heartbeat_reply":
        this.logger.emit("transport", "heartbeat_reply", { mode: SERVER_TRANSPORT_MODE });
        break;
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
    this.sentAtBySeq.clear();
    this.spawnPosition = null;
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
