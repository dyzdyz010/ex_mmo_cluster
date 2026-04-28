import { Vector3 } from "three";
import {
  AoiPriorityBand,
  MovementMode,
  type MovementAck,
  type RemoteMoveSnapshot,
} from "@domain/movement/types";

export interface AuthOkMessage {
  type: "auth_ok";
  requestId: number;
}

export interface EnterSceneOkMessage {
  type: "enter_scene_ok";
  requestId: number;
  position: Vector3;
  // Audit B-S1 / B-SRV2 (bevy sweep 2026-04-26): server-side next-expected
  // movement input `seq`. The client must align its local input counter
  // to this value before sending any movement input, so the server's
  // first-seq validation accepts it.
  expectedSeq: number;
}

export interface EnterSceneErrorMessage {
  type: "enter_scene_error";
  requestId: number;
}

export interface MovementAckMessage {
  type: "movement_ack";
  ack: MovementAck;
}

export interface RemoteMoveMessage {
  type: "player_move";
  snapshot: RemoteMoveSnapshot;
}

export interface PlayerEnterMessage {
  type: "player_enter";
  cid: number;
  position: Vector3;
}

export interface PlayerLeaveMessage {
  type: "player_leave";
  cid: number;
}

export interface TimeSyncReplyMessage {
  type: "time_sync_reply";
  requestId: number;
  clientSendTs: number;
  serverRecvTs: number;
  serverSendTs: number;
}

export interface HeartbeatReplyMessage {
  type: "heartbeat_reply";
}

export type ServerGateMessage =
  | AuthOkMessage
  | EnterSceneOkMessage
  | EnterSceneErrorMessage
  | MovementAckMessage
  | RemoteMoveMessage
  | PlayerEnterMessage
  | PlayerLeaveMessage
  | TimeSyncReplyMessage
  | HeartbeatReplyMessage;

export function encodeAuthRequest(requestId: number, username: string, token: string): Uint8Array {
  const usernameBytes = encoder.encode(username);
  const tokenBytes = encoder.encode(token);
  const buffer = new ArrayBuffer(1 + 8 + 2 + usernameBytes.length + 2 + tokenBytes.length);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, 0x05);
  offset += 1;
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

export function encodeEnterScene(requestId: number, cid: number): Uint8Array {
  const buffer = new ArrayBuffer(1 + 8 + 8);
  const view = new DataView(buffer);
  view.setUint8(0, 0x02);
  writeU64(view, 1, requestId);
  writeI64(view, 9, cid);
  return new Uint8Array(buffer);
}

export function encodeHeartbeat(timestampMs: number): Uint8Array {
  const buffer = new ArrayBuffer(1 + 8);
  const view = new DataView(buffer);
  view.setUint8(0, 0x04);
  writeU64(view, 1, timestampMs);
  return new Uint8Array(buffer);
}

export function encodeMovementInput(frame: {
  seq: number;
  clientTick: number;
  dtMs: number;
  inputDir: { x: number; y: number };
  speedScale: number;
  movementFlags: number;
}): Uint8Array {
  const buffer = new ArrayBuffer(1 + 4 + 4 + 2 + 4 + 4 + 4 + 2);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, 0x01);
  offset += 1;
  view.setUint32(offset, frame.seq, false);
  offset += 4;
  view.setUint32(offset, frame.clientTick, false);
  offset += 4;
  view.setUint16(offset, frame.dtMs, false);
  offset += 2;
  view.setFloat32(offset, frame.inputDir.x, false);
  offset += 4;
  view.setFloat32(offset, frame.inputDir.y, false);
  offset += 4;
  view.setFloat32(offset, frame.speedScale, false);
  offset += 4;
  view.setUint16(offset, frame.movementFlags, false);
  return new Uint8Array(buffer);
}

export function decodeServerMessage(payload: ArrayBuffer): ServerGateMessage | null {
  const view = new DataView(payload);
  if (view.byteLength < 1) {
    return null;
  }

  const msgType = view.getUint8(0);
  switch (msgType) {
    case 0x80: {
      const requestId = readU64(view, 1);
      const ok = view.getUint8(9) === 0;
      return ok ? { type: "auth_ok", requestId } : null;
    }
    case 0x81:
      return {
        type: "player_enter",
        cid: readI64(view, 1),
        position: readServerVec3AsBrowserVec3(view, 9),
      };
    case 0x82:
      return {
        type: "player_leave",
        cid: readI64(view, 1),
      };
    case 0x84: {
      const requestId = readU64(view, 1);
      const ok = view.getUint8(9) === 0;
      if (!ok) {
        return { type: "enter_scene_error", requestId };
      }
      // Layout (audit B-S1 / B-SRV2): packet_id(8) + ok(1) + vec3(24) +
      // expected_seq(u32 BE). Total body = 37; with msg_type the frame is
      // 38 bytes.
      return {
        type: "enter_scene_ok",
        requestId,
        position: readServerVec3AsBrowserVec3(view, 10),
        expectedSeq: view.getUint32(34, false),
      };
    }
    case 0x8b:
      // Layout (audit B-M2): + trailing fixed_dt_ms u16 BE at body offset 93
      // (i.e. msg_type-relative offset 94). Total body = 95; frame = 96.
      return {
        type: "movement_ack",
        ack: {
          ackSeq: view.getUint32(1, false),
          authTick: view.getUint32(5, false),
          position: readServerVec3AsBrowserVec3(view, 17),
          velocity: readServerVec3AsBrowserVec3(view, 41),
          acceleration: readServerVec3AsBrowserVec3(view, 65),
          movementMode: decodeMovementMode(view.getUint8(89)),
          correctionFlags: view.getUint32(90, false),
          serverFixedDtMs: view.getUint16(94, false),
        },
      };
    case 0x83:
      return {
        type: "player_move",
        snapshot: {
          cid: readI64(view, 1),
          serverTick: view.getUint32(9, false),
          position: readServerVec3AsBrowserVec3(view, 13),
          velocity: readServerVec3AsBrowserVec3(view, 37),
          acceleration: readServerVec3AsBrowserVec3(view, 61),
          movementMode: decodeMovementMode(view.getUint8(85)),
          ...decodeAoiPriority(view, 86),
        },
      };
    case 0x85:
      return {
        type: "time_sync_reply",
        requestId: readU64(view, 1),
        clientSendTs: readU64(view, 9),
        serverRecvTs: readU64(view, 17),
        serverSendTs: readU64(view, 25),
      };
    case 0x86:
      return { type: "heartbeat_reply" };
    default:
      return null;
  }
}

const encoder = new TextEncoder();

function writeU64(view: DataView, offset: number, value: number): void {
  const big = BigInt(Math.max(0, Math.trunc(value)));
  view.setBigUint64(offset, big, false);
}

function writeI64(view: DataView, offset: number, value: number): void {
  const big = BigInt(Math.trunc(value));
  view.setBigInt64(offset, big, false);
}

function readU64(view: DataView, offset: number): number {
  return Number(view.getBigUint64(offset, false));
}

function readI64(view: DataView, offset: number): number {
  return Number(view.getBigInt64(offset, false));
}

function readVec3(view: DataView, offset: number): Vector3 {
  return new Vector3(
    view.getFloat64(offset, false),
    view.getFloat64(offset + 8, false),
    view.getFloat64(offset + 16, false),
  );
}

function readServerVec3AsBrowserVec3(view: DataView, offset: number): Vector3 {
  const server = readVec3(view, offset);
  return new Vector3(server.x, server.z, server.y);
}

function decodeMovementMode(raw: number): MovementMode {
  switch (raw) {
    case 1:
      return MovementMode.Airborne;
    case 2:
      return MovementMode.Disabled;
    case 3:
      return MovementMode.Scripted;
    default:
      return MovementMode.Grounded;
  }
}

function decodeAoiPriority(
  view: DataView,
  offset: number,
): Partial<RemoteMoveSnapshot> {
  if (view.byteLength < offset + 11) {
    return {};
  }

  return {
    priorityBand: decodePriorityBand(view.getUint8(offset)),
    priorityScore: view.getFloat32(offset + 1, false),
    observerDistance: view.getFloat32(offset + 5, false),
    deliveryInterval: view.getUint16(offset + 9, false),
  };
}

function decodePriorityBand(raw: number) {
  switch (raw) {
    case 1:
      return AoiPriorityBand.Medium;
    case 2:
      return AoiPriorityBand.Low;
    default:
      return AoiPriorityBand.High;
  }
}
