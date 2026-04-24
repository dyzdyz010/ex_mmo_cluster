export interface FrameSubscriber {
  onFrame(nowMs: number, dtMs: number): void;
}

/**
 * Drives the browser's `requestAnimationFrame` and fans each tick out to
 * subscribers in deterministic registration order.
 *
 * Ordered, synchronous invocation is intentional: game simulation depends on
 * producer/consumer order (transport pump → player controllers → render).
 * The shared event bus carries _discrete_ events; per-frame pipeline stays
 * imperative to keep the ordering explicit and debuggable.
 *
 * One misbehaving subscriber must not kill the whole pipeline, so each call
 * is wrapped in a try/catch that logs once and keeps draining the queue.
 */
export class GameLoop {
  private readonly subscribers: FrameSubscriber[] = [];
  private readonly raf: (cb: FrameRequestCallback) => number;
  private readonly cancelRaf: (handle: number) => void;
  private readonly reportError: (err: unknown, subscriber: FrameSubscriber) => void;
  private handle: number | null = null;
  private lastMs = 0;

  constructor(
    options: {
      raf?: (cb: FrameRequestCallback) => number;
      cancelRaf?: (handle: number) => void;
      reportError?: (err: unknown, subscriber: FrameSubscriber) => void;
    } = {},
  ) {
    this.raf = options.raf ?? requestAnimationFrame.bind(globalThis);
    this.cancelRaf = options.cancelRaf ?? cancelAnimationFrame.bind(globalThis);
    this.reportError = options.reportError ?? defaultReportError;
  }

  subscribe(subscriber: FrameSubscriber): void {
    this.subscribers.push(subscriber);
  }

  start(): void {
    if (this.handle !== null) return;
    this.lastMs = performance.now();
    const tick = (nowMs: number): void => {
      const dtMs = Math.max(0, nowMs - this.lastMs);
      this.lastMs = nowMs;
      for (const subscriber of this.subscribers) {
        try {
          subscriber.onFrame(nowMs, dtMs);
        } catch (err) {
          this.reportError(err, subscriber);
        }
      }
      this.handle = this.raf(tick);
    };
    this.handle = this.raf(tick);
  }

  stop(): void {
    if (this.handle !== null) {
      this.cancelRaf(this.handle);
      this.handle = null;
    }
  }
}

const loggedOnce = new WeakSet<FrameSubscriber>();

function defaultReportError(err: unknown, subscriber: FrameSubscriber): void {
  if (loggedOnce.has(subscriber)) return;
  loggedOnce.add(subscriber);
  const name = subscriber.constructor?.name ?? "FrameSubscriber";
  console.error(`[GameLoop] subscriber "${name}" threw; continuing tick chain`, err);
}
