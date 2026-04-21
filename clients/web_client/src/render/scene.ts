import {
  AmbientLight,
  Color,
  DirectionalLight,
  Fog,
  GridHelper,
  Group,
  HemisphereLight,
  PerspectiveCamera,
  Scene,
  Vector3,
  WebGLRenderer,
} from "three";
import { MacroWorldSize, VoxelConstants } from "../voxel/core/constants";

export interface SceneHandles {
  renderer: WebGLRenderer;
  scene: Scene;
  camera: PerspectiveCamera;
  worldRoot: Group;
  setCameraFollow: (target: Vector3, facing: Vector3) => void;
  update: (dtSecs: number) => void;
  dispose: () => void;
}

export function createScene(canvas: HTMLCanvasElement): SceneHandles {
  const renderer = new WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(window.innerWidth, window.innerHeight, false);

  const scene = new Scene();
  scene.background = new Color(0x101922);
  scene.fog = new Fog(0x101922, 2200, 7800);

  const chunkExtent = VoxelConstants.ChunkSizeInMacros * MacroWorldSize * 2;
  const camera = new PerspectiveCamera(60, window.innerWidth / window.innerHeight, 1, 10000);
  camera.position.set(chunkExtent * 0.35, 480, chunkExtent * 0.35);
  camera.lookAt(0, 140, 0);

  const cameraFollowTarget = new Vector3(0, 140, 0);
  const cameraFacing = new Vector3(0, 0, 1);
  const currentLookAt = new Vector3(0, 140, 0);
  const currentCameraPosition = camera.position.clone();

  const ambient = new AmbientLight(0xffffff, 0.25);
  scene.add(ambient);

  const hemi = new HemisphereLight(0xbfe2ff, 0x11161d, 0.55);
  scene.add(hemi);

  const sun = new DirectionalLight(0xfff2d1, 1.25);
  sun.position.set(1.2, 1.8, 0.7).normalize();
  scene.add(sun);

  const baseGrid = new GridHelper(chunkExtent * 6, VoxelConstants.ChunkSizeInMacros * 6, 0x436072, 0x203543);
  scene.add(baseGrid);

  const worldRoot = new Group();
  worldRoot.name = "world-root";
  scene.add(worldRoot);

  const onResize = () => {
    const w = window.innerWidth;
    const h = window.innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  };
  window.addEventListener("resize", onResize);

  const setCameraFollow = (target: Vector3, facing: Vector3) => {
    cameraFollowTarget.copy(target);
    if (facing.lengthSq() > 1e-4) {
      cameraFacing.copy(facing).normalize();
    }
  };

  const update = (dtSecs: number) => {
    const lookAtTarget = cameraFollowTarget.clone().add(new Vector3(0, 110, 0));
    const desiredPosition = lookAtTarget
      .clone()
      .add(cameraFacing.clone().multiplyScalar(-340))
      .add(new Vector3(0, 220, 0));

    const lerpAlpha = 1 - Math.exp(-Math.max(dtSecs, 0) * 8);
    currentLookAt.lerp(lookAtTarget, lerpAlpha);
    currentCameraPosition.lerp(desiredPosition, lerpAlpha);
    camera.position.copy(currentCameraPosition);
    camera.lookAt(currentLookAt);
  };

  const dispose = () => {
    window.removeEventListener("resize", onResize);
    renderer.dispose();
  };

  return { renderer, scene, camera, worldRoot, setCameraFollow, update, dispose };
}
