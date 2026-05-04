import type { Vector3 } from "three";
import type { AoiPriorityBand, MovementAck, RemoteMoveSnapshot } from "@domain/movement/types";
import type { FChunkCoord, FMacroCoord, FMicroCoord } from "../../voxel/core/types";
import type { EventBus, ReadonlyEventBus } from "./eventBus";

/**
 * Central event dictionary. Each key names an event; each value is its payload.
 *
 * Conventions:
 * - Names are `namespace:verb` so grep stays cheap.
 * - Payloads are plain data objects. Three.js `Vector3` appears as the domain
 *   vector primitive; subscribers must clone before mutating.
 * - One-shot, discrete actions go through the bus. Continuous per-frame state
 *   (movement keys, rendered positions, selection) is pulled from the owning
 *   controller directly via typed provider interfaces in `app/controllers`.
 */
export type AppEvents = {
  "input:material-selected": { materialId: number; source: string };
  "input:prefab-selected": { prefabName: string; source: string };
  "input:hotbar-cycle": { direction: -1 | 1; source: string };
  "input:hotbar-select": { index: number; source: string };
  "input:place-block": { source: string };
  "input:break-block": { source: string };
  "input:jump": { source: string };

  // Audit B-S1 / B-SRV2: expectedSeq is the server-reported next-input
  // seq the client must align its local counter to before sending any
  // movement input.
  "transport:spawn": { position: Vector3; expectedSeq: number };
  "transport:mode-changed": { mode: string };
  "transport:ack-delivered": { ack: MovementAck; sentAtMs: number };
  "transport:snapshot-delivered": { snapshot: RemoteMoveSnapshot };
  "transport:entity-entered": { cid: number; position: Vector3 };
  "transport:entity-left": { cid: number };
  "transport:time-sync": {
    requestId: number;
    clientSendTs: number;
    serverRecvTs: number;
    serverSendTs: number;
  };

  "movement:reset": { start: Vector3 };
  "movement:local-step": {
    seq: number;
    clientTick: number;
    position: Vector3;
    velocity: Vector3;
    movementFlags: number;
    movementMode: string;
  };
  "movement:authority-applied": {
    action: string;
    ackSeq: number;
    authTick: number;
    correctionDistance: number;
    pendingInputs: number;
    replayedFrames: number;
    rttMs: number;
    movementMode: string;
    velocity: Vector3;
    serverFixedDtMs: number;
    fixedDtDriftMs: number;
  };
  "movement:remote-snapshot-ingested": {
    cid: number;
    serverTick: number;
    position: Vector3;
    movementMode: string;
    priorityBand?: AoiPriorityBand;
    priorityScore?: number;
    observerDistance?: number;
    deliveryInterval?: number;
  };

  "world:block-placed": { coord: FMacroCoord; materialId: number; source: string };
  "world:block-broken": { coord: FMacroCoord; source: string };
  "world:chunk-subscribed": {
    requestId: number;
    logicalSceneId: number;
    centerChunk: FChunkCoord;
    radiusLInf: number;
  };
  "world:chunk-snapshot-applied": {
    requestId: number;
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    chunkVersion: number;
    chunkHash: number;
    solidBlocks: number;
  };
  "world:chunk-delta-applied": {
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    baseChunkVersion: number;
    newChunkVersion: number;
    opCount: number;
    appliedOps: number;
  };
  "world:chunk-delta-skipped": {
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    baseChunkVersion: number;
    newChunkVersion: number;
    reason: "chunk_not_loaded" | "stale_base_version";
    knownChunkVersion?: number;
  };
  "world:chunk-invalidated": {
    logicalSceneId: number;
    chunkCoord: FChunkCoord;
    reason: string;
  };
  "world:voxel-intent-result": {
    requestId: number;
    clientIntentSeq: number;
    logicalSceneId: number;
    resultCodeName: string;
    resultRef: number;
    reason: string;
  };
  "world:voxel-sync-error": { reason: string; source: string };
  "world:prefab-placed": { name: string; origin: FMacroCoord; placed: number; source: string };
  "world:prefab-snap-committed": {
    prefabId: string;
    instanceId: number;
    targetInstanceId: number;
    socketId: string | null;
    targetSocketId: string;
    anchorMicroCoord: FMicroCoord;
    affectedMacroCount: number;
    incomingOccupiedSlots: number;
    overlapSlots: number;
    source: string;
  };
  "world:prefab-snap-rejected": {
    prefabId: string;
    targetInstanceId: number;
    socketId: string | null;
    targetSocketId: string;
    anchorMicroCoord: FMicroCoord | null;
    affectedMacroCount: number;
    incomingOccupiedSlots: number;
    overlapSlots: number;
    rejectReason: string;
    source: string;
  };
  "world:prefab-boundary-snap-committed": {
    prefabId: string;
    instanceId: number;
    hitMacro: FMacroCoord;
    faceNormal: FMacroCoord;
    anchorMicroCoord: FMicroCoord;
    affectedMacroCount: number;
    incomingOccupiedSlots: number;
    overlapSlots: number;
    contactSlots: number;
    source: string;
  };
  "world:prefab-boundary-snap-rejected": {
    prefabId: string;
    hitMacro: FMacroCoord;
    faceNormal: FMacroCoord;
    anchorMicroCoord: FMicroCoord | null;
    affectedMacroCount: number;
    incomingOccupiedSlots: number;
    overlapSlots: number;
    contactSlots: number;
    rejectReason: string;
    source: string;
  };
  "world:edit-rejected": { reason: string; source: string };

  "app:boot": {
    chunks: number;
    solidBlocks: number;
    selectedMaterialId: number;
    transportMode: string;
    worldMode: string;
  };
};

export type AppEventBus = EventBus<AppEvents>;
export type ReadonlyAppEventBus = ReadonlyEventBus<AppEvents>;
