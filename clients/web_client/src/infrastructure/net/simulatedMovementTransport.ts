import { Vector3 } from "three";
import { LocalPredictionRuntime } from "@domain/movement/localPlayer";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";
import {
  CorrectionFlag,
  type MoveInputFrame,
} from "@domain/movement/types";
import type {
  MovementTransport,
  MovementTransportTickResult,
  PendingMovementAck,
} from "@domain/movement/transport";

interface QueuedAck {
  ack: PendingMovementAck;
  deliverAtMs: number;
}

/**
 * Offline fallback adapter. Synthesizes authoritative acks by running the
 * same predictor locally and clamps to a square arena.
 */
export class SimulatedLocalMovementTransport implements MovementTransport {
  readonly mode = "simulated-local";

  private readonly pendingAcks: QueuedAck[] = [];
  private readonly authoritativeState = new Vector3();
  private authoritativeRuntime = new LocalPredictionRuntime();

  isReady(): boolean {
    return true;
  }

  debugSnapshot(): Record<string, unknown> {
    return {
      mode: this.mode,
      ready: true,
      pendingAcknowledgements: this.pendingAcks.length,
      pendingRemoteSnapshots: 0,
      decorativeRemoteActor: false,
    };
  }

  reset(position: Vector3): void {
    this.pendingAcks.splice(0, this.pendingAcks.length);
    this.authoritativeState.copy(position);
    this.authoritativeRuntime = new LocalPredictionRuntime();
    this.authoritativeRuntime.reset(position);
  }

  sendInput(frame: MoveInputFrame, nowMs: number): void {
    const predicted = this.authoritativeRuntime.applyLocalInput(frame);
    if (!predicted) {
      return;
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

    this.pendingAcks.push({
      ack: {
        sentAtMs: nowMs,
        ack: {
          ackSeq: frame.seq,
          authTick: frame.clientTick,
          // Pillar 1.1: simulated transport uses local wall-clock as a
          // stand-in; the real value is injected by the server send site.
          serverSendMs: Date.now(),
          position: correctedPosition,
          velocity: correctedVelocity,
          acceleration: predicted.acceleration.clone(),
          movementMode: predicted.movementMode,
          correctionFlags,
          // Audit B-M2: simulated transport reports the same fixed_dt_ms
          // the local profile uses, so drift detection is a no-op here
          // by construction.
          serverFixedDtMs: DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
          // Phase A1-4: simulated transport mirrors the predicted state's
          // groundY so reconcile sees a consistent value(没有真实 server
          // launch_ground_z 概念,直接 echo predicted.groundY)。
          groundY: predicted.groundY,
        },
      },
      deliverAtMs: nowMs,
    });
  }

  tick(nowMs: number, dtMs: number): MovementTransportTickResult {
    void dtMs;
    return {
      acknowledgements: this.consumeAcknowledgements(nowMs),
      remoteSnapshots: [],
      // Simulated transport never produces a spawn handshake — there is
      // no enter_scene round trip to mirror.
      spawn: null,
    };
  }

  private consumeAcknowledgements(nowMs: number): PendingMovementAck[] {
    const due = this.pendingAcks
      .filter((item) => item.deliverAtMs <= nowMs)
      .sort((a, b) => a.ack.ack.ackSeq - b.ack.ack.ackSeq);

    const remaining = this.pendingAcks.filter((item) => item.deliverAtMs > nowMs);
    this.pendingAcks.splice(0, this.pendingAcks.length, ...remaining);

    return due.map((item) => item.ack);
  }
}
