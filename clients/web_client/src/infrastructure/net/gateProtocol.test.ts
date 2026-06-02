import { Vector2, Vector3 } from "three";
import {
  decodeServerMessage,
  encodeChatSayScoped,
  encodeMovementInput,
  encodeTimeSync,
} from "./gateProtocol";
import {
  AoiPriorityBand,
  CorrectionFlag,
  MovementFlag,
  MovementMode,
  type MoveInputFrame,
} from "@domain/movement/types";
import { MOVEMENT_WIRE_SCHEMA, PROTOCOL_VERSION } from "./protocolVersion";

function writeVec3(view: DataView, offset: number, x: number, y: number, z: number): void {
  view.setFloat64(offset, x, false);
  view.setFloat64(offset + 8, y, false);
  view.setFloat64(offset + 16, z, false);
}

describe("gate movement protocol", () => {
  it("encodes time sync requests with request id and client wall-clock timestamp", () => {
    const encoded = encodeTimeSync(77, 1_700_000_000_123);
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);

    expect(view.getUint8(0)).toBe(0x03);
    expect(view.getBigUint64(1, false)).toBe(77n);
    expect(view.getBigUint64(9, false)).toBe(1_700_000_000_123n);
  });

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
    // Movement schema v2 layout (121 bytes):
    //   [0] opcode, [1] schema_version, [2] ack_seq, [6] auth_tick,
    //   [10] server_state_ms, [18] server_send_ms, [26] cid,
    //   [34] pos, [58] vel, [82] accel, [106] mode,
    //   [107] flags, [111] fixed_dt_ms, [113] ground_z.
    const buffer = new ArrayBuffer(121);
    const view = new DataView(buffer);
    view.setUint8(0, 0x8b);
    view.setUint8(1, MOVEMENT_WIRE_SCHEMA);
    view.setUint32(2, 10, false); // ack_seq
    view.setUint32(6, 11, false); // auth_tick
    view.setBigUint64(10, 1_700_000_000_000n, false); // server_state_ms
    view.setBigUint64(18, 1_700_000_000_020n, false); // server_send_ms
    view.setBigInt64(26, 42n, false); // cid
    writeVec3(view, 34, 1, 2, 3); // pos
    writeVec3(view, 58, 4, 5, 6); // vel
    writeVec3(view, 82, 7, 8, 9); // accel
    view.setUint8(106, 1); // movement_mode airborne
    view.setUint32(107, CorrectionFlag.StatusOverride, false); // correction_flags
    view.setUint16(111, 100, false); // fixed_dt_ms
    // ground_z at 113 (server z → browser y after vec3 swap)
    view.setFloat64(113, 7.5, false);

    const message = decodeServerMessage(buffer);

    expect(message?.type).toBe("movement_ack");
    if (message?.type !== "movement_ack") return;
    expect(message.ack.movementMode).toBe(MovementMode.Airborne);
    expect(message.ack.correctionFlags).toBe(CorrectionFlag.StatusOverride);
    expect(message.ack.serverStateMs).toBe(1_700_000_000_000);
    expect(message.ack.serverSendMs).toBe(1_700_000_000_020);
    expect(message.ack.position).toEqual(new Vector3(1, 3, 2));
    expect(message.ack.serverFixedDtMs).toBe(100);
    expect(message.ack.groundY).toBe(7.5);
  });

  it("decodes enter_scene_ok with expectedSeq", () => {
    // Pillar 1.1: packet_id(8) + ok(1) + vec3(24) + expected_seq(u32) +
    // protocol_version(u16). Total frame = 40 bytes.
    const buffer = new ArrayBuffer(40);
    const view = new DataView(buffer);
    view.setUint8(0, 0x84);
    view.setBigUint64(1, 7n, false); // requestId
    view.setUint8(9, 0); // ok
    writeVec3(view, 10, 100, 200, 90);
    view.setUint32(34, 42, false); // expected_seq
    view.setUint16(38, PROTOCOL_VERSION, false);

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
    // Movement schema v2 layout (compact 103B):
    //   [0] opcode, [1] schema, [2] cid, [10] server_tick,
    //   [14] server_state_ms, [22] server_send_ms,
    //   [30] pos, [54] vel, [78] accel, [102] mode.
    const buffer = new ArrayBuffer(103);
    const view = new DataView(buffer);
    view.setUint8(0, 0x83);
    view.setUint8(1, MOVEMENT_WIRE_SCHEMA);
    view.setBigInt64(2, 42n, false); // cid
    view.setUint32(10, 7, false); // server_tick
    view.setBigUint64(14, 1_700_000_000_000n, false); // server_state_ms
    view.setBigUint64(22, 1_700_000_000_020n, false); // server_send_ms
    writeVec3(view, 30, 1, 2, 3); // pos
    writeVec3(view, 54, 4, 5, 6); // vel
    writeVec3(view, 78, 7, 8, 9); // accel
    view.setUint8(102, 1); // movement_mode airborne

    const message = decodeServerMessage(buffer);

    expect(message?.type).toBe("player_move");
    if (message?.type !== "player_move") return;
    expect(message.snapshot.movementMode).toBe(MovementMode.Airborne);
    expect(message.snapshot.serverStateMs).toBe(1_700_000_000_000);
    expect(message.snapshot.serverSendMs).toBe(1_700_000_000_020);
  });

  it("decodes optional AOI priority metadata on remote snapshots", () => {
    // Movement schema v2 complete layout (114B):
    //   [0] opcode, [1] schema, [2] cid, [10] tick, [14] state_ms, [22] send_ms,
    //   [30] pos, [54] vel, [78] accel, [102] mode,
    //   [103] priority_band, [104] priority_score, [108] obs_dist, [112] delivery_interval.
    const buffer = new ArrayBuffer(114);
    const view = new DataView(buffer);
    view.setUint8(0, 0x83);
    view.setUint8(1, MOVEMENT_WIRE_SCHEMA);
    view.setBigInt64(2, 42n, false); // cid
    view.setUint32(10, 7, false); // server_tick
    view.setBigUint64(14, 1_700_000_000_000n, false); // server_state_ms
    view.setBigUint64(22, 1_700_000_000_020n, false); // server_send_ms
    writeVec3(view, 30, 1, 2, 3); // pos
    writeVec3(view, 54, 4, 5, 6); // vel
    writeVec3(view, 78, 7, 8, 9); // accel
    view.setUint8(102, 0); // grounded
    view.setUint8(103, 1); // priority_band medium
    view.setFloat32(104, 0.75, false);
    view.setFloat32(108, 125.5, false);
    view.setUint16(112, 2, false);

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

  // ── Task 8: encodeMovementInput schema_version ──
  it("encodeMovementInput emits schema_version byte after opcode (26 bytes)", () => {
    const bytes = encodeMovementInput({
      seq: 55,
      clientTick: 1000,
      dtMs: 100,
      inputDir: { x: 1.0, y: 0.5 },
      speedScale: 1.25,
      movementFlags: 3,
    });
    expect(bytes.byteLength).toBe(26);
    const view = new DataView(bytes.buffer);
    expect(view.getUint8(0)).toBe(0x01);
    expect(view.getUint8(1)).toBe(MOVEMENT_WIRE_SCHEMA);
    expect(view.getUint32(2, false)).toBe(55);
  });

  // ── Task 9: decode player_move schema v2 + server_state_ms + server_send_ms ──
  it("decodes player_move with schema_version + server_state_ms + server_send_ms (compact, 103 bytes)", () => {
    const buf = new ArrayBuffer(103);
    const v = new DataView(buf);
    v.setUint8(0, 0x83);
    v.setUint8(1, MOVEMENT_WIRE_SCHEMA);
    v.setBigUint64(2, 55n, false); // cid
    v.setUint32(10, 9, false); // server_tick
    v.setBigUint64(14, 1_700_000_000_100n, false); // server_state_ms
    v.setBigUint64(22, 1_700_000_000_123n, false); // server_send_ms
    v.setFloat64(30, 1.0, false); // x
    v.setFloat64(38, 2.0, false); // y (server) -> z (browser)
    v.setFloat64(46, 3.0, false); // z (server) -> y (browser)
    v.setFloat64(54, 0, false);
    v.setFloat64(62, 0, false);
    v.setFloat64(70, 0, false);
    v.setFloat64(78, 0, false);
    v.setFloat64(86, 0, false);
    v.setFloat64(94, 0, false);
    v.setUint8(102, 1); // movement_mode airborne

    const msg = decodeServerMessage(buf);
    expect(msg?.type).toBe("player_move");
    if (msg?.type === "player_move") {
      expect(msg.snapshot.cid).toBe(55);
      expect(msg.snapshot.serverTick).toBe(9);
      expect(msg.snapshot.serverStateMs).toBe(1_700_000_000_100);
      expect(msg.snapshot.serverSendMs).toBe(1_700_000_000_123);
      expect(msg.snapshot.position.x).toBeCloseTo(1.0);
      expect(msg.snapshot.position.y).toBeCloseTo(3.0); // server z -> browser y
      expect(msg.snapshot.position.z).toBeCloseTo(2.0); // server y -> browser z
    }
  });

  it("decodes player_move with AOI priority metadata (complete, 114 bytes) schema v2", () => {
    const buf = new ArrayBuffer(114);
    const v = new DataView(buf);
    v.setUint8(0, 0x83);
    v.setUint8(1, MOVEMENT_WIRE_SCHEMA);
    v.setBigUint64(2, 42n, false); // cid
    v.setUint32(10, 7, false); // server_tick
    v.setBigUint64(14, 1_700_000_000_000n, false); // server_state_ms
    v.setBigUint64(22, 1_700_000_000_020n, false); // server_send_ms
    // pos, vel, accel at 30, 54, 78 — leave 0
    v.setUint8(102, 0); // grounded
    v.setUint8(103, 1); // priority_band medium
    v.setFloat32(104, 0.75, false);
    v.setFloat32(108, 125.5, false);
    v.setUint16(112, 2, false);

    const msg = decodeServerMessage(buf);
    expect(msg?.type).toBe("player_move");
    if (msg?.type === "player_move") {
      expect(msg.snapshot.priorityBand).toBe(AoiPriorityBand.Medium);
      expect(msg.snapshot.priorityScore).toBeCloseTo(0.75, 4);
      expect(msg.snapshot.observerDistance).toBeCloseTo(125.5, 4);
      expect(msg.snapshot.deliveryInterval).toBe(2);
    }
  });

  it("rejects player_move with unknown schema version", () => {
    const buf = new ArrayBuffer(103);
    const v = new DataView(buf);
    v.setUint8(0, 0x83);
    v.setUint8(1, 9); // bad schema
    expect(decodeServerMessage(buf)).toBeNull();
  });

  // ── Task 10: decode movement_ack schema v2 + server_state_ms + server_send_ms ──
  it("decodes movement_ack with schema_version + server_state_ms + server_send_ms (121 bytes)", () => {
    const buf = new ArrayBuffer(121);
    const v = new DataView(buf);
    v.setUint8(0, 0x8b);
    v.setUint8(1, MOVEMENT_WIRE_SCHEMA);
    v.setUint32(2, 10, false); // ack_seq
    v.setUint32(6, 77, false); // auth_tick
    v.setBigUint64(10, 1_700_000_000_100n, false); // server_state_ms
    v.setBigUint64(18, 1_700_000_000_123n, false); // server_send_ms
    v.setBigUint64(26, 42n, false); // cid
    v.setFloat64(34, 1.5, false); // px
    v.setFloat64(42, 2.5, false); // py
    v.setFloat64(50, 3.5, false); // pz
    // vel(58..81), accel(82..105) leave 0
    v.setUint8(106, 0); // movement_mode grounded
    v.setUint32(107, 3, false); // correction_flags
    v.setUint16(111, 100, false); // fixed_dt_ms
    v.setFloat64(113, 3.5, false); // ground_z

    const msg = decodeServerMessage(buf);
    expect(msg?.type).toBe("movement_ack");
    if (msg?.type === "movement_ack") {
      expect(msg.ack.ackSeq).toBe(10);
      expect(msg.ack.authTick).toBe(77);
      expect(msg.ack.serverStateMs).toBe(1_700_000_000_100);
      expect(msg.ack.serverSendMs).toBe(1_700_000_000_123);
      expect(msg.ack.correctionFlags).toBe(3);
      expect(msg.ack.serverFixedDtMs).toBe(100);
      expect(msg.ack.groundY).toBeCloseTo(3.5);
    }
  });

  it("rejects movement_ack with unknown schema version", () => {
    const buf = new ArrayBuffer(121);
    const v = new DataView(buf);
    v.setUint8(0, 0x8b);
    v.setUint8(1, 9); // bad schema
    expect(decodeServerMessage(buf)).toBeNull();
  });

  // ── Task 11: decode enter_scene_ok with protocol_version ──
  it("decodes enter_scene_ok with trailing protocol_version (40 bytes)", () => {
    const buf = new ArrayBuffer(40);
    const v = new DataView(buf);
    v.setUint8(0, 0x84);
    v.setBigUint64(1, 12n, false); // packet_id
    v.setUint8(9, 0x00); // ok
    v.setFloat64(10, 10.0, false); // x
    v.setFloat64(18, 20.0, false); // y(server)
    v.setFloat64(26, 30.0, false); // z(server)
    v.setUint32(34, 1, false); // expected_seq
    v.setUint16(38, PROTOCOL_VERSION, false);

    const msg = decodeServerMessage(buf);
    expect(msg?.type).toBe("enter_scene_ok");
    if (msg?.type === "enter_scene_ok") {
      expect(msg.expectedSeq).toBe(1);
      expect(msg.protocolVersion).toBe(PROTOCOL_VERSION);
    }
  });
});
