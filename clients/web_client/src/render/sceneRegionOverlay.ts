import {
  BoxGeometry,
  Color,
  EdgesGeometry,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
} from "three";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";

export interface SceneRegionOverlayRegion {
  label: "scene1" | "scene2" | string;
  ownerSceneInstanceRef: number;
  chunkMin: { x: number; z: number };
  chunkMax: { x: number; z: number };
  color: number;
}

export interface SceneRegionOverlaySnapshotRegion {
  label: string;
  ownerSceneInstanceRef: number;
  chunkMin: { x: number; z: number };
  chunkMax: { x: number; z: number };
  worldMin: { x: number; z: number };
  worldMax: { x: number; z: number };
  color: string;
}

export interface SceneRegionOverlaySnapshot {
  visible: boolean;
  boundary: { chunkX: number; worldX: number };
  regions: SceneRegionOverlaySnapshotRegion[];
}

export interface SceneRegionOverlay {
  group: Group;
  setVisible: (visible: boolean) => void;
  snapshot: () => SceneRegionOverlaySnapshot;
  dispose: () => void;
}

const CHUNK_WORLD_SIZE = VoxelConstants.ChunkSizeInMacros * MacroWorldSize;
const GROUND_HINT_Y = 0.04;
const MARKER_BASE_Y = MacroWorldSize + 4;
const DEFAULT_Z_MIN = 0;
const DEFAULT_Z_MAX = 1;

export function dualSceneDemoRegions(): SceneRegionOverlayRegion[] {
  return [
    {
      label: "scene1",
      ownerSceneInstanceRef: 1,
      chunkMin: { x: 0, z: DEFAULT_Z_MIN },
      chunkMax: { x: 1, z: DEFAULT_Z_MAX },
      color: 0x25a8ff,
    },
    {
      label: "scene2",
      ownerSceneInstanceRef: 2,
      chunkMin: { x: 1, z: DEFAULT_Z_MIN },
      chunkMax: { x: 2, z: DEFAULT_Z_MAX },
      color: 0xffa726,
    },
  ];
}

export function createDualSceneDemoOverlay(): SceneRegionOverlay {
  return createSceneRegionOverlay(dualSceneDemoRegions(), 1);
}

export function createSceneRegionOverlay(
  regions: SceneRegionOverlayRegion[],
  boundaryChunkX: number,
): SceneRegionOverlay {
  const group = new Group();
  group.name = "scene-region-overlay";

  const disposables: Array<{ dispose: () => void }> = [];
  for (const region of regions) {
    const fill = createRegionFill(region);
    const border = createRegionBorder(region);
    group.add(fill, border);
    disposables.push(fill.geometry, fill.material, border.geometry, border.material);
  }

  const boundary = createBoundaryMarker(boundaryChunkX, regions);
  group.add(boundary);
  disposables.push(boundary.geometry, boundary.material);

  const snapshot = (): SceneRegionOverlaySnapshot => ({
    visible: group.visible,
    boundary: { chunkX: boundaryChunkX, worldX: boundaryChunkX * CHUNK_WORLD_SIZE },
    regions: regions.map(snapshotRegion),
  });

  return {
    group,
    setVisible(visible: boolean): void {
      group.visible = visible;
    },
    snapshot,
    dispose(): void {
      for (const disposable of disposables) {
        disposable.dispose();
      }
      group.clear();
    },
  };
}

function createRegionFill(region: SceneRegionOverlayRegion): Mesh<PlaneGeometry, MeshBasicMaterial> {
  const { width, depth, centerX, centerZ } = regionDimensions(region);
  const geometry = new PlaneGeometry(width, depth);
  const material = new MeshBasicMaterial({
    color: region.color,
    transparent: true,
    opacity: 0.08,
    depthTest: true,
    depthWrite: false,
  });
  const mesh = new Mesh(geometry, material);
  mesh.name = `scene-region-fill-${region.label}`;
  mesh.rotation.x = -Math.PI / 2;
  mesh.position.set(centerX, GROUND_HINT_Y, centerZ);
  mesh.renderOrder = -5;
  return mesh;
}

function createRegionBorder(region: SceneRegionOverlayRegion): LineSegments<EdgesGeometry, LineBasicMaterial> {
  const { width, depth, centerX, centerZ } = regionDimensions(region);
  const box = new BoxGeometry(width, 24, depth);
  const geometry = new EdgesGeometry(box);
  box.dispose();
  const material = new LineBasicMaterial({
    color: region.color,
    transparent: true,
    opacity: 0.9,
    depthTest: true,
  });
  const lines = new LineSegments(geometry, material);
  lines.name = `scene-region-border-${region.label}`;
  lines.position.set(centerX, MARKER_BASE_Y + 12, centerZ);
  lines.renderOrder = 3;
  return lines;
}

function createBoundaryMarker(
  boundaryChunkX: number,
  regions: SceneRegionOverlayRegion[],
): LineSegments<EdgesGeometry, LineBasicMaterial> {
  const minZ = Math.min(...regions.map((region) => region.chunkMin.z)) * CHUNK_WORLD_SIZE;
  const maxZ = Math.max(...regions.map((region) => region.chunkMax.z)) * CHUNK_WORLD_SIZE;
  const depth = maxZ - minZ;
  const box = new BoxGeometry(18, 220, depth);
  const geometry = new EdgesGeometry(box);
  box.dispose();
  const material = new LineBasicMaterial({
    color: 0xffffff,
    transparent: true,
    opacity: 0.95,
    depthTest: true,
  });
  const lines = new LineSegments(geometry, material);
  lines.name = `scene-region-boundary-x${boundaryChunkX}`;
  lines.position.set(boundaryChunkX * CHUNK_WORLD_SIZE, MARKER_BASE_Y + 110, (minZ + maxZ) / 2);
  lines.renderOrder = 4;
  return lines;
}

function regionDimensions(region: SceneRegionOverlayRegion): {
  width: number;
  depth: number;
  centerX: number;
  centerZ: number;
} {
  const minX = region.chunkMin.x * CHUNK_WORLD_SIZE;
  const maxX = region.chunkMax.x * CHUNK_WORLD_SIZE;
  const minZ = region.chunkMin.z * CHUNK_WORLD_SIZE;
  const maxZ = region.chunkMax.z * CHUNK_WORLD_SIZE;
  return {
    width: maxX - minX,
    depth: maxZ - minZ,
    centerX: (minX + maxX) / 2,
    centerZ: (minZ + maxZ) / 2,
  };
}

function snapshotRegion(region: SceneRegionOverlayRegion): SceneRegionOverlaySnapshotRegion {
  return {
    label: region.label,
    ownerSceneInstanceRef: region.ownerSceneInstanceRef,
    chunkMin: region.chunkMin,
    chunkMax: region.chunkMax,
    worldMin: { x: region.chunkMin.x * CHUNK_WORLD_SIZE, z: region.chunkMin.z * CHUNK_WORLD_SIZE },
    worldMax: { x: region.chunkMax.x * CHUNK_WORLD_SIZE, z: region.chunkMax.z * CHUNK_WORLD_SIZE },
    color: `#${new Color(region.color).getHexString()}`,
  };
}
