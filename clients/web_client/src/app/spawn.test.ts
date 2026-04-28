import { describe, expect, it } from "vitest";
import { LocalVoxelWorldAdapter } from "../voxel/worldAdapter";
import {
  DEFAULT_LOCAL_SPAWN_X,
  DEFAULT_LOCAL_SPAWN_Z,
  LOCAL_AVATAR_HALF_HEIGHT,
  resolveInitialLocalSpawn,
} from "./spawn";

describe("resolveInitialLocalSpawn", () => {
  it("grounds the initial local actor center on the seeded terrain surface", () => {
    const world = new LocalVoxelWorldAdapter();
    world.bootstrap();

    const spawn = resolveInitialLocalSpawn(world);

    expect(spawn.x).toBe(DEFAULT_LOCAL_SPAWN_X);
    expect(spawn.z).toBe(DEFAULT_LOCAL_SPAWN_Z);
    expect(spawn.y).toBe(
      world.store.surfaceCenterYAtWorldXZ(
        DEFAULT_LOCAL_SPAWN_X,
        DEFAULT_LOCAL_SPAWN_Z,
        LOCAL_AVATAR_HALF_HEIGHT,
        LOCAL_AVATAR_HALF_HEIGHT,
      ),
    );
    expect(spawn.y).toBeGreaterThan(LOCAL_AVATAR_HALF_HEIGHT);
    expect(spawn.y).toBeLessThan(650);
  });

  it("falls back to the avatar half height when no terrain exists", () => {
    const world = new LocalVoxelWorldAdapter();

    expect(resolveInitialLocalSpawn(world).y).toBe(LOCAL_AVATAR_HALF_HEIGHT);
  });
});
