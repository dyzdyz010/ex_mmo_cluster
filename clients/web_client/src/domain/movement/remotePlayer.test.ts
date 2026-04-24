import { Vector3 } from "three";
import { INTERPOLATION_DELAY_SECS, RemotePlayerState } from "./remotePlayer";
import { MovementMode, type RemoteMoveSnapshot } from "./types";

function snapshot(serverTick: number, x: number): RemoteMoveSnapshot {
  return {
    cid: 7,
    serverTick,
    position: new Vector3(x, 0, 0),
    velocity: new Vector3(100, 0, 0),
    acceleration: new Vector3(),
    movementMode: MovementMode.Grounded,
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
});
