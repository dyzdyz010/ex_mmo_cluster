// Phase 4-bis Step 4-bis-12: DebrisRenderer.
//
// THREE.js wrapper that turns DebrisSimulation's particle array into a
// single InstancedMesh draw call. Designed to attach into the world root
// group used by RenderOrchestrator.
//
// Each particle is a small棕色立方体 (0.05 m / 5 cm,渲染尺度按 MacroWorldSize
// 100 cm/macro 等比放大,即 5 个世界单位)。颜色在 `#8B4513` 到 `#A0522D` 间
// 用 InstancedColor 随机微抖。

import {
  BoxGeometry,
  Color,
  InstancedMesh,
  Matrix4,
  MeshStandardMaterial,
  Object3D,
} from "three";
import { MacroWorldSize } from "./core/constants";
import { DEBRIS_DEFAULTS, type DebrisSimulation } from "./debrisEffect";

const DEFAULT_PARTICLE_SIZE_WORLD = DEBRIS_DEFAULTS.particleSizeM * MacroWorldSize; // 5
const DEFAULT_MAX_PARTICLES = DEBRIS_DEFAULTS.maxLiveParticles; // 500
const DEBRIS_BASE_COLOR = new Color("#8b4513");
const DEBRIS_BRIGHT_COLOR = new Color("#a0522d");

export interface DebrisRendererOptions {
  particleSizeWorld?: number;
  maxParticles?: number;
}

export class DebrisRenderer {
  readonly mesh: InstancedMesh;
  private readonly tmpDummy = new Object3D();
  private readonly tmpMatrix = new Matrix4();
  private readonly hiddenMatrix: Matrix4;

  constructor(
    private readonly simulation: DebrisSimulation,
    options: DebrisRendererOptions = {},
  ) {
    const particleSize = options.particleSizeWorld ?? DEFAULT_PARTICLE_SIZE_WORLD;
    const maxParticles = options.maxParticles ?? DEFAULT_MAX_PARTICLES;

    const geometry = new BoxGeometry(particleSize, particleSize, particleSize);
    const material = new MeshStandardMaterial({
      color: DEBRIS_BASE_COLOR,
      roughness: 0.85,
      metalness: 0.0,
      vertexColors: false,
    });

    this.mesh = new InstancedMesh(geometry, material, maxParticles);
    this.mesh.count = 0;
    this.mesh.frustumCulled = false;
    this.mesh.castShadow = false;
    this.mesh.receiveShadow = false;

    // A matrix at very-far Y so unused instances don't accidentally render
    // inside the world. We set count instead for the steady state.
    this.hiddenMatrix = new Matrix4().makeTranslation(0, -1e6, 0);

    // Initialize all matrices to hidden so frustum doesn't pick a stale
    // identity transform if `count` later grows past previously-touched
    // instance slots.
    for (let i = 0; i < maxParticles; i++) {
      this.mesh.setMatrixAt(i, this.hiddenMatrix);
    }
    this.mesh.instanceMatrix.needsUpdate = true;
  }

  syncFromSimulation(): void {
    const particles = this.simulation.liveParticles();
    const count = Math.min(particles.length, this.mesh.count > 0 ? Number.MAX_SAFE_INTEGER : 1e9);
    const cap = Math.min(particles.length, this.mesh.instanceMatrix.array.length / 16);

    for (let i = 0; i < cap; i++) {
      const p = particles[i]!;
      this.tmpDummy.position.set(p.x * MacroWorldSize, p.y * MacroWorldSize, p.z * MacroWorldSize);
      this.tmpDummy.rotation.set(0, 0, 0);
      this.tmpDummy.updateMatrix();
      this.mesh.setMatrixAt(i, this.tmpDummy.matrix);
    }

    // Hide overflow slots beyond cap so they don't carry stale transforms.
    for (let i = cap; i < this.mesh.count; i++) {
      this.mesh.setMatrixAt(i, this.hiddenMatrix);
    }

    this.mesh.count = cap;
    this.mesh.instanceMatrix.needsUpdate = true;
    void count;

    // Tint:keep base brown for now;per-instance colour variation needs
    // mesh.instanceColor plumbing,deferred to Phase 5+。
    void DEBRIS_BRIGHT_COLOR;
  }

  dispose(): void {
    this.mesh.geometry.dispose();
    if (Array.isArray(this.mesh.material)) {
      for (const m of this.mesh.material) m.dispose();
    } else {
      this.mesh.material.dispose();
    }
  }
}
