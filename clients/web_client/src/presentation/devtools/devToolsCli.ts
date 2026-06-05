import {
  getMaterialDefinition,
  listMaterialDefinitions,
  parseMaterialIdOrName,
} from "../../material/catalog";
import type { ChatScope } from "../../domain/chat/types";
import { isChatScope } from "../../domain/chat/types";
import type { CliCommandHandler, CliCommandResult } from "../../observe/cli";
import type { ObserveLog } from "../../observe/logger";
import { installCli } from "../../observe/cli";
import { INTERPOLATION_DELAY_SECS } from "@domain/movement/remotePlayer";
import type { PrefabBoundarySnapPreview, PrefabSocketSnapPreview } from "../../voxel/prefab";
import type { SerializedWorldSnapshot } from "../../voxel/worldStore";
import type {
  ElectricConductionMode,
  ElectricOutputMode,
  ElectricPowerSourceRequest,
  VoxelWorldAdapter,
} from "../../voxel/worldAdapter";
import type { FChunkCoord, FMacroCoord } from "../../voxel/core/types";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";
import {
  formatCoord,
  formatMicroTarget,
  formatVector,
  formatVectorLike,
  summarizeSeries,
} from "./devToolsFormat";
import {
  parseBoundarySnapRequest,
  parseMacroCoord,
  parseMicroTarget,
  parseRotation,
  parseSocketSnapRequest,
  worldStorageKey,
} from "./devToolsParsers";
import {
  serializeBoundarySnapPreview,
  serializePrefabForCli,
  serializePrefabSocketData,
  serializeSnapPreview,
} from "./devToolsSerializers";

interface WorldStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

interface OnlineVoxelCliWorld extends VoxelWorldAdapter {
  flushServerMessagesForCli?(): void;
  requestVoxelDebugProbe(command?: string): number | null;
  subscribeVoxelChunk(centerChunk: FChunkCoord, radiusLInf?: number): number | null;
  unsubscribeVoxelChunk(chunk: FChunkCoord): number | null;
  sendVoxelImpactMacro(coord: FMacroCoord, materialId: number): number | null;
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

  executeCliCommand(command: string, args: string[], source = "cli"): CliCommandResult {
    switch (command) {
      case "snapshot":
        return this.ok(command, this.snapshotText(), this.snapshotData());
      case "renderer":
        return this.ok(command, this.rendererText(), this.deps.render.getRendererDebugSnapshot());
      case "chunks":
        return this.cmdChunks(command, args);
      case "voxel_sync":
      case "voxel":
        return this.ok(command, "voxel sync", this.deps.world.debugSnapshot());
      case "voxel_probe":
        return this.cmdVoxelProbe(command, args);
      case "voxel_subscribe":
        return this.cmdVoxelSubscribe(command, args);
      case "voxel_unsubscribe":
        return this.cmdVoxelUnsubscribe(command, args);
      case "voxel_impact":
        return this.cmdVoxelImpact(command, args);
      case "voxel_temp":
        return this.cmdVoxelTemperature(command, args, {
          defaultTargetTemperatureCelsius: 800,
          label: "temperature",
          requireExplicitTarget: true,
        });
      case "voxel_heat":
        return this.cmdVoxelTemperature(command, args, {
          defaultTargetTemperatureCelsius: 800,
          label: "heat",
        });
      case "voxel_cool":
        return this.cmdVoxelTemperature(command, args, {
          defaultTargetTemperatureCelsius: 0,
          label: "cool",
        });
      case "voxel_conduct":
        return this.cmdVoxelConduction(command, args, source);
      case "voxel_discharge":
        return this.cmdVoxelConduction(command, args, source, "discharge");
      case "voxel_auto_circuit":
        return this.cmdVoxelAutoCircuit(command, args);
      case "chunk_versions":
        return this.ok(command, "authoritative chunk versions", {
          chunks: this.deps.world.store.authoritativeChunkSummaries(128),
        });
      case "scene_regions":
        return this.cmdSceneRegions(command, args);
      case "field_overlay":
        return this.cmdFieldOverlay(command, args);
      case "target_probe":
        return this.cmdTargetProbe(command);
      case "cell":
        return this.cmdCell(command, args);
      case "micro_cell":
        return this.cmdMicroCell(command, args);
      case "micro_place":
        return this.cmdMicroPlace(command, args);
      case "micro_break":
        return this.cmdMicroBreak(command, args);
      case "place":
        return this.cmdPlace(command, args);
      case "break":
        return this.cmdBreak(command, args);
      case "hotbar":
        return this.ok(command, "hotbar", this.deps.edit.getHotbarState());
      case "hotbar_select":
        return this.cmdHotbarSelect(command, args);
      case "prefabs":
        return this.ok(
          command,
          "prefab list",
          this.deps.world.listPrefabs().map(serializePrefabForCli),
        );
      case "prefab_sockets":
        return this.cmdPrefabSockets(command, args);
      case "prefab_boundary":
        return this.cmdPrefabBoundary(command, args);
      case "prefab_capture":
        return this.cmdPrefabCapture(command, args);
      case "prefab_place":
        return this.cmdPrefabPlace(command, args);
      case "prefab_snap_preview":
        return this.cmdPrefabSnapPreview(command, args);
      case "prefab_place_snap":
        return this.cmdPrefabPlaceSnap(command, args);
      case "prefab_place_socket":
        return this.cmdPrefabPlaceSocket(command, args);
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
            movementMode: this.deps.remotePlayer.getCurrentMovementMode(),
            interpolation_delay_secs: INTERPOLATION_DELAY_SECS,
            clock: this.deps.remotePlayer.getClockDebugSnapshot(),
            entities: this.deps.remotePlayer.getDebugSnapshot(),
          },
        });
      case "aoi":
        return this.ok(command, "AOI remote entities", {
          visibleEntityIds: this.deps.remotePlayer.getVisibleEntityIds(),
          clock: this.deps.remotePlayer.getClockDebugSnapshot(),
          entities: this.deps.remotePlayer.getDebugSnapshot(),
        });
      case "remote":
        return this.cmdRemote(command, args);
      case "chat":
        return this.cmdChat(command, args);
      case "move":
        return this.cmdMove(command, args);
      case "jump":
        this.deps.localPlayer.requestJump("cli");
        return this.ok(command, "jump queued", this.playerData());
      case "transport":
        return this.ok(command, "transport snapshot", this.transportData());
      case "reconcile_stats":
        return this.ok(command, "reconcile stats", this.deps.localPlayer.getGovernanceStats());
      case "sync_stats":
        return this.ok(command, "movement sync stats", {
          local: {
            governance: this.deps.localPlayer.getGovernanceStats(),
            jitterMs: this.deps.localPlayer.getCurrentJitterMs(),
            softPositionError: this.deps.localPlayer.getCurrentSoftPositionError(),
            pendingCorrection: formatVector(this.deps.localPlayer.getPendingCorrection()),
            collision: this.collisionData(),
          },
          clock: this.deps.remotePlayer.getClockDebugSnapshot(),
          remote: this.deps.remotePlayer.getDebugSnapshot(),
          transport: this.transportData(),
        });
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
    this.flushWorldForCli();
    const limit = Number.parseInt(args[0] ?? "12", 10);
    const chunks = this.deps.world.store.chunkSummaries(Number.isFinite(limit) ? limit : 12);
    return this.ok(command, `chunks=${chunks.length}`, chunks);
  }

  private cmdMove(command: string, args: string[]): CliCommandResult {
    const strafe = Number.parseFloat(args[0] ?? "0");
    const forward = Number.parseFloat(args[1] ?? "0");

    if (!Number.isFinite(strafe) || !Number.isFinite(forward)) {
      return { ok: false, command, text: "usage: move <strafe:-1..1> <forward:-1..1>" };
    }

    const movement = this.deps.localPlayer.setVirtualMovement({ x: strafe, y: forward });
    return this.ok(
      command,
      `move strafe=${movement.x.toFixed(3)} forward=${movement.y.toFixed(3)}`,
      {
        strafe: movement.x,
        forward: movement.y,
      },
    );
  }

  private cmdSceneRegions(command: string, args: string[]): CliCommandResult {
    const requested = args[0]?.toLowerCase();
    if (requested === "on" || requested === "1" || requested === "true") {
      this.deps.render.setSceneRegionOverlayVisible(true);
    } else if (requested === "off" || requested === "0" || requested === "false") {
      this.deps.render.setSceneRegionOverlayVisible(false);
    } else if (requested !== undefined) {
      return { ok: false, command, text: "usage: scene_regions [on|off]" };
    }

    const snapshot = this.deps.render.getSceneRegionOverlaySnapshot();
    const regionText = snapshot.regions
      .map((region) => formatSceneRegionOverlayLine(region))
      .join("; ");
    return this.ok(
      command,
      `scene regions ${snapshot.visible ? "visible" : "hidden"}: ${regionText}; boundary chunk x=${snapshot.boundary.chunkX}`,
      snapshot,
    );
  }

  private cmdFieldOverlay(command: string, args: string[]): CliCommandResult {
    const requested = args[0]?.toLowerCase();
    if (requested === "on" || requested === "1" || requested === "true") {
      this.deps.render.setFieldDebugOverlayVisible(true);
    } else if (requested === "off" || requested === "0" || requested === "false") {
      this.deps.render.setFieldDebugOverlayVisible(false);
    } else if (requested !== undefined) {
      return { ok: false, command, text: "usage: field_overlay [on|off]" };
    }

    const snapshot = this.deps.render.getFieldDebugOverlaySnapshot();
    const regionText =
      snapshot.regions.length > 0
        ? snapshot.regions.map(formatFieldOverlayLine).join("; ")
        : "no active field regions";

    return this.ok(
      command,
      `field overlay ${snapshot.visible ? "visible" : "hidden"}: ${regionText}`,
      snapshot,
    );
  }

  private cmdTargetProbe(command: string): CliCommandResult {
    const snapshot = this.deps.render.getTargetOverlaySnapshot();
    const entityTarget = snapshot.entityTarget;
    if (entityTarget) {
      return this.ok(
        command,
        `target entity#${entityTarget.entityId} macro=${formatCoord(entityTarget.macroCoord)}`,
        snapshot,
      );
    }
    const projection = snapshot.projection;
    if (!projection) {
      const fallbackText = formatFallbackEntityTarget(snapshot.fallbackEntityTarget);
      return this.ok(command, `target none${fallbackText}`, snapshot);
    }
    const range =
      projection.coveredMacroMin && projection.coveredMacroMax
        ? ` macros=${formatCoord(projection.coveredMacroMin)}..${formatCoord(
            projection.coveredMacroMax,
          )}`
        : "";
    return this.ok(
      command,
      `target ${projection.granularity} ${projection.label} slots=${projection.occupiedSlots}${range}${formatFallbackEntityTarget(snapshot.fallbackEntityTarget)}`,
      snapshot,
    );
  }

  private cmdVoxelProbe(command: string, args: string[]): CliCommandResult {
    const world = this.onlineVoxelWorld();
    if (!world) return { ok: false, command, text: "voxel transport unavailable" };
    const requestId = world.requestVoxelDebugProbe(args.join(" ") || "voxel_transport");
    return this.ok(command, requestId === null ? "voxel probe rejected" : "voxel probe sent", {
      requestId,
      voxel: world.debugSnapshot(),
    });
  }

  private cmdChat(command: string, args: string[]): CliCommandResult {
    const scope = args[0];
    const text = args.slice(1).join(" ").trim();
    if (!isChatScope(scope) || text.length === 0) {
      return { ok: false, command, text: usageForChatCommand() };
    }

    const chatTransport = this.deps.transport as Partial<{
      sendChat(scope: ChatScope, text: string): number | null;
      debugSnapshot(): Record<string, unknown>;
    }>;
    if (typeof chatTransport.sendChat !== "function") {
      return { ok: false, command, text: "chat transport unavailable" };
    }

    const requestId = chatTransport.sendChat(scope, text);
    const result = {
      requestId,
      scope,
      textLength: new TextEncoder().encode(text).length,
      transport: chatTransport.debugSnapshot?.() ?? {},
    };
    return requestId === null
      ? { ok: false, command, text: `chat ${scope} rejected`, data: result }
      : this.ok(command, `chat ${scope} sent request=${requestId}`, result);
  }

  private cmdVoxelSubscribe(command: string, args: string[]): CliCommandResult {
    const world = this.onlineVoxelWorld();
    if (!world) return { ok: false, command, text: "voxel transport unavailable" };
    const coord = parseMacroCoord(args);
    if (!coord) {
      return { ok: false, command, text: "usage: voxel_subscribe <cx> <cy> <cz> [radius]" };
    }
    const radius = Number.parseInt(args[3] ?? "0", 10);
    const safeRadius = Number.isFinite(radius) ? Math.max(0, Math.min(radius, 4)) : 0;
    const requestId = world.subscribeVoxelChunk(coord, safeRadius);
    return this.ok(
      command,
      requestId === null ? "voxel subscribe rejected" : "voxel subscribe sent",
      {
        requestId,
        centerChunk: coord,
        radiusLInf: safeRadius,
        voxel: world.debugSnapshot(),
      },
    );
  }

  private cmdVoxelUnsubscribe(command: string, args: string[]): CliCommandResult {
    const world = this.onlineVoxelWorld();
    if (!world) return { ok: false, command, text: "voxel transport unavailable" };
    const coord = parseMacroCoord(args);
    if (!coord) {
      return { ok: false, command, text: "usage: voxel_unsubscribe <cx> <cy> <cz>" };
    }
    const requestId = world.unsubscribeVoxelChunk(coord);
    return this.ok(
      command,
      requestId === null ? "voxel unsubscribe rejected" : "voxel unsubscribe sent",
      {
        requestId,
        chunk: coord,
        voxel: world.debugSnapshot(),
      },
    );
  }

  private cmdVoxelImpact(command: string, args: string[]): CliCommandResult {
    const world = this.onlineVoxelWorld();
    if (!world) return { ok: false, command, text: "voxel transport unavailable" };
    const coord = parseMacroCoord(args);
    if (!coord) {
      return { ok: false, command, text: "usage: voxel_impact <x> <y> <z> [material]" };
    }
    const materialArg = args[3];
    const materialId =
      materialArg !== undefined
        ? (parseMaterialIdOrName(materialArg) ?? this.deps.edit.getSelectedMaterialId())
        : this.deps.edit.getSelectedMaterialId();
    const requestId = world.sendVoxelImpactMacro(coord, materialId);
    return this.ok(command, requestId === null ? "voxel impact rejected" : "voxel impact sent", {
      requestId,
      coord,
      materialId,
      voxel: world.debugSnapshot(),
    });
  }

  private cmdVoxelTemperature(
    command: string,
    args: string[],
    opts: {
      defaultTargetTemperatureCelsius: number;
      label: "temperature" | "heat" | "cool";
      requireExplicitTarget?: boolean;
    },
  ): CliCommandResult {
    const temperaturePort = this.deps.edit as Partial<{
      setTemperatureAt: (
        coord: FMacroCoord,
        targetTemperatureCelsius: number,
        source: string,
        maxTicks?: number,
      ) => boolean;
      setTemperatureAtSelection: (
        source: string,
        targetTemperatureCelsius?: number,
        maxTicks?: number,
      ) => boolean;
      heatAt: (
        coord: FMacroCoord,
        targetTemperatureCelsius: number,
        source: string,
        maxTicks?: number,
      ) => boolean;
      heatAtSelection: (
        source: string,
        targetTemperatureCelsius?: number,
        maxTicks?: number,
      ) => boolean;
    }>;
    const targetTemperatureCelsius = parseFiniteNumber(
      args[3],
      opts.defaultTargetTemperatureCelsius,
    );
    const maxTicks = parsePositiveInt(args[4], 600);

    if (args.length === 0) {
      const setSelection =
        temperaturePort.setTemperatureAtSelection ?? temperaturePort.heatAtSelection;
      if (typeof setSelection !== "function") {
        return { ok: false, command, text: "temperature action unavailable" };
      }
      const ok = setSelection.call(
        temperaturePort,
        "cli",
        opts.defaultTargetTemperatureCelsius,
        600,
      );
      return {
        ok,
        command,
        text: ok
          ? `${opts.label} request sent for selected voxel to ${opts.defaultTargetTemperatureCelsius}C`
          : `${opts.label} selected voxel rejected`,
      };
    }

    const coord = parseMacroCoord(args);
    if (!coord || (opts.requireExplicitTarget === true && !Number.isFinite(Number(args[3])))) {
      return {
        ok: false,
        command,
        text: usageForTemperatureCommand(command),
      };
    }
    const setTemperature = temperaturePort.setTemperatureAt ?? temperaturePort.heatAt;
    if (typeof setTemperature !== "function") {
      return { ok: false, command, text: "temperature action unavailable" };
    }
    const ok = setTemperature.call(
      temperaturePort,
      coord,
      targetTemperatureCelsius,
      "cli",
      maxTicks,
    );
    return {
      ok,
      command,
      text: ok
        ? `${opts.label} request sent for (${formatCoord(coord)}) to ${targetTemperatureCelsius}C`
        : `${opts.label} request rejected for (${formatCoord(coord)})`,
    };
  }

  private cmdVoxelConduction(
    command: string,
    args: string[],
    source: string,
    conductionMode?: ElectricConductionMode,
  ): CliCommandResult {
    const sourceCoord = parseMacroCoord(args.slice(0, 3));
    const targetCoord = parseMacroCoord(args.slice(3, 6));
    if (!sourceCoord || !targetCoord) {
      return {
        ok: false,
        command,
        text: usageForConductionCommand(command),
      };
    }

    const conductionPort = this.deps.edit as Partial<{
      conductBetween: (
        sourceCoord: FMacroCoord,
        targetCoord: FMacroCoord,
        sourcePotential: number,
        source: string,
        maxTicks?: number,
        powerSource?: ElectricPowerSourceRequest,
      ) => boolean;
    }>;
    if (typeof conductionPort.conductBetween !== "function") {
      return { ok: false, command, text: "conduction action unavailable" };
    }

    const sourcePotential = parseFiniteNumber(args[6], 120);
    const maxTicks = parsePositiveInt(args[7], 120);
    const powerSource = parseConductionPowerSource(args.slice(8), sourcePotential, conductionMode);
    if (powerSource === null) {
      return {
        ok: false,
        command,
        text: usageForConductionCommand(command),
      };
    }

    const ok =
      powerSource === undefined
        ? conductionPort.conductBetween.call(
            conductionPort,
            sourceCoord,
            targetCoord,
            sourcePotential,
            source,
            maxTicks,
          )
        : conductionPort.conductBetween.call(
            conductionPort,
            sourceCoord,
            targetCoord,
            sourcePotential,
            source,
            maxTicks,
            powerSource,
          );

    const label = conductionMode === "discharge" ? "discharge" : "conduction";

    return {
      ok,
      command,
      text: ok
        ? `${label} request submitted from (${formatCoord(sourceCoord)}) to (${formatCoord(targetCoord)}) at ${sourcePotential}V; waiting for server acceptance`
        : `${label} request rejected from (${formatCoord(sourceCoord)}) to (${formatCoord(targetCoord)})`,
      data: {
        sourceCoord,
        targetCoord,
        sourcePotential,
        maxTicks,
        source,
        powerSource,
      },
    };
  }

  private cmdVoxelAutoCircuit(command: string, args: string[]): CliCommandResult {
    const coord = parseMacroCoord(args);
    if (!coord) {
      return { ok: false, command, text: usageForAutoCircuitCommand() };
    }

    const autoCircuitPort = this.deps.world as Partial<{
      requestVoxelAutoCircuit: (coord: FMacroCoord, maxTicks?: number) => boolean;
    }>;
    if (typeof autoCircuitPort.requestVoxelAutoCircuit !== "function") {
      return { ok: false, command, text: "auto circuit action unavailable" };
    }

    const maxTicks = args[3] === undefined ? undefined : parsePositiveInt(args[3], 600);
    const ok = autoCircuitPort.requestVoxelAutoCircuit.call(autoCircuitPort, coord, maxTicks);
    return {
      ok,
      command,
      text: ok
        ? `auto circuit request submitted for (${formatCoord(coord)})`
        : `auto circuit request rejected for (${formatCoord(coord)})`,
      data: {
        coord,
        maxTicks: maxTicks ?? null,
        voxel: this.deps.world.debugSnapshot(),
      },
    };
  }

  private cmdCell(command: string, args: string[]): CliCommandResult {
    const coord = parseMacroCoord(args);
    if (!coord) return { ok: false, command, text: "usage: cell <x> <y> <z>" };
    this.flushWorldForCli();
    return this.ok(command, `cell ${formatCoord(coord)}`, {
      coord,
      block: this.deps.world.store.getNormalBlockWorld(coord),
      environment: this.deps.world.store.getEnvironmentSummaryWorld(coord),
    });
  }

  private cmdMicroCell(command: string, args: string[]): CliCommandResult {
    const target = parseMicroTarget(args);
    if (!target) {
      return { ok: false, command, text: "usage: micro_cell <x> <y> <z> <mx> <my> <mz>" };
    }
    this.flushWorldForCli();
    return this.ok(command, `micro_cell ${formatMicroTarget(target)}`, {
      ...target,
      block: this.deps.world.store.getMicroBlockWorld(target.macro, target.micro),
    });
  }

  private cmdMicroPlace(command: string, args: string[]): CliCommandResult {
    const target = parseMicroTarget(args);
    if (!target) {
      return {
        ok: false,
        command,
        text: "usage: micro_place <x> <y> <z> <mx> <my> <mz> [material]",
      };
    }
    const materialArg = args[6];
    const materialId =
      materialArg !== undefined
        ? (parseMaterialIdOrName(materialArg) ?? this.deps.edit.getSelectedMaterialId())
        : this.deps.edit.getSelectedMaterialId();
    const ok = this.deps.edit.placeMicroAt(target.macro, target.micro, materialId, "cli");
    return this.ok(command, ok ? "micro placed" : "micro place rejected", {
      ...target,
      materialId,
      ok,
    });
  }

  private cmdMicroBreak(command: string, args: string[]): CliCommandResult {
    const target = parseMicroTarget(args);
    if (!target) {
      return { ok: false, command, text: "usage: micro_break <x> <y> <z> <mx> <my> <mz>" };
    }
    const ok = this.deps.edit.breakMicroAt(target.macro, target.micro, "cli");
    return this.ok(command, ok ? "micro broken" : "micro break rejected", { ...target, ok });
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
    if (materialId === null)
      return { ok: false, command, text: `unknown material: ${materialArg}` };
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
    const safeFrames = Number.isFinite(frames) ? Math.max(1, Math.min(frames, 5_000)) : 240;
    this.deps.localPlayer.startFrameTrace(safeFrames);
    return this.ok(command, `frame trace started for ${safeFrames} frames`, {
      frames: safeFrames,
    });
  }

  private cmdRemote(command: string, args: string[]): CliCommandResult {
    const cid = Number.parseInt(args[0] ?? "", 10);
    if (!Number.isFinite(cid)) {
      return { ok: false, command, text: "usage: remote <cid>" };
    }

    const entity = this.deps.remotePlayer.getDebugSnapshot().find((item) => item.cid === cid);
    if (!entity) {
      return { ok: false, command, text: `remote entity not visible: ${cid}` };
    }

    return this.ok(command, `remote entity ${cid}`, entity);
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
      return {
        ok: false,
        command,
        text: "usage: prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]",
      };
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
    return this.ok(command, result.ok ? `placed prefab ${name}` : `unknown prefab ${name}`, result);
  }

  private cmdPrefabSockets(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    if (!name) {
      return { ok: false, command, text: "usage: prefab_sockets <name>" };
    }
    const prefab = this.deps.world.getPrefab(name);
    if (!prefab) {
      return { ok: false, command, text: `unknown prefab: ${name}` };
    }
    return this.ok(command, `prefab sockets ${name}`, serializePrefabSocketData(prefab));
  }

  private cmdPrefabBoundary(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    if (!name) {
      return { ok: false, command, text: "usage: prefab_boundary <name>" };
    }
    const prefab = this.deps.world.getPrefab(name);
    if (!prefab) {
      return { ok: false, command, text: `unknown prefab: ${name}` };
    }
    return this.ok(command, `prefab boundary ${name}`, serializePrefabSocketData(prefab));
  }

  private cmdPrefabSnapPreview(command: string, args: string[]): CliCommandResult {
    const boundaryRequest = parseBoundarySnapRequest(args);
    if (boundaryRequest) {
      const preview = this.deps.world.previewPrefabBoundarySnap(boundaryRequest);
      this.emitPrefabBoundarySnapObserve(
        preview.ok ? "prefab_boundary_snap_previewed" : "prefab_boundary_snap_rejected",
        {
          ...preview,
          rejectReason: preview.rejectReason ?? "",
        },
      );
      return this.ok(
        command,
        preview.ok ? "prefab boundary snap preview" : "prefab boundary snap rejected",
        {
          ...serializeBoundarySnapPreview(preview),
          ok: preview.ok,
        },
      );
    }

    const request = parseSocketSnapRequest(args);
    if (!request) {
      return {
        ok: false,
        command,
        text: "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rot0|rot90|rot180|rot270] [anchor_micro_x anchor_micro_y anchor_micro_z] OR prefab_snap_preview <name> <target-instance> <target-socket> [incoming-socket] [rot0|rot90|rot180|rot270]",
      };
    }
    const preview = this.deps.world.previewPrefabSocketSnap(request);
    this.emitPrefabSnapObserve(preview.ok ? "prefab_snap_previewed" : "prefab_snap_rejected", {
      ...preview,
      rejectReason: preview.rejectReason ?? "",
    });
    return this.ok(command, preview.ok ? "prefab snap preview" : "prefab snap rejected", {
      ...serializeSnapPreview(preview),
      ok: preview.ok,
    });
  }

  private cmdPrefabPlaceSnap(command: string, args: string[]): CliCommandResult {
    const request = parseBoundarySnapRequest(args);
    if (!request) {
      return {
        ok: false,
        command,
        text: "usage: prefab_place_snap <name> <x> <y> <z> <nx> <ny> <nz> [rot0|rot90|rot180|rot270] [anchor_micro_x anchor_micro_y anchor_micro_z]",
      };
    }
    const result = this.deps.world.placePrefabBoundarySnap(request);
    if (result.preview) {
      this.emitPrefabBoundarySnapObserve(
        result.ok ? "prefab_boundary_snap_committed" : "prefab_boundary_snap_rejected",
        {
          ...result.preview,
          instanceId: result.instanceId ?? 0,
          rejectReason: result.rejectReason ?? result.preview.rejectReason ?? "",
        },
      );
      if (result.conflict) {
        this.emitPrefabBoundarySnapObserve("prefab_overlap_conflict", {
          ...result.preview,
          instanceId: 0,
          rejectReason: result.rejectReason ?? result.preview.rejectReason ?? "micro_overlap",
        });
      }
    }
    return this.ok(command, result.ok ? "prefab boundary placed" : "prefab boundary rejected", {
      ...result,
      preview: result.preview ? serializeBoundarySnapPreview(result.preview) : undefined,
    });
  }

  private cmdPrefabPlaceSocket(command: string, args: string[]): CliCommandResult {
    const request = parseSocketSnapRequest(args);
    if (!request) {
      return {
        ok: false,
        command,
        text: "usage: prefab_place_socket <name> <target-instance> <target-socket> [incoming-socket] [rot0|rot90|rot180|rot270]",
      };
    }
    const result = this.deps.world.placePrefabSocketSnap(request);
    if (result.preview) {
      this.emitPrefabSnapObserve(result.ok ? "prefab_snap_committed" : "prefab_snap_rejected", {
        ...result.preview,
        instanceId: result.instanceId ?? result.preview.targetInstanceId,
        rejectReason: result.rejectReason ?? result.preview.rejectReason ?? "",
      });
      if (result.conflict) {
        this.emitPrefabSnapObserve("prefab_overlap_conflict", {
          ...result.preview,
          instanceId: result.preview.targetInstanceId,
          rejectReason: result.rejectReason ?? result.preview.rejectReason ?? "micro_overlap",
        });
      }
    }
    return this.ok(command, result.ok ? "prefab socket placed" : "prefab socket rejected", {
      ...result,
      preview: result.preview ? serializeSnapPreview(result.preview) : undefined,
    });
  }

  private cmdWorldExport(command: string): CliCommandResult {
    const snapshot = this.deps.world.exportSnapshot();
    const json = JSON.stringify(snapshot);
    return this.ok(
      command,
      `world exported chunks=${snapshot.chunks.length} bytes=${json.length}`,
      {
        snapshot,
        json,
        bytes: json.length,
      },
    );
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
    this.flushWorldForCli();
    return [
      this.rendererText(),
      `transport=${this.deps.transport.getMode()}`,
      `voxel_sync=${this.deps.world.mode}`,
      `chunks=${this.deps.world.store.listChunks().length}`,
      `solid_blocks=${this.deps.world.store.totalSolidBlocks()}`,
      `selected_material=${getMaterialDefinition(this.deps.edit.getSelectedMaterialId()).name}`,
      `player_rendered=${formatVector(this.deps.localPlayer.getRenderedPosition())}`,
      `player_display=${formatVectorLike(this.deps.render.getActorDisplaySnapshot().local)}`,
      `player_authority=${formatVector(this.deps.localPlayer.getAuthoritativePosition())}`,
      `remote_rendered=${formatVector(this.deps.remotePlayer.getRenderedPosition())}`,
    ].join(" ");
  }

  private flushWorldForCli(): void {
    const world = this.deps.world as Partial<OnlineVoxelCliWorld> | undefined;
    world?.flushServerMessagesForCli?.();
  }

  private snapshotData(): Record<string, unknown> {
    return {
      renderer: this.deps.render.getRendererDebugSnapshot(),
      transport: this.deps.transport.getMode(),
      voxelSync: this.deps.world.mode,
      voxel: this.deps.world.debugSnapshot(),
      chunks: this.deps.world.store.listChunks().length,
      solidBlocks: this.deps.world.store.totalSolidBlocks(),
      selectedMaterialId: this.deps.edit.getSelectedMaterialId(),
      selectedMaterial: getMaterialDefinition(this.deps.edit.getSelectedMaterialId()),
      hotbar: this.deps.edit.getHotbarState(),
      currentSelection: this.deps.render.getCurrentSelection(),
      entityTarget: this.deps.render.getTargetOverlaySnapshot().entityTarget,
      fallbackEntityTarget: this.deps.render.getTargetOverlaySnapshot().fallbackEntityTarget,
      prefabPreview: this.deps.render.getPrefabPreviewSnapshot(),
      actorDisplay: this.deps.render.getActorDisplaySnapshot(),
      player: this.playerData(),
      remote: { position: formatVector(this.deps.remotePlayer.getRenderedPosition()) },
      aoi: this.deps.remotePlayer.getDebugSnapshot(),
      camera: { position: formatVector(this.deps.render.getCameraPosition()) },
      transportState: this.transportData(),
      materials: listMaterialDefinitions(),
    };
  }

  private rendererText(): string {
    const renderer = this.deps.render.getRendererDebugSnapshot();
    return [
      `renderer=${renderer.active}`,
      `renderer_backend=${renderer.backend}`,
      `renderer_requested=${renderer.requested}`,
      `renderer_fallback=${renderer.fallbackReason ?? "none"}`,
    ].join(" ");
  }

  private transportData(): Record<string, unknown> {
    return {
      voxelSync: this.deps.world.mode,
      voxel: this.deps.world.debugSnapshot(),
      movementTransport: this.deps.transport.debugSnapshot(),
    };
  }

  private worldSummaryData(): Record<string, unknown> {
    return {
      chunks: this.deps.world.store.listChunks().length,
      solidBlocks: this.deps.world.store.totalSolidBlocks(),
      editStats: { ...this.deps.world.store.editStats },
      authoritativeChunks: this.deps.world.store.authoritativeChunkSummaries(16),
    };
  }

  private frameTraceData(): Record<string, unknown> {
    const trace = this.deps.localPlayer.getFrameTrace();
    const dtValues = trace.samples.map((sample) => sample.dtMs);
    const deltaValues = trace.samples.map((sample) => sample.deltaDistance);
    const authorityDeltaValues = trace.samples.map((sample) => sample.authorityDeltaDistance);
    const authorityRenderDeltaValues = trace.samples.map(
      (sample) => sample.authorityRenderDeltaDistance,
    );
    const authorityProjectedDeltaValues = trace.samples.map(
      (sample) => sample.authorityProjectedDeltaDistance,
    );
    const authorityDisplayDeltaValues = trace.samples.map(
      (sample) => sample.authorityDisplayDeltaDistance,
    );
    const localAuthorityDistanceValues = trace.samples.map(
      (sample) => sample.localAuthorityDistance,
    );
    const localAuthorityRenderDistanceValues = trace.samples.map(
      (sample) => sample.localAuthorityRenderDistance,
    );
    const localAuthorityProjectedDistanceValues = trace.samples.map(
      (sample) => sample.localAuthorityProjectedDistance,
    );
    const localAuthorityDisplayDistanceValues = trace.samples.map(
      (sample) => sample.localAuthorityDisplayDistance,
    );
    const authorityRenderAuthorityDistanceValues = trace.samples.map(
      (sample) => sample.authorityRenderAuthorityDistance,
    );
    const authorityProjectedAuthorityDistanceValues = trace.samples.map(
      (sample) => sample.authorityProjectedAuthorityDistance,
    );
    const authorityDisplayAuthorityDistanceValues = trace.samples.map(
      (sample) => sample.authorityDisplayAuthorityDistance,
    );
    const ackSeqValues = trace.samples.map((sample) => sample.ackSeq);
    const inputSeqGapValues = trace.samples.map((sample) => sample.inputSeqGap);
    const lastAckRttValues = trace.samples.map((sample) => sample.lastAckRttMs);
    const lastAckPendingInputValues = trace.samples.map((sample) => sample.lastAckPendingInputs);
    const lastAckReplayedFrameValues = trace.samples.map((sample) => sample.lastAckReplayedFrames);
    const serverStateAgeValues = trace.samples.map((sample) => sample.serverStateAgeMs);
    const serverSendAgeValues = trace.samples.map((sample) => sample.serverSendAgeMs);
    const sceneAckAgeValues = trace.samples.map((sample) => sample.sceneAckAgeMs);
    const browserApplyDelayValues = trace.samples.map((sample) => sample.browserApplyDelayMs);
    const gateSendDelayValues = trace.samples.map((sample) => sample.gateSendDelayMs);
    const sceneInputAgeValues = trace.samples.map((sample) => sample.sceneInputAgeMs);
    const sceneQueueLenValues = trace.samples.map((sample) => sample.sceneQueueLen);
    const sceneReplayCountValues = trace.samples.map((sample) => sample.sceneReplayCount);
    const sceneDroppedInputCountValues = trace.samples.map(
      (sample) => sample.sceneDroppedInputCount,
    );
    const sceneMailboxLenValues = trace.samples.map((sample) => sample.sceneMailboxLen);
    const sceneTickDriftValues = trace.samples.map((sample) => sample.sceneTickDriftMs);
    return {
      active: trace.active,
      frameCount: trace.samples.length,
      dtMs: summarizeSeries(dtValues),
      deltaDistance: summarizeSeries(deltaValues),
      authorityDeltaDistance: summarizeSeries(authorityDeltaValues),
      authorityRenderDeltaDistance: summarizeSeries(authorityRenderDeltaValues),
      authorityProjectedDeltaDistance: summarizeSeries(authorityProjectedDeltaValues),
      authorityDisplayDeltaDistance: summarizeSeries(authorityDisplayDeltaValues),
      localAuthorityDistance: summarizeSeries(localAuthorityDistanceValues),
      localAuthorityRenderDistance: summarizeSeries(localAuthorityRenderDistanceValues),
      localAuthorityProjectedDistance: summarizeSeries(localAuthorityProjectedDistanceValues),
      localAuthorityDisplayDistance: summarizeSeries(localAuthorityDisplayDistanceValues),
      authorityRenderAuthorityDistance: summarizeSeries(authorityRenderAuthorityDistanceValues),
      authorityProjectedAuthorityDistance: summarizeSeries(
        authorityProjectedAuthorityDistanceValues,
      ),
      authorityDisplayAuthorityDistance: summarizeSeries(authorityDisplayAuthorityDistanceValues),
      ackSeq: summarizeSeries(ackSeqValues),
      inputSeqGap: summarizeSeries(inputSeqGapValues),
      lastAckRttMs: summarizeSeries(lastAckRttValues),
      lastAckPendingInputs: summarizeSeries(lastAckPendingInputValues),
      lastAckReplayedFrames: summarizeSeries(lastAckReplayedFrameValues),
      serverStateAgeMs: summarizeSeries(serverStateAgeValues),
      serverSendAgeMs: summarizeSeries(serverSendAgeValues),
      sceneAckAgeMs: summarizeSeries(sceneAckAgeValues),
      browserApplyDelayMs: summarizeSeries(browserApplyDelayValues),
      gateSendDelayMs: summarizeSeries(gateSendDelayValues),
      sceneInputAgeMs: summarizeSeries(sceneInputAgeValues),
      sceneQueueLen: summarizeSeries(sceneQueueLenValues),
      sceneReplayCount: summarizeSeries(sceneReplayCountValues),
      sceneDroppedInputCount: summarizeSeries(sceneDroppedInputCountValues),
      sceneMailboxLen: summarizeSeries(sceneMailboxLenValues),
      sceneTickDriftMs: summarizeSeries(sceneTickDriftValues),
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
            movementMode: state.movementMode,
            groundY: state.groundY,
          }
        : null,
      renderedPosition: formatVector(this.deps.localPlayer.getRenderedPosition()),
      authoritativePosition: formatVector(this.deps.localPlayer.getAuthoritativePosition()),
      authorityRender: this.deps.localPlayer.getAuthorityRenderDebugSnapshot(),
      pendingCorrection: formatVector(this.deps.localPlayer.getPendingCorrection()),
      jitterMs: this.deps.localPlayer.getCurrentJitterMs(),
      softPositionError: this.deps.localPlayer.getCurrentSoftPositionError(),
      collision: this.collisionData(),
    };
  }

  private collisionData(): Record<string, unknown> | null {
    const summary = this.deps.localPlayer.getLastCollisionSummary();
    if (!summary) {
      return null;
    }
    return {
      status: summary.status,
      sampleCount: summary.sampleCount,
      occupiedCount: summary.occupiedCount,
      blockedAxes: summary.blockedAxes,
      previousPosition: formatVector(summary.previousPosition),
      proposedPosition: formatVector(summary.proposedPosition),
      resolvedPosition: formatVector(summary.resolvedPosition),
    };
  }

  private ok(command: string, text: string, data?: unknown): CliCommandResult {
    return data === undefined ? { ok: true, command, text } : { ok: true, command, text, data };
  }

  private onlineVoxelWorld(): OnlineVoxelCliWorld | null {
    const candidate = this.deps.world as Partial<OnlineVoxelCliWorld>;
    return typeof candidate.requestVoxelDebugProbe === "function" &&
      typeof candidate.subscribeVoxelChunk === "function" &&
      typeof candidate.sendVoxelImpactMacro === "function"
      ? (this.deps.world as OnlineVoxelCliWorld)
      : null;
  }

  private emitPrefabSnapObserve(
    event: string,
    payload: PrefabSocketSnapPreview & { instanceId?: number; rejectReason: string },
  ): void {
    this.deps.logger.emit("prefab", event, {
      prefabId: payload.prefabId,
      instanceId: payload.instanceId ?? payload.targetInstanceId,
      anchorMicroCoord: payload.anchorMicroCoord ? formatCoord(payload.anchorMicroCoord) : "",
      affectedMacroCount: payload.affectedMacroCount,
      incomingOccupiedSlots: payload.incomingOccupiedSlots,
      overlapSlots: payload.overlapSlots,
      socketId: payload.socketId ?? "",
      targetSocketId: payload.targetSocketId,
      rejectReason: payload.rejectReason,
    });
  }

  private emitPrefabBoundarySnapObserve(
    event: string,
    payload: PrefabBoundarySnapPreview & { instanceId?: number; rejectReason: string },
  ): void {
    this.deps.logger.emit("prefab", event, {
      prefabId: payload.prefabId,
      instanceId: payload.instanceId ?? 0,
      hitMacro: formatCoord(payload.hitMacro),
      faceNormal: formatCoord(payload.faceNormal),
      anchorMicroCoord: payload.anchorMicroCoord ? formatCoord(payload.anchorMicroCoord) : "",
      affectedMacroCount: payload.affectedMacroCount,
      incomingOccupiedSlots: payload.incomingOccupiedSlots,
      overlapSlots: payload.overlapSlots,
      contactSlots: payload.contactSlots,
      socketId: "",
      targetSocketId: "",
      rejectReason: payload.rejectReason,
    });
  }
}

function parseFiniteNumber(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseOptionalFiniteNumber(value: string | undefined): number | undefined {
  if (value === undefined) return undefined;
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function parsePositiveInt(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function parseConductionPowerSource(
  args: string[],
  sourcePotential: number,
  conductionMode?: ElectricConductionMode,
): ElectricPowerSourceRequest | undefined | null {
  if (args.length === 0) {
    return conductionMode === undefined ? undefined : { conductionMode };
  }

  const outputMode = parseElectricOutputMode(args[0]);
  if (!outputMode) return null;

  const powerSource: ElectricPowerSourceRequest = {
    ...(conductionMode === undefined ? {} : { conductionMode }),
    outputMode,
    voltage: parseFiniteNumber(args[1], sourcePotential),
  };
  const currentLimitAmps = parseOptionalFiniteNumber(args[2]);
  const frequencyHz = parseOptionalFiniteNumber(args[3]);
  const loadCurrentAmps = parseOptionalFiniteNumber(args[4]);
  const energyBudgetJoules = parseOptionalFiniteNumber(args[5]);
  if (currentLimitAmps !== undefined) {
    powerSource.currentLimitAmps = currentLimitAmps;
  }
  if (frequencyHz !== undefined) {
    powerSource.frequencyHz = frequencyHz;
  }
  if (loadCurrentAmps !== undefined) {
    powerSource.loadCurrentAmps = loadCurrentAmps;
  }
  if (energyBudgetJoules !== undefined) {
    powerSource.energyBudgetJoules = energyBudgetJoules;
  }
  return powerSource;
}

function parseElectricOutputMode(value: string | undefined): ElectricOutputMode | null {
  switch (value?.toLowerCase()) {
    case "dc":
    case "ac":
    case "pulse":
      return value.toLowerCase() as ElectricOutputMode;
    default:
      return null;
  }
}

function usageForTemperatureCommand(command: string): string {
  switch (command) {
    case "voxel_temp":
      return "usage: voxel_temp <x> <y> <z> <target_temperature_celsius> [max_ticks]";
    case "voxel_cool":
      return "usage: voxel_cool <x> <y> <z> [target_temperature_celsius] [max_ticks]";
    default:
      return "usage: voxel_heat <x> <y> <z> [target_temperature_celsius] [max_ticks]";
  }
}

function usageForConductionCommand(command = "voxel_conduct"): string {
  if (command === "voxel_discharge") {
    return "usage: voxel_discharge <sx> <sy> <sz> <tx> <ty> <tz> [source_potential] [max_ticks] [dc|ac|pulse] [voltage] [current_limit_amps] [frequency_hz] [load_current_amps] [energy_budget_joules]";
  }

  return "usage: voxel_conduct <sx> <sy> <sz> <tx> <ty> <tz> [source_potential] [max_ticks] [dc|ac|pulse] [voltage] [current_limit_amps] [frequency_hz] [load_current_amps] [energy_budget_joules]";
}

function usageForChatCommand(): string {
  return "usage: chat <world|region|local> <text...>";
}

function usageForAutoCircuitCommand(): string {
  return "usage: voxel_auto_circuit <x> <y> <z> [max_ticks]";
}

function formatSceneRegionOverlayLine(region: {
  label?: string;
  ownerSceneInstanceRef?: number;
  chunkMin?: { x: number; z: number };
  chunkMax?: { x: number; z: number };
}): string {
  const label = region.label ?? "scene";
  const owner = region.ownerSceneInstanceRef ?? "?";
  if (!region.chunkMin || !region.chunkMax) {
    return `${label}=owner${owner}`;
  }

  return `${label}=owner${owner} chunks x=${region.chunkMin.x}..${region.chunkMax.x - 1} z=${region.chunkMin.z}..${region.chunkMax.z - 1}`;
}

function formatFallbackEntityTarget(
  target:
    | {
        entityId: number;
        macroCoord: { x: number; y: number; z: number };
      }
    | null
    | undefined,
): string {
  return target ? ` action_entity#${target.entityId} macro=${formatCoord(target.macroCoord)}` : "";
}

function formatFieldOverlayLine(region: {
  regionId: number;
  chunkCoord: { cx: number; cy: number; cz: number };
  temperatureCells: number;
  electricCells: number;
  currentCells?: number;
  currentMicroCells?: number;
  currentMicroGroups?: number;
  smokeParticles?: number;
  temperatureMicroCells?: number;
  electricMicroCells?: number;
  temperatureMicroGroups?: number;
  electricMicroGroups?: number;
  maxTemperatureCelsius?: number | null;
  maxAbsTemperatureDeltaCelsius?: number;
  averageAbsTemperatureDeltaCelsius?: number;
  temperatureStats?: {
    maxTemperatureCelsius: number | null;
    maxAbsTemperatureDeltaCelsius: number;
    averageAbsTemperatureDeltaCelsius: number;
  };
}): string {
  const { cx, cy, cz } = region.chunkCoord;
  const micro =
    (region.temperatureMicroCells ?? 0) > 0 ||
    (region.electricMicroCells ?? 0) > 0 ||
    (region.currentMicroCells ?? 0) > 0
      ? ` micro=temp:${region.temperatureMicroCells ?? 0}/${region.temperatureMicroGroups ?? 0} electric:${region.electricMicroCells ?? 0}/${region.electricMicroGroups ?? 0} current:${region.currentMicroCells ?? 0}/${region.currentMicroGroups ?? 0}`
      : "";
  return `region#${region.regionId}@${cx},${cy},${cz} temp=${region.temperatureCells} electric=${region.electricCells} current=${region.currentCells ?? 0}${micro} smoke=${region.smokeParticles ?? 0}${formatTemperatureFieldStats(temperatureStatsForFieldRegion(region))}`;
}

function temperatureStatsForFieldRegion(region: {
  temperatureCells: number;
  maxTemperatureCelsius?: number | null;
  maxAbsTemperatureDeltaCelsius?: number;
  averageAbsTemperatureDeltaCelsius?: number;
  temperatureStats?: {
    maxTemperatureCelsius: number | null;
    maxAbsTemperatureDeltaCelsius: number;
    averageAbsTemperatureDeltaCelsius: number;
  };
}):
  | {
      maxTemperatureCelsius: number | null;
      maxAbsTemperatureDeltaCelsius: number;
      averageAbsTemperatureDeltaCelsius: number;
    }
  | undefined {
  if (region.temperatureStats) return region.temperatureStats;
  if (region.temperatureCells <= 0 || region.maxAbsTemperatureDeltaCelsius === undefined) {
    return undefined;
  }
  return {
    maxTemperatureCelsius: region.maxTemperatureCelsius ?? null,
    maxAbsTemperatureDeltaCelsius: region.maxAbsTemperatureDeltaCelsius,
    averageAbsTemperatureDeltaCelsius: region.averageAbsTemperatureDeltaCelsius ?? 0,
  };
}

function formatTemperatureFieldStats(
  stats:
    | {
        maxTemperatureCelsius: number | null;
        maxAbsTemperatureDeltaCelsius: number;
        averageAbsTemperatureDeltaCelsius: number;
      }
    | undefined,
): string {
  if (!stats) return "";

  return ` heat=maxT=${formatCelsius(stats.maxTemperatureCelsius)} maxDelta=${formatCelsius(stats.maxAbsTemperatureDeltaCelsius)} avgDelta=${formatCelsius(stats.averageAbsTemperatureDeltaCelsius)}`;
}

function formatCelsius(value: number | null | undefined): string {
  const safeValue = typeof value === "number" && Number.isFinite(value) ? value : 0;
  return `${safeValue.toFixed(1)}C`;
}
