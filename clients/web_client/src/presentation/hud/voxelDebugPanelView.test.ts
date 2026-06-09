import { describe, expect, it } from "vitest";
import type { CliCommandResult } from "../../observe/cli";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import {
  renderVoxelDebugPanelHtml,
  VoxelDebugPanelView,
  type VoxelDebugPanelCommandPort,
  type VoxelPanelFieldOverlaySnapshot,
} from "./voxelDebugPanelView";

class FakeVoxelPanelRoot {
  innerHTML = "";
  private clickListener: ((event: MouseEvent) => void) | null = null;
  private inputListener: ((event: Event) => void) | null = null;
  private pointerDownListener: ((event: PointerEvent) => void) | null = null;

  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "click") {
      this.clickListener = listener as (event: MouseEvent) => void;
    }
    if (type === "input") {
      this.inputListener = listener as (event: Event) => void;
    }
    if (type === "pointerdown") {
      this.pointerDownListener = listener as (event: PointerEvent) => void;
    }
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "click" && this.clickListener === listener) {
      this.clickListener = null;
    }
    if (type === "input" && this.inputListener === listener) {
      this.inputListener = null;
    }
    if (type === "pointerdown" && this.pointerDownListener === listener) {
      this.pointerDownListener = null;
    }
  }

  clickAction(action: string): void {
    this.clickListener?.({
      preventDefault: () => undefined,
      target: {
        closest: () => ({
          getAttribute: (name: string) => (name === "data-voxel-action" ? action : null),
        }),
      },
    } as unknown as MouseEvent);
  }

  inputField(field: string, value: string): void {
    this.inputListener?.({
      target: {
        value,
        getAttribute: (name: string) => (name === "data-voxel-input" ? field : null),
      },
    } as unknown as Event);
  }

  pointerDown(): boolean {
    let stopped = false;
    this.pointerDownListener?.({
      stopPropagation: () => {
        stopped = true;
      },
    } as unknown as PointerEvent);
    return stopped;
  }
}

class FakeCommands implements VoxelDebugPanelCommandPort {
  readonly calls: Array<{ command: string; args: string[]; source?: string }> = [];

  executeCliCommand(command: string, args: string[], source?: string): CliCommandResult {
    this.calls.push(source === undefined ? { command, args } : { command, args, source });
    return { ok: true, command, text: `${command} ok`, data: { args } };
  }
}

describe("VoxelDebugPanelView", () => {
  it("renders authoritative voxel status, shortcut guidance, CLI hints, and only pointer-worthy controls", () => {
    const html = renderVoxelDebugPanelHtml(
      makeVoxelSnapshot(),
      undefined,
      {
        ok: true,
        command: "voxel_sync",
        text: "voxel sync",
      },
      makeFieldOverlaySnapshot(),
    );

    expect(html).toContain("Voxel Runtime");
    expect(html).toContain("active");
    expect(html).toContain("<dd>3</dd>");
    expect(html).toContain("voxel-panel-stat--field");
    expect(html).toContain(
      "field=on regions=1 electric=2 current=0 smoke=12 smokeField=3 oxygenDeficit=28.5%",
    );
    expect(html).toContain("data-voxel-panel-shortcuts");
    expect(html).toContain("WASD");
    expect(html).toContain("F");
    expect(html).toContain("Z / X / C");
    expect(html).toContain("window.__voxelCli?.run(&quot;snapshot&quot;)");
    expect(html).toContain("voxel_auto_circuit");
    expect(html).toContain("voxel_subscribe");
    expect(html).toContain('data-voxel-action="field-overlay"');
    expect(html).toContain('data-voxel-action="auto-circuit-selected"');
    expect(html).toContain('data-voxel-action="guide"');
    expect(html).toContain('data-voxel-action="subscribe"');
    expect(html).not.toContain('data-voxel-action="impact"');
    expect(html).not.toContain('data-voxel-action="heat-selected"');
    expect(html).not.toContain('data-voxel-action="cool-selected"');
    expect(html).not.toContain('data-voxel-action="conduct"');
    expect(html).not.toContain('data-voxel-action="conduct-source-selection"');
    expect(html).not.toContain('data-voxel-action="probe"');
    expect(html).toContain("voxel_sync: voxel sync");
  });

  it("summarizes field overlay as inactive when no field snapshot is available", () => {
    const html = renderVoxelDebugPanelHtml(makeVoxelSnapshot());

    expect(html).toContain(
      "field=off regions=0 electric=0 current=0 smoke=0 smokeField=0 oxygenDeficit=0.0%",
    );
  });

  it("renders sync failures in the visible panel instead of hiding them in JSON", () => {
    const html = renderVoxelDebugPanelHtml({
      mode: "server-authoritative",
      seedState: "failed",
      subscriptionState: "idle",
      lastError: "dev_seed_failed:500",
      transport: {
        available: false,
        connectionStatus: "disconnected",
        connectionLostReason: "socket_closed:1006:closed",
        lastBlockedSend: {
          source: "impact_intent",
          reason: "disconnected:socket_closed:1006:closed",
        },
      },
    });

    expect(html).toContain("voxel-panel-alerts");
    expect(html).toContain("dev_seed failed: dev_seed_failed:500");
    expect(html).toContain("transport unavailable: socket_closed:1006:closed");
    expect(html).toContain("send blocked: impact_intent");
    expect(html).toContain("voxel-panel-badge is-error");
  });

  it("states that idle dev_seed is waiting on transport readiness", () => {
    const html = renderVoxelDebugPanelHtml({
      mode: "server-authoritative",
      seedState: "idle",
      subscriptionState: "idle",
      transport: {
        available: false,
        connectionStatus: "connecting",
        connectionPhase: "auto_login",
      },
    });

    expect(html).toContain("dev_seed not started: waiting for transport");
    expect(html).toContain("connecting:auto_login");
    expect(html).not.toContain("waiting for dev_seed: idle");
  });

  it("does not show pending region preparation as a blocking sync alert after subscription starts", () => {
    const html = renderVoxelDebugPanelHtml({
      mode: "server-authoritative",
      seedState: "pending",
      subscriptionState: "requested",
      transport: {
        available: true,
        connectionStatus: "connected",
        connectionPhase: "ready",
      },
    });

    expect(html).not.toContain("waiting for dev_seed");
    expect(html).not.toContain("dev_seed not started");
    expect(html).not.toContain("subscription not active: requested");
  });

  it("keeps the pointer-worthy Subscribe control wired to the same command port as the CLI", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(root as unknown as HTMLDivElement, commands, makeWorld());

    root.inputField("subscribeCx", "8");
    root.inputField("subscribeCy", "0");
    root.inputField("subscribeCz", "24");
    root.inputField("subscribeRadius", "2");
    root.clickAction("subscribe");

    expect(commands.calls).toEqual([{ command: "voxel_subscribe", args: ["8", "0", "24", "2"] }]);
    expect(root.innerHTML).toContain("voxel_subscribe ok");
    expect(root.pointerDown()).toBe(true);

    view.dispose();
    root.clickAction("refresh");
    expect(commands.calls).toHaveLength(1);
  });

  it("opens the operation guide from the visible panel without hitting the CLI", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    let openCount = 0;
    const view = new VoxelDebugPanelView(
      root as unknown as HTMLDivElement,
      commands,
      makeWorld(),
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      () => {
        openCount += 1;
      },
    );

    root.clickAction("guide");

    expect(openCount).toBe(1);
    expect(commands.calls).toEqual([]);
    expect(root.innerHTML).toContain("operation guide opened");

    view.dispose();
  });

  it("keeps subscribe inputs editable across panel refreshes", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(root as unknown as HTMLDivElement, commands, makeWorld());

    root.inputField("subscribeCx", "3");
    root.inputField("subscribeCy", "4");
    root.inputField("subscribeCz", "5");
    root.inputField("subscribeRadius", "1");
    view.onFrame(0, 300);
    root.clickAction("subscribe");

    expect(commands.calls).toEqual([{ command: "voxel_subscribe", args: ["3", "4", "5", "1"] }]);
  });

  it("sends a server rebind probe from the visible panel", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(root as unknown as HTMLDivElement, commands, makeWorld());

    root.clickAction("rebind");

    expect(commands.calls).toEqual([{ command: "voxel_probe", args: ["voxel_rebind 779 all"] }]);

    view.dispose();
  });

  it("lets the visible panel capture selected conduction endpoints and run conduct", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const selections = [
      { x: 5, y: 1, z: 0 },
      { x: 8, y: 1, z: 0 },
    ];
    const view = new VoxelDebugPanelView(
      root as unknown as HTMLDivElement,
      commands,
      makeWorld(),
      undefined,
      undefined,
      () => selections.shift() ?? null,
    );

    root.clickAction("conduct-source-selection");
    root.clickAction("conduct-target-selection");
    root.inputField("conductPotential", "150");
    root.inputField("conductTicks", "60");
    root.inputField("conductOutputMode", "ac");
    root.inputField("conductVoltage", "240");
    root.inputField("conductCurrentLimitAmps", "12.5");
    root.inputField("conductFrequencyHz", "60");
    root.inputField("conductLoadCurrentAmps", "6.25");
    root.inputField("conductEnergyBudgetJoules", "5000");
    root.clickAction("conduct");

    expect(commands.calls).toEqual([
      {
        command: "voxel_conduct",
        args: [
          "5",
          "1",
          "0",
          "8",
          "1",
          "0",
          "150",
          "60",
          "ac",
          "240",
          "12.5",
          "60",
          "6.25",
          "5000",
        ],
        source: "voxel_panel",
      },
    ]);
    expect(root.innerHTML).toContain("voxel_conduct ok");

    view.dispose();
  });

  it("lets keyboard shortcuts capture selected conduction endpoints", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const selections = [
      { x: 2, y: 1, z: 0 },
      { x: 6, y: 1, z: 0 },
    ];
    const view = new VoxelDebugPanelView(
      root as unknown as HTMLDivElement,
      commands,
      makeWorld(),
      undefined,
      undefined,
      () => selections.shift() ?? null,
    );

    expect(view.captureConductionEndpoint("source", "keyboard")).toMatchObject({
      ok: true,
      command: "conduct-source-selection",
    });
    const targetResult = view.captureConductionEndpoint("target", "keyboard");
    expect(targetResult).toMatchObject({
      ok: true,
      command: "conduct-target-selection",
      text: "target set to 6,1,0",
    });
    expect(root.innerHTML).toContain("<kbd>source</kbd><span>2,1,0</span>");
    expect(root.innerHTML).toContain("<kbd>target</kbd><span>6,1,0</span>");
    root.clickAction("conduct");

    expect(commands.calls).toEqual([
      {
        command: "voxel_conduct",
        args: ["2", "1", "0", "6", "1", "0", "120", "90"],
        source: "voxel_panel",
      },
    ]);

    view.dispose();
  });

  it("lets the visible panel trigger a manual auto-circuit refresh at the selected voxel", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(
      root as unknown as HTMLDivElement,
      commands,
      makeWorld(),
      undefined,
      undefined,
      () => ({ x: 4, y: 12, z: 12 }),
    );

    root.inputField("conductTicks", "180");
    root.clickAction("auto-circuit-selected");

    expect(commands.calls).toEqual([
      {
        command: "voxel_auto_circuit",
        args: ["4", "12", "12", "180"],
        source: "voxel_panel",
      },
    ]);
    expect(root.innerHTML).toContain("voxel_auto_circuit ok");

    view.dispose();
  });

  it("uses the aimed conduction pair when conduct coordinates are still blank", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(
      root as unknown as HTMLDivElement,
      commands,
      makeWorld(),
      undefined,
      undefined,
      undefined,
      () => ({
        sourceCoord: { x: 5, y: 0, z: 5 },
        targetCoord: { x: 5, y: 3, z: 5 },
      }),
    );

    root.clickAction("conduct");

    expect(commands.calls).toEqual([
      {
        command: "voxel_conduct",
        args: ["5", "0", "5", "5", "3", "5", "120", "90"],
        source: "voxel_panel",
      },
    ]);
    expect(root.innerHTML).toContain("<kbd>source</kbd><span>5,0,5</span>");
    expect(root.innerHTML).toContain("<kbd>target</kbd><span>5,3,5</span>");
    expect(root.innerHTML).toContain("voxel_conduct ok");

    view.dispose();
  });

  it("lets keyboard shortcuts submit the current conduction form", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(root as unknown as HTMLDivElement, commands, makeWorld());

    root.inputField("conductSourceX", "1");
    root.inputField("conductSourceY", "2");
    root.inputField("conductSourceZ", "3");
    root.inputField("conductTargetX", "4");
    root.inputField("conductTargetY", "5");
    root.inputField("conductTargetZ", "6");
    root.inputField("conductPotential", "180");
    root.inputField("conductTicks", "45");

    expect(view.submitConduction("keyboard")).toMatchObject({
      ok: true,
      command: "voxel_conduct",
    });

    expect(commands.calls).toEqual([
      {
        command: "voxel_conduct",
        args: ["1", "2", "3", "4", "5", "6", "180", "45"],
        source: "keyboard",
      },
    ]);
    expect(root.innerHTML).toContain("voxel_conduct ok");

    view.dispose();
  });
});

function makeWorld() {
  return {
    debugSnapshot: () => makeVoxelSnapshot(),
  } as unknown as VoxelWorldAdapter;
}

function makeVoxelSnapshot(): Record<string, unknown> {
  return {
    mode: "server-authoritative",
    logicalSceneId: 779,
    seedState: "ready",
    subscriptionState: "active",
    lastSnapshot: {
      chunkCoord: "0,0,0",
      chunkVersion: 2,
    },
    lastIntentResult: {
      resultCodeName: "accepted",
      resultRef: 2,
    },
    transport: {
      receivedVoxelSnapshotCount: 3,
    },
  };
}

function makeFieldOverlaySnapshot(): VoxelPanelFieldOverlaySnapshot {
  return {
    visible: true,
    regionCount: 1,
    regions: [
      {
        regionId: 43,
        chunkCoord: { cx: 0, cy: 0, cz: 0 },
        temperatureCells: 0,
        electricCells: 2,
        smokeParticles: 12,
        smokeDensityCells: 3,
        maxOxygenDeficitPercent: 28.5,
      },
    ],
  };
}
