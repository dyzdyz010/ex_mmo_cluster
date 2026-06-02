import { describe, expect, it } from "vitest";
import { LocalPredictionRuntime } from "./localPlayer";

describe("LocalPredictionRuntime jitter estimator", () => {
  it("keeps jitter near zero when RTT is stable", () => {
    const runtime = new LocalPredictionRuntime();

    for (const rttMs of [100, 100, 100, 100, 100]) {
      runtime.observeRtt(rttMs);
    }

    expect(runtime.getCurrentJitterMs()).toBeLessThan(1);
  });

  it("raises jitter when RTT varies around the smoothed RTT baseline", () => {
    const runtime = new LocalPredictionRuntime();

    for (const rttMs of [100, 160, 100, 160]) {
      runtime.observeRtt(rttMs);
    }

    expect(runtime.getCurrentJitterMs()).toBeGreaterThan(5);
  });
});
