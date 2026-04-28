import { describe, expect, it } from "vitest";
import { resolveActorDisplayY } from "./renderOrchestrator";

describe("resolveActorDisplayY", () => {
  it("adds airborne movement offset above the grounded surface center", () => {
    expect(
      resolveActorDisplayY({
        movementY: 172,
        movementGroundY: 100,
        surfaceCenterY: 160,
      }),
    ).toBe(232);
  });

  it("keeps grounded actors on the surface center when movement y is below the center", () => {
    expect(
      resolveActorDisplayY({
        movementY: 100,
        movementGroundY: 100,
        surfaceCenterY: 160,
      }),
    ).toBe(160);
  });
});
