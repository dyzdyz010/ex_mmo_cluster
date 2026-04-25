import { BoxGeometry, Group, Mesh, MeshStandardMaterial, RingGeometry, Vector3 } from "three";
import type { ObserveLog } from "../../observe/logger";
import { ChunkRenderController, type VoxelRaySelection } from "../../render/chunkRenderer";
import type { PrefabPreviewSnapshot } from "../../render/chunkRenderer";
import { createScene, type SceneHandles } from "../../render/scene";
import type { FMacroCoord, FMicroCoord } from "../../voxel/core/types";
import type { PrefabBoundarySnapPreview } from "../../voxel/prefab";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { WorldEditStats } from "../../voxel/worldStore";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController } from "./remotePlayerController";
import type { HotbarState, SelectionProvider } from "./worldEditController";

interface EditPreviewProvider {
  getHotbarState(): HotbarState;
}

const PREFAB_PREVIEW_REFRESH_INTERVAL_MS = 120;

/**
 * Holds the Three.js scene, the avatar meshes, and the camera. Each frame it
 * reads rendered positions from the player controllers, updates transforms,
 * re-meshes dirty chunks, and renders.
 *
 * Exposes the current raycast selection via SelectionProvider so the edit
 * controller never needs to know about the renderer.
 */
export class RenderOrchestrator implements FrameSubscriber, SelectionProvider {
  readonly sceneHandles: SceneHandles;
  private readonly rootGroup = new Group();
  private readonly chunkRenderer = new ChunkRenderController();
  private readonly localAvatar: Mesh<BoxGeometry, MeshStandardMaterial>;
  private readonly authorityAvatar: Mesh<BoxGeometry, MeshStandardMaterial>;
  private readonly remoteAvatar: Mesh<BoxGeometry, MeshStandardMaterial>;
  private readonly syncRing: Mesh<RingGeometry, MeshStandardMaterial>;
  private readonly localDisplay = new Vector3();
  private readonly authorityDisplay = new Vector3();
  private readonly remoteDisplay = new Vector3();
  private currentSelection: VoxelRaySelection | null = null;
  private editPreviewProvider: EditPreviewProvider | null = null;
  private prefabPreviewCacheKey: string | null = null;
  private prefabPreviewBoundaryPreview: PrefabBoundarySnapPreview | null = null;
  private prefabPreviewLastRefreshMs = Number.NEGATIVE_INFINITY;
  private prefabPreviewSelectedKey: string | null = null;
  private prefabPreviewEditSignature: string | null = null;

  constructor(
    canvas: HTMLCanvasElement,
    private readonly world: VoxelWorldAdapter,
    private readonly localPlayer: LocalPlayerController,
    private readonly remotePlayer: RemotePlayerController,
    private readonly logger: ObserveLog,
  ) {
    this.sceneHandles = createScene(canvas);
    this.sceneHandles.scene.add(this.rootGroup);
    this.chunkRenderer.attachToScene(this.rootGroup);

    this.localAvatar = new Mesh(
      new BoxGeometry(70, 120, 70),
      new MeshStandardMaterial({ color: 0x63d4ff, emissive: 0x113447, roughness: 0.35 }),
    );
    this.authorityAvatar = new Mesh(
      new BoxGeometry(50, 90, 50),
      new MeshStandardMaterial({
        color: 0xfafcff,
        transparent: true,
        opacity: 0.35,
        roughness: 0.2,
      }),
    );
    this.remoteAvatar = new Mesh(
      new BoxGeometry(70, 120, 70),
      new MeshStandardMaterial({ color: 0xffbb55, emissive: 0x4c2b08, roughness: 0.4 }),
    );
    this.syncRing = new Mesh(
      new RingGeometry(170, 190, 48),
      new MeshStandardMaterial({ color: 0x284051, emissive: 0x0d1a22, roughness: 0.9 }),
    );
    this.syncRing.rotation.x = -Math.PI / 2;

    this.rootGroup.add(this.localAvatar, this.authorityAvatar, this.remoteAvatar, this.syncRing);

    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
  }

  onFrame(nowMs: number, dtMs: number): void {
    const dtSecs = dtMs / 1000;
    this.updateAvatarTransforms(nowMs / 1000);
    this.sceneHandles.update(dtSecs);
    this.currentSelection = this.chunkRenderer.raycastFromCameraCenter(this.sceneHandles.camera);
    this.chunkRenderer.setTargetHighlights(this.currentSelection);
    this.updatePrefabPreview(nowMs);
    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
    this.sceneHandles.renderer.render(this.sceneHandles.scene, this.sceneHandles.camera);
  }

  getCurrentSelection(): VoxelRaySelection | null {
    return this.currentSelection;
  }

  getCameraPosition(): Vector3 {
    return this.sceneHandles.camera.position;
  }

  getActorDisplaySnapshot(): {
    local: { x: number; y: number; z: number };
    authority: { x: number; y: number; z: number };
    remote: { x: number; y: number; z: number };
  } {
    return {
      local: vectorSnapshot(this.localDisplay),
      authority: vectorSnapshot(this.authorityDisplay),
      remote: vectorSnapshot(this.remoteDisplay),
    };
  }

  getMovementYawRadians(): number {
    return this.sceneHandles.getMovementYawRadians();
  }

  getPrefabPreviewSnapshot(): PrefabPreviewSnapshot {
    return this.chunkRenderer.getPrefabPreviewSnapshot();
  }

  setEditPreviewProvider(provider: EditPreviewProvider): void {
    this.editPreviewProvider = provider;
  }

  dispose(): void {
    this.chunkRenderer.dispose();
    this.sceneHandles.dispose();
    this.localAvatar.geometry.dispose();
    this.localAvatar.material.dispose();
    this.authorityAvatar.geometry.dispose();
    this.authorityAvatar.material.dispose();
    this.remoteAvatar.geometry.dispose();
    this.remoteAvatar.material.dispose();
    this.syncRing.geometry.dispose();
    this.syncRing.material.dispose();
  }

  private updateAvatarTransforms(nowSecs: number): void {
    this.groundActorPosition(
      this.localPlayer.getRenderedPosition(),
      60,
      this.localDisplay,
      this.localPlayer.getCurrentState()?.groundY,
    );
    this.groundActorPosition(
      this.localPlayer.getAuthoritativePosition(),
      45,
      this.authorityDisplay,
    );
    this.groundActorPosition(this.remotePlayer.getRenderedPosition(), 60, this.remoteDisplay);

    this.localAvatar.position.copy(this.localDisplay);
    this.authorityAvatar.position.copy(this.authorityDisplay);
    this.remoteAvatar.position.copy(this.remoteDisplay);
    this.syncRing.position.set(this.localDisplay.x, this.localDisplay.y - 59, this.localDisplay.z);
    this.syncRing.rotation.z = nowSecs * 0.25;
    this.sceneHandles.setCameraFollow(this.localDisplay);
  }

  private updatePrefabPreview(nowMs: number): void {
    const selected = this.editPreviewProvider?.getHotbarState().selected;
    const selectedKey = prefabPreviewSelectedKey(selected);
    const editSignature = prefabPreviewEditSignature(this.world.store.editStats);
    const previewKey = prefabPreviewRequestKey(
      selected,
      this.currentSelection,
      this.world.store.editStats,
    );
    if (!previewKey || !this.currentSelection || selected?.kind !== "prefab") {
      this.prefabPreviewCacheKey = null;
      this.prefabPreviewBoundaryPreview = null;
      this.prefabPreviewLastRefreshMs = Number.NEGATIVE_INFINITY;
      this.prefabPreviewSelectedKey = null;
      this.prefabPreviewEditSignature = null;
      this.chunkRenderer.setPrefabPreview(null, null);
      return;
    }

    const hasReusablePrecisePreview =
      this.prefabPreviewBoundaryPreview?.ok === true &&
      this.prefabPreviewSelectedKey === selectedKey &&
      this.prefabPreviewEditSignature === editSignature;
    if (
      shouldUseCoarsePrefabPreview(
        selected,
        this.currentSelection,
        this.sceneHandles.isCameraInteracting(),
        hasReusablePrecisePreview,
      )
    ) {
      this.prefabPreviewCacheKey = null;
      this.prefabPreviewBoundaryPreview = null;
      this.prefabPreviewLastRefreshMs = Number.NEGATIVE_INFINITY;
      this.prefabPreviewSelectedKey = null;
      this.prefabPreviewEditSignature = null;
      this.chunkRenderer.setPrefabPreview(
        this.currentSelection,
        this.world.getPrefab(selected.prefabName),
      );
      return;
    }

    let preview = this.prefabPreviewBoundaryPreview;
    const refreshPreview = shouldRefreshPrefabPreview({
      nowMs,
      requestKey: previewKey,
      cachedKey: this.prefabPreviewCacheKey,
      hasCachedPreview: preview !== null,
      lastRefreshMs: this.prefabPreviewLastRefreshMs,
      selectedKey,
      lastSelectedKey: this.prefabPreviewSelectedKey,
      editSignature,
      lastEditSignature: this.prefabPreviewEditSignature,
      refreshIntervalMs: PREFAB_PREVIEW_REFRESH_INTERVAL_MS,
    });
    if (!refreshPreview && preview) {
      return;
    }

    if (refreshPreview || !preview) {
      preview = this.world.previewPrefabBoundarySnap({
        prefabName: selected.prefabName,
        hitMacro: this.currentSelection.occupiedMacro,
        ...(this.currentSelection.occupiedMicro
          ? { hitMicro: this.currentSelection.occupiedMicro.micro }
          : {}),
        faceNormal: this.currentSelection.faceNormal,
        rotation: selected.rotation,
      });
      this.prefabPreviewCacheKey = previewKey;
      this.prefabPreviewBoundaryPreview = preview;
      this.prefabPreviewLastRefreshMs = nowMs;
      this.prefabPreviewSelectedKey = selectedKey;
      this.prefabPreviewEditSignature = editSignature;
    }

    if (preview.ok) {
      this.chunkRenderer.setPrefabRasterPreview(selected.prefabName, preview.cells);
      return;
    }

    this.chunkRenderer.setPrefabPreview(
      this.currentSelection,
      this.world.getPrefab(selected.prefabName),
    );
  }

  private groundActorPosition(
    position: Vector3,
    halfHeight: number,
    out: Vector3,
    movementGroundY?: number,
  ): void {
    const surfaceCenterY = this.world.store.surfaceCenterYAtWorldXZ(
      position.x,
      position.z,
      halfHeight,
      movementGroundY ?? position.y,
    );
    out.set(
      position.x,
      movementGroundY === undefined
        ? surfaceCenterY
        : resolveActorDisplayY({
            movementY: position.y,
            movementGroundY,
            surfaceCenterY,
          }),
      position.z,
    );
  }
}

export function resolveActorDisplayY({
  movementY,
  movementGroundY,
  surfaceCenterY,
}: {
  movementY: number;
  movementGroundY: number;
  surfaceCenterY: number;
}): number {
  return surfaceCenterY + Math.max(0, movementY - movementGroundY);
}

export function prefabPreviewRequestKey(
  selected: HotbarState["selected"] | null | undefined,
  selection: VoxelRaySelection | null,
  editStats: Pick<WorldEditStats, "placed" | "broken" | "conflicts">,
): string | null {
  if (!selection || selected?.kind !== "prefab") {
    return null;
  }

  return [
    selected.prefabName,
    selected.rotation,
    macroCoordKey(selection.occupiedMacro),
    macroCoordKey(selection.adjacentMacro),
    macroCoordKey(selection.faceNormal),
    selection.occupiedMicro ? microCoordKey(selection.occupiedMicro.micro) : "micro:none",
    editStats.placed,
    editStats.broken,
    editStats.conflicts,
  ].join("|");
}

export function shouldRefreshPrefabPreview({
  nowMs,
  requestKey,
  cachedKey,
  hasCachedPreview,
  lastRefreshMs,
  selectedKey,
  lastSelectedKey,
  editSignature,
  lastEditSignature,
  refreshIntervalMs = PREFAB_PREVIEW_REFRESH_INTERVAL_MS,
}: {
  nowMs: number;
  requestKey: string;
  cachedKey: string | null;
  hasCachedPreview: boolean;
  lastRefreshMs: number;
  selectedKey: string | null;
  lastSelectedKey: string | null;
  editSignature: string;
  lastEditSignature: string | null;
  refreshIntervalMs?: number;
}): boolean {
  if (!hasCachedPreview || cachedKey === null) {
    return true;
  }
  if (requestKey === cachedKey) {
    return false;
  }
  if (selectedKey !== lastSelectedKey) {
    return true;
  }
  if (editSignature !== lastEditSignature) {
    return true;
  }
  return nowMs - lastRefreshMs >= refreshIntervalMs;
}

export function shouldUseCoarsePrefabPreview(
  selected: HotbarState["selected"] | null | undefined,
  selection: VoxelRaySelection | null,
  cameraInteracting: boolean,
  hasReusablePrecisePreview: boolean,
): boolean {
  return (
    cameraInteracting &&
    !hasReusablePrecisePreview &&
    selection !== null &&
    selected?.kind === "prefab"
  );
}

function vectorSnapshot(vector: Vector3): { x: number; y: number; z: number } {
  return { x: vector.x, y: vector.y, z: vector.z };
}

function prefabPreviewSelectedKey(selected: HotbarState["selected"] | null | undefined): string | null {
  return selected?.kind === "prefab" ? `${selected.prefabName}:${selected.rotation}` : null;
}

function prefabPreviewEditSignature(
  editStats: Pick<WorldEditStats, "placed" | "broken" | "conflicts">,
): string {
  return `${editStats.placed}:${editStats.broken}:${editStats.conflicts}`;
}

function macroCoordKey(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function microCoordKey(coord: FMicroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}
