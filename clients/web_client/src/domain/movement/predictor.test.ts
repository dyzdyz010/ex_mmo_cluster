import { Vector2, Vector3 } from "three";
import { DEFAULT_MOVEMENT_PROFILE } from "./profile";
import { step } from "./predictor";
import { MovementFlag, MovementMode, makeIdleState, type MoveInputFrame } from "./types";

function frame(seq: number, flags: number, inputDir = new Vector2()): MoveInputFrame {
  return {
    seq,
    clientTick: seq,
    dtMs: DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
    inputDir,
    speedScale: 1,
    movementFlags: flags,
  };
}

describe("movement predictor jump", () => {
  it("starts an airborne jump from grounded state", () => {
    const start = makeIdleState(new Vector3(0, 90, 0));

    const next = step(start, frame(1, MovementFlag.Jump));

    expect(next.movementMode).toBe(MovementMode.Airborne);
    expect(next.velocity.y).toBeGreaterThan(0);
    expect(next.position.y).toBeGreaterThan(start.position.y);
  });

  it("does not restart the impulse while already airborne", () => {
    const start = makeIdleState(new Vector3(0, 90, 0));
    const airborne = step(start, frame(1, MovementFlag.Jump));

    const next = step(airborne, frame(2, MovementFlag.Jump));

    expect(next.movementMode).toBe(MovementMode.Airborne);
    expect(next.velocity.y).toBeLessThan(airborne.velocity.y);
  });

  it("lands back on the original ground height without sinking through it", () => {
    let state = makeIdleState(new Vector3(0, 90, 0));
    state = step(state, frame(1, MovementFlag.Jump));

    // jumpImpulse=900 / gravity=980 / dt=16ms ⇒ 升顶约 57 帧、落回原地约 115 帧。
    // 原先只跑 20 帧(0.32s)远不足以让跳跃落地,与物理参数不一致;跑足够帧数。
    for (let seq = 2; seq <= 140; seq += 1) {
      state = step(state, frame(seq, MovementFlag.None));
    }

    expect(state.movementMode).toBe(MovementMode.Grounded);
    expect(state.position.y).toBeCloseTo(90, 5);
    expect(state.velocity.y).toBe(0);
  });
});
