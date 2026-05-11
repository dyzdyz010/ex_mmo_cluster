import { ClampToEdgeWrapping, DataTexture, NearestFilter, RGBAFormat, SRGBColorSpace } from "three";
import {
  materialAtlasTexelRgba,
  VoxelMaterialAtlasHeight,
  VoxelMaterialAtlasWidth,
} from "../material/atlas";

export function createVoxelMaterialMosaicTexture(): DataTexture {
  const data = new Uint8Array(VoxelMaterialAtlasWidth * VoxelMaterialAtlasHeight * 4);
  for (let y = 0; y < VoxelMaterialAtlasHeight; y += 1) {
    for (let x = 0; x < VoxelMaterialAtlasWidth; x += 1) {
      const [r, g, b, a] = materialAtlasTexelRgba(x, y);
      const offset = (y * VoxelMaterialAtlasWidth + x) * 4;
      data[offset] = r;
      data[offset + 1] = g;
      data[offset + 2] = b;
      data[offset + 3] = a;
    }
  }

  const texture = new DataTexture(data, VoxelMaterialAtlasWidth, VoxelMaterialAtlasHeight, RGBAFormat);
  texture.name = "voxel-material-mosaic-atlas";
  texture.magFilter = NearestFilter;
  texture.minFilter = NearestFilter;
  texture.wrapS = ClampToEdgeWrapping;
  texture.wrapT = ClampToEdgeWrapping;
  texture.generateMipmaps = false;
  texture.colorSpace = SRGBColorSpace;
  texture.needsUpdate = true;
  return texture;
}
