import { describe, expect, it, vi } from "vitest";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { InputController } from "./inputController";

type StoredListener = (event: Event) => void;

class FakeWindowTarget {
  private readonly listeners = new Map<string, StoredListener[]>();

  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    const fn = listener as StoredListener;
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(fn);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    const fn = listener as StoredListener;
    const listeners = this.listeners.get(type) ?? [];
    this.listeners.set(
      type,
      listeners.filter((candidate) => candidate !== fn),
    );
  }

  dispatch(type: string, event: Event): void {
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
  }
}

function pointerDown(button: number, shiftKey = false): Event {
  return {
    button,
    shiftKey,
    preventDefault: vi.fn(),
  } as unknown as Event;
}

function wheel(deltaY: number, ctrlKey = false): Event {
  return {
    deltaY,
    ctrlKey,
    preventDefault: vi.fn(),
  } as unknown as Event;
}

function keyboard(
  code: string,
  repeat = false,
  key = "",
  modifiers: Partial<KeyboardEvent> = {},
): Event {
  return {
    code,
    key,
    repeat,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    preventDefault: vi.fn(),
    ...modifiers,
  } as unknown as Event;
}

function editableKeyboard(code: string, tagName = "INPUT"): Event {
  return keyboard(code, false, "", {
    target: {
      tagName,
      isContentEditable: false,
    } as unknown as EventTarget,
  });
}

describe("InputController mouse editing", () => {
  it("emits break intent from left mouse and place intent from right mouse", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const breakEvents: AppEvents["input:break-block"][] = [];
    const placeEvents: AppEvents["input:place-block"][] = [];
    bus.on("input:break-block", (event) => breakEvents.push(event));
    bus.on("input:place-block", (event) => placeEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("pointerdown", pointerDown(0));
    target.dispatch("pointerdown", pointerDown(2));

    expect(breakEvents).toEqual([{ source: "mouse_left" }]);
    expect(placeEvents).toEqual([{ source: "mouse_right" }]);
  });

  it("keeps shift mouse actions on normal block editing instead of exposing micro edits", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const breakEvents: AppEvents["input:break-block"][] = [];
    const placeEvents: AppEvents["input:place-block"][] = [];
    bus.on("input:break-block", (event) => breakEvents.push(event));
    bus.on("input:place-block", (event) => placeEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("pointerdown", pointerDown(0, true));
    target.dispatch("pointerdown", pointerDown(2, true));

    expect(breakEvents).toEqual([{ source: "mouse_left" }]);
    expect(placeEvents).toEqual([{ source: "mouse_right" }]);
  });

  it("removes mouse listeners when detached", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const breakEvents: AppEvents["input:break-block"][] = [];
    bus.on("input:break-block", (event) => breakEvents.push(event));

    const detach = input.attach(target as unknown as Window);
    detach();
    target.dispatch("pointerdown", pointerDown(0));

    expect(breakEvents).toEqual([]);
  });

  it("cycles the hotbar from plain wheel while leaving ctrl-wheel for camera zoom", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const cycles: AppEvents["input:hotbar-cycle"][] = [];
    bus.on("input:hotbar-cycle", (event) => cycles.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("wheel", wheel(120));
    target.dispatch("wheel", wheel(-120));
    target.dispatch("wheel", wheel(120, true));

    expect(cycles).toEqual([
      { direction: 1, source: "wheel" },
      { direction: -1, source: "wheel" },
    ]);
  });

  it("emits numeric hotbar selections through the ninth slot", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const selections: AppEvents["input:hotbar-select"][] = [];
    bus.on("input:hotbar-select", (event) => selections.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("Digit6"));
    target.dispatch("keydown", keyboard("Digit9"));

    expect(selections).toEqual([
      { index: 5, source: "keyboard" },
      { index: 8, source: "keyboard" },
    ]);
  });

  it("ignores keyboard controls that originate from editable UI targets", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const selections: AppEvents["input:hotbar-select"][] = [];
    const jumps: AppEvents["input:jump"][] = [];
    const breakEvents: AppEvents["input:break-block"][] = [];
    bus.on("input:hotbar-select", (event) => selections.push(event));
    bus.on("input:jump", (event) => jumps.push(event));
    bus.on("input:break-block", (event) => breakEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", editableKeyboard("KeyW"));
    target.dispatch("keydown", editableKeyboard("Digit6"));
    target.dispatch("keydown", editableKeyboard("Space", "TEXTAREA"));
    target.dispatch("keydown", editableKeyboard("KeyG"));

    expect(input.getMovementKeys()).toEqual({
      forward: false,
      backward: false,
      left: false,
      right: false,
    });
    expect(input.consumeJumpPressed()).toBe(false);
    expect(selections).toEqual([]);
    expect(jumps).toEqual([]);
    expect(breakEvents).toEqual([]);
  });

  it("emits a set-temperature heat action from F instead of using F as a place shortcut", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const placeEvents: AppEvents["input:place-block"][] = [];
    const heatEvents: AppEvents["input:set-selected-voxel-temperature"][] = [];
    bus.on("input:place-block", (event) => placeEvents.push(event));
    bus.on("input:set-selected-voxel-temperature", (event) => heatEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("KeyF"));

    expect(placeEvents).toEqual([]);
    expect(heatEvents).toEqual([{ source: "keyboard", targetTemperatureCelsius: 800 }]);
  });

  it("emits a selected-voxel conduction action from E", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const conductionEvents: AppEvents["input:conduct-selected-voxel"][] = [];
    bus.on("input:conduct-selected-voxel", (event) => conductionEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("KeyE"));

    expect(conductionEvents).toEqual([{ source: "keyboard", sourcePotential: 120, maxTicks: 90 }]);
  });

  it("emits a short-lived lightning discharge action from L", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const lightningEvents: AppEvents["input:lightning-selected-entity"][] = [];
    bus.on("input:lightning-selected-entity", (event) => lightningEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("KeyL"));

    expect(lightningEvents).toEqual([
      {
        source: "keyboard",
        sourcePotential: 300,
        maxTicks: 5,
        verticalOffsetMacros: 4,
      },
    ]);
  });

  it("emits selected conduction endpoint capture actions from Z and X", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const endpointEvents: AppEvents["input:capture-conduction-endpoint"][] = [];
    bus.on("input:capture-conduction-endpoint", (event) => endpointEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("KeyZ"));
    target.dispatch("keydown", keyboard("KeyX"));

    expect(endpointEvents).toEqual([
      { role: "source", source: "keyboard" },
      { role: "target", source: "keyboard" },
    ]);
  });

  it("emits a panel conduction submit action from C", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const submitEvents: AppEvents["input:submit-conduction"][] = [];
    bus.on("input:submit-conduction", (event) => submitEvents.push(event));

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("KeyC"));

    expect(submitEvents).toEqual([{ source: "keyboard" }]);
  });

  it("treats voxel field shortcuts as plain one-shot key actions", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const heatEvents: AppEvents["input:set-selected-voxel-temperature"][] = [];
    const conductionEvents: AppEvents["input:conduct-selected-voxel"][] = [];
    const lightningEvents: AppEvents["input:lightning-selected-entity"][] = [];
    const endpointEvents: AppEvents["input:capture-conduction-endpoint"][] = [];
    const submitEvents: AppEvents["input:submit-conduction"][] = [];
    bus.on("input:set-selected-voxel-temperature", (event) => heatEvents.push(event));
    bus.on("input:conduct-selected-voxel", (event) => conductionEvents.push(event));
    bus.on("input:lightning-selected-entity", (event) => lightningEvents.push(event));
    bus.on("input:capture-conduction-endpoint", (event) => endpointEvents.push(event));
    bus.on("input:submit-conduction", (event) => submitEvents.push(event));

    input.attach(target as unknown as Window);
    for (const code of ["KeyF", "KeyE", "KeyL", "KeyZ", "KeyX", "KeyC"]) {
      target.dispatch("keydown", keyboard(code, true));
      target.dispatch("keydown", keyboard(code, false, "", { ctrlKey: true }));
      target.dispatch("keydown", keyboard(code, false, "", { metaKey: true }));
      target.dispatch("keydown", keyboard(code, false, "", { altKey: true }));
    }

    expect(heatEvents).toEqual([]);
    expect(conductionEvents).toEqual([]);
    expect(lightningEvents).toEqual([]);
    expect(endpointEvents).toEqual([]);
    expect(submitEvents).toEqual([]);
  });

  it("tracks Space as a one-shot jump request and consumes it exactly once", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();
    const jumps: AppEvents["input:jump"][] = [];
    bus.on("input:jump", (event) => jumps.push(event));

    input.attach(target as unknown as Window);
    const firstSpace = keyboard("Space");
    const repeatedSpace = keyboard("Space", true);
    target.dispatch("keydown", firstSpace);
    target.dispatch("keydown", repeatedSpace);

    expect(input.consumeJumpPressed()).toBe(true);
    expect(input.consumeJumpPressed()).toBe(false);
    expect(jumps).toEqual([{ source: "keyboard" }]);
    expect(firstSpace.preventDefault).toHaveBeenCalled();
    expect(repeatedSpace.preventDefault).toHaveBeenCalled();
  });

  it("treats Space key values as jump even when code is unavailable", () => {
    const bus = new EventBus<AppEvents>();
    const input = new InputController(bus);
    const target = new FakeWindowTarget();

    input.attach(target as unknown as Window);
    target.dispatch("keydown", keyboard("", false, " "));

    expect(input.consumeJumpPressed()).toBe(true);
  });
});

describe("InputController virtual movement and canvas disable flag", () => {
  it("getVirtualMovement returns zero by default", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new InputController(bus);
    expect(controller.getVirtualMovement()).toEqual({ x: 0, y: 0 });
  });

  it("setVirtualMovement updates state and clamps to unit length", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new InputController(bus);

    controller.setVirtualMovement({ x: 0.4, y: -0.2 });
    expect(controller.getVirtualMovement().x).toBeCloseTo(0.4);
    expect(controller.getVirtualMovement().y).toBeCloseTo(-0.2);

    controller.setVirtualMovement({ x: 3, y: 4 });
    const clamped = controller.getVirtualMovement();
    expect(Math.hypot(clamped.x, clamped.y)).toBeCloseTo(1);
  });

  it("setDisableCanvasActions short-circuits pointerdown break/place emit", () => {
    const bus = new EventBus<AppEvents>();
    const controller = new InputController(bus);
    const target = new FakeWindowTarget();
    let breakCount = 0;
    bus.on("input:break-block", () => {
      breakCount += 1;
    });

    controller.attach(target as unknown as Window);
    target.dispatch("pointerdown", pointerDown(0));
    expect(breakCount).toBe(1);

    controller.setDisableCanvasActions(true);
    target.dispatch("pointerdown", pointerDown(0));
    expect(breakCount).toBe(1);

    controller.setDisableCanvasActions(false);
    target.dispatch("pointerdown", pointerDown(0));
    expect(breakCount).toBe(2);
  });
});
