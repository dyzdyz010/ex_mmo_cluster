import type { Vector3 } from "three";
import {
  getMaterialDefinition,
  listMaterialDefinitions,
  parseMaterialIdOrName,
} from "../../material/catalog";
import type { CliCommandHandler, CliCommandResult } from "../../observe/cli";
import type { ObserveLog } from "../../observe/logger";
import { installCli } from "../../observe/cli";
import { INTERPOLATION_DELAY_SECS } from "../../movement/remotePlayer";
import type { FMacroCoord } from "../../voxel/core/types";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";

export interface DevToolsDeps {
  logger: ObserveLog;
  world: VoxelWorldAdapter;
  transport: TransportPump;
  localPlayer: LocalPlayerController;
  remotePlayer: RemotePlayerController;
  edit: WorldEditController;
  render: RenderOrchestrator;
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
      case "prefabs":
        return this.ok(command, "prefab list", this.deps.world.listPrefabs());
      case "prefab_capture":
        return this.cmdPrefabCapture(command, args);
      case "prefab_place":
        return this.cmdPrefabPlace(command, args);
      case "select_material":
        return this.cmdSelectMaterial(command, args);
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
    return this.ok(command, `captured prefab ${name}`, prefab);
  }

  private cmdPrefabPlace(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    const origin = parseMacroCoord(args.slice(1, 4));
    if (!name || !origin) {
      return { ok: false, command, text: "usage: prefab_place <name> <x> <y> <z>" };
    }
    const result = this.deps.world.placePrefab(name, origin);
    this.deps.logger.emit("prefab", result.ok ? "place" : "place_rejected", {
      name,
      origin: formatCoord(origin),
      placed: result.placed,
    });
    return this.ok(
      command,
      result.ok ? `placed prefab ${name}` : `unknown prefab ${name}`,
      result,
    );
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
      currentSelection: this.deps.render.getCurrentSelection(),
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
