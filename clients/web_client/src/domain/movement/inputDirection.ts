import { Vector2 } from "three";

export function buildMovementInputDirection(keys: {
  forward: boolean;
  backward: boolean;
  left: boolean;
  right: boolean;
}, cameraYawRadians = 0): Vector2 {
  const strafe = Number(keys.right) - Number(keys.left);
  const forward = Number(keys.forward) - Number(keys.backward);
  const cosYaw = Math.cos(cameraYawRadians);
  const sinYaw = Math.sin(cameraYawRadians);

  const worldX = (strafe * cosYaw) + (forward * -sinYaw);
  const worldZ = (strafe * -sinYaw) + (forward * -cosYaw);

  return new Vector2(worldX, worldZ);
}
