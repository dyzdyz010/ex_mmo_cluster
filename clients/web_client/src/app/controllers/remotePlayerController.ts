import { Vector3 } from "three";
import { INTERPOLATION_DELAY_SECS, RemotePlayerState } from "@domain/movement/remotePlayer";
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
  hasSnapshots: boolean;
  lastSnapshot: RemoteMoveSnapshot | null;
  enteredAtMs: number;
  lastSnapshotAtMs: number | null;
}

export interface RenderedRemoteEntity {
  cid: number;
  position: Vector3;
  movementMode: MovementModeValue;
}

export interface RemoteEntityDebugSnapshot {
  cid: number;
  renderedPosition: string;
  movementMode: MovementModeValue;
  hasSnapshots: boolean;
  enteredAtMs: number;
  lastSnapshotAtMs: number | null;
  latestServerTick: number | null;
  bufferedSnapshots: number;
  interpolationMode: "empty" | "interpolated" | "extrapolated";
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
  private tickDurationSecs = 0.1;
  private serverClockOffsetMs: number | null = null;
  private timeSyncRttMs: number | null = null;

  constructor(private readonly bus: EventBus<AppEvents>) {
    this.bus.on("transport:snapshot-delivered", ({ snapshot }) => {
      const entity = this.ensureEntity(snapshot.cid);
      entity.state.pushSnapshot(snapshot, 0, performance.now() / 1000);
      entity.hasSnapshots = true;
      entity.renderedPosition.copy(snapshot.position);
      entity.movementMode = snapshot.movementMode;
      entity.lastSnapshot = cloneRemoteMoveSnapshot(snapshot);
      entity.lastSnapshotAtMs = performance.now();
      this.primaryCid = snapshot.cid;
      this.bus.emit("movement:remote-snapshot-ingested", {
        cid: snapshot.cid,
        serverTick: snapshot.serverTick,
        position: snapshot.position.clone(),
        movementMode: snapshot.movementMode,
        priorityBand: snapshot.priorityBand,
        priorityScore: snapshot.priorityScore,
        observerDistance: snapshot.observerDistance,
        deliveryInterval: snapshot.deliveryInterval,
      });
    });
    this.bus.on("transport:entity-entered", ({ cid, position }) => {
      const entity = this.ensureEntity(cid);
      entity.renderedPosition.copy(position);
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
      const clientRecvTs = Date.now();
      this.timeSyncRttMs =
        clientRecvTs - sample.clientSendTs - (sample.serverSendTs - sample.serverRecvTs);
      this.serverClockOffsetMs =
        (sample.serverRecvTs - sample.clientSendTs + sample.serverSendTs - clientRecvTs) / 2;
    });
  }

  onFrame(nowMs: number, _dtMs: number): void {
    const nowSecs = nowMs / 1000;
    for (const entity of this.entities.values()) {
      if (!entity.hasSnapshots) {
        continue;
      }
      const sample = entity.state.sampleMotion(nowSecs);
      entity.renderedPosition.copy(sample.position);
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
    }));
  }

  getVisibleEntityIds(): number[] {
    return Array.from(this.entities.keys());
  }

  getDebugSnapshot(): RemoteEntityDebugSnapshot[] {
    return Array.from(this.entities.entries()).map(([cid, entity]) => {
      const debug = entity.state.debugSnapshot();
      return {
        cid,
        renderedPosition: formatVector(entity.renderedPosition),
        movementMode: entity.movementMode,
        hasSnapshots: entity.hasSnapshots,
        enteredAtMs: entity.enteredAtMs,
        lastSnapshotAtMs: entity.lastSnapshotAtMs,
        latestServerTick: debug.latestServerTick,
        bufferedSnapshots: debug.bufferedSnapshots,
        interpolationMode: debug.lastSampleMode,
        priorityBand: entity.lastSnapshot?.priorityBand ?? "unknown",
        priorityScore: entity.lastSnapshot?.priorityScore ?? null,
        observerDistance: entity.lastSnapshot?.observerDistance ?? null,
        deliveryInterval: entity.lastSnapshot?.deliveryInterval ?? null,
      };
    });
  }

  getClockDebugSnapshot(): { serverClockOffsetMs: number | null; timeSyncRttMs: number | null } {
    return {
      serverClockOffsetMs: this.serverClockOffsetMs,
      timeSyncRttMs: this.timeSyncRttMs,
    };
  }

  getCurrentMovementMode(): MovementModeValue {
    return this.primaryEntity()?.movementMode ?? MovementMode.Grounded;
  }

  private ensureEntity(cid: number): RemoteEntityRuntime {
    let entity = this.entities.get(cid);
    if (!entity) {
      entity = {
        state: new RemotePlayerState({ tickDurationSecs: this.tickDurationSecs }),
        renderedPosition: DEFAULT_REMOTE_POSITION.clone(),
        movementMode: MovementMode.Grounded,
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
