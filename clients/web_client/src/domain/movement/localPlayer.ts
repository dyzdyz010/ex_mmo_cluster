import { Vector2, type Vector3 } from "three";
import {
  DEFAULT_REPLAY_GOVERNANCE,
  effectiveSoftPositionError,
  makeReplayGovernanceStats,
  recordReplayAction,
  type ReplayGovernance,
  type ReplayGovernanceStats,
} from "./governance";
import { InputHistory, PredictedHistory } from "./history";
import { DEFAULT_MOVEMENT_PROFILE, type MovementProfile } from "./profile";
import { step } from "./predictor";
import { reconcile, type ReconcileResult } from "./reconcile";
import {
  cloneCollisionSummary,
  disabledCollisionSummary,
  type MovementCollisionResolver,
  type MovementCollisionSummary,
} from "./collision";
import {
  MovementFlag,
  makeIdleState,
  type MoveInputFrame,
  type MovementAck,
  type PredictedMoveState,
} from "./types";

export class LocalPredictionRuntime {
  private nextSeq = 1;
  private nextTick = 1;
  private currentState: PredictedMoveState | null = null;
  private readonly inputHistory = new InputHistory(128);
  private readonly predictedHistory = new PredictedHistory(256);
  private readonly governanceStats: ReplayGovernanceStats = makeReplayGovernanceStats();
  private smoothedRttMs: number | null = null;
  private smoothedJitterMs = 0;
  private collisionResolver: MovementCollisionResolver | null = null;
  private lastCollisionSummary: MovementCollisionSummary | null = null;

  constructor(
    private readonly profile: MovementProfile = DEFAULT_MOVEMENT_PROFILE,
    private readonly governance: ReplayGovernance = { ...DEFAULT_REPLAY_GOVERNANCE },
  ) {}

  reset(position: Vector3): void {
    this.resetWithSeq(position, 1);
  }

  /**
   * Audit B-S1 / B-SRV1 (bevy sweep 2026-04-26): align the local input
   * counter to whatever value the server told us via
   * `EnterSceneOkMessage.expectedSeq`. Drops the implicit "both sides
   * always start at 1" contract so a future server-side session reuse
   * does not silently desync.
   */
  resetWithSeq(position: Vector3, nextSeq: number): void {
    this.nextSeq = Math.max(1, Math.trunc(nextSeq));
    this.nextTick = 1;
    this.inputHistory.clear();
    this.predictedHistory.clear();
    Object.assign(this.governanceStats, makeReplayGovernanceStats());
    this.smoothedRttMs = null;
    this.smoothedJitterMs = 0;

    const state = makeIdleState(position);
    this.predictedHistory.push(state);
    this.currentState = state;
  }

  setCollisionResolver(resolver: MovementCollisionResolver | null): void {
    this.collisionResolver = resolver;
    this.lastCollisionSummary = null;
  }

  buildInputFrame(
    inputDir: Vector2,
    dtMs: number,
    speedScale: number,
    jumpRequested = false,
  ): MoveInputFrame {
    let movementFlags = inputDir.lengthSq() <= 1e-6 ? MovementFlag.Brake : MovementFlag.None;
    if (jumpRequested) {
      movementFlags |= MovementFlag.Jump;
    }
    const frame: MoveInputFrame = {
      seq: this.nextSeq,
      clientTick: this.nextTick,
      dtMs,
      inputDir: inputDir.clone(),
      speedScale,
      movementFlags,
    };
    this.nextSeq += 1;
    this.nextTick += 1;
    return frame;
  }

  applyLocalInput(frame: MoveInputFrame): PredictedMoveState | null {
    if (!this.currentState) {
      return null;
    }
    this.inputHistory.push(frame);
    const next = this.stepWithCollision(this.currentState, frame, this.profile);
    this.predictedHistory.push(next);
    this.currentState = next;
    return {
      ...next,
      position: next.position.clone(),
      velocity: next.velocity.clone(),
      acceleration: next.acceleration.clone(),
    };
  }

  applyAck(ack: MovementAck): ReconcileResult | null {
    // Phase A1-4: server now sends authoritative ground_z on every ack
    // (跟 launch tick 时锁定的 ground 一致),client 直接用,不再本地 hack
    // groundY = position.y(本地 hack 在 airborne 时会让 groundY 跟着 position
    // 升,导致永不落地)。
    this.extendPredictionThrough(ack.authTick);
    this.nextTick = Math.max(this.nextTick, ack.authTick + 1);
    this.governance.softPositionError = effectiveSoftPositionError(
      this.governance,
      this.smoothedJitterMs,
    );

    const result = reconcile(
      ack,
      this.inputHistory,
      this.predictedHistory,
      this.profile,
      this.governance,
      (previous, frame, profile) => this.stepWithCollision(previous, frame, profile),
    );
    if (!result) {
      return null;
    }

    recordReplayAction(
      this.governanceStats,
      result.action,
      result.replayedFrames,
      result.pendingInputs,
      result.correctionDistance,
    );
    this.currentState = result.latestState;
    return result;
  }

  observeRtt(rttMs: number): void {
    if (!Number.isFinite(rttMs)) {
      return;
    }

    const sample = Math.max(0, rttMs);
    if (this.smoothedRttMs === null) {
      this.smoothedRttMs = sample;
      this.smoothedJitterMs = 0;
      return;
    }

    const delta = Math.abs(sample - this.smoothedRttMs);
    this.smoothedRttMs = this.smoothedRttMs * 0.85 + sample * 0.15;
    this.smoothedJitterMs = this.smoothedJitterMs * 0.85 + delta * 0.15;
  }

  getCurrentState(): PredictedMoveState | null {
    return this.currentState
      ? {
          ...this.currentState,
          position: this.currentState.position.clone(),
          velocity: this.currentState.velocity.clone(),
          acceleration: this.currentState.acceleration.clone(),
        }
      : null;
  }

  /**
   * Read-only hot-path accessor for render sampling. Callers must not mutate
   * the returned vectors or state object.
   */
  peekCurrentState(): Readonly<PredictedMoveState> | null {
    return this.currentState;
  }

  getGovernanceStats(): ReplayGovernanceStats {
    return { ...this.governanceStats };
  }

  getCurrentJitterMs(): number {
    return this.smoothedJitterMs;
  }

  getCurrentSoftPositionError(): number {
    return this.governance.softPositionError;
  }

  getLastCollisionSummary(): MovementCollisionSummary | null {
    return this.lastCollisionSummary ? cloneCollisionSummary(this.lastCollisionSummary) : null;
  }

  predictFrom(state: PredictedMoveState, frame: MoveInputFrame): PredictedMoveState {
    return this.stepWithCollision(state, frame, this.profile);
  }

  private extendPredictionThrough(authTick: number): void {
    if (!this.currentState) {
      return;
    }

    while (this.currentState.tick < authTick) {
      const idleFrame: MoveInputFrame = {
        seq: 0,
        clientTick: this.currentState.tick + 1,
        dtMs: this.profile.fixedDtMs,
        inputDir: new Vector2(),
        speedScale: 1,
        movementFlags: MovementFlag.Brake,
      };
      const next = this.stepWithCollision(this.currentState, idleFrame, this.profile);
      this.predictedHistory.push(next);
      this.currentState = next;
    }
  }

  private stepWithCollision(
    previous: PredictedMoveState,
    frame: MoveInputFrame,
    profile: MovementProfile,
  ): PredictedMoveState {
    const proposed = step(previous, frame, profile);
    const resolver = this.collisionResolver;

    if (!resolver) {
      this.lastCollisionSummary = disabledCollisionSummary(previous, proposed);
      return proposed;
    }

    const resolution = resolver(previous, proposed);
    this.lastCollisionSummary = cloneCollisionSummary(resolution.summary);
    return resolution.state;
  }
}
