import { describe, expect, it, vi } from "vitest";
import { GameLoop, type FrameSubscriber } from "./gameLoop";

function makeManualRaf() {
  const queue: FrameRequestCallback[] = [];
  const cancelled = new Set<number>();
  let next = 1;
  const raf = (cb: FrameRequestCallback): number => {
    const handle = next;
    next += 1;
    queue.push(cb);
    return handle;
  };
  const cancelRaf = (handle: number): void => {
    cancelled.add(handle);
  };
  const fire = (nowMs: number): void => {
    const pending = queue.splice(0, queue.length);
    for (const cb of pending) {
      cb(nowMs);
    }
  };
  return { raf, cancelRaf, fire, cancelled };
}

describe("GameLoop", () => {
  it("fans each tick out to subscribers in registration order", () => {
    const { raf, cancelRaf, fire } = makeManualRaf();
    const loop = new GameLoop({ raf, cancelRaf });
    const order: string[] = [];
    const s = (name: string): FrameSubscriber => ({
      onFrame: () => {
        order.push(name);
      },
    });
    loop.subscribe(s("a"));
    loop.subscribe(s("b"));
    loop.subscribe(s("c"));

    loop.start();
    fire(16);
    fire(32);

    expect(order).toEqual(["a", "b", "c", "a", "b", "c"]);
  });

  it("keeps draining subscribers when one throws and keeps rAF alive", () => {
    const { raf, cancelRaf, fire } = makeManualRaf();
    const reportError = vi.fn();
    const loop = new GameLoop({ raf, cancelRaf, reportError });

    const rangToCompletion: string[] = [];
    const boom: FrameSubscriber = {
      onFrame: () => {
        throw new Error("boom");
      },
    };
    const tail: FrameSubscriber = {
      onFrame: () => {
        rangToCompletion.push("tail");
      },
    };

    loop.subscribe(boom);
    loop.subscribe(tail);

    loop.start();
    fire(16);
    fire(32);

    expect(rangToCompletion).toEqual(["tail", "tail"]);
    expect(reportError).toHaveBeenCalledTimes(2);
  });

  it("stop cancels the pending rAF handle", () => {
    const { raf, cancelRaf, cancelled } = makeManualRaf();
    const loop = new GameLoop({ raf, cancelRaf });
    loop.subscribe({ onFrame: () => {} });

    loop.start();
    loop.stop();

    expect(cancelled.size).toBe(1);
  });
});
