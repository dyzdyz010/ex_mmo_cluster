import { Vector3 } from "three";
import { DEFAULT_MOVEMENT_PROFILE, type MovementProfile } from "./profile";
import { MovementFlag, MovementMode, type MoveInputFrame, type PredictedMoveState } from "./types";

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
  if (previous.movementMode === MovementMode.Disabled) {
    return {
      seq: frame.seq,
      tick: frame.clientTick,
      position: previous.position.clone(),
      velocity: new Vector3(),
      acceleration: new Vector3(),
      movementMode: MovementMode.Disabled,
      groundY: previous.groundY,
    };
  }

  if (
    previous.movementMode === MovementMode.Airborne ||
    (frame.movementFlags & MovementFlag.Jump) !== 0
  ) {
    return stepAirborne(previous, frame, profile);
  }

  return stepGrounded(previous, frame, profile);
}

function stepGrounded(
  previous: PredictedMoveState,
  frame: MoveInputFrame,
  profile: MovementProfile,
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

  const nextVelocity = previous.velocity
    .clone()
    .add(clampedAcceleration.clone().multiplyScalar(dt));
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
    movementMode: MovementMode.Grounded,
    groundY: nextPosition.y,
  };
}

function stepAirborne(
  previous: PredictedMoveState,
  frame: MoveInputFrame,
  profile: MovementProfile,
): PredictedMoveState {
  const dt = Math.max(frame.dtMs, 1) / 1000;
  const inputDirection = frame.inputDir.clone();
  if (inputDirection.lengthSq() > 1e-6) {
    inputDirection.normalize();
  } else {
    inputDirection.set(0, 0);
  }

  const launchTick =
    previous.movementMode === MovementMode.Grounded &&
    (frame.movementFlags & MovementFlag.Jump) !== 0;
  const groundY = launchTick ? previous.position.y : previous.groundY;
  const horizontalVelocity = new Vector3(previous.velocity.x, 0, previous.velocity.z);
  const desiredHorizontal = new Vector3(
    inputDirection.x * profile.maxSpeed * frame.speedScale,
    0,
    inputDirection.y * profile.maxSpeed * frame.speedScale,
  );
  const horizontalDelta = desiredHorizontal
    .sub(horizontalVelocity)
    .clampLength(0, profile.airAccel * profile.airControl * dt);
  const startVy = launchTick ? profile.jumpImpulse : previous.velocity.y;
  const nextVelocity = new Vector3(
    previous.velocity.x + horizontalDelta.x,
    Math.max(startVy - profile.gravity * dt, -profile.maxFallSpeed),
    previous.velocity.z + horizontalDelta.z,
  );
  const nextAcceleration = new Vector3(
    horizontalDelta.x / dt,
    -profile.gravity,
    horizontalDelta.z / dt,
  );
  const nextPosition = previous.position.clone().add(nextVelocity.clone().multiplyScalar(dt));
  let movementMode: MovementMode = MovementMode.Airborne;

  if (nextPosition.y <= groundY && nextVelocity.y <= 0) {
    nextPosition.y = groundY;
    nextVelocity.y = 0;
    nextAcceleration.y = 0;
    movementMode = MovementMode.Grounded;
  }

  return {
    seq: frame.seq,
    tick: frame.clientTick,
    position: nextPosition,
    velocity: nextVelocity,
    acceleration: nextAcceleration,
    movementMode,
    groundY,
  };
}
