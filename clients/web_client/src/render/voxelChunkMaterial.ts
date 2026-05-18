import { MeshStandardMaterial } from "three";
import {
  VoxelMaterialAtlasColumns,
  VoxelMaterialAtlasHeight,
  VoxelMaterialAtlasRows,
  VoxelMaterialAtlasTileSize,
  VoxelMaterialAtlasWidth,
} from "../material/atlas";
import { listMaterialDefinitions, VoxelMaterialId } from "../material/catalog";

const POWER_BLOCK_GLOW_SHADER_VERSION = "power-block-glow-v1";

export function createVoxelChunkMaterial(): MeshStandardMaterial {
  const material = new MeshStandardMaterial({
    vertexColors: true,
    roughness: 0.78,
    metalness: 0.04,
  });

  installPowerBlockGlowShader(material);
  return material;
}

function installPowerBlockGlowShader(material: MeshStandardMaterial): void {
  const bounds = powerBlockAtlasBounds();
  material.userData["powerBlockGlow"] = {
    materialId: VoxelMaterialId.PowerBlock,
    atlasTile: {
      columns: VoxelMaterialAtlasColumns,
      rows: VoxelMaterialAtlasRows,
      tileSize: VoxelMaterialAtlasTileSize,
      ...bounds,
    },
  };

  material.onBeforeCompile = (shader) => {
    shader.fragmentShader = shader.fragmentShader.replace(
      "#include <emissivemap_fragment>",
      `${powerBlockGlowFragment(bounds)}
#include <emissivemap_fragment>`,
    );
  };

  material.customProgramCacheKey = () => POWER_BLOCK_GLOW_SHADER_VERSION;
}

function powerBlockGlowFragment(bounds: ReturnType<typeof powerBlockAtlasBounds>): string {
  return `
#ifdef USE_MAP
float powerBlockGlowMask(vec2 uv) {
  vec2 tileMin = vec2(${formatShaderFloat(bounds.u0)}, ${formatShaderFloat(bounds.v0)});
  vec2 tileMax = vec2(${formatShaderFloat(bounds.u1)}, ${formatShaderFloat(bounds.v1)});
  vec2 insideMin = step(tileMin, uv);
  vec2 insideMax = step(uv, tileMax);
  float tileMask = insideMin.x * insideMin.y * insideMax.x * insideMax.y;
  vec2 tileUv = clamp((uv - tileMin) / max(tileMax - tileMin, vec2(0.00001)), vec2(0.0), vec2(1.0));
  float core = 1.0 - smoothstep(0.0, 0.62, distance(tileUv, vec2(0.5)));
  vec2 mosaicCell = floor(tileUv * ${formatShaderFloat(VoxelMaterialAtlasTileSize)});
  float fleck = step(0.88, fract(sin(dot(mosaicCell, vec2(12.9898, 78.233))) * 43758.5453));
  return tileMask * (0.24 + core * 0.34 + fleck * 0.12);
}
vec3 powerBlockGlowColor = vec3(1.0, 0.78, 0.22) * powerBlockGlowMask(vMapUv);
totalEmissiveRadiance += powerBlockGlowColor;
#endif
`;
}

function powerBlockAtlasBounds(): { u0: number; v0: number; u1: number; v1: number } {
  const index = listMaterialDefinitions().findIndex(
    (definition) => definition.materialId === VoxelMaterialId.PowerBlock,
  );
  const safeIndex = Math.max(0, index);
  const col = safeIndex % VoxelMaterialAtlasColumns;
  const row = Math.floor(safeIndex / VoxelMaterialAtlasColumns);
  const inset = 0.5;
  return {
    u0: (col * VoxelMaterialAtlasTileSize + inset) / VoxelMaterialAtlasWidth,
    u1: ((col + 1) * VoxelMaterialAtlasTileSize - inset) / VoxelMaterialAtlasWidth,
    v0: (row * VoxelMaterialAtlasTileSize + inset) / VoxelMaterialAtlasHeight,
    v1: ((row + 1) * VoxelMaterialAtlasTileSize - inset) / VoxelMaterialAtlasHeight,
  };
}

function formatShaderFloat(value: number): string {
  const fixed = value.toFixed(8).replace(/0+$/, "").replace(/\.$/, "");
  return fixed.includes(".") ? fixed : `${fixed}.0`;
}
