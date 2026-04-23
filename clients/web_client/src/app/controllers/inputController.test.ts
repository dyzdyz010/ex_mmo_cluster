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

function pointerDown(button: number): Event {
  return {
    button,
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
});
