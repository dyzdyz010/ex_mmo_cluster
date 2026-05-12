import { Vector3 } from "three";
import { LocalPredictionRuntime } from "@domain/movement/localPlayer";
import { ReplayAction } from "@domain/movement/governance";
import { step } from "@domain/movement/predictor";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";
import {
  MovementFlag,
  MovementMode,
  type MovementAck,
  type MoveInputFrame,
  type PredictedMoveState,
} from "@domain/movement/types";
import {
  buildMovementWorldDirection,
  keysToAxes,
} from "@domain/movement/inputDirection";
import { makeFallbackLocalSpawn } from "../spawn";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FrameSubscriber } from "../gameLoop";
import type { InputController } from "./inputController";
import type { TransportPump } from "./transportPump";

const LOCAL_RENDER_SMOOTHING_RATE_HZ = 15;
const LOCAL_VISUAL_HARD_SNAP_DISTANCE = 256;

export interface MovementFrameTraceSample {
  frame: number;
  nowMs: number;
  dtMs: number;
  fixedSteps: number;
  renderedX: number;
  renderedY: number;
  renderedZ: number;
  deltaX: number;
  deltaY: number;
  deltaZ: number;
  deltaDistance: number;
  pendingCorrectionDistance: number;
  accumulatorMs: number;
  movementMode: string;
  velocityY: number;
}

/**
 * Owns local-player prediction, reconciliation, and the render-anchor buffer
 * that visually damps corrections so the player never teleports on screen.
 *
 * Logic stays on a 100 ms fixed step for input/authority parity, but render
 * samples are advanced every frame by replaying the in-progress remainder
 * against the latest predicted anchor. This fills the 10 Hz gaps without
 * changing transport cadence.
 */
export class LocalPlayerController implements FrameSubscriber {
  private readonly prediction = new LocalPredictionRuntime();
  private readonly renderAnchor = new Vector3();
  private readonly renderedPosition = new Vector3();
  private readonly pendingCorrection = new Vector3();
  private readonly authoritativePosition = new Vector3();
  private readonly lastTracedPosition = new Vector3();
  private readonly frameTraceSamples: MovementFrameTraceSample[] = [];
  private fixedStepAccumulatorMs = 0;
  private cameraYawResolver: () => number = () => 0;
  private frameTraceRemaining = 0;
  private renderSimulationState: PredictedMoveState | null = null;
  private lastInputBlockedAtMs = Number.NEGATIVE_INFINITY;

  constructor(
    private readonly bus: EventBus<AppEvents>,
    private readonly input: InputController,
    private readonly transport: TransportPump,
    initialPosition: Vector3 = makeFallbackLocalSpawn(),
  ) {
    this.resetTo(initialPosition);
    // Audit B-S1 / B-SRV2: spawn handshake carries the server's
    // expectedSeq; pass it through so the local input counter aligns
    // with what the server is going to validate against.
    this.bus.on("transport:spawn", ({ position, expectedSeq }) =>
      this.resetTo(position, expectedSeq),
    );
    this.bus.on("transport:ack-delivered", ({ ack, sentAtMs }) => {
      this.consumeAuthority(performance.now(), ack, sentAtMs);
    });
  }

  onFrame(nowMs: number, dtMs: number): void {
    let fixedSteps = 0;
    this.fixedStepAccumulatorMs += dtMs;
    while (this.fixedStepAccumulatorMs >= DEFAULT_MOVEMENT_PROFILE.fixedDtMs) {
      this.fixedStepAccumulatorMs -= DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
      this.stepFixed(nowMs);
      fixedSteps += 1;
    }
    this.dampenPendingCorrection(dtMs / 1000);
    this.advanceRenderedPrediction(dtMs);
    this.captureFrameTrace(nowMs, dtMs, fixedSteps);
  }

  getRenderedPosition(): Vector3 {
    return this.renderedPosition;
  }

  getAuthoritativePosition(): Vector3 {
    return this.authoritativePosition;
  }

  getPendingCorrection(): Vector3 {
    return this.pendingCorrection;
  }

  startFrameTrace(maxFrames: number): void {
    this.frameTraceSamples.length = 0;
    this.frameTraceRemaining = Math.max(1, Math.floor(maxFrames));
    this.lastTracedPosition.copy(this.renderedPosition);
  }

  clearFrameTrace(): void {
    this.frameTraceSamples.length = 0;
    this.frameTraceRemaining = 0;
  }

  getFrameTrace(): { active: boolean; samples: MovementFrameTraceSample[] } {
    return {
      active: this.frameTraceRemaining > 0,
      samples: this.frameTraceSamples.map((sample) => ({ ...sample })),
    };
  }

  getCurrentState(): PredictedMoveState | null {
    return this.prediction.getCurrentState();
  }

  getGovernanceStats(): ReturnType<LocalPredictionRuntime["getGovernanceStats"]> {
    return this.prediction.getGovernanceStats();
  }

  getCurrentJitterMs(): number {
    return this.prediction.getCurrentJitterMs();
  }

  getCurrentSoftPositionError(): number {
    return this.prediction.getCurrentSoftPositionError();
  }

  setCameraYawResolver(resolver: () => number): void {
    this.cameraYawResolver = resolver;
  }

  requestJump(source = "cli"): void {
    this.input.requestJump(source);
  }

  private stepFixed(nowMs: number): void {
    const inputDir = buildMovementWorldDirection(
      keysToAxes(this.input.getMovementKeys()),
      this.cameraYawResolver(),
    );
    if (!this.transport.isReady()) {
      this.emitInputBlockedIfActive(nowMs);
      return;
    }

    const jumpRequested = this.input.consumeJumpPressed();
    const frame = this.prediction.buildInputFrame(
      inputDir,
      DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
      1,
      jumpRequested,
    );
    const predicted = this.prediction.applyLocalInput(frame);
    if (!predicted) return;

    if (jumpRequested || this.renderSimulationState?.movementMode !== predicted.movementMode) {
      this.syncRenderAnchorTo(predicted);
    } else {
      this.renderAnchor.copy(predicted.position);
    }
    this.transport.sendInput(frame, nowMs);

    this.bus.emit("movement:local-step", {
      seq: frame.seq,
      clientTick: frame.clientTick,
      position: predicted.position,
      velocity: predicted.velocity,
      movementFlags: frame.movementFlags,
      movementMode: predicted.movementMode,
    });
  }

  private emitInputBlockedIfActive(nowMs: number): void {
    const keys = this.input.getMovementKeys();
    const jump = this.input.hasPendingJump();
    const hasMoveInput = keys.forward || keys.backward || keys.left || keys.right;
    if ((!hasMoveInput && !jump) || nowMs - this.lastInputBlockedAtMs < 1_000) {
      return;
    }

    this.lastInputBlockedAtMs = nowMs;
    this.bus.emit("movement:input-blocked", {
      reason: "transport_not_ready",
      keys: { ...keys },
      jump,
    });
  }

  private consumeAuthority(nowMs: number, ack: MovementAck, sentAtMs: number): void {
    const rttMs = Math.max(0, nowMs - sentAtMs);
    this.prediction.observeRtt(rttMs);
    const result = this.prediction.applyAck(ack);
    if (!result) return;

    this.authoritativePosition.copy(ack.position);
    if (result.action === ReplayAction.Accepted) {
      this.syncAcceptedAnchor(result.latestState);
    } else {
      this.syncRenderAnchorTo(result.latestState);
    }

    this.bus.emit("movement:authority-applied", {
      action: result.action,
      ackSeq: ack.ackSeq,
      authTick: ack.authTick,
      correctionDistance: result.correctionDistance,
      pendingInputs: result.pendingInputs,
      replayedFrames: result.replayedFrames,
      rttMs,
      movementMode: ack.movementMode,
      velocity: ack.velocity,
      serverFixedDtMs: ack.serverFixedDtMs,
      fixedDtDriftMs: ack.serverFixedDtMs - DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
    });
  }

  private syncRenderAnchorTo(nextAnchorState: PredictedMoveState): void {
    const oldRendered = this.renderedPosition.clone();
    this.renderAnchor.copy(nextAnchorState.position);
    this.pendingCorrection.copy(oldRendered.sub(nextAnchorState.position));
    if (this.pendingCorrection.length() <= 18) {
      this.pendingCorrection.set(0, 0, 0);
    }
    if (this.pendingCorrection.length() > LOCAL_VISUAL_HARD_SNAP_DISTANCE) {
      this.pendingCorrection.set(0, 0, 0);
    }
    this.renderSimulationState = clonePredictedMoveState(nextAnchorState);
    this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
  }

  private syncAcceptedAnchor(nextAnchorState: PredictedMoveState): void {
    this.renderAnchor.copy(nextAnchorState.position);
    if (!this.renderSimulationState) {
      this.renderSimulationState = clonePredictedMoveState(nextAnchorState);
      this.renderedPosition.copy(this.renderSimulationState.position);
      return;
    }

    // Accepted acks have no authoritative correction. Keep the in-frame render
    // phase intact instead of rewinding it to the last fixed-tick anchor.
    this.renderSimulationState.seq = nextAnchorState.seq;
    this.renderSimulationState.tick = nextAnchorState.tick;
    this.renderSimulationState.movementMode = nextAnchorState.movementMode;
    this.renderSimulationState.groundY = nextAnchorState.groundY;
  }

  private dampenPendingCorrection(dtSecs: number): void {
    const damping = Math.exp(-LOCAL_RENDER_SMOOTHING_RATE_HZ * dtSecs);
    this.pendingCorrection.multiplyScalar(damping);
    if (this.pendingCorrection.length() < 0.01) {
      this.pendingCorrection.set(0, 0, 0);
    }
  }

  private advanceRenderedPrediction(dtMs: number): void {
    if (!this.renderSimulationState) {
      const anchorState = this.prediction.peekCurrentState();
      if (anchorState) {
        this.renderSimulationState = clonePredictedMoveState(anchorState);
      }
    }

    if (!this.renderSimulationState) {
      this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
      return;
    }

    if (dtMs > 0) {
      const inputDir = buildMovementWorldDirection(
        keysToAxes(this.input.getMovementKeys()),
        this.cameraYawResolver(),
      );
      const partialFrame: MoveInputFrame = {
        seq: 0,
        clientTick: this.renderSimulationState.tick,
        dtMs,
        inputDir,
        speedScale: 1,
        movementFlags: inputDir.lengthSq() <= 1.0e-6 ? MovementFlag.Brake : MovementFlag.None,
      };
      this.renderSimulationState = step(
        this.renderSimulationState,
        partialFrame,
        DEFAULT_MOVEMENT_PROFILE,
      );
    }

    this.renderedPosition.copy(this.renderSimulationState.position).add(this.pendingCorrection);
  }

  private syncRenderedPositionToAnchor(): void {
    this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
  }

  private captureFrameTrace(nowMs: number, dtMs: number, fixedSteps: number): void {
    if (this.frameTraceRemaining <= 0) {
      return;
    }

    const deltaX = this.renderedPosition.x - this.lastTracedPosition.x;
    const deltaY = this.renderedPosition.y - this.lastTracedPosition.y;
    const deltaZ = this.renderedPosition.z - this.lastTracedPosition.z;
    this.frameTraceSamples.push({
      frame: this.frameTraceSamples.length + 1,
      nowMs,
      dtMs,
      fixedSteps,
      renderedX: this.renderedPosition.x,
      renderedY: this.renderedPosition.y,
      renderedZ: this.renderedPosition.z,
      deltaX,
      deltaY,
      deltaZ,
      deltaDistance: Math.hypot(deltaX, deltaY, deltaZ),
      pendingCorrectionDistance: this.pendingCorrection.length(),
      accumulatorMs: this.fixedStepAccumulatorMs,
      movementMode: this.renderSimulationState?.movementMode ?? MovementMode.Grounded,
      velocityY: this.renderSimulationState?.velocity.y ?? 0,
    });
    this.lastTracedPosition.copy(this.renderedPosition);
    this.frameTraceRemaining -= 1;
  }

  private resetTo(start: Vector3, nextSeq: number = 1): void {
    this.prediction.resetWithSeq(start, nextSeq);
    this.renderAnchor.copy(start);
    this.renderedPosition.copy(start);
    this.pendingCorrection.set(0, 0, 0);
    this.authoritativePosition.copy(start);
    this.fixedStepAccumulatorMs = 0;
    this.lastTracedPosition.copy(start);
    this.renderSimulationState = {
      seq: 0,
      tick: 0,
      position: start.clone(),
      velocity: new Vector3(),
      acceleration: new Vector3(),
      movementMode: MovementMode.Grounded,
      groundY: start.y,
    };
    this.syncRenderedPositionToAnchor();
    this.bus.emit("movement:reset", { start });
  }
}

function clonePredictedMoveState(state: Readonly<PredictedMoveState>): PredictedMoveState {
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
