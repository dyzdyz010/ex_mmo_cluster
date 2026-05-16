import { getMaterialDefinition, VoxelMaterialId } from "../../material/catalog";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { VoxelConstants } from "../../voxel/core/constants";
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

const OFFLINE_HOTBAR_ENTRIES: HotbarEntry[] = [
  { kind: "material", label: "dirt", materialId: VoxelMaterialId.Dirt },
  { kind: "material", label: "stone", materialId: VoxelMaterialId.Stone },
  { kind: "material", label: "wood", materialId: VoxelMaterialId.Wood },
  { kind: "material", label: "ice", materialId: VoxelMaterialId.Ice },
  { kind: "material", label: "iron", materialId: VoxelMaterialId.Iron },
  { kind: "prefab", label: "sphere", prefabName: "builtin_sphere", rotation: EVoxelRotation.Rot0 },
  {
    kind: "prefab",
    label: "cylinder",
    prefabName: "builtin_cylinder",
    rotation: EVoxelRotation.Rot0,
  },
  { kind: "prefab", label: "stairs", prefabName: "builtin_stairs", rotation: EVoxelRotation.Rot0 },
];

// Phase A1-1: server-side BlueprintCatalog v2 跟客户端 sphere/cylinder/stairs
// 形状对齐(`onlinePrefabCatalog.ts` blueprint_id 1/2/3),hotbar 不再用旧的
// pillar/floor/cube macro placeholder。两 mode hotbar 统一 prefab 列表。
const SERVER_HOTBAR_ENTRIES: HotbarEntry[] = [
  { kind: "material", label: "dirt", materialId: VoxelMaterialId.Dirt },
  { kind: "material", label: "stone", materialId: VoxelMaterialId.Stone },
  { kind: "material", label: "wood", materialId: VoxelMaterialId.Wood },
  { kind: "material", label: "ice", materialId: VoxelMaterialId.Ice },
  { kind: "material", label: "iron", materialId: VoxelMaterialId.Iron },
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
  private readonly hotbarEntries: HotbarEntry[];

  constructor(
    private readonly bus: EventBus<AppEvents>,
    private readonly world: VoxelWorldAdapter,
    private readonly selection: SelectionProvider,
  ) {
    this.hotbarEntries = hotbarEntriesForWorld(world);
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
    this.bus.on("input:heat-selected-voxel", ({ source, targetTemperatureCelsius }) =>
      this.heatAtSelection(source, targetTemperatureCelsius),
    );
  }

  getSelectedMaterialId(): number {
    return this.selectedMaterialId;
  }

  getHotbarState(): HotbarState {
    return {
      entries: this.hotbarEntries.map((entry) => ({ ...entry })),
      selectedIndex: this.selectedHotbarIndex,
      selected: { ...this.hotbarEntries[this.selectedHotbarIndex]! },
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

  heatAt(
    coord: FMacroCoord,
    targetTemperatureCelsius: number,
    source: string,
    maxTicks?: number,
  ): boolean {
    if (typeof this.world.requestDevHeatVoxel !== "function") {
      this.bus.emit("world:edit-rejected", { reason: "heat_not_supported", source });
      return false;
    }

    const ok = this.world.requestDevHeatVoxel(coord, targetTemperatureCelsius, maxTicks);
    if (ok) {
      this.bus.emit("world:voxel-heated", { coord, targetTemperatureCelsius, source });
    } else {
      this.bus.emit("world:edit-rejected", { reason: "heat_rejected", source });
    }
    return ok;
  }

  heatAtSelection(source: string, targetTemperatureCelsius = 800, maxTicks?: number): boolean {
    const selection = this.selection.getCurrentSelection();
    if (!selection) {
      this.bus.emit("world:edit-rejected", { reason: "no_selection", source });
      this.world.store.editStats.rejected += 1;
      return false;
    }
    return this.heatAt(selection.occupiedMacro, targetTemperatureCelsius, source, maxTicks);
  }

  /** Phase 1c-5: scripted micro-grid place driven by the dev CLI. */
  placeMicroAt(
    macro: FMacroCoord,
    micro: FMicroCoord,
    materialId: number,
    source: string,
  ): boolean {
    const block: FNormalBlockData = {
      materialId,
      stateFlags: 0,
      health: getMaterialDefinition(materialId).maxHealth,
      temperatureDelta: 0,
      moistureDelta: 0,
    };
    const ok = this.world.placeMicroBlock(macro, micro, block);
    if (ok) {
      this.bus.emit("world:micro-placed", { macro, micro, materialId, source });
    } else {
      this.bus.emit("world:edit-rejected", { reason: "micro_place_rejected", source });
    }
    return ok;
  }

  /** Phase 1c-5: scripted micro-grid break driven by the dev CLI. */
  breakMicroAt(macro: FMacroCoord, micro: FMicroCoord, source: string): boolean {
    const ok = this.world.breakMicroBlock(macro, micro);
    if (ok) {
      this.bus.emit("world:micro-broken", { macro, micro, source });
    } else {
      this.bus.emit("world:edit-rejected", { reason: "micro_break_rejected", source });
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
    if (!Number.isInteger(index) || index < 0 || index >= this.hotbarEntries.length) {
      this.bus.emit("world:edit-rejected", { reason: "hotbar_rejected", source });
      return;
    }

    const entry = this.hotbarEntries[index]!;
    this.selectedHotbarIndex = index;
    if (entry.kind === "material") {
      this.bus.emit("input:material-selected", { materialId: entry.materialId, source });
    } else {
      this.bus.emit("input:prefab-selected", { prefabName: entry.prefabName, source });
    }
  }

  private cycleHotbar(direction: -1 | 1, source: string): void {
    const nextIndex = positiveModulo(
      this.selectedHotbarIndex + direction,
      this.hotbarEntries.length,
    );
    this.selectHotbarIndex(nextIndex, source);
  }

  private placeAtSelection(source: string): void {
    const selection = this.selection.getCurrentSelection();
    if (!selection) {
      this.bus.emit("world:edit-rejected", { reason: "no_selection", source });
      this.world.store.editStats.rejected += 1;
      return;
    }
    const selected = this.hotbarEntries[this.selectedHotbarIndex]!;
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
      ...(selection.adjacentMicro
        ? { anchorMicroCoord: worldMicroCoordFromTarget(selection.adjacentMicro) }
        : {}),
      faceNormal: selection.faceNormal,
      rotation,
    });
    if (!result.ok && shouldFallbackToMacroPrefabPlace(result.rejectReason)) {
      this.bus.emit("world:prefab-boundary-snap-fallback", {
        prefabId: prefabName,
        hitMacro: selection.occupiedMacro,
        adjacentMacro: selection.adjacentMacro,
        faceNormal: selection.faceNormal,
        rejectReason: result.rejectReason ?? "prefab_boundary_snap_rejected",
        source,
      });
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
    const index = this.hotbarEntries.findIndex(
      (entry) => entry.kind === "material" && entry.materialId === materialId,
    );
    if (index !== -1) {
      this.selectedHotbarIndex = index;
    }
  }

  private applyPrefabSelection(prefabName: string): void {
    const index = this.hotbarEntries.findIndex(
      (entry) => entry.kind === "prefab" && entry.prefabName === prefabName,
    );
    if (index !== -1) {
      this.selectedHotbarIndex = index;
    } else {
      this.bus.emit("world:edit-rejected", {
        reason: `unknown_prefab:${prefabName}`,
        source: "select_prefab",
      });
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
    rejectReason === "empty_prefab" ||
    rejectReason === "server_authority_not_supported"
  );
}

function hotbarEntriesForWorld(world: VoxelWorldAdapter): HotbarEntry[] {
  const source =
    world.mode === "server-authoritative" ? SERVER_HOTBAR_ENTRIES : OFFLINE_HOTBAR_ENTRIES;
  return source.map((entry) => ({ ...entry }));
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
