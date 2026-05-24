import { Vector3 } from "three";
import { describe, expect, it } from "vitest";
import { MovementMode, type PredictedMoveState } from "@domain/movement/types";
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
