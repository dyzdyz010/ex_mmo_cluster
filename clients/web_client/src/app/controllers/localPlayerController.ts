import { Vector3 } from "three";
import { LocalPredictionRuntime } from "@domain/movement/localPlayer";
import { ServerClockEstimator, type ServerClockDebugSnapshot } from "@domain/movement/serverClock";
import { ReplayAction } from "@domain/movement/governance";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";
import type {
  MovementCollisionResolver,
  MovementCollisionSummary,
} from "@domain/movement/collision";
import {
  MovementFlag,
  MovementMode,
  type MovementAck,
  type MoveInputFrame,
  type PredictedMoveState,
} from "@domain/movement/types";
import {
  buildMovementWorldDirection,
  clampUnitVec,
  keysToAxes,
  type MovementAxes,
} from "@domain/movement/inputDirection";
import { makeFallbackLocalSpawn } from "../spawn";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FrameSubscriber } from "../gameLoop";
import type { InputController } from "./inputController";
import type { TransportPump } from "./transportPump";

const LOCAL_RENDER_SMOOTHING_RATE_HZ = 15;
const LOCAL_VISUAL_HARD_SNAP_DISTANCE = 256;
const MAX_FIXED_CATCH_UP_TICKS = 4;
const MAX_RENDER_PARTIAL_DT_MS = DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
const MAX_AUTHORITATIVE_PROJECTION_TICKS = 2;
const MAX_AUTHORITATIVE_CLOCK_PROJECTION_MS = 250;
const IDLE_INPUT_KEEPALIVE_MS = 5_000;

interface AuthorityLatencyDiagnostics {
  ackSeq: number | null;
  authTick: number | null;
  inputSeqGap: number | null;
  lastAckRttMs: number | null;
  lastAckPendingInputs: number | null;
  lastAckReplayedFrames: number | null;
  serverStateAgeMs: number | null;
  serverSendAgeMs: number | null;
  sceneAckAgeMs: number | null;
  browserApplyDelayMs: number | null;
  gateSendDelayMs: number | null;
  sceneInputAgeMs: number | null;
  sceneQueueLen: number | null;
  sceneReplayCount: number | null;
  sceneDroppedInputCount: number | null;
  sceneMailboxLen: number | null;
  sceneTickDriftMs: number | null;
}

export interface MovementFrameTraceSample {
  frame: number;
  nowMs: number;
  dtMs: number;
  fixedSteps: number;
  localX: number;
  localY: number;
  localZ: number;
  renderedX: number;
  renderedY: number;
  renderedZ: number;
  authorityX: number;
  authorityY: number;
  authorityZ: number;
  authorityRenderX: number;
  authorityRenderY: number;
  authorityRenderZ: number;
  authorityProjectedX: number;
  authorityProjectedY: number;
  authorityProjectedZ: number;
  authorityDisplayX: number;
  authorityDisplayY: number;
  authorityDisplayZ: number;
  deltaX: number;
  deltaY: number;
  deltaZ: number;
  deltaDistance: number;
  authorityDeltaX: number;
  authorityDeltaY: number;
  authorityDeltaZ: number;
  authorityDeltaDistance: number;
  authorityRenderDeltaX: number;
  authorityRenderDeltaY: number;
  authorityRenderDeltaZ: number;
  authorityRenderDeltaDistance: number;
  authorityProjectedDeltaX: number;
  authorityProjectedDeltaY: number;
  authorityProjectedDeltaZ: number;
  authorityProjectedDeltaDistance: number;
  authorityDisplayDeltaX: number;
  authorityDisplayDeltaY: number;
  authorityDisplayDeltaZ: number;
  authorityDisplayDeltaDistance: number;
  localAuthorityDistance: number;
  localAuthorityHorizontalDistance: number;
  localAuthorityRenderDistance: number;
  localAuthorityRenderHorizontalDistance: number;
  localAuthorityProjectedDistance: number;
  localAuthorityProjectedHorizontalDistance: number;
  localAuthorityDisplayDistance: number;
  localAuthorityDisplayHorizontalDistance: number;
  authorityRenderAuthorityDistance: number;
  authorityRenderAuthorityHorizontalDistance: number;
  authorityProjectedAuthorityDistance: number;
  authorityProjectedAuthorityHorizontalDistance: number;
  authorityDisplayAuthorityDistance: number;
  authorityDisplayAuthorityHorizontalDistance: number;
  pendingCorrectionDistance: number;
  accumulatorMs: number;
  movementMode: string;
  velocityY: number;
  collisionStatus: string;
  collisionOccupiedCount: number;
  collisionBlockedAxes: string[];
  ackSeq: number | null;
  authTick: number | null;
  inputSeqGap: number | null;
  lastAckRttMs: number | null;
  lastAckPendingInputs: number | null;
  lastAckReplayedFrames: number | null;
  serverStateAgeMs: number | null;
  serverSendAgeMs: number | null;
  sceneAckAgeMs: number | null;
  browserApplyDelayMs: number | null;
  gateSendDelayMs: number | null;
  sceneInputAgeMs: number | null;
  sceneQueueLen: number | null;
  sceneReplayCount: number | null;
  sceneDroppedInputCount: number | null;
  sceneMailboxLen: number | null;
  sceneTickDriftMs: number | null;
}

/**
 * Owns local-player prediction, reconciliation, and the render-anchor buffer
 * that visually damps corrections so the player never teleports on screen.
 *
 * Logic stays on a 16 ms fixed step for input/authority parity, while render
 * samples replay only the in-progress accumulator remainder from the latest
 * fixed state. Raw authoritative ack and ack projection stay available for
 * trace diagnostics; the visible gray marker follows the current server
 * projection so it remains independent from local visual correction damping.
 */
export class LocalPlayerController implements FrameSubscriber {
  private readonly prediction = new LocalPredictionRuntime();
  private readonly renderAnchor = new Vector3();
  private readonly renderedPosition = new Vector3();
  private readonly pendingCorrection = new Vector3();
  private readonly authoritativePosition = new Vector3();
  private readonly authoritativeVelocity = new Vector3();
  private readonly authoritativeAcceleration = new Vector3();
  private readonly serverClock = new ServerClockEstimator();
  private readonly lastTracedPosition = new Vector3();
  private readonly lastTracedAuthorityPosition = new Vector3();
  private readonly lastTracedAuthorityRenderPosition = new Vector3();
  private readonly lastTracedAuthorityProjectedPosition = new Vector3();
  private readonly lastTracedAuthorityDisplayPosition = new Vector3();
  private readonly frameTraceSamples: MovementFrameTraceSample[] = [];
  private fixedStepAccumulatorMs = 0;
  private lastAuthorityAtMs: number | null = null;
  private lastAuthorityTick: number | null = null;
  private lastAuthorityServerStateMs: number | null = null;
  private lastAuthorityServerSendMs: number | null = null;
  private lastAuthorityDiagnostics: AuthorityLatencyDiagnostics =
    emptyAuthorityLatencyDiagnostics();
  private lastAuthorityFixedDtMs = DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
  private cameraYawResolver: () => number = () => 0;
  private frameTraceRemaining = 0;
  private renderSimulationState: PredictedMoveState | null = null;
  private lastInputBlockedAtMs = Number.NEGATIVE_INFINITY;
  private lastCollisionSummary: MovementCollisionSummary | null = null;
  private lastSentInputWasIdle = false;
  private lastSentIdleInputAtMs = Number.NEGATIVE_INFINITY;

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
    this.bus.on("transport:ack-delivered", ({ ack, sentAtMs, receivedAtMs }) => {
      const nowMs = performance.now();
      this.consumeAuthority(nowMs, ack, sentAtMs, receivedAtMs ?? nowMs);
    });
    this.bus.on("transport:time-sync", (sample) => {
      this.serverClock.observe(sample);
    });
  }

  onFrame(nowMs: number, dtMs: number): void {
    const frameDtMs = Math.max(0, dtMs);
    let fixedSteps = 0;
    this.fixedStepAccumulatorMs += frameDtMs;
    while (
      this.fixedStepAccumulatorMs >= DEFAULT_MOVEMENT_PROFILE.fixedDtMs &&
      fixedSteps < MAX_FIXED_CATCH_UP_TICKS
    ) {
      this.fixedStepAccumulatorMs -= DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
      this.stepFixed(nowMs);
      fixedSteps += 1;
    }
    const renderPartialDtMs = Math.min(this.fixedStepAccumulatorMs, MAX_RENDER_PARTIAL_DT_MS);
    this.dampenPendingCorrection(frameDtMs / 1000);
    this.advanceRenderedPrediction(renderPartialDtMs);
    this.captureFrameTrace(nowMs, renderPartialDtMs, fixedSteps);
  }

  getRenderedPosition(): Vector3 {
    return this.renderedPosition;
  }

  getAuthoritativePosition(): Vector3 {
    return this.authoritativePosition;
  }

  getAuthoritativeProjectedPosition(nowMs: number = performance.now()): Vector3 {
    if (this.lastAuthorityAtMs === null) {
      return this.renderedPosition.clone();
    }

    const dtSecs = this.resolveAuthoritativeProjection(nowMs).dtMs / 1000;

    return this.authoritativePosition
      .clone()
      .add(this.authoritativeVelocity.clone().multiplyScalar(dtSecs))
      .add(this.authoritativeAcceleration.clone().multiplyScalar(0.5 * dtSecs * dtSecs));
  }

  getAuthoritativeDisplayPosition(nowMs: number = performance.now()): Vector3 {
    return this.getAuthoritativeProjectedPosition(nowMs);
  }

  getAuthoritativeRenderPosition(nowMs: number): Vector3 {
    return this.getAuthoritativeDisplayPosition(nowMs);
  }

  getAuthorityRenderDebugSnapshot(): ServerClockDebugSnapshot & {
    latestServerTick: number | null;
    latestServerStateMs: number | null;
    latestServerSendMs: number | null;
    latency: AuthorityLatencyDiagnostics;
    bufferedSnapshots: number;
    interpolationMode: "empty" | "interpolated" | "extrapolated";
    interpolationDelaySecs: number;
    interpolationTimeAxis: "server_tick" | "server_state_ms";
    serverStateTimelineHealthy: boolean;
    serverSendTimelineHealthy: boolean;
    playbackServerTimeMs: number | null;
    serverTickDiscontinuityCount: number;
    playbackTimeRegressionCount: number;
  } {
    const projection = this.resolveAuthoritativeProjection(performance.now());
    return {
      latestServerTick: this.lastAuthorityTick,
      latestServerStateMs: this.lastAuthorityServerStateMs,
      latestServerSendMs: this.lastAuthorityServerSendMs,
      latency: { ...this.lastAuthorityDiagnostics },
      bufferedSnapshots: this.lastAuthorityAtMs === null ? 0 : 1,
      interpolationMode: this.lastAuthorityAtMs === null ? "empty" : "extrapolated",
      interpolationDelaySecs: 0,
      interpolationTimeAxis: projection.timeAxis,
      serverStateTimelineHealthy: this.lastAuthorityAtMs !== null,
      serverSendTimelineHealthy: this.lastAuthorityAtMs !== null,
      playbackServerTimeMs: projection.playbackServerTimeMs,
      serverTickDiscontinuityCount: 0,
      playbackTimeRegressionCount: 0,
      ...this.serverClock.debugSnapshot(),
    };
  }

  getPendingCorrection(): Vector3 {
    return this.pendingCorrection;
  }

  startFrameTrace(maxFrames: number): void {
    this.frameTraceSamples.length = 0;
    this.frameTraceRemaining = Math.max(1, Math.floor(maxFrames));
    this.lastTracedPosition.copy(this.renderedPosition);
    this.lastTracedAuthorityPosition.copy(this.authoritativePosition);
    const nowMs = performance.now();
    this.lastTracedAuthorityRenderPosition.copy(this.getAuthoritativeRenderPosition(nowMs));
    this.lastTracedAuthorityProjectedPosition.copy(this.getAuthoritativeProjectedPosition(nowMs));
    this.lastTracedAuthorityDisplayPosition.copy(this.getAuthoritativeDisplayPosition(nowMs));
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

  setMovementCollisionResolver(resolver: MovementCollisionResolver | null): void {
    this.prediction.setCollisionResolver(resolver);
    this.lastCollisionSummary = null;
  }

  getLastCollisionSummary(): MovementCollisionSummary | null {
    const summary = this.lastCollisionSummary ?? this.prediction.getLastCollisionSummary();
    return summary
      ? {
          ...summary,
          blockedAxes: [...summary.blockedAxes],
          previousPosition: summary.previousPosition.clone(),
          proposedPosition: summary.proposedPosition.clone(),
          resolvedPosition: summary.resolvedPosition.clone(),
        }
      : null;
  }

  /** Visible for tests. */
  getCombinedMovementAxesForTest(): MovementAxes {
    return this.combinedAxes();
  }

  setCameraYawResolver(resolver: () => number): void {
    this.cameraYawResolver = resolver;
  }

  requestJump(source = "cli"): void {
    this.input.requestJump(source);
  }

  setVirtualMovement(vec: { x: number; y: number }): { x: number; y: number } {
    this.input.setVirtualMovement(vec);
    const current = this.input.getVirtualMovement();
    return { x: current.x, y: current.y };
  }

  /**
   * Returns the unit-clamped (strafe, forward) input axes from keyboard + virtual stick.
   *
   * Clamping is applied even when the stick is at rest so that diagonal keyboard input
   * (e.g. W+D) yields the same speed as cardinal input — matching the input-normalization
   * convention used by UE CMC / Source / Valorant. The local predictor and the server
   * authority both assume max input magnitude is 1, so this layer is the single place
   * where that contract is enforced.
   */
  private combinedAxes(): MovementAxes {
    const keyboard = keysToAxes(this.input.getMovementKeys());
    const stick = this.input.getVirtualMovement();
    const merged = clampUnitVec({
      x: keyboard.strafe + stick.x,
      y: keyboard.forward + stick.y,
    });
    return { strafe: merged.x, forward: merged.y };
  }

  private stepFixed(nowMs: number): void {
    const inputDir = buildMovementWorldDirection(this.combinedAxes(), this.cameraYawResolver());
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
    const collisionSummary = this.prediction.getLastCollisionSummary();
    this.lastCollisionSummary = collisionSummary;

    if (jumpRequested || this.renderSimulationState?.movementMode !== predicted.movementMode) {
      this.syncRenderAnchorTo(predicted);
    } else {
      this.renderAnchor.copy(predicted.position);
    }
    if (this.shouldSendInputFrame(frame, predicted, nowMs)) {
      this.transport.sendInput(frame, nowMs);
    }

    this.bus.emit("movement:local-step", {
      seq: frame.seq,
      clientTick: frame.clientTick,
      position: predicted.position,
      velocity: predicted.velocity,
      movementFlags: frame.movementFlags,
      movementMode: predicted.movementMode,
      collisionStatus: collisionSummary?.status ?? "disabled",
      collisionOccupiedCount: collisionSummary?.occupiedCount ?? 0,
      collisionBlockedAxes: collisionSummary?.blockedAxes ?? [],
    });
  }

  private emitInputBlockedIfActive(nowMs: number): void {
    const keys = this.input.getMovementKeys();
    const jump = this.input.hasPendingJump();
    const stick = this.input.getVirtualMovement();
    const hasMoveInput =
      keys.forward || keys.backward || keys.left || keys.right || stick.x !== 0 || stick.y !== 0;
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

  private shouldSendInputFrame(
    frame: MoveInputFrame,
    predicted: PredictedMoveState,
    nowMs: number,
  ): boolean {
    const idle = this.isNetworkIdleFrame(frame, predicted);

    if (!idle) {
      this.lastSentInputWasIdle = false;
      return true;
    }

    if (
      !this.lastSentInputWasIdle ||
      nowMs - this.lastSentIdleInputAtMs >= IDLE_INPUT_KEEPALIVE_MS
    ) {
      this.lastSentInputWasIdle = true;
      this.lastSentIdleInputAtMs = nowMs;
      return true;
    }

    return false;
  }

  private isNetworkIdleFrame(frame: MoveInputFrame, predicted: PredictedMoveState): boolean {
    return (
      frame.inputDir.lengthSq() <= 1.0e-6 &&
      (frame.movementFlags & MovementFlag.Jump) === 0 &&
      predicted.movementMode === MovementMode.Grounded &&
      predicted.velocity.lengthSq() <= 1.0e-6
    );
  }

  private consumeAuthority(
    nowMs: number,
    ack: MovementAck,
    sentAtMs: number,
    receivedAtMs: number,
  ): void {
    const rttMs = Math.max(0, nowMs - sentAtMs);
    this.prediction.observeRtt(rttMs);
    const result = this.prediction.applyAck(ack);
    if (!result) return;

    this.authoritativePosition.copy(ack.position);
    this.authoritativeVelocity.copy(ack.velocity);
    this.authoritativeAcceleration.copy(ack.acceleration);
    this.lastAuthorityAtMs = nowMs;
    this.lastAuthorityTick = ack.authTick;
    this.lastAuthorityServerStateMs = ack.serverStateMs;
    this.lastAuthorityServerSendMs = ack.serverSendMs;
    this.lastAuthorityFixedDtMs = Math.max(
      1,
      ack.serverFixedDtMs || DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
    );
    if (result.action === ReplayAction.Accepted) {
      this.syncAcceptedAnchor(result.latestState);
    } else {
      this.syncRenderAnchorTo(result.latestState);
    }
    const diagnostics = this.buildAuthorityLatencyDiagnostics(
      nowMs,
      ack,
      sentAtMs,
      receivedAtMs,
      result.pendingInputs,
      result.replayedFrames,
    );
    this.lastAuthorityDiagnostics = diagnostics;

    this.bus.emit("movement:authority-applied", {
      action: result.action,
      ackSeq: ack.ackSeq,
      authTick: ack.authTick,
      correctionDistance: result.correctionDistance,
      pendingInputs: result.pendingInputs,
      replayedFrames: result.replayedFrames,
      rttMs,
      lastAckRttMs: rttMs,
      inputSeqGap: diagnostics.inputSeqGap ?? 0,
      movementMode: ack.movementMode,
      velocity: ack.velocity,
      serverFixedDtMs: ack.serverFixedDtMs,
      fixedDtDriftMs: ack.serverFixedDtMs - DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
      serverStateAgeMs: diagnostics.serverStateAgeMs,
      serverSendAgeMs: diagnostics.serverSendAgeMs,
      sceneAckAgeMs: diagnostics.sceneAckAgeMs,
      browserApplyDelayMs: diagnostics.browserApplyDelayMs ?? 0,
      gateSendDelayMs: diagnostics.gateSendDelayMs,
      sceneInputAgeMs: diagnostics.sceneInputAgeMs,
      sceneQueueLen: diagnostics.sceneQueueLen,
      sceneReplayCount: diagnostics.sceneReplayCount,
      sceneDroppedInputCount: diagnostics.sceneDroppedInputCount,
      sceneMailboxLen: diagnostics.sceneMailboxLen,
      sceneTickDriftMs: diagnostics.sceneTickDriftMs,
    });
  }

  private buildAuthorityLatencyDiagnostics(
    nowMs: number,
    ack: MovementAck,
    sentAtMs: number,
    receivedAtMs: number,
    pendingInputs: number,
    replayedFrames: number,
  ): AuthorityLatencyDiagnostics {
    const localWallNowMs = Date.now();
    const clock = this.serverClock.sampleClock(localWallNowMs);
    const estimatedServerNowMs =
      clock.serverClockOffsetMs === null
        ? localWallNowMs
        : localWallNowMs + clock.serverClockOffsetMs;
    const sceneAckMs = finiteOptional(ack.sceneAckMs);
    const serverSendMs = finiteOptional(ack.serverSendMs);
    return {
      ackSeq: ack.ackSeq,
      authTick: ack.authTick,
      inputSeqGap: Math.max(0, pendingInputs),
      lastAckRttMs: Math.max(0, nowMs - sentAtMs),
      lastAckPendingInputs: Math.max(0, pendingInputs),
      lastAckReplayedFrames: Math.max(0, replayedFrames),
      serverStateAgeMs: timestampAgeMs(estimatedServerNowMs, ack.serverStateMs),
      serverSendAgeMs: timestampAgeMs(estimatedServerNowMs, serverSendMs),
      sceneAckAgeMs: timestampAgeMs(estimatedServerNowMs, sceneAckMs),
      browserApplyDelayMs: Math.max(0, nowMs - receivedAtMs),
      gateSendDelayMs:
        finiteOptional(ack.gateSendDelayMs) ??
        (serverSendMs === null || sceneAckMs === null
          ? null
          : Math.max(0, serverSendMs - sceneAckMs)),
      sceneInputAgeMs: finiteOptional(ack.sceneInputAgeMs),
      sceneQueueLen: finiteOptional(ack.sceneQueueLen),
      sceneReplayCount: finiteOptional(ack.sceneReplayCount),
      sceneDroppedInputCount: finiteOptional(ack.sceneDroppedInputCount),
      sceneMailboxLen: finiteOptional(ack.sceneMailboxLen),
      sceneTickDriftMs: finiteOptional(ack.sceneTickDriftMs),
    };
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
    const anchorState = this.prediction.peekCurrentState();
    if (anchorState) {
      this.renderSimulationState = clonePredictedMoveState(anchorState);
    }

    if (!this.renderSimulationState) {
      this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
      return;
    }

    if (dtMs > 0) {
      const inputDir = buildMovementWorldDirection(this.combinedAxes(), this.cameraYawResolver());
      const partialFrame: MoveInputFrame = {
        seq: 0,
        clientTick: this.renderSimulationState.tick,
        dtMs,
        inputDir,
        speedScale: 1,
        movementFlags: inputDir.lengthSq() <= 1.0e-6 ? MovementFlag.Brake : MovementFlag.None,
      };
      this.renderSimulationState = this.prediction.predictFrom(
        this.renderSimulationState,
        partialFrame,
      );
      this.lastCollisionSummary = this.prediction.getLastCollisionSummary();
    }

    this.renderedPosition.copy(this.renderSimulationState.position).add(this.pendingCorrection);
  }

  private resolveAuthoritativeProjection(nowMs: number): {
    dtMs: number;
    timeAxis: "server_tick" | "server_state_ms";
    playbackServerTimeMs: number | null;
  } {
    if (this.lastAuthorityAtMs === null) {
      return { dtMs: 0, timeAxis: "server_tick", playbackServerTimeMs: null };
    }

    const fixedDtMs = Math.max(1, this.lastAuthorityFixedDtMs);
    const fallbackDtMs = Math.min(
      Math.max(0, nowMs - this.lastAuthorityAtMs),
      fixedDtMs * MAX_AUTHORITATIVE_PROJECTION_TICKS,
    );
    const fallbackPlaybackServerTimeMs =
      this.lastAuthorityServerStateMs === null
        ? null
        : this.lastAuthorityServerStateMs + fallbackDtMs;

    const clock = this.serverClock.sampleClock(Date.now());
    if (
      this.lastAuthorityServerStateMs !== null &&
      this.lastAuthorityServerStateMs > 0 &&
      clock.serverClockOffsetMs !== null &&
      Number.isFinite(clock.serverClockOffsetMs)
    ) {
      const serverNowMs = clock.localWallClockMs + clock.serverClockOffsetMs;
      const maxProjectionMs = Math.max(
        fixedDtMs * MAX_AUTHORITATIVE_PROJECTION_TICKS,
        MAX_AUTHORITATIVE_CLOCK_PROJECTION_MS,
      );
      const dtMs = Math.min(
        Math.max(0, serverNowMs - this.lastAuthorityServerStateMs),
        maxProjectionMs,
      );
      return {
        dtMs,
        timeAxis: "server_state_ms",
        playbackServerTimeMs: this.lastAuthorityServerStateMs + dtMs,
      };
    }

    return {
      dtMs: fallbackDtMs,
      timeAxis: "server_tick",
      playbackServerTimeMs: fallbackPlaybackServerTimeMs,
    };
  }

  private syncRenderedPositionToAnchor(): void {
    this.renderedPosition.copy(this.renderAnchor).add(this.pendingCorrection);
  }

  private captureFrameTrace(nowMs: number, dtMs: number, fixedSteps: number): void {
    if (this.frameTraceRemaining <= 0) {
      return;
    }

    const authorityProjectedPosition = this.getAuthoritativeProjectedPosition(nowMs);
    const authorityRenderPosition = this.getAuthoritativeRenderPosition(nowMs);
    const authorityDisplayPosition = this.getAuthoritativeDisplayPosition(nowMs);
    const deltaX = this.renderedPosition.x - this.lastTracedPosition.x;
    const deltaY = this.renderedPosition.y - this.lastTracedPosition.y;
    const deltaZ = this.renderedPosition.z - this.lastTracedPosition.z;
    const authorityDeltaX = this.authoritativePosition.x - this.lastTracedAuthorityPosition.x;
    const authorityDeltaY = this.authoritativePosition.y - this.lastTracedAuthorityPosition.y;
    const authorityDeltaZ = this.authoritativePosition.z - this.lastTracedAuthorityPosition.z;
    const authorityRenderDeltaX =
      authorityRenderPosition.x - this.lastTracedAuthorityRenderPosition.x;
    const authorityRenderDeltaY =
      authorityRenderPosition.y - this.lastTracedAuthorityRenderPosition.y;
    const authorityRenderDeltaZ =
      authorityRenderPosition.z - this.lastTracedAuthorityRenderPosition.z;
    const authorityProjectedDeltaX =
      authorityProjectedPosition.x - this.lastTracedAuthorityProjectedPosition.x;
    const authorityProjectedDeltaY =
      authorityProjectedPosition.y - this.lastTracedAuthorityProjectedPosition.y;
    const authorityProjectedDeltaZ =
      authorityProjectedPosition.z - this.lastTracedAuthorityProjectedPosition.z;
    const authorityDisplayDeltaX =
      authorityDisplayPosition.x - this.lastTracedAuthorityDisplayPosition.x;
    const authorityDisplayDeltaY =
      authorityDisplayPosition.y - this.lastTracedAuthorityDisplayPosition.y;
    const authorityDisplayDeltaZ =
      authorityDisplayPosition.z - this.lastTracedAuthorityDisplayPosition.z;
    this.frameTraceSamples.push({
      frame: this.frameTraceSamples.length + 1,
      nowMs,
      dtMs,
      fixedSteps,
      localX: this.renderedPosition.x,
      localY: this.renderedPosition.y,
      localZ: this.renderedPosition.z,
      renderedX: this.renderedPosition.x,
      renderedY: this.renderedPosition.y,
      renderedZ: this.renderedPosition.z,
      authorityX: this.authoritativePosition.x,
      authorityY: this.authoritativePosition.y,
      authorityZ: this.authoritativePosition.z,
      authorityRenderX: authorityRenderPosition.x,
      authorityRenderY: authorityRenderPosition.y,
      authorityRenderZ: authorityRenderPosition.z,
      authorityProjectedX: authorityProjectedPosition.x,
      authorityProjectedY: authorityProjectedPosition.y,
      authorityProjectedZ: authorityProjectedPosition.z,
      authorityDisplayX: authorityDisplayPosition.x,
      authorityDisplayY: authorityDisplayPosition.y,
      authorityDisplayZ: authorityDisplayPosition.z,
      deltaX,
      deltaY,
      deltaZ,
      deltaDistance: Math.hypot(deltaX, deltaY, deltaZ),
      authorityDeltaX,
      authorityDeltaY,
      authorityDeltaZ,
      authorityDeltaDistance: Math.hypot(authorityDeltaX, authorityDeltaY, authorityDeltaZ),
      authorityRenderDeltaX,
      authorityRenderDeltaY,
      authorityRenderDeltaZ,
      authorityRenderDeltaDistance: Math.hypot(
        authorityRenderDeltaX,
        authorityRenderDeltaY,
        authorityRenderDeltaZ,
      ),
      authorityProjectedDeltaX,
      authorityProjectedDeltaY,
      authorityProjectedDeltaZ,
      authorityProjectedDeltaDistance: Math.hypot(
        authorityProjectedDeltaX,
        authorityProjectedDeltaY,
        authorityProjectedDeltaZ,
      ),
      authorityDisplayDeltaX,
      authorityDisplayDeltaY,
      authorityDisplayDeltaZ,
      authorityDisplayDeltaDistance: Math.hypot(
        authorityDisplayDeltaX,
        authorityDisplayDeltaY,
        authorityDisplayDeltaZ,
      ),
      localAuthorityDistance: this.renderedPosition.distanceTo(this.authoritativePosition),
      localAuthorityHorizontalDistance: Math.hypot(
        this.renderedPosition.x - this.authoritativePosition.x,
        this.renderedPosition.z - this.authoritativePosition.z,
      ),
      localAuthorityRenderDistance: this.renderedPosition.distanceTo(authorityRenderPosition),
      localAuthorityRenderHorizontalDistance: Math.hypot(
        this.renderedPosition.x - authorityRenderPosition.x,
        this.renderedPosition.z - authorityRenderPosition.z,
      ),
      localAuthorityProjectedDistance: this.renderedPosition.distanceTo(authorityProjectedPosition),
      localAuthorityProjectedHorizontalDistance: Math.hypot(
        this.renderedPosition.x - authorityProjectedPosition.x,
        this.renderedPosition.z - authorityProjectedPosition.z,
      ),
      localAuthorityDisplayDistance: this.renderedPosition.distanceTo(authorityDisplayPosition),
      localAuthorityDisplayHorizontalDistance: Math.hypot(
        this.renderedPosition.x - authorityDisplayPosition.x,
        this.renderedPosition.z - authorityDisplayPosition.z,
      ),
      authorityRenderAuthorityDistance: authorityRenderPosition.distanceTo(
        this.authoritativePosition,
      ),
      authorityRenderAuthorityHorizontalDistance: Math.hypot(
        authorityRenderPosition.x - this.authoritativePosition.x,
        authorityRenderPosition.z - this.authoritativePosition.z,
      ),
      authorityProjectedAuthorityDistance: authorityProjectedPosition.distanceTo(
        this.authoritativePosition,
      ),
      authorityProjectedAuthorityHorizontalDistance: Math.hypot(
        authorityProjectedPosition.x - this.authoritativePosition.x,
        authorityProjectedPosition.z - this.authoritativePosition.z,
      ),
      authorityDisplayAuthorityDistance: authorityDisplayPosition.distanceTo(
        this.authoritativePosition,
      ),
      authorityDisplayAuthorityHorizontalDistance: Math.hypot(
        authorityDisplayPosition.x - this.authoritativePosition.x,
        authorityDisplayPosition.z - this.authoritativePosition.z,
      ),
      pendingCorrectionDistance: this.pendingCorrection.length(),
      accumulatorMs: this.fixedStepAccumulatorMs,
      movementMode: this.renderSimulationState?.movementMode ?? MovementMode.Grounded,
      velocityY: this.renderSimulationState?.velocity.y ?? 0,
      collisionStatus: this.lastCollisionSummary?.status ?? "disabled",
      collisionOccupiedCount: this.lastCollisionSummary?.occupiedCount ?? 0,
      collisionBlockedAxes: this.lastCollisionSummary?.blockedAxes ?? [],
      ...this.lastAuthorityDiagnostics,
    });
    this.lastTracedPosition.copy(this.renderedPosition);
    this.lastTracedAuthorityPosition.copy(this.authoritativePosition);
    this.lastTracedAuthorityRenderPosition.copy(authorityRenderPosition);
    this.lastTracedAuthorityProjectedPosition.copy(authorityProjectedPosition);
    this.lastTracedAuthorityDisplayPosition.copy(authorityDisplayPosition);
    this.frameTraceRemaining -= 1;
  }

  private resetTo(start: Vector3, nextSeq: number = 1): void {
    this.prediction.resetWithSeq(start, nextSeq);
    this.renderAnchor.copy(start);
    this.renderedPosition.copy(start);
    this.pendingCorrection.set(0, 0, 0);
    this.authoritativePosition.copy(start);
    this.authoritativeVelocity.set(0, 0, 0);
    this.authoritativeAcceleration.set(0, 0, 0);
    this.lastAuthorityAtMs = null;
    this.lastAuthorityTick = null;
    this.lastAuthorityServerStateMs = null;
    this.lastAuthorityServerSendMs = null;
    this.lastAuthorityDiagnostics = emptyAuthorityLatencyDiagnostics();
    this.lastAuthorityFixedDtMs = DEFAULT_MOVEMENT_PROFILE.fixedDtMs;
    this.fixedStepAccumulatorMs = 0;
    this.lastTracedPosition.copy(start);
    this.lastTracedAuthorityPosition.copy(start);
    this.lastTracedAuthorityRenderPosition.copy(start);
    this.lastTracedAuthorityProjectedPosition.copy(start);
    this.lastTracedAuthorityDisplayPosition.copy(start);
    this.lastCollisionSummary = null;
    this.lastSentInputWasIdle = false;
    this.lastSentIdleInputAtMs = Number.NEGATIVE_INFINITY;
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

function emptyAuthorityLatencyDiagnostics(): AuthorityLatencyDiagnostics {
  return {
    ackSeq: null,
    authTick: null,
    inputSeqGap: null,
    lastAckRttMs: null,
    lastAckPendingInputs: null,
    lastAckReplayedFrames: null,
    serverStateAgeMs: null,
    serverSendAgeMs: null,
    sceneAckAgeMs: null,
    browserApplyDelayMs: null,
    gateSendDelayMs: null,
    sceneInputAgeMs: null,
    sceneQueueLen: null,
    sceneReplayCount: null,
    sceneDroppedInputCount: null,
    sceneMailboxLen: null,
    sceneTickDriftMs: null,
  };
}

function finiteOptional(value: number | undefined): number | null {
  return Number.isFinite(value) ? Number(value) : null;
}

function timestampAgeMs(estimatedServerNowMs: number, timestampMs: number | null): number | null {
  if (timestampMs === null || !Number.isFinite(timestampMs) || timestampMs <= 0) {
    return null;
  }
  return Math.max(0, estimatedServerNowMs - timestampMs);
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
