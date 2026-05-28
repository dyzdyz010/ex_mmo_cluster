import { type Vector2, Vector3 } from "three";

export const MovementFlag = {
  None: 0,
  Run: 1 << 0,
  Brake: 1 << 1,
  Jump: 1 << 2,
} as const;

export const CorrectionFlag = {
  None: 0,
  Teleport: 1 << 0,
  CollisionPush: 1 << 1,
  StatusOverride: 1 << 2,
  AntiCheatReject: 1 << 3,
} as const;

export const MovementMode = {
  Grounded: "grounded",
  Airborne: "airborne",
  Scripted: "scripted",
  Disabled: "disabled",
} as const;

export type MovementMode = (typeof MovementMode)[keyof typeof MovementMode];

export const AoiPriorityBand = {
  High: "high",
  Medium: "medium",
  Low: "low",
} as const;

export type AoiPriorityBand = (typeof AoiPriorityBand)[keyof typeof AoiPriorityBand];

export interface MoveInputFrame {
  seq: number;
  clientTick: number;
  dtMs: number;
  inputDir: Vector2;
  speedScale: number;
  movementFlags: number;
}

export interface PredictedMoveState {
  seq: number;
  tick: number;
  position: Vector3;
  velocity: Vector3;
  acceleration: Vector3;
  movementMode: MovementMode;
  groundY: number;
}

export interface MovementAck {
  ackSeq: number;
  authTick: number;
  // Pillar 1.1: wall-clock send timestamp (ms) injected by the server at
  // the send site. Stored here; consumed by the interpolation time-axis in
  // pillar 1.3.
  serverSendMs: number;
  position: Vector3;
  velocity: Vector3;
  acceleration: Vector3;
  movementMode: MovementMode;
  // Phase A1-4: server now authoritatively echos ground_z(launch level for
  // current airborne arc)on every ack。required field — wire format always
  // carries it,client predictor's stepAirborne 必须按此值落地。
  groundY: number;
  correctionFlags: number;
  // Audit B-M2 (bevy sweep 2026-04-26): server-authoritative fixed-tick
  // interval (ms) echoed in every ack. Used to detect MovementProfile
  // drift before it accumulates into prediction error.
  serverFixedDtMs: number;
}

export interface RemoteMoveSnapshot {
  cid: number;
  serverTick: number;
  // Pillar 1.1: wall-clock send timestamp (ms) injected by the server at
  // the send site. Stored here; consumed by the interpolation time-axis in
  // pillar 1.3.
  serverSendMs: number;
  position: Vector3;
  velocity: Vector3;
  acceleration: Vector3;
  movementMode: MovementMode;
  priorityBand?: AoiPriorityBand;
  priorityScore?: number;
  observerDistance?: number;
  deliveryInterval?: number;
}

export function makeIdleState(position: Vector3): PredictedMoveState {
  return {
    seq: 0,
    tick: 0,
    position: position.clone(),
    velocity: new Vector3(),
    acceleration: new Vector3(),
    movementMode: MovementMode.Grounded,
    groundY: position.y,
  };
}

export function cloneMoveInputFrame(frame: MoveInputFrame): MoveInputFrame {
  return {
    seq: frame.seq,
    clientTick: frame.clientTick,
    dtMs: frame.dtMs,
    inputDir: frame.inputDir.clone(),
    speedScale: frame.speedScale,
    movementFlags: frame.movementFlags,
  };
}

export function clonePredictedMoveState(state: PredictedMoveState): PredictedMoveState {
  return {
    seq: state.seq,
    tick: state.tick,
    position: state.position.clone(),
    velocity: state.velocity.clone(),
    acceleration: state.acceleration.clone(),
    movementMode: state.movementMode,
    groundY: state.groundY,
  };
}

export function cloneMovementAck(ack: MovementAck): MovementAck {
  const cloned: MovementAck = {
    ackSeq: ack.ackSeq,
    authTick: ack.authTick,
    serverSendMs: ack.serverSendMs,
    position: ack.position.clone(),
    velocity: ack.velocity.clone(),
    acceleration: ack.acceleration.clone(),
    movementMode: ack.movementMode,
    correctionFlags: ack.correctionFlags,
    serverFixedDtMs: ack.serverFixedDtMs,
    groundY: ack.groundY,
  };
  return cloned;
}

export function cloneRemoteMoveSnapshot(snapshot: RemoteMoveSnapshot): RemoteMoveSnapshot {
  const cloned: RemoteMoveSnapshot = {
    cid: snapshot.cid,
    serverTick: snapshot.serverTick,
    serverSendMs: snapshot.serverSendMs,
    position: snapshot.position.clone(),
    velocity: snapshot.velocity.clone(),
    acceleration: snapshot.acceleration.clone(),
    movementMode: snapshot.movementMode,
  };
  if (snapshot.priorityBand !== undefined) cloned.priorityBand = snapshot.priorityBand;
  if (snapshot.priorityScore !== undefined) cloned.priorityScore = snapshot.priorityScore;
  if (snapshot.observerDistance !== undefined) cloned.observerDistance = snapshot.observerDistance;
  if (snapshot.deliveryInterval !== undefined) cloned.deliveryInterval = snapshot.deliveryInterval;
  return cloned;
}
