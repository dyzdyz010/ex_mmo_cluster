import { Vector3 } from "three";
import { LocalPredictionRuntime } from "@domain/movement/localPlayer";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";
import { CorrectionFlag, type MoveInputFrame, type RemoteMoveSnapshot } from "@domain/movement/types";
import type {
  MovementTransport,
  MovementTransportTickResult,
  PendingMovementAck,
} from "@domain/movement/transport";

interface QueuedAck {
  frame: MoveInputFrame;
  sentAtMs: number;
  deliverAtMs: number;
}

interface QueuedRemoteSnapshot {
  snapshot: RemoteMoveSnapshot;
  deliverAtMs: number;
}

/**
 * Offline fallback adapter. Synthesizes authoritative acks by running the
 * same predictor locally, clamps to a square arena, and drives a decorative
 * remote actor on a circular path so the HUD / remote interpolator stay busy.
 */
export class SimulatedLocalMovementTransport implements MovementTransport {
  readonly mode = "simulated-local";

  private readonly pendingAcks: QueuedAck[] = [];
  private readonly pendingSnapshots: QueuedRemoteSnapshot[] = [];
  private readonly authoritativeState = new Vector3();
  private authoritativeRuntime = new LocalPredictionRuntime();
  private serverTick = 0;
  private accumulatorMs = 0;

  isReady(): boolean {
    return true;
  }

  debugSnapshot(): Record<string, unknown> {
    return {
      mode: this.mode,
      ready: true,
      pendingAcknowledgements: this.pendingAcks.length,
      pendingRemoteSnapshots: this.pendingSnapshots.length,
    };
  }

  reset(position: Vector3): void {
    this.pendingAcks.splice(0, this.pendingAcks.length);
    this.pendingSnapshots.splice(0, this.pendingSnapshots.length);
    this.authoritativeState.copy(position);
    this.authoritativeRuntime = new LocalPredictionRuntime();
    this.authoritativeRuntime.reset(position);
    this.serverTick = 0;
    this.accumulatorMs = 0;
  }

  sendInput(frame: MoveInputFrame, nowMs: number): void {
    const seqJitter = Math.sin(frame.seq * 0.63) * 18;
    const oneWayDelay = 75 + seqJitter + (frame.seq % 5) * 7;
    this.pendingAcks.push({
      frame,
      sentAtMs: nowMs,
      deliverAtMs: nowMs + Math.max(35, oneWayDelay),
    });
  }

  tick(nowMs: number, dtMs: number): MovementTransportTickResult {
    return {
      acknowledgements: this.consumeAcknowledgements(nowMs),
      remoteSnapshots: this.consumeRemoteSnapshots(nowMs, dtMs),
      spawnPosition: null,
    };
  }

  private consumeAcknowledgements(nowMs: number): PendingMovementAck[] {
    const due = this.pendingAcks
      .filter((item) => item.deliverAtMs <= nowMs)
      .sort((a, b) => a.deliverAtMs - b.deliverAtMs || a.frame.seq - b.frame.seq);

    const remaining = this.pendingAcks.filter((item) => item.deliverAtMs > nowMs);
    this.pendingAcks.splice(0, this.pendingAcks.length, ...remaining);

    const delivered: PendingMovementAck[] = [];
    for (const item of due) {
      const predicted = this.authoritativeRuntime.applyLocalInput(item.frame);
      if (!predicted) {
        continue;
      }

      let correctionFlags = CorrectionFlag.None;
      const correctedPosition = predicted.position.clone();
      const correctedVelocity = predicted.velocity.clone();

      if (correctedPosition.x > 900) {
        correctedPosition.x = 900;
        correctedVelocity.x = 0;
        correctionFlags |= CorrectionFlag.CollisionPush;
      }
      if (correctedPosition.x < -900) {
        correctedPosition.x = -900;
        correctedVelocity.x = 0;
        correctionFlags |= CorrectionFlag.CollisionPush;
      }
      if (correctedPosition.z > 900) {
        correctedPosition.z = 900;
        correctedVelocity.z = 0;
        correctionFlags |= CorrectionFlag.CollisionPush;
      }
      if (correctedPosition.z < -900) {
        correctedPosition.z = -900;
        correctedVelocity.z = 0;
        correctionFlags |= CorrectionFlag.CollisionPush;
      }

      delivered.push({
        sentAtMs: item.sentAtMs,
        ack: {
          ackSeq: item.frame.seq,
          authTick: item.frame.clientTick,
          position: correctedPosition,
          velocity: correctedVelocity,
          acceleration: predicted.acceleration.clone(),
          correctionFlags,
        },
      });
    }

    return delivered;
  }

  private consumeRemoteSnapshots(nowMs: number, dtMs: number): RemoteMoveSnapshot[] {
    this.accumulatorMs += dtMs;
    while (this.accumulatorMs >= DEFAULT_MOVEMENT_PROFILE.fixedDtMs) {
      this.accumulatorMs -= DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
      this.serverTick += 1;

      const timeSecs = this.serverTick * (DEFAULT_MOVEMENT_PROFILE.fixedDtMs / 1000);
      const angle = timeSecs * 0.8;
      const radiusX = 650;
      const radiusZ = 420;
      const position = new Vector3(Math.cos(angle) * radiusX, 650, Math.sin(angle) * radiusZ);
      const velocity = new Vector3(-Math.sin(angle) * radiusX * 0.8, 0, Math.cos(angle) * radiusZ * 0.8);
      const acceleration = new Vector3(-Math.cos(angle) * radiusX * 0.64, 0, -Math.sin(angle) * radiusZ * 0.64);

      const seqJitter = Math.cos(this.serverTick * 0.47) * 14;
      this.pendingSnapshots.push({
        snapshot: {
          cid: 42002,
          serverTick: this.serverTick,
          position,
          velocity,
          acceleration,
        },
        deliverAtMs: nowMs + 90 + Math.max(0, seqJitter),
      });
    }

    const due = this.pendingSnapshots.filter((item) => item.deliverAtMs <= nowMs).map((item) => item.snapshot);
    const remaining = this.pendingSnapshots.filter((item) => item.deliverAtMs > nowMs);
    this.pendingSnapshots.splice(0, this.pendingSnapshots.length, ...remaining);
    return due;
  }
}
