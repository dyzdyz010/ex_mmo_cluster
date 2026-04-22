export interface MovementProfile {
  fixedDtMs: number;
  maxSpeed: number;
  maxAccel: number;
  maxDecel: number;
  maxJerk: number;
}

export const DEFAULT_MOVEMENT_PROFILE: MovementProfile = {
  fixedDtMs: 100,
  maxSpeed: 280,
  maxAccel: 900,
  maxDecel: 1200,
  maxJerk: 1800,
};
