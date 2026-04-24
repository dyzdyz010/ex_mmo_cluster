import { Vector3 } from "three";
import { describe, expect, it } from "vitest";
import { MovementMode, type RemoteMoveSnapshot } from "@domain/movement/types";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { RemotePlayerController } from "./remotePlayerController";

function remoteSnapshot(movementMode = MovementMode.Airborne): RemoteMoveSnapshot {
  return {
    cid: 42,
    serverTick: 7,
    position: new Vector3(1, 2, 3),
    velocity: new Vector3(0, 10, 0),
    acceleration: new Vector3(0, -9, 0),
    movementMode,
  };
}

describe("RemotePlayerController", () => {
  it("preserves synced movement mode when ingesting remote snapshots", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);
    const ingested: AppEvents["movement:remote-snapshot-ingested"][] = [];
    bus.on("movement:remote-snapshot-ingested", (event) => ingested.push(event));

    bus.emit("transport:snapshot-delivered", { snapshot: remoteSnapshot() });

    expect(controller.getCurrentMovementMode()).toBe(MovementMode.Airborne);
    expect(ingested[0]).toMatchObject({ movementMode: MovementMode.Airborne });
  });
});
