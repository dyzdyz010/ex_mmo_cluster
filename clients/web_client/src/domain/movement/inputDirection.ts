import { Vector2 } from "three";

export function buildMovementInputDirection(keys: {
  forward: boolean;
  backward: boolean;
  left: boolean;
  right: boolean;
}): Vector2 {
  return new Vector2(Number(keys.right) - Number(keys.left), Number(keys.backward) - Number(keys.forward));
}
