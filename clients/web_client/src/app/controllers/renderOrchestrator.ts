import { BoxGeometry, Group, Mesh, MeshStandardMaterial, RingGeometry, Vector3 } from "three";
import type { Camera } from "three";
import type { ObserveLog } from "../../observe/logger";
import {
  ChunkRenderController,
  type TargetHighlightSnapshot,
  type VoxelRaySelection,
} from "../../render/chunkRenderer";
import type { PrefabPreviewSnapshot } from "../../render/chunkRenderer";
import type { RendererDebugSnapshot } from "../../render/rendererBackend";
import type { SceneHandles } from "../../render/scene";
import {
  createDualSceneDemoOverlay,
  type SceneRegionOverlay,
  type SceneRegionOverlaySnapshot,
} from "../../render/sceneRegionOverlay";
import { AvatarConstants, MacroWorldSize, VoxelConstants } from "../../voxel/core/constants";
import type { FMacroCoord, FMicroCoord } from "../../voxel/core/types";
import { macroCoordFromWorldPosition } from "../../voxel/core/gridUtils";
import {
  createFieldOverlayProjector,
  resolveSelectionOverlayProjection,
} from "../../voxel/overlayTarget";
import type { VoxelOverlayProjection } from "../../voxel/overlayTarget";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { WorldEditStats } from "../../voxel/worldStore";
import { DebrisRenderer } from "../../voxel/debrisRenderer";
import type { DebrisSimulation } from "../../voxel/debrisEffect";
import {
  FieldDebugOverlay,
  type FieldDebugOverlaySnapshot,
} from "../../voxel/field/fieldDebugOverlay";
import {
  LightningBoltRenderer,
  type LightningBoltRendererSnapshot,
} from "../../voxel/field/lightningBoltRenderer";
import { FieldMask, type FFieldRegionSnapshot } from "../../voxel/field/fieldProtocol";
import type {
  VoxelFieldRegionDestroyedMessage,
  VoxelFieldRegionSnapshotMessage,
} from "../../infrastructure/net/voxelProtocol";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController, RenderedRemoteEntity } from "./remotePlayerController";
import type {
  EntityTargetProvider,
  EntityTargetSelection,
  HotbarState,
  HotbarEntry,
  SelectionProvider,
} from "./worldEditController";

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

export interface TargetOverlaySnapshot {
  selection: VoxelRaySelection | null;
  highlight: TargetHighlightSnapshot;
  projection: {
    granularity: string;
    key: string;
    label: string;
    macro: FMacroCoord;
    selectedMicro?: FMicroCoord;
    ownerObjectId?: string;
    prefabInstanceId?: number;
    cellCount: number;
    occupiedSlots: number;
    coveredMacroMin: FMacroCoord | null;
    coveredMacroMax: FMacroCoord | null;
  } | null;
  entityTarget: EntityTargetSelection | null;
  fallbackEntityTarget: EntityTargetSelection | null;
}

const ENTITY_TARGET_NDC_RADIUS = 0.12;
interface PendingSnapshotLightningBolt {
  sourceCoord: FMacroCoord;
  targetCoord: FMacroCoord;
}

/**
 * Holds the Three.js scene, the avatar meshes, and the camera. Each frame it
 * reads rendered positions from the player controllers, updates transforms,
 * re-meshes dirty chunks, and renders.
 *
 * Exposes the current raycast selection via SelectionProvider so the edit
 * controller never needs to know about the renderer.
 */
export class RenderOrchestrator
  implements FrameSubscriber, SelectionProvider, EntityTargetProvider
{
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
  private readonly lightningBoltRenderer = new LightningBoltRenderer();
  private readonly pendingSnapshotLightningBolts = new Map<string, PendingSnapshotLightningBolt>();
  private readonly latestFieldSnapshots = new Map<number, VoxelFieldRegionSnapshotMessage>();
  private readonly sceneRegionOverlay: SceneRegionOverlay;
  private currentEntityTarget: EntityTargetSelection | null = null;

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
    this.fieldDebugOverlay.setProjector(createFieldOverlayProjector(this.world.store));
    this.rootGroup.add(this.fieldDebugOverlay.rootGroup);
    this.rootGroup.add(this.lightningBoltRenderer.group);
    if (import.meta.env.DEV) {
      const dev = window as unknown as Record<string, unknown>;
      dev.__devFieldOverlay = this.fieldDebugOverlay;
      dev.__devWorld = this.world;
      dev.__devRender = this;
    }

    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
  }

  onFrame(nowMs: number, dtMs: number): void {
    const dtSecs = dtMs / 1000;
    this.updateAvatarTransforms(nowMs, dtSecs);
    this.sceneHandles.update(dtSecs);
    this.currentSelection = this.chunkRenderer.raycastFromCameraCenter(this.sceneHandles.camera);
    this.currentEntityTarget = resolveEntityTargetFromCamera(
      this.remotePlayer.getRenderedEntities(),
      this.sceneHandles.camera,
    );
    this.chunkRenderer.setTargetHighlights(this.currentSelection, this.world.store);
    this.updatePrefabPreview();
    this.chunkRenderer.syncDirtyChunks(this.world.store, this.logger);
    if (this.debrisRenderer !== null) {
      this.debrisRenderer.syncFromSimulation();
    }
    this._drainFieldMessages();
    if (this.fieldDebugOverlay.isVisible()) {
      this.fieldDebugOverlay.updateSmoke(dtMs);
    }
    this.lightningBoltRenderer.update(nowMs);
    this.sceneHandles.render();
  }

  private _drainFieldMessages(): void {
    const fieldProvider = this.world as unknown as MaybeFieldProvider;
    const fieldOverlayVisible = this.fieldDebugOverlay.isVisible();
    if (typeof fieldProvider.drainVoxelFieldSnapshots === "function") {
      for (const msg of fieldProvider.drainVoxelFieldSnapshots()) {
        this.latestFieldSnapshots.set(msg.snapshot.regionId, msg);
        this.materializePendingSnapshotLightning(msg.snapshot);
        if (fieldOverlayVisible) {
          this.fieldDebugOverlay.onFieldSnapshot(msg.snapshot);
        }
      }
    }
    if (typeof fieldProvider.drainVoxelFieldDestroyeds === "function") {
      for (const msg of fieldProvider.drainVoxelFieldDestroyeds()) {
        this.latestFieldSnapshots.delete(msg.destroyed.regionId);
        if (fieldOverlayVisible) {
          this.fieldDebugOverlay.onRegionDestroyed(msg.destroyed.regionId);
        }
      }
    }
  }

  getCurrentSelection(): VoxelRaySelection | null {
    return this.currentSelection;
  }

  getCurrentEntityTarget(): EntityTargetSelection | null {
    return this.currentEntityTarget ? cloneEntityTarget(this.currentEntityTarget) : null;
  }

  getFallbackEntityTarget(): EntityTargetSelection | null {
    return {
      entityId: -1,
      macroCoord: macroCoordFromWorldPosition(this.localDisplay, MacroWorldSize),
      renderedPosition: vectorSnapshot(this.localDisplay),
    };
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

  getTargetOverlaySnapshot(): TargetOverlaySnapshot {
    return {
      selection: this.currentSelection ? cloneSelection(this.currentSelection) : null,
      highlight: this.chunkRenderer.getTargetHighlightSnapshot(),
      projection: this.currentSelection
        ? serializeOverlayProjection(
            resolveSelectionOverlayProjection(
              this.world.store,
              this.currentSelection.occupiedMicro,
              this.currentSelection.occupiedMacro,
            ),
          )
        : null,
      entityTarget: this.currentEntityTarget ? cloneEntityTarget(this.currentEntityTarget) : null,
      fallbackEntityTarget: this.getFallbackEntityTarget(),
    };
  }

  setSceneRegionOverlayVisible(visible: boolean): void {
    this.sceneRegionOverlay.setVisible(visible);
  }

  setEditPreviewProvider(provider: EditPreviewProvider): void {
    this.editPreviewProvider = provider;
  }

  toggleFieldDebugOverlay(): void {
    this.setFieldDebugOverlayVisible(!this.fieldDebugOverlay.isVisible());
  }

  setFieldDebugOverlayVisible(visible: boolean): void {
    const wasVisible = this.fieldDebugOverlay.isVisible();
    this.fieldDebugOverlay.setVisible(visible);
    if (visible && !wasVisible) {
      this.materializeFieldDebugOverlay();
    } else if (!visible && wasVisible) {
      this.fieldDebugOverlay.clearRenderedState();
    }
  }

  showFieldDebugOverlay(): void {
    this.setFieldDebugOverlayVisible(true);
  }

  getFieldDebugOverlaySnapshot(): FieldDebugOverlaySnapshot {
    return this.fieldDebugOverlay.snapshot();
  }

  setFieldHeatSmokeSource(regionId: number | string, heatEnergyJoulesPerTick: number): void {
    this.fieldDebugOverlay.setRegionHeatSmokeSource(regionId, heatEnergyJoulesPerTick);
  }

  spawnLightningBolt(sourceCoord: FMacroCoord, targetCoord: FMacroCoord): void {
    this.lightningBoltRenderer.strike(sourceCoord, targetCoord);
    this.lightningBoltRenderer.update(performance.now());
  }

  queueLightningBoltOnFieldSnapshot(sourceCoord: FMacroCoord, targetCoord: FMacroCoord): void {
    this.pendingSnapshotLightningBolts.set(lightningBoltKey(sourceCoord, targetCoord), {
      sourceCoord: { ...sourceCoord },
      targetCoord: { ...targetCoord },
    });
  }

  getLightningBoltSnapshot(): LightningBoltRendererSnapshot {
    return this.lightningBoltRenderer.snapshot();
  }

  dispose(): void {
    this.chunkRenderer.dispose();
    this.sceneRegionOverlay.dispose();
    this.fieldDebugOverlay.dispose();
    this.lightningBoltRenderer.dispose();
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

  private updateAvatarTransforms(nowMs: number, dtSecs: number): void {
    this.localDisplay.copy(this.localPlayer.getRenderedPosition());
    this.authorityDisplay.copy(this.localPlayer.getAuthoritativeDisplayPosition());
    this.remoteDisplay.copy(this.remotePlayer.getRenderedPosition());
    this.syncRemoteAvatarMeshes();

    this.localAvatar.position.copy(this.localDisplay);
    this.authorityAvatar.position.copy(this.authorityDisplay);
    this.syncRing.position.set(
      this.localDisplay.x,
      this.localDisplay.y - (AvatarConstants.HalfHeightCm - 1),
      this.localDisplay.z,
    );
    this.syncRing.rotation.z = (nowMs / 1000) * 0.25;
    this.sceneHandles.setCameraFollow(this.localDisplay);
  }

  private materializeFieldDebugOverlay(): void {
    this.fieldDebugOverlay.clearRenderedState();
    for (const msg of this.latestFieldSnapshots.values()) {
      this.fieldDebugOverlay.onFieldSnapshot(msg.snapshot);
    }
  }

  private materializePendingSnapshotLightning(snapshot: FFieldRegionSnapshot): void {
    if (this.pendingSnapshotLightningBolts.size === 0 || !isDischargeFieldSnapshot(snapshot)) {
      return;
    }

    for (const [key, pending] of this.pendingSnapshotLightningBolts) {
      if (!fieldSnapshotContainsEndpoints(snapshot, pending.sourceCoord, pending.targetCoord)) {
        continue;
      }
      this.pendingSnapshotLightningBolts.delete(key);
      this.spawnLightningBolt(pending.sourceCoord, pending.targetCoord);
      this.logger.emit("voxel", "lightning_authorized", {
        source_coord: coordKey(pending.sourceCoord),
        target_coord: coordKey(pending.targetCoord),
        authorization: "field_snapshot",
        region_id: snapshot.regionId,
        tick_count: snapshot.tickCount,
      });
    }
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
      avatar.position.copy(entity.position);
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
}

export function resolveEntityTargetFromCamera(
  entities: RenderedRemoteEntity[],
  camera: Camera,
): EntityTargetSelection | null {
  let best: { entity: RenderedRemoteEntity; score: number } | null = null;
  for (const entity of entities) {
    const score = entityTargetScore(entity, camera);
    if (score === null) {
      continue;
    }
    if (!best || score < best.score) {
      best = { entity, score };
    }
  }
  if (!best) {
    return null;
  }
  return {
    entityId: best.entity.cid,
    macroCoord: macroCoordFromWorldPosition(best.entity.position, MacroWorldSize),
    renderedPosition: vectorSnapshot(best.entity.position),
  };
}

function entityTargetScore(entity: RenderedRemoteEntity, camera: Camera): number | null {
  const center = entity.position;
  const centerScore = projectedCrosshairDistance(center, camera);
  const headScore = projectedCrosshairDistance(
    scratchEntityTargetVector.copy(center).setY(center.y + AvatarConstants.HalfHeightCm),
    camera,
  );
  const feetScore = projectedCrosshairDistance(
    scratchEntityTargetVector.copy(center).setY(center.y - AvatarConstants.HalfHeightCm),
    camera,
  );
  const score = Math.min(
    centerScore ?? Number.POSITIVE_INFINITY,
    headScore ?? Number.POSITIVE_INFINITY,
    feetScore ?? Number.POSITIVE_INFINITY,
  );
  return score <= ENTITY_TARGET_NDC_RADIUS ? score : null;
}

function projectedCrosshairDistance(position: Vector3, camera: Camera): number | null {
  scratchProjectedEntityTarget.copy(position).project(camera);
  if (
    scratchProjectedEntityTarget.z < -1 ||
    scratchProjectedEntityTarget.z > 1 ||
    Math.abs(scratchProjectedEntityTarget.x) > 1 ||
    Math.abs(scratchProjectedEntityTarget.y) > 1
  ) {
    return null;
  }
  return Math.hypot(scratchProjectedEntityTarget.x, scratchProjectedEntityTarget.y);
}

const scratchEntityTargetVector = new Vector3();
const scratchProjectedEntityTarget = new Vector3();

function vectorSnapshot(vector: Vector3): { x: number; y: number; z: number } {
  return { x: vector.x, y: vector.y, z: vector.z };
}

function cloneEntityTarget(target: EntityTargetSelection): EntityTargetSelection {
  return {
    entityId: target.entityId,
    macroCoord: { ...target.macroCoord },
    renderedPosition: { ...target.renderedPosition },
  };
}

function cloneSelection(selection: VoxelRaySelection): VoxelRaySelection {
  return {
    occupiedMacro: { ...selection.occupiedMacro },
    adjacentMacro: { ...selection.adjacentMacro },
    faceNormal: { ...selection.faceNormal },
    ...(selection.occupiedMicro
      ? {
          occupiedMicro: {
            macro: { ...selection.occupiedMicro.macro },
            micro: { ...selection.occupiedMicro.micro },
          },
        }
      : {}),
    ...(selection.adjacentMicro
      ? {
          adjacentMicro: {
            macro: { ...selection.adjacentMicro.macro },
            micro: { ...selection.adjacentMicro.micro },
          },
        }
      : {}),
  };
}

function serializeOverlayProjection(
  projection: VoxelOverlayProjection,
): TargetOverlaySnapshot["projection"] {
  const bounds = projectionBounds(projection);
  return {
    granularity: projection.granularity,
    key: projection.key,
    label: projection.label,
    macro: { ...projection.macro },
    ...(projection.selectedMicro ? { selectedMicro: { ...projection.selectedMicro } } : {}),
    ...(projection.ownerObjectId ? { ownerObjectId: projection.ownerObjectId } : {}),
    ...(projection.prefabInstanceId !== undefined
      ? { prefabInstanceId: projection.prefabInstanceId }
      : {}),
    cellCount: projection.cells.length,
    occupiedSlots: projection.cells.reduce(
      (sum, cell) => sum + countBits(cell.microOccupancyMask),
      0,
    ),
    coveredMacroMin: bounds ? { ...bounds.min } : null,
    coveredMacroMax: bounds ? { ...bounds.max } : null,
  };
}

function projectionBounds(
  projection: VoxelOverlayProjection,
): { min: FMacroCoord; max: FMacroCoord } | null {
  if (projection.cells.length === 0) {
    return null;
  }
  const first = projection.cells[0]!.macro;
  return projection.cells.reduce(
    (acc, cell) => ({
      min: {
        x: Math.min(acc.min.x, cell.macro.x),
        y: Math.min(acc.min.y, cell.macro.y),
        z: Math.min(acc.min.z, cell.macro.z),
      },
      max: {
        x: Math.max(acc.max.x, cell.macro.x),
        y: Math.max(acc.max.y, cell.macro.y),
        z: Math.max(acc.max.z, cell.macro.z),
      },
    }),
    { min: { ...first }, max: { ...first } },
  );
}

function countBits(mask: bigint): number {
  let count = 0;
  let remaining = mask;
  while (remaining !== 0n) {
    remaining &= remaining - 1n;
    count += 1;
  }
  return count;
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

function lightningBoltKey(sourceCoord: FMacroCoord, targetCoord: FMacroCoord): string {
  return `${coordKey(sourceCoord)}>${coordKey(targetCoord)}`;
}

function isDischargeFieldSnapshot(snapshot: FFieldRegionSnapshot): boolean {
  return Boolean(snapshot.fieldMask & (FieldMask.ElectricPotential | FieldMask.Ionization));
}

function fieldSnapshotContainsEndpoints(
  snapshot: FFieldRegionSnapshot,
  sourceCoord: FMacroCoord,
  targetCoord: FMacroCoord,
): boolean {
  const sourceChunk = chunkCoordForMacro(sourceCoord);
  const targetChunk = chunkCoordForMacro(targetCoord);
  if (
    !sameChunk(sourceChunk, snapshot.chunkCoord) ||
    !sameChunk(targetChunk, snapshot.chunkCoord)
  ) {
    return false;
  }
  const sourceIndex = macroIndexInChunk(sourceCoord, sourceChunk);
  const targetIndex = macroIndexInChunk(targetCoord, targetChunk);
  let hasSource = false;
  let hasTarget = false;
  for (const idx of snapshot.macroIndices) {
    hasSource ||= idx === sourceIndex;
    hasTarget ||= idx === targetIndex;
    if (hasSource && hasTarget) {
      return true;
    }
  }
  return false;
}

function chunkCoordForMacro(coord: FMacroCoord): { cx: number; cy: number; cz: number } {
  return {
    cx: Math.floor(coord.x / VoxelConstants.ChunkSizeX),
    cy: Math.floor(coord.y / VoxelConstants.ChunkSizeY),
    cz: Math.floor(coord.z / VoxelConstants.ChunkSizeZ),
  };
}

function sameChunk(
  a: { cx: number; cy: number; cz: number },
  b: { cx: number; cy: number; cz: number },
): boolean {
  return a.cx === b.cx && a.cy === b.cy && a.cz === b.cz;
}

function macroIndexInChunk(
  coord: FMacroCoord,
  chunkCoord: { cx: number; cy: number; cz: number },
): number {
  const x = coord.x - chunkCoord.cx * VoxelConstants.ChunkSizeX;
  const y = coord.y - chunkCoord.cy * VoxelConstants.ChunkSizeY;
  const z = coord.z - chunkCoord.cz * VoxelConstants.ChunkSizeZ;
  return (
    x + y * VoxelConstants.ChunkSizeX + z * VoxelConstants.ChunkSizeX * VoxelConstants.ChunkSizeY
  );
}

function worldMicroCoordFromTarget(target: {
  macro: FMacroCoord;
  micro: FMicroCoord;
}): FMicroCoord {
  return {
    x: target.macro.x * VoxelConstants.MicroPerMacro + target.micro.x,
    y: target.macro.y * VoxelConstants.MicroPerMacro + target.micro.y,
    z: target.macro.z * VoxelConstants.MicroPerMacro + target.micro.z,
  };
}
