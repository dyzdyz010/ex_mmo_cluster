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
  emissionGroupKey?: string;
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
  emissionGroupKey?: string;
  maxEmissionsPerSnapshot?: number;
}

export interface SmokeDensityEffectCell {
  localMacro: { x: number; y: number; z: number };
  worldMacro: { x: number; y: number; z: number };
  smokeDensityPercent: number;
}

export interface SmokeDensityEffectPoint {
  x: number;
  y: number;
  z: number;
  smokeDensityPercent: number;
  sizeWorld?: number;
  emissionGroupKey?: string;
  maxEmissionsPerSnapshot?: number;
}

export type ElectricEffectProjector = (
  cell: ElectricEffectCell,
) => readonly ElectricEffectPoint[] | null | undefined;

export type SmokeDensityEffectProjector = (
  cell: SmokeDensityEffectCell,
) => readonly SmokeDensityEffectPoint[] | null | undefined;

interface HeatSmokeSourcePoint {
  x: number;
  y: number;
  z: number;
  intensity: number;
  sizeWorld?: number;
  emissionGroupKey?: string;
  maxEmissionsPerSnapshot?: number;
}

interface HeatSmokePointGroup {
  key: string;
  points: HeatSmokeSourcePoint[];
  maxEmissionsPerSnapshot: number | null;
}

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

    const pointGroups = electricEffectPointGroupsForSnapshot(snapshot, activeCells, projector);
    if (pointGroups.length === 0) {
      return 0;
    }

    const heatScale = heatEnergyJoulesPerTick / this.joulesPerActiveCellParticle;
    return this.spawnFromPointGroups(snapshot.regionId, pointGroups, heatScale);
  }

  spawnFromSmokeDensitySnapshot(
    snapshot: FFieldRegionSnapshot,
    projector?: SmokeDensityEffectProjector,
  ): number {
    if (!(snapshot.fieldMask & FieldMask.SmokeDensity)) {
      return 0;
    }

    const activeCells = activeSmokeDensityCells(snapshot);
    if (activeCells.length === 0) {
      return 0;
    }

    const pointGroups = smokeDensityEffectPointGroupsForSnapshot(snapshot, activeCells, projector);
    if (pointGroups.length === 0) {
      return 0;
    }

    const maxDensityPercent = activeCells.reduce(
      (max, cell) => Math.max(max, cell.smokeDensityPercent),
      0,
    );
    const densityScale = Math.max(1, Math.min(4, maxDensityPercent / 20));
    return this.spawnFromPointGroups(snapshot.regionId, pointGroups, densityScale);
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

  clearParticles(): void {
    this.particles.length = 0;
  }

  reset(): void {
    this.regionHeatEnergyJoulesPerTick.clear();
    this.particles.length = 0;
  }

  private buildParticleFromPoint(
    regionId: number,
    point: HeatSmokeSourcePoint,
    heatScale: number,
  ): HeatSmokeParticle {
    const jitterX = (this.random() - 0.5) * MacroWorldSize * 0.34;
    const jitterZ = (this.random() - 0.5) * MacroWorldSize * 0.34;
    const driftAngle = this.random() * Math.PI * 2;
    const driftSpeed =
      this.driftSpeedWorldPerSecond * (0.35 + 0.65 * this.random()) * Math.min(2, heatScale);
    const riseSpeed =
      this.riseSpeedWorldPerSecond * (0.75 + 0.5 * this.random()) * Math.min(1.6, heatScale);
    const intensityScale = Math.max(0.75, Math.min(1.8, Math.abs(point.intensity) / 120));

    const particle: HeatSmokeParticle = {
      regionId,
      x: point.x + jitterX,
      y: point.y,
      z: point.z + jitterZ,
      vx: Math.cos(driftAngle) * driftSpeed,
      vy: riseSpeed,
      vz: Math.sin(driftAngle) * driftSpeed,
      ageMs: 0,
      lifetimeMs: this.particleLifetimeMs,
      sizeWorld: (point.sizeWorld ?? this.particleSizeWorld) * intensityScale,
    };
    if (point.emissionGroupKey) {
      particle.emissionGroupKey = point.emissionGroupKey;
    }
    return particle;
  }

  private upsertParticleFromPoint(
    regionId: number,
    point: HeatSmokeSourcePoint,
    heatScale: number,
  ): void {
    const next = this.buildParticleFromPoint(regionId, point, heatScale);
    if (point.emissionGroupKey) {
      const existing = this.particles.find(
        (particle) =>
          particle.regionId === regionId && particle.emissionGroupKey === point.emissionGroupKey,
      );
      if (existing) {
        Object.assign(existing, next);
        return;
      }
    }

    this.particles.push(next);
  }

  private spawnFromPointGroups(
    regionId: number,
    pointGroups: readonly HeatSmokePointGroup[],
    heatScale: number,
  ): number {
    const pointCount = pointGroups.reduce((sum, group) => sum + groupSpawnWeight(group), 0);
    const spawnCount = clampInt(Math.ceil(pointCount * heatScale), 1, this.maxSpawnPerSnapshot);
    const points = fairEffectPointSample(pointGroups, spawnCount);

    for (const point of points) {
      this.upsertParticleFromPoint(regionId, point, heatScale);
    }

    if (this.particles.length > this.maxLiveParticles) {
      this.particles.splice(0, this.particles.length - this.maxLiveParticles);
    }

    return points.length;
  }
}

function electricEffectPointGroupsForSnapshot(
  snapshot: FFieldRegionSnapshot,
  activeCells: readonly ActiveElectricCell[],
  projector?: ElectricEffectProjector,
): HeatSmokePointGroup[] {
  const groupsByKey = new Map<string, HeatSmokePointGroup>();
  for (const cell of activeCells) {
    const group = electricEffectPointGroupForCell(snapshot, cell, projector);
    if (!group) {
      continue;
    }
    mergeEffectPointGroup(groupsByKey, group);
  }
  return [...groupsByKey.values()];
}

function electricEffectPointGroupForCell(
  snapshot: FFieldRegionSnapshot,
  cell: ActiveElectricCell,
  projector?: ElectricEffectProjector,
): HeatSmokePointGroup | null {
  const worldMacro = {
    x: snapshot.chunkCoord.cx * 16 + cell.x,
    y: snapshot.chunkCoord.cy * 16 + cell.y,
    z: snapshot.chunkCoord.cz * 16 + cell.z,
  };
  const macroKey = `macro:${worldMacro.x},${worldMacro.y},${worldMacro.z}`;
  const projected = projector?.({
    localMacro: { x: cell.x, y: cell.y, z: cell.z },
    worldMacro,
    potential: cell.potential,
  });
  if (projected && projected.length > 0) {
    return normalizeElectricEffectPointGroup(macroKey, projected);
  }
  return {
    key: macroKey,
    points: [
      {
        x: (worldMacro.x + 0.5) * MacroWorldSize,
        y: (worldMacro.y + 0.92) * MacroWorldSize,
        z: (worldMacro.z + 0.5) * MacroWorldSize,
        intensity: Math.abs(cell.potential),
      },
    ],
    maxEmissionsPerSnapshot: null,
  };
}

function smokeDensityEffectPointGroupsForSnapshot(
  snapshot: FFieldRegionSnapshot,
  activeCells: readonly ActiveSmokeDensityCell[],
  projector?: SmokeDensityEffectProjector,
): HeatSmokePointGroup[] {
  const groupsByKey = new Map<string, HeatSmokePointGroup>();
  for (const cell of activeCells) {
    const group = smokeDensityEffectPointGroupForCell(snapshot, cell, projector);
    if (!group) {
      continue;
    }
    mergeEffectPointGroup(groupsByKey, group);
  }
  return [...groupsByKey.values()];
}

function smokeDensityEffectPointGroupForCell(
  snapshot: FFieldRegionSnapshot,
  cell: ActiveSmokeDensityCell,
  projector?: SmokeDensityEffectProjector,
): HeatSmokePointGroup | null {
  const worldMacro = {
    x: snapshot.chunkCoord.cx * 16 + cell.x,
    y: snapshot.chunkCoord.cy * 16 + cell.y,
    z: snapshot.chunkCoord.cz * 16 + cell.z,
  };
  const macroKey = `smoke:${worldMacro.x},${worldMacro.y},${worldMacro.z}`;
  const projected = projector?.({
    localMacro: { x: cell.x, y: cell.y, z: cell.z },
    worldMacro,
    smokeDensityPercent: cell.smokeDensityPercent,
  });
  if (projected && projected.length > 0) {
    return normalizeSmokeDensityEffectPointGroup(macroKey, projected);
  }
  return {
    key: macroKey,
    points: [
      {
        x: (worldMacro.x + 0.5) * MacroWorldSize,
        y: (worldMacro.y + 0.92) * MacroWorldSize,
        z: (worldMacro.z + 0.5) * MacroWorldSize,
        intensity: cell.smokeDensityPercent * 3,
      },
    ],
    maxEmissionsPerSnapshot: null,
  };
}

function normalizeElectricEffectPointGroup(
  fallbackKey: string,
  points: readonly ElectricEffectPoint[],
): HeatSmokePointGroup | null {
  const usablePoints = points.filter(
    (point) =>
      Number.isFinite(point.x) &&
      Number.isFinite(point.y) &&
      Number.isFinite(point.z) &&
      Number.isFinite(point.potential),
  );
  if (usablePoints.length === 0) {
    return null;
  }

  return {
    key: usablePoints.find((point) => point.emissionGroupKey)?.emissionGroupKey ?? fallbackKey,
    points: usablePoints.map((point) =>
      heatSmokeSourcePoint({
        x: point.x,
        y: point.y,
        z: point.z,
        intensity: Math.abs(point.potential),
        sizeWorld: point.sizeWorld,
        emissionGroupKey: point.emissionGroupKey,
        maxEmissionsPerSnapshot: point.maxEmissionsPerSnapshot,
      }),
    ),
    maxEmissionsPerSnapshot: minimumEmissionCap(usablePoints),
  };
}

function normalizeSmokeDensityEffectPointGroup(
  fallbackKey: string,
  points: readonly SmokeDensityEffectPoint[],
): HeatSmokePointGroup | null {
  const usablePoints = points.filter(
    (point) =>
      Number.isFinite(point.x) &&
      Number.isFinite(point.y) &&
      Number.isFinite(point.z) &&
      Number.isFinite(point.smokeDensityPercent),
  );
  if (usablePoints.length === 0) {
    return null;
  }

  return {
    key: usablePoints.find((point) => point.emissionGroupKey)?.emissionGroupKey ?? fallbackKey,
    points: usablePoints.map((point) =>
      heatSmokeSourcePoint({
        x: point.x,
        y: point.y,
        z: point.z,
        intensity: point.smokeDensityPercent * 3,
        sizeWorld: point.sizeWorld,
        emissionGroupKey: point.emissionGroupKey,
        maxEmissionsPerSnapshot: point.maxEmissionsPerSnapshot,
      }),
    ),
    maxEmissionsPerSnapshot: minimumEmissionCap(usablePoints),
  };
}

function heatSmokeSourcePoint(input: {
  x: number;
  y: number;
  z: number;
  intensity: number;
  sizeWorld: number | undefined;
  emissionGroupKey: string | undefined;
  maxEmissionsPerSnapshot: number | undefined;
}): HeatSmokeSourcePoint {
  const point: HeatSmokeSourcePoint = {
    x: input.x,
    y: input.y,
    z: input.z,
    intensity: input.intensity,
  };
  if (input.sizeWorld !== undefined) {
    point.sizeWorld = input.sizeWorld;
  }
  if (input.emissionGroupKey !== undefined) {
    point.emissionGroupKey = input.emissionGroupKey;
  }
  if (input.maxEmissionsPerSnapshot !== undefined) {
    point.maxEmissionsPerSnapshot = input.maxEmissionsPerSnapshot;
  }
  return point;
}

function mergeEffectPointGroup(
  groupsByKey: Map<string, HeatSmokePointGroup>,
  next: HeatSmokePointGroup,
): void {
  const existing = groupsByKey.get(next.key);
  if (!existing) {
    groupsByKey.set(next.key, next);
    return;
  }

  existing.points.push(...next.points);
  existing.maxEmissionsPerSnapshot = mergeEmissionCaps(
    existing.maxEmissionsPerSnapshot,
    next.maxEmissionsPerSnapshot,
  );
}

function minimumEmissionCap(
  points: readonly { maxEmissionsPerSnapshot?: number }[],
): number | null {
  let cap: number | null = null;
  for (const point of points) {
    const pointCap = point.maxEmissionsPerSnapshot;
    if (pointCap === undefined || !Number.isFinite(pointCap)) {
      continue;
    }
    const normalized = Math.max(0, Math.floor(pointCap));
    cap = cap === null ? normalized : Math.min(cap, normalized);
  }
  return cap;
}

function mergeEmissionCaps(left: number | null, right: number | null): number | null {
  if (left === null) {
    return right;
  }
  if (right === null) {
    return left;
  }
  return Math.min(left, right);
}

function groupSpawnWeight(group: HeatSmokePointGroup): number {
  if (group.maxEmissionsPerSnapshot === null) {
    return group.points.length;
  }
  return Math.min(group.points.length, group.maxEmissionsPerSnapshot);
}

function fairEffectPointSample(
  pointGroups: readonly HeatSmokePointGroup[],
  spawnCount: number,
): HeatSmokeSourcePoint[] {
  const groups = pointGroups.filter(
    (group) => group.points.length > 0 && groupSpawnCapacity(group) > 0,
  );
  if (groups.length === 0 || spawnCount <= 0) {
    return [];
  }

  const selected: HeatSmokeSourcePoint[] = [];
  const emissionsByGroup = new Array(groups.length).fill(0) as number[];
  const targetCount = Math.min(spawnCount, totalSpawnCapacity(groups));
  const order = fairGroupOrder(groups.length, targetCount);

  while (selected.length < targetCount) {
    let emittedInRound = 0;
    for (const groupIndex of order) {
      if (selected.length >= targetCount) {
        break;
      }
      const group = groups[groupIndex]!;
      const capacity = groupSpawnCapacity(group);
      const emissionIndex = emissionsByGroup[groupIndex]!;
      if (emissionIndex >= capacity) {
        continue;
      }
      selected.push(group.points[emissionIndex % group.points.length]!);
      emissionsByGroup[groupIndex] = emissionIndex + 1;
      emittedInRound += 1;
    }
    if (emittedInRound === 0) {
      break;
    }
  }

  return selected;
}

function groupSpawnCapacity(group: HeatSmokePointGroup): number {
  return group.maxEmissionsPerSnapshot ?? Number.POSITIVE_INFINITY;
}

function totalSpawnCapacity(groups: readonly HeatSmokePointGroup[]): number {
  let total = 0;
  for (const group of groups) {
    const capacity = groupSpawnCapacity(group);
    if (capacity === Number.POSITIVE_INFINITY) {
      return Number.POSITIVE_INFINITY;
    }
    total += capacity;
  }
  return total;
}

function fairGroupOrder(groupCount: number, spawnCount: number): number[] {
  if (spawnCount >= groupCount) {
    return Array.from({ length: groupCount }, (_value, index) => index);
  }

  return Array.from({ length: spawnCount }, (_value, index) =>
    Math.min(groupCount - 1, Math.floor(((index + 0.5) * groupCount) / spawnCount)),
  );
}

interface ActiveSmokeDensityCell {
  x: number;
  y: number;
  z: number;
  smokeDensityPercent: number;
}

function activeSmokeDensityCells(snapshot: FFieldRegionSnapshot): ActiveSmokeDensityCell[] {
  const cells: ActiveSmokeDensityCell[] = [];
  for (let i = 0; i < snapshot.cellCount; i++) {
    const smokeDensityPercent = snapshot.smokeDensityValues[i];
    const macroIndex = snapshot.macroIndices[i];
    if (
      smokeDensityPercent === undefined ||
      macroIndex === undefined ||
      !Number.isFinite(smokeDensityPercent) ||
      smokeDensityPercent < 0.1
    ) {
      continue;
    }
    const coord = macroIndexToCoord(macroIndex);
    cells.push({ ...coord, smokeDensityPercent });
  }
  return cells;
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
