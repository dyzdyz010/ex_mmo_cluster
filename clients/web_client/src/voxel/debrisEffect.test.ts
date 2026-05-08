import { describe, expect, it } from "vitest";

import {
  DEBRIS_DEFAULTS,
  DebrisSimulation,
  type DebrisSpawnPoint,
} from "./debrisEffect";

// Deterministic RNG for tests:0.5 keeps math sane and avoids edge cases.
const FIXED_RNG = () => 0.5;

function spawnPoint(x: number, y: number, z: number): DebrisSpawnPoint {
  return { worldX: x, worldY: y, worldZ: z };
}

describe("DebrisSimulation.spawn", () => {
  it("spawns burstSize particles per sample point", () => {
    const sim = new DebrisSimulation({ burstSize: 4, random: FIXED_RNG });
    const spawned = sim.spawn([spawnPoint(0, 0, 0), spawnPoint(1, 0, 0)], "destroyed");

    expect(spawned).toBe(8);
    expect(sim.activeCount()).toBe(8);
  });

  it("each particle starts with age=0 at the sample point", () => {
    const sim = new DebrisSimulation({ burstSize: 2, random: FIXED_RNG });
    sim.spawn([spawnPoint(5, 10, -3)], "damaged");

    const live = sim.liveParticles();
    expect(live).toHaveLength(2);
    for (const p of live) {
      expect(p.ageMs).toBe(0);
      expect(p.seedX).toBe(5);
      expect(p.seedY).toBe(10);
      expect(p.seedZ).toBe(-3);
    }
  });

  it("enforces the global cap by trimming oldest particles", () => {
    const sim = new DebrisSimulation({
      burstSize: 4,
      maxLiveParticles: 6,
      random: FIXED_RNG,
    });

    // First spawn: 8 particles (>6) → trim oldest 2, leaving 6.
    sim.spawn([spawnPoint(0, 0, 0), spawnPoint(1, 0, 0)], "destroyed");

    expect(sim.activeCount()).toBe(6);

    // Subsequent spawns continue trimming.
    sim.spawn([spawnPoint(5, 0, 0)], "damaged");
    expect(sim.activeCount()).toBe(6);
  });
});

describe("DebrisSimulation.update", () => {
  it("ages particles and applies gravity over time", () => {
    const sim = new DebrisSimulation({ burstSize: 1, random: () => 0.0 });
    sim.spawn([spawnPoint(0, 0, 0)], "destroyed");

    const before = sim.liveParticles()[0]!;
    const initialVy = before.vy;
    const initialY = before.y;

    sim.update(100); // 100 ms tick.

    const after = sim.liveParticles()[0]!;
    expect(after.ageMs).toBe(100);
    // Gravity is negative (-9.8 m/s²); vy must have decreased.
    expect(after.vy).toBeLessThan(initialVy);
    // Position integration uses pre-gravity velocity vs post — symplectic
    // Euler picks post-velocity, so y can move either way depending on
    // initial sign. We just assert that y has *changed* by the integration.
    expect(after.y).not.toBe(initialY);
  });

  it("removes particles that have aged beyond particleLifetimeMs", () => {
    const sim = new DebrisSimulation({
      burstSize: 1,
      particleLifetimeMs: 200,
      random: FIXED_RNG,
    });
    sim.spawn([spawnPoint(0, 0, 0)], "damaged");

    expect(sim.activeCount()).toBe(1);

    sim.update(150); // age = 150
    expect(sim.activeCount()).toBe(1);

    sim.update(60); // age = 210 → expired
    expect(sim.activeCount()).toBe(0);
  });

  it("update with non-positive dt is a no-op", () => {
    const sim = new DebrisSimulation({ burstSize: 1, random: FIXED_RNG });
    sim.spawn([spawnPoint(0, 0, 0)], "damaged");

    const beforeY = sim.liveParticles()[0]!.y;
    sim.update(0);
    const afterY = sim.liveParticles()[0]!.y;
    expect(afterY).toBe(beforeY);

    sim.update(-50);
    expect(sim.liveParticles()[0]!.y).toBe(beforeY);
  });

  it("partial expiry compaction keeps the live array dense", () => {
    const sim = new DebrisSimulation({
      burstSize: 4,
      particleLifetimeMs: 500,
      random: FIXED_RNG,
    });

    sim.spawn([spawnPoint(0, 0, 0)], "destroyed");

    sim.update(300); // all 4 alive at age 300

    sim.spawn([spawnPoint(10, 0, 0)], "damaged");
    expect(sim.activeCount()).toBe(8);

    // 250 ms tick → first batch ages to 550 (expired);second batch to 250.
    sim.update(250);

    expect(sim.activeCount()).toBe(4);
  });
});

describe("DebrisSimulation defaults / reset", () => {
  it("DEBRIS_DEFAULTS exposes documented constants", () => {
    expect(DEBRIS_DEFAULTS.burstSize).toBe(8);
    expect(DEBRIS_DEFAULTS.maxLiveParticles).toBe(500);
    expect(DEBRIS_DEFAULTS.particleLifetimeMs).toBe(800);
    expect(DEBRIS_DEFAULTS.particleSizeM).toBe(0.05);
    expect(DEBRIS_DEFAULTS.gravityMps2).toBe(-9.8);
  });

  it("reset drops every active particle", () => {
    const sim = new DebrisSimulation({ burstSize: 4, random: FIXED_RNG });
    sim.spawn([spawnPoint(0, 0, 0)], "destroyed");
    expect(sim.activeCount()).toBe(4);

    sim.reset();
    expect(sim.activeCount()).toBe(0);
    expect(sim.liveParticles()).toHaveLength(0);
  });
});
