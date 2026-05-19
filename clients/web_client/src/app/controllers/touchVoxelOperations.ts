import type { CliCommandResult } from "../../observe/cli";
import type { ObserveFieldValue } from "../../observe/logger";
import type { AppEvents } from "../../shared/events/events";
import { formatCoord } from "../../shared/runtimeFormat";
import { chunkCoordFromMacro } from "../../voxel/core/gridUtils";
import type { FMacroCoord } from "../../voxel/core/types";

const TOUCH_SOURCE = "touch_button";
const TOUCH_HEAT_TARGET_CELSIUS = 800;
const TOUCH_CONDUCTION_SOURCE_POTENTIAL = 120;
const TOUCH_CONDUCTION_MAX_TICKS = 90;

export interface TouchVoxelOperationPorts {
  toggleField(): void;
  emitHeat(): void;
  emitConduct(): void;
  subscribeAim(): void;
}

export interface TouchVoxelOperationDeps {
  toggleFieldDebugOverlay(): void;
  emitAppEvent<K extends keyof AppEvents>(event: K, payload: AppEvents[K]): void;
  getSelectedOccupiedMacro(): FMacroCoord | null;
  executeCliCommand(command: string, args: string[], source?: string): CliCommandResult;
  emitObserve(category: string, event: string, fields: Record<string, ObserveFieldValue>): void;
}

export function createTouchVoxelOperationPorts(
  deps: TouchVoxelOperationDeps,
): TouchVoxelOperationPorts {
  return {
    toggleField: () => deps.toggleFieldDebugOverlay(),
    emitHeat: () => {
      deps.emitAppEvent("input:set-selected-voxel-temperature", {
        source: TOUCH_SOURCE,
        targetTemperatureCelsius: TOUCH_HEAT_TARGET_CELSIUS,
      });
    },
    emitConduct: () => {
      deps.emitAppEvent("input:conduct-selected-voxel", {
        source: TOUCH_SOURCE,
        sourcePotential: TOUCH_CONDUCTION_SOURCE_POTENTIAL,
        maxTicks: TOUCH_CONDUCTION_MAX_TICKS,
      });
    },
    subscribeAim: () => subscribeAimedChunk(deps),
  };
}

function subscribeAimedChunk(deps: TouchVoxelOperationDeps): void {
  const selectedMacro = deps.getSelectedOccupiedMacro();
  if (!selectedMacro) {
    deps.emitAppEvent("world:edit-rejected", {
      reason: "no_selection",
      source: TOUCH_SOURCE,
    });
    deps.emitObserve("voxel", "touch_subscribe_rejected", {
      reason: "no_selection",
      source: TOUCH_SOURCE,
    });
    return;
  }

  const centerChunk = chunkCoordFromMacro(selectedMacro);
  const result = deps.executeCliCommand(
    "voxel_subscribe",
    [String(centerChunk.x), String(centerChunk.y), String(centerChunk.z), "0"],
    TOUCH_SOURCE,
  );
  deps.emitObserve("voxel", result.ok ? "touch_subscribe" : "touch_subscribe_rejected", {
    center_chunk: formatCoord(centerChunk),
    ok: result.ok,
    text: result.text,
  });
}
