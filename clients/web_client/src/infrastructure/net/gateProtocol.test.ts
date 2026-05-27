import { Vector2, Vector3 } from "three";
import { decodeServerMessage, encodeChatSayScoped, encodeMovementInput } from "./gateProtocol";
import {
  AoiPriorityBand,
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
  it("encodes scoped chat with only request id, scope, and text", () => {
    const encoded = encodeChatSayScoped(43, "region", "region hello");
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    expect(view.getUint8(0)).toBe(0x0a);
    expect(view.getBigUint64(1, false)).toBe(43n);
    expect(view.getUint8(9)).toBe(1);
    expect(view.getUint16(10, false)).toBe(12);
    expect(new TextDecoder().decode(encoded.slice(12))).toBe("region hello");
    expect(encoded.byteLength).toBe(1 + 8 + 1 + 2 + 12);
  });

  it("decodes chat messages as first-class server frames", () => {
    const username = new TextEncoder().encode("tester");
    const text = new TextEncoder().encode("hello world");
    const buffer = new ArrayBuffer(1 + 8 + 2 + username.length + 2 + text.length);
    const view = new DataView(buffer);
    let offset = 0;
    view.setUint8(offset, 0x89);
    offset += 1;
    view.setBigInt64(offset, 42n, false);
    offset += 8;
    view.setUint16(offset, username.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, username.length).set(username);
    offset += username.length;
    view.setUint16(offset, text.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, text.length).set(text);

    expect(decodeServerMessage(buffer)).toEqual({
      type: "chat_message",
      cid: 42,
      username: "tester",
      text: "hello world",
    });
  });

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
    // Audit B-M2: trailing fixed_dt_ms u16 BE pushed total frame from
    // 95 → 96 bytes;new field lives at view offset 94.
    // Phase A1-4: trailing ground_z f64 BE pushed total frame from
    // 96 → 104 bytes;new field lives at view offset 96.
    const buffer = new ArrayBuffer(104);
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
    view.setUint16(94, 100, false);
    // Phase A1-4:server's ground_z (browser y axis after vec3 swap).
    view.setFloat64(96, 7.5, false);

    const message = decodeServerMessage(buffer);

    expect(message?.type).toBe("movement_ack");
    if (message?.type !== "movement_ack") return;
    expect(message.ack.movementMode).toBe(MovementMode.Airborne);
    expect(message.ack.correctionFlags).toBe(CorrectionFlag.StatusOverride);
    expect(message.ack.position).toEqual(new Vector3(1, 3, 2));
    expect(message.ack.serverFixedDtMs).toBe(100);
    expect(message.ack.groundY).toBe(7.5);
  });

  it("decodes enter_scene_ok with expectedSeq", () => {
    // Audit B-S1 / B-SRV2: success body is packet_id(8) + ok(1) +
    // vec3(24) + expected_seq(u32 BE). Total frame = 38 bytes (1 +37).
    const buffer = new ArrayBuffer(38);
    const view = new DataView(buffer);
    view.setUint8(0, 0x84);
    view.setBigUint64(1, 7n, false); // requestId
    view.setUint8(9, 0); // ok
    writeVec3(view, 10, 100, 200, 90);
    view.setUint32(34, 42, false); // expected_seq

    const message = decodeServerMessage(buffer);
    expect(message?.type).toBe("enter_scene_ok");
    if (message?.type !== "enter_scene_ok") return;
    expect(message.requestId).toBe(7);
    expect(message.expectedSeq).toBe(42);
    // Server vec3 (x, y, z) → browser (x, z, y) per readServerVec3AsBrowserVec3.
    expect(message.position.x).toBe(100);
    expect(message.position.y).toBe(90);
    expect(message.position.z).toBe(200);
  });

  it("decodes generic result errors instead of dropping them", () => {
    const buffer = new ArrayBuffer(10);
    const view = new DataView(buffer);
    view.setUint8(0, 0x80);
    view.setBigUint64(1, 99n, false);
    view.setUint8(9, 1);

    expect(decodeServerMessage(buffer)).toEqual({
      type: "result_error",
      requestId: 99,
    });
  });

  it("decodes generic result success frames without hard-coding auth semantics", () => {
    const buffer = new ArrayBuffer(10);
    const view = new DataView(buffer);
    view.setUint8(0, 0x80);
    view.setBigUint64(1, 99n, false);
    view.setUint8(9, 0);

    expect(decodeServerMessage(buffer)).toEqual({
      type: "result_ok",
      requestId: 99,
    });
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

  it("decodes optional AOI priority metadata on remote snapshots", () => {
    const buffer = new ArrayBuffer(97);
    const view = new DataView(buffer);
    view.setUint8(0, 0x83);
    view.setBigInt64(1, 42n, false);
    view.setUint32(9, 7, false);
    writeVec3(view, 13, 1, 2, 3);
    writeVec3(view, 37, 4, 5, 6);
    writeVec3(view, 61, 7, 8, 9);
    view.setUint8(85, 0);
    view.setUint8(86, 1);
    view.setFloat32(87, 0.75, false);
    view.setFloat32(91, 125.5, false);
    view.setUint16(95, 2, false);

    const message = decodeServerMessage(buffer);

    expect(message?.type).toBe("player_move");
    if (message?.type !== "player_move") return;
    expect(message.snapshot.priorityBand).toBe(AoiPriorityBand.Medium);
    expect(message.snapshot.priorityScore).toBeCloseTo(0.75, 4);
    expect(message.snapshot.observerDistance).toBeCloseTo(125.5, 4);
    expect(message.snapshot.deliveryInterval).toBe(2);
  });

  it("decodes AOI enter and leave messages for remote entity lifetime", () => {
    const enter = new ArrayBuffer(33);
    const enterView = new DataView(enter);
    enterView.setUint8(0, 0x81);
    enterView.setBigInt64(1, 42n, false);
    writeVec3(enterView, 9, 1, 2, 3);

    const leave = new ArrayBuffer(9);
    const leaveView = new DataView(leave);
    leaveView.setUint8(0, 0x82);
    leaveView.setBigInt64(1, 42n, false);

    const enterMessage = decodeServerMessage(enter);
    const leaveMessage = decodeServerMessage(leave);

    expect(enterMessage?.type).toBe("player_enter");
    if (enterMessage?.type === "player_enter") {
      expect(enterMessage.cid).toBe(42);
      expect(enterMessage.position).toEqual(new Vector3(1, 3, 2));
    }

    expect(leaveMessage).toEqual({ type: "player_leave", cid: 42 });
  });

  it("decodes time sync replies for server-clock interpolation", () => {
    const buffer = new ArrayBuffer(33);
    const view = new DataView(buffer);
    view.setUint8(0, 0x85);
    view.setBigUint64(1, 7n, false);
    view.setBigUint64(9, 100n, false);
    view.setBigUint64(17, 120n, false);
    view.setBigUint64(25, 125n, false);

    const message = decodeServerMessage(buffer);

    expect(message).toEqual({
      type: "time_sync_reply",
      requestId: 7,
      clientSendTs: 100,
      serverRecvTs: 120,
      serverSendTs: 125,
    });
  });

  it("decodes player state pushes instead of treating them as ignored frames", () => {
    const buffer = new ArrayBuffer(14);
    const view = new DataView(buffer);
    view.setUint8(0, 0x8c);
    view.setBigInt64(1, 42n, false);
    view.setUint16(9, 75, false);
    view.setUint16(11, 100, false);
    view.setUint8(13, 1);

    const message = decodeServerMessage(buffer);

    expect(message).toEqual({
      type: "player_state",
      cid: 42,
      hp: 75,
      maxHp: 100,
      alive: true,
    });
  });

  it("labels known but currently unhandled downlink frames for observe logs", () => {
    const message = decodeServerMessage(new Uint8Array([0x8e, 0, 1, 2]).buffer);

    expect(message).toEqual({
      type: "known_unhandled_downlink",
      opcode: 0x8e,
      name: "actor_identity",
      byteLength: 4,
    });
  });

  it("returns null instead of throwing when known fixed-length frames are truncated", () => {
    for (const opcode of [0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x8b, 0x8c]) {
      const frame = new Uint8Array([opcode, 0, 1, 2]).buffer;
      expect(() => decodeServerMessage(frame)).not.toThrow();
      expect(decodeServerMessage(frame)).toBeNull();
    }
  });
});
