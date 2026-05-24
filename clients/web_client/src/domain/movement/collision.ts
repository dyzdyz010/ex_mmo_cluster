import type { Vector3 } from "three";
import type { PredictedMoveState } from "./types";

export type MovementCollisionAxis = "x" | "y" | "z";
export type MovementCollisionStatus = "disabled" | "clear" | "resolved" | "sample_budget_exceeded";

export interface MovementCollisionSummary {
  status: MovementCollisionStatus;
  sampleCount: number;
  occupiedCount: number;
  blockedAxes: MovementCollisionAxis[];
  previousPosition: Vector3;
  proposedPosition: Vector3;
  resolvedPosition: Vector3;
}

export interface MovementCollisionResolution {
  state: PredictedMoveState;
  summary: MovementCollisionSummary;
}

export type MovementCollisionResolver = (
  previous: PredictedMoveState,
  proposed: PredictedMoveState,
) => MovementCollisionResolution;

export function disabledCollisionSummary(
  previous: PredictedMoveState,
  proposed: PredictedMoveState,
): MovementCollisionSummary {
  return {
    status: "disabled",
    sampleCount: 0,
    occupiedCount: 0,
    blockedAxes: [],
    previousPosition: previous.position.clone(),
    proposedPosition: proposed.position.clone(),
    resolvedPosition: proposed.position.clone(),
  };
}

export function cloneCollisionSummary(summary: MovementCollisionSummary): MovementCollisionSummary {
  return {
    status: summary.status,
    sampleCount: summary.sampleCount,
    occupiedCount: summary.occupiedCount,
    blockedAxes: [...summary.blockedAxes],
    previousPosition: summary.previousPosition.clone(),
    proposedPosition: summary.proposedPosition.clone(),
    resolvedPosition: summary.resolvedPosition.clone(),
  };
}
