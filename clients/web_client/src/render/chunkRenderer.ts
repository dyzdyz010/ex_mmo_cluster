import {
  BoxGeometry,
  BufferGeometry,
  Float32BufferAttribute,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  Raycaster,
  Vector2,
  Vector3,
} from "three";
import type { PerspectiveCamera } from "three";
import { buildChunkMeshData } from "../voxel/meshing/chunkMesher";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import { macroCenterWorldPosition, macroCoordFromWorldPosition, macroStepFromSurfaceNormal } from "../voxel/core/gridUtils";
import type { FMacroCoord } from "../voxel/core/types";
import { chunkCoordKey } from "../voxel/core/types";
import { VoxelDirtyFlags } from "../voxel/storage/types";
import type { WorldStore } from "../voxel/worldStore";
import type { ObserveLog } from "../observe/logger";

const HIT_FACE_OUTLINE_OFFSET = MacroWorldSize * 0.006;
const HIT_FACE_OUTLINE_SIZE = MacroWorldSize * 1.04;
const LOCAL_FACE_NORMAL = new Vector3(0, 0, 1);
const PREFAB_GHOST_OPACITY = 0.28;

export interface VoxelRaySelection {
  occupiedMacro: FMacroCoord;
  adjacentMacro: FMacroCoord;
  faceNormal: FMacroCoord;
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
  private readonly prefabPreviewGeometry = new BoxGeometry(
    MacroWorldSize * 0.96,
    MacroWorldSize * 0.96,
    MacroWorldSize * 0.96,
  );
  private readonly prefabPreviewMaterial = new MeshBasicMaterial({
    color: 0x67e8f9,
    transparent: true,
    opacity: PREFAB_GHOST_OPACITY,
    depthWrite: false,
  });
  private prefabPreviewSnapshot: PrefabPreviewSnapshot = {
    visible: false,
    prefabName: null,
    origin: null,
    cellCount: 0,
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
    const activeKeys = new Set(world.listChunks().map((chunk) => chunkCoordKey(chunk.data.chunkCoord)));
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
    const adjacentMacro = {
      x: occupiedMacro.x + faceNormal.x,
      y: occupiedMacro.y + faceNormal.y,
      z: occupiedMacro.z + faceNormal.z,
    };
    return { occupiedMacro, adjacentMacro, faceNormal };
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

    this.clearPrefabPreview();
    for (const cell of prefab.cells) {
      const coord = {
        x: origin.x + cell.offset.x,
        y: origin.y + cell.offset.y,
        z: origin.z + cell.offset.z,
      };
      const center = macroCenterWorldPosition(coord, MacroWorldSize);
      const mesh = new Mesh(this.prefabPreviewGeometry, this.prefabPreviewMaterial);
      mesh.position.set(center.x, center.y, center.z);
      this.prefabPreviewGroup.add(mesh);
    }

    this.prefabPreviewGroup.visible = true;
    this.prefabPreviewKey = key;
    this.prefabPreviewSnapshot = {
      visible: true,
      prefabName: prefab.name,
      origin: { ...origin },
      cellCount: prefab.cells.length,
    };
  }

  getPrefabPreviewSnapshot(): PrefabPreviewSnapshot {
    return {
      visible: this.prefabPreviewSnapshot.visible,
      prefabName: this.prefabPreviewSnapshot.prefabName,
      origin: this.prefabPreviewSnapshot.origin ? { ...this.prefabPreviewSnapshot.origin } : null,
      cellCount: this.prefabPreviewSnapshot.cellCount,
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
    this.prefabPreviewGeometry.dispose();
    this.prefabPreviewMaterial.dispose();
  }

  private clearPrefabPreview(): void {
    for (const child of [...this.prefabPreviewGroup.children]) {
      this.prefabPreviewGroup.remove(child);
    }
    this.prefabPreviewGroup.visible = false;
    this.prefabPreviewKey = "";
    this.prefabPreviewSnapshot = {
      visible: false,
      prefabName: null,
      origin: null,
      cellCount: 0,
    };
  }
}

function makeHitFaceOutlineGeometry(): BufferGeometry {
  const half = HIT_FACE_OUTLINE_SIZE / 2;
  const positions = [
    -half, -half, 0,
    half, -half, 0,
    half, -half, 0,
    half, half, 0,
    half, half, 0,
    -half, half, 0,
    -half, half, 0,
    -half, -half, 0,
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

  const faceDistance = (MacroWorldSize / 2) + HIT_FACE_OUTLINE_OFFSET;
  return {
    position: {
      x: blockCenter.x + normalVector.x * faceDistance,
      y: blockCenter.y + normalVector.y * faceDistance,
      z: blockCenter.z + normalVector.z * faceDistance,
    },
    normalVector,
  };
}
