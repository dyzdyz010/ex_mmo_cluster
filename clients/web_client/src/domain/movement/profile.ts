export interface MovementProfile {
  fixedDtMs: number;
  maxSpeed: number;
  maxAccel: number;
  maxDecel: number;
  maxJerk: number;
}

export const DEFAULT_MOVEMENT_PROFILE: MovementProfile = {
  fixedDtMs: 100,
  maxSpeed: 220,
  maxAccel: 1200,
  maxDecel: 1400,
  maxJerk: 9000,
};
