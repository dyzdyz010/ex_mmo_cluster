import { Vector3 } from "three";
import {
  type MovementCollisionAxis,
  type MovementCollisionResolver,
  type MovementCollisionSummary,
} from "@domain/movement/collision";
import {
  MovementMode,
  clonePredictedMoveState,
  type PredictedMoveState,
} from "@domain/movement/types";
import { AvatarConstants, MacroWorldSize, VoxelConstants } from "./core/constants";
import { chunkCoordFromMacro, macroCoordFromMicro, positiveModulo } from "./core/gridUtils";
import { chunkCoordKey, type FChunkCoord, type FMicroCoord } from "./core/types";
import { microMaskBit } from "./microgrid/governance";
import type { WorldStore } from "./worldStore";

interface Aabb {
  min: Vector3;
  max: Vector3;
}

interface CollisionConfig {
  radiusCm: number;
  halfHeightCm: number;
  maxSamples: number;
  requireAuthoritativeChunks: boolean;
  authorityPrewarmMarginCm: number;
  requestAuthoritativeChunks:
    | ((chunks: readonly FChunkCoord[], reason: "collision_query" | "movement_prewarm") => void)
    | undefined;
}

interface MovementCollisionOptions {
  radiusCm?: number;
  heightCm?: number;
  maxSamples?: number;
  requireAuthoritativeChunks?: boolean;
  authorityPrewarmMarginCm?: number;
  requestAuthoritativeChunks?: (
    chunks: readonly FChunkCoord[],
    reason: "collision_query" | "movement_prewarm",
  ) => void;
}

const DEFAULT_MAX_SAMPLES = 4_096;
const CM_PER_MICRO = MacroWorldSize / VoxelConstants.MicroPerMacro;
const EPSILON = 1.0e-6;

export function createWorldStoreMovementCollisionResolver(
  store: WorldStore,
  options: MovementCollisionOptions = {},
): MovementCollisionResolver {
  const config: CollisionConfig = {
    radiusCm: options.radiusCm ?? AvatarConstants.CapsuleRadiusCm,
    halfHeightCm: (options.heightCm ?? AvatarConstants.HeightCm) / 2,
    maxSamples: options.maxSamples ?? DEFAULT_MAX_SAMPLES,
    requireAuthoritativeChunks: options.requireAuthoritativeChunks ?? false,
    authorityPrewarmMarginCm: Math.max(0, options.authorityPrewarmMarginCm ?? 0),
    requestAuthoritativeChunks: options.requestAuthoritativeChunks,
  };

  return (previous, proposed) =>
    resolveWorldStoreMovementCollision(store, previous, proposed, config);
}

function resolveWorldStoreMovementCollision(
  store: WorldStore,
  previous: PredictedMoveState,
  proposed: PredictedMoveState,
  config: CollisionConfig,
) {
  const queryAabb = unionAabb(
    movementAabb(previous.position, config),
    movementAabb(proposed.position, config),
  );
  const microAabb = movementAabbToWorldMicro(queryAabb);
  const sampleCount = microAabbVolume(microAabb);

  if (sampleCount > config.maxSamples) {
    return {
      state: clonePredictedMoveState(proposed),
      summary: makeSummary(
        "sample_budget_exceeded",
        previous,
        proposed,
        proposed,
        sampleCount,
        0,
        [],
      ),
    };
  }

  if (config.requireAuthoritativeChunks) {
    const missingChunks = missingAuthoritativeChunks(store, microAabb);
    if (missingChunks.length > 0) {
      requestAuthoritativeChunks(config, missingChunks, "collision_query");
      const authorityHold = holdAtPreviousPosition(previous, proposed);
      return {
        state: authorityHold.state,
        summary: makeSummary(
          "authority_unavailable",
          previous,
          proposed,
          authorityHold.state,
          sampleCount,
          0,
          authorityHold.blockedAxes,
        ),
      };
    }
    prewarmNearbyAuthoritativeChunks(store, queryAabb, config);
  }

  const occupiedBoxes = queryOccupiedMicroBoxes(store, microAabb);
  if (occupiedBoxes.length === 0) {
    return {
      state: clonePredictedMoveState(proposed),
      summary: makeSummary("clear", previous, proposed, proposed, sampleCount, 0, []),
    };
  }

  const { state, blockedAxes } = resolveAgainstBoxes(previous, proposed, occupiedBoxes, config);

  return {
    state,
    summary: makeSummary(
      blockedAxes.length > 0 ? "resolved" : "clear",
      previous,
      proposed,
      state,
      sampleCount,
      occupiedBoxes.length,
      blockedAxes,
    ),
  };
}

function holdAtPreviousPosition(
  previous: PredictedMoveState,
  proposed: PredictedMoveState,
): { state: PredictedMoveState; blockedAxes: MovementCollisionAxis[] } {
  const state = clonePredictedMoveState(proposed);
  state.position.copy(previous.position);
  state.movementMode = previous.movementMode;
  state.groundY = previous.groundY;

  const blockedAxes: MovementCollisionAxis[] = [];
  if (Math.abs(proposed.position.x - previous.position.x) > EPSILON) {
    state.velocity.x = 0;
    state.acceleration.x = 0;
    blockedAxes.push("x");
  }
  if (Math.abs(proposed.position.y - previous.position.y) > EPSILON) {
    state.velocity.y = 0;
    state.acceleration.y = 0;
    blockedAxes.push("y");
  }
  if (Math.abs(proposed.position.z - previous.position.z) > EPSILON) {
    state.velocity.z = 0;
    state.acceleration.z = 0;
    blockedAxes.push("z");
  }

  return { state, blockedAxes };
}

function resolveAgainstBoxes(
  previous: PredictedMoveState,
  proposed: PredictedMoveState,
  boxes: Aabb[],
  config: CollisionConfig,
): { state: PredictedMoveState; blockedAxes: MovementCollisionAxis[] } {
  const previousPosition = previous.position;
  const proposedPosition = proposed.position;

  const xAttempt = tryHorizontalAxis(previousPosition, proposedPosition, "x", boxes, config);
  const zAttempt = tryHorizontalAxis(xAttempt.position, proposedPosition, "z", boxes, config);
  const yAttempt = tryVerticalAxis(
    zAttempt.position,
    previousPosition,
    proposedPosition,
    proposed,
    boxes,
    config,
  );

  const state = clonePredictedMoveState(proposed);
  state.position.copy(yAttempt.position);

  const blockedAxes: MovementCollisionAxis[] = [];
  if (xAttempt.blocked) {
    state.velocity.x = 0;
    state.acceleration.x = 0;
    blockedAxes.push("x");
  }
  if (zAttempt.blocked) {
    state.velocity.z = 0;
    state.acceleration.z = 0;
    blockedAxes.push("z");
  }
  if (yAttempt.status === "landed" || yAttempt.status === "ceiling") {
    state.velocity.y = 0;
    state.acceleration.y = 0;
    blockedAxes.push("y");
  }
  if (yAttempt.status === "landed") {
    state.movementMode = MovementMode.Grounded;
    state.groundY = state.position.y;
  } else if (yAttempt.status === "ceiling") {
    state.movementMode = MovementMode.Airborne;
  }

  return { state, blockedAxes };
}

function tryHorizontalAxis(
  currentPosition: Vector3,
  proposedPosition: Vector3,
  axis: "x" | "z",
  boxes: Aabb[],
  config: CollisionConfig,
): { position: Vector3; blocked: boolean } {
  const candidate = currentPosition.clone();
  candidate[axis] = proposedPosition[axis];

  if (collides(candidate, boxes, config)) {
    return { position: currentPosition.clone(), blocked: true };
  }
  return { position: candidate, blocked: false };
}

function tryVerticalAxis(
  currentPosition: Vector3,
  previousPosition: Vector3,
  proposedPosition: Vector3,
  proposedState: PredictedMoveState,
  boxes: Aabb[],
  config: CollisionConfig,
): { position: Vector3; status: "clear" | "landed" | "ceiling" } {
  const candidate = currentPosition.clone();
  candidate.y = proposedPosition.y;

  if (!collides(candidate, boxes, config)) {
    return { position: candidate, status: "clear" };
  }

  if (proposedPosition.y <= previousPosition.y || proposedState.velocity.y <= 0) {
    const landedY =
      landingY(candidate, previousPosition.y, proposedPosition.y, boxes, config) ??
      currentPosition.y;
    const landed = currentPosition.clone();
    landed.y = landedY;
    return { position: landed, status: "landed" };
  }

  return { position: currentPosition.clone(), status: "ceiling" };
}

function landingY(
  position: Vector3,
  previousY: number,
  proposedY: number,
  boxes: Aabb[],
  config: CollisionConfig,
): number | null {
  const minY = Math.min(previousY, proposedY) - EPSILON;
  const maxY = Math.max(previousY, proposedY) + EPSILON;
  const footprint = horizontalFootprint(position, config);
  const candidates = boxes
    .filter(
      (box) =>
        horizontalOverlap(footprint, box) &&
        box.max.y + config.halfHeightCm >= minY &&
        box.max.y + config.halfHeightCm <= maxY,
    )
    .map((box) => box.max.y + config.halfHeightCm);
  return candidates.length > 0 ? Math.max(...candidates) : null;
}

function collides(position: Vector3, boxes: Aabb[], config: CollisionConfig): boolean {
  const avatar = movementAabb(position, config);
  return boxes.some((box) => aabbOverlap(avatar, box));
}

function queryOccupiedMicroBoxes(store: WorldStore, aabb: Aabb): Aabb[] {
  const boxes: Aabb[] = [];

  for (let worldX = aabb.min.x; worldX < aabb.max.x; worldX += 1) {
    for (let worldY = aabb.min.y; worldY < aabb.max.y; worldY += 1) {
      for (let worldZ = aabb.min.z; worldZ < aabb.max.z; worldZ += 1) {
        const worldMicro = { x: worldX, y: worldY, z: worldZ };
        if (isWorldMicroOccupied(store, worldMicro)) {
          boxes.push(worldMicroToMovementBox(worldMicro));
        }
      }
    }
  }

  return boxes;
}

function missingAuthoritativeChunks(store: WorldStore, aabb: Aabb): FChunkCoord[] {
  const chunks = coveredChunkCoords(aabb);
  return chunks.filter((chunk) => store.getChunkAuthorityMetadata(chunk) === null);
}

function prewarmNearbyAuthoritativeChunks(
  store: WorldStore,
  queryAabb: Aabb,
  config: CollisionConfig,
): void {
  if (config.authorityPrewarmMarginCm <= 0 || !config.requestAuthoritativeChunks) {
    return;
  }

  const prewarmAabb = expandHorizontalAabb(queryAabb, config.authorityPrewarmMarginCm);
  const missingChunks = missingAuthoritativeChunks(store, movementAabbToWorldMicro(prewarmAabb));
  requestAuthoritativeChunks(config, missingChunks, "movement_prewarm");
}

function requestAuthoritativeChunks(
  config: CollisionConfig,
  chunks: readonly FChunkCoord[],
  reason: "collision_query" | "movement_prewarm",
): void {
  if (chunks.length === 0 || !config.requestAuthoritativeChunks) {
    return;
  }
  config.requestAuthoritativeChunks(chunks, reason);
}

function coveredChunkCoords(aabb: Aabb): FChunkCoord[] {
  if (aabb.max.x <= aabb.min.x || aabb.max.y <= aabb.min.y || aabb.max.z <= aabb.min.z) {
    return [];
  }

  const minMacro = macroCoordFromMicro({
    x: aabb.min.x,
    y: aabb.min.y,
    z: aabb.min.z,
  });
  const maxMacro = macroCoordFromMicro({
    x: aabb.max.x - 1,
    y: aabb.max.y - 1,
    z: aabb.max.z - 1,
  });

  const byKey = new Map<string, FChunkCoord>();
  for (let x = minMacro.x; x <= maxMacro.x; x += 1) {
    for (let y = minMacro.y; y <= maxMacro.y; y += 1) {
      for (let z = minMacro.z; z <= maxMacro.z; z += 1) {
        const chunk = chunkCoordFromMacro({ x, y, z });
        byKey.set(chunkCoordKey(chunk), chunk);
      }
    }
  }
  return [...byKey.values()];
}

function isWorldMicroOccupied(store: WorldStore, worldMicro: FMicroCoord): boolean {
  const worldMacro = macroCoordFromMicro(worldMicro);
  const localMicro = {
    x: positiveModulo(worldMicro.x, VoxelConstants.MicroPerMacro),
    y: positiveModulo(worldMicro.y, VoxelConstants.MicroPerMacro),
    z: positiveModulo(worldMicro.z, VoxelConstants.MicroPerMacro),
  };
  const mask = store.getMicroOccupancyMaskWorld(worldMacro);
  return (mask & microMaskBit(localMicro)) !== 0n;
}

function movementAabb(position: Vector3, config: CollisionConfig): Aabb {
  return {
    min: new Vector3(
      position.x - config.radiusCm,
      position.y - config.halfHeightCm,
      position.z - config.radiusCm,
    ),
    max: new Vector3(
      position.x + config.radiusCm,
      position.y + config.halfHeightCm,
      position.z + config.radiusCm,
    ),
  };
}

function movementAabbToWorldMicro(aabb: Aabb): Aabb {
  return {
    min: new Vector3(
      floorCmToMicro(aabb.min.x),
      floorCmToMicro(aabb.min.y),
      floorCmToMicro(aabb.min.z),
    ),
    max: new Vector3(
      ceilCmToMicro(aabb.max.x),
      ceilCmToMicro(aabb.max.y),
      ceilCmToMicro(aabb.max.z),
    ),
  };
}

function worldMicroToMovementBox(worldMicro: FMicroCoord): Aabb {
  return {
    min: new Vector3(
      worldMicro.x * CM_PER_MICRO,
      worldMicro.y * CM_PER_MICRO,
      worldMicro.z * CM_PER_MICRO,
    ),
    max: new Vector3(
      (worldMicro.x + 1) * CM_PER_MICRO,
      (worldMicro.y + 1) * CM_PER_MICRO,
      (worldMicro.z + 1) * CM_PER_MICRO,
    ),
  };
}

function horizontalFootprint(position: Vector3, config: CollisionConfig): Aabb {
  return {
    min: new Vector3(position.x - config.radiusCm, 0, position.z - config.radiusCm),
    max: new Vector3(position.x + config.radiusCm, 0, position.z + config.radiusCm),
  };
}

function horizontalOverlap(footprint: Aabb, box: Aabb): boolean {
  return (
    footprint.min.x < box.max.x &&
    footprint.max.x > box.min.x &&
    footprint.min.z < box.max.z &&
    footprint.max.z > box.min.z
  );
}

function aabbOverlap(a: Aabb, b: Aabb): boolean {
  return (
    a.min.x < b.max.x &&
    a.max.x > b.min.x &&
    a.min.y < b.max.y &&
    a.max.y > b.min.y &&
    a.min.z < b.max.z &&
    a.max.z > b.min.z
  );
}

function unionAabb(a: Aabb, b: Aabb): Aabb {
  return {
    min: new Vector3(
      Math.min(a.min.x, b.min.x),
      Math.min(a.min.y, b.min.y),
      Math.min(a.min.z, b.min.z),
    ),
    max: new Vector3(
      Math.max(a.max.x, b.max.x),
      Math.max(a.max.y, b.max.y),
      Math.max(a.max.z, b.max.z),
    ),
  };
}

function expandHorizontalAabb(aabb: Aabb, marginCm: number): Aabb {
  if (marginCm <= 0) {
    return {
      min: aabb.min.clone(),
      max: aabb.max.clone(),
    };
  }

  return {
    min: new Vector3(aabb.min.x - marginCm, aabb.min.y, aabb.min.z - marginCm),
    max: new Vector3(aabb.max.x + marginCm, aabb.max.y, aabb.max.z + marginCm),
  };
}

function microAabbVolume(aabb: Aabb): number {
  return (
    Math.max(aabb.max.x - aabb.min.x, 0) *
    Math.max(aabb.max.y - aabb.min.y, 0) *
    Math.max(aabb.max.z - aabb.min.z, 0)
  );
}

function floorCmToMicro(value: number): number {
  return Math.floor((value * VoxelConstants.MicroPerMacro) / MacroWorldSize);
}

function ceilCmToMicro(value: number): number {
  return Math.ceil((value * VoxelConstants.MicroPerMacro) / MacroWorldSize);
}

function makeSummary(
  status: MovementCollisionSummary["status"],
  previous: PredictedMoveState,
  proposed: PredictedMoveState,
  resolved: PredictedMoveState,
  sampleCount: number,
  occupiedCount: number,
  blockedAxes: MovementCollisionAxis[],
): MovementCollisionSummary {
  return {
    status,
    sampleCount,
    occupiedCount,
    blockedAxes: [...blockedAxes],
    previousPosition: previous.position.clone(),
    proposedPosition: proposed.position.clone(),
    resolvedPosition: resolved.position.clone(),
  };
}
