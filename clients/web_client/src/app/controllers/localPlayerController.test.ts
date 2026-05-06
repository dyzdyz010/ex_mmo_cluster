import { LocalPlayerController } from "./localPlayerController";
import { InputController } from "./inputController";
import { TransportPump } from "./transportPump";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { MovementTransport, MovementTransportTickResult } from "@domain/movement/transport";
import { CorrectionFlag, MovementFlag, MovementMode } from "@domain/movement/types";
import { makeIdleState } from "@domain/movement/types";
import type { MoveInputFrame } from "@domain/movement/types";
import { Vector3 } from "three";
import type { MovementKeys } from "./inputController";
import { step } from "@domain/movement/predictor";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";

class FakeMovementTransport implements MovementTransport {
  readonly mode = "test";
  readonly sentInputs: MoveInputFrame[] = [];
  ready = true;

  isReady(): boolean {
    return this.ready;
  }

  debugSnapshot(): Record<string, unknown> {
    return {};
  }

  reset(_position: Vector3): void {}

  sendInput(frame: MoveInputFrame, _nowMs: number): void {
    this.sentInputs.push(frame);
  }

  tick(_nowMs: number, _dtMs: number): MovementTransportTickResult {
    return {
      acknowledgements: [],
      remoteSnapshots: [],
      spawn: null,
    };
  }
}

describe("LocalPlayerController", () => {
  it("initializes prediction, rendered position, and ground from the provided spawn", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const spawn = new Vector3(-350, 260, -280);
    const controller = new LocalPlayerController(bus, input, pump, spawn);

    expect(controller.getRenderedPosition()).toEqual(spawn);
    expect(controller.getAuthoritativePosition()).toEqual(spawn);
    expect(controller.getCurrentState()).toMatchObject({ groundY: 260 });
  });

  it("advances the rendered local position before the first 100 ms fixed step lands", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;

    const start = controller.getRenderedPosition().clone();

    controller.onFrame(16, 16);

    expect(controller.getRenderedPosition().x).toBeGreaterThan(start.x);
    expect(transport.sentInputs).toHaveLength(0);
  });

  it("treats camera forward as movement forward", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const cameraAwareController = controller as LocalPlayerController & {
      setCameraYawResolver?: (resolver: () => number) => void;
    };
    cameraAwareController.setCameraYawResolver?.(() => -Math.PI / 2);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.forward = true;

    const start = controller.getRenderedPosition().clone();

    controller.onFrame(16, 16);

    expect(controller.getRenderedPosition().x).toBeGreaterThan(start.x);
    expect(controller.getRenderedPosition().z).toBeCloseTo(start.z, 4);
  });

  it("keeps per-frame displacement continuous across fixed-tick boundaries", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.forward = true;

    controller.startFrameTrace(40);
    for (let frame = 0; frame < 40; frame += 1) {
      controller.onFrame((frame + 1) * 10, 10);
    }

    const samples = controller.getFrameTrace().samples;
    let maxAdjacentDrop = 0;
    for (let i = 1; i < samples.length; i += 1) {
      const previous = samples[i - 1];
      const current = samples[i];
      if (!previous || !current) {
        continue;
      }
      const drop = previous.deltaDistance - current.deltaDistance;
      if (drop > maxAdjacentDrop) {
        maxAdjacentDrop = drop;
      }
    }

    expect(maxAdjacentDrop).toBeLessThan(0.35);
  });

  it("does not rewind the render phase when an accepted ack has no correction", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;

    for (let frame = 0; frame < 16; frame += 1) {
      controller.onFrame((frame + 1) * 10, 10);
    }
    const acceptedState = controller.getCurrentState();
    expect(acceptedState).not.toBeNull();

    const beforeAckFrame = controller.getRenderedPosition().clone();
    bus.emit("transport:ack-delivered", {
      ack: {
        ackSeq: acceptedState!.seq,
        authTick: acceptedState!.tick,
        position: acceptedState!.position.clone(),
        velocity: acceptedState!.velocity.clone(),
        acceleration: acceptedState!.acceleration.clone(),
        movementMode: MovementMode.Grounded,
        correctionFlags: CorrectionFlag.None,
        serverFixedDtMs: 100,
      },
      sentAtMs: performance.now(),
    });

    controller.onFrame(170, 10);

    expect(controller.getRenderedPosition().x).toBeGreaterThanOrEqual(beforeAckFrame.x);
    expect(controller.getPendingCorrection().length()).toBe(0);
  });

  it("keeps moving forward when a delayed accepted ack matches an older predicted tick", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;
    const start = controller.getRenderedPosition().clone();

    for (let frame = 0; frame < 36; frame += 1) {
      controller.onFrame((frame + 1) * 10, 10);
    }

    const firstInput = transport.sentInputs[0];
    expect(firstInput).toBeDefined();
    const firstAuthoritative = step(makeIdleState(start), firstInput!, DEFAULT_MOVEMENT_PROFILE);
    const beforeAckFrame = controller.getRenderedPosition().clone();

    bus.emit("transport:ack-delivered", {
      ack: {
        ackSeq: firstInput!.seq,
        authTick: firstInput!.clientTick,
        position: firstAuthoritative.position.clone(),
        velocity: firstAuthoritative.velocity.clone(),
        acceleration: firstAuthoritative.acceleration.clone(),
        movementMode: firstAuthoritative.movementMode,
        correctionFlags: CorrectionFlag.None,
        serverFixedDtMs: 100,
      },
      sentAtMs: performance.now(),
    });

    controller.onFrame(370, 10);

    expect(controller.getRenderedPosition().x).toBeGreaterThanOrEqual(beforeAckFrame.x);
    expect(controller.getPendingCorrection().length()).toBe(0);
  });

  it("sends one jump flag on the next fixed movement frame", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    input.requestJump("test");

    controller.onFrame(100, 100);
    controller.onFrame(200, 100);

    expect(transport.sentInputs).toHaveLength(2);
    expect(transport.sentInputs[0]?.movementFlags).toBe(MovementFlag.Jump | MovementFlag.Brake);
    expect(transport.sentInputs[1]?.movementFlags).toBe(MovementFlag.Brake);
  });

  it("emits an observable blocked-input event when controls are used before transport is ready", () => {
    const bus = new EventBus<AppEvents>();
    const blocked: AppEvents["movement:input-blocked"][] = [];
    bus.on("movement:input-blocked", (event) => blocked.push(event));
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    transport.ready = false;
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.forward = true;
    input.requestJump("test");

    controller.onFrame(100, 100);
    controller.onFrame(200, 100);

    expect(transport.sentInputs).toHaveLength(0);
    expect(blocked).toEqual([
      {
        reason: "transport_not_ready",
        keys: { forward: true, backward: false, left: false, right: false },
        jump: true,
      },
    ]);
  });

  it("records vertical displacement and movement mode in frame traces", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);
    const startY = controller.getRenderedPosition().y;

    input.requestJump("test");
    controller.startFrameTrace(8);
    for (let frame = 0; frame < 8; frame += 1) {
      controller.onFrame((frame + 1) * 25, 25);
    }

    const samples = controller.getFrameTrace().samples;
    expect(samples.some((sample) => sample.renderedY !== startY)).toBe(true);
    expect(samples.some((sample) => sample.movementMode === "airborne")).toBe(true);
    expect(samples.some((sample) => Math.abs(sample.deltaY) > 0)).toBe(true);
  });
});
