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
import { EVoxelRotation, type FMacroCoord, type FMicroCoord } from "../../voxel/core/types";
import { isMicroCoordInBounds } from "../../voxel/microgrid/governance";
import {
  countBits,
  type LocalPrefab,
  type PrefabBoundarySnapPreview,
  type PrefabSocketSnapPreview,
} from "../../voxel/prefab";
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
      case "micro_cell":
        return this.cmdMicroCell(command, args);
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
          },
        });
      case "jump":
        this.deps.localPlayer.requestJump("cli");
        return this.ok(command, "jump queued", this.playerData());
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

  private cmdMicroCell(command: string, args: string[]): CliCommandResult {
    const target = parseMicroTarget(args);
    if (!target) {
      return { ok: false, command, text: "usage: micro_cell <x> <y> <z> <mx> <my> <mz>" };
    }
    return this.ok(command, `micro_cell ${formatMicroTarget(target)}`, {
      ...target,
      block: this.deps.world.store.getMicroBlockWorld(target.macro, target.micro),
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
        text: "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rot0|rot90|rot180|rot270] OR prefab_snap_preview <name> <target-instance> <target-socket> [incoming-socket] [rot0|rot90|rot180|rot270]",
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
        text: "usage: prefab_place_snap <name> <x> <y> <z> <nx> <ny> <nz> [rot0|rot90|rot180|rot270]",
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
    return [
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
      actorDisplay: this.deps.render.getActorDisplaySnapshot(),
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
            movementMode: state.movementMode,
            groundY: state.groundY,
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

function parseMacroCoord(args: string[]): FMacroCoord | null {
  const [xRaw, yRaw, zRaw] = args;
  const x = Number.parseInt(xRaw ?? "", 10);
  const y = Number.parseInt(yRaw ?? "", 10);
  const z = Number.parseInt(zRaw ?? "", 10);
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) return null;
  return { x, y, z };
}

function parseMicroTarget(args: string[]): { macro: FMacroCoord; micro: FMicroCoord } | null {
  const macro = parseMacroCoord(args.slice(0, 3));
  const micro = parseMicroCoord(args.slice(3, 6));
  if (!macro || !micro) {
    return null;
  }
  return { macro, micro };
}

function parseMicroCoord(args: string[]): FMicroCoord | null {
  const coord = parseMacroCoord(args);
  if (!coord || !isMicroCoordInBounds(coord)) {
    return null;
  }
  return coord;
}

function formatVector(vector: Vector3): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}

function formatVectorLike(vector: { x: number; y: number; z: number }): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}

function formatCoord(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function formatMicroTarget(target: { macro: FMacroCoord; micro: FMicroCoord }): string {
  return `${formatCoord(target.macro)}:${formatCoord(target.micro)}`;
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

function parseSocketSnapRequest(args: string[]): {
  prefabName: string;
  targetInstanceId: number;
  targetSocketId: string;
  incomingSocketId?: string;
  rotation?: EVoxelRotation;
} | null {
  const prefabName = args[0];
  const targetInstanceId = Number.parseInt(args[1] ?? "", 10);
  const targetSocketId = args[2];
  if (!prefabName || !Number.isFinite(targetInstanceId) || !targetSocketId) {
    return null;
  }

  const fourth = args[3];
  const fifth = args[4];
  let incomingSocketId: string | undefined;
  let rotation = EVoxelRotation.Rot0;
  if (fourth !== undefined) {
    const fourthAsRotation = parseRotation(fourth);
    if (fourthAsRotation === null) {
      incomingSocketId = fourth;
      if (fifth !== undefined) {
        const parsed = parseRotation(fifth);
        if (parsed === null) {
          return null;
        }
        rotation = parsed;
      }
    } else {
      if (fifth !== undefined) {
        return null;
      }
      rotation = fourthAsRotation;
    }
  }

  return {
    prefabName,
    targetInstanceId,
    targetSocketId,
    ...(incomingSocketId ? { incomingSocketId } : {}),
    rotation,
  };
}

function parseBoundarySnapRequest(args: string[]): {
  prefabName: string;
  hitMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  rotation?: EVoxelRotation;
} | null {
  const prefabName = args[0];
  const hitMacro = parseMacroCoord(args.slice(1, 4));
  const faceNormal = parseMacroCoord(args.slice(4, 7));
  if (!prefabName || !hitMacro || !faceNormal) {
    return null;
  }
  const rotation = parseRotation(args[7]);
  if (rotation === null) {
    return null;
  }
  return { prefabName, hitMacro, faceNormal, rotation };
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
      boundaryFaceMasks: serializeBoundaryFaceMasks(prefab),
      sockets: prefab.definition.sockets.map(serializeSocketForCli),
    },
  };
}

function serializePrefabSocketData(prefab: LocalPrefab): Record<string, unknown> {
  return {
    prefabId: prefab.definition.prefabId,
    boundaryFaceMasks: serializeBoundaryFaceMasks(prefab),
    sockets: prefab.definition.sockets.map(serializeSocketForCli),
  };
}

function serializeBoundaryFaceMasks(prefab: LocalPrefab): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(prefab.definition.boundaryFaceMasks).map(([face, mask]) => [
      face,
      {
        mask: mask.toString(),
        occupiedSlots: countBits(mask),
      },
    ]),
  );
}

function serializeSocketForCli(
  socket: LocalPrefab["definition"]["sockets"][number],
): Record<string, unknown> {
  return {
    ...socket,
    faceMask: socket.faceMask?.toString(),
    faceMaskOccupiedSlots: countBits(socket.faceMask ?? 0n),
  };
}

function serializeSnapPreview(preview: PrefabSocketSnapPreview): Record<string, unknown> {
  return {
    ...preview,
    cells: serializeRasterCells(preview.cells),
  };
}

function serializeBoundarySnapPreview(preview: PrefabBoundarySnapPreview): Record<string, unknown> {
  return {
    ...preview,
    cells: serializeRasterCells(preview.cells),
  };
}

function serializeRasterCells(cells: PrefabSocketSnapPreview["cells"]): Record<string, unknown>[] {
  return cells.map((cell) => ({
    macro: cell.macro,
    microOccupancyMask: cell.microOccupancyMask.toString(),
    occupiedSlots: countBits(cell.microOccupancyMask),
  }));
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
