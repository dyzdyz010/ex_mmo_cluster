import { describe, expect, it, vi } from "vitest";
import { EventBus } from "./eventBus";

type TestEvents = {
  tick: { dt: number };
  message: string;
  empty: void;
};

describe("EventBus", () => {
  it("delivers payloads to registered listeners", () => {
    const bus = new EventBus<TestEvents>();
    const spy = vi.fn();
    bus.on("tick", spy);
    bus.emit("tick", { dt: 16 });
    expect(spy).toHaveBeenCalledWith({ dt: 16 });
  });

  it("on() returns an unsubscribe that prevents future delivery", () => {
    const bus = new EventBus<TestEvents>();
    const spy = vi.fn();
    const off = bus.on("message", spy);
    bus.emit("message", "first");
    off();
    bus.emit("message", "second");
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith("first");
  });

  it("once() fires exactly once then auto-unsubscribes", () => {
    const bus = new EventBus<TestEvents>();
    const spy = vi.fn();
    bus.once("message", spy);
    bus.emit("message", "hello");
    bus.emit("message", "again");
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("isolates listener errors so surviving listeners still run", () => {
    const bus = new EventBus<TestEvents>();
    const healthy = vi.fn();
    const broken = vi.fn(() => {
      throw new Error("boom");
    });
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    bus.on("message", broken);
    bus.on("message", healthy);
    bus.emit("message", "ping");
    expect(broken).toHaveBeenCalled();
    expect(healthy).toHaveBeenCalled();
    consoleError.mockRestore();
  });

  it("is safe against unsubscribes issued mid-dispatch", () => {
    const bus = new EventBus<TestEvents>();
    const first = vi.fn(() => {
      bus.off("message", second);
    });
    const second = vi.fn();
    bus.on("message", first);
    bus.on("message", second);
    bus.emit("message", "x");
    expect(first).toHaveBeenCalledTimes(1);
    expect(second).toHaveBeenCalledTimes(1);
  });

  it("listenerCount and clear behave as expected", () => {
    const bus = new EventBus<TestEvents>();
    bus.on("message", () => {});
    bus.on("message", () => {});
    bus.on("tick", () => {});
    expect(bus.listenerCount("message")).toBe(2);
    expect(bus.listenerCount("tick")).toBe(1);
    bus.clear();
    expect(bus.listenerCount("message")).toBe(0);
    expect(bus.listenerCount("tick")).toBe(0);
  });
});
