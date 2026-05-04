import { HudView } from "./hudView";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";
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
});
