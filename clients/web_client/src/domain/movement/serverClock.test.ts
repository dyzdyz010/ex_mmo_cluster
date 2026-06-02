import { describe, expect, it } from "vitest";
import { ServerClockEstimator } from "./serverClock";

describe("ServerClockEstimator", () => {
  it("keeps the render clock on low-rtt samples when a queued TimeSync outlier arrives", () => {
    const clock = new ServerClockEstimator();

    clock.observe(
      {
        requestId: 1,
        clientSendTs: 1_000,
        serverRecvTs: 1_500,
        serverSendTs: 1_500,
      },
      1_100,
    );
    clock.observe(
      {
        requestId: 2,
        clientSendTs: 2_000,
        serverRecvTs: 4_000,
        serverSendTs: 4_000,
      },
      7_000,
    );

    expect(clock.debugSnapshot()).toMatchObject({
      serverClockOffsetMs: 450,
      rawServerClockOffsetMs: -500,
      timeSyncRttMs: 5_000,
      timeSyncSampleCount: 2,
      timeSyncRejectedOffsetSampleCount: 1,
      timeSyncOffsetJitterMs: 0,
      timeSyncOffsetJumpCount: 0,
    });
  });

  it("does not initialize the render clock from a queued high-rtt sample", () => {
    const clock = new ServerClockEstimator();

    clock.observe(
      {
        requestId: 1,
        clientSendTs: 1_000,
        serverRecvTs: 4_000,
        serverSendTs: 4_000,
      },
      7_000,
    );

    expect(clock.debugSnapshot()).toMatchObject({
      serverClockOffsetMs: null,
      rawServerClockOffsetMs: 0,
      timeSyncRejectedOffsetSampleCount: 1,
      timeSyncSampleCount: 1,
    });

    clock.observe(
      {
        requestId: 2,
        clientSendTs: 8_000,
        serverRecvTs: 8_500,
        serverSendTs: 8_500,
      },
      8_100,
    );

    expect(clock.debugSnapshot()).toMatchObject({
      serverClockOffsetMs: 450,
      rawServerClockOffsetMs: 450,
      timeSyncRejectedOffsetSampleCount: 1,
      timeSyncSampleCount: 2,
    });
  });
});
