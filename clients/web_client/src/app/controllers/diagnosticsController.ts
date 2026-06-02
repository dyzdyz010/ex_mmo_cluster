import type { ObserveLog } from "../../observe/logger";
import { formatVector } from "../../shared/runtimeFormat";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController } from "./remotePlayerController";
import type { RenderOrchestrator } from "./renderOrchestrator";
import type { WorldEditController } from "./worldEditController";

const DIAGNOSTICS_INTERVAL_MS = 2000;

/**
 * Emits a periodic diagnostic summary to the observe log. Purely a read-only
 * consumer of other controllers — it never changes game state.
 */
export class DiagnosticsController implements FrameSubscriber {
  private accumulatorMs = 0;

  constructor(
    private readonly logger: ObserveLog,
    private readonly world: VoxelWorldAdapter,
    private readonly localPlayer: LocalPlayerController,
    private readonly remotePlayer: RemotePlayerController,
    private readonly render: RenderOrchestrator,
    private readonly edit: WorldEditController,
  ) {}

  onFrame(_nowMs: number, dtMs: number): void {
    this.accumulatorMs += dtMs;
    if (this.accumulatorMs < DIAGNOSTICS_INTERVAL_MS) return;
    this.accumulatorMs = 0;

    this.logger.emit("diag", "snapshot", {
      chunks: this.world.store.listChunks().length,
      solid_blocks: this.world.store.totalSolidBlocks(),
      player_rendered: formatVector(this.localPlayer.getRenderedPosition()),
      player_authority: formatVector(this.localPlayer.getAuthoritativePosition()),
      player_mode: this.localPlayer.getCurrentState()?.movementMode ?? "unknown",
      player_velocity: formatVector(this.localPlayer.getCurrentState()?.velocity ?? zeroVector()),
      authority_render: JSON.stringify(this.localPlayer.getAuthorityRenderDebugSnapshot()),
      remote_rendered: formatVector(this.remotePlayer.getRenderedPosition()),
      remote_mode: this.remotePlayer.getCurrentMovementMode(),
      remote_count: this.remotePlayer.getVisibleEntityIds().length,
      remote_aoi: JSON.stringify(this.remotePlayer.getDebugSnapshot()),
      remote_clock: JSON.stringify(this.remotePlayer.getClockDebugSnapshot()),
      renderer: this.render.getRendererDebugSnapshot().active,
      renderer_backend: this.render.getRendererDebugSnapshot().backend,
      renderer_fallback_reason: this.render.getRendererDebugSnapshot().fallbackReason ?? "",
      selected_material: this.edit.getSelectedMaterialId(),
    });
  }
}

function zeroVector(): { x: number; y: number; z: number } {
  return { x: 0, y: 0, z: 0 };
}
