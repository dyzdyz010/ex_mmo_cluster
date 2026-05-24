import type { ObserveEvent, ObserveLog } from "./logger";

export interface CliCommandResult {
  ok: boolean;
  command: string;
  text: string;
  data?: unknown;
}

export interface CliCommandHandler {
  executeCliCommand(command: string, args: string[], source?: string): CliCommandResult;
}

export interface VoxelCli {
  run(commandLine: string): CliCommandResult;
  help(): string;
  recent(limit?: number): ObserveEvent[];
  clearLogs(): void;
}

function splitCommandLine(commandLine: string): string[] {
  return commandLine
    .trim()
    .split(/\s+/)
    .filter((part) => part.length > 0);
}

function defaultHelpText(): string {
  return [
    "help",
    "snapshot",
    "chunks [limit]",
    "voxel_sync",
    "voxel_probe [command]",
    "voxel_probe voxel_rebind <logical_scene_id> <region_id|all>",
    "voxel_subscribe <cx> <cy> <cz> [radius]",
    "voxel_unsubscribe <cx> <cy> <cz>",
    "voxel_impact <x> <y> <z> [material]",
    "voxel_temp <x> <y> <z> <target_temperature_celsius> [max_ticks]",
    "voxel_heat <x> <y> <z> [target_temperature_celsius] [max_ticks]",
    "voxel_cool <x> <y> <z> [target_temperature_celsius] [max_ticks]",
    "voxel_conduct <sx> <sy> <sz> <tx> <ty> <tz> [source_potential] [max_ticks] [dc|ac|pulse] [voltage] [current_limit_amps] [frequency_hz] [load_current_amps] [energy_budget_joules]",
    "voxel_discharge <sx> <sy> <sz> <tx> <ty> <tz> [source_potential] [max_ticks] [dc|ac|pulse] [voltage] [current_limit_amps] [frequency_hz] [load_current_amps] [energy_budget_joules]",
    "voxel_auto_circuit <x> <y> <z> [max_ticks]",
    "field_overlay [on|off]",
    "target_probe",
    "chunk_versions",
    "scene_regions [on|off]",
    "cell <x> <y> <z>",
    "micro_cell <x> <y> <z> <mx> <my> <mz>",
    "place <x> <y> <z> [material]",
    "break <x> <y> <z>",
    "hotbar",
    "hotbar_select <index>",
    "prefabs",
    "prefab_sockets <name>",
    "prefab_boundary <name>",
    "prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>",
    "prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]",
    "prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rot0|rot90|rot180|rot270] [anchor_micro_x anchor_micro_y anchor_micro_z]",
    "prefab_place_snap <name> <x> <y> <z> <nx> <ny> <nz> [rot0|rot90|rot180|rot270] [anchor_micro_x anchor_micro_y anchor_micro_z]",
    "prefab_snap_preview <name> <target-instance> <target-socket> [incoming-socket] [rot0|rot90|rot180|rot270]",
    "prefab_place_socket <name> <target-instance> <target-socket> [incoming-socket] [rot0|rot90|rot180|rot270]",
    "select_prefab <name>",
    "select_material <id|name>",
    "world_export",
    "world_import <json>",
    "world_save [slot]",
    "world_load [slot]",
    "player",
    "players",
    "aoi",
    "remote <cid>",
    "jump",
    "transport",
    "reconcile_stats",
    "sync_stats",
    "edit_stats",
    "frame_trace_start [frames]",
    "frame_trace",
    "frame_trace_clear",
    "logs [limit]",
  ].join("\n");
}

export function installCli(
  windowObject: Window,
  logger: ObserveLog,
  handler: CliCommandHandler,
): void {
  const cli: VoxelCli = {
    run(commandLine: string): CliCommandResult {
      const parts = splitCommandLine(commandLine);
      if (parts.length === 0) {
        const result = { ok: false, command: "", text: "empty command" };
        logger.emit("cli", "empty_command", {});
        return result;
      }

      const command = parts[0];
      if (!command) {
        const result = { ok: false, command: "", text: "empty command" };
        logger.emit("cli", "empty_command", {});
        return result;
      }
      const args = parts.slice(1);
      if (command === "help") {
        const result = { ok: true, command, text: defaultHelpText() };
        logger.emit("cli", "help", { command_count: defaultHelpText().split("\n").length });
        console.info(result.text);
        return result;
      }

      if (command === "logs") {
        const limit = Number.parseInt(args[0] ?? "20", 10);
        const events = logger.recent(Number.isFinite(limit) ? limit : 20);
        const text = events.map((entry) => JSON.stringify(entry)).join("\n");
        const result: CliCommandResult = { ok: true, command, text, data: events };
        logger.emit("cli", "logs", { limit: events.length });
        console.info(result.text);
        return result;
      }

      const result = handler.executeCliCommand(command, args, "cli");
      logger.emit("cli", "command", {
        command,
        ok: result.ok,
        text: result.text ?? "",
      });
      console.info(result.text);
      return result;
    },

    help(): string {
      return defaultHelpText();
    },

    recent(limit: number = 20): ObserveEvent[] {
      return logger.recent(limit);
    },

    clearLogs(): void {
      logger.clear();
      logger.emit("cli", "clear_logs", {});
    },
  };

  windowObject.__voxelCli = cli;
  windowObject.__voxelObserve = {
    recent(limit: number = 40): ObserveEvent[] {
      return logger.recent(limit);
    },
    snapshot(): ObserveEvent[] {
      return logger.snapshot();
    },
    clear(): void {
      logger.clear();
    },
  };

  logger.emit("cli", "installed", {
    commands: defaultHelpText().split("\n").length,
  });
}

declare global {
  interface Window {
    __voxelCli?: VoxelCli;
    __voxelObserve?: {
      recent(limit?: number): ObserveEvent[];
      snapshot(): ObserveEvent[];
      clear(): void;
    };
  }
}

export {};
