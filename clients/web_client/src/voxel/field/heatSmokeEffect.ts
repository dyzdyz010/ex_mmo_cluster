import { MacroWorldSize } from "../core/constants";
import type { FFieldRegionSnapshot } from "./fieldProtocol";
import { FieldMask } from "./fieldProtocol";

export const HEAT_SMOKE_DEFAULTS = {
  joulesPerActiveCellParticle: 240,
  fallbackCurrentVoltage: 120,
  fieldTickSeconds: 0.1,
  maxSpawnPerSnapshot: 96,
  maxLiveParticles: 640,
  particleLifetimeMs: 2200,
  particleSizeWorld: MacroWorldSize * 0.16,
  riseSpeedWorldPerSecond: MacroWorldSize * 0.34,
  driftSpeedWorldPerSecond: MacroWorldSize * 0.05,
} as const;

export interface HeatSmokeParticle {
  regionId: number;
  x: number;
  y: number;
  z: number;
  vx: number;
  vy: number;
  vz: number;
  ageMs: number;
  lifetimeMs: number;
  sizeWorld: number;
}

export interface HeatSmokeSimulationOptions {
  joulesPerActiveCellParticle?: number;
  maxSpawnPerSnapshot?: number;
  maxLiveParticles?: number;
  particleLifetimeMs?: number;
  particleSizeWorld?: number;
  riseSpeedWorldPerSecond?: number;
  driftSpeedWorldPerSecond?: number;
  random?: () => number;
}

interface ActiveElectricCell {
  x: number;
  y: number;
  z: number;
  potential: number;
}

export interface ElectricEffectCell {
  localMacro: { x: number; y: number; z: number };
  worldMacro: { x: number; y: number; z: number };
  potential: number;
}

export interface ElectricEffectPoint {
  x: number;
  y: number;
  z: number;
  potential: number;
  sizeWorld?: number;
}

export type ElectricEffectProjector = (
  cell: ElectricEffectCell,
) => readonly ElectricEffectPoint[] | null | undefined;

export class HeatSmokeSimulation {
  private readonly particles: HeatSmokeParticle[] = [];
  private readonly regionHeatEnergyJoulesPerTick = new Map<number, number>();
  private readonly joulesPerActiveCellParticle: number;
  private readonly maxSpawnPerSnapshot: number;
  private readonly maxLiveParticles: number;
  private readonly particleLifetimeMs: number;
  private readonly particleSizeWorld: number;
  private readonly riseSpeedWorldPerSecond: number;
  private readonly driftSpeedWorldPerSecond: number;
  private readonly random: () => number;

  constructor(options: HeatSmokeSimulationOptions = {}) {
    this.joulesPerActiveCellParticle =
      options.joulesPerActiveCellParticle ?? HEAT_SMOKE_DEFAULTS.joulesPerActiveCellParticle;
    this.maxSpawnPerSnapshot =
      options.maxSpawnPerSnapshot ?? HEAT_SMOKE_DEFAULTS.maxSpawnPerSnapshot;
    this.maxLiveParticles = options.maxLiveParticles ?? HEAT_SMOKE_DEFAULTS.maxLiveParticles;
    this.particleLifetimeMs = options.particleLifetimeMs ?? HEAT_SMOKE_DEFAULTS.particleLifetimeMs;
    this.particleSizeWorld = options.particleSizeWorld ?? HEAT_SMOKE_DEFAULTS.particleSizeWorld;
    this.riseSpeedWorldPerSecond =
      options.riseSpeedWorldPerSecond ?? HEAT_SMOKE_DEFAULTS.riseSpeedWorldPerSecond;
    this.driftSpeedWorldPerSecond =
      options.driftSpeedWorldPerSecond ?? HEAT_SMOKE_DEFAULTS.driftSpeedWorldPerSecond;
    this.random = options.random ?? Math.random;
  }

  setRegionHeatSmokeSource(regionId: number, heatEnergyJoulesPerTick: number): void {
    if (!Number.isFinite(heatEnergyJoulesPerTick) || heatEnergyJoulesPerTick <= 0) {
      this.regionHeatEnergyJoulesPerTick.delete(regionId);
      return;
    }
    this.regionHeatEnergyJoulesPerTick.set(regionId, heatEnergyJoulesPerTick);
  }

  spawnFromElectricSnapshot(
    snapshot: FFieldRegionSnapshot,
    projector?: ElectricEffectProjector,
  ): number {
    if (!(snapshot.fieldMask & (FieldMask.ElectricPotential | FieldMask.ElectricCurrent))) {
      return 0;
    }

    const heatEnergyJoulesPerTick =
      this.regionHeatEnergyJoulesPerTick.get(snapshot.regionId) ??
      estimateCurrentHeatEnergyJoulesPerTick(snapshot);
    if (!heatEnergyJoulesPerTick || heatEnergyJoulesPerTick <= 0) {
      return 0;
    }

    const activeCells = activeElectricCells(snapshot);
    if (activeCells.length === 0) {
      return 0;
    }

    const points = activeCells.flatMap((cell) =>
      electricEffectPointsForCell(snapshot, cell, projector),
    );
    if (points.length === 0) {
      return 0;
    }

    const heatScale = heatEnergyJoulesPerTick / this.joulesPerActiveCellParticle;
    const spawnCount = clampInt(Math.ceil(points.length * heatScale), 1, this.maxSpawnPerSnapshot);

    for (let i = 0; i < spawnCount; i++) {
      const point = points[i % points.length]!;
      this.particles.push(this.buildParticleFromPoint(snapshot.regionId, point, heatScale));
    }

    if (this.particles.length > this.maxLiveParticles) {
      this.particles.splice(0, this.particles.length - this.maxLiveParticles);
    }

    return spawnCount;
  }

  update(dtMs: number): void {
    if (dtMs <= 0) {
      return;
    }
    const dtS = dtMs / 1000;

    let writeIdx = 0;
    for (let readIdx = 0; readIdx < this.particles.length; readIdx++) {
      const particle = this.particles[readIdx]!;
      const newAge = particle.ageMs + dtMs;
      if (newAge >= particle.lifetimeMs) {
        continue;
      }

      particle.x += particle.vx * dtS;
      particle.y += particle.vy * dtS;
      particle.z += particle.vz * dtS;
      particle.vx *= 0.985;
      particle.vz *= 0.985;
      particle.ageMs = newAge;

      if (writeIdx !== readIdx) {
        this.particles[writeIdx] = particle;
      }
      writeIdx += 1;
    }

    this.particles.length = writeIdx;
  }

  activeCount(regionId?: number): number {
    if (regionId === undefined) {
      return this.particles.length;
    }
    return this.particles.filter((particle) => particle.regionId === regionId).length;
  }

  liveParticles(): readonly HeatSmokeParticle[] {
    return this.particles;
  }

  clearRegion(regionId: number): void {
    this.regionHeatEnergyJoulesPerTick.delete(regionId);
    this.clearRegionParticles(regionId);
  }

  clearRegionParticles(regionId: number): void {
    let writeIdx = 0;
    for (let readIdx = 0; readIdx < this.particles.length; readIdx++) {
      const particle = this.particles[readIdx]!;
      if (particle.regionId === regionId) {
        continue;
      }
      if (writeIdx !== readIdx) {
        this.particles[writeIdx] = particle;
      }
      writeIdx += 1;
    }
    this.particles.length = writeIdx;
  }

  reset(): void {
    this.regionHeatEnergyJoulesPerTick.clear();
    this.particles.length = 0;
  }

  private buildParticleFromPoint(
    regionId: number,
    point: ElectricEffectPoint,
    heatScale: number,
  ): HeatSmokeParticle {
    const jitterX = (this.random() - 0.5) * MacroWorldSize * 0.34;
    const jitterZ = (this.random() - 0.5) * MacroWorldSize * 0.34;
    const driftAngle = this.random() * Math.PI * 2;
    const driftSpeed =
      this.driftSpeedWorldPerSecond * (0.35 + 0.65 * this.random()) * Math.min(2, heatScale);
    const riseSpeed =
      this.riseSpeedWorldPerSecond * (0.75 + 0.5 * this.random()) * Math.min(1.6, heatScale);
    const potentialScale = Math.max(0.75, Math.min(1.8, Math.abs(point.potential) / 120));

    return {
      regionId,
      x: point.x + jitterX,
      y: point.y,
      z: point.z + jitterZ,
      vx: Math.cos(driftAngle) * driftSpeed,
      vy: riseSpeed,
      vz: Math.sin(driftAngle) * driftSpeed,
      ageMs: 0,
      lifetimeMs: this.particleLifetimeMs,
      sizeWorld: (point.sizeWorld ?? this.particleSizeWorld) * potentialScale,
    };
  }
}

function electricEffectPointsForCell(
  snapshot: FFieldRegionSnapshot,
  cell: ActiveElectricCell,
  projector?: ElectricEffectProjector,
): ElectricEffectPoint[] {
  const worldMacro = {
    x: snapshot.chunkCoord.cx * 16 + cell.x,
    y: snapshot.chunkCoord.cy * 16 + cell.y,
    z: snapshot.chunkCoord.cz * 16 + cell.z,
  };
  const projected = projector?.({
    localMacro: { x: cell.x, y: cell.y, z: cell.z },
    worldMacro,
    potential: cell.potential,
  });
  if (projected && projected.length > 0) {
    return [...projected];
  }
  return [
    {
      x: (worldMacro.x + 0.5) * MacroWorldSize,
      y: (worldMacro.y + 0.92) * MacroWorldSize,
      z: (worldMacro.z + 0.5) * MacroWorldSize,
      potential: cell.potential,
    },
  ];
}

function activeElectricCells(snapshot: FFieldRegionSnapshot): ActiveElectricCell[] {
  const currentCells = activeElectricCellsFromValues(
    snapshot,
    snapshot.electricCurrentValues,
    0.001,
  );
  if (currentCells.length > 0) {
    return currentCells;
  }
  return activeElectricCellsFromValues(snapshot, snapshot.electricValues, 0.5);
}

function activeElectricCellsFromValues(
  snapshot: FFieldRegionSnapshot,
  values: ArrayLike<number>,
  threshold: number,
): ActiveElectricCell[] {
  const cells: ActiveElectricCell[] = [];
  for (let i = 0; i < snapshot.cellCount; i++) {
    const potential = values[i];
    const macroIndex = snapshot.macroIndices[i];
    if (
      potential === undefined ||
      macroIndex === undefined ||
      !Number.isFinite(potential) ||
      Math.abs(potential) < threshold
    ) {
      continue;
    }
    const coord = macroIndexToCoord(macroIndex);
    cells.push({ ...coord, potential });
  }
  return cells;
}

function estimateCurrentHeatEnergyJoulesPerTick(snapshot: FFieldRegionSnapshot): number {
  if (!(snapshot.fieldMask & FieldMask.ElectricCurrent)) {
    return 0;
  }

  let maxCurrentAmps = 0;
  for (let i = 0; i < snapshot.cellCount; i++) {
    const current = snapshot.electricCurrentValues[i];
    if (current !== undefined && Number.isFinite(current)) {
      maxCurrentAmps = Math.max(maxCurrentAmps, Math.abs(current));
    }
  }

  return (
    maxCurrentAmps *
    HEAT_SMOKE_DEFAULTS.fallbackCurrentVoltage *
    HEAT_SMOKE_DEFAULTS.fieldTickSeconds
  );
}

function macroIndexToCoord(idx: number): { x: number; y: number; z: number } {
  const x = idx & 0xf;
  const y = (idx >> 4) & 0xf;
  const z = (idx >> 8) & 0xf;
  return { x, y, z };
}

function clampInt(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, Math.floor(value)));
}
