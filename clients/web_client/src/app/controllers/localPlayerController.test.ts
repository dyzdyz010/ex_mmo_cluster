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
    const spawn = new Vector3(0, 123, 0);
    const controller = new LocalPlayerController(bus, input, pump, spawn);

    expect(controller.getRenderedPosition()).toEqual(spawn);
    expect(controller.getAuthoritativePosition()).toEqual(spawn);
    expect(controller.getCurrentState()).toMatchObject({ groundY: 123 });
  });

  it("advances the rendered local position before the first 16 ms fixed step lands", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;

    const start = controller.getRenderedPosition().clone();

    controller.onFrame(8, 8);

    expect(controller.getRenderedPosition().x).toBeGreaterThan(start.x);
    expect(transport.sentInputs).toHaveLength(0);
  });

  it("catches up fixed inputs during a 33 ms browser frame instead of slowing movement", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;

    controller.onFrame(33, 33);

    expect(transport.sentInputs.map((frame) => frame.clientTick)).toEqual([1, 2]);
  });

  it("keeps hitch overflow in the fixed accumulator instead of dropping movement time", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;

    controller.onFrame(100, 100);
    expect(transport.sentInputs.map((frame) => frame.clientTick)).toEqual([1, 2, 3, 4]);

    controller.onFrame(116, 16);
    expect(transport.sentInputs.map((frame) => frame.clientTick)).toEqual([
      1, 2, 3, 4, 5, 6, 7,
    ]);
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

    const finalSample = samples[samples.length - 1];
    expect(finalSample?.localX).toBeCloseTo(finalSample?.renderedX ?? 0, 5);
    expect(finalSample?.authorityX).toBeCloseTo(controller.getAuthoritativePosition().x, 5);
    expect(samples.some((sample) => sample.authorityRenderDeltaDistance > 0)).toBe(true);
    expect(Math.max(...samples.map((sample) => sample.localAuthorityDistance))).toBeGreaterThan(0);
    expect(Math.max(...samples.map((sample) => sample.localAuthorityRenderDistance))).toBeLessThan(
      0.001,
    );
    expect(samples.every((sample) => Number.isFinite(sample.localAuthorityProjectedDistance))).toBe(
      true,
    );
    expect(
      Math.max(...samples.map((sample) => sample.localAuthorityProjectedDistance)),
    ).toBeLessThan(0.001);
    expect(samples.every((sample) => Number.isFinite(sample.localAuthorityDisplayDistance))).toBe(
      true,
    );
    expect(Math.max(...samples.map((sample) => sample.localAuthorityDisplayDistance))).toBeLessThan(
      0.001,
    );
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
        serverStateMs: 0,
        serverSendMs: 0,
        position: acceptedState!.position.clone(),
        velocity: acceptedState!.velocity.clone(),
        acceleration: acceptedState!.acceleration.clone(),
        movementMode: MovementMode.Grounded,
        correctionFlags: CorrectionFlag.None,
        serverFixedDtMs: 16,
        groundY: acceptedState!.groundY,
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
        serverStateMs: 0,
        serverSendMs: 0,
        position: firstAuthoritative.position.clone(),
        velocity: firstAuthoritative.velocity.clone(),
        acceleration: firstAuthoritative.acceleration.clone(),
        movementMode: firstAuthoritative.movementMode,
        correctionFlags: CorrectionFlag.None,
        serverFixedDtMs: 16,
        groundY: firstAuthoritative.groundY,
      },
      sentAtMs: performance.now(),
    });

    controller.onFrame(370, 10);

    expect(controller.getRenderedPosition().x).toBeGreaterThanOrEqual(beforeAckFrame.x);
    expect(controller.getPendingCorrection().length()).toBe(0);
  });

  it("uses a 2-tick latest-ack projection fallback before TimeSync is available", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump, new Vector3(0, 0, 0));

    bus.emit("transport:ack-delivered", {
      ack: {
        ackSeq: 0,
        authTick: 0,
        serverStateMs: 0,
        serverSendMs: 0,
        position: new Vector3(0, 0, 0),
        velocity: new Vector3(100, 0, 0),
        acceleration: new Vector3(0, 0, 0),
        movementMode: MovementMode.Grounded,
        correctionFlags: CorrectionFlag.None,
        serverFixedDtMs: 16,
        groundY: 0,
      },
      sentAtMs: performance.now(),
    });

    const estimated = controller.getAuthoritativeProjectedPosition(performance.now() + 250);

    expect(controller.getAuthoritativePosition().x).toBe(0);
    expect(estimated.x).toBeCloseTo(3.2, 4);
  });

  it("falls back to the rendered local position before the first ack arrives", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump, new Vector3(0, 0, 0));

    const keys = input.getMovementKeys() as MovementKeys;
    keys.right = true;
    for (let frame = 0; frame < 4; frame += 1) {
      controller.onFrame((frame + 1) * 16, 16);
    }

    const rendered = controller.getRenderedPosition().clone();
    const estimated = controller.getAuthoritativeProjectedPosition(performance.now() + 64);

    expect(rendered.x).toBeGreaterThan(0);
    expect(estimated.x).toBeCloseTo(rendered.x, 5);
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

    expect(transport.sentInputs).toHaveLength(8);
    expect(transport.sentInputs[0]?.movementFlags).toBe(MovementFlag.Jump | MovementFlag.Brake);
    expect(transport.sentInputs.slice(1).every((frame) => frame.movementFlags === MovementFlag.Brake)).toBe(
      true,
    );
  });

  it("coalesces repeated idle movement frames between keepalives", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    for (let frame = 0; frame < 10; frame += 1) {
      controller.onFrame((frame + 1) * 100, 100);
    }

    expect(transport.sentInputs).toHaveLength(1);
    expect(transport.sentInputs[0]?.movementFlags).toBe(MovementFlag.Brake);

    controller.onFrame(5_100, 100);

    expect(transport.sentInputs).toHaveLength(2);
    expect(transport.sentInputs[1]?.movementFlags).toBe(MovementFlag.Brake);
  });

  it("does not replay a whole jump arc in one frame after a long tab pause", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    input.requestJump("test");

    controller.onFrame(2_000, 2_000);
    controller.onFrame(2_100, 100);

    expect(transport.sentInputs).toHaveLength(8);
    expect(transport.sentInputs[0]?.movementFlags).toBe(MovementFlag.Jump | MovementFlag.Brake);
    expect(transport.sentInputs.slice(1).every((frame) => frame.movementFlags === MovementFlag.Brake)).toBe(
      true,
    );
    expect(transport.sentInputs[0]?.clientTick).toBe(1);
    expect(transport.sentInputs.at(-1)?.clientTick).toBe(8);
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
    expect(samples.some((sample) => Math.abs(sample.authorityRenderDeltaY) > 0)).toBe(true);
    expect(samples.every((sample) => Number.isFinite(sample.localAuthorityRenderDistance))).toBe(
      true,
    );
  });

  it("merges keyboard and virtual stick axes, clamping to unit length", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.forward = true;
    input.setVirtualMovement({ x: 0.8, y: 0 });

    const axes = controller.getCombinedMovementAxesForTest();
    // keyboard forward = 1, stick x = 0.8, stick y = 0 → raw length ≈ 1.28 → clampUnitVec → length 1
    expect(Math.hypot(axes.strafe, axes.forward)).toBeCloseTo(1);
    expect(axes.strafe).toBeGreaterThan(0);
    expect(axes.forward).toBeGreaterThan(0);
  });

  it("clamps keyboard-only diagonal input to unit length (no diagonal speed boost)", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const transport = new FakeMovementTransport();
    const pump = new TransportPump(transport, bus);
    const controller = new LocalPlayerController(bus, input, pump);

    const keys = input.getMovementKeys() as MovementKeys;
    keys.forward = true;
    keys.right = true;
    // No virtual stick input.

    const axes = controller.getCombinedMovementAxesForTest();
    expect(Math.hypot(axes.strafe, axes.forward)).toBeCloseTo(1);
    expect(axes.strafe).toBeCloseTo(Math.SQRT1_2, 4); // 1/√2
    expect(axes.forward).toBeCloseTo(Math.SQRT1_2, 4);
  });
});
