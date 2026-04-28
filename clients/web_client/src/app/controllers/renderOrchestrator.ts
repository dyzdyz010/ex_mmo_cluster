import { BoxGeometry, Group, Mesh, MeshStandardMaterial, RingGeometry, Vector3 } from "three";
import type { ObserveLog } from "../../observe/logger";
import { ChunkRenderController, type VoxelRaySelection } from "../../render/chunkRenderer";
import type { PrefabPreviewSnapshot } from "../../render/chunkRenderer";
import type { RendererDebugSnapshot } from "../../render/rendererBackend";
import type { SceneHandles } from "../../render/scene";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController } from "./remotePlayerController";
import type { HotbarState, SelectionProvider } from "./worldEditController";

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
    this.syncRing = new Mesh(
      new RingGeometry(170, 190, 48),
      new MeshStandardMaterial({ color: 0x284051, emissive: 0x0d1a22, roughness: 0.9 }),
    );
    this.syncRing.rotation.x = -Math.PI / 2;

    this.rootGroup.add(this.localAvatar, this.authorityAvatar, this.syncRing);

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
    this.sceneHandles.render();
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
    this.syncRemoteAvatarMeshes();

    this.localAvatar.position.copy(this.localDisplay);
    this.authorityAvatar.position.copy(this.authorityDisplay);
    this.syncRing.position.set(this.localDisplay.x, this.localDisplay.y - 59, this.localDisplay.z);
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
      this.groundActorPosition(entity.position, 60, display);
      avatar.position.copy(display);
    }
  }

  private ensureRemoteAvatar(cid: number): Mesh<BoxGeometry, MeshStandardMaterial> {
    let avatar = this.remoteAvatars.get(cid);
    if (!avatar) {
      avatar = new Mesh(
        new BoxGeometry(70, 120, 70),
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
      this.chunkRenderer.setPrefabPreview(null, null);
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

function vectorSnapshot(vector: Vector3): { x: number; y: number; z: number } {
  return { x: vector.x, y: vector.y, z: vector.z };
}
