import { Color } from "three";
import { EVoxelBlockStateFlags } from "../voxel/core/types";
import type { FNormalBlockData } from "../voxel/storage/types";

export const VoxelMaterialId = {
  Dirt: 1,
  Stone: 2,
  Wood: 3,
  Ice: 4,
  Iron: 5,
  PowerBlock: 6,
  LoadBlock: 7,
} as const;

export interface VoxelMaterialDefinition {
  materialId: number;
  name: string;
  baseColorHex: number;
  maxHealth: number;
  flammable: boolean;
}

export interface FVoxelBlockStateView {
  materialId: number;
  stateFlags: number;
  damageRatio: number;
  freezeCoverage: number;
  wetness: number;
  heatLevel: number;
  burnIntensity: number;
}

export interface ResolvedVoxelVisual {
  displayColor: Color;
  label: string;
}

const MATERIAL_DEFINITIONS: readonly VoxelMaterialDefinition[] = [
  {
    materialId: VoxelMaterialId.Dirt,
    name: "dirt",
    baseColorHex: 0x8d6b44,
    maxHealth: 110,
    flammable: false,
  },
  {
    materialId: VoxelMaterialId.Stone,
    name: "stone",
    baseColorHex: 0x8f96a3,
    maxHealth: 180,
    flammable: false,
  },
  {
    materialId: VoxelMaterialId.Wood,
    name: "wood",
    baseColorHex: 0xa86c3f,
    maxHealth: 95,
    flammable: true,
  },
  {
    materialId: VoxelMaterialId.Ice,
    name: "ice",
    baseColorHex: 0xa7d9ff,
    maxHealth: 70,
    flammable: false,
  },
  {
    materialId: VoxelMaterialId.Iron,
    name: "iron",
    baseColorHex: 0x8a9099,
    maxHealth: 220,
    flammable: false,
  },
  {
    materialId: VoxelMaterialId.PowerBlock,
    name: "power_block",
    baseColorHex: 0xffd866,
    maxHealth: 240,
    flammable: false,
  },
  {
    materialId: VoxelMaterialId.LoadBlock,
    name: "load_block",
    baseColorHex: 0x29b6f6,
    maxHealth: 220,
    flammable: false,
  },
] as const;

const DEFAULT_MATERIAL: VoxelMaterialDefinition = MATERIAL_DEFINITIONS[0]!;

function hasStateFlag(stateFlags: number, flag: EVoxelBlockStateFlags): boolean {
  return (stateFlags & flag) !== 0;
}

export function listMaterialDefinitions(): readonly VoxelMaterialDefinition[] {
  return MATERIAL_DEFINITIONS;
}

export function getMaterialDefinition(materialId: number): VoxelMaterialDefinition {
  return (
    MATERIAL_DEFINITIONS.find((definition) => definition.materialId === materialId) ??
    DEFAULT_MATERIAL
  );
}

export function parseMaterialIdOrName(value: string): number | null {
  const numeric = Number.parseInt(value, 10);
  if (Number.isFinite(numeric)) {
    return getMaterialDefinition(numeric).materialId;
  }

  const lowered = value.toLowerCase();
  return MATERIAL_DEFINITIONS.find((definition) => definition.name === lowered)?.materialId ?? null;
}

export function buildBlockStateView(block: FNormalBlockData): FVoxelBlockStateView {
  const definition = getMaterialDefinition(block.materialId);
  const damageRatio =
    definition.maxHealth > 0
      ? Math.max(0, Math.min(1, 1 - block.health / definition.maxHealth))
      : 0;

  const freezeCoverage =
    hasStateFlag(block.stateFlags, EVoxelBlockStateFlags.Frozen) || block.temperatureDelta < -20
      ? 1
      : 0;
  const wetness =
    hasStateFlag(block.stateFlags, EVoxelBlockStateFlags.Wet) || block.moistureDelta > 20
      ? 0.85
      : 0;
  const heatLevel = block.temperatureDelta > 20 ? Math.min(1, block.temperatureDelta / 80) : 0;
  const burnIntensity = hasStateFlag(block.stateFlags, EVoxelBlockStateFlags.Burning)
    ? Math.max(0.4, heatLevel || 0.7)
    : 0;

  return {
    materialId: block.materialId,
    stateFlags: block.stateFlags,
    damageRatio,
    freezeCoverage,
    wetness,
    heatLevel,
    burnIntensity,
  };
}

export function resolveVoxelVisual(view: FVoxelBlockStateView): ResolvedVoxelVisual {
  const definition = getMaterialDefinition(view.materialId);
  const displayColor = new Color(definition.baseColorHex);

  if (view.damageRatio > 0) {
    displayColor.lerp(new Color(0x262220), view.damageRatio * 0.35);
  }
  if (view.wetness > 0) {
    displayColor.lerp(new Color(0x4d708f), view.wetness * 0.2);
  }
  if (view.freezeCoverage > 0) {
    displayColor.lerp(new Color(0xc7ecff), view.freezeCoverage * 0.55);
  }
  if (view.burnIntensity > 0) {
    displayColor.lerp(new Color(0xff6433), view.burnIntensity * 0.45);
  }
  if (hasStateFlag(view.stateFlags, EVoxelBlockStateFlags.Charred)) {
    displayColor.lerp(new Color(0x1f1611), 0.45);
  }

  return {
    displayColor,
    label: definition.name,
  };
}
