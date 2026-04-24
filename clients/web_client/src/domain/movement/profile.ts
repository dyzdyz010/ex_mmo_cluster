export interface MovementProfile {
  fixedDtMs: number;
  maxSpeed: number;
  maxAccel: number;
  maxDecel: number;
  maxJerk: number;
  jumpImpulse: number;
  gravity: number;
  airControl: number;
  airAccel: number;
  maxFallSpeed: number;
}

export const DEFAULT_MOVEMENT_PROFILE: MovementProfile = {
  fixedDtMs: 100,
  maxSpeed: 220,
  maxAccel: 1200,
  maxDecel: 1400,
  maxJerk: 9000,
  jumpImpulse: 420,
  gravity: 980,
  airControl: 0.35,
  airAccel: 420,
  maxFallSpeed: 900,
};
