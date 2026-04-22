import { LocalPlayerController } from "./localPlayerController";
import { InputController } from "./inputController";
import { TransportPump } from "./transportPump";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type {
  MovementTransport,
  MovementTransportTickResult,
} from "@domain/movement/transport";
import type { MoveInputFrame } from "@domain/movement/types";
import type { Vector3 } from "three";
import type { MovementKeys } from "./inputController";

class FakeMovementTransport implements MovementTransport {
  readonly mode = "test";
  readonly sentInputs: MoveInputFrame[] = [];

  isReady(): boolean {
    return true;
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
      spawnPosition: null,
    };
  }
}

describe("LocalPlayerController", () => {
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
});
