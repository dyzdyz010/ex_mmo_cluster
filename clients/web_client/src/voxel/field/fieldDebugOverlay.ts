// Phase 6: FieldDebugOverlay — Three.js debug overlay for FieldRegion field values.
//
// Hidden by default; toggled with Ctrl+\ (or the "Field" button in the voxel panel). Shows:
//   - Temperature field: ambient transparent / hot red / cold purple InstancedMesh cubes
//   - Electric potential: black (low) → yellow (high) InstancedMesh cubes
//   - Region AABB: LineSegments box wireframe
//
// §5.5 constraint: hidden by default, dev hotkey only, no production player UX.

import {
  BoxGeometry,
  Color,
  EdgesGeometry,
  Group,
  InstancedBufferAttribute,
  InstancedMesh,
  LineBasicMaterial,
  LineSegments,
  Matrix4,
  MeshBasicMaterial,
  Object3D,
} from "three";
import { MacroWorldSize } from "../core/constants";
import type { FFieldRegionSnapshot } from "./fieldProtocol";
import { FieldMask } from "./fieldProtocol";

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

export interface FieldRegionOverlay {
  regionId: number;
  chunkCoord: { cx: number; cy: number; cz: number };
  group: Group;
  temperatureMeshes: TemperatureMeshBucket[];
  electricMesh: InstancedMesh | null;
  aabbWireframe: LineSegments | null;
}

export interface FieldDebugOverlaySnapshot {
  visible: boolean;
  regionCount: number;
  regions: Array<{
    regionId: number;
    chunkCoord: { cx: number; cy: number; cz: number };
    temperatureCells: number;
    electricCells: number;
  }>;
}

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

  constructor() {
    this.rootGroup = new Group();
    this.rootGroup.visible = false;
    this.rootGroup.name = "FieldDebugOverlay";
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
    this._updateOverlay(overlay, snapshot);
    const tempCount = temperatureCellCount(overlay);
    const elecCount = overlay.electricMesh?.count ?? 0;
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

  snapshot(): FieldDebugOverlaySnapshot {
    return {
      visible: this.visible,
      regionCount: this.regions.size,
      regions: Array.from(this.regions.values()).map((overlay) => ({
        regionId: overlay.regionId,
        chunkCoord: overlay.chunkCoord,
        temperatureCells: temperatureCellCount(overlay),
        electricCells: overlay.electricMesh?.count ?? 0,
      })),
    };
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
    }

    if (snapshot.fieldMask & FieldMask.ElectricPotential) {
      const mat = new MeshBasicMaterial({
        transparent: true,
        opacity: 0.18,
        vertexColors: true,
        depthTest: false,
        depthWrite: false,
      });
      electricMesh = new InstancedMesh(makeCellGeometry(), mat, MAX_CELLS);
      electricMesh.count = 0;
      electricMesh.frustumCulled = false;
      electricMesh.renderOrder = 5;
      electricMesh.instanceColor = new InstancedBufferAttribute(new Float32Array(MAX_CELLS * 3), 3);
      initializeHiddenInstances(electricMesh);
      group.add(electricMesh);
    }

    // AABB wireframe: covers the full 16x16x16 macro-cell extent of the chunk
    const aabbWireframe = _makeAabbWireframe(0, 0, 0, 16, 16, 16);
    group.add(aabbWireframe);

    return {
      regionId: snapshot.regionId,
      chunkCoord: snapshot.chunkCoord,
      group,
      temperatureMeshes,
      electricMesh,
      aabbWireframe,
    };
  }

  private _updateOverlay(overlay: FieldRegionOverlay, snapshot: FFieldRegionSnapshot): void {
    if (overlay.temperatureMeshes.length > 0 && snapshot.fieldMask & FieldMask.Temperature) {
      this._syncTemperatureMeshes(overlay.temperatureMeshes, snapshot);
    }
    if (overlay.electricMesh && snapshot.fieldMask & FieldMask.ElectricPotential) {
      this._syncElectricMesh(overlay.electricMesh, snapshot);
    }
  }

  private _syncTemperatureMeshes(
    buckets: TemperatureMeshBucket[],
    snapshot: FFieldRegionSnapshot,
  ): void {
    const { macroIndices, temperatureValues, cellCount } = snapshot;
    const previousCounts = new Map<InstancedMesh, number>();
    for (const bucket of buckets) {
      previousCounts.set(bucket.mesh, bucket.mesh.count);
      bucket.mesh.count = 0;
    }

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
      return;
    }

    for (const { srcIdx, deviation } of topN) {
      const idx = macroIndices[srcIdx]!;
      const { x, y, z } = macroIndexToCoord(idx);
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
  }

  private _syncElectricMesh(mesh: InstancedMesh, snapshot: FFieldRegionSnapshot): void {
    const { macroIndices, electricValues, cellCount } = snapshot;
    const previousCount = mesh.count;
    let count = 0;

    for (let i = 0; i < cellCount; i++) {
      const potential = electricValues[i];
      if (potential === undefined || Math.abs(potential) < 0.5) continue;

      const idx = macroIndices[i]!;
      const { x, y, z } = macroIndexToCoord(idx);

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

function estimateBackgroundTemperature(samples: number[], cellCount: number): number {
  if (samples.length === 0) return TEMP_ENV_BASELINE;
  if (cellCount < MAX_CELLS / 2) return TEMP_ENV_BASELINE;
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted[Math.floor((sorted.length - 1) / 2)] ?? TEMP_ENV_BASELINE;
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
  return overlay.temperatureMeshes.reduce((sum, bucket) => sum + bucket.mesh.count, 0);
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

function _makeAabbWireframe(
  minX: number,
  minY: number,
  minZ: number,
  maxX: number,
  maxY: number,
  maxZ: number,
): LineSegments {
  const boxGeo = new BoxGeometry(
    (maxX - minX) * CELL_SIZE,
    (maxY - minY) * CELL_SIZE,
    (maxZ - minZ) * CELL_SIZE,
  );
  const edges = new EdgesGeometry(boxGeo);
  boxGeo.dispose();
  const mat = new LineBasicMaterial({ color: 0x00ff88, depthTest: false });
  const wire = new LineSegments(edges, mat);
  wire.renderOrder = 5;
  wire.position.set(
    ((minX + maxX) / 2) * CELL_SIZE,
    ((minY + maxY) / 2) * CELL_SIZE,
    ((minZ + maxZ) / 2) * CELL_SIZE,
  );
  return wire;
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
  overlay.aabbWireframe?.geometry.dispose();
  (overlay.aabbWireframe?.material as { dispose?: () => void })?.dispose?.();
}
