// Phase 6: FieldDebugOverlay — Three.js debug overlay for FieldRegion field values.
//
// Hidden by default; toggled with Ctrl+\ (or the "Field" button in the voxel panel). Shows:
//   - Temperature field: blue (cold) → red (hot) InstancedMesh cubes
//   - Electric potential: black (low) → yellow (high) InstancedMesh cubes
//   - Region AABB: LineSegments box wireframe
//
// §5.5 constraint: hidden by default, dev hotkey only, no production player UX.

import {
  BoxGeometry,
  BufferGeometry,
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
const HOT_COLOR = new Color(1, 0.1, 0.05); // red
const COLD_COLOR = new Color(0.05, 0.1, 1.0); // blue
const HIGH_ELEC_COLOR = new Color(1, 1, 0); // yellow
const LOW_ELEC_COLOR = new Color(0, 0, 0); // black
const ENV_TEMP = 20.0;

export interface FieldRegionOverlay {
  regionId: number;
  chunkCoord: { cx: number; cy: number; cz: number };
  group: Group;
  temperatureMesh: InstancedMesh | null;
  electricMesh: InstancedMesh | null;
  aabbWireframe: LineSegments | null;
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
    let overlay = this.regions.get(snapshot.regionId);
    if (!overlay) {
      overlay = this._createOverlay(snapshot);
      this.regions.set(snapshot.regionId, overlay);
      this.rootGroup.add(overlay.group);
    }
    this._updateOverlay(overlay, snapshot);
  }

  /** Called when FieldRegionDestroyed (0x74) arrives. */
  onRegionDestroyed(regionId: number): void {
    const overlay = this.regions.get(regionId);
    if (overlay) {
      this.rootGroup.remove(overlay.group);
      _disposeOverlay(overlay);
      this.regions.delete(regionId);
    }
  }

  /** Clear all regions (e.g., on chunk invalidate). */
  clear(): void {
    for (const overlay of this.regions.values()) {
      this.rootGroup.remove(overlay.group);
      _disposeOverlay(overlay);
    }
    this.regions.clear();
  }

  toggle(): void {
    this.visible = !this.visible;
    this.rootGroup.visible = this.visible;
  }

  isVisible(): boolean {
    return this.visible;
  }

  private _createOverlay(snapshot: FFieldRegionSnapshot): FieldRegionOverlay {
    const group = new Group();
    group.name = `field-region-${snapshot.regionId}`;

    const { cx, cy, cz } = snapshot.chunkCoord;
    // Position the group at chunk origin in world space
    group.position.set(cx * 16 * CELL_SIZE, cy * 16 * CELL_SIZE, cz * 16 * CELL_SIZE);

    const geo = new BoxGeometry(CELL_SIZE * 0.85, CELL_SIZE * 0.85, CELL_SIZE * 0.85);
    let temperatureMesh: InstancedMesh | null = null;
    let electricMesh: InstancedMesh | null = null;

    if (snapshot.fieldMask & FieldMask.Temperature) {
      // depthTest:false + depthWrite:false so field cells are visible through terrain
      const mat = new MeshBasicMaterial({ transparent: true, opacity: 0.45, vertexColors: true, depthTest: false, depthWrite: false });
      temperatureMesh = new InstancedMesh(geo, mat, MAX_CELLS);
      temperatureMesh.count = 0;
      temperatureMesh.frustumCulled = false;
      temperatureMesh.renderOrder = 5;
      temperatureMesh.instanceColor = new InstancedBufferAttribute(new Float32Array(MAX_CELLS * 3), 3);
      group.add(temperatureMesh);
    }

    if (snapshot.fieldMask & FieldMask.ElectricPotential) {
      const mat = new MeshBasicMaterial({ transparent: true, opacity: 0.5, vertexColors: true, depthTest: false, depthWrite: false });
      electricMesh = new InstancedMesh(geo, mat, MAX_CELLS);
      electricMesh.count = 0;
      electricMesh.frustumCulled = false;
      electricMesh.renderOrder = 5;
      electricMesh.instanceColor = new InstancedBufferAttribute(new Float32Array(MAX_CELLS * 3), 3);
      group.add(electricMesh);
    }

    // AABB wireframe: covers the full 16x16x16 macro-cell extent of the chunk
    const aabbWireframe = _makeAabbWireframe(0, 0, 0, 16, 16, 16);
    group.add(aabbWireframe);

    return {
      regionId: snapshot.regionId,
      chunkCoord: snapshot.chunkCoord,
      group,
      temperatureMesh,
      electricMesh,
      aabbWireframe,
    };
  }

  private _updateOverlay(overlay: FieldRegionOverlay, snapshot: FFieldRegionSnapshot): void {
    if (overlay.temperatureMesh && (snapshot.fieldMask & FieldMask.Temperature)) {
      this._syncTemperatureMesh(overlay.temperatureMesh, snapshot);
    }
    if (overlay.electricMesh && (snapshot.fieldMask & FieldMask.ElectricPotential)) {
      this._syncElectricMesh(overlay.electricMesh, snapshot);
    }
  }

  private _syncTemperatureMesh(mesh: InstancedMesh, snapshot: FFieldRegionSnapshot): void {
    const { macroIndices, temperatureValues, cellCount } = snapshot;
    let count = 0;

    for (let i = 0; i < cellCount; i++) {
      const temp = temperatureValues[i];
      if (temp === undefined || Math.abs(temp - ENV_TEMP) < 0.5) continue;

      const idx = macroIndices[i]!;
      const { x, y, z } = macroIndexToCoord(idx);

      this.tmpDummy.position.set(
        (x + 0.5) * CELL_SIZE,
        (y + 0.5) * CELL_SIZE,
        (z + 0.5) * CELL_SIZE,
      );
      this.tmpDummy.updateMatrix();
      mesh.setMatrixAt(count, this.tmpDummy.matrix);

      const t = Math.max(0, Math.min(1, (temp - ENV_TEMP) / 80.0));
      this.tmpColor.copy(COLD_COLOR).lerp(HOT_COLOR, t);
      mesh.setColorAt(count, this.tmpColor);
      count++;
    }

    mesh.count = count;
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
  }

  private _syncElectricMesh(mesh: InstancedMesh, snapshot: FFieldRegionSnapshot): void {
    const { macroIndices, electricValues, cellCount } = snapshot;
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

function _makeAabbWireframe(
  minX: number, minY: number, minZ: number,
  maxX: number, maxY: number, maxZ: number,
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
  overlay.temperatureMesh?.geometry.dispose();
  if (Array.isArray(overlay.temperatureMesh?.material)) {
    overlay.temperatureMesh?.material.forEach((m) => m.dispose());
  } else {
    (overlay.temperatureMesh?.material as { dispose?: () => void })?.dispose?.();
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
