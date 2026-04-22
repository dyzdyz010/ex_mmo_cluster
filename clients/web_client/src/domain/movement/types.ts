import { Vector2, Vector3 } from "three";

export const MovementFlag = {
  None: 0,
  Brake: 1 << 0,
} as const;

export const CorrectionFlag = {
  None: 0,
  Teleport: 1 << 0,
  CollisionPush: 1 << 1,
  AntiCheatReject: 1 << 2,
  StatusOverride: 1 << 3,
} as const;

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
}

export interface MovementAck {
  ackSeq: number;
  authTick: number;
  position: Vector3;
  velocity: Vector3;
  acceleration: Vector3;
  correctionFlags: number;
}

export interface RemoteMoveSnapshot {
  cid: number;
  serverTick: number;
  position: Vector3;
  velocity: Vector3;
  acceleration: Vector3;
}

export function makeIdleState(position: Vector3): PredictedMoveState {
  return {
    seq: 0,
    tick: 0,
    position: position.clone(),
    velocity: new Vector3(),
    acceleration: new Vector3(),
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
  };
}

export function cloneMovementAck(ack: MovementAck): MovementAck {
  return {
    ackSeq: ack.ackSeq,
    authTick: ack.authTick,
    position: ack.position.clone(),
    velocity: ack.velocity.clone(),
    acceleration: ack.acceleration.clone(),
    correctionFlags: ack.correctionFlags,
  };
}

export function cloneRemoteMoveSnapshot(snapshot: RemoteMoveSnapshot): RemoteMoveSnapshot {
  return {
    cid: snapshot.cid,
    serverTick: snapshot.serverTick,
    position: snapshot.position.clone(),
    velocity: snapshot.velocity.clone(),
    acceleration: snapshot.acceleration.clone(),
  };
}
