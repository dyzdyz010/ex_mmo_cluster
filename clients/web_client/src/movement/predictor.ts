import { Vector3 } from "three";
import { DEFAULT_MOVEMENT_PROFILE, type MovementProfile } from "./profile";
import { MovementFlag, type MoveInputFrame, type PredictedMoveState } from "./types";

function clampLength(vector: Vector3, maxLength: number): Vector3 {
  const length = vector.length();
  if (length <= maxLength || length <= 1e-6) {
    return vector;
  }
  return vector.multiplyScalar(maxLength / length);
}

export function step(
  previous: PredictedMoveState,
  frame: MoveInputFrame,
  profile: MovementProfile = DEFAULT_MOVEMENT_PROFILE,
): PredictedMoveState {
  const dt = Math.max(frame.dtMs, 1) / 1000;
  const inputDirection = frame.inputDir.clone();
  if (inputDirection.lengthSq() > 1e-6) {
    inputDirection.normalize();
  } else {
    inputDirection.set(0, 0);
  }

  const desiredVelocity = new Vector3(
    inputDirection.x * profile.maxSpeed * frame.speedScale,
    0,
    inputDirection.y * profile.maxSpeed * frame.speedScale,
  );

  const horizontalVelocity = new Vector3(previous.velocity.x, 0, previous.velocity.z);
  const velocityDelta = desiredVelocity.clone().sub(horizontalVelocity);
  const braking =
    desiredVelocity.lengthSq() === 0 || (frame.movementFlags & MovementFlag.Brake) !== 0;
  const accelLimit = braking ? profile.maxDecel : profile.maxAccel;
  const clampedVelocityDelta = clampLength(velocityDelta, accelLimit * dt);
  const candidateVelocity = horizontalVelocity.clone().add(clampedVelocityDelta);

  const rawAcceleration = candidateVelocity.clone().sub(horizontalVelocity).divideScalar(dt);
  const jerkDelta = rawAcceleration.clone().sub(previous.acceleration);
  const clampedAcceleration = previous.acceleration
    .clone()
    .add(clampLength(jerkDelta, profile.maxJerk * dt));

  const nextVelocity = previous.velocity.clone().add(clampedAcceleration.clone().multiplyScalar(dt));
  nextVelocity.y = 0;

  if (desiredVelocity.lengthSq() > 0 && nextVelocity.length() > desiredVelocity.length()) {
    nextVelocity.copy(desiredVelocity);
  }
  if (desiredVelocity.lengthSq() === 0 && nextVelocity.length() < 1) {
    nextVelocity.set(0, 0, 0);
  }

  const nextPosition = previous.position.clone().add(nextVelocity.clone().multiplyScalar(dt));

  return {
    seq: frame.seq,
    tick: frame.clientTick,
    position: nextPosition,
    velocity: nextVelocity,
    acceleration: clampedAcceleration,
  };
}
