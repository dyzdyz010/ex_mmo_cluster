import { Vector3 } from "three";
import { INTERPOLATION_DELAY_SECS, RemotePlayerState } from "./remotePlayer";
import { MovementMode, type RemoteMoveSnapshot } from "./types";

function snapshot(
  serverTick: number,
  x: number,
  overrides: Partial<RemoteMoveSnapshot> = {},
): RemoteMoveSnapshot {
  return {
    cid: 7,
    serverTick,
    serverStateMs: 0,
    serverSendMs: 0,
    position: new Vector3(x, 0, 0),
    velocity: new Vector3(100, 0, 0),
    acceleration: new Vector3(),
    movementMode: MovementMode.Grounded,
    ...overrides,
  };
}

describe("remotePlayer", () => {
  it("keeps the interpolation delay at the 150 ms baseline", () => {
    expect(INTERPOLATION_DELAY_SECS).toBeCloseTo(0.15, 5);
  });

  it("replays the 150 ms delayed historical snapshot instead of lagging an extra 70 ms", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(10, 0), 0, 1.0);
    state.pushSnapshot(snapshot(11, 10), 0, 1.1);
    state.pushSnapshot(snapshot(12, 20), 0, 1.2);
    state.pushSnapshot(snapshot(13, 30), 0, 1.3);

    const sample = state.sampleMotion(1.35);

    expect(sample.position.x).toBeCloseTo(20, 4);
  });

  it("uses the server advertised tick duration when converting snapshot ticks", () => {
    const state = new RemotePlayerState({ tickDurationSecs: 0.05 });
    state.pushSnapshot(snapshot(20, 0), 0, 1.0);
    state.pushSnapshot(snapshot(21, 10), 0, 1.05);
    state.pushSnapshot(snapshot(22, 20), 0, 1.1);
    state.pushSnapshot(snapshot(23, 30), 0, 1.15);

    const sample = state.sampleMotion(1.25);

    expect(sample.position.x).toBeCloseTo(20, 4);
  });

  it("uses server_state_ms plus clock offset as the interpolation timeline", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(
      snapshot(1_000, 0, { serverStateMs: 2_000_000, serverSendMs: 2_000_020 }),
      0,
      1.0,
    );
    state.pushSnapshot(
      snapshot(1_001, 100, { serverStateMs: 2_000_100, serverSendMs: 2_000_120 }),
      0,
      1.1,
    );

    const sample = state.sampleMotion(0, {
      localWallClockMs: 1_999_700,
      serverClockOffsetMs: 500,
    });
    const debug = state.debugSnapshot();

    expect(sample.mode).toBe("interpolated");
    expect(sample.position.x).toBeCloseTo(50, 4);
    expect(debug.timeAxisMode).toBe("server_state_ms");
    expect(debug.lastPlaybackServerTimeMs).toBeCloseTo(2_000_050, 4);
  });

  it("keeps the state timeline when send timestamps are distorted by delivery backlog", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(
      snapshot(10, 0, { serverStateMs: 2_000_000, serverSendMs: 2_000_500 }),
      0,
      1.0,
    );
    state.pushSnapshot(
      snapshot(18, 80, { serverStateMs: 2_000_800, serverSendMs: 2_000_560 }),
      0,
      1.06,
    );

    const sample = state.sampleMotion(1.06, {
      localWallClockMs: 2_000_950,
      serverClockOffsetMs: 0,
    });

    expect(sample.position.x).toBeCloseTo(80, 4);
    expect(state.debugSnapshot()).toMatchObject({
      timeAxisMode: "server_state_ms",
      serverStateTimelineHealthy: true,
    });
  });

  it("falls back to server_tick when server_state_ms is missing from old/offline snapshots", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(10, 0, { serverSendMs: 2_000_000 }), 0, 1.0);
    state.pushSnapshot(snapshot(18, 80, { serverSendMs: 2_000_060 }), 0, 1.06);

    state.sampleMotion(1.06, {
      localWallClockMs: 2_000_200,
      serverClockOffsetMs: 0,
    });

    expect(state.debugSnapshot()).toMatchObject({
      timeAxisMode: "server_tick",
      serverSendTimelineHealthy: false,
    });
  });

  it("holds the earliest wall-clock snapshot when playback is before the buffer", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(1_000, 0, { serverStateMs: 2_000_000 }), 0, 1.0);
    state.pushSnapshot(snapshot(1_001, 100, { serverStateMs: 2_000_100 }), 0, 1.1);

    const sample = state.sampleMotion(0, {
      localWallClockMs: 1_999_550,
      serverClockOffsetMs: 500,
    });

    expect(sample.position.x).toBeCloseTo(0, 4);
  });

  it("expands interpolation delay for low-priority throttled remote snapshots", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(10, 0, { deliveryInterval: 5 }), 0, 1.0);
    state.pushSnapshot(snapshot(15, 50, { deliveryInterval: 5 }), 0, 1.5);

    const debug = state.debugSnapshot();

    expect(debug.interpolationDelaySecs).toBeCloseTo(0.6, 5);
  });

  it("reports interpolation buffer diagnostics for CLI observability", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(10, 0), 0, 1.0);
    state.pushSnapshot(snapshot(11, 10), 0, 1.1);

    const sample = state.sampleMotion(1.4);
    const debug = state.debugSnapshot();

    expect(sample.mode).toBe("extrapolated");
    expect(debug.bufferedSnapshots).toBe(2);
    expect(debug.latestServerTick).toBe(11);
    expect(debug.lastSampleMode).toBe("extrapolated");
  });

  it("counts server tick discontinuities for observe diagnostics", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(10, 0), 0, 1.0);
    state.pushSnapshot(snapshot(12, 20), 0, 1.2);

    expect(state.debugSnapshot().serverTickDiscontinuityCount).toBe(1);
  });

  it("keeps server_state_ms playback monotonic when clock offset moves backward", () => {
    const state = new RemotePlayerState();
    state.pushSnapshot(snapshot(10, 0, { serverStateMs: 2_000_000 }), 0, 1.0);
    state.pushSnapshot(snapshot(11, 10, { serverStateMs: 2_000_100 }), 0, 1.1);

    state.sampleMotion(0, { localWallClockMs: 2_000_300, serverClockOffsetMs: 0 });
    state.sampleMotion(0, { localWallClockMs: 2_000_250, serverClockOffsetMs: 0 });

    const debug = state.debugSnapshot();
    expect(debug.lastPlaybackServerTimeMs).toBeCloseTo(2_000_150, 4);
    expect(debug.playbackTimeRegressionCount).toBe(0);
  });
});
