import {
  CorrectionFlag,
  clonePredictedMoveState,
  type MovementAck,
  type PredictedMoveState,
} from "./types";
import type { ReplayGovernance } from "./governance";
import { ReplayAction } from "./governance";
import type { InputHistory, PredictedHistory } from "./history";
import type { MovementProfile } from "./profile";
import { step } from "./predictor";
import type { MoveInputFrame } from "./types";

export interface ReconcileResult {
  action: ReplayAction;
  latestState: PredictedMoveState;
  replayedFrames: number;
  pendingInputs: number;
  correctionDistance: number;
}

export type MovementStepFunction = (
  previous: PredictedMoveState,
  frame: MoveInputFrame,
  profile: MovementProfile,
) => PredictedMoveState;

function authoritativeFromAck(ack: MovementAck): PredictedMoveState {
  return {
    seq: ack.ackSeq,
    tick: ack.authTick,
    position: ack.position.clone(),
    velocity: ack.velocity.clone(),
    acceleration: ack.acceleration.clone(),
    movementMode: ack.movementMode,
    // Phase A1-4: groundY is required on the wire (not optional anymore).
    // Server's launch_ground_z is echoed every ack so the predictor can
    // land at the correct z during a replayed jump arc.
    groundY: ack.groundY,
  };
}

export function reconcile(
  ack: MovementAck,
  inputHistory: InputHistory,
  predictedHistory: PredictedHistory,
  profile: MovementProfile,
  governance: ReplayGovernance,
  predictStep: MovementStepFunction = step,
): ReconcileResult | null {
  const authoritative = authoritativeFromAck(ack);

  if (
    (ack.correctionFlags & CorrectionFlag.Teleport) !== 0 ||
    (ack.correctionFlags & CorrectionFlag.AntiCheatReject) !== 0
  ) {
    inputHistory.clear();
    predictedHistory.clear();
    predictedHistory.push(authoritative);
    return {
      action: ReplayAction.Teleport,
      latestState: clonePredictedMoveState(authoritative),
      replayedFrames: 0,
      pendingInputs: 0,
      correctionDistance: 0,
    };
  }

  if (ack.ackSeq > 0) {
    inputHistory.dropThroughSeq(ack.ackSeq);
  } else {
    inputHistory.dropThroughTick(ack.authTick);
  }

  const pendingFrames =
    ack.ackSeq > 0
      ? inputHistory.framesAfterSeq(ack.ackSeq)
      : inputHistory.framesAfterTick(ack.authTick);
  const pendingInputs = pendingFrames.length;

  const forceReplay = (ack.correctionFlags & CorrectionFlag.CollisionPush) !== 0;
  const predictedMatch =
    predictedHistory.stateAtTick(ack.authTick) ?? predictedHistory.stateAtSeq(ack.ackSeq);

  if (!predictedMatch) {
    predictedHistory.clear();
    predictedHistory.push(authoritative);

    let replayState = clonePredictedMoveState(authoritative);
    for (const frame of pendingFrames) {
      replayState = predictStep(replayState, frame, profile);
      predictedHistory.push(replayState);
    }

    return {
      action: pendingFrames.length > 0 ? ReplayAction.Replayed : ReplayAction.Accepted,
      latestState: clonePredictedMoveState(replayState),
      replayedFrames: pendingFrames.length,
      pendingInputs,
      correctionDistance: 0,
    };
  }

  const correctionDistance = predictedMatch.position.distanceTo(authoritative.position);
  const modeMismatch = predictedMatch.movementMode !== authoritative.movementMode;

  if ((ack.correctionFlags & CorrectionFlag.StatusOverride) !== 0) {
    predictedHistory.replaceFromTick(authoritative.tick, authoritative);
    return {
      action: ReplayAction.StatusOverride,
      latestState: clonePredictedMoveState(authoritative),
      replayedFrames: 0,
      pendingInputs,
      correctionDistance,
    };
  }

  if (correctionDistance <= governance.softPositionError && !forceReplay && !modeMismatch) {
    const latest = predictedHistory.latest();
    if (!latest || authoritative.tick >= latest.tick) {
      predictedHistory.replaceFromTick(authoritative.tick, authoritative);
    }
    return {
      action: ReplayAction.Accepted,
      latestState: predictedHistory.latest() ?? clonePredictedMoveState(authoritative),
      replayedFrames: 0,
      pendingInputs,
      correctionDistance,
    };
  }

  if (correctionDistance >= governance.hardSnapDistance) {
    inputHistory.clear();
    predictedHistory.clear();
    predictedHistory.push(authoritative);
    return {
      action: ReplayAction.HardSnap,
      latestState: clonePredictedMoveState(authoritative),
      replayedFrames: 0,
      pendingInputs,
      correctionDistance,
    };
  }

  predictedHistory.replaceFromTick(authoritative.tick, authoritative);

  let replayFrames = pendingFrames;
  let action = forceReplay ? ReplayAction.ForcedReplay : ReplayAction.Replayed;
  if (replayFrames.length > governance.maxReplayFrames) {
    replayFrames = replayFrames.slice(-governance.maxReplayFrames);
    inputHistory.retainRecent(governance.maxPendingInputs);
    action = ReplayAction.WindowTrimmed;
  }

  let replayState = clonePredictedMoveState(authoritative);
  for (const frame of replayFrames) {
    replayState = predictStep(replayState, frame, profile);
    predictedHistory.push(replayState);
  }

  return {
    action,
    latestState: clonePredictedMoveState(replayState),
    replayedFrames: replayFrames.length,
    pendingInputs,
    correctionDistance,
  };
}
