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
});
