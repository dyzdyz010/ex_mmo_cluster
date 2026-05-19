import { describe, expect, it, vi } from "vitest";
import { TouchControlsView, type TouchControlsPorts } from "./TouchControlsView";

type ConstructorElements = ConstructorParameters<typeof TouchControlsView>[0];

class FakeElement {
  classList = (() => {
    const set = new Set<string>();
    return {
      add: (cls: string) => set.add(cls),
      remove: (cls: string) => set.delete(cls),
      contains: (cls: string) => set.has(cls),
      has: (cls: string) => set.has(cls),
    };
  })();
  style: Record<string, string> = {};
  private listeners = new Map<string, EventListener[]>();
  setPointerCapture = vi.fn();
  releasePointerCapture = vi.fn();
  addEventListener(type: string, fn: EventListener): void {
    const arr = this.listeners.get(type) ?? [];
    arr.push(fn);
    this.listeners.set(type, arr);
  }
  removeEventListener(type: string, fn: EventListener): void {
    const arr = this.listeners.get(type) ?? [];
    this.listeners.set(
      type,
      arr.filter((f) => f !== fn),
    );
  }
  fire(type: string, evt: Partial<PointerEvent>): void {
    for (const fn of this.listeners.get(type) ?? []) fn(evt as PointerEvent);
  }
}

function makePorts(): TouchControlsPorts {
  return {
    setMovement: vi.fn(),
    requestJump: vi.fn(),
    emitBreak: vi.fn(),
    emitPlace: vi.fn(),
    toggleField: vi.fn(),
    emitHeat: vi.fn(),
    emitConduct: vi.fn(),
    subscribeAim: vi.fn(),
    applyCameraYawPitchDelta: vi.fn(),
  };
}

function makeFakeDom() {
  return {
    zoneLeft: new FakeElement(),
    zoneRight: new FakeElement(),
    stickLeft: new FakeElement(),
    stickRight: new FakeElement(),
    btnJump: new FakeElement(),
    btnBreak: new FakeElement(),
    btnPlace: new FakeElement(),
    btnField: new FakeElement(),
    btnHeat: new FakeElement(),
    btnConduct: new FakeElement(),
    btnSubscribe: new FakeElement(),
  };
}

describe("TouchControlsView", () => {
  it("left stick pointerdown captures pointer and updates movement", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    const view = new TouchControlsView(dom as unknown as ConstructorElements, ports);

    dom.zoneLeft.fire("pointerdown", {
      pointerId: 1,
      clientX: 60,
      clientY: 300,
      preventDefault: () => undefined,
    });
    expect(dom.zoneLeft.setPointerCapture).toHaveBeenCalledWith(1);

    dom.zoneLeft.fire("pointermove", {
      pointerId: 1,
      clientX: 140,
      clientY: 300,
      preventDefault: () => undefined,
    });
    const lastCall = (ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.at(-1)?.[0];
    expect(lastCall.x).toBeCloseTo(1);
    expect(lastCall.y).toBeCloseTo(0);

    dom.zoneLeft.fire("pointerup", { pointerId: 1 });
    const finalCall = (ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.at(-1)?.[0];
    expect(finalCall).toEqual({ x: 0, y: 0 });

    view.dispose();
  });

  it("second pointer in same zone does not steal the active stick", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as ConstructorElements, ports);

    dom.zoneLeft.fire("pointerdown", {
      pointerId: 1,
      clientX: 60,
      clientY: 300,
      preventDefault: () => undefined,
    });
    const before = (ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.length;

    dom.zoneLeft.fire("pointerdown", {
      pointerId: 2,
      clientX: 10,
      clientY: 10,
      preventDefault: () => undefined,
    });
    expect((ports.setMovement as ReturnType<typeof vi.fn>).mock.calls.length).toBe(before);
  });

  it("right stick drives applyCameraYawPitchDelta on frame", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    const view = new TouchControlsView(dom as unknown as ConstructorElements, ports);

    dom.zoneRight.fire("pointerdown", {
      pointerId: 5,
      clientX: 100,
      clientY: 300,
      preventDefault: () => undefined,
    });
    dom.zoneRight.fire("pointermove", {
      pointerId: 5,
      clientX: 180,
      clientY: 300,
      preventDefault: () => undefined,
    });

    view.onFrame(0, 100);
    const [yaw, pitch] = (ports.applyCameraYawPitchDelta as ReturnType<typeof vi.fn>).mock.calls.at(
      -1,
    ) ?? [0, 0];
    expect(yaw).toBeGreaterThan(0);
    expect(pitch).toBeCloseTo(0);
  });

  it("jump button pointerdown calls requestJump immediately", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as ConstructorElements, ports);
    dom.btnJump.fire("pointerdown", {
      pointerId: 9,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.requestJump).toHaveBeenCalledOnce();
  });

  it("break/place buttons emit through ports", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as ConstructorElements, ports);

    dom.btnBreak.fire("pointerdown", {
      pointerId: 10,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.emitBreak).toHaveBeenCalledOnce();

    dom.btnPlace.fire("pointerdown", {
      pointerId: 11,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.emitPlace).toHaveBeenCalledOnce();
  });

  it("mobile operation buttons emit field, heat, conduct, and aim subscribe intents", () => {
    const dom = makeFakeDom();
    const ports = makePorts();
    new TouchControlsView(dom as unknown as ConstructorElements, ports);

    dom.btnField.fire("pointerdown", {
      pointerId: 12,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.toggleField).toHaveBeenCalledOnce();

    dom.btnHeat.fire("pointerdown", {
      pointerId: 13,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.emitHeat).toHaveBeenCalledOnce();

    dom.btnConduct.fire("pointerdown", {
      pointerId: 14,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.emitConduct).toHaveBeenCalledOnce();

    dom.btnSubscribe.fire("pointerdown", {
      pointerId: 15,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    });
    expect(ports.subscribeAim).toHaveBeenCalledOnce();
  });
});
