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

function keyboard(code: string, repeat = false, key = ""): Event {
  return {
    code,
    key,
    repeat,
    preventDefault: vi.fn(),
  } as unknown as Event;
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
