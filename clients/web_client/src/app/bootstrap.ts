import type { Vector3 } from "three";
import { ObserveLog } from "../observe/logger";
import {
  SimulatedLocalMovementTransport,
  type MovementTransport,
} from "../net/movementTransport";
import { ServerMovementTransport } from "../net/serverMovementTransport";
import { LocalVoxelWorldAdapter, type VoxelWorldAdapter } from "../voxel/worldAdapter";
import { HudView } from "../presentation/hud/hudView";
import { DevToolsCli } from "../presentation/devtools/devToolsCli";
import { EventBus } from "../shared/events/eventBus";
import type { AppEvents } from "../shared/events/events";
import { DiagnosticsController } from "./controllers/diagnosticsController";
import { InputController } from "./controllers/inputController";
import { LocalPlayerController } from "./controllers/localPlayerController";
import { RemotePlayerController } from "./controllers/remotePlayerController";
import { RenderOrchestrator } from "./controllers/renderOrchestrator";
import { TransportPump } from "./controllers/transportPump";
import { WorldEditController } from "./controllers/worldEditController";
import { GameLoop } from "./gameLoop";

export interface AppContext {
  readonly eventBus: EventBus<AppEvents>;
  dispose(): void;
}

export interface BootstrapTargets {
  canvas: HTMLCanvasElement;
  hud: HTMLDivElement;
}

/**
 * Composition root. Constructs every long-lived service, wires them together
 * in explicit dependency order, installs subscribers, and starts the loop.
 *
 * This is the only file allowed to `new` a controller or transport. Everything
 * else takes its dependencies through constructors.
 */
export function bootstrap({ canvas, hud }: BootstrapTargets): AppContext {
  const logger = new ObserveLog(1200);
  const eventBus = new EventBus<AppEvents>();
  const world: VoxelWorldAdapter = new LocalVoxelWorldAdapter();
  world.bootstrap();

  const transport = createMovementTransport(logger);
  const transportPump = new TransportPump(transport, eventBus);

  const input = new InputController(eventBus);
  const detachInput = input.attach(window);

  const localPlayer = new LocalPlayerController(eventBus, input, transportPump);
  const remotePlayer = new RemotePlayerController(eventBus);

  const render = new RenderOrchestrator(canvas, world, localPlayer, remotePlayer, logger);
  const edit = new WorldEditController(eventBus, world, render);

  const hudView = new HudView(hud, world, transportPump, localPlayer, remotePlayer, edit, render);
  const diagnostics = new DiagnosticsController(
    logger,
    world,
    localPlayer,
    remotePlayer,
    edit,
  );

  const loop = new GameLoop();
  loop.subscribe(transportPump);
  loop.subscribe(localPlayer);
  loop.subscribe(remotePlayer);
  loop.subscribe(render);
  loop.subscribe(hudView);
  loop.subscribe(diagnostics);

  bridgeBusToLogger(eventBus, logger);

  const devTools = new DevToolsCli({
    logger,
    world,
    transport: transportPump,
    localPlayer,
    remotePlayer,
    edit,
    render,
  });
  devTools.install(window);

  logger.emit("boot", "runtime_started", {
    chunks: world.store.listChunks().length,
    solid_blocks: world.store.totalSolidBlocks(),
    selected_material: edit.getSelectedMaterialId(),
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
    detachInput();
    render.dispose();
    eventBus.clear();
  }

  return { eventBus, dispose };
}

function createMovementTransport(logger: ObserveLog): MovementTransport {
  if (import.meta.env.VITE_MOVEMENT_TRANSPORT === "simulated") {
    return new SimulatedLocalMovementTransport();
  }
  return new ServerMovementTransport(logger);
}

/**
 * The old monolithic runtime logged directly from every code path it touched.
 * That coupling is replaced by a single bridge that translates bus events
 * into ObserveLog entries, so controllers no longer depend on the logger.
 */
function bridgeBusToLogger(bus: EventBus<AppEvents>, logger: ObserveLog): void {
  bus.on("movement:reset", ({ start }) => {
    logger.emit("movement", "demo_reset", { start: formatVector(start) });
  });
  bus.on("movement:local-step", ({ seq, clientTick, position }) => {
    logger.emit("movement", "input_frame", {
      seq,
      tick: clientTick,
      predicted: formatVector(position),
    });
  });
  bus.on("movement:authority-applied", (payload) => {
    logger.emit("movement", "ack", {
      seq: payload.ackSeq,
      tick: payload.authTick,
      action: payload.action,
      correction_distance: payload.correctionDistance.toFixed(2),
      pending_inputs: payload.pendingInputs,
      replayed_frames: payload.replayedFrames,
      rtt_ms: payload.rttMs.toFixed(1),
    });
  });
  bus.on("movement:remote-snapshot-ingested", ({ cid, serverTick, position }) => {
    logger.emit("movement", "remote_snapshot", {
      cid,
      tick: serverTick,
      position: formatVector(position),
    });
  });

  bus.on("input:material-selected", ({ materialId, source }) => {
    logger.emit("edit", "select_material", { material: materialId, source });
  });
  bus.on("world:block-placed", ({ coord, materialId, source }) => {
    logger.emit("edit", "place", {
      coord: `${coord.x},${coord.y},${coord.z}`,
      material: materialId,
      source,
    });
  });
  bus.on("world:block-broken", ({ coord, source }) => {
    logger.emit("edit", "break", {
      coord: `${coord.x},${coord.y},${coord.z}`,
      source,
    });
  });
  bus.on("world:edit-rejected", ({ reason, source }) => {
    logger.emit("edit", reason, { source });
  });

  bus.on("transport:mode-changed", ({ mode }) => {
    logger.emit("transport", "mode_changed", { mode });
  });
}

function formatVector(vector: Vector3): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}
