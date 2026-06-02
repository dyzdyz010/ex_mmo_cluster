import type { TimeSyncSample } from "./transport";

const TIME_SYNC_EWMA_ALPHA = 0.2;
const TIME_SYNC_JUMP_THRESHOLD_MS = 250;
const TIME_SYNC_INITIAL_MAX_RTT_MS = 500;
const TIME_SYNC_ACCEPT_RTT_MARGIN_MS = 120;
const TIME_SYNC_ACCEPT_RTT_MULTIPLIER = 3;

export interface ServerClockDebugSnapshot {
  serverClockOffsetMs: number | null;
  rawServerClockOffsetMs: number | null;
  timeSyncRttMs: number | null;
  timeSyncSmoothedRttMs: number | null;
  timeSyncOffsetJitterMs: number;
  timeSyncOffsetJumpCount: number;
  timeSyncRejectedOffsetSampleCount: number;
  timeSyncSampleCount: number;
}

export class ServerClockEstimator {
  private serverClockOffsetMs: number | null = null;
  private rawServerClockOffsetMs: number | null = null;
  private timeSyncRttMs: number | null = null;
  private timeSyncSmoothedRttMs: number | null = null;
  private timeSyncBestRttMs: number | null = null;
  private timeSyncOffsetJitterMs = 0;
  private timeSyncOffsetJumpCount = 0;
  private timeSyncRejectedOffsetSampleCount = 0;
  private timeSyncSampleCount = 0;

  observe(sample: TimeSyncSample, clientRecvTs = Date.now()): void {
    const rttMs = clientRecvTs - sample.clientSendTs - (sample.serverSendTs - sample.serverRecvTs);
    const rawOffsetMs =
      (sample.serverRecvTs - sample.clientSendTs + sample.serverSendTs - clientRecvTs) / 2;
    this.observeRawSample(rawOffsetMs, rttMs);
  }

  sampleClock(localWallClockMs = Date.now()): {
    localWallClockMs: number;
    serverClockOffsetMs: number | null;
  } {
    return {
      localWallClockMs,
      serverClockOffsetMs: this.serverClockOffsetMs,
    };
  }

  debugSnapshot(): ServerClockDebugSnapshot {
    return {
      serverClockOffsetMs: this.serverClockOffsetMs,
      rawServerClockOffsetMs: this.rawServerClockOffsetMs,
      timeSyncRttMs: this.timeSyncRttMs,
      timeSyncSmoothedRttMs: this.timeSyncSmoothedRttMs,
      timeSyncOffsetJitterMs: this.timeSyncOffsetJitterMs,
      timeSyncOffsetJumpCount: this.timeSyncOffsetJumpCount,
      timeSyncRejectedOffsetSampleCount: this.timeSyncRejectedOffsetSampleCount,
      timeSyncSampleCount: this.timeSyncSampleCount,
    };
  }

  private observeRawSample(rawOffsetMs: number, rttMs: number): void {
    if (!Number.isFinite(rawOffsetMs) || !Number.isFinite(rttMs)) {
      return;
    }

    const normalizedRttMs = Math.max(0, rttMs);
    const previousBestRttMs = this.timeSyncBestRttMs;

    this.rawServerClockOffsetMs = rawOffsetMs;
    this.timeSyncRttMs = normalizedRttMs;
    this.timeSyncBestRttMs =
      this.timeSyncBestRttMs === null
        ? normalizedRttMs
        : Math.min(this.timeSyncBestRttMs, normalizedRttMs);
    this.timeSyncSampleCount += 1;

    if (this.serverClockOffsetMs === null) {
      this.timeSyncSmoothedRttMs = normalizedRttMs;
      if (normalizedRttMs > TIME_SYNC_INITIAL_MAX_RTT_MS) {
        this.timeSyncRejectedOffsetSampleCount += 1;
        return;
      }
      this.serverClockOffsetMs = rawOffsetMs;
      this.timeSyncOffsetJitterMs = 0;
      return;
    }

    this.timeSyncSmoothedRttMs =
      this.timeSyncSmoothedRttMs === null
        ? normalizedRttMs
        : this.timeSyncSmoothedRttMs * (1 - TIME_SYNC_EWMA_ALPHA) +
          normalizedRttMs * TIME_SYNC_EWMA_ALPHA;

    if (!this.acceptOffsetSample(normalizedRttMs, previousBestRttMs)) {
      this.timeSyncRejectedOffsetSampleCount += 1;
      return;
    }

    const offsetDeltaMs = Math.abs(rawOffsetMs - this.serverClockOffsetMs);
    if (offsetDeltaMs > TIME_SYNC_JUMP_THRESHOLD_MS) {
      this.timeSyncOffsetJumpCount += 1;
    }
    this.timeSyncOffsetJitterMs =
      this.timeSyncOffsetJitterMs * (1 - TIME_SYNC_EWMA_ALPHA) +
      offsetDeltaMs * TIME_SYNC_EWMA_ALPHA;
    this.serverClockOffsetMs =
      this.serverClockOffsetMs * (1 - TIME_SYNC_EWMA_ALPHA) + rawOffsetMs * TIME_SYNC_EWMA_ALPHA;
  }

  private acceptOffsetSample(normalizedRttMs: number, previousBestRttMs: number | null): boolean {
    if (previousBestRttMs === null) {
      return true;
    }

    const acceptedRttCeilingMs = Math.max(
      previousBestRttMs + TIME_SYNC_ACCEPT_RTT_MARGIN_MS,
      previousBestRttMs * TIME_SYNC_ACCEPT_RTT_MULTIPLIER,
    );
    return normalizedRttMs <= acceptedRttCeilingMs;
  }
}
