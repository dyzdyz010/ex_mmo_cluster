import { Vector3 } from "three";
import { DEFAULT_MOVEMENT_PROFILE } from "./profile";
import { CorrectionFlag, cloneRemoteMoveSnapshot, type RemoteMoveSnapshot } from "./types";

const MAX_BUFFERED_SNAPSHOTS = 32;
const DEFAULT_SNAPSHOT_TICK_SECS = DEFAULT_MOVEMENT_PROFILE.fixedDtMs / 1000;
// Follow the 150 ms Bernier/Source baseline documented in
// docs/2026-04-20-movement-reference-audit.md. Local authority markers do not
// use this delayed remote-player buffer.
export const INTERPOLATION_DELAY_SECS = 0.15;
// Server AOI Priority throttles low-priority (far) observers to one
// snapshot per 5 server ticks (see
// `apps/scene_server/lib/scene_server/aoi/priority.ex` `delivery_interval/1`).
// The clamp must cover that gap or remote players visibly stutter:
// extrapolation freezes after the clamp window, then snaps when the
// next throttled snapshot arrives. At the current 16 ms fixed tick, the low
// priority gap is about 80 ms, so a 250 ms cap leaves headroom without adding
// another half-second of stale remote motion.
export const MAX_REMOTE_EXTRAPOLATION_SECS = 0.25;
const LOW_PRIORITY_EXTRA_JITTER_SECS = 0.05;
const MIN_SERVER_SEND_TICK_RATIO = 0.5;
const MAX_SERVER_SEND_TICK_RATIO = 2.5;

interface BufferedSnapshot {
  snapshot: RemoteMoveSnapshot;
  receivedAtSecs: number;
}

interface RemotePlayerStateOptions {
  tickDurationSecs?: number;
  interpolationDelaySecs?: number;
}

export interface RemoteSampleClock {
  localWallClockMs?: number;
  serverClockOffsetMs?: number | null;
}

export interface RemoteMotionSample {
  position: Vector3;
  velocity: Vector3;
  mode: "empty" | "interpolated" | "extrapolated";
}

export interface RemoteInterpolationDebug {
  bufferedSnapshots: number;
  latestServerTick: number | null;
  latestServerStateMs: number | null;
  latestServerSendMs: number | null;
  lastSampleMode: "empty" | "interpolated" | "extrapolated";
  interpolationDelaySecs: number;
  maxExtrapolationSecs: number;
  timeAxisMode: "server_tick" | "server_state_ms";
  serverStateTimelineHealthy: boolean;
  serverSendTimelineHealthy: boolean;
  lastPlaybackServerTimeMs: number | null;
  serverTickDiscontinuityCount: number;
  playbackTimeRegressionCount: number;
}

export class RemotePlayerState {
  private readonly snapshots: BufferedSnapshot[] = [];
  private lastSampleMode: RemoteMotionSample["mode"] = "empty";
  private interpolationDelaySecs = INTERPOLATION_DELAY_SECS;
  private tickDurationSecs = DEFAULT_SNAPSHOT_TICK_SECS;
  private baseInterpolationDelaySecs = INTERPOLATION_DELAY_SECS;
  private timeAxisMode: RemoteInterpolationDebug["timeAxisMode"] = "server_tick";
  private lastPlaybackServerTimeMs: number | null = null;
  private lastPlaybackTimeAxisMode: RemoteInterpolationDebug["timeAxisMode"] | null = null;
  private serverStateTimelineHealthy = true;
  private serverTickDiscontinuityCount = 0;
  private playbackTimeRegressionCount = 0;

  constructor(options: RemotePlayerStateOptions = {}) {
    if (Number.isFinite(options.tickDurationSecs) && Number(options.tickDurationSecs) > 0) {
      this.tickDurationSecs = Number(options.tickDurationSecs);
    }
    if (
      Number.isFinite(options.interpolationDelaySecs) &&
      Number(options.interpolationDelaySecs) >= 0
    ) {
      this.baseInterpolationDelaySecs = Math.min(
        Number(options.interpolationDelaySecs),
        MAX_REMOTE_EXTRAPOLATION_SECS,
      );
      this.interpolationDelaySecs = this.baseInterpolationDelaySecs;
    }
  }

  setTickDurationSecs(tickDurationSecs: number): void {
    if (Number.isFinite(tickDurationSecs) && tickDurationSecs > 0) {
      this.tickDurationSecs = tickDurationSecs;
      this.serverStateTimelineHealthy = this.computeServerStateTimelineHealthy();
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

    const latest = this.snapshots.at(-1)?.snapshot;
    const latestTick = latest?.serverTick ?? -1;
    if (snapshot.serverTick <= latestTick) {
      return;
    }
    if (latest) {
      const expectedDelta = Math.max(
        1,
        Math.trunc(latest.deliveryInterval ?? snapshot.deliveryInterval ?? 1),
      );
      if (snapshot.serverTick !== latest.serverTick + expectedDelta) {
        this.serverTickDiscontinuityCount += 1;
      }
    }

    this.snapshots.push({
      snapshot: cloneRemoteMoveSnapshot(snapshot),
      receivedAtSecs,
    });
    this.interpolationDelaySecs = this.resolveInterpolationDelaySecs(snapshot.deliveryInterval);
    if (this.snapshots.length > MAX_BUFFERED_SNAPSHOTS) {
      this.snapshots.splice(0, this.snapshots.length - MAX_BUFFERED_SNAPSHOTS);
    }
    this.serverStateTimelineHealthy = this.computeServerStateTimelineHealthy();
  }

  sampleMotion(nowSecs: number, clock: RemoteSampleClock = {}): RemoteMotionSample {
    if (this.snapshots.length === 0) {
      this.lastSampleMode = "empty";
      this.timeAxisMode = "server_tick";
      this.lastPlaybackServerTimeMs = null;
      this.lastPlaybackTimeAxisMode = null;
      return {
        position: new Vector3(),
        velocity: new Vector3(),
        mode: "empty",
      };
    }

    const timeline = this.resolveTimeline(nowSecs, clock);

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
      const sample = extrapolateSingle(only, nowSecs, extrapolationPlaybackTime(timeline));
      this.lastSampleMode = sample.mode;
      return sample;
    }

    const latest = this.snapshots.at(-1);
    if (!latest) {
      this.lastSampleMode = "empty";
      return { position: new Vector3(), velocity: new Vector3(), mode: "empty" };
    }

    const first = this.snapshots[0];
    if (first) {
      const firstTime = this.snapshotTimeSecs(first.snapshot, timeline.mode);
      if (timeline.playbackServerTime <= firstTime) {
        const sample = holdSnapshot(first);
        this.lastSampleMode = sample.mode;
        return sample;
      }
    }

    for (let index = 0; index < this.snapshots.length - 1; index += 1) {
      const previous = this.snapshots[index];
      const next = this.snapshots[index + 1];
      if (!previous || !next) {
        continue;
      }
      const previousTime = this.snapshotTimeSecs(previous.snapshot, timeline.mode);
      const nextTime = this.snapshotTimeSecs(next.snapshot, timeline.mode);
      if (timeline.playbackServerTime >= previousTime && timeline.playbackServerTime <= nextTime) {
        const sample = interpolatePair(
          previous,
          next,
          timeline.playbackServerTime,
          previousTime,
          nextTime,
        );
        this.lastSampleMode = sample.mode;
        return sample;
      }
    }

    const sample = extrapolateSingle(latest, nowSecs, extrapolationPlaybackTime(timeline));
    this.lastSampleMode = sample.mode;
    return sample;
  }

  debugSnapshot(): RemoteInterpolationDebug {
    const latest = this.snapshots.at(-1)?.snapshot;
    return {
      bufferedSnapshots: this.snapshots.length,
      latestServerTick: latest?.serverTick ?? null,
      latestServerStateMs: latest?.serverStateMs ?? null,
      latestServerSendMs: latest?.serverSendMs ?? null,
      lastSampleMode: this.lastSampleMode,
      interpolationDelaySecs: this.interpolationDelaySecs,
      maxExtrapolationSecs: MAX_REMOTE_EXTRAPOLATION_SECS,
      timeAxisMode: this.timeAxisMode,
      serverStateTimelineHealthy: this.serverStateTimelineHealthy,
      serverSendTimelineHealthy: this.serverStateTimelineHealthy,
      lastPlaybackServerTimeMs: this.lastPlaybackServerTimeMs,
      serverTickDiscontinuityCount: this.serverTickDiscontinuityCount,
      playbackTimeRegressionCount: this.playbackTimeRegressionCount,
    };
  }

  private snapshotTimeSecs(
    snapshot: RemoteMoveSnapshot,
    mode: RemoteInterpolationDebug["timeAxisMode"],
  ): number {
    if (mode === "server_state_ms") {
      return snapshot.serverStateMs / 1000;
    }
    return snapshot.serverTick * this.tickDurationSecs;
  }

  private resolveInterpolationDelaySecs(deliveryInterval: number | undefined): number {
    if (
      !Number.isFinite(deliveryInterval) ||
      deliveryInterval === undefined ||
      deliveryInterval <= 1
    ) {
      return this.baseInterpolationDelaySecs;
    }

    const intervalDelay =
      this.baseInterpolationDelaySecs + (deliveryInterval - 1) * this.tickDurationSecs;
    const jitter = deliveryInterval >= 5 ? LOW_PRIORITY_EXTRA_JITTER_SECS : 0;
    return Math.min(MAX_REMOTE_EXTRAPOLATION_SECS, intervalDelay + jitter);
  }

  private computeServerStateTimelineHealthy(): boolean {
    for (let index = 1; index < this.snapshots.length; index += 1) {
      const previous = this.snapshots[index - 1]?.snapshot;
      const next = this.snapshots[index]?.snapshot;
      if (!previous || !next) {
        continue;
      }

      const tickDeltaSecs = (next.serverTick - previous.serverTick) * this.tickDurationSecs;
      const stateDeltaSecs = (next.serverStateMs - previous.serverStateMs) / 1000;
      if (!Number.isFinite(tickDeltaSecs) || !Number.isFinite(stateDeltaSecs)) {
        return false;
      }
      if (tickDeltaSecs <= 0 || stateDeltaSecs <= 0) {
        return false;
      }

      const ratio = stateDeltaSecs / tickDeltaSecs;
      if (ratio < MIN_SERVER_SEND_TICK_RATIO || ratio > MAX_SERVER_SEND_TICK_RATIO) {
        return false;
      }
    }

    return true;
  }

  private resolveTimeline(
    nowSecs: number,
    clock: RemoteSampleClock,
  ): {
    mode: RemoteInterpolationDebug["timeAxisMode"];
    playbackServerTime: number;
  } {
    const canUseServerStateMs =
      Number.isFinite(clock.localWallClockMs) &&
      Number.isFinite(clock.serverClockOffsetMs) &&
      this.serverStateTimelineHealthy &&
      this.snapshots.every(
        (entry) =>
          Number.isFinite(entry.snapshot.serverStateMs) && entry.snapshot.serverStateMs > 0,
      );

    if (canUseServerStateMs) {
      const serverNowSecs =
        ((clock.localWallClockMs as number) + (clock.serverClockOffsetMs as number)) / 1000;
      const playbackServerTime = this.monotonicPlaybackServerTime(
        "server_state_ms",
        serverNowSecs - this.interpolationDelaySecs,
      );
      this.timeAxisMode = "server_state_ms";
      return { mode: "server_state_ms", playbackServerTime };
    }

    const latest = this.snapshots.at(-1);
    const latestServerTime =
      latest === undefined ? 0 : this.snapshotTimeSecs(latest.snapshot, "server_tick");
    const estimatedServerTime =
      latest === undefined
        ? 0
        : latestServerTime +
          Math.min(Math.max(nowSecs - latest.receivedAtSecs, 0), MAX_REMOTE_EXTRAPOLATION_SECS);
    const playbackServerTime = estimatedServerTime - this.interpolationDelaySecs;
    this.timeAxisMode = "server_tick";
    return {
      mode: "server_tick",
      playbackServerTime: this.monotonicPlaybackServerTime("server_tick", playbackServerTime),
    };
  }

  private monotonicPlaybackServerTime(
    mode: RemoteInterpolationDebug["timeAxisMode"],
    playbackServerTime: number,
  ): number {
    const playbackServerTimeMs = playbackServerTime * 1000;
    if (
      this.lastPlaybackTimeAxisMode === mode &&
      this.lastPlaybackServerTimeMs !== null &&
      playbackServerTimeMs + 1 < this.lastPlaybackServerTimeMs
    ) {
      return this.lastPlaybackServerTimeMs / 1000;
    }
    this.lastPlaybackServerTimeMs = playbackServerTimeMs;
    this.lastPlaybackTimeAxisMode = mode;
    return playbackServerTime;
  }
}

function extrapolationPlaybackTime(timeline: {
  mode: RemoteInterpolationDebug["timeAxisMode"];
  playbackServerTime: number;
}): number | undefined {
  return timeline.mode === "server_state_ms" ? timeline.playbackServerTime : undefined;
}

function interpolatePair(
  previous: BufferedSnapshot,
  next: BufferedSnapshot,
  playbackServerTime: number,
  previousTime: number,
  nextTime: number,
): RemoteMotionSample {
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

function extrapolateSingle(
  entry: BufferedSnapshot,
  nowSecs: number,
  playbackServerTime?: number,
): RemoteMotionSample {
  const snapshotTime =
    playbackServerTime === undefined || entry.snapshot.serverStateMs <= 0
      ? entry.receivedAtSecs
      : entry.snapshot.serverStateMs / 1000;
  const rawDt =
    playbackServerTime === undefined
      ? nowSecs - entry.receivedAtSecs
      : playbackServerTime - snapshotTime;
  const dt = Math.min(Math.max(rawDt, 0), MAX_REMOTE_EXTRAPOLATION_SECS);
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

function holdSnapshot(entry: BufferedSnapshot): RemoteMotionSample {
  return {
    position: entry.snapshot.position.clone(),
    velocity: entry.snapshot.velocity.clone(),
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
