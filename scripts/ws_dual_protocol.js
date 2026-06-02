const MOVEMENT_WIRE_SCHEMA = 2;

const MovementFlag = {
  None: 0,
  Brake: 1 << 1,
  Jump: 1 << 2,
};

const enc = new TextEncoder();
const dec = new TextDecoder();

function writeU64(view, offset, value) {
  view.setBigUint64(offset, BigInt(value), false);
}

function writeI64(view, offset, value) {
  view.setBigInt64(offset, BigInt(value), false);
}

function encodeAuth(requestId, username, token) {
  const usernameBytes = enc.encode(username);
  const tokenBytes = enc.encode(token);
  const buffer = new ArrayBuffer(1 + 8 + 2 + usernameBytes.length + 2 + tokenBytes.length);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset++, 0x05);
  writeU64(view, offset, requestId);
  offset += 8;
  view.setUint16(offset, usernameBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, usernameBytes.length).set(usernameBytes);
  offset += usernameBytes.length;
  view.setUint16(offset, tokenBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, tokenBytes.length).set(tokenBytes);
  return new Uint8Array(buffer);
}

function encodeEnterScene(requestId, cid) {
  const buffer = new ArrayBuffer(17);
  const view = new DataView(buffer);
  view.setUint8(0, 0x02);
  writeU64(view, 1, requestId);
  writeI64(view, 9, cid);
  return new Uint8Array(buffer);
}

function encodeMove({ seq, clientTick, dx, dy, flags }) {
  const buffer = new ArrayBuffer(26);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset++, 0x01);
  view.setUint8(offset++, MOVEMENT_WIRE_SCHEMA);
  view.setUint32(offset, seq, false);
  offset += 4;
  view.setUint32(offset, clientTick, false);
  offset += 4;
  view.setUint16(offset, 100, false);
  offset += 2;
  view.setFloat32(offset, dx, false);
  offset += 4;
  view.setFloat32(offset, dy, false);
  offset += 4;
  view.setFloat32(offset, 1, false);
  offset += 4;
  view.setUint16(offset, flags, false);
  return new Uint8Array(buffer);
}

function vec3(view, offset) {
  return {
    x: view.getFloat64(offset, false),
    y: view.getFloat64(offset + 8, false),
    z: view.getFloat64(offset + 16, false),
  };
}

function formatVec3(position) {
  return `${position.x.toFixed(1)},${position.y.toFixed(1)},${position.z.toFixed(1)}`;
}

function decodeMovementMode(raw) {
  if (raw === 1) return "airborne";
  if (raw === 2) return "disabled";
  if (raw === 3) return "scripted";
  return "grounded";
}

function decodePriorityBand(raw) {
  if (raw === 1) return "medium";
  if (raw === 2) return "low";
  return "high";
}

function decodeAoiPriority(view, offset) {
  if (view.byteLength < offset + 11) {
    return null;
  }

  return {
    band: decodePriorityBand(view.getUint8(offset)),
    score: view.getFloat32(offset + 1, false),
    distance: view.getFloat32(offset + 5, false),
    interval: view.getUint16(offset + 9, false),
  };
}

function decodeEnterScene(view) {
  return {
    requestId: Number(view.getBigUint64(1, false)),
    ok: view.getUint8(9) === 0,
    position: vec3(view, 10),
    expectedSeq: view.byteLength >= 38 ? view.getUint32(34, false) : 1,
    protocolVersion: view.byteLength >= 40 ? view.getUint16(38, false) : null,
  };
}

function decodeMovementAck(view) {
  return {
    ackSeq: view.getUint32(2, false),
    authTick: view.getUint32(6, false),
    serverStateMs: Number(view.getBigUint64(10, false)),
    serverSendMs: Number(view.getBigUint64(18, false)),
    cid: Number(view.getBigInt64(26, false)),
    position: vec3(view, 34),
    velocity: vec3(view, 58),
    acceleration: vec3(view, 82),
    movementMode: decodeMovementMode(view.getUint8(106)),
    correctionFlags: view.getUint32(107, false),
    fixedDtMs: view.getUint16(111, false),
    groundZ: view.getFloat64(113, false),
  };
}

function decodePlayerMove(view) {
  return {
    cid: Number(view.getBigInt64(2, false)),
    serverTick: view.getUint32(10, false),
    serverStateMs: Number(view.getBigUint64(14, false)),
    serverSendMs: Number(view.getBigUint64(22, false)),
    position: vec3(view, 30),
    velocity: vec3(view, 54),
    acceleration: vec3(view, 78),
    movementMode: decodeMovementMode(view.getUint8(102)),
    priority: decodeAoiPriority(view, 103),
  };
}

function decodePlayerState(view) {
  return {
    cid: Number(view.getBigInt64(1, false)),
    hp: view.getUint16(9, false),
    maxHp: view.getUint16(11, false),
    alive: view.getUint8(13) !== 0,
  };
}

function decodeActorIdentity(view) {
  const nameLength = view.byteLength >= 12 ? view.getUint16(10, false) : 0;
  const name =
    view.byteLength >= 12 + nameLength
      ? dec.decode(new Uint8Array(view.buffer, view.byteOffset + 12, nameLength))
      : "";
  return {
    cid: Number(view.getBigInt64(1, false)),
    actorKind: decodeActorKind(view.getUint8(9)),
    name,
  };
}

function decodeActorKind(raw) {
  if (raw === 1) return "npc";
  if (raw === 2) return "monster";
  if (raw === 3) return "object";
  return "player";
}

function knownDownlinkName(msgType) {
  if (msgType === 0x87) return "fast_lane_result";
  if (msgType === 0x88) return "fast_lane_attached";
  if (msgType === 0x89) return "chat_message";
  if (msgType === 0x8a) return "skill_event";
  if (msgType === 0x8d) return "combat_hit";
  if (msgType === 0x8f) return "effect_event";
  return null;
}

module.exports = {
  MOVEMENT_WIRE_SCHEMA,
  MovementFlag,
  encodeAuth,
  encodeEnterScene,
  encodeMove,
  decodeEnterScene,
  decodeMovementAck,
  decodePlayerMove,
  decodePlayerState,
  decodeActorIdentity,
  formatVec3,
  knownDownlinkName,
};
