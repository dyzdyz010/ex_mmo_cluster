import type { ObserveEvent } from "./logger";
import { ObserveLog } from "./logger";

export interface CliCommandResult {
  ok: boolean;
  command: string;
  text: string;
  data?: unknown;
}

export interface CliCommandHandler {
  executeCliCommand(command: string, args: string[]): CliCommandResult;
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
    "cell <x> <y> <z>",
    "place <x> <y> <z> [material]",
    "break <x> <y> <z>",
    "prefabs",
    "prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>",
    "prefab_place <name> <x> <y> <z>",
    "select_material <id|name>",
    "player",
    "players",
    "transport",
    "reconcile_stats",
    "edit_stats",
    "frame_trace_start [frames]",
    "frame_trace",
    "frame_trace_clear",
    "logs [limit]",
  ].join("\n");
}

export function installCli(windowObject: Window, logger: ObserveLog, handler: CliCommandHandler): void {
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

      const result = handler.executeCliCommand(command, args);
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
