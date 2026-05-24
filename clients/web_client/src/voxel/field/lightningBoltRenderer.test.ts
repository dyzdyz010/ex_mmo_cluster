import { describe, expect, it } from "vitest";
import { LightningBoltRenderer } from "./lightningBoltRenderer";

describe("LightningBoltRenderer", () => {
  it("renders a bounded preallocated line effect for a strike", () => {
    const renderer = new LightningBoltRenderer({ maxSegments: 64, ttlMs: 140 });

    renderer.strike({ x: 2, y: 7, z: 4 }, { x: 2, y: 3, z: 4 }, 1000);
    renderer.update(1000);

    expect(renderer.group.visible).toBe(true);
    expect(renderer.snapshot()).toMatchObject({
      activeBolts: 1,
      visibleSegments: expect.any(Number),
      maxSegments: 64,
    });
    expect(renderer.snapshot().visibleSegments).toBeGreaterThan(0);
    expect(renderer.snapshot().visibleSegments).toBeLessThanOrEqual(64);

    renderer.update(1200);

    expect(renderer.group.visible).toBe(false);
    expect(renderer.snapshot()).toMatchObject({ activeBolts: 0, visibleSegments: 0 });
    renderer.dispose();
  });

  it("keeps the default bolt visible long enough for manual testing", () => {
    const renderer = new LightningBoltRenderer({ maxSegments: 64 });

    renderer.strike({ x: 2, y: 7, z: 4 }, { x: 2, y: 3, z: 4 }, 1000);
    renderer.update(1250);

    expect(renderer.snapshot().visibleSegments).toBeGreaterThan(0);
    renderer.dispose();
  });
});
