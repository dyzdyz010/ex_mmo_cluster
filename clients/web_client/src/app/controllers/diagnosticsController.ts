import type { Vector3 } from "three";
import type { ObserveLog } from "../../observe/logger";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { FrameSubscriber } from "../gameLoop";
import type { LocalPlayerController } from "./localPlayerController";
import type { RemotePlayerController } from "./remotePlayerController";
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
      remote_rendered: formatVector(this.remotePlayer.getRenderedPosition()),
      selected_material: this.edit.getSelectedMaterialId(),
    });
  }
}

function formatVector(vector: Vector3): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}
