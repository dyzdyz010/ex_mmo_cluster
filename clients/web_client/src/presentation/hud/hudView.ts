import type { Vector3 } from "three";
import { getMaterialDefinition } from "../../material/catalog";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";
import type { FrameSubscriber } from "../../app/gameLoop";
import type { FMacroCoord } from "../../voxel/core/types";

/**
 * Pulls display data from every controller once per frame and writes the HUD
 * overlay. Read-only — never mutates controller state.
 */
export class HudView implements FrameSubscriber {
  private frameCount = 0;

  constructor(
    private readonly hud: HTMLDivElement,
    private readonly world: VoxelWorldAdapter,
    private readonly transport: TransportPump,
    private readonly localPlayer: LocalPlayerController,
    private readonly remotePlayer: RemotePlayerController,
    private readonly edit: WorldEditController,
    private readonly render: RenderOrchestrator,
  ) {
    this.hud.textContent = "ex_mmo voxel web-client (booting...)";
  }

  onFrame(): void {
    this.frameCount += 1;
    const currentState = this.localPlayer.getCurrentState();
    const stats = this.localPlayer.getGovernanceStats();
    const selection = this.render.getCurrentSelection();
    const selectedMaterialId = this.edit.getSelectedMaterialId();
    const transportSnapshot = {
      voxelSync: this.world.mode,
      movementTransport: this.transport.debugSnapshot(),
    };
    const selectionText = selection
      ? `${formatCoord(selection.occupiedMacro)} -> ${formatCoord(selection.adjacentMacro)}`
      : "n/a";

    this.hud.textContent = [
      `ex_mmo voxel web-client  frame: ${this.frameCount}`,
      `voxel_sync: ${this.world.mode}  movement_transport: ${this.transport.getMode()}`,
      `movement_ready: ${this.transport.isReady()}  transport_state: ${JSON.stringify(transportSnapshot)}`,
      `chunks: ${this.world.store.listChunks().length}  solid_blocks: ${this.world.store.totalSolidBlocks()}`,
      `selected_material: ${getMaterialDefinition(selectedMaterialId).name} (${selectedMaterialId})`,
      `selection: ${selectionText}`,
      `player_rendered: ${formatVector(this.localPlayer.getRenderedPosition())}`,
      `player_authority: ${formatVector(this.localPlayer.getAuthoritativePosition())}`,
      `player_tick: ${currentState?.tick ?? 0}  player_seq: ${currentState?.seq ?? 0}`,
      `remote_rendered: ${formatVector(this.remotePlayer.getRenderedPosition())}`,
      `reconcile: corrections=${stats.totalCorrections} replays=${stats.totalReplays} hard_snaps=${stats.totalHardSnaps}`,
      `last_correction=${stats.lastCorrectionDistance.toFixed(2)}  jitter_ms=${this.localPlayer.getCurrentJitterMs().toFixed(2)}  soft=${this.localPlayer.getCurrentSoftPositionError().toFixed(2)}`,
      `edits: placed=${this.world.store.editStats.placed} broken=${this.world.store.editStats.broken} rejected=${this.world.store.editStats.rejected} conflicts=${this.world.store.editStats.conflicts}`,
      "controls: click or drag to orbit camera, wheel zoom, WASD move relative to camera, F place, G break, 1-4 material",
      'cli: window.__voxelCli?.run("snapshot")',
    ].join("\n");
  }
}

function formatVector(vector: Vector3): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}

function formatCoord(coord: FMacroCoord): string {
  return `${coord.x},${coord.y},${coord.z}`;
}
