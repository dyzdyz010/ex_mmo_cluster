import type { Vector3 } from "three";
import type { MoveInputFrame, MovementAck, RemoteMoveSnapshot } from "./types";

export interface PendingMovementAck {
  ack: MovementAck;
  sentAtMs: number;
}

export interface MovementTransportTickResult {
  acknowledgements: PendingMovementAck[];
  remoteSnapshots: RemoteMoveSnapshot[];
  spawnPosition: Vector3 | null;
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
