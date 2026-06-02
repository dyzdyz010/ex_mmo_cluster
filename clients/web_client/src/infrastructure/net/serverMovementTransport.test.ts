import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Vector2 } from "three";
import type { ObserveLog } from "../../observe/logger";
import {
  resolveAuthBaseUrl,
  resolveAutoLoginTimeoutMs,
  resolveDefaultUsername,
  resolveGameWsUrl,
  resolveHandshakeTimeoutMs,
  ServerMovementTransport,
} from "./serverMovementTransport";
import { VoxelOpcode } from "./opcodes";
import { PROTOCOL_VERSION } from "./protocolVersion";

const viteDevLocation = {
  protocol: "http:",
  host: "127.0.0.1:5173",
  origin: "http://127.0.0.1:5173",
};

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  binaryType: BinaryType = "blob";
  readyState = FakeWebSocket.CONNECTING;
  sent: unknown[] = [];
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this);
  }

  send(data: unknown): void {
    this.sent.push(data);
  }

  close(): void {
    this.readyState = FakeWebSocket.CLOSED;
  }

  closeWith(code = 1006, reason = "network_lost"): void {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.({ code, reason } as CloseEvent);
  }

  open(): void {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.({} as Event);
  }

  message(data: ArrayBuffer): void {
    this.onmessage?.({ data } as MessageEvent);
  }
}

describe("server movement transport chat", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("window", {
      location: viteDevLocation,
      setTimeout: vi.fn(() => 1),
      clearTimeout: vi.fn(),
      setInterval: vi.fn(() => 1),
      clearInterval: vi.fn(),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ token: "dev-token", cid: 42, username: "tester" }),
      })),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends scoped chat only after the server session is ready", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    expect(socket).toBeDefined();

    socket?.open();
    expect(socket?.sent).toHaveLength(1);
    socket?.message(resultFrame(1, true));
    expect(socket?.sent).toHaveLength(2);
    socket?.message(enterSceneOkFrame(2));

    const requestId = transport.sendChat("region", "  hello region  ");
    expect(requestId).toBe(3);
    expect(socket?.sent).toHaveLength(3);
    const encoded = socket?.sent[2] as Uint8Array;
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);
    expect(view.getUint8(0)).toBe(0x0a);
    expect(view.getBigUint64(1, false)).toBe(3n);
    expect(view.getUint8(9)).toBe(1);
    expect(new TextDecoder().decode(encoded.slice(12))).toBe("hello region");
    expect(transport.debugSnapshot().chat).toMatchObject({
      sentChatMessageCount: 1,
      lastSend: { requestId: 3, scope: "region", textLength: 12 },
    });
    expect(emit).toHaveBeenCalledWith(
      "chat",
      "chat_scoped_sent",
      expect.objectContaining({ request_id: 3, scope: "region", text_length: 12 }),
    );
  });

  it("queues server chat frames for the pump and observe logs", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));
    socket?.message(chatMessageFrame(42, "tester", "server delivered"));

    expect(transport.drainChatMessages()).toEqual([
      { cid: 42, username: "tester", text: "server delivered" },
    ]);
    expect(transport.drainChatMessages()).toEqual([]);
    expect(transport.debugSnapshot().chat).toMatchObject({
      receivedChatMessageCount: 1,
      queuedMessages: 0,
      lastMessage: { cid: 42, username: "tester", text: "server delivered" },
    });
    expect(emit).toHaveBeenCalledWith(
      "chat",
      "chat_message_received",
      expect.objectContaining({ cid: 42, username: "tester", text_length: 16 }),
    );
  });

  it("records scoped chat result acknowledgements separately from auth", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));

    const requestId = transport.sendChat("world", "accepted by server");
    socket?.message(resultFrame(requestId ?? -1, true));

    expect(transport.debugSnapshot().chat).toMatchObject({
      lastAccepted: { requestId, scope: "world" },
    });
    expect(emit).toHaveBeenCalledWith(
      "chat",
      "chat_scoped_accepted",
      expect.objectContaining({ request_id: requestId, scope: "world" }),
    );
  });

  it("records blocked scoped chat sends before the server session is ready", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );

    expect(transport.sendChat("local", "hello")).toBeNull();
    expect(transport.debugSnapshot().chat).toMatchObject({
      blockedSendCount: 1,
      lastBlockedSend: { scope: "local", reason: "connecting" },
    });
    expect(emit).toHaveBeenCalledWith(
      "chat",
      "send_blocked",
      expect.objectContaining({ scope: "local", reason: "connecting" }),
    );
    await flushAsync();
  });

  it("clears all queued voxel and field downlinks when the socket disconnects", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));
    const queues = transport as unknown as {
      voxelDeltas: unknown[];
      voxelInvalidates: unknown[];
      voxelFieldSnapshots: unknown[];
      voxelFieldDestroyeds: unknown[];
    };
    queues.voxelDeltas.push({});
    queues.voxelInvalidates.push({});
    queues.voxelFieldSnapshots.push({});
    queues.voxelFieldDestroyeds.push({});

    socket?.closeWith(1006, "network_lost");

    expect(transport.drainVoxelDeltas()).toEqual([]);
    expect(transport.drainVoxelInvalidates()).toEqual([]);
    expect(transport.drainVoxelFieldSnapshots()).toEqual([]);
    expect(transport.drainVoxelFieldDestroyeds()).toEqual([]);
  });
});

describe("server movement transport voxel chunk ACKs", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("window", {
      location: viteDevLocation,
      setTimeout: vi.fn(() => 1),
      clearTimeout: vi.fn(),
      setInterval: vi.fn(() => 1),
      clearInterval: vi.fn(),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ token: "dev-token", cid: 42, username: "tester" }),
      })),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends explicit applied-version ACKs after the server session is ready", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));

    const requestId = transport.sendVoxelChunkAck({
      logicalSceneId: 7,
      acks: [{ chunkCoord: { x: -2, y: 4, z: 9 }, chunkVersion: 123 }],
    });

    expect(requestId).toBe(3);
    expect(socket?.sent).toHaveLength(3);
    const encoded = socket?.sent[2] as Uint8Array;
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);
    expect(view.getUint8(0)).toBe(VoxelOpcode.VoxelChunkAck);
    expect(view.getBigUint64(1, false)).toBe(3n);
    expect(view.getBigUint64(9, false)).toBe(7n);
    expect(view.getUint16(17, false)).toBe(1);
    expect(view.getInt32(19, false)).toBe(-2);
    expect(view.getInt32(23, false)).toBe(4);
    expect(view.getInt32(27, false)).toBe(9);
    expect(view.getBigUint64(31, false)).toBe(123n);
    expect(transport.voxelDebugSnapshot()).toMatchObject({
      sentVoxelMessageCount: 1,
      sentVoxelChunkAckCount: 1,
      lastChunkAck: {
        requestId: 3,
        logicalSceneId: 7,
        ackCount: 1,
        acks: ["-2,4,9@123"],
      },
    });
    expect(emit).toHaveBeenCalledWith(
      "voxel",
      "chunk_ack_sent",
      expect.objectContaining({
        request_id: 3,
        logical_scene_id: 7,
        ack_count: 1,
        chunks: JSON.stringify(["-2,4,9@123"]),
      }),
    );
  });
});

describe("server movement transport result errors", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("window", {
      location: viteDevLocation,
      setTimeout: vi.fn(() => 1),
      clearTimeout: vi.fn(),
      setInterval: vi.fn(() => 1),
      clearInterval: vi.fn(),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ token: "dev-token", cid: 42, username: "tester" }),
      })),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("disconnects when the server rejects an in-flight movement input", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));

    transport.sendInput(
      {
        seq: 10,
        clientTick: 10,
        dtMs: 50,
        inputDir: new Vector2(1, 0),
        speedScale: 1,
        movementFlags: 0,
      },
      1_000,
    );

    socket?.message(resultFrame(10, false));

    expect(transport.debugSnapshot()).toMatchObject({
      connectionStatus: "disconnected",
      connectionLostReason: "movement_result_error:10",
    });
    expect(emit).toHaveBeenCalledWith(
      "transport",
      "result_error",
      expect.objectContaining({ request_id: 10, in_flight_movement: true }),
    );
  });

  it("does not treat a voxel control result_error as a movement rejection when ids collide", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));

    transport.sendInput(
      {
        seq: 3,
        clientTick: 3,
        dtMs: 50,
        inputDir: new Vector2(1, 0),
        speedScale: 1,
        movementFlags: 0,
      },
      1_000,
    );
    const requestId = transport.sendVoxelChunkAck({
      logicalSceneId: 7,
      acks: [{ chunkCoord: { x: 6, y: 0, z: -2 }, chunkVersion: 0 }],
    });
    expect(requestId).toBe(3);

    socket?.message(resultFrame(3, false));

    expect(transport.debugSnapshot()).toMatchObject({
      connectionStatus: "connected",
      connectionPhase: "ready",
      receivedResultErrorCount: 1,
      lastResultError: expect.objectContaining({ requestId: 3, inFlightMovement: true }),
    });
    expect(transport.voxelDebugSnapshot()).toMatchObject({
      lastError: "control_result_error:chunk_ack:3",
      pendingControlRequests: 0,
    });
    expect(emit).toHaveBeenCalledWith(
      "voxel",
      "control_result_error",
      expect.objectContaining({
        request_id: 3,
        source: "chunk_ack",
        in_flight_movement: true,
      }),
    );
    expect(emit).not.toHaveBeenCalledWith(
      "transport",
      "connection_lost",
      expect.objectContaining({ reason: "movement_result_error:3" }),
    );
  });

  it("keeps the connection when the server rejects a superseded movement input", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));

    transport.sendInput(
      {
        seq: 10,
        clientTick: 10,
        dtMs: 50,
        inputDir: new Vector2(1, 0),
        speedScale: 1,
        movementFlags: 0,
      },
      1_000,
    );
    transport.sendInput(
      {
        seq: 11,
        clientTick: 11,
        dtMs: 50,
        inputDir: new Vector2(1, 0),
        speedScale: 1,
        movementFlags: 0,
      },
      1_050,
    );

    socket?.message(resultFrame(10, false));

    expect(transport.debugSnapshot()).toMatchObject({
      connectionStatus: "connected",
      connectionPhase: "ready",
      receivedResultErrorCount: 1,
      lastResultError: expect.objectContaining({ requestId: 10, inFlightMovement: true }),
    });
    expect(emit).toHaveBeenCalledWith(
      "transport",
      "movement_result_error_superseded",
      expect.objectContaining({ request_id: 10, max_in_flight_seq: 11 }),
    );
  });
});

describe("server movement transport time sync", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("window", {
      location: viteDevLocation,
      setTimeout: vi.fn(() => 1),
      clearTimeout: vi.fn(),
      setInterval: vi.fn(() => 1),
      clearInterval: vi.fn(),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ token: "dev-token", cid: 42, username: "tester" }),
      })),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("sends periodic time-sync requests once the scene session is ready", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1_700_000_000_123);
    const logger = { emit: vi.fn() } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    socket?.open();
    socket?.message(resultFrame(1, true));
    socket?.message(enterSceneOkFrame(2));

    transport.tick(1_000, 16);
    transport.tick(1_500, 16);

    expect(socket?.sent).toHaveLength(3);
    const encoded = socket?.sent[2] as Uint8Array;
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);
    expect(view.getUint8(0)).toBe(0x03);
    expect(view.getBigUint64(1, false)).toBe(3n);
    expect(view.getBigUint64(9, false)).toBe(1_700_000_000_123n);
    expect(logger.emit).toHaveBeenCalledWith(
      "transport",
      "time_sync_sent",
      expect.objectContaining({ request_id: 3 }),
    );
  });
});

describe("server movement transport reconnect", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("window", {
      location: viteDevLocation,
      setTimeout: vi.fn(() => 1),
      clearTimeout: vi.fn(),
      setInterval: vi.fn(() => 1),
      clearInterval: vi.fn(),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ token: "dev-token", cid: 42, username: "tester" }),
      })),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("re-enters the scene after a transient socket close without page reload", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const firstSocket = FakeWebSocket.instances[0];
    firstSocket?.open();
    firstSocket?.message(resultFrame(1, true));
    firstSocket?.message(enterSceneOkFrame(2));
    transport.tick(0, 16);

    firstSocket?.closeWith(1006, "network_lost");

    transport.tick(999, 16);
    expect(FakeWebSocket.instances).toHaveLength(1);
    expect(transport.debugSnapshot()).toMatchObject({
      connectionStatus: "disconnected",
      ready: false,
      reconnectAttemptCount: 1,
    });

    transport.tick(1_000, 16);
    await flushAsync();
    const secondSocket = FakeWebSocket.instances[1];
    expect(secondSocket).toBeDefined();
    secondSocket?.open();
    const authRequestId = requestIdFromSentFrame(secondSocket?.sent[0]);
    secondSocket?.message(resultFrame(authRequestId, true));
    const enterSceneRequestId = requestIdFromSentFrame(secondSocket?.sent[1]);
    secondSocket?.message(enterSceneOkFrame(enterSceneRequestId));

    const result = transport.tick(1_100, 16);
    expect(result.spawn).toMatchObject({ expectedSeq: 1 });
    expect(transport.debugSnapshot()).toMatchObject({
      connectionStatus: "connected",
      connectionPhase: "ready",
      ready: true,
      reconnectAttemptCount: 0,
      connectionLostReason: null,
    });
    expect(emit).toHaveBeenCalledWith(
      "transport",
      "reconnect_scheduled",
      expect.objectContaining({ attempt: 1, delay_ms: 1_000 }),
    );
    expect(emit).toHaveBeenCalledWith(
      "transport",
      "reconnect_start",
      expect.objectContaining({ attempt: 1 }),
    );
  });
});

// ── Pillar 1.1 integration: protocol_version mismatch fail-fast ──────────────
// Verifies that an enter_scene_ok frame carrying a mismatched protocol_version
// causes the transport to enter the disconnected state and set ready=false,
// rather than silently accepting the session and producing corrupt decodes on
// every subsequent message.
describe("server movement transport protocol version guard", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("window", {
      location: viteDevLocation,
      setTimeout: vi.fn(() => 1),
      clearTimeout: vi.fn(),
      setInterval: vi.fn(() => 1),
      clearInterval: vi.fn(),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        json: async () => ({ token: "dev-token", cid: 42, username: "tester" }),
      })),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("disconnects immediately when enter_scene_ok carries an unexpected protocol_version", async () => {
    const emit = vi.fn();
    const logger = { emit } as unknown as ObserveLog;
    const transport = new ServerMovementTransport(
      logger,
      "http://127.0.0.1:20000",
      "ws://127.0.0.1:20000/ingame/ws",
      "tester",
    );
    await flushAsync();
    const socket = FakeWebSocket.instances[0];
    expect(socket).toBeDefined();

    // Complete the auth handshake so we reach the enter_scene phase.
    socket?.open();
    socket?.message(resultFrame(1, true)); // auth ok

    // Build a 40-byte enter_scene_ok frame (0x84) with protocol_version = 99
    // instead of the expected PROTOCOL_VERSION (1), placed at byte offset 38.
    //
    // Layout (Pillar 1.1 wire spec):
    //   [0]     opcode         u8  = 0x84
    //   [1..8]  packet_id      u64 (bigEndian)
    //   [9]     status         u8  = 0x00 (ok)
    //   [10..17] x             f64
    //   [18..25] y             f64
    //   [26..33] z             f64
    //   [34..37] expected_seq  u32
    //   [38..39] protocol_version u16 = 99  ← mismatch
    const buffer = new ArrayBuffer(40);
    const view = new DataView(buffer);
    view.setUint8(0, 0x84);
    view.setBigUint64(1, BigInt(2), false); // packet_id matches enter_scene request_id
    view.setUint8(9, 0);
    view.setFloat64(10, 0, false);
    view.setFloat64(18, 0, false);
    view.setFloat64(26, 0, false);
    view.setUint32(34, 1, false);
    view.setUint16(38, 99, false); // mismatched protocol_version

    socket?.message(buffer);

    // The transport must fail-fast: enter disconnected state with ready=false.
    expect(transport.debugSnapshot()).toMatchObject({
      connectionStatus: "disconnected",
      ready: false,
      reconnectAttemptCount: 0,
      nextReconnectInMs: null,
    });
    expect(emit).toHaveBeenCalledWith(
      "transport",
      "connection_lost",
      expect.objectContaining({
        reason: expect.stringContaining("protocol_version_mismatch"),
      }),
    );
    expect(emit).toHaveBeenCalledWith(
      "transport",
      "reconnect_suppressed",
      expect.objectContaining({
        reason: expect.stringContaining("protocol_version_mismatch"),
      }),
    );
  });
});

describe("server movement transport runtime config", () => {
  it("honors explicit VITE_GAME_* endpoint overrides", () => {
    const env = {
      VITE_GAME_AUTH_BASE_URL: "http://127.0.0.1:20000",
      VITE_AUTH_BASE_URL: "http://wrong.example.test",
      VITE_GAME_WS_URL: "ws://127.0.0.1:20000/ingame/ws",
      VITE_WS_URL: "ws://wrong.example.test/ingame/ws",
      VITE_GAME_CLIENT_USERNAME: "alice",
      VITE_GAME_USERNAME: "legacy_alice",
    };

    expect(resolveAuthBaseUrl(env, viteDevLocation)).toBe("http://127.0.0.1:20000");
    expect(resolveGameWsUrl(env, viteDevLocation)).toBe("ws://127.0.0.1:20000/ingame/ws");
    expect(resolveDefaultUsername(env, null)).toBe("alice");
  });

  it("keeps legacy env names working for manual npm runs", () => {
    const env = {
      VITE_AUTH_BASE_URL: "http://127.0.0.1:20000",
      VITE_WS_URL: "ws://127.0.0.1:20000/ingame/ws",
      VITE_GAME_USERNAME: "manual_user",
    };

    expect(resolveAuthBaseUrl(env, viteDevLocation)).toBe("http://127.0.0.1:20000");
    expect(resolveGameWsUrl(env, viteDevLocation)).toBe("ws://127.0.0.1:20000/ingame/ws");
    expect(resolveDefaultUsername(env, null)).toBe("manual_user");
  });

  it("uses the Vite /ingame proxy when auth env mapping is absent", () => {
    expect(resolveAuthBaseUrl({}, viteDevLocation)).toBe("");
    expect(resolveGameWsUrl({}, viteDevLocation)).toBe("ws://127.0.0.1:5173/ingame/ws");
  });

  it("keeps dev auto_login tolerant of cold startup while allowing env override", () => {
    expect(resolveAutoLoginTimeoutMs({})).toBe(15_000);
    expect(resolveAutoLoginTimeoutMs({ VITE_GAME_AUTO_LOGIN_TIMEOUT_MS: "12000" })).toBe(12_000);
    expect(resolveAutoLoginTimeoutMs({ VITE_GAME_AUTO_LOGIN_TIMEOUT_MS: "250" })).toBe(15_000);
    expect(resolveAutoLoginTimeoutMs({ VITE_GAME_AUTO_LOGIN_TIMEOUT_MS: "not-a-number" })).toBe(
      15_000,
    );
  });

  it("keeps WebSocket handshakes tolerant of cold browser networking", () => {
    expect(resolveHandshakeTimeoutMs({})).toBe(20_000);
    expect(resolveHandshakeTimeoutMs({ VITE_GAME_HANDSHAKE_TIMEOUT_MS: "18000" })).toBe(18_000);
    expect(resolveHandshakeTimeoutMs({ VITE_GAME_HANDSHAKE_TIMEOUT_MS: "250" })).toBe(20_000);
    expect(resolveHandshakeTimeoutMs({ VITE_GAME_HANDSHAKE_TIMEOUT_MS: "not-a-number" })).toBe(
      20_000,
    );
  });

  // Phase A4-bis follow-up: dev auto_login maps username → cid 1:1, so
  // two tabs sharing a username (Chrome copies sessionStorage on
  // Duplicate Tab / "open in new tab") would collide on the same cid
  // and the server treats them as one player — breaking remote
  // rendering. resolveDefaultUsername() must return a fresh value per
  // call so each tab is a distinct user out of the box.
  it("generates a fresh username per call when no env override is set", () => {
    const a = resolveDefaultUsername({}, null);
    const b = resolveDefaultUsername({}, null);
    const c = resolveDefaultUsername({}, null);

    expect(a).toMatch(/^web_/);
    expect(b).toMatch(/^web_/);
    expect(c).toMatch(/^web_/);
    expect(a).not.toBe(b);
    expect(b).not.toBe(c);
    expect(a).not.toBe(c);
  });
});

async function flushAsync(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

function resultFrame(requestId: number, ok: boolean): ArrayBuffer {
  const buffer = new ArrayBuffer(10);
  const view = new DataView(buffer);
  view.setUint8(0, 0x80);
  view.setBigUint64(1, BigInt(requestId), false);
  view.setUint8(9, ok ? 0 : 1);
  return buffer;
}

function requestIdFromSentFrame(frame: unknown): number {
  if (!(frame instanceof Uint8Array)) {
    throw new Error("expected binary client frame");
  }

  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  return Number(view.getBigUint64(1, false));
}

function enterSceneOkFrame(requestId: number): ArrayBuffer {
  // Pillar 1.1: 40-byte layout with trailing protocol_version u16.
  const buffer = new ArrayBuffer(40);
  const view = new DataView(buffer);
  view.setUint8(0, 0x84);
  view.setBigUint64(1, BigInt(requestId), false);
  view.setUint8(9, 0);
  view.setFloat64(10, 0, false);
  view.setFloat64(18, 0, false);
  view.setFloat64(26, 0, false);
  view.setUint32(34, 1, false);
  view.setUint16(38, PROTOCOL_VERSION, false);
  return buffer;
}

function chatMessageFrame(cid: number, username: string, text: string): ArrayBuffer {
  const usernameBytes = new TextEncoder().encode(username);
  const textBytes = new TextEncoder().encode(text);
  const buffer = new ArrayBuffer(1 + 8 + 2 + usernameBytes.length + 2 + textBytes.length);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, 0x89);
  offset += 1;
  view.setBigInt64(offset, BigInt(cid), false);
  offset += 8;
  view.setUint16(offset, usernameBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, usernameBytes.length).set(usernameBytes);
  offset += usernameBytes.length;
  view.setUint16(offset, textBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, textBytes.length).set(textBytes);
  return buffer;
}
