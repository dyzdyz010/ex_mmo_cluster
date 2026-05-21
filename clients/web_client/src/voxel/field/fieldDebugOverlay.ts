// Phase 6: FieldDebugOverlay — Three.js debug overlay for FieldRegion field values.
//
// Hidden by default; toggled with Ctrl+\ (or the "Field" button in the voxel panel). Shows:
//   - Temperature field: ambient transparent / hot red / cold purple InstancedMesh cubes
//   - Electric potential: black (low) → yellow (high) InstancedMesh cubes
//
// §5.5 constraint: hidden by default, dev hotkey only, no production player UX.

import {
  BoxGeometry,
  BufferGeometry,
  Color,
  Float32BufferAttribute,
  Group,
  InstancedBufferAttribute,
  InstancedMesh,
  LineBasicMaterial,
  LineSegments,
  Matrix4,
  MeshBasicMaterial,
  Object3D,
} from "three";
import { MacroWorldSize, VoxelConstants } from "../core/constants";
import type { FMacroCoord } from "../core/types";
import { MICRO_SLOT_COORDS } from "../prefab/math";
import type { PrefabRasterCell } from "../prefab";
import type { VoxelOverlayProjection } from "../overlayTarget";
import { buildPrefabRasterSurfaceOutlineGeometry } from "../../render/prefabPreviewGeometry";
import type { FFieldRegionSnapshot } from "./fieldProtocol";
import { FieldMask } from "./fieldProtocol";
import { HeatSmokeSimulation, type ElectricEffectPoint } from "./heatSmokeEffect";
import { HeatSmokeRenderer } from "./heatSmokeRenderer";

const CELL_SIZE = MacroWorldSize; // 100 world units per macro cell
const MAX_CELLS = 4096;
const HIGH_ELEC_COLOR = new Color(1, 1, 0); // yellow
const LOW_ELEC_COLOR = new Color(0, 0, 0); // black
const TEMP_HOT_COLOR = new Color(1, 0, 0);
const TEMP_COLD_COLOR = new Color(0.55, 0, 1);
const TEMP_FULL_OPACITY_DELTA = 20;
const TEMP_VISUAL_GAMMA = 0.25;
const TEMP_MAX_OPACITY = 0.62;
const TEMP_OPACITY_BUCKETS = [0.08, 0.16, 0.28, 0.42, TEMP_MAX_OPACITY] as const;
const MICRO_ELECTRIC_COLOR = 0xfacc15;
const MICRO_TEMP_HOT_COLOR = 0xff4040;
const MICRO_TEMP_COLD_COLOR = 0x9d4edd;
// Show only the top-N cells that deviate from the snapshot background.
// Dense legacy snapshots estimate the background with a median. Sparse server
// snapshots only contain anomaly cells, so they fall back to the current field
// environment baseline instead of treating the single anomaly as background.
const TEMP_ENV_BASELINE = 20;
const TEMP_TOP_N = 150;
const TEMP_MIN_DELTA_FROM_BACKGROUND = 0.0001;
const HIDDEN_INSTANCE_MATRIX = new Matrix4().makeScale(0, 0, 0);

interface TemperatureMeshBucket {
  kind: "hot" | "cold";
  opacity: number;
  mesh: InstancedMesh;
}

interface TemperatureFieldStats {
  maxTemperatureCelsius: number | null;
  maxAbsTemperatureDeltaCelsius: number;
  averageAbsTemperatureDeltaCelsius: number;
}

const EMPTY_TEMPERATURE_STATS: TemperatureFieldStats = {
  maxTemperatureCelsius: null,
  maxAbsTemperatureDeltaCelsius: 0,
  averageAbsTemperatureDeltaCelsius: 0,
};

export interface FieldRegionOverlay {
  regionId: number;
  chunkCoord: { cx: number; cy: number; cz: number };
  group: Group;
  temperatureMeshes: TemperatureMeshBucket[];
  electricMesh: InstancedMesh | null;
  temperatureHotMicroLines: LineSegments | null;
  temperatureColdMicroLines: LineSegments | null;
  electricMicroLines: LineSegments | null;
  temperatureMicroCells: number;
  electricMicroCells: number;
  temperatureMicroGroups: number;
  electricMicroGroups: number;
  temperatureStats: TemperatureFieldStats;
}

export interface FieldDebugOverlaySnapshot {
  visible: boolean;
  regionCount: number;
  regions: Array<{
    regionId: number;
    chunkCoord: { cx: number; cy: number; cz: number };
    temperatureCells: number;
    electricCells: number;
    smokeParticles: number;
    maxTemperatureCelsius: number | null;
    maxAbsTemperatureDeltaCelsius: number;
    averageAbsTemperatureDeltaCelsius: number;
    temperatureMicroCells: number;
    electricMicroCells: number;
    temperatureMicroGroups: number;
    electricMicroGroups: number;
  }>;
}

export type FieldOverlayProjector = (worldMacro: FMacroCoord) => VoxelOverlayProjection;

/**
 * Manages debug overlay meshes for all active FieldRegions.
 * Attach `.rootGroup` to the scene root.
 */
export class FieldDebugOverlay {
  readonly rootGroup: Group;
  private visible = false;
  private regions = new Map<number, FieldRegionOverlay>();
  private readonly tmpDummy = new Object3D();
  private readonly tmpMatrix = new Matrix4();
  private readonly tmpColor = new Color();
  private readonly heatSmoke = new HeatSmokeSimulation();
  private readonly heatSmokeRenderer = new HeatSmokeRenderer(this.heatSmoke);
  private overlayProjector: FieldOverlayProjector | null = null;

  constructor() {
    this.rootGroup = new Group();
    this.rootGroup.visible = false;
    this.rootGroup.name = "FieldDebugOverlay";
    this.rootGroup.add(this.heatSmokeRenderer.mesh);
    this._bindHotkey();
  }

  /** Called when a new FieldRegionSnapshot arrives (0x73). */
  onFieldSnapshot(snapshot: FFieldRegionSnapshot): void {
    const isNew = !this.regions.has(snapshot.regionId);
    let overlay = this.regions.get(snapshot.regionId);
    if (!overlay) {
      overlay = this._createOverlay(snapshot);
      this.regions.set(snapshot.regionId, overlay);
      this.rootGroup.add(overlay.group);
    }
    const projector = this.overlayProjector ?? undefined;
    this._updateOverlay(overlay, snapshot, projector);
    const smokeSpawned = this.heatSmoke.spawnFromElectricSnapshot(
      snapshot,
      projector
        ? (cell) => electricEffectPointsForProjection(projector(cell.worldMacro), cell.potential)
        : undefined,
    );
    const tempCount = temperatureCellCount(overlay);
    const elecCount = electricCellCount(overlay);
    let tMin = Infinity;
    let tMax = -Infinity;
    let tSum = 0;
    let nonZeroCount = 0;
    for (let i = 0; i < snapshot.cellCount; i++) {
      const v = snapshot.temperatureValues[i];
      if (v === undefined) continue;
      if (v < tMin) tMin = v;
      if (v > tMax) tMax = v;
      tSum += v;
      if (Math.abs(v) > 0.0001) nonZeroCount++;
    }
    const tAvg = snapshot.cellCount > 0 ? tSum / snapshot.cellCount : 0;
    console.info(
      `[FieldDebugOverlay] snapshot region=${snapshot.regionId} ` +
        `chunk=${snapshot.chunkCoord.cx},${snapshot.chunkCoord.cy},${snapshot.chunkCoord.cz} ` +
        `tick=${snapshot.tickCount} mask=0x${snapshot.fieldMask.toString(16)} ` +
        `cells=${snapshot.cellCount} nonzero=${nonZeroCount} ` +
        `temp_min=${tMin.toFixed(3)} temp_max=${tMax.toFixed(3)} temp_avg=${tAvg.toFixed(3)} ` +
        `rendered_temp=${tempCount} rendered_elec=${elecCount} ` +
        `micro_temp=${overlay.temperatureMicroCells} micro_elec=${overlay.electricMicroCells} ` +
        `smoke_spawned=${smokeSpawned} ` +
        `new=${isNew} group_visible=${this.rootGroup.visible} regions_total=${this.regions.size}`,
    );
  }

  /** Called when FieldRegionDestroyed (0x74) arrives. */
  onRegionDestroyed(regionId: number): void {
    const overlay = this.regions.get(regionId);
    if (overlay) {
      this.rootGroup.remove(overlay.group);
      _disposeOverlay(overlay);
      this.regions.delete(regionId);
    }
    this.heatSmoke.clearRegion(regionId);
    this.heatSmokeRenderer.syncFromSimulation();
    console.info(
      `[FieldDebugOverlay] destroyed region=${regionId} existed=${overlay !== undefined} ` +
        `regions_remaining=${this.regions.size}`,
    );
  }

  /** Clear all regions (e.g., on chunk invalidate). */
  clear(): void {
    for (const overlay of this.regions.values()) {
      this.rootGroup.remove(overlay.group);
      _disposeOverlay(overlay);
    }
    this.regions.clear();
    this.heatSmoke.reset();
    this.heatSmokeRenderer.syncFromSimulation();
  }

  show(): void {
    this.setVisible(true);
  }

  hide(): void {
    this.setVisible(false);
  }

  setVisible(visible: boolean): void {
    this.visible = visible;
    this.rootGroup.visible = visible;
    console.info(`[FieldDebugOverlay] set visible=${this.visible} regions=${this.regions.size}`);
  }

  toggle(): void {
    this.setVisible(!this.visible);
    console.info(`[FieldDebugOverlay] toggle visible=${this.visible} regions=${this.regions.size}`);
  }

  isVisible(): boolean {
    return this.visible;
  }

  setProjector(projector: FieldOverlayProjector | null): void {
    this.overlayProjector = projector;
  }

  snapshot(): FieldDebugOverlaySnapshot {
    return {
      visible: this.visible,
      regionCount: this.regions.size,
      regions: Array.from(this.regions.values()).map((overlay) => ({
        regionId: overlay.regionId,
        chunkCoord: overlay.chunkCoord,
        temperatureCells: temperatureCellCount(overlay),
        electricCells: electricCellCount(overlay),
        smokeParticles: this.heatSmoke.activeCount(overlay.regionId),
        temperatureMicroCells: overlay.temperatureMicroCells,
        electricMicroCells: overlay.electricMicroCells,
        temperatureMicroGroups: overlay.temperatureMicroGroups,
        electricMicroGroups: overlay.electricMicroGroups,
        ...overlay.temperatureStats,
      })),
    };
  }

  setRegionHeatSmokeSource(regionId: number | string, heatEnergyJoulesPerTick: number): void {
    const normalizedRegionId = normalizeRegionId(regionId);
    if (normalizedRegionId === null) {
      return;
    }
    this.heatSmoke.setRegionHeatSmokeSource(normalizedRegionId, heatEnergyJoulesPerTick);
  }

  updateSmoke(dtMs: number): void {
    this.heatSmoke.update(dtMs);
    this.heatSmokeRenderer.syncFromSimulation();
  }

  dispose(): void {
    this.clear();
    this.heatSmokeRenderer.dispose();
  }

  private _createOverlay(snapshot: FFieldRegionSnapshot): FieldRegionOverlay {
    const group = new Group();
    group.name = `field-region-${snapshot.regionId}`;

    const { cx, cy, cz } = snapshot.chunkCoord;
    // Position the group at chunk origin in world space
    group.position.set(cx * 16 * CELL_SIZE, cy * 16 * CELL_SIZE, cz * 16 * CELL_SIZE);

    const makeCellGeometry = () =>
      new BoxGeometry(CELL_SIZE * 0.85, CELL_SIZE * 0.85, CELL_SIZE * 0.85);
    const temperatureMeshes: TemperatureMeshBucket[] = [];
    let electricMesh: InstancedMesh | null = null;
    let temperatureHotMicroLines: LineSegments | null = null;
    let temperatureColdMicroLines: LineSegments | null = null;
    let electricMicroLines: LineSegments | null = null;

    if (snapshot.fieldMask & FieldMask.Temperature) {
      // depthTest:false + depthWrite:false so field cells are visible through terrain.
      // WebGPU ignores WebGL shader patch hooks, so temperature opacity is
      // represented with standard material opacity buckets instead of a custom
      // per-instance alpha attribute.
      for (const kind of ["hot", "cold"] as const) {
        for (const opacity of TEMP_OPACITY_BUCKETS) {
          const mat = makeTemperatureMaterial(kind, opacity);
          const mesh = new InstancedMesh(makeCellGeometry(), mat, MAX_CELLS);
          mesh.name = `temperature-${kind}-${opacity.toFixed(2)}`;
          mesh.count = 0;
          mesh.frustumCulled = false;
          mesh.renderOrder = 5;
          initializeHiddenInstances(mesh);
          temperatureMeshes.push({ kind, opacity, mesh });
          group.add(mesh);
        }
      }
      temperatureHotMicroLines = makeMicroLineSegments(
        "temperature-hot-micro-wire",
        MICRO_TEMP_HOT_COLOR,
      );
      temperatureColdMicroLines = makeMicroLineSegments(
        "temperature-cold-micro-wire",
        MICRO_TEMP_COLD_COLOR,
      );
      group.add(temperatureHotMicroLines, temperatureColdMicroLines);
    }

    if (snapshot.fieldMask & FieldMask.ElectricPotential) {
      const mat = new MeshBasicMaterial({
        transparent: true,
        opacity: 0.42,
        vertexColors: true,
        depthTest: false,
        depthWrite: false,
      });
      electricMesh = new InstancedMesh(makeCellGeometry(), mat, MAX_CELLS);
      electricMesh.name = "electric-potential";
      electricMesh.count = 0;
      electricMesh.frustumCulled = false;
      electricMesh.renderOrder = 5;
      electricMesh.instanceColor = new InstancedBufferAttribute(new Float32Array(MAX_CELLS * 3), 3);
      initializeHiddenInstances(electricMesh);
      group.add(electricMesh);
      electricMicroLines = makeMicroLineSegments("electric-micro-wire", MICRO_ELECTRIC_COLOR);
      group.add(electricMicroLines);
    }

    return {
      regionId: snapshot.regionId,
      chunkCoord: snapshot.chunkCoord,
      group,
      temperatureMeshes,
      electricMesh,
      temperatureHotMicroLines,
      temperatureColdMicroLines,
      electricMicroLines,
      temperatureMicroCells: 0,
      electricMicroCells: 0,
      temperatureMicroGroups: 0,
      electricMicroGroups: 0,
      temperatureStats: { ...EMPTY_TEMPERATURE_STATS },
    };
  }

  private _updateOverlay(
    overlay: FieldRegionOverlay,
    snapshot: FFieldRegionSnapshot,
    projector?: FieldOverlayProjector,
  ): void {
    if (overlay.temperatureMeshes.length > 0 && snapshot.fieldMask & FieldMask.Temperature) {
      overlay.temperatureStats = summarizeTemperatureField(snapshot);
      this._syncTemperatureMeshes(overlay, snapshot, projector);
    }
    if (overlay.electricMesh && snapshot.fieldMask & FieldMask.ElectricPotential) {
      this._syncElectricMesh(overlay, snapshot, projector);
    }
  }

  private _syncTemperatureMeshes(
    overlay: FieldRegionOverlay,
    snapshot: FFieldRegionSnapshot,
    projector?: FieldOverlayProjector,
  ): void {
    const buckets = overlay.temperatureMeshes;
    const { macroIndices, temperatureValues, cellCount } = snapshot;
    const previousCounts = new Map<InstancedMesh, number>();
    for (const bucket of buckets) {
      previousCounts.set(bucket.mesh, bucket.mesh.count);
      bucket.mesh.count = 0;
    }
    overlay.temperatureMicroCells = 0;
    overlay.temperatureMicroGroups = 0;

    // Build (cell index, temperature) pairs, then keep only cells that stand
    // away from the local background. Sorting 4096 entries is cheap at the
    // field tick cadence and avoids baking in assumptions about dense vs sparse
    // server snapshots.
    const samples: number[] = [];
    const pairs: { srcIdx: number; temp: number }[] = [];
    for (let i = 0; i < cellCount; i++) {
      const v = temperatureValues[i];
      if (v !== undefined && Number.isFinite(v)) {
        pairs.push({ srcIdx: i, temp: v });
        samples.push(v);
      }
    }
    const backgroundTemp = estimateBackgroundTemperature(samples, cellCount);
    const visiblePairs = pairs
      .map(({ srcIdx, temp }) => ({
        srcIdx,
        temp,
        deviation: temp - backgroundTemp,
      }))
      .filter(({ deviation }) => Math.abs(deviation) >= TEMP_MIN_DELTA_FROM_BACKGROUND);
    visiblePairs.sort((a, b) => Math.abs(b.deviation) - Math.abs(a.deviation));
    const topN = visiblePairs.slice(0, Math.min(TEMP_TOP_N, visiblePairs.length));

    if (topN.length === 0) {
      for (const bucket of buckets) {
        clearUnusedInstances(bucket.mesh, 0, previousCounts.get(bucket.mesh) ?? 0);
        bucket.mesh.instanceMatrix.needsUpdate = true;
      }
      syncMicroLineSegments(overlay.temperatureHotMicroLines, []);
      syncMicroLineSegments(overlay.temperatureColdMicroLines, []);
      return;
    }

    const hotMicroCells = new Map<string, PrefabRasterCell[]>();
    const coldMicroCells = new Map<string, PrefabRasterCell[]>();
    for (const { srcIdx, deviation } of topN) {
      const idx = macroIndices[srcIdx]!;
      const { x, y, z } = macroIndexToCoord(idx);
      const worldMacro = worldMacroFromSnapshot(snapshot, { x, y, z });
      const projection = projector?.(worldMacro);
      if (projection && projection.granularity !== "macro") {
        const target = deviation >= 0 ? hotMicroCells : coldMicroCells;
        target.set(projection.key, localizeRasterCellsForSnapshot(snapshot, projection.cells));
        continue;
      }
      const bucket = temperatureBucketForDeviation(buckets, deviation);
      const mesh = bucket.mesh;
      const count = mesh.count;

      this.tmpDummy.position.set(
        (x + 0.5) * CELL_SIZE,
        (y + 0.5) * CELL_SIZE,
        (z + 0.5) * CELL_SIZE,
      );
      this.tmpDummy.updateMatrix();
      mesh.setMatrixAt(count, this.tmpDummy.matrix);
      mesh.count = count + 1;
    }

    for (const bucket of buckets) {
      clearUnusedInstances(
        bucket.mesh,
        bucket.mesh.count,
        previousCounts.get(bucket.mesh) ?? bucket.mesh.count,
      );
      bucket.mesh.instanceMatrix.needsUpdate = true;
    }
    const hotGeometry = syncMicroLineSegments(
      overlay.temperatureHotMicroLines,
      [...hotMicroCells.values()].flat(),
    );
    const coldGeometry = syncMicroLineSegments(
      overlay.temperatureColdMicroLines,
      [...coldMicroCells.values()].flat(),
    );
    overlay.temperatureMicroCells = hotGeometry.occupiedSlotCount + coldGeometry.occupiedSlotCount;
    overlay.temperatureMicroGroups = hotMicroCells.size + coldMicroCells.size;
  }

  private _syncElectricMesh(
    overlay: FieldRegionOverlay,
    snapshot: FFieldRegionSnapshot,
    projector?: FieldOverlayProjector,
  ): void {
    const mesh = overlay.electricMesh;
    if (!mesh) {
      return;
    }
    const { macroIndices, electricValues, cellCount } = snapshot;
    const previousCount = mesh.count;
    let count = 0;
    const microCells = new Map<string, PrefabRasterCell[]>();

    for (let i = 0; i < cellCount; i++) {
      const potential = electricValues[i];
      if (potential === undefined || Math.abs(potential) < 0.5) continue;

      const idx = macroIndices[i]!;
      const { x, y, z } = macroIndexToCoord(idx);
      const worldMacro = worldMacroFromSnapshot(snapshot, { x, y, z });
      const projection = projector?.(worldMacro);
      if (projection && projection.granularity !== "macro") {
        microCells.set(projection.key, localizeRasterCellsForSnapshot(snapshot, projection.cells));
        continue;
      }

      this.tmpDummy.position.set(
        (x + 0.5) * CELL_SIZE,
        (y + 0.5) * CELL_SIZE,
        (z + 0.5) * CELL_SIZE,
      );
      this.tmpDummy.updateMatrix();
      mesh.setMatrixAt(count, this.tmpDummy.matrix);

      const t = Math.max(0, Math.min(1, Math.abs(potential) / 100.0));
      this.tmpColor.copy(LOW_ELEC_COLOR).lerp(HIGH_ELEC_COLOR, t);
      mesh.setColorAt(count, this.tmpColor);
      count++;
    }

    clearUnusedInstances(mesh, count, previousCount);
    mesh.count = count;
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    const geometry = syncMicroLineSegments(
      overlay.electricMicroLines,
      [...microCells.values()].flat(),
    );
    overlay.electricMicroCells = geometry.occupiedSlotCount;
    overlay.electricMicroGroups = microCells.size;
  }

  private _bindHotkey(): void {
    if (typeof window === "undefined") return;
    window.addEventListener("keydown", (e: KeyboardEvent) => {
      if (e.ctrlKey && e.code === "Backslash") {
        e.preventDefault();
        this.toggle();
        console.info(`[FieldDebugOverlay] ${this.visible ? "shown" : "hidden"} (Ctrl+\\)`);
      }
    });
  }
}

function macroIndexToCoord(idx: number): { x: number; y: number; z: number } {
  const x = idx & 0xf;
  const y = (idx >> 4) & 0xf;
  const z = (idx >> 8) & 0xf;
  return { x, y, z };
}

function normalizeRegionId(regionId: number | string): number | null {
  const value = typeof regionId === "number" ? regionId : Number.parseInt(regionId, 10);
  return Number.isFinite(value) ? value : null;
}

function makeMicroLineSegments(name: string, color: number): LineSegments {
  const material = new LineBasicMaterial({
    color,
    transparent: true,
    opacity: 0.82,
    depthTest: false,
    depthWrite: false,
  });
  const lines = new LineSegments(new BufferGeometry(), material);
  lines.name = name;
  lines.visible = false;
  lines.frustumCulled = false;
  lines.renderOrder = 7;
  return lines;
}

function syncMicroLineSegments(
  lines: LineSegments | null,
  cells: readonly PrefabRasterCell[],
): { occupiedSlotCount: number; wireSegmentCount: number } {
  const geometry =
    cells.length > 0
      ? buildPrefabRasterSurfaceOutlineGeometry(cells)
      : { positions: [], occupiedSlotCount: 0, wireSegmentCount: 0 };
  if (!lines) {
    return geometry;
  }

  lines.geometry.dispose();
  const next = new BufferGeometry();
  next.setAttribute("position", new Float32BufferAttribute(geometry.positions, 3));
  lines.geometry = next;
  lines.visible = geometry.wireSegmentCount > 0;
  return geometry;
}

function localizeRasterCellsForSnapshot(
  snapshot: FFieldRegionSnapshot,
  cells: readonly PrefabRasterCell[],
): PrefabRasterCell[] {
  const origin = chunkWorldMacroOrigin(snapshot);
  return cells.map((cell) => ({
    ...cell,
    macro: {
      x: cell.macro.x - origin.x,
      y: cell.macro.y - origin.y,
      z: cell.macro.z - origin.z,
    },
    microMaterialIds: [...cell.microMaterialIds],
    microStateFlags: [...cell.microStateFlags],
    microPartIds: [...cell.microPartIds],
  }));
}

function worldMacroFromSnapshot(
  snapshot: FFieldRegionSnapshot,
  localMacro: FMacroCoord,
): FMacroCoord {
  const origin = chunkWorldMacroOrigin(snapshot);
  return {
    x: origin.x + localMacro.x,
    y: origin.y + localMacro.y,
    z: origin.z + localMacro.z,
  };
}

function chunkWorldMacroOrigin(snapshot: FFieldRegionSnapshot): FMacroCoord {
  return {
    x: snapshot.chunkCoord.cx * VoxelConstants.ChunkSizeX,
    y: snapshot.chunkCoord.cy * VoxelConstants.ChunkSizeY,
    z: snapshot.chunkCoord.cz * VoxelConstants.ChunkSizeZ,
  };
}

function electricEffectPointsForProjection(
  projection: VoxelOverlayProjection,
  potential: number,
): ElectricEffectPoint[] {
  if (projection.granularity === "macro") {
    return [];
  }

  const microSize = MacroWorldSize / VoxelConstants.MicroPerMacro;
  const points: ElectricEffectPoint[] = [];
  for (const cell of projection.cells) {
    for (const [index, micro] of MICRO_SLOT_COORDS.entries()) {
      if ((cell.microOccupancyMask & (1n << BigInt(index))) === 0n) {
        continue;
      }
      points.push({
        x: cell.macro.x * MacroWorldSize + (micro.x + 0.5) * microSize,
        y: cell.macro.y * MacroWorldSize + (micro.y + 0.5) * microSize,
        z: cell.macro.z * MacroWorldSize + (micro.z + 0.5) * microSize,
        potential,
        sizeWorld: microSize * 0.7,
      });
    }
  }
  return points;
}

function estimateBackgroundTemperature(samples: number[], cellCount: number): number {
  if (samples.length === 0) return TEMP_ENV_BASELINE;
  if (cellCount < MAX_CELLS / 2) return TEMP_ENV_BASELINE;
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted[Math.floor((sorted.length - 1) / 2)] ?? TEMP_ENV_BASELINE;
}

function summarizeTemperatureField(snapshot: FFieldRegionSnapshot): TemperatureFieldStats {
  if (snapshot.cellCount <= 0) {
    return { ...EMPTY_TEMPERATURE_STATS };
  }

  let maxTemperatureCelsius: number | null = null;
  let maxAbsTemperatureDeltaCelsius = 0;
  let absTemperatureDeltaSum = 0;
  let sampleCount = 0;

  for (let i = 0; i < snapshot.cellCount; i++) {
    const value = snapshot.temperatureValues[i];
    if (value === undefined || !Number.isFinite(value)) {
      continue;
    }

    maxTemperatureCelsius =
      maxTemperatureCelsius === null ? value : Math.max(maxTemperatureCelsius, value);
    const absDelta = Math.abs(value - TEMP_ENV_BASELINE);
    maxAbsTemperatureDeltaCelsius = Math.max(maxAbsTemperatureDeltaCelsius, absDelta);
    absTemperatureDeltaSum += absDelta;
    sampleCount += 1;
  }

  return {
    maxTemperatureCelsius,
    maxAbsTemperatureDeltaCelsius,
    averageAbsTemperatureDeltaCelsius: sampleCount > 0 ? absTemperatureDeltaSum / sampleCount : 0,
  };
}

function makeTemperatureMaterial(kind: "hot" | "cold", opacity: number): MeshBasicMaterial {
  return new MeshBasicMaterial({
    color: kind === "hot" ? TEMP_HOT_COLOR : TEMP_COLD_COLOR,
    transparent: true,
    opacity,
    depthTest: false,
    depthWrite: false,
  });
}

function temperatureOpacity(deviation: number): number {
  const linear = Math.max(0, Math.min(1, Math.abs(deviation) / TEMP_FULL_OPACITY_DELTA));
  const t = Math.pow(linear, TEMP_VISUAL_GAMMA);
  return t * TEMP_MAX_OPACITY;
}

function temperatureBucketForDeviation(
  buckets: TemperatureMeshBucket[],
  deviation: number,
): TemperatureMeshBucket {
  const kind = deviation >= 0 ? "hot" : "cold";
  const targetOpacity = temperatureOpacity(deviation);
  let best: TemperatureMeshBucket | null = null;
  for (const bucket of buckets) {
    if (bucket.kind !== kind) continue;
    if (
      !best ||
      Math.abs(bucket.opacity - targetOpacity) < Math.abs(best.opacity - targetOpacity)
    ) {
      best = bucket;
    }
  }
  if (!best) {
    throw new Error(`missing temperature opacity bucket: ${kind}`);
  }
  return best;
}

function temperatureCellCount(overlay: FieldRegionOverlay): number {
  return (
    overlay.temperatureMeshes.reduce((sum, bucket) => sum + bucket.mesh.count, 0) +
    overlay.temperatureMicroCells
  );
}

function electricCellCount(overlay: FieldRegionOverlay): number {
  return (overlay.electricMesh?.count ?? 0) + overlay.electricMicroCells;
}

function initializeHiddenInstances(mesh: InstancedMesh): void {
  clearUnusedInstances(mesh, 0, MAX_CELLS);
  mesh.instanceMatrix.needsUpdate = true;
}

function clearUnusedInstances(
  mesh: InstancedMesh,
  fromInclusive: number,
  toExclusive: number,
): void {
  const start = Math.max(0, fromInclusive);
  const end = Math.min(MAX_CELLS, Math.max(start, toExclusive));
  for (let i = start; i < end; i++) {
    mesh.setMatrixAt(i, HIDDEN_INSTANCE_MATRIX);
  }
}

function _disposeOverlay(overlay: FieldRegionOverlay): void {
  for (const bucket of overlay.temperatureMeshes) {
    bucket.mesh.geometry.dispose();
    if (Array.isArray(bucket.mesh.material)) {
      bucket.mesh.material.forEach((m) => m.dispose());
    } else {
      (bucket.mesh.material as { dispose?: () => void })?.dispose?.();
    }
  }
  overlay.electricMesh?.geometry.dispose();
  if (Array.isArray(overlay.electricMesh?.material)) {
    overlay.electricMesh?.material.forEach((m) => m.dispose());
  } else {
    (overlay.electricMesh?.material as { dispose?: () => void })?.dispose?.();
  }
  disposeLineSegments(overlay.temperatureHotMicroLines);
  disposeLineSegments(overlay.temperatureColdMicroLines);
  disposeLineSegments(overlay.electricMicroLines);
}

function disposeLineSegments(lines: LineSegments | null): void {
  if (!lines) {
    return;
  }
  lines.geometry.dispose();
  if (Array.isArray(lines.material)) {
    lines.material.forEach((m) => m.dispose());
  } else {
    lines.material.dispose();
  }
}
