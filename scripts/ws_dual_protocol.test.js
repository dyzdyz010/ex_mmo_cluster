const test = require("node:test");
const assert = require("node:assert/strict");

const {
  MOVEMENT_WIRE_SCHEMA,
  encodeMove,
  decodeMovementAck,
  decodePlayerMove,
} = require("./ws_dual_protocol");

test("encodes current schema movement input", () => {
  const frame = encodeMove({
    seq: 7,
    clientTick: 11,
    dx: 0.5,
    dy: -0.25,
    flags: 4,
  });
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);

  assert.equal(frame.byteLength, 26);
  assert.equal(view.getUint8(0), 0x01);
  assert.equal(view.getUint8(1), MOVEMENT_WIRE_SCHEMA);
  assert.equal(view.getUint32(2, false), 7);
  assert.equal(view.getUint32(6, false), 11);
  assert.equal(view.getUint16(10, false), 100);
  assert.equal(view.getFloat32(12, false), 0.5);
  assert.equal(view.getFloat32(16, false), -0.25);
  assert.equal(view.getFloat32(20, false), 1);
  assert.equal(view.getUint16(24, false), 4);
});

test("decodes current schema movement ack", () => {
  const buffer = new ArrayBuffer(121);
  const view = new DataView(buffer);
  view.setUint8(0, 0x8b);
  view.setUint8(1, MOVEMENT_WIRE_SCHEMA);
  view.setUint32(2, 7, false);
  view.setUint32(6, 22, false);
  view.setBigUint64(10, 1_780_000_000_100n, false);
  view.setBigUint64(18, 1_780_000_000_123n, false);
  view.setBigInt64(26, 42n, false);
  view.setFloat64(34, 1, false);
  view.setFloat64(42, 2, false);
  view.setFloat64(50, 3, false);
  view.setUint8(106, 1);
  view.setUint32(107, 4, false);
  view.setUint16(111, 100, false);
  view.setFloat64(113, 185, false);

  const ack = decodeMovementAck(view);

  assert.equal(ack.ackSeq, 7);
  assert.equal(ack.authTick, 22);
  assert.equal(ack.serverStateMs, 1_780_000_000_100);
  assert.equal(ack.serverSendMs, 1_780_000_000_123);
  assert.equal(ack.cid, 42);
  assert.deepEqual(ack.position, { x: 1, y: 2, z: 3 });
  assert.equal(ack.movementMode, "airborne");
  assert.equal(ack.correctionFlags, 4);
  assert.equal(ack.fixedDtMs, 100);
  assert.equal(ack.groundZ, 185);
});

test("decodes current schema player move with AOI priority metadata", () => {
  const buffer = new ArrayBuffer(114);
  const view = new DataView(buffer);
  view.setUint8(0, 0x83);
  view.setUint8(1, MOVEMENT_WIRE_SCHEMA);
  view.setBigInt64(2, 42n, false);
  view.setUint32(10, 22, false);
  view.setBigUint64(14, 1_780_000_000_100n, false);
  view.setBigUint64(22, 1_780_000_000_123n, false);
  view.setFloat64(30, 1, false);
  view.setFloat64(38, 2, false);
  view.setFloat64(46, 3, false);
  view.setUint8(102, 1);
  view.setUint8(103, 2);
  view.setFloat32(104, 0.75, false);
  view.setFloat32(108, 123.5, false);
  view.setUint16(112, 5, false);

  const move = decodePlayerMove(view);

  assert.equal(move.cid, 42);
  assert.equal(move.serverTick, 22);
  assert.equal(move.serverStateMs, 1_780_000_000_100);
  assert.equal(move.serverSendMs, 1_780_000_000_123);
  assert.deepEqual(move.position, { x: 1, y: 2, z: 3 });
  assert.equal(move.movementMode, "airborne");
  assert.deepEqual(move.priority, {
    band: "low",
    score: 0.75,
    distance: 123.5,
    interval: 5,
  });
});
