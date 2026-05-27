import { describe, expect, it, vi } from "vitest";
import { installCli, type CliCommandHandler } from "./cli";
import type { ObserveLog } from "./logger";

describe("voxel CLI help", () => {
  it("documents microgrid inspection without exposing microgrid write commands", () => {
    const windowObject = {} as Window;
    const logger = {
      emit: vi.fn(),
      recent: vi.fn(() => []),
      clear: vi.fn(),
    } as unknown as ObserveLog;
    const handler: CliCommandHandler = {
      executeCliCommand: () => ({ ok: true, command: "noop", text: "noop" }),
    };

    installCli(windowObject, logger, handler);

    expect(windowObject.__voxelCli?.help()).toContain("micro_cell <x> <y> <z> <mx> <my> <mz>");
    expect(windowObject.__voxelCli?.help()).toContain("scene_regions [on|off]");
    expect(windowObject.__voxelCli?.help()).toContain("target_probe");
    expect(windowObject.__voxelCli?.help()).toContain("chat <world|region|local> <text...>");
    expect(windowObject.__voxelCli?.help()).toContain("voxel_auto_circuit <x> <y> <z> [max_ticks]");
    expect(windowObject.__voxelCli?.help()).not.toContain("micro_place");
    expect(windowObject.__voxelCli?.help()).not.toContain("micro_break");
  });
});
