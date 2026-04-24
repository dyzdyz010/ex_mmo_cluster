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

const CAMERA_LOOK_HEIGHT = 110;
const CAMERA_POSITION_SMOOTHING_HZ = 10;
const CAMERA_TARGET_SMOOTHING_HZ = 12;
const CAMERA_YAW_SENSITIVITY = 0.005;
const CAMERA_PITCH_SENSITIVITY = 0.004;
const CAMERA_MIN_PITCH = 0.2;
const CAMERA_MAX_PITCH = 1.15;
const CAMERA_MIN_DISTANCE = 180;
const CAMERA_MAX_DISTANCE = 620;
const CAMERA_SNAP_DISTANCE = 600;

export interface SceneHandles {
  renderer: WebGLRenderer;
  scene: Scene;
  camera: PerspectiveCamera;
  worldRoot: Group;
  getMovementYawRadians: () => number;
  setCameraFollow: (target: Vector3) => void;
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

  const cameraFollowTarget = new Vector3(0, 0, 0);
  const smoothedFollowTarget = new Vector3(0, 0, 0);
  const currentLookAt = new Vector3(0, 140, 0);
  const currentCameraPosition = camera.position.clone();
  const orbitOffset = new Vector3();
  const desiredLookAt = new Vector3();
  const desiredPosition = new Vector3();
  let orbitYaw = Math.PI * 0.25;
  let orbitPitch = 0.58;
  let orbitDistance = 410;
  let cameraAnchored = false;
  let dragActive = false;
  let lastPointerClientX = 0;
  let lastPointerClientY = 0;

  const ambient = new AmbientLight(0xffffff, 0.25);
  scene.add(ambient);

  const hemi = new HemisphereLight(0xbfe2ff, 0x11161d, 0.55);
  scene.add(hemi);

  const sun = new DirectionalLight(0xfff2d1, 1.25);
  sun.position.set(1.2, 1.8, 0.7).normalize();
  scene.add(sun);

  const baseGrid = new GridHelper(
    chunkExtent * 6,
    VoxelConstants.ChunkSizeInMacros * 6,
    0x436072,
    0x203543,
  );
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

  const onPointerDown = (event: PointerEvent) => {
    if (event.button !== 0) {
      return;
    }

    dragActive = true;
    lastPointerClientX = event.clientX;
    lastPointerClientY = event.clientY;

    if (document.pointerLockElement !== canvas) {
      try {
        canvas.requestPointerLock();
      } catch {
        // Some browsers refuse pointer lock; drag fallback still works.
      }
    }
  };

  const onPointerUp = () => {
    if (document.pointerLockElement !== canvas) {
      dragActive = false;
    }
  };

  const onPointerMove = (event: PointerEvent) => {
    const pointerLocked = document.pointerLockElement === canvas;
    if (!pointerLocked && !dragActive) {
      return;
    }

    const deltaX = pointerLocked ? event.movementX : event.clientX - lastPointerClientX;
    const deltaY = pointerLocked ? event.movementY : event.clientY - lastPointerClientY;

    lastPointerClientX = event.clientX;
    lastPointerClientY = event.clientY;

    orbitYaw -= deltaX * CAMERA_YAW_SENSITIVITY;
    orbitPitch = clamp(
      orbitPitch + deltaY * CAMERA_PITCH_SENSITIVITY,
      CAMERA_MIN_PITCH,
      CAMERA_MAX_PITCH,
    );
  };

  const onPointerLeave = () => {
    if (document.pointerLockElement !== canvas) {
      dragActive = false;
    }
  };

  const onPointerLockChange = () => {
    if (document.pointerLockElement !== canvas) {
      dragActive = false;
    }
  };

  const onWheel = (event: WheelEvent) => {
    if (!event.ctrlKey) {
      return;
    }
    event.preventDefault();
    orbitDistance = clamp(
      orbitDistance + event.deltaY * 0.35,
      CAMERA_MIN_DISTANCE,
      CAMERA_MAX_DISTANCE,
    );
  };

  canvas.addEventListener("pointerdown", onPointerDown);
  window.addEventListener("pointerup", onPointerUp);
  window.addEventListener("pointermove", onPointerMove);
  canvas.addEventListener("pointerleave", onPointerLeave);
  document.addEventListener("pointerlockchange", onPointerLockChange);
  canvas.addEventListener("wheel", onWheel, { passive: false });

  const fillOrbitPose = (target: Vector3) => {
    desiredLookAt.set(target.x, target.y + CAMERA_LOOK_HEIGHT, target.z);
    const cosPitch = Math.cos(orbitPitch);
    orbitOffset
      .set(Math.sin(orbitYaw) * cosPitch, Math.sin(orbitPitch), Math.cos(orbitYaw) * cosPitch)
      .multiplyScalar(orbitDistance);
    desiredPosition.copy(desiredLookAt).add(orbitOffset);
  };

  const snapCameraToTarget = (target: Vector3) => {
    fillOrbitPose(target);
    smoothedFollowTarget.copy(target);
    currentLookAt.copy(desiredLookAt);
    currentCameraPosition.copy(desiredPosition);
    camera.position.copy(desiredPosition);
    camera.lookAt(desiredLookAt);
    cameraAnchored = true;
  };

  const setCameraFollow = (target: Vector3) => {
    cameraFollowTarget.copy(target);
    if (!cameraAnchored || smoothedFollowTarget.distanceTo(target) > CAMERA_SNAP_DISTANCE) {
      snapCameraToTarget(target);
    }
  };

  const update = (dtSecs: number) => {
    const targetAlpha = 1 - Math.exp(-Math.max(dtSecs, 0) * CAMERA_TARGET_SMOOTHING_HZ);
    smoothedFollowTarget.lerp(cameraFollowTarget, targetAlpha);
    fillOrbitPose(smoothedFollowTarget);

    const lerpAlpha = 1 - Math.exp(-Math.max(dtSecs, 0) * CAMERA_POSITION_SMOOTHING_HZ);
    currentLookAt.lerp(desiredLookAt, lerpAlpha);
    currentCameraPosition.lerp(desiredPosition, lerpAlpha);
    camera.position.copy(currentCameraPosition);
    camera.lookAt(currentLookAt);
  };

  const dispose = () => {
    window.removeEventListener("resize", onResize);
    canvas.removeEventListener("pointerdown", onPointerDown);
    window.removeEventListener("pointerup", onPointerUp);
    window.removeEventListener("pointermove", onPointerMove);
    canvas.removeEventListener("pointerleave", onPointerLeave);
    document.removeEventListener("pointerlockchange", onPointerLockChange);
    canvas.removeEventListener("wheel", onWheel);
    if (document.pointerLockElement === canvas) {
      document.exitPointerLock();
    }
    renderer.dispose();
  };

  return {
    renderer,
    scene,
    camera,
    worldRoot,
    getMovementYawRadians: () => orbitYaw,
    setCameraFollow,
    update,
    dispose,
  };
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}
