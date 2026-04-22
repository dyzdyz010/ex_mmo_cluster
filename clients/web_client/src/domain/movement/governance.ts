export enum ReplayAction {
  Accepted = "accepted",
  Replayed = "replayed",
  HardSnap = "hard_snap",
  WindowTrimmed = "window_trimmed",
  ForcedReplay = "forced_replay",
  Teleport = "teleport",
  StatusOverride = "status_override",
}

export interface ReplayGovernance {
  softPositionError: number;
  hardSnapDistance: number;
  maxReplayFrames: number;
  maxPendingInputs: number;
  baseSoftPositionError: number;
  maxSoftPositionError: number;
  jitterFactor: number;
}

export interface ReplayGovernanceStats {
  totalCorrections: number;
  totalReplays: number;
  totalHardSnaps: number;
  totalWindowTrims: number;
  totalForcedReplays: number;
  totalTeleports: number;
  totalStatusOverrides: number;
  lastReplayedFrames: number;
  lastPendingInputs: number;
  lastCorrectionDistance: number;
}

export const DEFAULT_REPLAY_GOVERNANCE: ReplayGovernance = {
  softPositionError: 2,
  hardSnapDistance: 256,
  maxReplayFrames: 32,
  maxPendingInputs: 64,
  baseSoftPositionError: 2,
  maxSoftPositionError: 8,
  jitterFactor: 0.02,
};

export function makeReplayGovernanceStats(): ReplayGovernanceStats {
  return {
    totalCorrections: 0,
    totalReplays: 0,
    totalHardSnaps: 0,
    totalWindowTrims: 0,
    totalForcedReplays: 0,
    totalTeleports: 0,
    totalStatusOverrides: 0,
    lastReplayedFrames: 0,
    lastPendingInputs: 0,
    lastCorrectionDistance: 0,
  };
}

export function effectiveSoftPositionError(governance: ReplayGovernance, jitterMs: number): number {
  const raw = governance.baseSoftPositionError + Math.max(0, jitterMs) * governance.jitterFactor;
  return Math.min(governance.maxSoftPositionError, Math.max(governance.baseSoftPositionError, raw));
}

export function recordReplayAction(
  stats: ReplayGovernanceStats,
  action: ReplayAction,
  replayedFrames: number,
  pendingInputs: number,
  correctionDistance: number,
): void {
  stats.totalCorrections += 1;
  stats.lastReplayedFrames = replayedFrames;
  stats.lastPendingInputs = pendingInputs;
  stats.lastCorrectionDistance = correctionDistance;

  switch (action) {
    case ReplayAction.Replayed:
      stats.totalReplays += 1;
      break;
    case ReplayAction.HardSnap:
      stats.totalHardSnaps += 1;
      break;
    case ReplayAction.WindowTrimmed:
      stats.totalReplays += 1;
      stats.totalWindowTrims += 1;
      break;
    case ReplayAction.ForcedReplay:
      stats.totalReplays += 1;
      stats.totalForcedReplays += 1;
      break;
    case ReplayAction.Teleport:
      stats.totalHardSnaps += 1;
      stats.totalTeleports += 1;
      break;
    case ReplayAction.StatusOverride:
      stats.totalStatusOverrides += 1;
      break;
    case ReplayAction.Accepted:
      break;
  }
}
