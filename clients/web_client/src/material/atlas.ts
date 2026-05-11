import { getMaterialDefinition, listMaterialDefinitions } from "./catalog";

export const VoxelMaterialAtlasTileSize = 8;
export const VoxelMaterialAtlasColumns = 4;
export const VoxelMaterialAtlasRows = Math.max(
  1,
  Math.ceil(listMaterialDefinitions().length / VoxelMaterialAtlasColumns),
);
export const VoxelMaterialAtlasWidth = VoxelMaterialAtlasColumns * VoxelMaterialAtlasTileSize;
export const VoxelMaterialAtlasHeight = VoxelMaterialAtlasRows * VoxelMaterialAtlasTileSize;

interface UvBounds {
  u0: number;
  v0: number;
  u1: number;
  v1: number;
}

const FACE_UV_CORNERS: readonly [number, number][] = [
  [0, 1],
  [1, 1],
  [1, 0],
  [0, 0],
];

export function materialAtlasFaceUvs(materialId: number): number[] {
  const bounds = materialAtlasUvBounds(materialId);
  const uvs: number[] = [];
  for (const [x, y] of FACE_UV_CORNERS) {
    uvs.push(x === 0 ? bounds.u0 : bounds.u1, y === 0 ? bounds.v0 : bounds.v1);
  }
  return uvs;
}

export function materialAtlasTexelRgba(x: number, y: number): [number, number, number, number] {
  const tileX = Math.floor(x / VoxelMaterialAtlasTileSize);
  const tileY = Math.floor(y / VoxelMaterialAtlasTileSize);
  const tileIndex = tileY * VoxelMaterialAtlasColumns + tileX;
  const definition = listMaterialDefinitions()[tileIndex] ?? listMaterialDefinitions()[0]!;
  const localX = x % VoxelMaterialAtlasTileSize;
  const localY = y % VoxelMaterialAtlasTileSize;
  const brightness = mosaicBrightness(definition.name, localX, localY);
  const tint = mosaicTint(definition.baseColorHex);
  return [
    clampByte(tint.r * brightness),
    clampByte(tint.g * brightness),
    clampByte(tint.b * brightness),
    255,
  ];
}

function materialAtlasUvBounds(materialId: number): UvBounds {
  const index = materialAtlasIndex(materialId);
  const col = index % VoxelMaterialAtlasColumns;
  const row = Math.floor(index / VoxelMaterialAtlasColumns);
  const inset = 0.5;
  return {
    u0: (col * VoxelMaterialAtlasTileSize + inset) / VoxelMaterialAtlasWidth,
    u1: ((col + 1) * VoxelMaterialAtlasTileSize - inset) / VoxelMaterialAtlasWidth,
    v0: (row * VoxelMaterialAtlasTileSize + inset) / VoxelMaterialAtlasHeight,
    v1: ((row + 1) * VoxelMaterialAtlasTileSize - inset) / VoxelMaterialAtlasHeight,
  };
}

function materialAtlasIndex(materialId: number): number {
  const definitions = listMaterialDefinitions();
  const normalized = getMaterialDefinition(materialId).materialId;
  return Math.max(
    0,
    definitions.findIndex((definition) => definition.materialId === normalized),
  );
}

function mosaicBrightness(name: string, x: number, y: number): number {
  switch (name) {
    case "stone":
      return 0.82 + (((x * 5 + y * 3) % 7) / 6) * 0.22;
    case "wood":
      return 0.78 + (((x + Math.floor(y / 2) * 3) % 5) / 4) * 0.26;
    case "ice":
      return 0.86 + (((x ^ y) % 6) / 5) * 0.18;
    default:
      return 0.76 + (((x * 3 + y * 5) % 6) / 5) * 0.24;
  }
}

function mosaicTint(hex: number): { r: number; g: number; b: number } {
  const r = (hex >> 16) & 0xff;
  const g = (hex >> 8) & 0xff;
  const b = hex & 0xff;
  return {
    r: 210 + (r / 255) * 45,
    g: 210 + (g / 255) * 45,
    b: 210 + (b / 255) * 45,
  };
}

function clampByte(value: number): number {
  return Math.max(0, Math.min(255, Math.round(value)));
}
