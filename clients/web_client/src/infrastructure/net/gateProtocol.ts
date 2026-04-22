import { Vector3 } from "three";
import type { MovementAck, RemoteMoveSnapshot } from "@domain/movement/types";

export interface AuthOkMessage {
  type: "auth_ok";
  requestId: number;
}

export interface EnterSceneOkMessage {
  type: "enter_scene_ok";
  requestId: number;
  position: Vector3;
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

export interface HeartbeatReplyMessage {
  type: "heartbeat_reply";
}

export type ServerGateMessage =
  | AuthOkMessage
  | EnterSceneOkMessage
  | EnterSceneErrorMessage
  | MovementAckMessage
  | RemoteMoveMessage
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
    case 0x84: {
      const requestId = readU64(view, 1);
      const ok = view.getUint8(9) === 0;
      if (!ok) {
        return { type: "enter_scene_error", requestId };
      }
      return {
        type: "enter_scene_ok",
        requestId,
        position: readServerVec3AsBrowserVec3(view, 10),
      };
    }
    case 0x8B:
      return {
        type: "movement_ack",
        ack: {
          ackSeq: view.getUint32(1, false),
          authTick: view.getUint32(5, false),
          position: readServerVec3AsBrowserVec3(view, 17),
          velocity: readServerVec3AsBrowserVec3(view, 41),
          acceleration: readServerVec3AsBrowserVec3(view, 65),
          correctionFlags: view.getUint32(90, false),
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
        },
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
