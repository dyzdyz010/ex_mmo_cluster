import type { Vector3 } from "three";
import {
  getMaterialDefinition,
  listMaterialDefinitions,
  parseMaterialIdOrName,
} from "../../material/catalog";
import type { CliCommandHandler, CliCommandResult } from "../../observe/cli";
import type { ObserveLog } from "../../observe/logger";
import { installCli } from "../../observe/cli";
import { INTERPOLATION_DELAY_SECS } from "@domain/movement/remotePlayer";
import { EVoxelRotation, type FMacroCoord } from "../../voxel/core/types";
import type { LocalPrefab } from "../../voxel/prefab";
import type { SerializedWorldSnapshot } from "../../voxel/worldStore";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";

interface WorldStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface DevToolsDeps {
  logger: ObserveLog;
  world: VoxelWorldAdapter;
  transport: TransportPump;
  localPlayer: LocalPlayerController;
  remotePlayer: RemotePlayerController;
  edit: WorldEditController;
  render: RenderOrchestrator;
  storage?: WorldStorageLike;
}

/**
 * DevTools CLI: implements the CliCommandHandler by dispatching to whichever
 * controller owns the requested data. It carries no game state itself.
 */
export class DevToolsCli implements CliCommandHandler {
  constructor(private readonly deps: DevToolsDeps) {}

  install(target: Window): void {
    installCli(target, this.deps.logger, this);
  }

  executeCliCommand(command: string, args: string[]): CliCommandResult {
    switch (command) {
      case "snapshot":
        return this.ok(command, this.snapshotText(), this.snapshotData());
      case "chunks":
        return this.cmdChunks(command, args);
      case "cell":
        return this.cmdCell(command, args);
      case "place":
        return this.cmdPlace(command, args);
      case "break":
        return this.cmdBreak(command, args);
      case "hotbar":
        return this.ok(command, "hotbar", this.deps.edit.getHotbarState());
      case "hotbar_select":
        return this.cmdHotbarSelect(command, args);
      case "prefabs":
        return this.ok(command, "prefab list", this.deps.world.listPrefabs().map(serializePrefabForCli));
      case "prefab_capture":
        return this.cmdPrefabCapture(command, args);
      case "prefab_place":
        return this.cmdPrefabPlace(command, args);
      case "select_prefab":
        return this.cmdSelectPrefab(command, args);
      case "select_material":
        return this.cmdSelectMaterial(command, args);
      case "world_export":
        return this.cmdWorldExport(command);
      case "world_import":
        return this.cmdWorldImport(command, args);
      case "world_save":
        return this.cmdWorldSave(command, args);
      case "world_load":
        return this.cmdWorldLoad(command, args);
      case "player":
        return this.ok(command, "local player snapshot", this.playerData());
      case "players":
        return this.ok(command, "local and remote players", {
          local: this.playerData(),
          remote: {
            position: formatVector(this.deps.remotePlayer.getRenderedPosition()),
            interpolation_delay_secs: INTERPOLATION_DELAY_SECS,
          },
        });
      case "transport":
        return this.ok(command, "transport snapshot", this.transportData());
      case "reconcile_stats":
        return this.ok(command, "reconcile stats", this.deps.localPlayer.getGovernanceStats());
      case "edit_stats":
        return this.ok(command, "edit stats", { ...this.deps.world.store.editStats });
      case "frame_trace_start":
        return this.cmdFrameTraceStart(command, args);
      case "frame_trace":
        return this.ok(command, "frame trace", this.frameTraceData());
      case "frame_trace_clear":
        this.deps.localPlayer.clearFrameTrace();
        return this.ok(command, "frame trace cleared");
      default:
        return { ok: false, command, text: `unknown command: ${command}` };
    }
  }

  private cmdChunks(command: string, args: string[]): CliCommandResult {
    const limit = Number.parseInt(args[0] ?? "12", 10);
    const chunks = this.deps.world.store.chunkSummaries(Number.isFinite(limit) ? limit : 12);
    return this.ok(command, `chunks=${chunks.length}`, chunks);
  }

  private cmdCell(command: string, args: string[]): CliCommandResult {
    const coord = parseMacroCoord(args);
    if (!coord) return { ok: false, command, text: "usage: cell <x> <y> <z>" };
    return this.ok(command, `cell ${formatCoord(coord)}`, {
      coord,
      block: this.deps.world.store.getNormalBlockWorld(coord),
      environment: this.deps.world.store.getEnvironmentSummaryWorld(coord),
    });
  }

  private cmdPlace(command: string, args: string[]): CliCommandResult {
    const coord = parseMacroCoord(args);
    if (!coord) return { ok: false, command, text: "usage: place <x> <y> <z> [material]" };

    const materialArg = args[3];
    const materialId =
      materialArg !== undefined
        ? (parseMaterialIdOrName(materialArg) ?? this.deps.edit.getSelectedMaterialId())
        : this.deps.edit.getSelectedMaterialId();
    const ok = this.deps.edit.placeAt(coord, materialId, "cli");
    return this.ok(command, ok ? "placed" : "place rejected", { coord, materialId, ok });
  }

  private cmdBreak(command: string, args: string[]): CliCommandResult {
    const coord = parseMacroCoord(args);
    if (!coord) return { ok: false, command, text: "usage: break <x> <y> <z>" };
    const ok = this.deps.edit.breakAt(coord, "cli");
    return this.ok(command, ok ? "broken" : "break rejected", { coord, ok });
  }

  private cmdSelectMaterial(command: string, args: string[]): CliCommandResult {
    const materialArg = args[0];
    if (!materialArg) return { ok: false, command, text: "usage: select_material <id|name>" };
    const materialId = parseMaterialIdOrName(materialArg);
    if (materialId === null) return { ok: false, command, text: `unknown material: ${materialArg}` };
    this.deps.edit.selectMaterial(materialId, "cli");
    return this.ok(command, `selected material ${materialId}`, {
      materialId,
      material: getMaterialDefinition(materialId),
    });
  }

  private cmdSelectPrefab(command: string, args: string[]): CliCommandResult {
    const prefabName = args[0];
    if (!prefabName) return { ok: false, command, text: "usage: select_prefab <name>" };
    if (!this.deps.world.getPrefab(prefabName)) {
      return { ok: false, command, text: `unknown prefab: ${prefabName}` };
    }
    this.deps.edit.selectPrefab(prefabName, "cli");
    return this.ok(command, `selected prefab ${prefabName}`, this.deps.edit.getHotbarState());
  }

  private cmdHotbarSelect(command: string, args: string[]): CliCommandResult {
    const raw = Number.parseInt(args[0] ?? "", 10);
    if (!Number.isFinite(raw)) {
      return { ok: false, command, text: "usage: hotbar_select <index>" };
    }
    this.deps.edit.selectHotbarIndex(raw - 1, "cli");
    return this.ok(command, `hotbar selected ${raw}`, this.deps.edit.getHotbarState());
  }

  private cmdFrameTraceStart(command: string, args: string[]): CliCommandResult {
    const frames = Number.parseInt(args[0] ?? "240", 10);
    const safeFrames = Number.isFinite(frames) ? Math.max(1, Math.min(frames, 600)) : 240;
    this.deps.localPlayer.startFrameTrace(safeFrames);
    return this.ok(command, `frame trace started for ${safeFrames} frames`, {
      frames: safeFrames,
    });
  }

  private cmdPrefabCapture(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    const min = parseMacroCoord(args.slice(1, 4));
    const max = parseMacroCoord(args.slice(4, 7));
    if (!name || !min || !max) {
      return {
        ok: false,
        command,
        text: "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>",
      };
    }
    const prefab = this.deps.world.capturePrefab(name, min, max);
    this.deps.logger.emit("prefab", "capture", { name, blocks: prefab.blocks.length });
    return this.ok(command, `captured prefab ${name}`, serializePrefabForCli(prefab));
  }

  private cmdPrefabPlace(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    const origin = parseMacroCoord(args.slice(1, 4));
    if (!name || !origin) {
      return { ok: false, command, text: "usage: prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]" };
    }
    const rotation = parseRotation(args[4]);
    if (rotation === null) {
      return { ok: false, command, text: `invalid rotation: ${args[4]}` };
    }
    const result = this.deps.world.placePrefab(name, origin, rotation);
    this.deps.logger.emit("prefab", result.ok ? "place" : "place_rejected", {
      name,
      origin: formatCoord(origin),
      placed: result.placed,
      rotation,
    });
    return this.ok(
      command,
      result.ok ? `placed prefab ${name}` : `unknown prefab ${name}`,
      result,
    );
  }

  private cmdWorldExport(command: string): CliCommandResult {
    const snapshot = this.deps.world.exportSnapshot();
    const json = JSON.stringify(snapshot);
    return this.ok(command, `world exported chunks=${snapshot.chunks.length} bytes=${json.length}`, {
      snapshot,
      json,
      bytes: json.length,
    });
  }

  private cmdWorldImport(command: string, args: string[]): CliCommandResult {
    const json = args.join(" ");
    if (!json) {
      return { ok: false, command, text: "usage: world_import <json>" };
    }
    try {
      const snapshot = JSON.parse(json) as SerializedWorldSnapshot;
      this.deps.world.importSnapshot(snapshot);
      this.deps.logger.emit("world", "import", {
        chunks: this.deps.world.store.listChunks().length,
        solid_blocks: this.deps.world.store.totalSolidBlocks(),
      });
      return this.ok(command, "world imported", this.worldSummaryData());
    } catch (error) {
      return {
        ok: false,
        command,
        text: `world import failed: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
  }

  private cmdWorldSave(command: string, args: string[]): CliCommandResult {
    if (!this.deps.storage) {
      return { ok: false, command, text: "world storage unavailable" };
    }
    const slot = args[0] ?? "default";
    const snapshot = this.deps.world.exportSnapshot();
    const json = JSON.stringify(snapshot);
    this.deps.storage.setItem(worldStorageKey(slot), json);
    this.deps.logger.emit("world", "save", { slot, bytes: json.length });
    return this.ok(command, `world saved ${slot}`, { slot, bytes: json.length });
  }

  private cmdWorldLoad(command: string, args: string[]): CliCommandResult {
    if (!this.deps.storage) {
      return { ok: false, command, text: "world storage unavailable" };
    }
    const slot = args[0] ?? "default";
    const json = this.deps.storage.getItem(worldStorageKey(slot));
    if (!json) {
      return { ok: false, command, text: `world save not found: ${slot}` };
    }
    try {
      this.deps.world.importSnapshot(JSON.parse(json) as SerializedWorldSnapshot);
      this.deps.logger.emit("world", "load", { slot });
      return this.ok(command, `world loaded ${slot}`, this.worldSummaryData());
    } catch (error) {
      return {
        ok: false,
        command,
        text: `world load failed: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
  }

  private snapshotText(): string {
    return [
      `transport=${this.deps.transport.getMode()}`,
      `voxel_sync=${this.deps.world.mode}`,
      `chunks=${this.deps.world.store.listChunks().length}`,
      `solid_blocks=${this.deps.world.store.totalSolidBlocks()}`,
      `selected_material=${getMaterialDefinition(this.deps.edit.getSelectedMaterialId()).name}`,
      `player_rendered=${formatVector(this.deps.localPlayer.getRenderedPosition())}`,
      `player_authority=${formatVector(this.deps.localPlayer.getAuthoritativePosition())}`,
      `remote_rendered=${formatVector(this.deps.remotePlayer.getRenderedPosition())}`,
    ].join(" ");
  }

  private snapshotData(): Record<string, unknown> {
    return {
      transport: this.deps.transport.getMode(),
      voxelSync: this.deps.world.mode,
      chunks: this.deps.world.store.listChunks().length,
      solidBlocks: this.deps.world.store.totalSolidBlocks(),
      selectedMaterialId: this.deps.edit.getSelectedMaterialId(),
      selectedMaterial: getMaterialDefinition(this.deps.edit.getSelectedMaterialId()),
      hotbar: this.deps.edit.getHotbarState(),
      currentSelection: this.deps.render.getCurrentSelection(),
      prefabPreview: this.deps.render.getPrefabPreviewSnapshot(),
      player: this.playerData(),
      remote: { position: formatVector(this.deps.remotePlayer.getRenderedPosition()) },
      camera: { position: formatVector(this.deps.render.getCameraPosition()) },
      transportState: this.transportData(),
      materials: listMaterialDefinitions(),
    };
  }

  private transportData(): Record<string, unknown> {
    return {
      voxelSync: this.deps.world.mode,
      movementTransport: this.deps.transport.debugSnapshot(),
    };
  }

  private worldSummaryData(): Record<string, unknown> {
    return {
      chunks: this.deps.world.store.listChunks().length,
      solidBlocks: this.deps.world.store.totalSolidBlocks(),
      editStats: { ...this.deps.world.store.editStats },
    };
  }

  private frameTraceData(): Record<string, unknown> {
    const trace = this.deps.localPlayer.getFrameTrace();
    const dtValues = trace.samples.map((sample) => sample.dtMs);
    const deltaValues = trace.samples.map((sample) => sample.deltaDistance);
    return {
      active: trace.active,
      frameCount: trace.samples.length,
      dtMs: summarizeSeries(dtValues),
      deltaDistance: summarizeSeries(deltaValues),
      samples: trace.samples,
    };
  }

  private playerData(): Record<string, unknown> {
    const state = this.deps.localPlayer.getCurrentState();
    return {
      predicted: state
        ? {
            seq: state.seq,
            tick: state.tick,
            position: formatVector(state.position),
            velocity: formatVector(state.velocity),
            acceleration: formatVector(state.acceleration),
          }
        : null,
      renderedPosition: formatVector(this.deps.localPlayer.getRenderedPosition()),
      authoritativePosition: formatVector(this.deps.localPlayer.getAuthoritativePosition()),
      pendingCorrection: formatVector(this.deps.localPlayer.getPendingCorrection()),
      jitterMs: this.deps.localPlayer.getCurrentJitterMs(),
      softPositionError: this.deps.localPlayer.getCurrentSoftPositionError(),
    };
  }

  private ok(command: string, text: string, data?: unknown): CliCommandResult {
    return data === undefined ? { ok: true, command, text } : { ok: true, command, text, data };
  }
}

function parseMacroCoord(args: string[]): FMacroCoord | null {
  const [xRaw, yRaw, zRaw] = args;
  const x = Number.parseInt(xRaw ?? "", 10);
  const y = Number.parseInt(yRaw ?? "", 10);
  const z = Number.parseInt(zRaw ?? "", 10);
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) return null;
  return { x, y, z };
}

function formatVector(vector: Vector3): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}

function formatCoord(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function parseRotation(value: string | undefined): EVoxelRotation | null {
  if (value === undefined) {
    return EVoxelRotation.Rot0;
  }

  switch (value.toLowerCase()) {
    case "0":
    case "rot0":
      return EVoxelRotation.Rot0;
    case "90":
    case "rot90":
      return EVoxelRotation.Rot90;
    case "180":
    case "rot180":
      return EVoxelRotation.Rot180;
    case "270":
    case "rot270":
      return EVoxelRotation.Rot270;
    default:
      return null;
  }
}

function worldStorageKey(slot: string): string {
  return `ex_mmo_web_client.world.${slot}`;
}

function serializePrefabForCli(prefab: LocalPrefab): Record<string, unknown> {
  return {
    name: prefab.name,
    boundsMin: prefab.boundsMin,
    boundsMax: prefab.boundsMax,
    blockCount: prefab.blocks.length,
    definition: {
      ...prefab.definition,
      occupancyWords: prefab.definition.occupancyWords.map((word) => word.toString()),
    },
  };
}

function summarizeSeries(values: number[]): { min: number; max: number; mean: number } | null {
  if (values.length === 0) {
    return null;
  }
  const min = Math.min(...values);
  const max = Math.max(...values);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return { min, max, mean };
}
