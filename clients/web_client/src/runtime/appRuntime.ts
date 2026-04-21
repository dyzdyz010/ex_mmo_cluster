import {
  BoxGeometry,
  Group,
  Mesh,
  MeshStandardMaterial,
  RingGeometry,
  Vector3,
} from "three";
import { installCli, type CliCommandHandler, type CliCommandResult } from "../observe/cli";
import { ObserveLog } from "../observe/logger";
import { getMaterialDefinition, listMaterialDefinitions, parseMaterialIdOrName, VoxelMaterialId } from "../material/catalog";
import { LocalPredictionRuntime } from "../movement/localPlayer";
import { INTERPOLATION_DELAY_SECS, RemotePlayerState } from "../movement/remotePlayer";
import { DEFAULT_MOVEMENT_PROFILE } from "../movement/profile";
import { buildMovementInputDirection, SimulatedLocalMovementTransport, type MovementTransport } from "../net/movementTransport";
import { ServerMovementTransport } from "../net/serverMovementTransport";
import { createScene, type SceneHandles } from "../render/scene";
import { ChunkRenderController, type VoxelRaySelection } from "../render/chunkRenderer";
import { type FMacroCoord } from "../voxel/core/types";
import type { FNormalBlockData } from "../voxel/storage/types";
import { LocalVoxelWorldAdapter } from "../voxel/worldAdapter";

const LOCAL_RENDER_SMOOTHING_RATE_HZ = 15;
const LOCAL_VISUAL_HARD_SNAP_DISTANCE = 256;

export class AppRuntime implements CliCommandHandler {
  private readonly logger = new ObserveLog(1200);
  private readonly sceneHandles: SceneHandles;
  private readonly worldAdapter = new LocalVoxelWorldAdapter();
  private readonly chunkRenderer = new ChunkRenderController();
  private readonly localPrediction = new LocalPredictionRuntime();
  private readonly remoteState = new RemotePlayerState();
  private readonly movementTransport: MovementTransport;
  private readonly rootGroup = new Group();
  private readonly localAvatar: Mesh;
  private readonly authorityAvatar: Mesh;
  private readonly remoteAvatar: Mesh;
  private readonly syncRing: Mesh;
  private readonly movementKeys = {
    forward: false,
    backward: false,
    left: false,
    right: false,
  };
  private selectedMaterialId: number = VoxelMaterialId.Dirt;
  private currentSelection: VoxelRaySelection | null = null;
  private currentTransportMode = "uninitialized";
  private lastFrameAtMs = performance.now();
  private localMovementAccumulatorMs = 0;
  private localRenderAnchor = new Vector3();
  private localRenderedPosition = new Vector3();
  private localPendingCorrection = new Vector3();
  private latestAuthoritativePosition = new Vector3();
  private remoteRenderedPosition = new Vector3();
  private diagnosticsAccumulatorMs = 0;

  private readonly handleKeyDown = (event: KeyboardEvent): void => {
    switch (event.code) {
      case "KeyW":
      case "ArrowUp":
        this.movementKeys.forward = true;
        break;
      case "KeyS":
      case "ArrowDown":
        this.movementKeys.backward = true;
        break;
      case "KeyA":
      case "ArrowLeft":
        this.movementKeys.left = true;
        break;
      case "KeyD":
      case "ArrowRight":
        this.movementKeys.right = true;
        break;
      case "Digit1":
        this.setSelectedMaterial(VoxelMaterialId.Dirt, "keyboard");
        break;
      case "Digit2":
        this.setSelectedMaterial(VoxelMaterialId.Stone, "keyboard");
        break;
      case "Digit3":
        this.setSelectedMaterial(VoxelMaterialId.Wood, "keyboard");
        break;
      case "Digit4":
        this.setSelectedMaterial(VoxelMaterialId.Ice, "keyboard");
        break;
      case "KeyF":
        this.placeSelectedBlock("keyboard");
        break;
      case "KeyG":
        this.breakSelectedBlock("keyboard");
        break;
      default:
        break;
    }
  };

  private readonly handleKeyUp = (event: KeyboardEvent): void => {
    switch (event.code) {
      case "KeyW":
      case "ArrowUp":
        this.movementKeys.forward = false;
        break;
      case "KeyS":
      case "ArrowDown":
        this.movementKeys.backward = false;
        break;
      case "KeyA":
      case "ArrowLeft":
        this.movementKeys.left = false;
        break;
      case "KeyD":
      case "ArrowRight":
        this.movementKeys.right = false;
        break;
      default:
        break;
    }
  };

  private readonly tick = (nowMs: number): void => {
    const dtMs = Math.max(0, nowMs - this.lastFrameAtMs);
    this.lastFrameAtMs = nowMs;
    const transportTick = this.movementTransport.tick(nowMs, dtMs);
    this.currentTransportMode = this.movementTransport.mode;

    this.localMovementAccumulatorMs += dtMs;
    while (this.localMovementAccumulatorMs >= DEFAULT_MOVEMENT_PROFILE.fixedDtMs) {
      this.localMovementAccumulatorMs -= DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
      this.stepLocalMovement(nowMs);
    }

    if (transportTick.spawnPosition) {
      this.resetMovementDemo(transportTick.spawnPosition);
    }

    this.consumeAuthority(nowMs, transportTick.acknowledgements);
    this.consumeRemoteSnapshots(nowMs, transportTick.remoteSnapshots);
    this.advanceLocalRenderPrediction(dtMs / 1000);
    this.updateAvatarTransforms(nowMs / 1000);
    this.sceneHandles.update(dtMs / 1000);
    this.currentSelection = this.chunkRenderer.raycastFromCameraCenter(this.sceneHandles.camera);
    this.chunkRenderer.setTargetHighlights(this.currentSelection);
    this.chunkRenderer.syncDirtyChunks(this.worldAdapter.store, this.logger);
    this.updateHud();
    this.maybeEmitDiagnostics(dtMs);
    this.sceneHandles.renderer.render(this.sceneHandles.scene, this.sceneHandles.camera);
    requestAnimationFrame(this.tick);
  };

  private constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly hud: HTMLDivElement,
  ) {
    this.movementTransport = createMovementTransport(this.logger);
    this.currentTransportMode = this.movementTransport.mode;
    this.sceneHandles = createScene(canvas);
    this.sceneHandles.scene.add(this.rootGroup);
    this.chunkRenderer.attachToScene(this.rootGroup);

    this.localAvatar = new Mesh(
      new BoxGeometry(70, 120, 70),
      new MeshStandardMaterial({ color: 0x63d4ff, emissive: 0x113447, roughness: 0.35 }),
    );
    this.authorityAvatar = new Mesh(
      new BoxGeometry(50, 90, 50),
      new MeshStandardMaterial({ color: 0xfafcff, transparent: true, opacity: 0.35, roughness: 0.2 }),
    );
    this.remoteAvatar = new Mesh(
      new BoxGeometry(70, 120, 70),
      new MeshStandardMaterial({ color: 0xffbb55, emissive: 0x4c2b08, roughness: 0.4 }),
    );
    this.syncRing = new Mesh(
      new RingGeometry(170, 190, 48),
      new MeshStandardMaterial({ color: 0x284051, emissive: 0x0d1a22, roughness: 0.9 }),
    );
    this.syncRing.rotation.x = -Math.PI / 2;

    this.rootGroup.add(this.localAvatar, this.authorityAvatar, this.remoteAvatar, this.syncRing);

    this.worldAdapter.bootstrap();
    this.chunkRenderer.syncDirtyChunks(this.worldAdapter.store, this.logger);
    this.resetMovementDemo();

    window.addEventListener("keydown", this.handleKeyDown);
    window.addEventListener("keyup", this.handleKeyUp);
    window.addEventListener("beforeunload", () => this.dispose(), { once: true });
    window.addEventListener("contextmenu", (event) => event.preventDefault());

    installCli(window, this.logger, this);
    this.logger.emit("boot", "runtime_started", {
      chunks: this.worldAdapter.store.listChunks().length,
      solid_blocks: this.worldAdapter.store.totalSolidBlocks(),
      selected_material: this.selectedMaterialId,
      transport: this.currentTransportMode,
      world_mode: this.worldAdapter.mode,
    });
  }

  static boot(canvas: HTMLCanvasElement, hud: HTMLDivElement): AppRuntime {
    const runtime = new AppRuntime(canvas, hud);
    requestAnimationFrame(runtime.tick);
    return runtime;
  }

  executeCliCommand(command: string, args: string[]): CliCommandResult {
    switch (command) {
      case "snapshot":
        return this.makeResult(command, this.snapshotText(), this.snapshotData());
      case "chunks":
        return this.commandChunks(command, args);
      case "cell":
        return this.commandCell(command, args);
      case "place":
        return this.commandPlace(command, args);
      case "break":
        return this.commandBreak(command, args);
      case "prefabs":
        return this.makeResult(command, "prefab list", this.worldAdapter.listPrefabs());
      case "prefab_capture":
        return this.commandPrefabCapture(command, args);
      case "prefab_place":
        return this.commandPrefabPlace(command, args);
      case "select_material":
        return this.commandSelectMaterial(command, args);
      case "player":
        return this.makeResult(command, "local player snapshot", this.playerData());
      case "players":
        return this.makeResult(command, "local and remote players", {
          local: this.playerData(),
          remote: {
            position: this.formatVector(this.remoteRenderedPosition),
            interpolation_delay_secs: INTERPOLATION_DELAY_SECS,
          },
        });
      case "transport":
        return this.makeResult(command, "transport snapshot", this.transportData());
      case "reconcile_stats":
        return this.makeResult(command, "reconcile stats", this.localPrediction.getGovernanceStats());
      case "edit_stats":
        return this.makeResult(command, "edit stats", { ...this.worldAdapter.store.editStats });
      default:
        return {
          ok: false,
          command,
          text: `unknown command: ${command}`,
        };
    }
  }

  private commandChunks(command: string, args: string[]): CliCommandResult {
    const limit = Number.parseInt(args[0] ?? "12", 10);
    const chunks = this.worldAdapter.store.chunkSummaries(Number.isFinite(limit) ? limit : 12);
    return this.makeResult(command, `chunks=${chunks.length}`, chunks);
  }

  private commandCell(command: string, args: string[]): CliCommandResult {
    const coord = this.parseMacroCoordArgs(args);
    if (!coord) {
      return { ok: false, command, text: "usage: cell <x> <y> <z>" };
    }

    return this.makeResult(command, `cell ${this.formatMacroCoord(coord)}`, {
      coord,
      block: this.worldAdapter.store.getNormalBlockWorld(coord),
      environment: this.worldAdapter.store.getEnvironmentSummaryWorld(coord),
    });
  }

  private commandPlace(command: string, args: string[]): CliCommandResult {
    const coord = this.parseMacroCoordArgs(args);
    if (!coord) {
      return { ok: false, command, text: "usage: place <x> <y> <z> [material]" };
    }

    const materialArg = args[3];
    const materialId =
      materialArg !== undefined ? parseMaterialIdOrName(materialArg) ?? this.selectedMaterialId : this.selectedMaterialId;
    const ok = this.placeBlockAt(coord, materialId, "cli");
    return this.makeResult(command, ok ? "placed" : "place rejected", {
      coord,
      materialId,
      ok,
    });
  }

  private commandBreak(command: string, args: string[]): CliCommandResult {
    const coord = this.parseMacroCoordArgs(args);
    if (!coord) {
      return { ok: false, command, text: "usage: break <x> <y> <z>" };
    }

    const ok = this.breakBlockAt(coord, "cli");
    return this.makeResult(command, ok ? "broken" : "break rejected", {
      coord,
      ok,
    });
  }

  private commandSelectMaterial(command: string, args: string[]): CliCommandResult {
    const materialArg = args[0];
    if (!materialArg) {
      return { ok: false, command, text: "usage: select_material <id|name>" };
    }
    const materialId = parseMaterialIdOrName(materialArg);
    if (materialId === null) {
      return { ok: false, command, text: `unknown material: ${materialArg}` };
    }
    this.setSelectedMaterial(materialId, "cli");
    return this.makeResult(command, `selected material ${materialId}`, {
      materialId,
      material: getMaterialDefinition(materialId),
    });
  }

  private commandPrefabCapture(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    const min = this.parseMacroCoordArgs(args.slice(1, 4));
    const max = this.parseMacroCoordArgs(args.slice(4, 7));
    if (!name || !min || !max) {
      return { ok: false, command, text: "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>" };
    }

    const prefab = this.worldAdapter.capturePrefab(name, min, max);
    this.logger.emit("prefab", "capture", { name, blocks: prefab.blocks.length });
    return this.makeResult(command, `captured prefab ${name}`, prefab);
  }

  private commandPrefabPlace(command: string, args: string[]): CliCommandResult {
    const name = args[0];
    const origin = this.parseMacroCoordArgs(args.slice(1, 4));
    if (!name || !origin) {
      return { ok: false, command, text: "usage: prefab_place <name> <x> <y> <z>" };
    }

    const result = this.worldAdapter.placePrefab(name, origin);
    this.logger.emit("prefab", result.ok ? "place" : "place_rejected", {
      name,
      origin: this.formatMacroCoord(origin),
      placed: result.placed,
    });

    return this.makeResult(command, result.ok ? `placed prefab ${name}` : `unknown prefab ${name}`, result);
  }

  private resetMovementDemo(start: Vector3 = new Vector3(-350, 650, -280)): void {
    this.localPrediction.reset(start);
    this.movementTransport.reset(start);
    this.currentTransportMode = this.movementTransport.mode;
    this.localRenderAnchor.copy(start);
    this.localRenderedPosition.copy(start);
    this.localPendingCorrection.set(0, 0, 0);
    this.latestAuthoritativePosition.copy(start);
    this.remoteRenderedPosition.set(400, 650, 320);
    this.logger.emit("movement", "demo_reset", {
      start: this.formatVector(start),
    });
  }

  private stepLocalMovement(nowMs: number): void {
    if (!this.movementTransport.isReady()) {
      return;
    }

    const inputDir = buildMovementInputDirection(this.movementKeys);
    const frame = this.localPrediction.buildInputFrame(inputDir, DEFAULT_MOVEMENT_PROFILE.fixedDtMs, 1);
    const predicted = this.localPrediction.applyLocalInput(frame);
    if (!predicted) {
      return;
    }

    this.localRenderAnchor.copy(predicted.position);
    this.localRenderedPosition.copy(this.localRenderAnchor.clone().add(this.localPendingCorrection));
    this.movementTransport.sendInput(frame, nowMs);
    this.logger.emit("movement", "input_frame", {
      seq: frame.seq,
      tick: frame.clientTick,
      input_x: frame.inputDir.x.toFixed(2),
      input_z: frame.inputDir.y.toFixed(2),
      predicted: this.formatVector(predicted.position),
    });
  }

  private consumeAuthority(nowMs: number, due: ReadonlyArray<{ ack: { ackSeq: number; authTick: number; position: Vector3; velocity: Vector3; acceleration: Vector3; correctionFlags: number; }; sentAtMs: number; }>): void {
    for (const delivered of due) {
      const rttMs = Math.max(0, nowMs - delivered.sentAtMs);
      this.localPrediction.observeRtt(rttMs);
      const result = this.localPrediction.applyAck(delivered.ack);
      if (!result) {
        continue;
      }
      this.latestAuthoritativePosition.copy(delivered.ack.position);
      this.syncLocalRenderPrediction(result.latestState.position);
      this.logger.emit("movement", "ack", {
        seq: delivered.ack.ackSeq,
        tick: delivered.ack.authTick,
        action: result.action,
        correction_distance: result.correctionDistance.toFixed(2),
        pending_inputs: result.pendingInputs,
        replayed_frames: result.replayedFrames,
        rtt_ms: rttMs.toFixed(1),
      });
    }
  }

  private consumeRemoteSnapshots(nowMs: number, due: ReadonlyArray<{ cid: number; serverTick: number; position: Vector3; velocity: Vector3; acceleration: Vector3; }>): void {
    for (const item of due) {
      this.remoteState.pushSnapshot(item, 0, nowMs / 1000);
      this.logger.emit("movement", "remote_snapshot", {
        cid: item.cid,
        tick: item.serverTick,
        position: this.formatVector(item.position),
      });
    }

    const sample = this.remoteState.sampleMotion(nowMs / 1000);
    this.remoteRenderedPosition.copy(sample.position);
  }

  private syncLocalRenderPrediction(nextAnchor: Vector3): void {
    const oldRendered = this.localRenderedPosition.clone();
    this.localRenderAnchor.copy(nextAnchor);
    this.localPendingCorrection.copy(oldRendered.sub(nextAnchor));
    if (this.localPendingCorrection.length() <= 18) {
      this.localPendingCorrection.set(0, 0, 0);
    }
    if (this.localPendingCorrection.length() > LOCAL_VISUAL_HARD_SNAP_DISTANCE) {
      this.localPendingCorrection.set(0, 0, 0);
    }
    this.localRenderedPosition.copy(this.localRenderAnchor.clone().add(this.localPendingCorrection));
  }

  private advanceLocalRenderPrediction(dtSecs: number): void {
    const damping = Math.exp(-LOCAL_RENDER_SMOOTHING_RATE_HZ * dtSecs);
    this.localPendingCorrection.multiplyScalar(damping);
    if (this.localPendingCorrection.length() < 0.01) {
      this.localPendingCorrection.set(0, 0, 0);
    }
    this.localRenderedPosition.copy(this.localRenderAnchor.clone().add(this.localPendingCorrection));
  }

  private updateAvatarTransforms(nowSecs: number): void {
    const localDisplay = this.groundActorPosition(this.localRenderedPosition, 60);
    const authorityDisplay = this.groundActorPosition(this.latestAuthoritativePosition, 45);
    const remoteDisplay = this.groundActorPosition(this.remoteRenderedPosition, 60);

    this.localAvatar.position.copy(localDisplay);
    this.authorityAvatar.position.copy(authorityDisplay);
    this.remoteAvatar.position.copy(remoteDisplay);
    this.syncRing.position.set(localDisplay.x, localDisplay.y - 59, localDisplay.z);
    this.syncRing.rotation.z = nowSecs * 0.25;
    this.sceneHandles.setCameraFollow(localDisplay);
  }

  private updateHud(): void {
    const currentState = this.localPrediction.getCurrentState();
    const stats = this.localPrediction.getGovernanceStats();
    const transportSnapshot = this.transportData();
    const selectionText = this.currentSelection
      ? `${this.formatMacroCoord(this.currentSelection.occupiedMacro)} -> ${this.formatMacroCoord(this.currentSelection.adjacentMacro)}`
      : "n/a";

    this.hud.textContent = [
      "ex_mmo voxel web-client",
      `voxel_sync: ${this.worldAdapter.mode}  movement_transport: ${this.currentTransportMode}`,
      `movement_ready: ${this.movementTransport.isReady()}  transport_state: ${JSON.stringify(transportSnapshot)}`,
      `chunks: ${this.worldAdapter.store.listChunks().length}  solid_blocks: ${this.worldAdapter.store.totalSolidBlocks()}`,
      `selected_material: ${getMaterialDefinition(this.selectedMaterialId).name} (${this.selectedMaterialId})`,
      `selection: ${selectionText}`,
      `player_rendered: ${this.formatVector(this.localRenderedPosition)}`,
      `player_authority: ${this.formatVector(this.latestAuthoritativePosition)}`,
      `player_tick: ${currentState?.tick ?? 0}  player_seq: ${currentState?.seq ?? 0}`,
      `remote_rendered: ${this.formatVector(this.remoteRenderedPosition)}`,
      `reconcile: corrections=${stats.totalCorrections} replays=${stats.totalReplays} hard_snaps=${stats.totalHardSnaps}`,
      `last_correction=${stats.lastCorrectionDistance.toFixed(2)}  jitter_ms=${this.localPrediction.getCurrentJitterMs().toFixed(2)}  soft=${this.localPrediction.getCurrentSoftPositionError().toFixed(2)}`,
      `edits: placed=${this.worldAdapter.store.editStats.placed} broken=${this.worldAdapter.store.editStats.broken} rejected=${this.worldAdapter.store.editStats.rejected} conflicts=${this.worldAdapter.store.editStats.conflicts}`,
      "controls: click or drag to orbit camera, wheel zoom, WASD move, F place, G break, 1-4 material",
      "cli: window.__voxelCli?.run(\"snapshot\")",
    ].join("\n");
  }

  private maybeEmitDiagnostics(dtMs: number): void {
    this.diagnosticsAccumulatorMs += dtMs;
    if (this.diagnosticsAccumulatorMs < 2000) {
      return;
    }
    this.diagnosticsAccumulatorMs = 0;

    this.logger.emit("diag", "snapshot", {
      chunks: this.worldAdapter.store.listChunks().length,
      solid_blocks: this.worldAdapter.store.totalSolidBlocks(),
      player_rendered: this.formatVector(this.localRenderedPosition),
      player_authority: this.formatVector(this.latestAuthoritativePosition),
      remote_rendered: this.formatVector(this.remoteRenderedPosition),
      selected_material: this.selectedMaterialId,
    });
  }

  private placeSelectedBlock(source: string): void {
    if (!this.currentSelection) {
      this.logger.emit("edit", "place_rejected", {
        reason: "no_selection",
        source,
      });
      this.worldAdapter.store.editStats.rejected += 1;
      return;
    }
    this.placeBlockAt(this.currentSelection.adjacentMacro, this.selectedMaterialId, source);
  }

  private breakSelectedBlock(source: string): void {
    if (!this.currentSelection) {
      this.logger.emit("edit", "break_rejected", {
        reason: "no_selection",
        source,
      });
      this.worldAdapter.store.editStats.rejected += 1;
      return;
    }
    this.breakBlockAt(this.currentSelection.occupiedMacro, source);
  }

  private placeBlockAt(coord: FMacroCoord, materialId: number, source: string): boolean {
    const block: FNormalBlockData = {
      materialId,
      stateFlags: 0,
      health: getMaterialDefinition(materialId).maxHealth,
      temperatureDelta: 0,
      moistureDelta: 0,
    };
    const ok = this.worldAdapter.placeBlock(coord, block);
    this.logger.emit("edit", ok ? "place" : "place_rejected", {
      coord: this.formatMacroCoord(coord),
      material: materialId,
      source,
    });
    return ok;
  }

  private breakBlockAt(coord: FMacroCoord, source: string): boolean {
    const ok = this.worldAdapter.breakBlock(coord);
    this.logger.emit("edit", ok ? "break" : "break_rejected", {
      coord: this.formatMacroCoord(coord),
      source,
    });
    return ok;
  }

  private setSelectedMaterial(materialId: number, source: string): void {
    this.selectedMaterialId = materialId;
    this.logger.emit("edit", "select_material", {
      material: materialId,
      source,
    });
  }

  private snapshotText(): string {
    this.currentTransportMode = this.movementTransport.mode;
    return [
      `transport=${this.currentTransportMode}`,
      `voxel_sync=${this.worldAdapter.mode}`,
      `chunks=${this.worldAdapter.store.listChunks().length}`,
      `solid_blocks=${this.worldAdapter.store.totalSolidBlocks()}`,
      `selected_material=${getMaterialDefinition(this.selectedMaterialId).name}`,
      `player_rendered=${this.formatVector(this.localRenderedPosition)}`,
      `player_authority=${this.formatVector(this.latestAuthoritativePosition)}`,
      `remote_rendered=${this.formatVector(this.remoteRenderedPosition)}`,
    ].join(" ");
  }

  private snapshotData(): Record<string, unknown> {
    this.currentTransportMode = this.movementTransport.mode;
    const transportSnapshot = this.transportData();
    return {
      transport: this.currentTransportMode,
      voxelSync: this.worldAdapter.mode,
      chunks: this.worldAdapter.store.listChunks().length,
      solidBlocks: this.worldAdapter.store.totalSolidBlocks(),
      selectedMaterialId: this.selectedMaterialId,
      selectedMaterial: getMaterialDefinition(this.selectedMaterialId),
      currentSelection: this.currentSelection,
      player: this.playerData(),
      remote: {
        position: this.formatVector(this.remoteRenderedPosition),
      },
      camera: {
        position: this.formatVector(this.sceneHandles.camera.position),
      },
      transportState: transportSnapshot,
      materials: listMaterialDefinitions(),
    };
  }

  private transportData(): Record<string, unknown> {
    return {
      voxelSync: this.worldAdapter.mode,
      movementTransport: this.movementTransport.debugSnapshot(),
    };
  }

  private playerData(): Record<string, unknown> {
    const state = this.localPrediction.getCurrentState();
    return {
      predicted: state
        ? {
            seq: state.seq,
            tick: state.tick,
            position: this.formatVector(state.position),
            velocity: this.formatVector(state.velocity),
            acceleration: this.formatVector(state.acceleration),
          }
        : null,
      renderedPosition: this.formatVector(this.localRenderedPosition),
      groundedRenderedPosition: this.formatVector(this.localAvatar.position),
      authoritativePosition: this.formatVector(this.latestAuthoritativePosition),
      groundedAuthoritativePosition: this.formatVector(this.authorityAvatar.position),
      pendingCorrection: this.formatVector(this.localPendingCorrection),
      jitterMs: this.localPrediction.getCurrentJitterMs(),
      softPositionError: this.localPrediction.getCurrentSoftPositionError(),
    };
  }

  private parseMacroCoordArgs(args: string[]): FMacroCoord | null {
    const [xRaw, yRaw, zRaw] = args;
    const x = Number.parseInt(xRaw ?? "", 10);
    const y = Number.parseInt(yRaw ?? "", 10);
    const z = Number.parseInt(zRaw ?? "", 10);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) {
      return null;
    }
    return { x, y, z };
  }

  private formatVector(vector: Vector3): string {
    return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
  }

  private formatMacroCoord(coord: FMacroCoord): string {
    return `${coord.x},${coord.y},${coord.z}`;
  }

  private groundActorPosition(position: Vector3, halfHeight: number): Vector3 {
    return new Vector3(
      position.x,
      this.worldAdapter.store.surfaceCenterYAtWorldXZ(position.x, position.z, halfHeight, position.y),
      position.z,
    );
  }

  private makeResult(command: string, text: string, data?: unknown): CliCommandResult {
    return {
      ok: true,
      command,
      text,
      data,
    };
  }

  dispose(): void {
    this.chunkRenderer.dispose();
    this.sceneHandles.dispose();
    this.localAvatar.geometry.dispose();
    (this.localAvatar.material as MeshStandardMaterial).dispose();
    this.authorityAvatar.geometry.dispose();
    (this.authorityAvatar.material as MeshStandardMaterial).dispose();
    this.remoteAvatar.geometry.dispose();
    (this.remoteAvatar.material as MeshStandardMaterial).dispose();
    this.syncRing.geometry.dispose();
    (this.syncRing.material as MeshStandardMaterial).dispose();
    window.removeEventListener("keydown", this.handleKeyDown);
    window.removeEventListener("keyup", this.handleKeyUp);
  }
}

function createMovementTransport(logger: ObserveLog): MovementTransport {
  if (import.meta.env.VITE_MOVEMENT_TRANSPORT === "simulated") {
    return new SimulatedLocalMovementTransport();
  }

  return new ServerMovementTransport(logger);
}
