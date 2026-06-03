import { Vector3 } from "three";
import { INTERPOLATION_DELAY_SECS, RemotePlayerState } from "@domain/movement/remotePlayer";
import { ServerClockEstimator, type ServerClockDebugSnapshot } from "@domain/movement/serverClock";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";
import {
  cloneRemoteMoveSnapshot,
  MovementMode,
  type MovementMode as MovementModeValue,
  type RemoteMoveSnapshot,
} from "@domain/movement/types";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FrameSubscriber } from "../gameLoop";

const DEFAULT_REMOTE_POSITION = new Vector3(400, 650, 320);

interface RemoteEntityRuntime {
  state: RemotePlayerState;
  renderedPosition: Vector3;
  movementMode: MovementModeValue;
  movementGroundY: number | null;
  hasSnapshots: boolean;
  lastSnapshot: RemoteMoveSnapshot | null;
  enteredAtMs: number;
  lastSnapshotAtMs: number | null;
}

export interface RenderedRemoteEntity {
  cid: number;
  position: Vector3;
  movementMode: MovementModeValue;
  movementGroundY: number | null;
}

export interface RemoteEntityDebugSnapshot {
  cid: number;
  renderedPosition: string;
  movementMode: MovementModeValue;
  movementGroundY: number | null;
  hasSnapshots: boolean;
  enteredAtMs: number;
  lastSnapshotAtMs: number | null;
  latestServerTick: number | null;
  latestServerStateMs: number | null;
  latestServerSendMs: number | null;
  bufferedSnapshots: number;
  interpolationMode: "empty" | "interpolated" | "extrapolated";
  interpolationDelaySecs: number;
  interpolationTimeAxis: "server_tick" | "server_state_ms";
  serverStateTimelineHealthy: boolean;
  serverSendTimelineHealthy: boolean;
  playbackServerTimeMs: number | null;
  serverClockOffsetMs: number | null;
  rawServerClockOffsetMs: number | null;
  timeSyncRttMs: number | null;
  timeSyncSmoothedRttMs: number | null;
  timeSyncOffsetJitterMs: number;
  timeSyncOffsetJumpCount: number;
  timeSyncRejectedOffsetSampleCount: number;
  timeSyncSampleCount: number;
  serverTickDiscontinuityCount: number;
  playbackTimeRegressionCount: number;
  priorityBand: string;
  priorityScore: number | null;
  observerDistance: number | null;
  deliveryInterval: number | null;
}

/**
 * Owns remote-entity interpolation buffers. Each AOI-visible CID gets an
 * independent snapshot timeline so one actor's packets cannot overwrite
 * another actor's render state.
 */
export class RemotePlayerController implements FrameSubscriber {
  static readonly interpolationDelaySecs = INTERPOLATION_DELAY_SECS;

  private readonly entities = new Map<number, RemoteEntityRuntime>();
  private readonly renderedPosition = DEFAULT_REMOTE_POSITION.clone();
  private primaryCid: number | null = null;
  private tickDurationSecs = DEFAULT_MOVEMENT_PROFILE.fixedDtMs / 1000;
  private readonly serverClock = new ServerClockEstimator();

  constructor(private readonly bus: EventBus<AppEvents>) {
    this.bus.on("transport:snapshot-delivered", ({ snapshot }) => {
      const entity = this.ensureEntity(snapshot.cid);
      const isFirstSnapshot = !entity.hasSnapshots;
      entity.state.pushSnapshot(snapshot, 0, performance.now() / 1000);
      entity.hasSnapshots = true;
      entity.movementMode = snapshot.movementMode;
      if (snapshot.movementMode === MovementMode.Grounded) {
        entity.movementGroundY = snapshot.position.y;
      }
      if (isFirstSnapshot) {
        entity.renderedPosition.copy(snapshot.position);
      }
      entity.lastSnapshot = cloneRemoteMoveSnapshot(snapshot);
      entity.lastSnapshotAtMs = performance.now();
      this.primaryCid = snapshot.cid;
      this.bus.emit("movement:remote-snapshot-ingested", {
        cid: snapshot.cid,
        serverTick: snapshot.serverTick,
        position: snapshot.position.clone(),
        movementMode: snapshot.movementMode,
        ...(snapshot.priorityBand !== undefined ? { priorityBand: snapshot.priorityBand } : {}),
        ...(snapshot.priorityScore !== undefined ? { priorityScore: snapshot.priorityScore } : {}),
        ...(snapshot.observerDistance !== undefined
          ? { observerDistance: snapshot.observerDistance }
          : {}),
        ...(snapshot.deliveryInterval !== undefined
          ? { deliveryInterval: snapshot.deliveryInterval }
          : {}),
      });
    });
    this.bus.on("transport:entity-entered", ({ cid, position }) => {
      const entity = this.ensureEntity(cid);
      entity.renderedPosition.copy(position);
      entity.movementGroundY = position.y;
      this.primaryCid ??= cid;
    });
    this.bus.on("transport:entity-left", ({ cid }) => {
      this.entities.delete(cid);
      if (this.primaryCid === cid) {
        this.primaryCid = this.entities.keys().next().value ?? null;
      }
    });
    this.bus.on("transport:ack-delivered", ({ ack }) => {
      const tickDurationSecs = ack.serverFixedDtMs / 1000;
      if (!Number.isFinite(tickDurationSecs) || tickDurationSecs <= 0) {
        return;
      }
      this.tickDurationSecs = tickDurationSecs;
      for (const entity of this.entities.values()) {
        entity.state.setTickDurationSecs(tickDurationSecs);
      }
    });
    this.bus.on("transport:spawn", () => {
      this.renderedPosition.copy(DEFAULT_REMOTE_POSITION);
      this.entities.clear();
      this.primaryCid = null;
    });
    this.bus.on("transport:time-sync", (sample) => {
      this.serverClock.observe(sample);
    });
  }

  onFrame(nowMs: number, _dtMs: number): void {
    const nowSecs = nowMs / 1000;
    const clock = this.serverClock.sampleClock(Date.now());
    for (const entity of this.entities.values()) {
      if (!entity.hasSnapshots) {
        continue;
      }
      const sample = entity.state.sampleMotion(nowSecs, clock);
      const rendered = clampRemoteMotionToKnownGround(entity, sample);
      entity.renderedPosition.copy(rendered.position);
      entity.movementMode = rendered.movementMode;
    }
    const primary = this.primaryEntity();
    this.renderedPosition.copy(primary?.renderedPosition ?? DEFAULT_REMOTE_POSITION);
  }

  getRenderedPosition(): Vector3 {
    return this.renderedPosition.clone();
  }

  getRenderedPositionFor(cid: number): Vector3 {
    return this.entities.get(cid)?.renderedPosition.clone() ?? DEFAULT_REMOTE_POSITION.clone();
  }

  getRenderedEntities(): RenderedRemoteEntity[] {
    return Array.from(this.entities.entries()).map(([cid, entity]) => ({
      cid,
      position: entity.renderedPosition.clone(),
      movementMode: entity.movementMode,
      movementGroundY: entity.movementGroundY,
    }));
  }

  getVisibleEntityIds(): number[] {
    return Array.from(this.entities.keys());
  }

  getDebugSnapshot(): RemoteEntityDebugSnapshot[] {
    const clock = this.serverClock.debugSnapshot();
    return Array.from(this.entities.entries()).map(([cid, entity]) => {
      const debug = entity.state.debugSnapshot();
      return {
        cid,
        renderedPosition: formatVector(entity.renderedPosition),
        movementMode: entity.movementMode,
        movementGroundY: entity.movementGroundY,
        hasSnapshots: entity.hasSnapshots,
        enteredAtMs: entity.enteredAtMs,
        lastSnapshotAtMs: entity.lastSnapshotAtMs,
        latestServerTick: debug.latestServerTick,
        latestServerStateMs: debug.latestServerStateMs,
        latestServerSendMs: debug.latestServerSendMs,
        bufferedSnapshots: debug.bufferedSnapshots,
        interpolationMode: debug.lastSampleMode,
        interpolationDelaySecs: debug.interpolationDelaySecs,
        interpolationTimeAxis: debug.timeAxisMode,
        serverStateTimelineHealthy: debug.serverStateTimelineHealthy,
        serverSendTimelineHealthy: debug.serverSendTimelineHealthy,
        playbackServerTimeMs: debug.lastPlaybackServerTimeMs,
        serverClockOffsetMs: clock.serverClockOffsetMs,
        rawServerClockOffsetMs: clock.rawServerClockOffsetMs,
        timeSyncRttMs: clock.timeSyncRttMs,
        timeSyncSmoothedRttMs: clock.timeSyncSmoothedRttMs,
        timeSyncOffsetJitterMs: clock.timeSyncOffsetJitterMs,
        timeSyncOffsetJumpCount: clock.timeSyncOffsetJumpCount,
        timeSyncRejectedOffsetSampleCount: clock.timeSyncRejectedOffsetSampleCount,
        timeSyncSampleCount: clock.timeSyncSampleCount,
        serverTickDiscontinuityCount: debug.serverTickDiscontinuityCount,
        playbackTimeRegressionCount: debug.playbackTimeRegressionCount,
        priorityBand: entity.lastSnapshot?.priorityBand ?? "unknown",
        priorityScore: entity.lastSnapshot?.priorityScore ?? null,
        observerDistance: entity.lastSnapshot?.observerDistance ?? null,
        deliveryInterval: entity.lastSnapshot?.deliveryInterval ?? null,
      };
    });
  }

  getClockDebugSnapshot(): ServerClockDebugSnapshot {
    return this.serverClock.debugSnapshot();
  }

  getCurrentMovementMode(): MovementModeValue {
    return this.primaryEntity()?.movementMode ?? MovementMode.Grounded;
  }

  getRenderedGroundY(): number | null {
    return this.primaryEntity()?.movementGroundY ?? null;
  }

  private ensureEntity(cid: number): RemoteEntityRuntime {
    let entity = this.entities.get(cid);
    if (!entity) {
      entity = {
        state: new RemotePlayerState({ tickDurationSecs: this.tickDurationSecs }),
        renderedPosition: DEFAULT_REMOTE_POSITION.clone(),
        movementMode: MovementMode.Grounded,
        movementGroundY: null,
        hasSnapshots: false,
        lastSnapshot: null,
        enteredAtMs: performance.now(),
        lastSnapshotAtMs: null,
      };
      this.entities.set(cid, entity);
    }
    return entity;
  }

  private primaryEntity(): RemoteEntityRuntime | null {
    return this.primaryCid === null ? null : (this.entities.get(this.primaryCid) ?? null);
  }
}

function formatVector(vector: Vector3): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}

function clampRemoteMotionToKnownGround(
  entity: RemoteEntityRuntime,
  sample: { position: Vector3; velocity: Vector3 },
): { position: Vector3; movementMode: MovementModeValue } {
  const position = sample.position.clone();
  const snapshotMode = entity.lastSnapshot?.movementMode ?? entity.movementMode;
  const groundY = entity.movementGroundY;
  if (
    groundY !== null &&
    snapshotMode === MovementMode.Airborne &&
    position.y <= groundY &&
    sample.velocity.y <= 0
  ) {
    position.y = groundY;
    return { position, movementMode: MovementMode.Grounded };
  }
  return { position, movementMode: snapshotMode };
}
