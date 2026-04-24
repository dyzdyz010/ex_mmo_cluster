import { Vector2, Vector3 } from "three";
import { decodeServerMessage, encodeMovementInput } from "./gateProtocol";
import {
  CorrectionFlag,
  MovementFlag,
  MovementMode,
  type MoveInputFrame,
} from "@domain/movement/types";

function writeVec3(view: DataView, offset: number, x: number, y: number, z: number): void {
  view.setFloat64(offset, x, false);
  view.setFloat64(offset + 8, y, false);
  view.setFloat64(offset + 16, z, false);
}

describe("gate movement protocol", () => {
  it("encodes jump as movement flag bit 0x04 while preserving brake bit 0x02", () => {
    const frame: MoveInputFrame = {
      seq: 1,
      clientTick: 2,
      dtMs: 100,
      inputDir: new Vector2(0, 0),
      speedScale: 1,
      movementFlags: MovementFlag.Jump | MovementFlag.Brake,
    };

    const encoded = encodeMovementInput(frame);
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    expect(view.getUint16(encoded.byteLength - 2, false)).toBe(0x06);
  });

  it("decodes movement ack mode and correction flags from the wire", () => {
    const buffer = new ArrayBuffer(95);
    const view = new DataView(buffer);
    view.setUint8(0, 0x8b);
    view.setUint32(1, 10, false);
    view.setUint32(5, 11, false);
    view.setBigInt64(9, 42n, false);
    writeVec3(view, 17, 1, 2, 3);
    writeVec3(view, 41, 4, 5, 6);
    writeVec3(view, 65, 7, 8, 9);
    view.setUint8(89, 1);
    view.setUint32(90, CorrectionFlag.StatusOverride, false);

    const message = decodeServerMessage(buffer);

    expect(message?.type).toBe("movement_ack");
    if (message?.type !== "movement_ack") return;
    expect(message.ack.movementMode).toBe(MovementMode.Airborne);
    expect(message.ack.correctionFlags).toBe(CorrectionFlag.StatusOverride);
    expect(message.ack.position).toEqual(new Vector3(1, 3, 2));
  });

  it("decodes remote snapshot movement mode from the wire", () => {
    const buffer = new ArrayBuffer(86);
    const view = new DataView(buffer);
    view.setUint8(0, 0x83);
    view.setBigInt64(1, 42n, false);
    view.setUint32(9, 7, false);
    writeVec3(view, 13, 1, 2, 3);
    writeVec3(view, 37, 4, 5, 6);
    writeVec3(view, 61, 7, 8, 9);
    view.setUint8(85, 1);

    const message = decodeServerMessage(buffer);

    expect(message?.type).toBe("player_move");
    if (message?.type !== "player_move") return;
    expect(message.snapshot.movementMode).toBe(MovementMode.Airborne);
  });
});
