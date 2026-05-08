import { describe, expect, it } from "vitest";

import { DebrisSimulation } from "./debrisEffect";
import { DebrisRenderer } from "./debrisRenderer";

describe("DebrisRenderer", () => {
  it("creates an InstancedMesh sized to maxParticles and starts hidden", () => {
    const sim = new DebrisSimulation();
    const renderer = new DebrisRenderer(sim, { maxParticles: 32 });

    expect(renderer.mesh).toBeDefined();
    expect(renderer.mesh.count).toBe(0);
  });

  it("syncFromSimulation copies particles into instance matrices", () => {
    const sim = new DebrisSimulation({ burstSize: 3, random: () => 0.5 });
    const renderer = new DebrisRenderer(sim, { maxParticles: 16 });

    sim.spawn([{ worldX: 1, worldY: 2, worldZ: 3 }], "destroyed");
    expect(sim.activeCount()).toBe(3);

    renderer.syncFromSimulation();

    expect(renderer.mesh.count).toBe(3);
  });

  it("syncFromSimulation hides overflow slots when particle count drops", () => {
    const sim = new DebrisSimulation({ burstSize: 2, random: () => 0.5 });
    const renderer = new DebrisRenderer(sim, { maxParticles: 16 });

    sim.spawn([{ worldX: 0, worldY: 0, worldZ: 0 }], "destroyed");
    renderer.syncFromSimulation();
    expect(renderer.mesh.count).toBe(2);

    sim.reset();
    renderer.syncFromSimulation();
    expect(renderer.mesh.count).toBe(0);
  });

  it("dispose releases geometry and material without throwing", () => {
    const sim = new DebrisSimulation();
    const renderer = new DebrisRenderer(sim);

    expect(() => renderer.dispose()).not.toThrow();
  });
});
