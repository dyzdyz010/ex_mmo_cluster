// three.js 场景脚手架：摄像机、灯光、一个 ChunkSizeInMacros 的立方网格指示 Chunk 边界。
// Chunk 级 BufferGeometry 构建延后到 voxel/meshing/chunkMesher.ts（W-B 阶段）。

import {
  AmbientLight,
  BoxGeometry,
  Color,
  DirectionalLight,
  GridHelper,
  Mesh,
  MeshStandardMaterial,
  PerspectiveCamera,
  Scene,
  WebGLRenderer,
} from "three";
import { VoxelConstants, MacroWorldSize } from "../voxel/core/constants";

export interface SceneHandles {
  renderer: WebGLRenderer;
  scene: Scene;
  camera: PerspectiveCamera;
  dispose: () => void;
}

export function createScene(canvas: HTMLCanvasElement): SceneHandles {
  const renderer = new WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(window.innerWidth, window.innerHeight, false);

  const scene = new Scene();
  scene.background = new Color(0x202833);

  const chunkExtent = VoxelConstants.ChunkSizeInMacros * MacroWorldSize;
  const camera = new PerspectiveCamera(60, window.innerWidth / window.innerHeight, 1, 10000);
  camera.position.set(chunkExtent * 0.8, chunkExtent * 0.9, chunkExtent * 1.3);
  camera.lookAt(chunkExtent * 0.5, chunkExtent * 0.5, chunkExtent * 0.5);

  const ambient = new AmbientLight(0xffffff, 0.35);
  scene.add(ambient);

  const sun = new DirectionalLight(0xffffff, 0.9);
  sun.position.set(1, 2, 1).normalize();
  scene.add(sun);

  // Chunk 基底网格，用于对齐首个空 Chunk 的坐标系预览。
  const baseGrid = new GridHelper(chunkExtent, VoxelConstants.ChunkSizeInMacros, 0x557799, 0x334455);
  baseGrid.position.set(chunkExtent * 0.5, 0, chunkExtent * 0.5);
  scene.add(baseGrid);

  // W-A 阶段占位立方体：验证 renderer 路径。W-B 上线后会被 chunk mesh 替换。
  const placeholderGeometry = new BoxGeometry(MacroWorldSize, MacroWorldSize, MacroWorldSize);
  const placeholderMaterial = new MeshStandardMaterial({ color: 0x88aacc, roughness: 0.6 });
  const placeholder = new Mesh(placeholderGeometry, placeholderMaterial);
  placeholder.position.set(MacroWorldSize * 0.5, MacroWorldSize * 0.5, MacroWorldSize * 0.5);
  scene.add(placeholder);

  const onResize = () => {
    const w = window.innerWidth;
    const h = window.innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  };
  window.addEventListener("resize", onResize);

  const dispose = () => {
    window.removeEventListener("resize", onResize);
    placeholderGeometry.dispose();
    placeholderMaterial.dispose();
    renderer.dispose();
  };

  return { renderer, scene, camera, dispose };
}
