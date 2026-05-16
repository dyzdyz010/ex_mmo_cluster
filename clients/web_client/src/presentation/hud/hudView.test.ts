import { buildRuntimeAlerts, HudView } from "./hudView";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";

describe("HudView", () => {
  it("throttles expensive snapshot reads instead of rebuilding every frame", () => {
    const hud = { textContent: "" } as HTMLDivElement;
    const transport = {
      debugCalls: 0,
      getMode: () => "server-ws",
      isReady: () => true,
      debugSnapshot() {
        this.debugCalls += 1;
        return { mode: "server-ws", ready: true };
      },
    };
    const localPlayer = {
      stateCalls: 0,
      getRenderedPosition: () => ({ x: 0, y: 0, z: 0 }),
      getAuthoritativePosition: () => ({ x: 0, y: 0, z: 0 }),
      getCurrentState() {
        this.stateCalls += 1;
        return {
          tick: 1,
          seq: 1,
          movementMode: "airborne",
          velocity: { x: 0, y: 322, z: 0 },
        };
      },
      getGovernanceStats: () => ({
        totalCorrections: 0,
        totalAcks: 0,
        totalReplays: 0,
        totalHardSnaps: 0,
        lastCorrectionDistance: 0,
      }),
      getCurrentJitterMs: () => 0,
      getCurrentSoftPositionError: () => 2,
    };
    const remotePlayer = {
      getRenderedPosition: () => ({ x: 0, y: 0, z: 0 }),
      getVisibleEntityIds: () => [],
    };
    const edit = {
      getSelectedMaterialId: () => 1,
      getHotbarState: () => ({
        selectedIndex: 0,
        selected: { kind: "material", label: "dirt", materialId: 1 },
        entries: [{ kind: "material", label: "dirt", materialId: 1 }],
      }),
    };
    const render = {
      getCurrentSelection: () => null,
      getRendererDebugSnapshot: () => ({
        requested: "auto",
        active: "webgl",
        renderer: "WebGLRenderer",
        backend: "WebGLRenderer",
        webgpuAvailable: false,
        fallbackReason: "navigator_gpu_unavailable_or_insecure_context",
      }),
    };
    const world = {
      mode: "offline-local",
      debugSnapshot: () => ({ mode: "offline-local" }),
      store: {
        listChunks: () => [],
        totalSolidBlocks: () => 0,
        editStats: { placed: 0, broken: 0, rejected: 0, conflicts: 0 },
      },
    };

    const view = new HudView(
      hud,
      world as unknown as VoxelWorldAdapter,
      transport as unknown as TransportPump,
      localPlayer as unknown as LocalPlayerController,
      remotePlayer as unknown as RemotePlayerController,
      edit as unknown as WorldEditController,
      render as unknown as RenderOrchestrator,
    );

    for (let i = 0; i < 6; i += 1) {
      view.onFrame(16 * i, 16);
    }

    expect(transport.debugCalls).toBe(1);
    expect(localPlayer.stateCalls).toBe(1);
    expect(hud.textContent).toContain("player_mode: airborne");
    expect(hud.textContent).toContain("player_vy: 322.0");
    expect(hud.textContent).toContain("renderer: webgl");
    expect(hud.textContent).toContain("Space jump");
  });

  it("surfaces transport and voxel failures as persistent HUD alerts", () => {
    const alerts = buildRuntimeAlerts(
      {
        mode: "server-authoritative",
        seedState: "failed",
        subscriptionState: "idle",
        lastError: "dev_seed_failed:500",
        transport: {
          available: false,
          connectionStatus: "disconnected",
          lastError: "impact_intent_blocked:disconnected:socket_closed:1006:closed",
          lastBlockedSend: {
            source: "impact_intent",
            reason: "disconnected:socket_closed:1006:closed",
          },
        },
      },
      {
        connectionStatus: "disconnected",
        connectionLostReason: "socket_closed:1006:closed",
        webSocketUrl: "ws://127.0.0.1:20000/ingame/ws",
        authBaseUrl: "",
        blockedInputCount: 3,
        lastBlockedInputReason: "disconnected:socket_closed:1006:closed",
      },
      false,
      "server-authoritative",
    );

    expect(alerts).toEqual(
      expect.arrayContaining([
        expect.stringContaining("TRANSPORT DISCONNECTED"),
        expect.stringContaining("MOVEMENT INPUT BLOCKED"),
        expect.stringContaining("VOXEL DEV SEED FAILED"),
        expect.stringContaining("VOXEL TRANSPORT UNAVAILABLE"),
        expect.stringContaining("VOXEL SEND BLOCKED"),
      ]),
    );
  });

  it("tells the user that Heat also enables the field overlay", () => {
    const hud = { textContent: "" } as HTMLDivElement;
    const bus = new EventBus<AppEvents>();

    const view = new HudView(
      hud,
      minimalWorld() as unknown as VoxelWorldAdapter,
      minimalTransport() as unknown as TransportPump,
      minimalLocalPlayer() as unknown as LocalPlayerController,
      minimalRemotePlayer() as unknown as RemotePlayerController,
      minimalEdit() as unknown as WorldEditController,
      minimalRender() as unknown as RenderOrchestrator,
      bus,
    );

    bus.emit("world:voxel-heated", {
      coord: { x: 3, y: 4, z: 5 },
      targetTemperatureCelsius: 800,
      source: "test",
    });
    view.onFrame(0, 0);

    expect(hud.textContent).toContain("heated 3,4,5 to 800C; field overlay on");
  });

  it("explains that idle dev_seed means transport has not become usable yet", () => {
    const alerts = buildRuntimeAlerts(
      {
        mode: "server-authoritative",
        seedState: "idle",
        subscriptionState: "idle",
        transport: {
          available: false,
          connectionStatus: "connecting",
          connectionPhase: "auto_login",
        },
      },
      {
        connectionStatus: "connecting",
        connectionPhase: "auto_login",
        webSocketUrl: "ws://127.0.0.1:5173/ingame/ws",
        authBaseUrl: "",
      },
      false,
      "server-authoritative",
    );

    expect(alerts).toEqual(
      expect.arrayContaining([
        expect.stringContaining("TRANSPORT CONNECTING: phase=auto_login"),
        expect.stringContaining("VOXEL DEV SEED NOT STARTED"),
        expect.stringContaining("connecting:auto_login"),
      ]),
    );
    expect(alerts.some((alert) => alert.includes("VOXEL WAITING FOR DEV SEED: idle"))).toBe(false);
  });

  it("does not treat pending region preparation as a blocking voxel alert after subscription starts", () => {
    const alerts = buildRuntimeAlerts(
      {
        mode: "server-authoritative",
        seedState: "pending",
        subscriptionState: "requested",
        transport: {
          available: true,
          connectionStatus: "connected",
          connectionPhase: "ready",
        },
      },
      {
        connectionStatus: "connected",
        connectionPhase: "ready",
        webSocketUrl: "ws://127.0.0.1:5173/ingame/ws",
        authBaseUrl: "",
      },
      true,
      "server-authoritative",
    );

    expect(alerts.some((alert) => alert.includes("VOXEL WAITING FOR DEV SEED"))).toBe(false);
    expect(alerts.some((alert) => alert.includes("VOXEL DEV SEED NOT STARTED"))).toBe(false);
    expect(alerts.some((alert) => alert.includes("VOXEL SUBSCRIPTION NOT ACTIVE"))).toBe(false);
  });
});

function minimalWorld() {
  return {
    mode: "offline-local",
    debugSnapshot: () => ({ mode: "offline-local" }),
    store: {
      listChunks: () => [],
      totalSolidBlocks: () => 0,
      editStats: { placed: 0, broken: 0, rejected: 0, conflicts: 0 },
    },
  };
}

function minimalTransport() {
  return {
    getMode: () => "server-ws",
    isReady: () => true,
    debugSnapshot: () => ({ mode: "server-ws", ready: true }),
  };
}

function minimalLocalPlayer() {
  return {
    getRenderedPosition: () => ({ x: 0, y: 0, z: 0 }),
    getAuthoritativePosition: () => ({ x: 0, y: 0, z: 0 }),
    getCurrentState: () => ({
      tick: 1,
      seq: 1,
      movementMode: "grounded",
      velocity: { x: 0, y: 0, z: 0 },
    }),
    getGovernanceStats: () => ({
      totalCorrections: 0,
      totalAcks: 0,
      totalReplays: 0,
      totalHardSnaps: 0,
      lastCorrectionDistance: 0,
    }),
    getCurrentJitterMs: () => 0,
    getCurrentSoftPositionError: () => 0,
  };
}

function minimalRemotePlayer() {
  return {
    getRenderedPosition: () => ({ x: 0, y: 0, z: 0 }),
    getVisibleEntityIds: () => [],
  };
}

function minimalEdit() {
  return {
    getSelectedMaterialId: () => 1,
    getHotbarState: () => ({
      selectedIndex: 0,
      selected: { kind: "material", label: "dirt", materialId: 1 },
      entries: [{ kind: "material", label: "dirt", materialId: 1 }],
    }),
  };
}

function minimalRender() {
  return {
    getCurrentSelection: () => null,
    getRendererDebugSnapshot: () => ({
      requested: "auto",
      active: "webgl",
      renderer: "WebGLRenderer",
      backend: "WebGLRenderer",
      webgpuAvailable: false,
      fallbackReason: "navigator_gpu_unavailable_or_insecure_context",
    }),
  };
}
