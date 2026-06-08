import { describe, expect, it } from "vitest";
import { FieldMask, type FFieldRegionSnapshot } from "./fieldProtocol";
import { HeatSmokeSimulation, type ElectricEffectPoint } from "./heatSmokeEffect";

describe("HeatSmokeSimulation", () => {
  it("does not let dense prefab projections starve later macro current cells", () => {
    const simulation = new HeatSmokeSimulation({
      maxSpawnPerSnapshot: 4,
      maxLiveParticles: 32,
      random: () => 0.5,
    });

    const spawned = simulation.spawnFromElectricSnapshot(makeCurrentSnapshot(), (cell) => {
      if (cell.localMacro.x !== 0) {
        return null;
      }

      return Array.from(
        { length: 32 },
        (_value, index): ElectricEffectPoint => ({
          x: 10 + index,
          y: 20,
          z: 30,
          potential: cell.potential,
          sizeWorld: 8,
        }),
      );
    });

    expect(spawned).toBe(4);
    expect(simulation.liveParticles().some((particle) => particle.x === 150)).toBe(true);
  });
});

function makeCurrentSnapshot(): FFieldRegionSnapshot {
  return {
    logicalSceneId: 1,
    chunkCoord: { cx: 0, cy: 0, cz: 0 },
    regionId: 77,
    tickCount: 1,
    fieldMask: FieldMask.ElectricCurrent,
    cellCount: 2,
    macroIndices: Uint16Array.of(0, 1),
    temperatureValues: new Float32Array(0),
    electricValues: new Float32Array(0),
    electricCurrentValues: Float32Array.of(20, 20),
    ionizationValues: new Uint8Array(0),
    smokeDensityValues: new Float32Array(0),
    oxygenValues: new Float32Array(0),
  };
}
