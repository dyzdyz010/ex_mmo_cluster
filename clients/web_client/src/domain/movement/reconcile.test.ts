import { Vector2, Vector3 } from "three";
import { describe, expect, it } from "vitest";
import { DEFAULT_REPLAY_GOVERNANCE } from "./governance";
import { InputHistory, PredictedHistory } from "./history";
import { DEFAULT_MOVEMENT_PROFILE } from "./profile";
import { reconcile } from "./reconcile";
import {
  MovementMode,
  type MoveInputFrame,
  type MovementAck,
  type PredictedMoveState,
} from "./types";

function predicted({ seq, tick, x }: { seq: number; tick: number; x: number }): PredictedMoveState {
  return {
    seq,
    tick,
    position: new Vector3(x, 0, 0),
    velocity: new Vector3(),
    acceleration: new Vector3(),
    movementMode: MovementMode.Grounded,
    groundY: 0,
  };
}

function ack({
  ackSeq,
  authTick,
  x,
}: {
  ackSeq: number;
  authTick: number;
  x: number;
}): MovementAck {
  return {
    ackSeq,
    authTick,
    position: new Vector3(x, 0, 0),
    velocity: new Vector3(),
    acceleration: new Vector3(),
    movementMode: MovementMode.Grounded,
    correctionFlags: 0,
    serverFixedDtMs: 100,
    groundY: 0,
  };
}

function frame(seq: number, clientTick: number, x: number): MoveInputFrame {
  return {
    seq,
    clientTick,
    dtMs: 100,
    inputDir: new Vector2(x, 0),
    speedScale: 1,
    movementFlags: 0,
  };
}

describe("reconcile", () => {
  it("anchors correction matching on authoritative tick before sequence fallback", () => {
    const inputHistory = new InputHistory(16);
    const predictedHistory = new PredictedHistory(16);
    predictedHistory.push(predicted({ seq: 10, tick: 4, x: 500 }));
    predictedHistory.push(predicted({ seq: 0, tick: 5, x: 5 }));

    const result = reconcile(
      ack({ ackSeq: 10, authTick: 5, x: 5 }),
      inputHistory,
      predictedHistory,
      DEFAULT_MOVEMENT_PROFILE,
      { ...DEFAULT_REPLAY_GOVERNANCE },
    );

    expect(result?.action).toBe("accepted");
    expect(result?.correctionDistance).toBe(0);
    expect(result?.latestState.position.x).toBeCloseTo(5, 5);
  });

  it("replays pending inputs from the authoritative anchor when prediction history misses", () => {
    const inputHistory = new InputHistory(16);
    const predictedHistory = new PredictedHistory(16);
    inputHistory.push(frame(2, 2, 1));
    inputHistory.push(frame(3, 3, 1));

    const result = reconcile(
      ack({ ackSeq: 1, authTick: 1, x: 0 }),
      inputHistory,
      predictedHistory,
      DEFAULT_MOVEMENT_PROFILE,
      { ...DEFAULT_REPLAY_GOVERNANCE },
    );

    expect(result?.action).toBe("replayed");
    expect(result?.replayedFrames).toBe(2);
    expect(result?.latestState.tick).toBe(3);
    expect(result?.latestState.position.x).toBeGreaterThan(0);
  });
});
