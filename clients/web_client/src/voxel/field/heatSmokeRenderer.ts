import { BoxGeometry, Color, InstancedMesh, MeshBasicMaterial } from "three";
import { HEAT_SMOKE_DEFAULTS, type HeatSmokeSimulation } from "./heatSmokeEffect";

const SMOKE_COLOR = new Color("#8f8f8f");
const INSTANCE_MATRIX_STRIDE = 16;

export interface HeatSmokeRendererOptions {
  maxParticles?: number;
}

export class HeatSmokeRenderer {
  readonly mesh: InstancedMesh;

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
    this.mesh.visible = false;
    this.mesh.frustumCulled = false;
    this.mesh.renderOrder = 6;
    const matrices = this.mesh.instanceMatrix.array;
    for (let i = 0; i < maxParticles; i++) {
      writeHiddenMatrix(matrices, i);
    }
    this.mesh.instanceMatrix.needsUpdate = true;
  }

  syncFromSimulation(): void {
    const particles = this.simulation.liveParticles();
    const cap = Math.min(particles.length, this.mesh.instanceMatrix.array.length / 16);
    const matrices = this.mesh.instanceMatrix.array;

    for (let i = 0; i < cap; i++) {
      const particle = particles[i]!;
      const ageRatio = Math.max(0, Math.min(1, particle.ageMs / particle.lifetimeMs));
      const scale = particle.sizeWorld * (1 + ageRatio * 1.45);
      writeSmokeMatrix(matrices, i, particle.x, particle.y, particle.z, ageRatio * Math.PI, scale);
    }

    for (let i = cap; i < this.mesh.count; i++) {
      writeHiddenMatrix(matrices, i);
    }

    this.mesh.count = cap;
    this.mesh.visible = cap > 0;
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

function writeSmokeMatrix(
  matrices: ArrayLike<number> & { [index: number]: number },
  index: number,
  x: number,
  y: number,
  z: number,
  rotationY: number,
  scale: number,
): void {
  const offset = index * INSTANCE_MATRIX_STRIDE;
  const c = Math.cos(rotationY) * scale;
  const s = Math.sin(rotationY) * scale;

  matrices[offset] = c;
  matrices[offset + 1] = 0;
  matrices[offset + 2] = -s;
  matrices[offset + 3] = 0;
  matrices[offset + 4] = 0;
  matrices[offset + 5] = scale;
  matrices[offset + 6] = 0;
  matrices[offset + 7] = 0;
  matrices[offset + 8] = s;
  matrices[offset + 9] = 0;
  matrices[offset + 10] = c;
  matrices[offset + 11] = 0;
  matrices[offset + 12] = x;
  matrices[offset + 13] = y;
  matrices[offset + 14] = z;
  matrices[offset + 15] = 1;
}

function writeHiddenMatrix(
  matrices: ArrayLike<number> & { [index: number]: number },
  index: number,
): void {
  const offset = index * INSTANCE_MATRIX_STRIDE;
  matrices[offset] = 0;
  matrices[offset + 1] = 0;
  matrices[offset + 2] = 0;
  matrices[offset + 3] = 0;
  matrices[offset + 4] = 0;
  matrices[offset + 5] = 0;
  matrices[offset + 6] = 0;
  matrices[offset + 7] = 0;
  matrices[offset + 8] = 0;
  matrices[offset + 9] = 0;
  matrices[offset + 10] = 0;
  matrices[offset + 11] = 0;
  matrices[offset + 12] = 0;
  matrices[offset + 13] = 0;
  matrices[offset + 14] = 0;
  matrices[offset + 15] = 1;
}
