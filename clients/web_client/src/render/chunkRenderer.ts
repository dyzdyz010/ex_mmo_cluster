import {
  BufferGeometry,
  Float32BufferAttribute,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  Raycaster,
  Vector2,
} from "three";
import type { PerspectiveCamera, Vector3 } from "three";
import type { Intersection, MeshStandardMaterial } from "three";
import { buildChunkMeshData, type ChunkMeshBuildData } from "../voxel/meshing/chunkMesher";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import {
  macroCenterWorldPosition,
  macroCoordFromWorldPosition,
  macroStepFromSurfaceNormal,
} from "../voxel/core/gridUtils";
import type { FChunkCoord, FMacroCoord, FMicroCoord } from "../voxel/core/types";
import { FullMicroOccupancyMask } from "../voxel/microgrid/governance";
import { chunkCoordKey } from "../voxel/core/types";
import { VoxelDirtyFlags } from "../voxel/storage/types";
import type { WorldStore } from "../voxel/worldStore";
import { resolveSelectionOverlayProjection } from "../voxel/overlayTarget";
import type { VoxelOverlayProjection } from "../voxel/overlayTarget";
import type { ObserveLog } from "../observe/logger";
import type { PrefabRasterCell } from "../voxel/prefab";
import type { FChunkMesherInputSnapshot } from "../voxel/meshing/types";
import {
  buildPrefabRasterMicroWireGeometry,
  buildPrefabRasterSurfaceOutlineGeometry,
} from "./prefabPreviewGeometry";
import { createVoxelChunkMaterial } from "./voxelChunkMaterial";
import { createVoxelMaterialMosaicTexture } from "./voxelMaterialTexture";
export {
  buildPrefabRasterMicroWireGeometry,
  buildPrefabRasterSurfaceOutlineGeometry,
} from "./prefabPreviewGeometry";
export type { PrefabRasterMicroWireGeometry } from "./prefabPreviewGeometry";

const HIT_FACE_OUTLINE_OFFSET = MacroWorldSize * 0.006;
const MACRO_HIT_OUTLINE_SIZE = MacroWorldSize * 1.04;
const MACRO_HIT_COLOR = 0xfff4a8;
const PREFAB_HIT_COLOR = 0x67e8f9;
const RAYCAST_SURFACE_NUDGE = MacroWorldSize * 0.001;
const RAYCAST_SEAM_DISTANCE_EPSILON = MacroWorldSize * 0.002;

interface ChunkMeshWorkerSuccess {
  id: number;
  key: string;
  ok: true;
  meshData: ChunkMeshBuildData;
  durationMs: number;
}

interface ChunkMeshWorkerFailure {
  id: number;
  key: string;
  ok: false;
  reason: string;
  durationMs: number;
}

type ChunkMeshWorkerResponse = ChunkMeshWorkerSuccess | ChunkMeshWorkerFailure;

interface PendingChunkMeshBuild {
  id: number;
  key: string;
  startedAtMs: number;
}

interface RaycastSelectionCandidate {
  distance: number;
  key: string;
  selection: VoxelRaySelection;
}

export interface VoxelRaySelection {
  occupiedMacro: FMacroCoord;
  adjacentMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  occupiedMicro?: MicroCellTarget;
  adjacentMicro?: MicroCellTarget;
}

export interface MicroCellTarget {
  macro: FMacroCoord;
  micro: FMicroCoord;
}

export interface TargetHighlightSnapshot {
  visible: boolean;
  kind: "none" | "macro-cell" | "prefab";
  position: { x: number; y: number; z: number };
  faceNormal: FMacroCoord | null;
  occupiedMacro: FMacroCoord | null;
  occupiedMicro: MicroCellTarget | null;
}

type VisibleTargetHighlightKind = Exclude<TargetHighlightSnapshot["kind"], "none">;

export interface PrefabPreviewInput {
  name: string;
  cells: readonly { offset: FMacroCoord; occupancyWord?: bigint }[];
}

export interface PrefabPreviewSnapshot {
  visible: boolean;
  prefabName: string | null;
  origin: FMacroCoord | null;
  cellCount: number;
  renderObjectCount: number;
  renderStyle: "none" | "micro-wire";
  wireSegmentCount: number;
}

export class ChunkRenderController {
  private readonly group = new Group();
  private readonly meshWorker = createChunkMeshWorker();
  private readonly chunkMaterial = createVoxelChunkMaterial();
  private readonly chunkMeshes = new Map<string, Mesh<BufferGeometry, MeshStandardMaterial>>();
  private readonly chunkTexture = createVoxelMaterialMosaicTexture();
  private readonly raycaster = new Raycaster();
  private readonly ndcCenter = new Vector2(0, 0);
  private readonly targetHighlight: LineSegments;
  private targetHighlightKind: TargetHighlightSnapshot["kind"] = "none";
  private targetHighlightGeometryKey = "";
  private targetHighlightFaceNormal: FMacroCoord | null = null;
  private targetHighlightOccupiedMacro: FMacroCoord | null = null;
  private targetHighlightOccupiedMicro: MicroCellTarget | null = null;
  private readonly prefabPreviewGroup = new Group();
  private readonly prefabPreviewLineMaterial = new LineBasicMaterial({
    color: 0x67e8f9,
  });
  private prefabPreviewSnapshot: PrefabPreviewSnapshot = {
    visible: false,
    prefabName: null,
    origin: null,
    cellCount: 0,
    renderObjectCount: 0,
    renderStyle: "none",
    wireSegmentCount: 0,
  };
  private prefabPreviewKey = "";
  private meshBuildSeq = 1;
  private readonly pendingMeshBuilds = new Map<string, PendingChunkMeshBuild>();
  private readonly completedMeshBuilds: ChunkMeshWorkerResponse[] = [];
  private readonly emptyChunkMeshKeys = new Set<string>();
  private lastRaySelection: VoxelRaySelection | null = null;

  constructor() {
    this.chunkMaterial.map = this.chunkTexture;
    this.group.name = "voxel-chunks";

    this.targetHighlight = new LineSegments(
      makeBoxOutlineGeometry(MACRO_HIT_OUTLINE_SIZE),
      new LineBasicMaterial({ color: MACRO_HIT_COLOR }),
    );
    this.targetHighlight.visible = false;
    this.targetHighlight.name = "voxel-target-outline";

    this.group.add(this.targetHighlight);
    this.prefabPreviewGroup.name = "voxel-prefab-preview";
    this.prefabPreviewGroup.visible = false;
    this.group.add(this.prefabPreviewGroup);

    if (this.meshWorker) {
      this.meshWorker.onmessage = (event: MessageEvent<ChunkMeshWorkerResponse>) => {
        this.completedMeshBuilds.push(event.data);
      };
    }
  }

  attachToScene(parent: Group): void {
    parent.add(this.group);
  }

  syncDirtyChunks(world: WorldStore, logger: ObserveLog): void {
    this.applyCompletedMeshBuilds(logger);

    const activeKeys = new Set(
      world.listChunks().map((chunk) => chunkCoordKey(chunk.data.chunkCoord)),
    );
    for (const [key, mesh] of this.chunkMeshes) {
      if (activeKeys.has(key)) {
        continue;
      }
      this.group.remove(mesh);
      mesh.geometry.dispose();
      this.chunkMeshes.delete(key);
      this.pendingMeshBuilds.delete(key);
      this.emptyChunkMeshKeys.delete(key);
    }
    for (const key of [...this.emptyChunkMeshKeys]) {
      if (!activeKeys.has(key)) {
        this.emptyChunkMeshKeys.delete(key);
      }
    }

    for (const chunk of world.listChunks()) {
      const key = chunkCoordKey(chunk.data.chunkCoord);
      const existing = this.chunkMeshes.get(key);
      const meshDirty =
        (chunk.data.dirtyFlags & (VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision)) !== 0;
      if (!existing && this.emptyChunkMeshKeys.has(key) && !meshDirty) {
        continue;
      }

      const needsRebuild =
        !existing || meshDirty;
      if (!needsRebuild) {
        continue;
      }
      if (this.pendingMeshBuilds.has(key)) {
        continue;
      }
      if (!chunk.hasRenderableCells()) {
        if (existing) {
          this.removeChunkMesh(key, existing);
        }
        this.pendingMeshBuilds.delete(key);
        this.emptyChunkMeshKeys.add(key);
        chunk.consumeDirtyFlags(VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision);
        continue;
      }
      this.emptyChunkMeshKeys.delete(key);

      const snapshot = chunk.buildMesherSnapshot();
      if (this.meshWorker) {
        const id = this.meshBuildSeq;
        this.meshBuildSeq += 1;
        const startedAtMs = Math.round(performance.now());
        this.pendingMeshBuilds.set(key, { id, key, startedAtMs });

        // The dirty span represented by this snapshot is now in flight. Any
        // edit that lands while the worker is running will mark the chunk
        // dirty again and schedule a follow-up build.
        chunk.consumeDirtyFlags(VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision);

        this.meshWorker.postMessage({
          id,
          key,
          snapshot,
          solidWorldMacroKeys: collectBoundarySolidMacroKeys(world, snapshot),
        });

        logger.emit("render", "chunk_rebuild_scheduled", {
          chunk: key,
          worker: true,
          dirty_min: formatCoord(snapshot.dirtyMacroMin),
          dirty_max: formatCoord(snapshot.dirtyMacroMax),
        });
        continue;
      }

      const meshData = buildChunkMeshData(snapshot, {
        isSolidWorldMacroCoord(coord: FMacroCoord): boolean {
          return world.isSolidWorldMacroCoord(coord);
        },
        isSolidWorldMicroCoord(macro: FMacroCoord, micro: FMicroCoord): boolean {
          return world.isSolidWorldMicroCoord(macro, micro);
        },
      });
      this.applyMeshData(key, chunk.data.chunkCoord, meshData, existing);
      chunk.consumeDirtyFlags();

      logger.emit("render", "chunk_rebuilt", {
        chunk: key,
        worker: false,
        solid_blocks: meshData.solidBlockCount,
        triangles: meshData.triangleCount,
      });
    }
  }

  private applyCompletedMeshBuilds(logger: ObserveLog): void {
    if (this.completedMeshBuilds.length === 0) {
      return;
    }

    const completed = this.completedMeshBuilds.splice(0, this.completedMeshBuilds.length);
    for (const message of completed) {
      const pending = this.pendingMeshBuilds.get(message.key);
      if (!pending || pending.id !== message.id) {
        continue;
      }
      this.pendingMeshBuilds.delete(message.key);

      if (!message.ok) {
        logger.emit("render", "chunk_rebuild_failed", {
          chunk: message.key,
          worker: true,
          duration_ms: message.durationMs,
          reason: message.reason,
        });
        continue;
      }

      const chunkCoord = parseChunkKey(message.key);
      this.applyMeshData(message.key, chunkCoord, message.meshData);

      logger.emit("render", "chunk_rebuilt", {
        chunk: message.key,
        worker: true,
        worker_duration_ms: message.durationMs,
        elapsed_ms: Math.round(performance.now()) - pending.startedAtMs,
        solid_blocks: message.meshData.solidBlockCount,
        triangles: message.meshData.triangleCount,
      });
    }
  }

  private applyMeshData(
    key: string,
    chunkCoord: FChunkCoord,
    meshData: ChunkMeshBuildData,
    existing: Mesh<BufferGeometry, MeshStandardMaterial> | undefined = this.chunkMeshes.get(key),
  ): void {
    const geometry = new BufferGeometry();
    geometry.setAttribute("position", new Float32BufferAttribute(meshData.positions, 3));
    geometry.setAttribute("normal", new Float32BufferAttribute(meshData.normals, 3));
    geometry.setAttribute("color", new Float32BufferAttribute(meshData.colors, 3));
    geometry.setAttribute("uv", new Float32BufferAttribute(meshData.uvs, 2));
    geometry.setIndex(meshData.indices);
    geometry.computeBoundingBox();
    geometry.computeBoundingSphere();

    const mesh =
      existing ??
      new Mesh<BufferGeometry, MeshStandardMaterial>(new BufferGeometry(), this.chunkMaterial);
    mesh.name = `chunk:${key}`;
    mesh.position.set(
      chunkCoord.x * VoxelConstants.ChunkSizeX * MacroWorldSize,
      chunkCoord.y * VoxelConstants.ChunkSizeY * MacroWorldSize,
      chunkCoord.z * VoxelConstants.ChunkSizeZ * MacroWorldSize,
    );
    mesh.frustumCulled = false;
    mesh.visible = meshData.indices.length > 0;
    mesh.userData["chunkCoord"] = chunkCoord;

    if (!existing) {
      this.chunkMeshes.set(key, mesh);
      this.group.add(mesh);
    }

    mesh.geometry.dispose();
    mesh.geometry = geometry;
  }

  private removeChunkMesh(
    key: string,
    mesh: Mesh<BufferGeometry, MeshStandardMaterial> = this.chunkMeshes.get(key)!,
  ): void {
    this.group.remove(mesh);
    mesh.geometry.dispose();
    this.chunkMeshes.delete(key);
  }

  raycastFromCameraCenter(camera: PerspectiveCamera): VoxelRaySelection | null {
    const objects = [...this.chunkMeshes.values()];
    if (objects.length === 0) {
      this.lastRaySelection = null;
      return null;
    }

    this.raycaster.setFromCamera(this.ndcCenter, camera);
    const selection = selectStableRaySelection(
      this.raycaster.intersectObjects(objects, false),
      this.lastRaySelection,
    );
    this.lastRaySelection = selection;
    return selection;
  }

  setTargetHighlights(selection: VoxelRaySelection | null, world?: WorldStore): void {
    if (!selection) {
      this.targetHighlight.visible = false;
      this.targetHighlightKind = "none";
      this.targetHighlightFaceNormal = null;
      this.targetHighlightOccupiedMacro = null;
      this.targetHighlightOccupiedMicro = null;
      return;
    }

    const projection =
      world && selection.occupiedMicro
        ? resolveSelectionOverlayProjection(world, selection.occupiedMicro, selection.occupiedMacro)
        : null;
    const prefabProjection =
      projection?.granularity === "prefab" && projection.cells.length > 0 ? projection : null;
    const selectedMicro =
      projection?.selectedMicro && selection.occupiedMicro
        ? {
            macro: projection.macro,
            micro: projection.selectedMicro,
          }
        : null;
    const kind: VisibleTargetHighlightKind = prefabProjection ? "prefab" : "macro-cell";
    this.syncTargetHighlightGeometry(kind, prefabProjection ?? undefined);
    if (prefabProjection) {
      this.targetHighlight.position.set(0, 0, 0);
    } else {
      const pose = macroCellOutlinePose(selection);
      this.targetHighlight.position.set(pose.position.x, pose.position.y, pose.position.z);
    }
    this.targetHighlight.quaternion.identity();
    this.targetHighlight.visible = true;
    this.targetHighlightKind = kind;
    this.targetHighlightFaceNormal = { ...selection.faceNormal };
    this.targetHighlightOccupiedMacro = { ...selection.occupiedMacro };
    this.targetHighlightOccupiedMicro = selectedMicro
      ? {
          macro: { ...selectedMicro.macro },
          micro: { ...selectedMicro.micro },
        }
      : null;
  }

  getTargetHighlightSnapshot(): TargetHighlightSnapshot {
    return {
      visible: this.targetHighlight.visible,
      kind: this.targetHighlight.visible ? this.targetHighlightKind : "none",
      position: {
        x: this.targetHighlight.position.x,
        y: this.targetHighlight.position.y,
        z: this.targetHighlight.position.z,
      },
      faceNormal: this.targetHighlightFaceNormal ? { ...this.targetHighlightFaceNormal } : null,
      occupiedMacro: this.targetHighlightOccupiedMacro
        ? { ...this.targetHighlightOccupiedMacro }
        : null,
      occupiedMicro: this.targetHighlightOccupiedMicro
        ? {
            macro: { ...this.targetHighlightOccupiedMicro.macro },
            micro: { ...this.targetHighlightOccupiedMicro.micro },
          }
        : null,
    };
  }

  setPrefabPreview(selection: VoxelRaySelection | null, prefab: PrefabPreviewInput | null): void {
    if (!selection || !prefab || prefab.cells.length === 0) {
      this.clearPrefabPreview();
      return;
    }

    const origin = selection.adjacentMacro;
    const key = `${prefab.name}:${origin.x},${origin.y},${origin.z}:${prefab.cells
      .map(
        (cell) =>
          `${cell.offset.x},${cell.offset.y},${cell.offset.z}:${
            cell.occupancyWord ?? FullMicroOccupancyMask
          }`,
      )
      .join("|")}`;
    if (key === this.prefabPreviewKey) {
      return;
    }

    const rasterCells = prefabPreviewInputToRasterCells(origin, prefab);
    const geometry = buildPrefabRasterMicroWireGeometry(rasterCells);
    if (geometry.occupiedSlotCount === 0 || geometry.wireSegmentCount === 0) {
      this.clearPrefabPreview();
      return;
    }

    this.setPrefabWirePreview(key, geometry.positions, {
      visible: true,
      prefabName: prefab.name,
      origin: { ...origin },
      cellCount: geometry.occupiedSlotCount,
      renderStyle: "micro-wire",
    });
  }

  setPrefabRasterPreview(prefabName: string, cells: readonly PrefabRasterCell[]): void {
    if (cells.length === 0) {
      this.clearPrefabPreview();
      return;
    }

    const key = `${prefabName}:${cells
      .map((cell) => `${cell.macro.x},${cell.macro.y},${cell.macro.z}:${cell.microOccupancyMask}`)
      .join("|")}`;
    if (key === this.prefabPreviewKey) {
      return;
    }

    const geometry = buildPrefabRasterMicroWireGeometry(cells);
    if (geometry.occupiedSlotCount === 0 || geometry.wireSegmentCount === 0) {
      this.clearPrefabPreview();
      return;
    }

    this.setPrefabWirePreview(key, geometry.positions, {
      visible: true,
      prefabName,
      origin: cells[0] ? { ...cells[0].macro } : null,
      cellCount: geometry.occupiedSlotCount,
      renderStyle: "micro-wire",
    });
  }

  getPrefabPreviewSnapshot(): PrefabPreviewSnapshot {
    return {
      visible: this.prefabPreviewSnapshot.visible,
      prefabName: this.prefabPreviewSnapshot.prefabName,
      origin: this.prefabPreviewSnapshot.origin ? { ...this.prefabPreviewSnapshot.origin } : null,
      cellCount: this.prefabPreviewSnapshot.cellCount,
      renderObjectCount: this.prefabPreviewSnapshot.renderObjectCount,
      renderStyle: this.prefabPreviewSnapshot.renderStyle,
      wireSegmentCount: this.prefabPreviewSnapshot.wireSegmentCount,
    };
  }

  dispose(): void {
    for (const mesh of this.chunkMeshes.values()) {
      mesh.geometry.dispose();
    }
    this.meshWorker?.terminate();
    this.clearPrefabPreview();
    this.chunkTexture.dispose();
    this.chunkMaterial.dispose();
    this.targetHighlight.geometry.dispose();
    (this.targetHighlight.material as LineBasicMaterial).dispose();
    this.prefabPreviewLineMaterial.dispose();
  }

  private clearPrefabPreview(): void {
    for (const child of [...this.prefabPreviewGroup.children]) {
      this.prefabPreviewGroup.remove(child);
      const geometry = (child as { geometry?: { dispose(): void } }).geometry;
      geometry?.dispose();
    }
    this.prefabPreviewGroup.visible = false;
    this.prefabPreviewKey = "";
    this.prefabPreviewSnapshot = {
      visible: false,
      prefabName: null,
      origin: null,
      cellCount: 0,
      renderObjectCount: 0,
      renderStyle: "none",
      wireSegmentCount: 0,
    };
  }

  private setPrefabWirePreview(
    key: string,
    positions: number[],
    snapshot: Omit<PrefabPreviewSnapshot, "renderObjectCount" | "wireSegmentCount">,
  ): void {
    this.clearPrefabPreview();
    const geometry = new BufferGeometry();
    geometry.setAttribute("position", new Float32BufferAttribute(positions, 3));
    const lines = new LineSegments(geometry, this.prefabPreviewLineMaterial);
    lines.name = `prefab-wire-preview:${snapshot.prefabName ?? "unknown"}`;
    lines.frustumCulled = false;
    this.prefabPreviewGroup.add(lines);
    this.prefabPreviewGroup.visible = true;
    this.prefabPreviewKey = key;
    this.prefabPreviewSnapshot = {
      ...snapshot,
      renderObjectCount: this.prefabPreviewGroup.children.length,
      wireSegmentCount: positions.length / 6,
    };
  }

  private syncTargetHighlightGeometry(
    kind: VisibleTargetHighlightKind,
    projection?: VoxelOverlayProjection,
  ): void {
    const geometryKey = targetHighlightGeometryKey(kind, projection);
    if (geometryKey === this.targetHighlightGeometryKey) {
      return;
    }

    this.targetHighlight.geometry.dispose();
    this.targetHighlight.geometry =
      kind === "prefab" && projection
        ? makePrefabTargetOutlineGeometry(projection.cells)
        : makeBoxOutlineGeometry(MACRO_HIT_OUTLINE_SIZE);
    const material = this.targetHighlight.material as LineBasicMaterial;
    material.color.setHex(kind === "prefab" ? PREFAB_HIT_COLOR : MACRO_HIT_COLOR);
    this.targetHighlightGeometryKey = geometryKey;
  }
}

function createChunkMeshWorker(): Worker | null {
  if (typeof Worker === "undefined") {
    return null;
  }

  try {
    return new Worker(new URL("./chunkMeshWorker.ts", import.meta.url), { type: "module" });
  } catch {
    return null;
  }
}

function collectBoundarySolidMacroKeys(
  world: WorldStore,
  snapshot: FChunkMesherInputSnapshot,
): string[] {
  const keys: string[] = [];
  const base = {
    x: snapshot.chunkCoord.x * VoxelConstants.ChunkSizeX,
    y: snapshot.chunkCoord.y * VoxelConstants.ChunkSizeY,
    z: snapshot.chunkCoord.z * VoxelConstants.ChunkSizeZ,
  };
  const max = VoxelConstants.ChunkSizeX - 1;

  for (let y = 0; y < VoxelConstants.ChunkSizeY; y += 1) {
    for (let z = 0; z < VoxelConstants.ChunkSizeZ; z += 1) {
      pushSolidMacroKey(world, keys, { x: base.x - 1, y: base.y + y, z: base.z + z });
      pushSolidMacroKey(world, keys, { x: base.x + max + 1, y: base.y + y, z: base.z + z });
    }
  }

  for (let x = 0; x < VoxelConstants.ChunkSizeX; x += 1) {
    for (let z = 0; z < VoxelConstants.ChunkSizeZ; z += 1) {
      pushSolidMacroKey(world, keys, { x: base.x + x, y: base.y - 1, z: base.z + z });
      pushSolidMacroKey(world, keys, { x: base.x + x, y: base.y + max + 1, z: base.z + z });
    }
  }

  for (let x = 0; x < VoxelConstants.ChunkSizeX; x += 1) {
    for (let y = 0; y < VoxelConstants.ChunkSizeY; y += 1) {
      pushSolidMacroKey(world, keys, { x: base.x + x, y: base.y + y, z: base.z - 1 });
      pushSolidMacroKey(world, keys, { x: base.x + x, y: base.y + y, z: base.z + max + 1 });
    }
  }

  return keys;
}

function pushSolidMacroKey(world: WorldStore, keys: string[], coord: FMacroCoord): void {
  if (world.isSolidWorldMacroCoord(coord)) {
    keys.push(formatCoord(coord));
  }
}

function parseChunkKey(key: string): FChunkCoord {
  const [x = "0", y = "0", z = "0"] = key.split(",");
  return {
    x: Number.parseInt(x, 10) || 0,
    y: Number.parseInt(y, 10) || 0,
    z: Number.parseInt(z, 10) || 0,
  };
}

function formatCoord(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function selectStableRaySelection(
  hits: readonly Intersection<Mesh<BufferGeometry, MeshStandardMaterial>>[],
  previous: VoxelRaySelection | null,
): VoxelRaySelection | null {
  const candidates = hits
    .map(raycastCandidateFromHit)
    .filter((candidate): candidate is RaycastSelectionCandidate => candidate !== null)
    .sort(compareRaycastCandidates);
  const nearest = candidates[0];
  if (!nearest) {
    return null;
  }

  const seamCandidates = candidates.filter(
    (candidate) => candidate.distance - nearest.distance <= RAYCAST_SEAM_DISTANCE_EPSILON,
  );
  if (previous) {
    const previousKey = raySelectionKey(previous);
    const retained = seamCandidates.find((candidate) => candidate.key === previousKey);
    if (retained) {
      return retained.selection;
    }
  }

  return seamCandidates[0]?.selection ?? nearest.selection;
}

function raycastCandidateFromHit(
  hit: Intersection<Mesh<BufferGeometry, MeshStandardMaterial>>,
): RaycastSelectionCandidate | null {
  if (!hit.face) {
    return null;
  }

  const worldNormal = hit.face.normal.clone().transformDirection(hit.object.matrixWorld);
  const faceNormal = macroStepFromSurfaceNormal(worldNormal);
  if (coordKey(faceNormal) === "0,0,0") {
    return null;
  }

  const occupiedPoint = hit.point
    .clone()
    .add(worldNormal.clone().multiplyScalar(-RAYCAST_SURFACE_NUDGE));
  const occupiedMacro = macroCoordFromWorldPosition(occupiedPoint, MacroWorldSize);
  const occupiedMicro = microTargetFromWorldPoint(occupiedPoint);
  const adjacentMacro = {
    x: occupiedMacro.x + faceNormal.x,
    y: occupiedMacro.y + faceNormal.y,
    z: occupiedMacro.z + faceNormal.z,
  };
  const adjacentMicro = stepMicroTarget(occupiedMicro, faceNormal);
  const selection = { occupiedMacro, adjacentMacro, faceNormal, occupiedMicro, adjacentMicro };
  return {
    distance: hit.distance,
    key: raySelectionKey(selection),
    selection,
  };
}

function compareRaycastCandidates(
  a: RaycastSelectionCandidate,
  b: RaycastSelectionCandidate,
): number {
  const distanceDelta = a.distance - b.distance;
  if (Math.abs(distanceDelta) > RAYCAST_SEAM_DISTANCE_EPSILON) {
    return distanceDelta;
  }
  return a.key.localeCompare(b.key);
}

function raySelectionKey(selection: VoxelRaySelection): string {
  return [
    coordKey(selection.occupiedMacro),
    coordKey(selection.adjacentMacro),
    coordKey(selection.faceNormal),
    selection.occupiedMicro ? coordKey(selection.occupiedMicro.macro) : "",
    selection.occupiedMicro ? coordKey(selection.occupiedMicro.micro) : "",
    selection.adjacentMicro ? coordKey(selection.adjacentMicro.macro) : "",
    selection.adjacentMicro ? coordKey(selection.adjacentMicro.micro) : "",
  ].join("|");
}

function coordKey(coord: { x: number; y: number; z: number }): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function makeBoxOutlineGeometry(size: number): BufferGeometry {
  const half = size / 2;
  const corners: Array<[number, number, number]> = [
    [-half, -half, -half],
    [half, -half, -half],
    [half, half, -half],
    [-half, half, -half],
    [-half, -half, half],
    [half, -half, half],
    [half, half, half],
    [-half, half, half],
  ];
  const edges: Array<[number, number]> = [
    [0, 1],
    [1, 2],
    [2, 3],
    [3, 0],
    [4, 5],
    [5, 6],
    [6, 7],
    [7, 4],
    [0, 4],
    [1, 5],
    [2, 6],
    [3, 7],
  ];
  const positions = edges.flatMap(([fromIndex, toIndex]) => [
    ...corners[fromIndex]!,
    ...corners[toIndex]!,
  ]);
  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new Float32BufferAttribute(positions, 3));
  return geometry;
}

function makePrefabTargetOutlineGeometry(cells: readonly PrefabRasterCell[]): BufferGeometry {
  const wire = buildPrefabRasterSurfaceOutlineGeometry(cells);
  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new Float32BufferAttribute(wire.positions, 3));
  return geometry;
}

function targetHighlightGeometryKey(
  kind: VisibleTargetHighlightKind,
  projection?: VoxelOverlayProjection,
): string {
  if (kind !== "prefab" || !projection) {
    return kind;
  }
  return [
    kind,
    projection.key,
    projection.cells
      .map(
        (cell) =>
          `${coordKey(cell.macro)}:${cell.microOccupancyMask.toString(16)}:${cell.microMaterialIds.join(
            ",",
          )}:${cell.microStateFlags.join(",")}`,
      )
      .join("|"),
  ].join(":");
}

function macroCellOutlinePose(selection: VoxelRaySelection): {
  position: { x: number; y: number; z: number };
} {
  const blockCenter = macroCenterWorldPosition(selection.occupiedMacro, MacroWorldSize);
  return {
    position: {
      x: blockCenter.x + selection.faceNormal.x * HIT_FACE_OUTLINE_OFFSET,
      y: blockCenter.y + selection.faceNormal.y * HIT_FACE_OUTLINE_OFFSET,
      z: blockCenter.z + selection.faceNormal.z * HIT_FACE_OUTLINE_OFFSET,
    },
  };
}

function microTargetFromWorldPoint(point: Vector3): MicroCellTarget {
  const macro = macroCoordFromWorldPosition(point, MacroWorldSize);
  return {
    macro,
    micro: {
      x: microAxisFromWorld(point.x, macro.x),
      y: microAxisFromWorld(point.y, macro.y),
      z: microAxisFromWorld(point.z, macro.z),
    },
  };
}

function microAxisFromWorld(value: number, macroAxis: number): number {
  const local = value - macroAxis * MacroWorldSize;
  const microSize = MacroWorldSize / VoxelConstants.MicroPerMacro;
  return Math.max(
    0,
    Math.min(VoxelConstants.MicroPerMacro - 1, Math.floor(clampLocal(local) / microSize)),
  );
}

function clampLocal(value: number): number {
  return Math.max(0, Math.min(MacroWorldSize - Number.EPSILON, value));
}

function stepMicroTarget(target: MicroCellTarget, normal: FMacroCoord): MicroCellTarget {
  const macro = { ...target.macro };
  const micro = {
    x: target.micro.x + normal.x,
    y: target.micro.y + normal.y,
    z: target.micro.z + normal.z,
  };

  if (micro.x < 0) {
    macro.x -= 1;
    micro.x = VoxelConstants.MicroPerMacro - 1;
  } else if (micro.x >= VoxelConstants.MicroPerMacro) {
    macro.x += 1;
    micro.x = 0;
  }

  if (micro.y < 0) {
    macro.y -= 1;
    micro.y = VoxelConstants.MicroPerMacro - 1;
  } else if (micro.y >= VoxelConstants.MicroPerMacro) {
    macro.y += 1;
    micro.y = 0;
  }

  if (micro.z < 0) {
    macro.z -= 1;
    micro.z = VoxelConstants.MicroPerMacro - 1;
  } else if (micro.z >= VoxelConstants.MicroPerMacro) {
    macro.z += 1;
    micro.z = 0;
  }

  return { macro, micro };
}

function prefabPreviewInputToRasterCells(
  origin: FMacroCoord,
  prefab: PrefabPreviewInput,
): PrefabRasterCell[] {
  return prefab.cells
    .map((cell) => ({
      macro: {
        x: origin.x + cell.offset.x,
        y: origin.y + cell.offset.y,
        z: origin.z + cell.offset.z,
      },
      microOccupancyMask: cell.occupancyWord ?? FullMicroOccupancyMask,
      microMaterialIds: [],
      microStateFlags: [],
      microPartIds: [],
    }))
    .filter((cell) => cell.microOccupancyMask !== 0n);
}
