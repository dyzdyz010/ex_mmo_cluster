import { Vector2, Vector3 } from "three";
import { describe, expect, it } from "vitest";
import { MovementFlag, MovementMode, type MoveInputFrame } from "@domain/movement/types";
import { SimulatedLocalMovementTransport } from "./simulatedMovementTransport";

function frame(seq: number, inputDir = new Vector2(1, 0)): MoveInputFrame {
  return {
    seq,
    clientTick: seq,
    dtMs: 100,
    inputDir,
    speedScale: 1,
    movementFlags: inputDir.lengthSq() > 0 ? MovementFlag.None : MovementFlag.Brake,
  };
}

describe("SimulatedLocalMovementTransport", () => {
  it("acks local inputs immediately and in input sequence order", () => {
    const transport = new SimulatedLocalMovementTransport();
    transport.reset(new Vector3(0, 0, 0));

    transport.sendInput(frame(1), 1000);
    transport.sendInput(frame(2), 1000);
    transport.sendInput(frame(3), 1000);

    const result = transport.tick(1000, 0);

    expect(result.acknowledgements.map((entry) => entry.ack.ackSeq)).toEqual([1, 2, 3]);
    expect(result.acknowledgements.map((entry) => entry.ack.authTick)).toEqual([1, 2, 3]);
    expect(result.acknowledgements.every((entry) => entry.ack.movementMode === MovementMode.Grounded))
      .toBe(true);
    expect(transport.debugSnapshot()).toMatchObject({ pendingAcknowledgements: 0 });
  });

  it("does not synthesize decorative remote actors in offline fallback", () => {
    const transport = new SimulatedLocalMovementTransport();
    transport.reset(new Vector3(0, 0, 0));

    expect(transport.tick(1_000, 500).remoteSnapshots).toEqual([]);
    expect(transport.debugSnapshot()).toMatchObject({
      pendingRemoteSnapshots: 0,
      decorativeRemoteActor: false,
    });
  });
});
