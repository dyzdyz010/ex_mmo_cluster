import { Vector3 } from "three";
import { CorrectionFlag, cloneRemoteMoveSnapshot, type RemoteMoveSnapshot } from "./types";

const MAX_BUFFERED_SNAPSHOTS = 32;
const SNAPSHOT_TICK_SECS = 0.1;
export const INTERPOLATION_DELAY_SECS = 0.22;
export const MAX_REMOTE_EXTRAPOLATION_SECS = 0.25;

interface BufferedSnapshot {
  snapshot: RemoteMoveSnapshot;
  receivedAtSecs: number;
}

export interface RemoteMotionSample {
  position: Vector3;
  velocity: Vector3;
}

export class RemotePlayerState {
  private readonly snapshots: BufferedSnapshot[] = [];

  pushSnapshot(snapshot: RemoteMoveSnapshot, correctionFlags: number, receivedAtSecs: number): void {
    if ((correctionFlags & CorrectionFlag.Teleport) !== 0 || (correctionFlags & CorrectionFlag.AntiCheatReject) !== 0) {
      this.snapshots.splice(0, this.snapshots.length);
    }

    const latestTick = this.snapshots.at(-1)?.snapshot.serverTick ?? -1;
    if (snapshot.serverTick <= latestTick) {
      return;
    }

    this.snapshots.push({
      snapshot: cloneRemoteMoveSnapshot(snapshot),
      receivedAtSecs,
    });
    if (this.snapshots.length > MAX_BUFFERED_SNAPSHOTS) {
      this.snapshots.splice(0, this.snapshots.length - MAX_BUFFERED_SNAPSHOTS);
    }
  }

  sampleMotion(nowSecs: number): RemoteMotionSample {
    if (this.snapshots.length === 0) {
      return {
        position: new Vector3(),
        velocity: new Vector3(),
      };
    }

    if (this.snapshots.length === 1) {
      const only = this.snapshots[0];
      if (!only) {
        return {
          position: new Vector3(),
          velocity: new Vector3(),
        };
      }
      return extrapolateSingle(only, nowSecs);
    }

    const latest = this.snapshots.at(-1);
    if (!latest) {
      return { position: new Vector3(), velocity: new Vector3() };
    }

    const latestServerTime = snapshotTimeSecs(latest.snapshot.serverTick);
    const estimatedServerTime =
      latestServerTime + Math.min(Math.max(nowSecs - latest.receivedAtSecs, 0), MAX_REMOTE_EXTRAPOLATION_SECS);
    const playbackServerTime = estimatedServerTime - INTERPOLATION_DELAY_SECS;

    for (let index = 0; index < this.snapshots.length - 1; index += 1) {
      const previous = this.snapshots[index];
      const next = this.snapshots[index + 1];
      if (!previous || !next) {
        continue;
      }
      const previousTime = snapshotTimeSecs(previous.snapshot.serverTick);
      const nextTime = snapshotTimeSecs(next.snapshot.serverTick);
      if (playbackServerTime >= previousTime && playbackServerTime <= nextTime) {
        return interpolatePair(previous, next, playbackServerTime);
      }
    }

    return extrapolateSingle(latest, nowSecs);
  }
}

function snapshotTimeSecs(serverTick: number): number {
  return serverTick * SNAPSHOT_TICK_SECS;
}

function interpolatePair(previous: BufferedSnapshot, next: BufferedSnapshot, playbackServerTime: number): RemoteMotionSample {
  const previousTime = snapshotTimeSecs(previous.snapshot.serverTick);
  const nextTime = snapshotTimeSecs(next.snapshot.serverTick);
  const duration = Math.max(nextTime - previousTime, 1e-6);
  const t = Math.min(1, Math.max(0, (playbackServerTime - previousTime) / duration));

  const position = hermitePosition(
    previous.snapshot.position,
    previous.snapshot.velocity,
    next.snapshot.position,
    next.snapshot.velocity,
    duration,
    t,
  );
  const velocity = previous.snapshot.velocity.clone().lerp(next.snapshot.velocity, t);
  return { position, velocity };
}

function extrapolateSingle(entry: BufferedSnapshot, nowSecs: number): RemoteMotionSample {
  const dt = Math.min(Math.max(nowSecs - entry.receivedAtSecs, 0), MAX_REMOTE_EXTRAPOLATION_SECS);
  return {
    position: entry.snapshot.position
      .clone()
      .add(entry.snapshot.velocity.clone().multiplyScalar(dt))
      .add(entry.snapshot.acceleration.clone().multiplyScalar(0.5 * dt * dt)),
    velocity: entry.snapshot.velocity.clone().add(entry.snapshot.acceleration.clone().multiplyScalar(dt)),
  };
}

function hermitePosition(
  p0: Vector3,
  v0: Vector3,
  p1: Vector3,
  v1: Vector3,
  durationSecs: number,
  t: number,
): Vector3 {
  const t2 = t * t;
  const t3 = t2 * t;
  const h00 = (2 * t3) - (3 * t2) + 1;
  const h10 = t3 - (2 * t2) + t;
  const h01 = (-2 * t3) + (3 * t2);
  const h11 = t3 - t2;

  return new Vector3()
    .add(p0.clone().multiplyScalar(h00))
    .add(v0.clone().multiplyScalar(h10 * durationSecs))
    .add(p1.clone().multiplyScalar(h01))
    .add(v1.clone().multiplyScalar(h11 * durationSecs));
}
