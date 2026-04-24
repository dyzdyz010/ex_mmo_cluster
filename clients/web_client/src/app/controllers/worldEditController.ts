import { getMaterialDefinition, VoxelMaterialId } from "../../material/catalog";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { EVoxelRotation, type FMacroCoord, type FMicroCoord } from "../../voxel/core/types";
import type { FNormalBlockData } from "../../voxel/storage/types";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";

export interface EditSelection {
  occupiedMacro: FMacroCoord;
  adjacentMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  occupiedMicro?: { macro: FMacroCoord; micro: FMicroCoord };
  adjacentMicro?: { macro: FMacroCoord; micro: FMicroCoord };
}

export interface SelectionProvider {
  getCurrentSelection(): EditSelection | null;
}

export type HotbarEntry =
  | { kind: "material"; label: string; materialId: number }
  | { kind: "prefab"; label: string; prefabName: string; rotation: EVoxelRotation };

export interface HotbarState {
  entries: HotbarEntry[];
  selectedIndex: number;
  selected: HotbarEntry;
}

const HOTBAR_ENTRIES: HotbarEntry[] = [
  { kind: "material", label: "dirt", materialId: VoxelMaterialId.Dirt },
  { kind: "material", label: "stone", materialId: VoxelMaterialId.Stone },
  { kind: "material", label: "wood", materialId: VoxelMaterialId.Wood },
  { kind: "material", label: "ice", materialId: VoxelMaterialId.Ice },
  { kind: "prefab", label: "sphere", prefabName: "builtin_sphere", rotation: EVoxelRotation.Rot0 },
  {
    kind: "prefab",
    label: "cylinder",
    prefabName: "builtin_cylinder",
    rotation: EVoxelRotation.Rot0,
  },
  { kind: "prefab", label: "stairs", prefabName: "builtin_stairs", rotation: EVoxelRotation.Rot0 },
];

/**
 * Handles material selection, block placement, and block removal. The current
 * camera-centre selection is pulled from a SelectionProvider (the render
 * orchestrator) so the controller never needs to know about Three.js.
 */
export class WorldEditController {
  private selectedMaterialId: number = VoxelMaterialId.Dirt;
  private selectedHotbarIndex = 0;

  constructor(
    private readonly bus: EventBus<AppEvents>,
    private readonly world: VoxelWorldAdapter,
    private readonly selection: SelectionProvider,
  ) {
    this.bus.on("input:material-selected", ({ materialId }) => {
      this.applyMaterialSelection(materialId);
    });
    this.bus.on("input:prefab-selected", ({ prefabName }) => this.applyPrefabSelection(prefabName));
    this.bus.on("input:hotbar-cycle", ({ direction, source }) =>
      this.cycleHotbar(direction, source),
    );
    this.bus.on("input:hotbar-select", ({ index, source }) =>
      this.selectHotbarIndex(index, source),
    );
    this.bus.on("input:place-block", ({ source }) => this.placeAtSelection(source));
    this.bus.on("input:break-block", ({ source }) => this.breakAtSelection(source));
  }

  getSelectedMaterialId(): number {
    return this.selectedMaterialId;
  }

  getHotbarState(): HotbarState {
    return {
      entries: HOTBAR_ENTRIES.map((entry) => ({ ...entry })),
      selectedIndex: this.selectedHotbarIndex,
      selected: { ...HOTBAR_ENTRIES[this.selectedHotbarIndex]! },
    };
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

  selectPrefab(prefabName: string, source: string): void {
    this.bus.emit("input:prefab-selected", { prefabName, source });
  }

  selectHotbarIndex(index: number, source: string): void {
    if (!Number.isInteger(index) || index < 0 || index >= HOTBAR_ENTRIES.length) {
      this.bus.emit("world:edit-rejected", { reason: "hotbar_rejected", source });
      return;
    }

    const entry = HOTBAR_ENTRIES[index]!;
    this.selectedHotbarIndex = index;
    if (entry.kind === "material") {
      this.bus.emit("input:material-selected", { materialId: entry.materialId, source });
    } else {
      this.bus.emit("input:prefab-selected", { prefabName: entry.prefabName, source });
    }
  }

  private cycleHotbar(direction: -1 | 1, source: string): void {
    const nextIndex = positiveModulo(this.selectedHotbarIndex + direction, HOTBAR_ENTRIES.length);
    this.selectHotbarIndex(nextIndex, source);
  }

  private placeAtSelection(source: string): void {
    const selection = this.selection.getCurrentSelection();
    if (!selection) {
      this.bus.emit("world:edit-rejected", { reason: "no_selection", source });
      this.world.store.editStats.rejected += 1;
      return;
    }
    const selected = HOTBAR_ENTRIES[this.selectedHotbarIndex]!;
    if (selected.kind === "prefab") {
      this.placePrefabAtSelection(selection, selected.prefabName, selected.rotation, source);
    } else {
      this.placeAt(selection.adjacentMacro, selected.materialId, source);
    }
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

  private placePrefabAt(
    origin: FMacroCoord,
    prefabName: string,
    rotation: EVoxelRotation,
    source: string,
  ): boolean {
    const result = this.world.placePrefab(prefabName, origin, rotation);
    if (result.ok) {
      this.bus.emit("world:prefab-placed", {
        name: prefabName,
        origin,
        placed: result.placed,
        source,
      });
      return true;
    }

    this.bus.emit("world:edit-rejected", {
      reason: result.conflict ? "prefab_conflict" : "prefab_place_rejected",
      source,
    });
    return false;
  }

  private placePrefabAtSelection(
    selection: ReturnType<SelectionProvider["getCurrentSelection"]>,
    prefabName: string,
    rotation: EVoxelRotation,
    source: string,
  ): boolean {
    if (!selection) {
      return false;
    }

    const result = this.world.placePrefabBoundarySnap({
      prefabName,
      hitMacro: selection.occupiedMacro,
      ...(selection.occupiedMicro ? { hitMicro: selection.occupiedMicro.micro } : {}),
      faceNormal: selection.faceNormal,
      rotation,
    });
    if (!result.ok && shouldFallbackToMacroPrefabPlace(result.rejectReason)) {
      return this.placePrefabAt(selection.adjacentMacro, prefabName, rotation, source);
    }
    if (result.ok && result.preview && result.instanceId !== undefined) {
      this.bus.emit("world:prefab-boundary-snap-committed", {
        prefabId: prefabName,
        instanceId: result.instanceId,
        hitMacro: result.preview.hitMacro,
        faceNormal: result.preview.faceNormal,
        anchorMicroCoord: result.preview.anchorMicroCoord ?? { x: 0, y: 0, z: 0 },
        affectedMacroCount: result.preview.affectedMacroCount,
        incomingOccupiedSlots: result.preview.incomingOccupiedSlots,
        overlapSlots: result.preview.overlapSlots,
        contactSlots: result.preview.contactSlots,
        source,
      });
      return true;
    }

    this.bus.emit("world:prefab-boundary-snap-rejected", {
      prefabId: prefabName,
      hitMacro: result.preview?.hitMacro ?? selection.occupiedMacro,
      faceNormal: result.preview?.faceNormal ?? selection.faceNormal,
      anchorMicroCoord: result.preview?.anchorMicroCoord ?? null,
      affectedMacroCount: result.preview?.affectedMacroCount ?? 0,
      incomingOccupiedSlots: result.preview?.incomingOccupiedSlots ?? 0,
      overlapSlots: result.preview?.overlapSlots ?? 0,
      contactSlots: result.preview?.contactSlots ?? 0,
      rejectReason: result.rejectReason ?? "prefab_boundary_snap_rejected",
      source,
    });
    this.bus.emit("world:edit-rejected", {
      reason: result.conflict ? "prefab_overlap_conflict" : "prefab_boundary_snap_rejected",
      source,
    });
    return false;
  }

  private applyMaterialSelection(materialId: number): void {
    this.selectedMaterialId = materialId;
    const index = HOTBAR_ENTRIES.findIndex(
      (entry) => entry.kind === "material" && entry.materialId === materialId,
    );
    if (index !== -1) {
      this.selectedHotbarIndex = index;
    }
  }

  private applyPrefabSelection(prefabName: string): void {
    const index = HOTBAR_ENTRIES.findIndex(
      (entry) => entry.kind === "prefab" && entry.prefabName === prefabName,
    );
    if (index !== -1) {
      this.selectedHotbarIndex = index;
    }
  }
}

function positiveModulo(value: number, divisor: number): number {
  return ((value % divisor) + divisor) % divisor;
}

function shouldFallbackToMacroPrefabPlace(rejectReason: string | undefined): boolean {
  return (
    rejectReason === "no_target_boundary" ||
    rejectReason === "no_contact" ||
    rejectReason === "empty_prefab"
  );
}
