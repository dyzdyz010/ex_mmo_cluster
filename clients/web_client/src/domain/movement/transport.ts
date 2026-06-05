import type { Vector3 } from "three";
import type { MoveInputFrame, MovementAck, RemoteMoveSnapshot } from "./types";

export interface PendingMovementAck {
  ack: MovementAck;
  sentAtMs: number;
  receivedAtMs?: number;
}

export interface SpawnInfo {
  position: Vector3;
  // Audit B-S1 / B-SRV2: server-reported next-input seq for this spawn.
  expectedSeq: number;
}

export interface RemoteEntityEnter {
  cid: number;
  position: Vector3;
}

export interface TimeSyncSample {
  requestId: number;
  clientSendTs: number;
  serverRecvTs: number;
  serverSendTs: number;
}

export interface MovementTransportTickResult {
  acknowledgements: PendingMovementAck[];
  remoteSnapshots: RemoteMoveSnapshot[];
  spawn: SpawnInfo | null;
  remoteEntityEnters?: RemoteEntityEnter[];
  remoteEntityLeaves?: number[];
  timeSyncSamples?: TimeSyncSample[];
}

/**
 * Port the movement domain depends on. Infrastructure supplies concrete
 * adapters (simulated-local, server-ws). The domain never imports adapters;
 * composition root wires one in.
 */
export interface MovementTransport {
  readonly mode: string;
  isReady(): boolean;
  debugSnapshot(): Record<string, unknown>;
  reset(position: Vector3): void;
  sendInput(frame: MoveInputFrame, nowMs: number): void;
  tick(nowMs: number, dtMs: number): MovementTransportTickResult;
}
