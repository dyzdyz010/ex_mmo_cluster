import {
  BoxGeometry,
  Group,
  Mesh,
  MeshStandardMaterial,
  RingGeometry,
  Vector3,
} from "three";
import type { ObserveLog } from "../../observe/logger";
import { ChunkRenderController, type VoxelRaySelection } from "../../render/chunkRenderer";
import { createScene, type SceneHandles } from "../../render/scene";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController } from "./remotePlayerController";
import type { SelectionProvider } from "./worldEditController";

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
      new MeshStandardMaterial({ color: 0xfafcff, transparent: true, opacity: 0.35, roughness: 0.2 }),
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
    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
    this.sceneHandles.renderer.render(this.sceneHandles.scene, this.sceneHandles.camera);
  }

  getCurrentSelection(): VoxelRaySelection | null {
    return this.currentSelection;
  }

  getCameraPosition(): Vector3 {
    return this.sceneHandles.camera.position;
  }

  getMovementYawRadians(): number {
    return this.sceneHandles.getMovementYawRadians();
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
    this.groundActorPosition(this.localPlayer.getRenderedPosition(), 60, this.localDisplay);
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

  private groundActorPosition(position: Vector3, halfHeight: number, out: Vector3): void {
    out.set(
      position.x,
      this.world.store.surfaceCenterYAtWorldXZ(position.x, position.z, halfHeight, position.y),
      position.z,
    );
  }
}
