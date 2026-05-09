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

export interface PlayerStateMessage {
  type: "player_state";
  cid: number;
  hp: number;
  maxHp: number;
  alive: boolean;
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

export interface KnownUnhandledDownlinkMessage {
  type: "known_unhandled_downlink";
  opcode: number;
  name: string;
  byteLength: number;
}

export type ServerGateMessage =
  | AuthOkMessage
  | EnterSceneOkMessage
  | EnterSceneErrorMessage
  | MovementAckMessage
  | RemoteMoveMessage
  | PlayerEnterMessage
  | PlayerLeaveMessage
  | PlayerStateMessage
  | TimeSyncReplyMessage
  | HeartbeatReplyMessage
  | KnownUnhandledDownlinkMessage;

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
      // Layout (audit B-M2 + Phase A1-4): + trailing fixed_dt_ms u16 BE at
      // body offset 93 + ground_z f64 BE at body offset 95. Frame layout:
      //   [0]  opcode (1)
      //   [1]  ack_seq u32 (4)
      //   [5]  auth_tick u32 (4)
      //   [9]  cid i64 (8)              ← client doesn't decode (player owns own ack)
      //   [17] position vec3 f64×3 (24)
      //   [41] velocity vec3 f64×3 (24)
      //   [65] acceleration vec3 f64×3 (24)
      //   [89] movement_mode u8 (1)
      //   [90] correction_flags u32 (4)
      //   [94] fixed_dt_ms u16 (2)
      //   [96] ground_z f64 (8)         ← Phase A1-4
      // Total: 104 bytes (1 opcode + 103 body).
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
          // Phase A1-4: server's launch z (ground level for the current
          // airborne arc). Server maps z → browser y in readServerVec3AsBrowserVec3,
          // so we mirror the same convention here for groundY.
          groundY: view.getFloat64(96, false),
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
    case 0x8c:
      if (view.byteLength !== 14) {
        return null;
      }
      return {
        type: "player_state",
        cid: readI64(view, 1),
        hp: view.getUint16(9, false),
        maxHp: view.getUint16(11, false),
        alive: view.getUint8(13) !== 0,
      };
    default: {
      const name = knownUnhandledDownlinkName(msgType);
      return name
        ? { type: "known_unhandled_downlink", opcode: msgType, name, byteLength: view.byteLength }
        : null;
    }
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

function knownUnhandledDownlinkName(opcode: number): string | null {
  switch (opcode) {
    case 0x87:
      return "fast_lane_result";
    case 0x88:
      return "fast_lane_attached";
    case 0x89:
      return "chat_message";
    case 0x8a:
      return "skill_event";
    case 0x8d:
      return "combat_hit";
    case 0x8e:
      return "actor_identity";
    case 0x8f:
      return "effect_event";
    default:
      return null;
  }
}
