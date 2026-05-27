import type { Vector3 } from "three";
import type { ChatMessage } from "../../domain/chat/types";
import type { AoiPriorityBand, MovementAck, RemoteMoveSnapshot } from "@domain/movement/types";
import type { FChunkCoord, FMacroCoord, FMicroCoord } from "../../voxel/core/types";
import type { EventBus, ReadonlyEventBus } from "./eventBus";

export interface ElectricPowerDraw {
  outputMode?: "dc" | "ac" | "pulse";
  voltage?: number;
  currentLimitAmps?: number;
  frequencyHz?: number;
  loadCurrentAmps?: number;
  estimatedTickEnergyJoules?: number;
  overCurrent?: boolean;
}

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
  "input:heat-selected-voxel": { source: string; targetTemperatureCelsius: number };
  "input:set-selected-voxel-temperature": {
    source: string;
    targetTemperatureCelsius: number;
    maxTicks?: number;
  };
  "input:conduct-selected-voxel": {
    source: string;
    sourcePotential: number;
    maxTicks?: number;
  };
  "input:lightning-selected-entity": {
    source: string;
    sourcePotential: number;
    maxTicks?: number;
    verticalOffsetMacros?: number;
  };
  "input:capture-conduction-endpoint": {
    role: "source" | "target";
    source: string;
  };
  "input:submit-conduction": { source: string };
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
  "chat:message-received": ChatMessage;

  "movement:reset": { start: Vector3 };
  "movement:local-step": {
    seq: number;
    clientTick: number;
    position: Vector3;
    velocity: Vector3;
    movementFlags: number;
    movementMode: string;
    collisionStatus: string;
    collisionOccupiedCount: number;
    collisionBlockedAxes: string[];
  };
  "movement:input-blocked": {
    reason: string;
    keys: {
      forward: boolean;
      backward: boolean;
      left: boolean;
      right: boolean;
    };
    jump: boolean;
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
  "world:voxel-heated": { coord: FMacroCoord; targetTemperatureCelsius: number; source: string };
  "world:voxel-temperature-set": {
    coord: FMacroCoord;
    targetTemperatureCelsius: number;
    source: string;
  };
  "world:voxel-conduction-requested": {
    sourceCoord: FMacroCoord;
    targetCoord: FMacroCoord;
    sourcePotential: number;
    source: string;
    powerSource?: {
      conductionMode?: "conductive" | "discharge";
      outputMode?: "dc" | "ac" | "pulse";
      voltage?: number;
      currentLimitAmps?: number;
      frequencyHz?: number;
      loadCurrentAmps?: number;
      energyBudgetJoules?: number;
    };
  };
  "world:lightning-effect-requested": {
    targetKind: "entity" | "voxel" | "fallback_entity";
    entityId?: number;
    sourceCoord: FMacroCoord;
    targetCoord: FMacroCoord;
    sourcePotential: number;
    source: string;
  };
  "world:voxel-conduction-accepted": {
    sourceCoord: FMacroCoord;
    targetCoord: FMacroCoord;
    sourcePotential: number;
    source: string;
    conductionMode?: "conductive" | "discharge";
    regionId?: string;
    fieldRegionCreated?: boolean;
    powerDraw?: ElectricPowerDraw;
  };
  "world:voxel-auto-circuit-accepted": {
    coord: FMacroCoord;
    source: string;
    regionId?: string;
    fieldRegionCreated?: boolean;
    sourceCount?: number;
    loadCount?: number;
    powerDraw?: ElectricPowerDraw;
  };
  "world:micro-placed": {
    macro: FMacroCoord;
    micro: FMicroCoord;
    materialId: number;
    source: string;
  };
  "world:micro-broken": { macro: FMacroCoord; micro: FMicroCoord; source: string };
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
  "world:voxel-prefab-result": {
    blueprintId: number;
    blueprintName: string;
    requestId: number;
    accepted: boolean;
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
  "world:prefab-boundary-snap-fallback": {
    prefabId: string;
    hitMacro: FMacroCoord;
    adjacentMacro: FMacroCoord;
    faceNormal: FMacroCoord;
    rejectReason: string;
    source: string;
  };
  "world:edit-rejected": { reason: string; source: string };

  // Phase 4-bis Step 4-bis-10:0x6C ObjectStateDelta 客户端处理后 emit。
  // HUD / 任意旁观者可订阅;destroyed flag 时显示一行临时提示。
  "world:object-state-delta": {
    objectId: string;
    objectVersion: string;
    flagName: "damaged" | "part_destroyed" | "destroyed" | "unknown";
    affectedChunkCount: number;
    debrisSpawned: number;
    debrisSource: "cleared_slot_cache" | "delayed_retry" | "affected_chunks_fallback" | "none";
  };

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
