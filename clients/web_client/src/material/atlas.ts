import { getMaterialDefinition, listMaterialDefinitions } from "./catalog";

export const VoxelMaterialAtlasTileSize = 16;
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

export interface MaterialAtlasFaceNormal {
  x: number;
  y: number;
  z: number;
}

const FACE_UV_CORNERS: readonly [number, number][] = [
  [0, 1],
  [1, 1],
  [1, 0],
  [0, 0],
];

export function materialAtlasFaceUvs(materialId: number): number[] {
  const bounds = materialAtlasUvBounds(materialId);
  return materialAtlasUvsFromUnitCorners(bounds, FACE_UV_CORNERS);
}

export function materialAtlasFaceUvsForMacroCorners(
  materialId: number,
  normal: MaterialAtlasFaceNormal,
  corners: readonly [number, number, number][],
): number[] {
  const bounds = materialAtlasUvBounds(materialId);
  return materialAtlasUvsFromUnitCorners(
    bounds,
    corners.map((corner) => projectMacroCornerToFaceUv(normal, corner)),
  );
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

function materialAtlasUvsFromUnitCorners(
  bounds: UvBounds,
  corners: readonly [number, number][],
): number[] {
  const uvs: number[] = [];
  for (const [x, y] of corners) {
    uvs.push(lerp(bounds.u0, bounds.u1, x), lerp(bounds.v0, bounds.v1, y));
  }
  return uvs;
}

function projectMacroCornerToFaceUv(
  normal: MaterialAtlasFaceNormal,
  corner: readonly [number, number, number],
): [number, number] {
  if (normal.y !== 0) {
    return [corner[0], corner[2]];
  }
  if (normal.x !== 0) {
    return [corner[2], corner[1]];
  }
  return [corner[0], corner[1]];
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
  const coarseX = Math.floor(x / 4);
  const coarseY = Math.floor(y / 4);
  switch (name) {
    case "dirt":
      return [0.78, 0.92, 0.86, 1.02][(coarseX * 3 + coarseY) % 4]!;
    case "stone":
      return [0.74, 0.86, 0.94, 1.04][(coarseX + coarseY * 2) % 4]!;
    case "wood":
      if (x % 8 === 0 || x % 8 === 7) {
        return 0.7;
      }
      return [0.82, 0.96, 0.88, 1.04][(coarseX + coarseY) % 4]!;
    case "ice":
      if (x === y || x + y === VoxelMaterialAtlasTileSize - 1) {
        return 1.12;
      }
      return [0.88, 1.0, 0.94, 1.08][(coarseX * 2 + coarseY) % 4]!;
    default:
      return [0.8, 0.9, 1.0, 0.86][(coarseX + coarseY) % 4]!;
  }
}

function mosaicTint(hex: number): { r: number; g: number; b: number } {
  const r = (hex >> 16) & 0xff;
  const g = (hex >> 8) & 0xff;
  const b = hex & 0xff;
  return {
    r: r + (255 - r) * 0.62,
    g: g + (255 - g) * 0.62,
    b: b + (255 - b) * 0.62,
  };
}

function lerp(a: number, b: number, amount: number): number {
  return a + (b - a) * amount;
}

function clampByte(value: number): number {
  return Math.max(0, Math.min(255, Math.round(value)));
}
