import { BoxGeometry, Group, Mesh, MeshStandardMaterial, RingGeometry, Vector3 } from "three";
import type { ObserveLog } from "../../observe/logger";
import { ChunkRenderController, type VoxelRaySelection } from "../../render/chunkRenderer";
import type { PrefabPreviewSnapshot } from "../../render/chunkRenderer";
import type { RendererDebugSnapshot } from "../../render/rendererBackend";
import type { SceneHandles } from "../../render/scene";
import {
  createDualSceneDemoOverlay,
  type SceneRegionOverlay,
  type SceneRegionOverlaySnapshot,
} from "../../render/sceneRegionOverlay";
import { AvatarConstants, VoxelConstants } from "../../voxel/core/constants";
import type { FMacroCoord, FMicroCoord } from "../../voxel/core/types";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { WorldEditStats } from "../../voxel/worldStore";
import { DebrisRenderer } from "../../voxel/debrisRenderer";
import type { DebrisSimulation } from "../../voxel/debrisEffect";
import { FieldDebugOverlay } from "../../voxel/field/fieldDebugOverlay";
import type { VoxelFieldRegionDestroyedMessage, VoxelFieldRegionSnapshotMessage } from "../../infrastructure/net/voxelProtocol";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController } from "./remotePlayerController";
import type { HotbarState, HotbarEntry, SelectionProvider } from "./worldEditController";

interface MaybeDebrisProvider {
  getDebrisSimulation?(): DebrisSimulation;
}

interface MaybeFieldProvider {
  drainVoxelFieldSnapshots?(): VoxelFieldRegionSnapshotMessage[];
  drainVoxelFieldDestroyeds?(): VoxelFieldRegionDestroyedMessage[];
}

interface EditPreviewProvider {
  getHotbarState(): HotbarState;
}

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
  private readonly remoteAvatars = new Map<number, Mesh<BoxGeometry, MeshStandardMaterial>>();
  private readonly syncRing: Mesh<RingGeometry, MeshStandardMaterial>;
  private readonly localDisplay = new Vector3();
  private readonly authorityDisplay = new Vector3();
  private readonly remoteDisplay = new Vector3();
  private currentSelection: VoxelRaySelection | null = null;
  private editPreviewProvider: EditPreviewProvider | null = null;
  private prefabPreviewIntentKey = "";
  private readonly debrisRenderer: DebrisRenderer | null;
  private readonly fieldDebugOverlay: FieldDebugOverlay;
  private readonly sceneRegionOverlay: SceneRegionOverlay;

  constructor(
    sceneHandles: SceneHandles,
    private readonly world: VoxelWorldAdapter,
    private readonly localPlayer: LocalPlayerController,
    private readonly remotePlayer: RemotePlayerController,
    private readonly logger: ObserveLog,
  ) {
    this.sceneHandles = sceneHandles;
    this.sceneHandles.scene.add(this.rootGroup);
    this.chunkRenderer.attachToScene(this.rootGroup);
    this.sceneRegionOverlay = createDualSceneDemoOverlay();
    this.rootGroup.add(this.sceneRegionOverlay.group);

    this.localAvatar = new Mesh(
      new BoxGeometry(AvatarConstants.WidthCm, AvatarConstants.HeightCm, AvatarConstants.WidthCm),
      new MeshStandardMaterial({ color: 0x63d4ff, emissive: 0x113447, roughness: 0.35 }),
    );
    this.authorityAvatar = new Mesh(
      new BoxGeometry(35, 120, 35),
      new MeshStandardMaterial({
        color: 0xfafcff,
        transparent: true,
        opacity: 0.35,
        roughness: 0.2,
      }),
    );
    this.syncRing = new Mesh(
      new RingGeometry(120, 140, 48),
      new MeshStandardMaterial({ color: 0x284051, emissive: 0x0d1a22, roughness: 0.9 }),
    );
    this.syncRing.rotation.x = -Math.PI / 2;

    this.rootGroup.add(this.localAvatar, this.authorityAvatar, this.syncRing);

    // Phase 4-bis Step 4-bis-12:if the world adapter exposes a
    // DebrisSimulation(OnlineVoxelWorldAdapter does),wire its InstancedMesh
    // into the world root so destroyed-object debris is visible to the
    // user. Offline / browser-fallback adapters skip silently.
    const maybeDebrisProvider = this.world as unknown as MaybeDebrisProvider;
    if (typeof maybeDebrisProvider.getDebrisSimulation === "function") {
      const sim = maybeDebrisProvider.getDebrisSimulation();
      this.debrisRenderer = new DebrisRenderer(sim);
      this.rootGroup.add(this.debrisRenderer.mesh);
    } else {
      this.debrisRenderer = null;
    }

    this.fieldDebugOverlay = new FieldDebugOverlay();
    this.rootGroup.add(this.fieldDebugOverlay.rootGroup);
    if (import.meta.env.DEV) {
      (window as Record<string, unknown>).__devFieldOverlay = this.fieldDebugOverlay;
    }

    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
  }

  onFrame(nowMs: number, dtMs: number): void {
    const dtSecs = dtMs / 1000;
    this.updateAvatarTransforms(nowMs / 1000);
    this.sceneHandles.update(dtSecs);
    this.currentSelection = this.chunkRenderer.raycastFromCameraCenter(this.sceneHandles.camera);
    this.chunkRenderer.setTargetHighlights(this.currentSelection);
    this.updatePrefabPreview();
    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
    if (this.debrisRenderer !== null) {
      this.debrisRenderer.syncFromSimulation();
    }
    this._drainFieldMessages();
    this.sceneHandles.render();
  }

  private _drainFieldMessages(): void {
    const fieldProvider = this.world as unknown as MaybeFieldProvider;
    if (typeof fieldProvider.drainVoxelFieldSnapshots === "function") {
      for (const msg of fieldProvider.drainVoxelFieldSnapshots()) {
        this.fieldDebugOverlay.onFieldSnapshot(msg.snapshot);
      }
    }
    if (typeof fieldProvider.drainVoxelFieldDestroyeds === "function") {
      for (const msg of fieldProvider.drainVoxelFieldDestroyeds()) {
        this.fieldDebugOverlay.onRegionDestroyed(msg.destroyed.regionId);
      }
    }
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

  getRendererDebugSnapshot(): RendererDebugSnapshot {
    return this.sceneHandles.getRendererDebugSnapshot();
  }

  getSceneRegionOverlaySnapshot(): SceneRegionOverlaySnapshot {
    return this.sceneRegionOverlay.snapshot();
  }

  setSceneRegionOverlayVisible(visible: boolean): void {
    this.sceneRegionOverlay.setVisible(visible);
  }

  setEditPreviewProvider(provider: EditPreviewProvider): void {
    this.editPreviewProvider = provider;
  }

  toggleFieldDebugOverlay(): void {
    this.fieldDebugOverlay.toggle();
  }

  dispose(): void {
    this.chunkRenderer.dispose();
    this.sceneRegionOverlay.dispose();
    this.sceneHandles.dispose();
    this.localAvatar.geometry.dispose();
    this.localAvatar.material.dispose();
    this.authorityAvatar.geometry.dispose();
    this.authorityAvatar.material.dispose();
    for (const avatar of this.remoteAvatars.values()) {
      avatar.geometry.dispose();
      avatar.material.dispose();
    }
    this.remoteAvatars.clear();
    this.syncRing.geometry.dispose();
    this.syncRing.material.dispose();
  }

  private updateAvatarTransforms(nowSecs: number): void {
    this.groundActorPosition(
      this.localPlayer.getRenderedPosition(),
      AvatarConstants.HalfHeightCm,
      this.localDisplay,
      this.localPlayer.getCurrentState()?.groundY,
    );
    this.groundActorPosition(
      this.localPlayer.getAuthoritativePosition(),
      60,
      this.authorityDisplay,
    );
    this.groundActorPosition(
      this.remotePlayer.getRenderedPosition(),
      AvatarConstants.HalfHeightCm,
      this.remoteDisplay,
      this.remotePlayer.getRenderedGroundY() ?? undefined,
    );
    this.syncRemoteAvatarMeshes();

    this.localAvatar.position.copy(this.localDisplay);
    this.authorityAvatar.position.copy(this.authorityDisplay);
    this.syncRing.position.set(
      this.localDisplay.x,
      this.localDisplay.y - (AvatarConstants.HalfHeightCm - 1),
      this.localDisplay.z,
    );
    this.syncRing.rotation.z = nowSecs * 0.25;
    this.sceneHandles.setCameraFollow(this.localDisplay);
  }

  private syncRemoteAvatarMeshes(): void {
    const rendered = this.remotePlayer.getRenderedEntities();
    const visible = new Set(rendered.map((entity) => entity.cid));
    for (const [cid, avatar] of this.remoteAvatars) {
      if (!visible.has(cid)) {
        this.rootGroup.remove(avatar);
        avatar.geometry.dispose();
        avatar.material.dispose();
        this.remoteAvatars.delete(cid);
      }
    }

    for (const entity of rendered) {
      const avatar = this.ensureRemoteAvatar(entity.cid);
      const display = new Vector3();
      this.groundActorPosition(
        entity.position,
        AvatarConstants.HalfHeightCm,
        display,
        entity.movementGroundY ?? undefined,
      );
      avatar.position.copy(display);
    }
  }

  private ensureRemoteAvatar(cid: number): Mesh<BoxGeometry, MeshStandardMaterial> {
    let avatar = this.remoteAvatars.get(cid);
    if (!avatar) {
      avatar = new Mesh(
        new BoxGeometry(AvatarConstants.WidthCm, AvatarConstants.HeightCm, AvatarConstants.WidthCm),
        new MeshStandardMaterial({ color: 0xffbb55, emissive: 0x4c2b08, roughness: 0.4 }),
      );
      this.remoteAvatars.set(cid, avatar);
      this.rootGroup.add(avatar);
    }
    return avatar;
  }

  private updatePrefabPreview(): void {
    const selected = this.editPreviewProvider?.getHotbarState().selected;
    if (!this.currentSelection || selected?.kind !== "prefab") {
      this.clearPrefabPreviewIfNeeded();
      return;
    }

    const intentKey = prefabPreviewIntentKey(
      this.currentSelection,
      selected,
      this.world.store.editStats,
    );
    if (intentKey === this.prefabPreviewIntentKey) {
      return;
    }
    const startedAtMs = performance.now();
    this.prefabPreviewIntentKey = intentKey;

    const boundaryPreview = this.world.previewPrefabBoundarySnap({
      prefabName: selected.prefabName,
      hitMacro: this.currentSelection.occupiedMacro,
      ...(this.currentSelection.occupiedMicro
        ? { hitMicro: this.currentSelection.occupiedMicro.micro }
        : {}),
      ...(this.currentSelection.adjacentMicro
        ? { anchorMicroCoord: worldMicroCoordFromTarget(this.currentSelection.adjacentMicro) }
        : {}),
      faceNormal: this.currentSelection.faceNormal,
      rotation: selected.rotation,
    });
    if (boundaryPreview.cells.length > 0) {
      this.chunkRenderer.setPrefabRasterPreview(selected.prefabName, boundaryPreview.cells);
      this.logger.emit("render", "prefab_preview_updated", {
        prefab: selected.prefabName,
        mode: "boundary",
        elapsed_ms: Math.round((performance.now() - startedAtMs) * 10) / 10,
        cells: boundaryPreview.cells.length,
        incoming_occupied_slots: boundaryPreview.incomingOccupiedSlots,
        overlap_slots: boundaryPreview.overlapSlots,
        contact_slots: boundaryPreview.contactSlots,
        anchor_candidate_count: boundaryPreview.debug?.anchorCandidateCount ?? 0,
        rasterize_count: boundaryPreview.debug?.rasterizeCount ?? 0,
      });
      return;
    }

    this.chunkRenderer.setPrefabPreview(
      this.currentSelection,
      this.world.getPrefab(selected.prefabName),
    );
    this.logger.emit("render", "prefab_preview_updated", {
      prefab: selected.prefabName,
      mode: "fallback",
      elapsed_ms: Math.round((performance.now() - startedAtMs) * 10) / 10,
      reject_reason: boundaryPreview.rejectReason ?? "empty_boundary_preview",
      anchor_candidate_count: boundaryPreview.debug?.anchorCandidateCount ?? 0,
      rasterize_count: boundaryPreview.debug?.rasterizeCount ?? 0,
    });
  }

  private clearPrefabPreviewIfNeeded(): void {
    if (this.prefabPreviewIntentKey === "") {
      return;
    }
    this.prefabPreviewIntentKey = "";
    this.chunkRenderer.setPrefabPreview(null, null);
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

function vectorSnapshot(vector: Vector3): { x: number; y: number; z: number } {
  return { x: vector.x, y: vector.y, z: vector.z };
}

function prefabPreviewIntentKey(
  selection: VoxelRaySelection,
  selected: Extract<HotbarEntry, { kind: "prefab" }>,
  editStats: WorldEditStats,
): string {
  return [
    selected.prefabName,
    selected.rotation,
    coordKey(selection.occupiedMacro),
    coordKey(selection.adjacentMacro),
    coordKey(selection.faceNormal),
    selection.occupiedMicro ? coordKey(selection.occupiedMicro.macro) : "",
    selection.occupiedMicro ? coordKey(selection.occupiedMicro.micro) : "",
    selection.adjacentMicro ? coordKey(selection.adjacentMicro.macro) : "",
    selection.adjacentMicro ? coordKey(selection.adjacentMicro.micro) : "",
    editStats.placed,
    editStats.broken,
    editStats.rejected,
    editStats.conflicts,
  ].join("|");
}

function coordKey(coord: { x: number; y: number; z: number }): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

function worldMicroCoordFromTarget(target: { macro: FMacroCoord; micro: FMicroCoord }): FMicroCoord {
  return {
    x: target.macro.x * VoxelConstants.MicroPerMacro + target.micro.x,
    y: target.macro.y * VoxelConstants.MicroPerMacro + target.micro.y,
    z: target.macro.z * VoxelConstants.MicroPerMacro + target.micro.z,
  };
}
