import {
  BufferGeometry,
  Float32BufferAttribute,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MeshStandardMaterial,
  Raycaster,
  Vector2,
  Vector3,
} from "three";
import type { PerspectiveCamera } from "three";
import { buildChunkMeshData } from "../voxel/meshing/chunkMesher";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import {
  macroCenterWorldPosition,
  macroCoordFromWorldPosition,
  macroStepFromSurfaceNormal,
} from "../voxel/core/gridUtils";
import type { FMacroCoord, FMicroCoord } from "../voxel/core/types";
import { chunkCoordKey } from "../voxel/core/types";
import { VoxelDirtyFlags } from "../voxel/storage/types";
import type { WorldStore } from "../voxel/worldStore";
import type { ObserveLog } from "../observe/logger";
import type { PrefabRasterCell } from "../voxel/prefab";

const HIT_FACE_OUTLINE_OFFSET = MacroWorldSize * 0.006;
const HIT_FACE_OUTLINE_SIZE = MacroWorldSize * 1.04;
const LOCAL_FACE_NORMAL = new Vector3(0, 0, 1);
const PREFAB_PREVIEW_INSET = MacroWorldSize * 0.03;

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
  kind: "none" | "hit-face";
  position: { x: number; y: number; z: number };
  faceNormal: FMacroCoord | null;
}

export interface PrefabPreviewInput {
  name: string;
  cells: readonly { offset: FMacroCoord }[];
}

export interface PrefabPreviewSnapshot {
  visible: boolean;
  prefabName: string | null;
  origin: FMacroCoord | null;
  cellCount: number;
  renderObjectCount: number;
  renderStyle: "none" | "wire-bounds" | "micro-wire";
  wireSegmentCount: number;
}

export interface PrefabRasterMicroWireGeometry {
  positions: number[];
  occupiedSlotCount: number;
  wireSegmentCount: number;
}

export class ChunkRenderController {
  private readonly group = new Group();
  private readonly chunkMaterial = new MeshStandardMaterial({
    vertexColors: true,
    roughness: 0.82,
    metalness: 0.05,
  });
  private readonly chunkMeshes = new Map<string, Mesh<BufferGeometry, MeshStandardMaterial>>();
  private readonly raycaster = new Raycaster();
  private readonly ndcCenter = new Vector2(0, 0);
  private readonly targetHighlight: LineSegments;
  private targetHighlightFaceNormal: FMacroCoord | null = null;
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

  constructor() {
    this.group.name = "voxel-chunks";

    this.targetHighlight = new LineSegments(
      makeHitFaceOutlineGeometry(),
      new LineBasicMaterial({ color: 0xfff4a8 }),
    );
    this.targetHighlight.visible = false;
    this.targetHighlight.name = "voxel-hit-face-outline";

    this.group.add(this.targetHighlight);
    this.prefabPreviewGroup.name = "voxel-prefab-preview";
    this.prefabPreviewGroup.visible = false;
    this.group.add(this.prefabPreviewGroup);
  }

  attachToScene(parent: Group): void {
    parent.add(this.group);
  }

  syncDirtyChunks(world: WorldStore, logger: ObserveLog): void {
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
    }

    for (const chunk of world.listChunks()) {
      const key = chunkCoordKey(chunk.data.chunkCoord);
      const existing = this.chunkMeshes.get(key);
      const needsRebuild =
        !existing ||
        (chunk.data.dirtyFlags & (VoxelDirtyFlags.Mesh | VoxelDirtyFlags.Collision)) !== 0;
      if (!needsRebuild) {
        continue;
      }

      const snapshot = chunk.buildMesherSnapshot();
      const meshData = buildChunkMeshData(snapshot, {
        isSolidWorldMacroCoord(coord: FMacroCoord): boolean {
          return world.isSolidWorldMacroCoord(coord);
        },
        isSolidWorldMicroCoord(macro: FMacroCoord, micro: FMicroCoord): boolean {
          return world.isSolidWorldMicroCoord(macro, micro);
        },
      });

      const geometry = new BufferGeometry();
      geometry.setAttribute("position", new Float32BufferAttribute(meshData.positions, 3));
      geometry.setAttribute("normal", new Float32BufferAttribute(meshData.normals, 3));
      geometry.setAttribute("color", new Float32BufferAttribute(meshData.colors, 3));
      geometry.setIndex(meshData.indices);
      geometry.computeBoundingBox();
      geometry.computeBoundingSphere();

      const mesh =
        existing ??
        new Mesh<BufferGeometry, MeshStandardMaterial>(new BufferGeometry(), this.chunkMaterial);
      mesh.name = `chunk:${key}`;
      mesh.position.set(
        chunk.data.chunkCoord.x * VoxelConstants.ChunkSizeX * MacroWorldSize,
        chunk.data.chunkCoord.y * VoxelConstants.ChunkSizeY * MacroWorldSize,
        chunk.data.chunkCoord.z * VoxelConstants.ChunkSizeZ * MacroWorldSize,
      );
      mesh.frustumCulled = false;
      mesh.visible = meshData.indices.length > 0;
      mesh.userData["chunkCoord"] = chunk.data.chunkCoord;

      if (!existing) {
        this.chunkMeshes.set(key, mesh);
        this.group.add(mesh);
      }

      mesh.geometry.dispose();
      mesh.geometry = geometry;
      chunk.consumeDirtyFlags();

      logger.emit("render", "chunk_rebuilt", {
        chunk: key,
        solid_blocks: meshData.solidBlockCount,
        triangles: meshData.triangleCount,
      });
    }
  }

  raycastFromCameraCenter(camera: PerspectiveCamera): VoxelRaySelection | null {
    const objects = [...this.chunkMeshes.values()];
    if (objects.length === 0) {
      return null;
    }

    this.raycaster.setFromCamera(this.ndcCenter, camera);
    const hit = this.raycaster.intersectObjects(objects, false)[0];
    if (!hit?.face) {
      return null;
    }

    const worldNormal = hit.face.normal.clone().transformDirection(hit.object.matrixWorld);
    const faceNormal = macroStepFromSurfaceNormal(worldNormal);
    const occupiedMacro = macroCoordFromWorldPosition(
      hit.point.clone().add(worldNormal.clone().multiplyScalar(-0.1)),
      MacroWorldSize,
    );
    const occupiedMicro = microTargetFromWorldPoint(
      hit.point.clone().add(worldNormal.clone().multiplyScalar(-0.1)),
    );
    const adjacentMacro = {
      x: occupiedMacro.x + faceNormal.x,
      y: occupiedMacro.y + faceNormal.y,
      z: occupiedMacro.z + faceNormal.z,
    };
    const adjacentMicro = stepMicroTarget(occupiedMicro, faceNormal);
    return { occupiedMacro, adjacentMacro, faceNormal, occupiedMicro, adjacentMicro };
  }

  setTargetHighlights(selection: VoxelRaySelection | null): void {
    if (!selection) {
      this.targetHighlight.visible = false;
      this.targetHighlightFaceNormal = null;
      return;
    }

    const pose = hitFaceOutlinePose(selection);
    this.targetHighlight.position.set(pose.position.x, pose.position.y, pose.position.z);
    this.targetHighlight.quaternion.setFromUnitVectors(LOCAL_FACE_NORMAL, pose.normalVector);
    this.targetHighlight.visible = true;
    this.targetHighlightFaceNormal = { ...selection.faceNormal };
  }

  getTargetHighlightSnapshot(): TargetHighlightSnapshot {
    return {
      visible: this.targetHighlight.visible,
      kind: this.targetHighlight.visible ? "hit-face" : "none",
      position: {
        x: this.targetHighlight.position.x,
        y: this.targetHighlight.position.y,
        z: this.targetHighlight.position.z,
      },
      faceNormal: this.targetHighlightFaceNormal ? { ...this.targetHighlightFaceNormal } : null,
    };
  }

  setPrefabPreview(selection: VoxelRaySelection | null, prefab: PrefabPreviewInput | null): void {
    if (!selection || !prefab || prefab.cells.length === 0) {
      this.clearPrefabPreview();
      return;
    }

    const origin = selection.adjacentMacro;
    const key = `${prefab.name}:${origin.x},${origin.y},${origin.z}:${prefab.cells
      .map((cell) => `${cell.offset.x},${cell.offset.y},${cell.offset.z}`)
      .join("|")}`;
    if (key === this.prefabPreviewKey) {
      return;
    }

    const positions: number[] = [];
    for (const cell of prefab.cells) {
      const coord = {
        x: origin.x + cell.offset.x,
        y: origin.y + cell.offset.y,
        z: origin.z + cell.offset.z,
      };
      appendMacroCellWireBox(positions, coord);
    }

    this.setPrefabWirePreview(key, positions, {
      visible: true,
      prefabName: prefab.name,
      origin: { ...origin },
      cellCount: prefab.cells.length,
      renderStyle: "wire-bounds",
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
    this.clearPrefabPreview();
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
}

interface MicroGridCorner {
  x: number;
  y: number;
  z: number;
}

export function buildPrefabRasterMicroWireGeometry(
  cells: readonly PrefabRasterCell[],
): PrefabRasterMicroWireGeometry {
  const edges = new Map<string, [MicroGridCorner, MicroGridCorner]>();
  let occupiedSlotCount = 0;

  for (const cell of cells) {
    for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
      for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
        for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
          const index =
            x +
            y * VoxelConstants.MicroPerMacro +
            z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro;
          if ((cell.microOccupancyMask & (1n << BigInt(index))) === 0n) {
            continue;
          }
          occupiedSlotCount += 1;
          appendMicroSlotWireEdges(edges, cell.macro, { x, y, z });
        }
      }
    }
  }

  const positions: number[] = [];
  for (const [from, to] of edges.values()) {
    appendMicroGridEdgeWorldPositions(positions, from, to);
  }

  return {
    positions,
    occupiedSlotCount,
    wireSegmentCount: edges.size,
  };
}

function appendMicroSlotWireEdges(
  edges: Map<string, [MicroGridCorner, MicroGridCorner]>,
  macro: FMacroCoord,
  micro: FMicroCoord,
): void {
  const base = {
    x: macro.x * VoxelConstants.MicroPerMacro + micro.x,
    y: macro.y * VoxelConstants.MicroPerMacro + micro.y,
    z: macro.z * VoxelConstants.MicroPerMacro + micro.z,
  };
  const corners: MicroGridCorner[] = [
    { x: base.x, y: base.y, z: base.z },
    { x: base.x + 1, y: base.y, z: base.z },
    { x: base.x + 1, y: base.y + 1, z: base.z },
    { x: base.x, y: base.y + 1, z: base.z },
    { x: base.x, y: base.y, z: base.z + 1 },
    { x: base.x + 1, y: base.y, z: base.z + 1 },
    { x: base.x + 1, y: base.y + 1, z: base.z + 1 },
    { x: base.x, y: base.y + 1, z: base.z + 1 },
  ];
  const edgeIndices: Array<[number, number]> = [
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

  for (const [fromIndex, toIndex] of edgeIndices) {
    addCanonicalMicroGridEdge(edges, corners[fromIndex]!, corners[toIndex]!);
  }
}

function addCanonicalMicroGridEdge(
  edges: Map<string, [MicroGridCorner, MicroGridCorner]>,
  a: MicroGridCorner,
  b: MicroGridCorner,
): void {
  const [from, to] = compareMicroGridCorners(a, b) <= 0 ? [a, b] : [b, a];
  edges.set(`${microGridCornerKey(from)}|${microGridCornerKey(to)}`, [from, to]);
}

function compareMicroGridCorners(a: MicroGridCorner, b: MicroGridCorner): number {
  if (a.x !== b.x) {
    return a.x - b.x;
  }
  if (a.y !== b.y) {
    return a.y - b.y;
  }
  return a.z - b.z;
}

function microGridCornerKey(corner: MicroGridCorner): string {
  return `${corner.x},${corner.y},${corner.z}`;
}

function appendMicroGridEdgeWorldPositions(
  positions: number[],
  from: MicroGridCorner,
  to: MicroGridCorner,
): void {
  positions.push(
    microGridCornerWorldAxis(from.x),
    microGridCornerWorldAxis(from.y),
    microGridCornerWorldAxis(from.z),
    microGridCornerWorldAxis(to.x),
    microGridCornerWorldAxis(to.y),
    microGridCornerWorldAxis(to.z),
  );
}

function microGridCornerWorldAxis(value: number): number {
  return (value / VoxelConstants.MicroPerMacro) * MacroWorldSize;
}

function appendMacroCellWireBox(positions: number[], coord: FMacroCoord): void {
  appendWireBox(
    positions,
    {
      x: coord.x * MacroWorldSize + PREFAB_PREVIEW_INSET,
      y: coord.y * MacroWorldSize + PREFAB_PREVIEW_INSET,
      z: coord.z * MacroWorldSize + PREFAB_PREVIEW_INSET,
    },
    {
      x: (coord.x + 1) * MacroWorldSize - PREFAB_PREVIEW_INSET,
      y: (coord.y + 1) * MacroWorldSize - PREFAB_PREVIEW_INSET,
      z: (coord.z + 1) * MacroWorldSize - PREFAB_PREVIEW_INSET,
    },
  );
}

function appendWireBox(
  positions: number[],
  min: { x: number; y: number; z: number },
  max: { x: number; y: number; z: number },
): void {
  const corners: Array<[number, number, number]> = [
    [min.x, min.y, min.z],
    [max.x, min.y, min.z],
    [max.x, max.y, min.z],
    [min.x, max.y, min.z],
    [min.x, min.y, max.z],
    [max.x, min.y, max.z],
    [max.x, max.y, max.z],
    [min.x, max.y, max.z],
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
  for (const [a, b] of edges) {
    positions.push(...corners[a]!, ...corners[b]!);
  }
}

function makeHitFaceOutlineGeometry(): BufferGeometry {
  const half = HIT_FACE_OUTLINE_SIZE / 2;
  const positions = [
    -half,
    -half,
    0,
    half,
    -half,
    0,
    half,
    -half,
    0,
    half,
    half,
    0,
    half,
    half,
    0,
    -half,
    half,
    0,
    -half,
    half,
    0,
    -half,
    -half,
    0,
  ];
  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new Float32BufferAttribute(positions, 3));
  return geometry;
}

function hitFaceOutlinePose(selection: VoxelRaySelection): {
  position: { x: number; y: number; z: number };
  normalVector: Vector3;
} {
  const blockCenter = macroCenterWorldPosition(selection.occupiedMacro, MacroWorldSize);
  const normalVector = new Vector3(
    selection.faceNormal.x,
    selection.faceNormal.y,
    selection.faceNormal.z,
  );
  if (normalVector.lengthSq() === 0) {
    normalVector.copy(LOCAL_FACE_NORMAL);
  } else {
    normalVector.normalize();
  }

  const faceDistance = MacroWorldSize / 2 + HIT_FACE_OUTLINE_OFFSET;
  return {
    position: {
      x: blockCenter.x + normalVector.x * faceDistance,
      y: blockCenter.y + normalVector.y * faceDistance,
      z: blockCenter.z + normalVector.z * faceDistance,
    },
    normalVector,
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
