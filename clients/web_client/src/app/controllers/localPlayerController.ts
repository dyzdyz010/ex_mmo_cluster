import { Vector3 } from "three";
import { LocalPredictionRuntime } from "@domain/movement/localPlayer";
import { step } from "@domain/movement/predictor";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";
import {
  MovementFlag,
  type MovementAck,
  type MoveInputFrame,
  type PredictedMoveState,
} from "@domain/movement/types";
import { buildMovementInputDirection } from "@domain/movement/inputDirection";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FrameSubscriber } from "../gameLoop";
import type { InputController } from "./inputController";
import type { TransportPump } from "./transportPump";

const LOCAL_RENDER_SMOOTHING_RATE_HZ = 15;
const LOCAL_VISUAL_HARD_SNAP_DISTANCE = 256;
const DEFAULT_SPAWN = new Vector3(-350, 650, -280);

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
  private fixedStepAccumulatorMs = 0;
  private cameraYawResolver: () => number = () => 0;

  constructor(
    private readonly bus: EventBus<AppEvents>,
    private readonly input: InputController,
    private readonly transport: TransportPump,
  ) {
    this.resetTo(DEFAULT_SPAWN);
    this.bus.on("transport:spawn", ({ position }) => this.resetTo(position));
    this.bus.on("transport:ack-delivered", ({ ack, sentAtMs }) => {
      this.consumeAuthority(performance.now(), ack, sentAtMs);
    });
  }

  onFrame(nowMs: number, dtMs: number): void {
    this.fixedStepAccumulatorMs += dtMs;
    while (this.fixedStepAccumulatorMs >= DEFAULT_MOVEMENT_PROFILE.fixedDtMs) {
      this.fixedStepAccumulatorMs -= DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
      this.stepFixed(nowMs);
    }
    this.dampenPendingCorrection(dtMs / 1000);
    this.advanceRenderedPrediction();
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

  private stepFixed(nowMs: number): void {
    if (!this.transport.isReady()) return;

    const inputDir = buildMovementInputDirection(
      this.input.getMovementKeys(),
      this.cameraYawResolver(),
    );
    const frame = this.prediction.buildInputFrame(inputDir, DEFAULT_MOVEMENT_PROFILE.fixedDtMs, 1);
    const predicted = this.prediction.applyLocalInput(frame);
    if (!predicted) return;

    this.renderAnchor.copy(predicted.position);
    this.transport.sendInput(frame, nowMs);

    this.bus.emit("movement:local-step", {
      seq: frame.seq,
      clientTick: frame.clientTick,
      position: predicted.position,
    });
  }

  private consumeAuthority(nowMs: number, ack: MovementAck, sentAtMs: number): void {
    const rttMs = Math.max(0, nowMs - sentAtMs);
    this.prediction.observeRtt(rttMs);
    const result = this.prediction.applyAck(ack);
    if (!result) return;

    this.authoritativePosition.copy(ack.position);
    this.syncRenderAnchorTo(result.latestState.position);

    this.bus.emit("movement:authority-applied", {
      action: result.action,
      ackSeq: ack.ackSeq,
      authTick: ack.authTick,
      correctionDistance: result.correctionDistance,
      pendingInputs: result.pendingInputs,
      replayedFrames: result.replayedFrames,
      rttMs,
    });
  }

  private syncRenderAnchorTo(nextAnchor: Vector3): void {
    const oldRendered = this.renderedPosition.clone();
    this.renderAnchor.copy(nextAnchor);
    this.pendingCorrection.copy(oldRendered.sub(nextAnchor));
    if (this.pendingCorrection.length() <= 18) {
      this.pendingCorrection.set(0, 0, 0);
    }
    if (this.pendingCorrection.length() > LOCAL_VISUAL_HARD_SNAP_DISTANCE) {
      this.pendingCorrection.set(0, 0, 0);
    }
    this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
  }

  private dampenPendingCorrection(dtSecs: number): void {
    const damping = Math.exp(-LOCAL_RENDER_SMOOTHING_RATE_HZ * dtSecs);
    this.pendingCorrection.multiplyScalar(damping);
    if (this.pendingCorrection.length() < 0.01) {
      this.pendingCorrection.set(0, 0, 0);
    }
  }

  private advanceRenderedPrediction(): void {
    const anchorState = this.prediction.getCurrentState();
    if (!anchorState) {
      this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
      return;
    }

    let displayAnchor = anchorState.position;
    if (this.transport.isReady() && this.fixedStepAccumulatorMs > 0) {
      displayAnchor = this.predictPartialAnchor(anchorState).position;
    }

    this.renderedPosition.copy(displayAnchor).add(this.pendingCorrection);
  }

  private predictPartialAnchor(anchorState: PredictedMoveState): PredictedMoveState {
    const inputDir = buildMovementInputDirection(
      this.input.getMovementKeys(),
      this.cameraYawResolver(),
    );
    const partialFrame: MoveInputFrame = {
      seq: 0,
      clientTick: anchorState.tick,
      dtMs: this.fixedStepAccumulatorMs,
      inputDir,
      speedScale: 1,
      movementFlags:
        inputDir.lengthSq() <= 1.0e-6 ? MovementFlag.Brake : MovementFlag.None,
    };

    return step(anchorState, partialFrame, DEFAULT_MOVEMENT_PROFILE);
  }

  private syncRenderedPositionToAnchor(): void {
    this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
  }

  private resetTo(start: Vector3): void {
    this.prediction.reset(start);
    this.renderAnchor.copy(start);
    this.renderedPosition.copy(start);
    this.pendingCorrection.set(0, 0, 0);
    this.authoritativePosition.copy(start);
    this.fixedStepAccumulatorMs = 0;
    this.syncRenderedPositionToAnchor();
    this.bus.emit("movement:reset", { start });
  }
}
