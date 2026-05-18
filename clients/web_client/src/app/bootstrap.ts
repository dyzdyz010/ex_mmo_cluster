import { ObserveLog } from "../observe/logger";
import {
  TouchControlsView,
  type TouchControlsElements,
} from "../presentation/touch/TouchControlsView";
import type { MovementTransport } from "@domain/movement/transport";
import { SimulatedLocalMovementTransport } from "@infra/net/simulatedMovementTransport";
import { ServerMovementTransport } from "@infra/net/serverMovementTransport";
import { createScene } from "../render/scene";
import {
  DefaultRendererPreference,
  normalizeRendererPreference,
  type RendererPreference,
} from "../render/rendererBackend";
import { LocalVoxelWorldAdapter, type VoxelWorldAdapter } from "../voxel/worldAdapter";
import {
  isServerVoxelTransportPort,
  OnlineVoxelWorldAdapter,
} from "../voxel/onlineVoxelWorldAdapter";
import { HudView } from "../presentation/hud/hudView";
import { HotbarDockView } from "../presentation/hud/hotbarDockView";
import { VoxelDebugPanelView } from "../presentation/hud/voxelDebugPanelView";
import { DevToolsCli } from "../presentation/devtools/devToolsCli";
import { EventBus } from "../shared/events/eventBus";
import type { AppEvents } from "../shared/events/events";
import { formatCoord, formatVector } from "../shared/runtimeFormat";
import { DiagnosticsController } from "./controllers/diagnosticsController";
import { InputController } from "./controllers/inputController";
import { LocalPlayerController } from "./controllers/localPlayerController";
import { RemotePlayerController } from "./controllers/remotePlayerController";
import { RenderOrchestrator } from "./controllers/renderOrchestrator";
import { TransportPump } from "./controllers/transportPump";
import { WorldEditController } from "./controllers/worldEditController";
import { GameLoop } from "./gameLoop";
import { resolveInitialLocalSpawn } from "./spawn";

export interface AppContext {
  readonly eventBus: EventBus<AppEvents>;
  dispose(): void;
}

export interface BootstrapTargets {
  canvas: HTMLCanvasElement;
  hud: HTMLDivElement;
  hotbarDock: HTMLDivElement;
  voxelPanel: HTMLDivElement;
  touchControls: HTMLDivElement;
}

/**
 * Composition root. Constructs every long-lived service, wires them together
 * in explicit dependency order, installs subscribers, and starts the loop.
 *
 * This is the only file allowed to `new` a controller or transport. Everything
 * else takes its dependencies through constructors.
 */
export async function bootstrap({
  canvas,
  hud,
  hotbarDock,
  voxelPanel,
  touchControls,
}: BootstrapTargets): Promise<AppContext> {
  canvas.tabIndex = 0;
  canvas.focus();
  canvas.addEventListener("pointerdown", () => canvas.focus());

  const logger = new ObserveLog(1200);
  const eventBus = new EventBus<AppEvents>();
  const transport = createMovementTransport(logger);
  const world: VoxelWorldAdapter = createVoxelWorldAdapter(logger, eventBus, transport);
  world.bootstrap();
  const initialSpawn = resolveInitialLocalSpawn(world);

  const transportPump = new TransportPump(transport, eventBus);
  transportPump.reset(initialSpawn);

  const input = new InputController(eventBus);
  const detachInput = input.attach(window);

  const localPlayer = new LocalPlayerController(eventBus, input, transportPump, initialSpawn);
  const remotePlayer = new RemotePlayerController(eventBus);

  const sceneHandles = await createScene(canvas, {
    rendererPreference: resolveRendererPreference(),
  });
  const render = new RenderOrchestrator(sceneHandles, world, localPlayer, remotePlayer, logger);
  localPlayer.setCameraYawResolver(() => render.getMovementYawRadians());
  const edit = new WorldEditController(eventBus, world, render);
  render.setEditPreviewProvider(edit);

  const hudView = new HudView(
    hud,
    world,
    transportPump,
    localPlayer,
    remotePlayer,
    edit,
    render,
    eventBus,
  );
  const hotbarDockView = new HotbarDockView(hotbarDock, edit);
  const diagnostics = new DiagnosticsController(
    logger,
    world,
    localPlayer,
    remotePlayer,
    render,
    edit,
  );

  const devTools = new DevToolsCli({
    logger,
    world,
    transport: transportPump,
    localPlayer,
    remotePlayer,
    edit,
    render,
    storage: window.localStorage,
  });
  devTools.install(window);
  const voxelDebugPanelView = new VoxelDebugPanelView(
    voxelPanel,
    devTools,
    world,
    () => render.toggleFieldDebugOverlay(),
    (targetTemperatureCelsius) =>
      edit.setTemperatureAtSelection("voxel_panel", targetTemperatureCelsius),
    () => edit.getSelectedOccupiedMacro(),
    () => edit.getSelectedConductionPair(),
  );
  const unsubscribeConductionEndpointShortcut = eventBus.on(
    "input:capture-conduction-endpoint",
    ({ role, source }) => {
      voxelDebugPanelView.captureConductionEndpoint(role, source);
    },
  );
  const unsubscribeConductionSubmitShortcut = eventBus.on(
    "input:submit-conduction",
    ({ source }) => {
      voxelDebugPanelView.submitConduction(source);
    },
  );

  const loop = new GameLoop();
  loop.subscribe(transportPump);
  if (isFrameDrivenVoxelWorld(world)) {
    loop.subscribe(world);
  }
  loop.subscribe(localPlayer);
  loop.subscribe(remotePlayer);
  loop.subscribe(render);
  loop.subscribe(hudView);
  loop.subscribe(hotbarDockView);
  loop.subscribe(voxelDebugPanelView);
  loop.subscribe(diagnostics);

  const isTouchPrimary =
    window.matchMedia?.("(pointer: coarse)")?.matches === true && navigator.maxTouchPoints > 0;

  let touchControlsView: TouchControlsView | null = null;

  if (isTouchPrimary) {
    const elements = resolveTouchControlsElements(touchControls);
    if (elements) {
      document.documentElement.classList.add("is-touch");
      input.setDisableCanvasActions(true);
      sceneHandles.setDisableCanvasInput(true);

      touchControlsView = new TouchControlsView(elements, {
        setMovement: (vec) => input.setVirtualMovement(vec),
        requestJump: (source) => input.requestJump(source),
        emitBreak: () => eventBus.emit("input:break-block", { source: "touch_button" }),
        emitPlace: () => eventBus.emit("input:place-block", { source: "touch_button" }),
        applyCameraYawPitchDelta: (yaw, pitch) => sceneHandles.applyCameraYawPitchDelta(yaw, pitch),
      });
      loop.subscribe(touchControlsView);
    } else {
      console.error(
        "[bootstrap] touch-controls DOM tree incomplete — falling back to desktop input",
      );
    }
  }

  bridgeBusToLogger(eventBus, logger, render);

  const rendererSnapshot = render.getRendererDebugSnapshot();
  logger.emit("boot", "runtime_started", {
    chunks: world.store.listChunks().length,
    renderer: rendererSnapshot.active,
    renderer_backend: rendererSnapshot.backend,
    renderer_fallback_reason: rendererSnapshot.fallbackReason ?? "",
    renderer_requested: rendererSnapshot.requested,
    solid_blocks: world.store.totalSolidBlocks(),
    selected_material: edit.getSelectedMaterialId(),
    spawn: formatVector(initialSpawn),
    transport: transportPump.getMode(),
    world_mode: world.mode,
  });

  loop.start();

  const unloadHandler = () => dispose();
  window.addEventListener("beforeunload", unloadHandler, { once: true });

  let disposed = false;
  function dispose(): void {
    if (disposed) return;
    disposed = true;
    loop.stop();
    unsubscribeConductionEndpointShortcut();
    unsubscribeConductionSubmitShortcut();
    detachInput();
    touchControlsView?.dispose();
    document.documentElement.classList.remove("is-touch");
    voxelDebugPanelView.dispose();
    hotbarDockView.dispose();
    render.dispose();
    eventBus.clear();
  }

  return { eventBus, dispose };
}

function resolveTouchControlsElements(root: HTMLElement): TouchControlsElements | null {
  const q = <T extends HTMLElement>(sel: string) => root.querySelector(sel) as T | null;
  const zoneLeft = q<HTMLElement>(".touch-zone--left");
  const zoneRight = q<HTMLElement>(".touch-zone--right");
  const stickLeft = q<HTMLElement>(".touch-stick--left");
  const stickRight = q<HTMLElement>(".touch-stick--right");
  const btnJump = q<HTMLElement>(".touch-btn--jump");
  const btnBreak = q<HTMLElement>(".touch-btn--break");
  const btnPlace = q<HTMLElement>(".touch-btn--place");
  if (!zoneLeft || !zoneRight || !stickLeft || !stickRight || !btnJump || !btnBreak || !btnPlace) {
    return null;
  }
  return { zoneLeft, zoneRight, stickLeft, stickRight, btnJump, btnBreak, btnPlace };
}

function createMovementTransport(logger: ObserveLog): MovementTransport {
  if (import.meta.env.VITE_MOVEMENT_TRANSPORT === "simulated") {
    return new SimulatedLocalMovementTransport();
  }
  return new ServerMovementTransport(logger);
}

function createVoxelWorldAdapter(
  logger: ObserveLog,
  eventBus: EventBus<AppEvents>,
  transport: MovementTransport,
): VoxelWorldAdapter {
  if (import.meta.env.VITE_VOXEL_SYNC === "offline") {
    return new LocalVoxelWorldAdapter();
  }

  if (isServerVoxelTransportPort(transport)) {
    return new OnlineVoxelWorldAdapter(transport, eventBus, logger, {
      logicalSceneId: parsePositiveIntEnv(import.meta.env.VITE_VOXEL_LOGICAL_SCENE_ID, 1),
      defaultRadiusLInf: parsePositiveIntEnv(import.meta.env.VITE_VOXEL_SUBSCRIBE_RADIUS, 0),
      initialSubscriptions: [
        { centerChunk: { x: 0, y: 0, z: 0 }, radiusLInf: 0 },
        { centerChunk: { x: 1, y: 0, z: 0 }, radiusLInf: 0 },
      ],
      devSeed: import.meta.env.VITE_VOXEL_DEV_SEED === "1",
      primeDemoBlock: import.meta.env.VITE_VOXEL_PRIME_DEMO_BLOCK === "1",
    });
  }

  // No silent downgrade. If `VITE_VOXEL_SYNC` is anything other than
  // "offline" but the configured transport cannot satisfy
  // `ServerVoxelTransportPort`, that almost always means the dev-env was
  // forced into a simulated movement transport. Prefer surfacing the
  // mismatch immediately over starting a local-only world that the
  // operator did not actually ask for.
  const movementTransportEnv = import.meta.env.VITE_MOVEMENT_TRANSPORT ?? "(unset)";
  throw new Error(
    `Voxel sync requires a server transport but VITE_MOVEMENT_TRANSPORT=${movementTransportEnv} produced a non-server transport. Set VITE_VOXEL_SYNC=offline if you want offline mode explicitly.`,
  );
}

interface FrameDrivenVoxelWorldAdapter extends VoxelWorldAdapter {
  onFrame(nowMs: number, dtMs: number): void;
}

function isFrameDrivenVoxelWorld(world: VoxelWorldAdapter): world is FrameDrivenVoxelWorldAdapter {
  return typeof (world as Partial<FrameDrivenVoxelWorldAdapter>).onFrame === "function";
}

function parsePositiveIntEnv(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

export function resolveRendererPreference(): RendererPreference {
  const queryPreference = new URLSearchParams(window.location.search).get("renderer");
  return resolveRendererPreferenceFrom(queryPreference, import.meta.env.VITE_RENDER_BACKEND);
}

export function resolveRendererPreferenceFrom(
  queryPreference: string | null,
  envPreference: string | undefined,
): RendererPreference {
  const explicitPreference = queryPreference ?? envPreference;
  return explicitPreference === undefined ||
    explicitPreference === null ||
    explicitPreference === ""
    ? DefaultRendererPreference
    : normalizeRendererPreference(explicitPreference);
}

/**
 * The old monolithic runtime logged directly from every code path it touched.
 * That coupling is replaced by a single bridge that translates bus events
 * into ObserveLog entries, so controllers no longer depend on the logger.
 */
function bridgeBusToLogger(
  bus: EventBus<AppEvents>,
  logger: ObserveLog,
  render: RenderOrchestrator,
): void {
  bus.on("movement:reset", ({ start }) => {
    logger.emit("movement", "demo_reset", { start: formatVector(start) });
  });
  bus.on(
    "movement:local-step",
    ({ seq, clientTick, position, velocity, movementFlags, movementMode }) => {
      logger.emit("movement", "input_frame", {
        seq,
        tick: clientTick,
        predicted: formatVector(position),
        velocity: formatVector(velocity),
        movement_flags: movementFlags,
        movement_mode: movementMode,
      });
    },
  );
  bus.on("movement:authority-applied", (payload) => {
    logger.emit("movement", "ack", {
      seq: payload.ackSeq,
      tick: payload.authTick,
      action: payload.action,
      movement_mode: payload.movementMode,
      velocity: formatVector(payload.velocity),
      correction_distance: payload.correctionDistance.toFixed(2),
      pending_inputs: payload.pendingInputs,
      replayed_frames: payload.replayedFrames,
      rtt_ms: payload.rttMs.toFixed(1),
      server_fixed_dt_ms: payload.serverFixedDtMs,
      fixed_dt_drift_ms: payload.fixedDtDriftMs,
    });
  });
  bus.on("movement:remote-snapshot-ingested", (payload) => {
    logger.emit("movement", "remote_snapshot", {
      cid: payload.cid,
      tick: payload.serverTick,
      position: formatVector(payload.position),
      movement_mode: payload.movementMode,
      priority_band: payload.priorityBand ?? "unknown",
      priority_score: payload.priorityScore ?? -1,
      observer_distance: payload.observerDistance ?? -1,
      delivery_interval: payload.deliveryInterval ?? -1,
    });
  });
  bus.on("input:jump", ({ source }) => {
    logger.emit("input", "jump_pressed", { source });
  });
  bus.on("movement:input-blocked", ({ reason, keys, jump }) => {
    logger.emit("movement", "input_blocked", {
      reason,
      forward: keys.forward,
      backward: keys.backward,
      left: keys.left,
      right: keys.right,
      jump,
    });
  });

  bus.on("input:material-selected", ({ materialId, source }) => {
    logger.emit("edit", "select_material", { material: materialId, source });
  });
  bus.on("input:prefab-selected", ({ prefabName, source }) => {
    logger.emit("edit", "select_prefab", { prefab: prefabName, source });
  });
  bus.on("world:block-placed", ({ coord, materialId, source }) => {
    logger.emit("edit", "place", {
      coord: `${coord.x},${coord.y},${coord.z}`,
      material: materialId,
      source,
    });
  });
  bus.on("world:prefab-placed", ({ name, origin, placed, source }) => {
    logger.emit("edit", "prefab_place", {
      name,
      origin: `${origin.x},${origin.y},${origin.z}`,
      placed,
      source,
    });
  });
  bus.on("world:prefab-snap-committed", (payload) => {
    logger.emit("prefab", "prefab_snap_committed", {
      prefabId: payload.prefabId,
      instanceId: payload.instanceId,
      targetInstanceId: payload.targetInstanceId,
      socketId: payload.socketId ?? "",
      targetSocketId: payload.targetSocketId,
      anchorMicroCoord: formatCoord(payload.anchorMicroCoord),
      affectedMacroCount: payload.affectedMacroCount,
      incomingOccupiedSlots: payload.incomingOccupiedSlots,
      overlapSlots: payload.overlapSlots,
      source: payload.source,
    });
  });
  bus.on("world:prefab-snap-rejected", (payload) => {
    logger.emit("prefab", "prefab_snap_rejected", {
      prefabId: payload.prefabId,
      instanceId: payload.targetInstanceId,
      socketId: payload.socketId ?? "",
      targetSocketId: payload.targetSocketId,
      anchorMicroCoord: payload.anchorMicroCoord ? formatCoord(payload.anchorMicroCoord) : "",
      affectedMacroCount: payload.affectedMacroCount,
      incomingOccupiedSlots: payload.incomingOccupiedSlots,
      overlapSlots: payload.overlapSlots,
      rejectReason: payload.rejectReason,
      source: payload.source,
    });
  });
  bus.on("world:prefab-boundary-snap-committed", (payload) => {
    logger.emit("prefab", "prefab_boundary_snap_committed", {
      prefabId: payload.prefabId,
      instanceId: payload.instanceId,
      hitMacro: formatCoord(payload.hitMacro),
      faceNormal: formatCoord(payload.faceNormal),
      anchorMicroCoord: formatCoord(payload.anchorMicroCoord),
      affectedMacroCount: payload.affectedMacroCount,
      incomingOccupiedSlots: payload.incomingOccupiedSlots,
      overlapSlots: payload.overlapSlots,
      contactSlots: payload.contactSlots,
      source: payload.source,
    });
  });
  bus.on("world:prefab-boundary-snap-rejected", (payload) => {
    logger.emit("prefab", "prefab_boundary_snap_rejected", {
      prefabId: payload.prefabId,
      instanceId: 0,
      hitMacro: formatCoord(payload.hitMacro),
      faceNormal: formatCoord(payload.faceNormal),
      anchorMicroCoord: payload.anchorMicroCoord ? formatCoord(payload.anchorMicroCoord) : "",
      affectedMacroCount: payload.affectedMacroCount,
      incomingOccupiedSlots: payload.incomingOccupiedSlots,
      overlapSlots: payload.overlapSlots,
      contactSlots: payload.contactSlots,
      rejectReason: payload.rejectReason,
      source: payload.source,
    });
  });
  bus.on("world:prefab-boundary-snap-fallback", (payload) => {
    logger.emit("prefab", "prefab_boundary_snap_fallback", {
      prefabId: payload.prefabId,
      hitMacro: formatCoord(payload.hitMacro),
      adjacentMacro: formatCoord(payload.adjacentMacro),
      faceNormal: formatCoord(payload.faceNormal),
      rejectReason: payload.rejectReason,
      source: payload.source,
    });
  });
  bus.on("world:block-broken", ({ coord, source }) => {
    logger.emit("edit", "break", {
      coord: `${coord.x},${coord.y},${coord.z}`,
      source,
    });
  });
  bus.on("world:voxel-temperature-set", ({ coord, targetTemperatureCelsius, source }) => {
    render.showFieldDebugOverlay();
    logger.emit("voxel", "set_temperature", {
      coord: formatCoord(coord),
      target_temperature_celsius: targetTemperatureCelsius,
      source,
      field_overlay_visible: true,
    });
  });
  bus.on(
    "world:voxel-conduction-requested",
    ({ sourceCoord, targetCoord, sourcePotential, source }) => {
      logger.emit("voxel", "conduction_path", {
        source_coord: formatCoord(sourceCoord),
        target_coord: formatCoord(targetCoord),
        source_potential: sourcePotential,
        source,
        request_state: "submitted",
        field_overlay_visible: false,
      });
    },
  );
  bus.on(
    "world:voxel-conduction-accepted",
    ({ sourceCoord, targetCoord, sourcePotential, source, regionId, fieldRegionCreated }) => {
      render.showFieldDebugOverlay();
      logger.emit("voxel", "conduction_path", {
        source_coord: formatCoord(sourceCoord),
        target_coord: formatCoord(targetCoord),
        source_potential: sourcePotential,
        source,
        request_state: "accepted",
        region_id: regionId ?? "",
        field_region_created: fieldRegionCreated ?? false,
        field_overlay_visible: true,
      });
    },
  );
  bus.on("world:chunk-subscribed", ({ requestId, logicalSceneId, centerChunk, radiusLInf }) => {
    logger.emit("voxel", "chunk_subscribed", {
      request_id: requestId,
      logical_scene_id: logicalSceneId,
      center_chunk: formatCoord(centerChunk),
      radius_l_inf: radiusLInf,
    });
  });
  bus.on(
    "world:chunk-snapshot-applied",
    ({ requestId, logicalSceneId, chunkCoord, chunkVersion, chunkHash, solidBlocks }) => {
      logger.emit("voxel", "chunk_snapshot_applied", {
        request_id: requestId,
        logical_scene_id: logicalSceneId,
        chunk_coord: formatCoord(chunkCoord),
        chunk_version: chunkVersion,
        chunk_hash: chunkHash,
        solid_blocks: solidBlocks,
      });
    },
  );
  bus.on("world:voxel-intent-result", (payload) => {
    logger.emit("voxel", "intent_result_applied", {
      request_id: payload.requestId,
      client_intent_seq: payload.clientIntentSeq,
      logical_scene_id: payload.logicalSceneId,
      result_code: payload.resultCodeName,
      result_ref: payload.resultRef,
      reason: payload.reason,
    });
  });
  bus.on("world:voxel-sync-error", ({ reason, source }) => {
    logger.emit("voxel", "sync_error", { reason, source });
  });
  bus.on("world:edit-rejected", ({ reason, source }) => {
    logger.emit("edit", reason, { source });
  });

  bus.on("transport:mode-changed", ({ mode }) => {
    logger.emit("transport", "mode_changed", { mode });
  });
}
