import { describe, expect, it } from "vitest";
import type { CliCommandResult } from "../../observe/cli";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import {
  renderVoxelDebugPanelHtml,
  VoxelDebugPanelView,
  type VoxelDebugPanelCommandPort,
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
  readonly calls: Array<{ command: string; args: string[] }> = [];

  executeCliCommand(command: string, args: string[]): CliCommandResult {
    this.calls.push({ command, args });
    return { ok: true, command, text: `${command} ok`, data: { args } };
  }
}

describe("VoxelDebugPanelView", () => {
  it("renders authoritative voxel state and command buttons", () => {
    const html = renderVoxelDebugPanelHtml(makeVoxelSnapshot(), undefined, {
      ok: true,
      command: "voxel_sync",
      text: "voxel sync",
    });

    expect(html).toContain("Server Voxel");
    expect(html).toContain("active");
    expect(html).toContain("<dd>3</dd>");
    expect(html).toContain('data-voxel-action="rebind"');
    expect(html).toContain('data-voxel-action="impact"');
    expect(html).toContain('data-voxel-input="material"');
    expect(html).toContain("voxel_sync: voxel sync");
  });

  it("delegates visible controls to the same command port as the CLI", () => {
    const root = new FakeVoxelPanelRoot();
    const commands = new FakeCommands();
    const view = new VoxelDebugPanelView(root as unknown as HTMLDivElement, commands, makeWorld());

    root.inputField("impactX", "8");
    root.inputField("impactY", "16");
    root.inputField("impactZ", "24");
    root.inputField("material", "stone");
    root.clickAction("impact");

    expect(commands.calls).toEqual([{ command: "voxel_impact", args: ["8", "16", "24", "stone"] }]);
    expect(root.innerHTML).toContain("voxel_impact ok");
    expect(root.pointerDown()).toBe(true);

    view.dispose();
    root.clickAction("refresh");
    expect(commands.calls).toHaveLength(1);
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

    expect(commands.calls).toEqual([
      { command: "voxel_probe", args: ["voxel_rebind 779 all"] },
    ]);

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
