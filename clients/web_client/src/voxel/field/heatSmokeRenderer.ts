import { BoxGeometry, Color, InstancedMesh, Matrix4, MeshBasicMaterial, Object3D } from "three";
import { HEAT_SMOKE_DEFAULTS, type HeatSmokeSimulation } from "./heatSmokeEffect";

const SMOKE_COLOR = new Color("#8f8f8f");

export interface HeatSmokeRendererOptions {
  maxParticles?: number;
}

export class HeatSmokeRenderer {
  readonly mesh: InstancedMesh;
  private readonly tmpDummy = new Object3D();
  private readonly hiddenMatrix = new Matrix4().makeScale(0, 0, 0);

  constructor(
    private readonly simulation: HeatSmokeSimulation,
    options: HeatSmokeRendererOptions = {},
  ) {
    const maxParticles = options.maxParticles ?? HEAT_SMOKE_DEFAULTS.maxLiveParticles;
    const geometry = new BoxGeometry(1, 1, 1);
    const material = new MeshBasicMaterial({
      color: SMOKE_COLOR,
      transparent: true,
      opacity: 0.36,
      depthTest: true,
      depthWrite: false,
    });

    this.mesh = new InstancedMesh(geometry, material, maxParticles);
    this.mesh.name = "heat-smoke-particles";
    this.mesh.count = 0;
    this.mesh.frustumCulled = false;
    this.mesh.renderOrder = 6;
    for (let i = 0; i < maxParticles; i++) {
      this.mesh.setMatrixAt(i, this.hiddenMatrix);
    }
    this.mesh.instanceMatrix.needsUpdate = true;
  }

  syncFromSimulation(): void {
    const particles = this.simulation.liveParticles();
    const cap = Math.min(particles.length, this.mesh.instanceMatrix.array.length / 16);

    for (let i = 0; i < cap; i++) {
      const particle = particles[i]!;
      const ageRatio = Math.max(0, Math.min(1, particle.ageMs / particle.lifetimeMs));
      const scale = particle.sizeWorld * (1 + ageRatio * 1.45);
      this.tmpDummy.position.set(particle.x, particle.y, particle.z);
      this.tmpDummy.rotation.set(0, ageRatio * Math.PI, 0);
      this.tmpDummy.scale.set(scale, scale, scale);
      this.tmpDummy.updateMatrix();
      this.mesh.setMatrixAt(i, this.tmpDummy.matrix);
    }

    for (let i = cap; i < this.mesh.count; i++) {
      this.mesh.setMatrixAt(i, this.hiddenMatrix);
    }

    this.mesh.count = cap;
    this.mesh.instanceMatrix.needsUpdate = true;
  }

  dispose(): void {
    this.mesh.geometry.dispose();
    if (Array.isArray(this.mesh.material)) {
      this.mesh.material.forEach((material) => material.dispose());
    } else {
      this.mesh.material.dispose();
    }
  }
}
