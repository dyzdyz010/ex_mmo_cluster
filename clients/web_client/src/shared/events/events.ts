import type { Vector3 } from "three";
import type { MovementAck, RemoteMoveSnapshot } from "../../movement/types";
import type { FMacroCoord } from "../../voxel/core/types";
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
  "input:place-block": { source: string };
  "input:break-block": { source: string };

  "transport:spawn": { position: Vector3 };
  "transport:mode-changed": { mode: string };
  "transport:ack-delivered": { ack: MovementAck; sentAtMs: number };
  "transport:snapshot-delivered": { snapshot: RemoteMoveSnapshot };

  "movement:reset": { start: Vector3 };
  "movement:local-step": {
    seq: number;
    clientTick: number;
    position: Vector3;
  };
  "movement:authority-applied": {
    action: string;
    ackSeq: number;
    authTick: number;
    correctionDistance: number;
    pendingInputs: number;
    replayedFrames: number;
    rttMs: number;
  };
  "movement:remote-snapshot-ingested": {
    cid: number;
    serverTick: number;
    position: Vector3;
  };

  "world:block-placed": { coord: FMacroCoord; materialId: number; source: string };
  "world:block-broken": { coord: FMacroCoord; source: string };
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
