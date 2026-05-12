import { Vector2 } from "three";

export interface MovementKeys {
  forward: boolean;
  backward: boolean;
  left: boolean;
  right: boolean;
}

export interface MovementAxes {
  strafe: number;
  forward: number;
}

export function keysToAxes(keys: MovementKeys): MovementAxes {
  return {
    strafe: Number(keys.right) - Number(keys.left),
    forward: Number(keys.forward) - Number(keys.backward),
  };
}

export function clampUnitVec(v: { x: number; y: number }): { x: number; y: number } {
  const length = Math.hypot(v.x, v.y);
  if (length <= 1) {
    return { x: v.x, y: v.y };
  }
  return { x: v.x / length, y: v.y / length };
}

export function buildMovementWorldDirection(
  axes: MovementAxes,
  cameraYawRadians = 0,
): Vector2 {
  const cosYaw = Math.cos(cameraYawRadians);
  const sinYaw = Math.sin(cameraYawRadians);
  const worldX = axes.strafe * cosYaw + axes.forward * -sinYaw;
  const worldZ = axes.strafe * -sinYaw + axes.forward * -cosYaw;
  return new Vector2(worldX, worldZ);
}
