import { Vector3 } from "three";
import { CorrectionFlag, cloneRemoteMoveSnapshot, type RemoteMoveSnapshot } from "./types";

const MAX_BUFFERED_SNAPSHOTS = 32;
const DEFAULT_SNAPSHOT_TICK_SECS = 0.1;
// Follow the 150 ms Bernier/Source baseline documented in
// docs/2026-04-20-movement-reference-audit.md. This keeps one full 100 ms
// server sample in reserve without adding the extra 70 ms "slow half-beat"
// introduced by the previous 220 ms delay.
export const INTERPOLATION_DELAY_SECS = 0.15;
// Server AOI Priority throttles low-priority (far) observers to one
// snapshot per 5 server ticks = 500 ms (see
// `apps/scene_server/lib/scene_server/aoi/priority.ex` `delivery_interval/1`).
// The clamp must cover that gap or remote players visibly stutter:
// extrapolation freezes after the clamp window, then snaps when the
// next throttled snapshot arrives. 600 ms = 500 ms throttle + 100 ms
// jitter headroom.
export const MAX_REMOTE_EXTRAPOLATION_SECS = 0.6;
const LOW_PRIORITY_EXTRA_JITTER_SECS = 0.05;

interface BufferedSnapshot {
  snapshot: RemoteMoveSnapshot;
  receivedAtSecs: number;
}

export interface RemoteMotionSample {
  position: Vector3;
  velocity: Vector3;
  mode: "empty" | "interpolated" | "extrapolated";
}

export interface RemoteInterpolationDebug {
  bufferedSnapshots: number;
  latestServerTick: number | null;
  lastSampleMode: "empty" | "interpolated" | "extrapolated";
  interpolationDelaySecs: number;
  maxExtrapolationSecs: number;
}

export class RemotePlayerState {
  private readonly snapshots: BufferedSnapshot[] = [];
  private lastSampleMode: RemoteMotionSample["mode"] = "empty";
  private interpolationDelaySecs = INTERPOLATION_DELAY_SECS;

  constructor(
    private options: { tickDurationSecs: number } = {
      tickDurationSecs: DEFAULT_SNAPSHOT_TICK_SECS,
    },
  ) {}

  setTickDurationSecs(tickDurationSecs: number): void {
    if (Number.isFinite(tickDurationSecs) && tickDurationSecs > 0) {
      this.options = { tickDurationSecs };
    }
  }

  pushSnapshot(
    snapshot: RemoteMoveSnapshot,
    correctionFlags: number,
    receivedAtSecs: number,
  ): void {
    if (
      (correctionFlags & CorrectionFlag.Teleport) !== 0 ||
      (correctionFlags & CorrectionFlag.AntiCheatReject) !== 0
    ) {
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
    this.interpolationDelaySecs = this.resolveInterpolationDelaySecs(snapshot.deliveryInterval);
    if (this.snapshots.length > MAX_BUFFERED_SNAPSHOTS) {
      this.snapshots.splice(0, this.snapshots.length - MAX_BUFFERED_SNAPSHOTS);
    }
  }

  sampleMotion(nowSecs: number): RemoteMotionSample {
    if (this.snapshots.length === 0) {
      this.lastSampleMode = "empty";
      return {
        position: new Vector3(),
        velocity: new Vector3(),
        mode: "empty",
      };
    }

    if (this.snapshots.length === 1) {
      const only = this.snapshots[0];
      if (!only) {
        this.lastSampleMode = "empty";
        return {
          position: new Vector3(),
          velocity: new Vector3(),
          mode: "empty",
        };
      }
      const sample = extrapolateSingle(only, nowSecs);
      this.lastSampleMode = sample.mode;
      return sample;
    }

    const latest = this.snapshots.at(-1);
    if (!latest) {
      this.lastSampleMode = "empty";
      return { position: new Vector3(), velocity: new Vector3(), mode: "empty" };
    }

    const latestServerTime = this.snapshotTimeSecs(latest.snapshot.serverTick);
    const estimatedServerTime =
      latestServerTime +
      Math.min(Math.max(nowSecs - latest.receivedAtSecs, 0), MAX_REMOTE_EXTRAPOLATION_SECS);
    const playbackServerTime = estimatedServerTime - this.interpolationDelaySecs;

    for (let index = 0; index < this.snapshots.length - 1; index += 1) {
      const previous = this.snapshots[index];
      const next = this.snapshots[index + 1];
      if (!previous || !next) {
        continue;
      }
      const previousTime = this.snapshotTimeSecs(previous.snapshot.serverTick);
      const nextTime = this.snapshotTimeSecs(next.snapshot.serverTick);
      if (playbackServerTime >= previousTime && playbackServerTime <= nextTime) {
        const sample = interpolatePair(
          previous,
          next,
          playbackServerTime,
          this.options.tickDurationSecs,
        );
        this.lastSampleMode = sample.mode;
        return sample;
      }
    }

    const sample = extrapolateSingle(latest, nowSecs);
    this.lastSampleMode = sample.mode;
    return sample;
  }

  debugSnapshot(): RemoteInterpolationDebug {
    return {
      bufferedSnapshots: this.snapshots.length,
      latestServerTick: this.snapshots.at(-1)?.snapshot.serverTick ?? null,
      lastSampleMode: this.lastSampleMode,
      interpolationDelaySecs: this.interpolationDelaySecs,
      maxExtrapolationSecs: MAX_REMOTE_EXTRAPOLATION_SECS,
    };
  }

  private snapshotTimeSecs(serverTick: number): number {
    return serverTick * this.options.tickDurationSecs;
  }

  private resolveInterpolationDelaySecs(deliveryInterval: number | undefined): number {
    if (
      !Number.isFinite(deliveryInterval) ||
      deliveryInterval === undefined ||
      deliveryInterval <= 1
    ) {
      return INTERPOLATION_DELAY_SECS;
    }

    const intervalDelay =
      INTERPOLATION_DELAY_SECS + (deliveryInterval - 1) * this.options.tickDurationSecs;
    const jitter = deliveryInterval >= 5 ? LOW_PRIORITY_EXTRA_JITTER_SECS : 0;
    return Math.min(MAX_REMOTE_EXTRAPOLATION_SECS, intervalDelay + jitter);
  }
}

function interpolatePair(
  previous: BufferedSnapshot,
  next: BufferedSnapshot,
  playbackServerTime: number,
  tickDurationSecs: number,
): RemoteMotionSample {
  const previousTime = previous.snapshot.serverTick * tickDurationSecs;
  const nextTime = next.snapshot.serverTick * tickDurationSecs;
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
  return { position, velocity, mode: "interpolated" };
}

function extrapolateSingle(entry: BufferedSnapshot, nowSecs: number): RemoteMotionSample {
  const dt = Math.min(Math.max(nowSecs - entry.receivedAtSecs, 0), MAX_REMOTE_EXTRAPOLATION_SECS);
  return {
    position: entry.snapshot.position
      .clone()
      .add(entry.snapshot.velocity.clone().multiplyScalar(dt))
      .add(entry.snapshot.acceleration.clone().multiplyScalar(0.5 * dt * dt)),
    velocity: entry.snapshot.velocity
      .clone()
      .add(entry.snapshot.acceleration.clone().multiplyScalar(dt)),
    mode: "extrapolated",
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
  const h00 = 2 * t3 - 3 * t2 + 1;
  const h10 = t3 - 2 * t2 + t;
  const h01 = -2 * t3 + 3 * t2;
  const h11 = t3 - t2;

  return new Vector3()
    .add(p0.clone().multiplyScalar(h00))
    .add(v0.clone().multiplyScalar(h10 * durationSecs))
    .add(p1.clone().multiplyScalar(h01))
    .add(v1.clone().multiplyScalar(h11 * durationSecs));
}
