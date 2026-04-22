import { getMaterialDefinition, VoxelMaterialId } from "../../material/catalog";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FMacroCoord } from "../../voxel/core/types";
import type { FNormalBlockData } from "../../voxel/storage/types";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";

export interface SelectionProvider {
  getCurrentSelection(): { occupiedMacro: FMacroCoord; adjacentMacro: FMacroCoord } | null;
}

/**
 * Handles material selection, block placement, and block removal. The current
 * camera-centre selection is pulled from a SelectionProvider (the render
 * orchestrator) so the controller never needs to know about Three.js.
 */
export class WorldEditController {
  private selectedMaterialId: number = VoxelMaterialId.Dirt;

  constructor(
    private readonly bus: EventBus<AppEvents>,
    private readonly world: VoxelWorldAdapter,
    private readonly selection: SelectionProvider,
  ) {
    this.bus.on("input:material-selected", ({ materialId }) => {
      this.selectedMaterialId = materialId;
    });
    this.bus.on("input:place-block", ({ source }) => this.placeAtSelection(source));
    this.bus.on("input:break-block", ({ source }) => this.breakAtSelection(source));
  }

  getSelectedMaterialId(): number {
    return this.selectedMaterialId;
  }

  /** CLI entrypoint for scripted edits that do not depend on the raycast. */
  placeAt(coord: FMacroCoord, materialId: number, source: string): boolean {
    const block: FNormalBlockData = {
      materialId,
      stateFlags: 0,
      health: getMaterialDefinition(materialId).maxHealth,
      temperatureDelta: 0,
      moistureDelta: 0,
    };
    const ok = this.world.placeBlock(coord, block);
    if (ok) {
      this.bus.emit("world:block-placed", { coord, materialId, source });
    } else {
      this.bus.emit("world:edit-rejected", { reason: "place_rejected", source });
    }
    return ok;
  }

  breakAt(coord: FMacroCoord, source: string): boolean {
    const ok = this.world.breakBlock(coord);
    if (ok) {
      this.bus.emit("world:block-broken", { coord, source });
    } else {
      this.bus.emit("world:edit-rejected", { reason: "break_rejected", source });
    }
    return ok;
  }

  selectMaterial(materialId: number, source: string): void {
    this.bus.emit("input:material-selected", { materialId, source });
  }

  private placeAtSelection(source: string): void {
    const selection = this.selection.getCurrentSelection();
    if (!selection) {
      this.bus.emit("world:edit-rejected", { reason: "no_selection", source });
      this.world.store.editStats.rejected += 1;
      return;
    }
    this.placeAt(selection.adjacentMacro, this.selectedMaterialId, source);
  }

  private breakAtSelection(source: string): void {
    const selection = this.selection.getCurrentSelection();
    if (!selection) {
      this.bus.emit("world:edit-rejected", { reason: "no_selection", source });
      this.world.store.editStats.rejected += 1;
      return;
    }
    this.breakAt(selection.occupiedMacro, source);
  }
}
