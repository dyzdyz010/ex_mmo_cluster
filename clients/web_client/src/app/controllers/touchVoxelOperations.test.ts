import { describe, expect, it, vi } from "vitest";
import {
  createTouchVoxelOperationPorts,
  type TouchVoxelOperationDeps,
} from "./touchVoxelOperations";

function makeDeps(): TouchVoxelOperationDeps {
  return {
    toggleFieldDebugOverlay: vi.fn(),
    emitAppEvent: vi.fn() as unknown as TouchVoxelOperationDeps["emitAppEvent"],
    getSelectedOccupiedMacro: vi.fn(() => ({ x: 17, y: 0, z: -1 })),
    executeCliCommand: vi.fn(() => ({
      ok: true,
      command: "voxel_subscribe",
      text: "voxel subscribe sent",
    })),
    emitObserve: vi.fn(),
  };
}

describe("touch voxel operations", () => {
  it("maps mobile operation buttons onto existing field, heat, and conduction intents", () => {
    const deps = makeDeps();
    const ports = createTouchVoxelOperationPorts(deps);

    ports.toggleField();
    expect(deps.toggleFieldDebugOverlay).toHaveBeenCalledOnce();

    ports.emitHeat();
    expect(deps.emitAppEvent).toHaveBeenCalledWith("input:set-selected-voxel-temperature", {
      source: "touch_button",
      targetTemperatureCelsius: 800,
    });

    ports.emitConduct();
    expect(deps.emitAppEvent).toHaveBeenCalledWith("input:conduct-selected-voxel", {
      source: "touch_button",
      sourcePotential: 120,
      maxTicks: 90,
    });
  });

  it("subscribes the chunk under the aimed block without requiring mobile coordinate entry", () => {
    const deps = makeDeps();
    const ports = createTouchVoxelOperationPorts(deps);

    ports.subscribeAim();

    expect(deps.executeCliCommand).toHaveBeenCalledWith(
      "voxel_subscribe",
      ["1", "0", "-1", "0"],
      "touch_button",
    );
    expect(deps.emitObserve).toHaveBeenCalledWith("voxel", "touch_subscribe", {
      center_chunk: "1,0,-1",
      ok: true,
      text: "voxel subscribe sent",
    });
  });

  it("reports a normal edit rejection when aim subscribe has no selected block", () => {
    const deps = makeDeps();
    vi.mocked(deps.getSelectedOccupiedMacro).mockReturnValue(null);
    const ports = createTouchVoxelOperationPorts(deps);

    ports.subscribeAim();

    expect(deps.executeCliCommand).not.toHaveBeenCalled();
    expect(deps.emitAppEvent).toHaveBeenCalledWith("world:edit-rejected", {
      reason: "no_selection",
      source: "touch_button",
    });
    expect(deps.emitObserve).toHaveBeenCalledWith("voxel", "touch_subscribe_rejected", {
      reason: "no_selection",
      source: "touch_button",
    });
  });
});
