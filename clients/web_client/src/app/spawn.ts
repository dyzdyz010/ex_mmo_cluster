import { Vector3 } from "three";
import type { VoxelWorldAdapter } from "../voxel/worldAdapter";

export const LOCAL_AVATAR_HALF_HEIGHT = 60;
export const DEFAULT_LOCAL_SPAWN_X = -350;
export const DEFAULT_LOCAL_SPAWN_Z = -280;

export function makeFallbackLocalSpawn(): Vector3 {
  return new Vector3(DEFAULT_LOCAL_SPAWN_X, LOCAL_AVATAR_HALF_HEIGHT, DEFAULT_LOCAL_SPAWN_Z);
}

export function resolveInitialLocalSpawn(world: Pick<VoxelWorldAdapter, "store">): Vector3 {
  const fallback = makeFallbackLocalSpawn();
  fallback.y = world.store.surfaceCenterYAtWorldXZ(
    fallback.x,
    fallback.z,
    LOCAL_AVATAR_HALF_HEIGHT,
    LOCAL_AVATAR_HALF_HEIGHT,
  );
  return fallback;
}
