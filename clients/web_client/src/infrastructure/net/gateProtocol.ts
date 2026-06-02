import { Vector3 } from "three";
import {
  AoiPriorityBand,
  MovementMode,
  type MovementAck,
  type RemoteMoveSnapshot,
} from "@domain/movement/types";
import type { ChatMessage, ChatScope } from "@domain/chat/types";
import { MOVEMENT_WIRE_SCHEMA } from "./protocolVersion";

export interface ResultOkMessage {
  type: "result_ok";
  requestId: number;
}

export interface ResultErrorMessage {
  type: "result_error";
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
  // Pillar 1.1: wire protocol version echoed in the enter-scene handshake.
  // Client fail-fasts if this does not match PROTOCOL_VERSION.
  protocolVersion: number;
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

export interface ChatMessageFrame extends ChatMessage {
  type: "chat_message";
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
  | ResultOkMessage
  | ResultErrorMessage
  | EnterSceneOkMessage
  | EnterSceneErrorMessage
  | MovementAckMessage
  | RemoteMoveMessage
  | PlayerEnterMessage
  | PlayerLeaveMessage
  | PlayerStateMessage
  | ChatMessageFrame
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

export function encodeTimeSync(requestId: number, clientSendTs: number): Uint8Array {
  const buffer = new ArrayBuffer(1 + 8 + 8);
  const view = new DataView(buffer);
  view.setUint8(0, 0x03);
  writeU64(view, 1, requestId);
  writeU64(view, 9, clientSendTs);
  return new Uint8Array(buffer);
}

export function encodeChatSayScoped(requestId: number, scope: ChatScope, text: string): Uint8Array {
  const textBytes = encoder.encode(text);
  const buffer = new ArrayBuffer(1 + 8 + 1 + 2 + textBytes.length);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, 0x0a);
  offset += 1;
  writeU64(view, offset, requestId);
  offset += 8;
  view.setUint8(offset, encodeChatScope(scope));
  offset += 1;
  view.setUint16(offset, textBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, textBytes.length).set(textBytes);
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
  // Pillar 1.1: 1(opcode) + 1(schema_version) + 4(seq) + 4(client_tick) +
  //             2(dt_ms) + 4(input_dir_x) + 4(input_dir_y) + 4(speed_scale) +
  //             2(movement_flags) = 26 bytes
  const buffer = new ArrayBuffer(1 + 1 + 4 + 4 + 2 + 4 + 4 + 4 + 2);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, 0x01);
  offset += 1;
  view.setUint8(offset, MOVEMENT_WIRE_SCHEMA);
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
      if (!hasBytes(view, 10)) return null;
      const requestId = readU64(view, 1);
      const ok = view.getUint8(9) === 0;
      return ok ? { type: "result_ok", requestId } : { type: "result_error", requestId };
    }
    case 0x81:
      if (!hasBytes(view, 33)) return null;
      return {
        type: "player_enter",
        cid: readI64(view, 1),
        position: readServerVec3AsBrowserVec3(view, 9),
      };
    case 0x82:
      if (!hasBytes(view, 9)) return null;
      return {
        type: "player_leave",
        cid: readI64(view, 1),
      };
    case 0x84: {
      if (!hasBytes(view, 10)) return null;
      const requestId = readU64(view, 1);
      const ok = view.getUint8(9) === 0;
      if (!ok) {
        return { type: "enter_scene_error", requestId };
      }
      if (!hasBytes(view, 40)) return null;
      // Pillar 1.1 layout: packet_id(8) + ok(1) + vec3(24) +
      // expected_seq(u32) + protocol_version(u16). Total = 40 bytes.
      return {
        type: "enter_scene_ok",
        requestId,
        position: readServerVec3AsBrowserVec3(view, 10),
        expectedSeq: view.getUint32(34, false),
        protocolVersion: view.getUint16(38, false),
      };
    }
    case 0x8b:
      if (!hasBytes(view, 121)) return null;
      if (view.getUint8(1) !== MOVEMENT_WIRE_SCHEMA) return null;
      // Movement schema v2 layout (121 bytes):
      //   [0]   opcode (1)
      //   [1]   schema_version u8 (1)
      //   [2]   ack_seq u32 (4)
      //   [6]   auth_tick u32 (4)
      //   [10]  server_state_ms u64 (8)
      //   [18]  server_send_ms u64 (8)
      //   [26]  cid i64 (8)
      //   [34]  position vec3 f64×3 (24)
      //   [58]  velocity vec3 f64×3 (24)
      //   [82]  acceleration vec3 f64×3 (24)
      //   [106] movement_mode u8 (1)
      //   [107] correction_flags u32 (4)
      //   [111] fixed_dt_ms u16 (2)
      //   [113] ground_z f64 (8)
      // Total: 121 bytes
      return {
        type: "movement_ack",
        ack: {
          ackSeq: view.getUint32(2, false),
          authTick: view.getUint32(6, false),
          serverStateMs: Number(view.getBigUint64(10, false)),
          serverSendMs: Number(view.getBigUint64(18, false)),
          position: readServerVec3AsBrowserVec3(view, 34),
          velocity: readServerVec3AsBrowserVec3(view, 58),
          acceleration: readServerVec3AsBrowserVec3(view, 82),
          movementMode: decodeMovementMode(view.getUint8(106)),
          correctionFlags: view.getUint32(107, false),
          serverFixedDtMs: view.getUint16(111, false),
          // Phase A1-4: server's launch z (ground level for the current
          // airborne arc). Server maps z → browser y in readServerVec3AsBrowserVec3,
          // so we mirror the same convention here for groundY.
          groundY: view.getFloat64(113, false),
        },
      };
    case 0x83:
      if (!hasBytes(view, 103)) return null;
      if (view.getUint8(1) !== MOVEMENT_WIRE_SCHEMA) return null;
      // Movement schema v2 layout (compact 103B / complete 114B):
      //   [0]  opcode (1)
      //   [1]  schema_version u8 (1)
      //   [2]  cid u64 (8)
      //   [10] server_tick u32 (4)
      //   [14] server_state_ms u64 (8)
      //   [22] server_send_ms u64 (8)
      //   [30] pos vec3 f64×3 (24)
      //   [54] vel vec3 f64×3 (24)
      //   [78] accel vec3 f64×3 (24)
      //   [102] movement_mode u8 (1)
      //  [103+] optional: priority_band u8, priority_score f32,
      //         observer_distance f32, delivery_interval u16 (11 bytes)
      return {
        type: "player_move",
        snapshot: {
          cid: readI64(view, 2),
          serverTick: view.getUint32(10, false),
          serverStateMs: Number(view.getBigUint64(14, false)),
          serverSendMs: Number(view.getBigUint64(22, false)),
          position: readServerVec3AsBrowserVec3(view, 30),
          velocity: readServerVec3AsBrowserVec3(view, 54),
          acceleration: readServerVec3AsBrowserVec3(view, 78),
          movementMode: decodeMovementMode(view.getUint8(102)),
          ...decodeAoiPriority(view, 103),
        },
      };
    case 0x85:
      if (!hasBytes(view, 33)) return null;
      return {
        type: "time_sync_reply",
        requestId: readU64(view, 1),
        clientSendTs: readU64(view, 9),
        serverRecvTs: readU64(view, 17),
        serverSendTs: readU64(view, 25),
      };
    case 0x86:
      return { type: "heartbeat_reply" };
    case 0x89:
      return decodeChatMessage(view);
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
const decoder = new TextDecoder();

function encodeChatScope(scope: ChatScope): number {
  switch (scope) {
    case "region":
      return 1;
    case "local":
      return 2;
    default:
      return 0;
  }
}

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

function hasBytes(view: DataView, byteLength: number): boolean {
  return view.byteLength >= byteLength;
}

function readPrefixedString(view: DataView, offset: number): [string, number] | null {
  if (view.byteLength < offset + 2) {
    return null;
  }
  const length = view.getUint16(offset, false);
  const start = offset + 2;
  const end = start + length;
  if (view.byteLength < end) {
    return null;
  }
  const bytes = new Uint8Array(view.buffer, view.byteOffset + start, length);
  return [decoder.decode(bytes), end];
}

function decodeChatMessage(view: DataView): ChatMessageFrame | null {
  if (view.byteLength < 1 + 8 + 2) {
    return null;
  }
  const cid = readI64(view, 1);
  const usernameResult = readPrefixedString(view, 9);
  if (!usernameResult) {
    return null;
  }
  const [username, textOffset] = usernameResult;
  const textResult = readPrefixedString(view, textOffset);
  if (!textResult) {
    return null;
  }
  const [text, end] = textResult;
  if (end !== view.byteLength) {
    return null;
  }
  return { type: "chat_message", cid, username, text };
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

function decodeAoiPriority(view: DataView, offset: number): Partial<RemoteMoveSnapshot> {
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
