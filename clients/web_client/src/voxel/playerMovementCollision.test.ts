import { Vector3 } from "three";
import { describe, expect, it } from "vitest";
import { MovementMode, type PredictedMoveState } from "@domain/movement/types";
import { chunkCoordFromMacro } from "./core/gridUtils";
import type { FChunkCoord } from "./core/types";
import { createWorldStoreMovementCollisionResolver } from "./playerMovementCollision";
import { WorldStore } from "./worldStore";

describe("player movement voxel collision", () => {
  it("blocks horizontal prediction against solid world voxels at body height", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 9, y: 1, z: 7 }, stoneBlock());

    const resolver = createWorldStoreMovementCollisionResolver(world);
    const previous = stateAt(new Vector3(750, 185, 750));
    const proposed = stateAt(new Vector3(900, 185, 750));
    proposed.velocity.set(500, 0, 0);
    proposed.acceleration.set(3000, 0, 0);

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("resolved");
    expect(result.summary.occupiedCount).toBeGreaterThan(0);
    expect(result.summary.blockedAxes).toEqual(["x"]);
    expect(result.state.position.x).toBe(750);
    expect(result.state.velocity.x).toBe(0);
    expect(result.state.acceleration.x).toBe(0);
  });

  it("blocks prediction against known authoritative voxel chunks in online mode", () => {
    const world = new WorldStore();
    const blocker = { x: 9, y: 1, z: 7 };
    world.setNormalBlockWorld(blocker, stoneBlock());
    markAuthoritative(world, chunkCoordFromMacro(blocker));

    const resolver = createWorldStoreMovementCollisionResolver(world, {
      requireAuthoritativeChunks: true,
    });
    const previous = stateAt(new Vector3(750, 185, 750));
    const proposed = stateAt(new Vector3(900, 185, 750));
    proposed.velocity.set(500, 0, 0);
    proposed.acceleration.set(3000, 0, 0);

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("resolved");
    expect(result.summary.blockedAxes).toEqual(["x"]);
    expect(result.state.position.x).toBe(750);
  });

  it("holds prediction when online movement lacks authoritative voxel chunk data", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 9, y: 1, z: 7 }, stoneBlock());

    const resolver = createWorldStoreMovementCollisionResolver(world, {
      requireAuthoritativeChunks: true,
    });
    const previous = stateAt(new Vector3(750, 185, 750));
    const proposed = stateAt(new Vector3(900, 185, 750));
    proposed.velocity.set(500, 0, 0);
    proposed.acceleration.set(3000, 0, 0);

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("authority_unavailable");
    expect(result.summary.occupiedCount).toBe(0);
    expect(result.summary.blockedAxes).toEqual([]);
    expect(result.state.position.x).toBe(750);
  });

  it("prewarms nearby authoritative chunks without treating them as required for this collision", () => {
    const world = new WorldStore();
    markEmptyAuthoritative(world, { x: 0, y: 0, z: 0 });
    const requestedChunks: FChunkCoord[] = [];

    const resolver = createWorldStoreMovementCollisionResolver(world, {
      requireAuthoritativeChunks: true,
      authorityPrewarmMarginCm: 200,
      requestAuthoritativeChunks: (chunks: readonly FChunkCoord[]) => {
        requestedChunks.push(...chunks.map((chunk) => ({ ...chunk })));
      },
    } as Parameters<typeof createWorldStoreMovementCollisionResolver>[1] & {
      authorityPrewarmMarginCm: number;
      requestAuthoritativeChunks: (chunks: readonly FChunkCoord[]) => void;
    });
    const previous = stateAt(new Vector3(1510, 185, 750));
    const proposed = stateAt(new Vector3(1510, 185, 750));

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("clear");
    expect(requestedChunks).toContainEqual({ x: 1, y: 0, z: 0 });
    expect(requestedChunks).not.toContainEqual({ x: 0, y: 0, z: 0 });
  });

  it("requests the missing strict authoritative chunks before failing open", () => {
    const world = new WorldStore();
    const requestedChunks: FChunkCoord[] = [];

    const resolver = createWorldStoreMovementCollisionResolver(world, {
      requireAuthoritativeChunks: true,
      requestAuthoritativeChunks: (chunks: readonly FChunkCoord[]) => {
        requestedChunks.push(...chunks.map((chunk) => ({ ...chunk })));
      },
    } as Parameters<typeof createWorldStoreMovementCollisionResolver>[1] & {
      requestAuthoritativeChunks: (chunks: readonly FChunkCoord[]) => void;
    });
    const previous = stateAt(new Vector3(750, 185, 750));
    const proposed = stateAt(new Vector3(750, 185, 750));

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("authority_unavailable");
    expect(requestedChunks).toContainEqual({ x: 0, y: 0, z: 0 });
  });

  it("keeps floor contact half-open so a grounded center does not collide with floor blocks", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 7, y: 0, z: 7 }, stoneBlock());

    const resolver = createWorldStoreMovementCollisionResolver(world);
    const previous = stateAt(new Vector3(750, 185, 750));
    const proposed = stateAt(new Vector3(750, 185, 750));

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("clear");
    expect(result.summary.occupiedCount).toBe(0);
    expect(result.state.position.y).toBe(185);
  });

  it("lands falling prediction on top of occupied voxels", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 7, y: 0, z: 7 }, stoneBlock());

    const resolver = createWorldStoreMovementCollisionResolver(world);
    const previous = stateAt(new Vector3(750, 235, 750));
    const proposed = stateAt(new Vector3(750, 135, 750));
    proposed.velocity.set(0, -300, 0);
    proposed.acceleration.set(0, -980, 0);
    proposed.movementMode = MovementMode.Airborne;

    const result = resolver(previous, proposed);

    expect(result.summary.status).toBe("resolved");
    expect(result.summary.blockedAxes).toEqual(["y"]);
    expect(result.state.position.y).toBe(185);
    expect(result.state.velocity.y).toBe(0);
    expect(result.state.movementMode).toBe(MovementMode.Grounded);
    expect(result.state.groundY).toBe(185);
  });
});

function stateAt(position: Vector3): PredictedMoveState {
  return {
    seq: 1,
    tick: 1,
    position,
    velocity: new Vector3(),
    acceleration: new Vector3(),
    movementMode: MovementMode.Grounded,
    groundY: position.y,
  };
}

function stoneBlock() {
  return {
    materialId: 1,
    stateFlags: 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

function markAuthoritative(world: WorldStore, chunkCoord: FChunkCoord): void {
  const chunk = world.getChunk(chunkCoord);
  if (!chunk) {
    throw new Error(`missing chunk ${chunkCoord.x},${chunkCoord.y},${chunkCoord.z}`);
  }

  world.replaceChunkStorage(chunk.data, {
    requestId: 1,
    logicalSceneId: 1,
    schemaVersion: 1,
    chunkVersion: 1,
    chunkHash: 1,
    receivedAtMs: 1,
  });
}

function markEmptyAuthoritative(world: WorldStore, chunkCoord: FChunkCoord): void {
  world.ensureChunk(chunkCoord);
  markAuthoritative(world, chunkCoord);
}
