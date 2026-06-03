import { Vector3 } from "three";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AoiPriorityBand, MovementMode, type RemoteMoveSnapshot } from "@domain/movement/types";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { RemotePlayerController } from "./remotePlayerController";

function remoteSnapshot(
  movementMode: MovementMode = MovementMode.Airborne,
  overrides: Partial<RemoteMoveSnapshot> = {},
): RemoteMoveSnapshot {
  return {
    cid: 42,
    serverTick: 7,
    serverStateMs: 0,
    serverSendMs: 0,
    position: new Vector3(1, 2, 3),
    velocity: new Vector3(0, 10, 0),
    acceleration: new Vector3(0, -9, 0),
    movementMode,
    ...overrides,
  };
}

describe("RemotePlayerController", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("preserves synced movement mode when ingesting remote snapshots", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);
    const ingested: AppEvents["movement:remote-snapshot-ingested"][] = [];
    bus.on("movement:remote-snapshot-ingested", (event) => ingested.push(event));

    bus.emit("transport:snapshot-delivered", { snapshot: remoteSnapshot() });

    expect(controller.getCurrentMovementMode()).toBe(MovementMode.Airborne);
    expect(ingested[0]).toMatchObject({ movementMode: MovementMode.Airborne });
  });

  it("omits absent AOI priority fields from ingested events", () => {
    const bus = new EventBus<AppEvents>();
    new RemotePlayerController(bus);
    const ingested: AppEvents["movement:remote-snapshot-ingested"][] = [];
    bus.on("movement:remote-snapshot-ingested", (event) => ingested.push(event));

    bus.emit("transport:snapshot-delivered", { snapshot: remoteSnapshot() });

    expect(ingested[0]).not.toHaveProperty("priorityBand");
    expect(ingested[0]).not.toHaveProperty("priorityScore");
    expect(ingested[0]).not.toHaveProperty("observerDistance");
    expect(ingested[0]).not.toHaveProperty("deliveryInterval");
  });

  it("keeps independent interpolators for each remote cid", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:snapshot-delivered", {
      snapshot: { ...remoteSnapshot(), cid: 42, position: new Vector3(10, 0, 0) },
    });
    bus.emit("transport:snapshot-delivered", {
      snapshot: { ...remoteSnapshot(), cid: 77, position: new Vector3(100, 0, 0) },
    });
    controller.onFrame(1_000, 16);

    expect(controller.getVisibleEntityIds().sort()).toEqual([42, 77]);
    expect(controller.getRenderedPositionFor(42).x).toBeCloseTo(10, 4);
    expect(controller.getRenderedPositionFor(77).x).toBeCloseTo(100, 4);
  });

  it("does not snap the rendered position to every delivered snapshot", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Grounded, {
        serverTick: 1,
        position: new Vector3(10, 100, 10),
        velocity: new Vector3(0, 0, 0),
        acceleration: new Vector3(0, 0, 0),
      }),
    });
    controller.onFrame(1_000, 16);

    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Grounded, {
        serverTick: 2,
        position: new Vector3(110, 100, 10),
        velocity: new Vector3(0, 0, 0),
        acceleration: new Vector3(0, 0, 0),
      }),
    });

    expect(controller.getRenderedPositionFor(42).x).toBeCloseTo(10, 4);
  });

  it("uses synced server state wall-clock time for remote interpolation", () => {
    vi.spyOn(Date, "now").mockReturnValue(1_999_700);
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:time-sync", {
      requestId: 1,
      clientSendTs: 1_999_600,
      serverRecvTs: 2_000_100,
      serverSendTs: 2_000_200,
    });
    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Grounded, {
        serverTick: 1_000,
        serverStateMs: 2_000_000,
        serverSendMs: 2_000_020,
        position: new Vector3(0, 0, 0),
        velocity: new Vector3(1_000, 0, 0),
        acceleration: new Vector3(),
      }),
    });
    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Grounded, {
        serverTick: 1_006,
        serverStateMs: 2_000_100,
        serverSendMs: 2_000_120,
        position: new Vector3(100, 0, 0),
        velocity: new Vector3(1_000, 0, 0),
        acceleration: new Vector3(),
      }),
    });

    controller.onFrame(0, 16);

    expect(controller.getRenderedPositionFor(42).x).toBeCloseTo(50, 4);
    expect(controller.getDebugSnapshot()[0]).toMatchObject({
      interpolationTimeAxis: "server_state_ms",
      playbackServerTimeMs: 2_000_050,
      serverClockOffsetMs: 500,
    });
  });

  it("smooths time-sync offset samples and exposes jitter diagnostics", () => {
    vi.spyOn(Date, "now").mockReturnValueOnce(1_000).mockReturnValueOnce(2_000);
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:time-sync", {
      requestId: 1,
      clientSendTs: 1_000,
      serverRecvTs: 1_500,
      serverSendTs: 1_500,
    });
    bus.emit("transport:time-sync", {
      requestId: 2,
      clientSendTs: 2_000,
      serverRecvTs: 2_900,
      serverSendTs: 2_900,
    });

    expect(controller.getClockDebugSnapshot()).toMatchObject({
      serverClockOffsetMs: 580,
      rawServerClockOffsetMs: 900,
      timeSyncSampleCount: 2,
      timeSyncOffsetJitterMs: 80,
      timeSyncOffsetJumpCount: 1,
    });
  });

  it("keeps a grounded baseline for remote airborne display", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Grounded, {
        serverTick: 1,
        position: new Vector3(10, 100, 10),
      }),
    });
    controller.onFrame(1_000, 16);
    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Airborne, {
        serverTick: 2,
        position: new Vector3(10, 145, 10),
      }),
    });

    expect(controller.getRenderedEntities()[0]).toMatchObject({
      movementMode: MovementMode.Airborne,
      movementGroundY: 100,
    });
  });

  it("clamps stale airborne extrapolation to the known ground", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    vi.spyOn(performance, "now").mockReturnValueOnce(0).mockReturnValueOnce(100);
    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Grounded, {
        serverTick: 1,
        position: new Vector3(10, 185, 10),
        velocity: new Vector3(0, 0, 0),
        acceleration: new Vector3(0, 0, 0),
      }),
    });
    bus.emit("transport:snapshot-delivered", {
      snapshot: remoteSnapshot(MovementMode.Airborne, {
        serverTick: 2,
        position: new Vector3(10, 215, 10),
        velocity: new Vector3(0, -1_000, 0),
        acceleration: new Vector3(0, -980, 0),
      }),
    });

    controller.onFrame(10_000, 16);

    expect(controller.getRenderedPositionFor(42).y).toBe(185);
    expect(controller.getRenderedEntities()[0]).toMatchObject({
      movementMode: MovementMode.Grounded,
      movementGroundY: 185,
    });
  });

  it("removes remote entities when AOI leave arrives", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:snapshot-delivered", { snapshot: remoteSnapshot() });
    expect(controller.getVisibleEntityIds()).toContain(42);

    bus.emit("transport:entity-left", { cid: 42 });

    expect(controller.getVisibleEntityIds()).not.toContain(42);
  });

  it("keeps AOI enter positions until the first movement snapshot arrives", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:entity-entered", { cid: 99, position: new Vector3(25, 5, 75) });
    controller.onFrame(1_000, 16);

    expect(controller.getRenderedPositionFor(99)).toEqual(new Vector3(25, 5, 75));
  });

  it("exposes per-cid AOI priority and interpolation diagnostics", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new RemotePlayerController(bus);

    bus.emit("transport:snapshot-delivered", {
      snapshot: {
        ...remoteSnapshot(),
        priorityBand: AoiPriorityBand.High,
        priorityScore: 0.9,
        observerDistance: 50,
        deliveryInterval: 1,
      },
    });
    controller.onFrame(1_000, 16);

    expect(controller.getDebugSnapshot()).toMatchObject([
      {
        cid: 42,
        bufferedSnapshots: 1,
        latestServerTick: 7,
        priorityBand: AoiPriorityBand.High,
        priorityScore: 0.9,
        observerDistance: 50,
        deliveryInterval: 1,
      },
    ]);
  });
});
