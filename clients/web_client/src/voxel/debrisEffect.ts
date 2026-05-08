// Phase 4-bis Step 4-bis-9: DebrisEffect.
//
// Decision D6:destroy / part_destroyed / damaged 时在 0x6C 携带的
// affected_chunks 区域(或更精确的 ClearedSlotCache 命中位置)播碎屑
// 粒子。粒子是 0.05m 棕色调小立方体,半球面随机方向 + 中心向外 push,
// 重力 -9.8 m/s²,寿命 0.8s。
//
// 模块拆成两层:
//
//   * **DebrisSimulation**(本文件):纯数据 + 物理积分。可在 vitest
//     里独立测试,不依赖 THREE / DOM / WebGL。
//   * Renderer wrapper(InstancedMesh)在 Step 4-bis-10 串联到
//     onlineVoxelWorldAdapter 时附加:`DebrisRenderer` 持有
//     `THREE.InstancedMesh`,每帧从 simulation 读 particles 同步
//     `setMatrixAt` + `instanceMatrix.needsUpdate = true`。
//
// 拆分理由:
//   * vitest 的 jsdom 环境没 WebGL,直接 new InstancedMesh 不会崩,
//     但断言 visible state 比断言 particles 数组麻烦;simulation 层
//     可以用纯断言。
//   * Step 4-bis-10 把 simulation 接到现有 RenderOrchestrator 主循环,
//     改动集中。
//
// 性能上限:MAX_LIVE_PARTICLES = 500。超出时 spawn 路径 drop 最旧的
// 粒子(粒子数组 head trim)。Step 4-bis-12 浏览器手测如果 mid-spec GPU
// 卡顿,可以改 BURST_SIZE / PARTICLE_LIFETIME_S / 粒子尺寸。

export const DEBRIS_DEFAULTS = {
  burstSize: 8,
  maxLiveParticles: 500,
  particleLifetimeMs: 800,
  particleSizeM: 0.05,
  // Initial outward push (m/s);spawn 时再叠加 0..1 之间的随机系数。
  outwardSpeedMps: 1.5,
  // Random tangential jitter (m/s);0..1 之间随机系数 × 这个上限。
  tangentialSpeedMps: 0.6,
  gravityMps2: -9.8,
} as const;

export interface DebrisSpawnPoint {
  worldX: number;
  worldY: number;
  worldZ: number;
}

export interface DebrisSimulationOptions {
  burstSize?: number;
  maxLiveParticles?: number;
  particleLifetimeMs?: number;
  outwardSpeedMps?: number;
  tangentialSpeedMps?: number;
  gravityMps2?: number;
  // Inject a deterministic random source for tests. Defaults to Math.random.
  random?: () => number;
}

export interface DebrisParticle {
  x: number;
  y: number;
  z: number;
  vx: number;
  vy: number;
  vz: number;
  ageMs: number;
  // Where the particle was spawned, retained for visual variations(rotation
  // seed,colour jitter)later in the renderer wrapper layer.
  seedX: number;
  seedY: number;
  seedZ: number;
}

export type DebrisKind = "damaged" | "part_destroyed" | "destroyed";

export class DebrisSimulation {
  private readonly particles: DebrisParticle[] = [];
  private readonly burstSize: number;
  private readonly maxLiveParticles: number;
  private readonly particleLifetimeMs: number;
  private readonly outwardSpeedMps: number;
  private readonly tangentialSpeedMps: number;
  private readonly gravityMps2: number;
  private readonly random: () => number;

  constructor(options: DebrisSimulationOptions = {}) {
    this.burstSize = options.burstSize ?? DEBRIS_DEFAULTS.burstSize;
    this.maxLiveParticles = options.maxLiveParticles ?? DEBRIS_DEFAULTS.maxLiveParticles;
    this.particleLifetimeMs =
      options.particleLifetimeMs ?? DEBRIS_DEFAULTS.particleLifetimeMs;
    this.outwardSpeedMps = options.outwardSpeedMps ?? DEBRIS_DEFAULTS.outwardSpeedMps;
    this.tangentialSpeedMps =
      options.tangentialSpeedMps ?? DEBRIS_DEFAULTS.tangentialSpeedMps;
    this.gravityMps2 = options.gravityMps2 ?? DEBRIS_DEFAULTS.gravityMps2;
    this.random = options.random ?? Math.random;
  }

  spawn(samplePoints: readonly DebrisSpawnPoint[], _kind: DebrisKind): number {
    let spawned = 0;

    for (const point of samplePoints) {
      for (let i = 0; i < this.burstSize; i++) {
        const particle = this.buildParticle(point);
        this.particles.push(particle);
        spawned += 1;
      }
    }

    // Enforce global cap by trimming oldest particles (head of array).
    if (this.particles.length > this.maxLiveParticles) {
      const overflow = this.particles.length - this.maxLiveParticles;
      this.particles.splice(0, overflow);
    }

    return spawned;
  }

  update(dtMs: number): void {
    if (dtMs <= 0) {
      return;
    }
    const dtS = dtMs / 1000;

    let writeIdx = 0;
    for (let readIdx = 0; readIdx < this.particles.length; readIdx++) {
      const p = this.particles[readIdx]!;
      const newAge = p.ageMs + dtMs;

      if (newAge >= this.particleLifetimeMs) {
        // Drop the particle by skipping the write.
        continue;
      }

      // Symplectic Euler: integrate velocity then position.
      p.vy += this.gravityMps2 * dtS;
      p.x += p.vx * dtS;
      p.y += p.vy * dtS;
      p.z += p.vz * dtS;
      p.ageMs = newAge;

      if (writeIdx !== readIdx) {
        this.particles[writeIdx] = p;
      }
      writeIdx += 1;
    }

    if (writeIdx !== this.particles.length) {
      this.particles.length = writeIdx;
    }
  }

  activeCount(): number {
    return this.particles.length;
  }

  // Test hatch:read-only view of the live particles. Renderer wrapper
  // (Step 4-bis-10)reads this every frame to sync InstancedMesh transforms.
  liveParticles(): readonly DebrisParticle[] {
    return this.particles;
  }

  reset(): void {
    this.particles.length = 0;
  }

  private buildParticle(point: DebrisSpawnPoint): DebrisParticle {
    // Hemisphere-up random direction:y component biased to upward burst.
    const u = this.random();
    const v = this.random();
    const theta = 2 * Math.PI * u;
    // y biased to >= 0 by mapping v ∈ [0, 1] to phi ∈ [0, π/2].
    const phi = (v * Math.PI) / 2;
    const sinPhi = Math.sin(phi);
    const dirX = Math.cos(theta) * sinPhi;
    const dirZ = Math.sin(theta) * sinPhi;
    const dirY = Math.cos(phi);

    const outwardScale = this.outwardSpeedMps * (0.4 + 0.6 * this.random());
    const tangScale = this.tangentialSpeedMps * (this.random() * 2 - 1);

    return {
      x: point.worldX,
      y: point.worldY,
      z: point.worldZ,
      vx: dirX * outwardScale + tangScale,
      vy: dirY * outwardScale,
      vz: dirZ * outwardScale + tangScale,
      ageMs: 0,
      seedX: point.worldX,
      seedY: point.worldY,
      seedZ: point.worldZ,
    };
  }
}
