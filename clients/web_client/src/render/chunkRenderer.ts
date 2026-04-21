import {
  BoxGeometry,
  BufferGeometry,
  EdgesGeometry,
  Float32BufferAttribute,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MeshStandardMaterial,
  PerspectiveCamera,
  Raycaster,
  Vector2,
} from "three";
import { buildChunkMeshData } from "../voxel/meshing/chunkMesher";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";
import { adjacentMacroCoordFromSurfaceNormal, macroCenterWorldPosition, macroCoordFromWorldPosition } from "../voxel/core/gridUtils";
import type { FMacroCoord } from "../voxel/core/types";
import { chunkCoordKey } from "../voxel/core/types";
import { VoxelDirtyFlags } from "../voxel/storage/types";
import { WorldStore } from "../voxel/worldStore";
import { ObserveLog } from "../observe/logger";

export interface VoxelRaySelection {
  occupiedMacro: FMacroCoord;
  adjacentMacro: FMacroCoord;
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
  private readonly breakHighlight: LineSegments;
  private readonly placeHighlight: LineSegments;

  constructor() {
    this.group.name = "voxel-chunks";

    const highlightGeometry = new EdgesGeometry(
      new BoxGeometry(MacroWorldSize * 1.02, MacroWorldSize * 1.02, MacroWorldSize * 1.02),
    );
    this.breakHighlight = new LineSegments(
      highlightGeometry,
      new LineBasicMaterial({ color: 0xff5d5d }),
    );
    this.breakHighlight.visible = false;

    this.placeHighlight = new LineSegments(
      highlightGeometry,
      new LineBasicMaterial({ color: 0x55ff99 }),
    );
    this.placeHighlight.visible = false;

    this.group.add(this.breakHighlight);
    this.group.add(this.placeHighlight);
  }

  attachToScene(parent: Group): void {
    parent.add(this.group);
  }

  syncDirtyChunks(world: WorldStore, logger: ObserveLog): void {
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
    const occupiedMacro = macroCoordFromWorldPosition(
      hit.point.clone().add(worldNormal.clone().multiplyScalar(-0.1)),
      MacroWorldSize,
    );
    const adjacentMacro = adjacentMacroCoordFromSurfaceNormal(occupiedMacro, worldNormal);
    return { occupiedMacro, adjacentMacro };
  }

  setTargetHighlights(selection: VoxelRaySelection | null): void {
    if (!selection) {
      this.breakHighlight.visible = false;
      this.placeHighlight.visible = false;
      return;
    }

    const breakCenter = macroCenterWorldPosition(selection.occupiedMacro, MacroWorldSize);
    this.breakHighlight.position.set(breakCenter.x, breakCenter.y, breakCenter.z);
    this.breakHighlight.visible = true;

    const placeCenter = macroCenterWorldPosition(selection.adjacentMacro, MacroWorldSize);
    this.placeHighlight.position.set(placeCenter.x, placeCenter.y, placeCenter.z);
    this.placeHighlight.visible = true;
  }

  dispose(): void {
    for (const mesh of this.chunkMeshes.values()) {
      mesh.geometry.dispose();
    }
    this.chunkMaterial.dispose();
    this.breakHighlight.geometry.dispose();
    (this.breakHighlight.material as LineBasicMaterial).dispose();
    (this.placeHighlight.material as LineBasicMaterial).dispose();
  }
}
