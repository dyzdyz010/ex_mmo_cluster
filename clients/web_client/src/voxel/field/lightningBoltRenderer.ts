import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  DynamicDrawUsage,
  Group,
  LineBasicMaterial,
  LineSegments,
} from "three";
import { MacroWorldSize } from "../core/constants";
import type { FMacroCoord } from "../core/types";
import { macroCenterWorldPosition } from "../core/gridUtils";

interface LightningBoltRendererOptions {
  maxSegments?: number;
  maxBolts?: number;
  ttlMs?: number;
}

interface ActiveBolt {
  source: { x: number; y: number; z: number };
  target: { x: number; y: number; z: number };
  startedAtMs: number;
  ttlMs: number;
  seed: number;
}

export interface LightningBoltRendererSnapshot {
  activeBolts: number;
  visibleSegments: number;
  maxSegments: number;
}

const DEFAULT_MAX_SEGMENTS = 512;
const DEFAULT_MAX_BOLTS = 6;
const DEFAULT_TTL_MS = 480;
const MAIN_SEGMENTS_PER_BOLT = 18;
const BRANCH_COUNT = 2;
const BRANCH_SEGMENTS = 4;

export class LightningBoltRenderer {
  readonly group = new Group();
  private readonly maxSegments: number;
  private readonly maxBolts: number;
  private readonly ttlMs: number;
  private readonly positions: Float32Array;
  private readonly positionAttribute: BufferAttribute;
  private readonly geometry: BufferGeometry;
  private readonly material: LineBasicMaterial;
  private readonly line: LineSegments;
  private readonly activeBolts: ActiveBolt[] = [];
  private visibleSegments = 0;

  constructor(options: LightningBoltRendererOptions = {}) {
    this.maxSegments = Math.max(1, Math.floor(options.maxSegments ?? DEFAULT_MAX_SEGMENTS));
    this.maxBolts = Math.max(1, Math.floor(options.maxBolts ?? DEFAULT_MAX_BOLTS));
    this.ttlMs = Math.max(1, Math.floor(options.ttlMs ?? DEFAULT_TTL_MS));
    this.positions = new Float32Array(this.maxSegments * 2 * 3);
    this.positionAttribute = new BufferAttribute(this.positions, 3);
    this.positionAttribute.setUsage(DynamicDrawUsage);
    this.geometry = new BufferGeometry();
    this.geometry.setAttribute("position", this.positionAttribute);
    this.geometry.setDrawRange(0, 0);
    this.material = new LineBasicMaterial({
      color: 0x99ddff,
      transparent: true,
      opacity: 0.95,
      depthWrite: false,
      blending: AdditiveBlending,
    });
    this.line = new LineSegments(this.geometry, this.material);
    this.line.name = "entity-lightning-bolts";
    this.line.frustumCulled = false;
    this.group.name = "lightning-bolt-renderer";
    this.group.visible = false;
    this.group.add(this.line);
  }

  strike(sourceCoord: FMacroCoord, targetCoord: FMacroCoord, nowMs = performance.now()): void {
    const source = macroCenterWorldPosition(sourceCoord, MacroWorldSize);
    const target = macroCenterWorldPosition(targetCoord, MacroWorldSize);
    this.activeBolts.push({
      source,
      target,
      startedAtMs: nowMs,
      ttlMs: this.ttlMs,
      seed: boltSeed(sourceCoord, targetCoord, nowMs),
    });
    if (this.activeBolts.length > this.maxBolts) {
      this.activeBolts.splice(0, this.activeBolts.length - this.maxBolts);
    }
  }

  update(nowMs = performance.now()): void {
    let writeSegment = 0;
    let maxAlpha = 0;
    for (let index = this.activeBolts.length - 1; index >= 0; index -= 1) {
      const bolt = this.activeBolts[index]!;
      const ageMs = nowMs - bolt.startedAtMs;
      if (ageMs >= bolt.ttlMs) {
        this.activeBolts.splice(index, 1);
        continue;
      }
      const life = Math.max(0, 1 - ageMs / bolt.ttlMs);
      maxAlpha = Math.max(maxAlpha, life);
      writeSegment = this.writeBoltSegments(bolt, ageMs, writeSegment);
      if (writeSegment >= this.maxSegments) {
        break;
      }
    }

    this.visibleSegments = writeSegment;
    this.geometry.setDrawRange(0, this.visibleSegments * 2);
    this.positionAttribute.needsUpdate = this.visibleSegments > 0;
    this.group.visible = this.visibleSegments > 0;
    this.material.opacity = 0.25 + maxAlpha * 0.7;
  }

  snapshot(): LightningBoltRendererSnapshot {
    return {
      activeBolts: this.activeBolts.length,
      visibleSegments: this.visibleSegments,
      maxSegments: this.maxSegments,
    };
  }

  dispose(): void {
    this.geometry.dispose();
    this.material.dispose();
    this.activeBolts.splice(0, this.activeBolts.length);
    this.visibleSegments = 0;
    this.group.clear();
  }

  private writeBoltSegments(bolt: ActiveBolt, ageMs: number, writeSegment: number): number {
    const dx = bolt.target.x - bolt.source.x;
    const dy = bolt.target.y - bolt.source.y;
    const dz = bolt.target.z - bolt.source.z;
    const length = Math.hypot(dx, dy, dz) || 1;
    const flicker = Math.floor(ageMs / 28);
    const jitterScale = Math.min(55, Math.max(14, length * 0.06));

    let previous = pointOnBolt(bolt, 0, 0, jitterScale, flicker);
    for (let index = 1; index <= MAIN_SEGMENTS_PER_BOLT; index += 1) {
      if (writeSegment >= this.maxSegments) return writeSegment;
      const t = index / MAIN_SEGMENTS_PER_BOLT;
      const next = pointOnBolt(bolt, t, index, jitterScale, flicker);
      this.writeSegment(writeSegment, previous, next);
      writeSegment += 1;
      previous = next;
    }

    for (let branch = 0; branch < BRANCH_COUNT; branch += 1) {
      const startT = 0.28 + branch * 0.24;
      let branchStart = pointOnBolt(
        bolt,
        startT,
        MAIN_SEGMENTS_PER_BOLT + branch,
        jitterScale,
        flicker,
      );
      const branchLength = length * (0.14 + branch * 0.04);
      const branchSign = branch % 2 === 0 ? 1 : -1;
      for (let index = 1; index <= BRANCH_SEGMENTS; index += 1) {
        if (writeSegment >= this.maxSegments) return writeSegment;
        const branchT = index / BRANCH_SEGMENTS;
        const next = {
          x:
            branchStart.x +
            branchSign * branchLength * 0.18 +
            branchSign * branchT * branchLength * 0.12,
          y: branchStart.y - branchT * branchLength * 0.18,
          z: branchStart.z + branchT * branchLength * 0.22,
        };
        this.writeSegment(writeSegment, branchStart, next);
        writeSegment += 1;
        branchStart = next;
      }
    }
    return writeSegment;
  }

  private writeSegment(
    segmentIndex: number,
    start: { x: number; y: number; z: number },
    end: { x: number; y: number; z: number },
  ): void {
    const offset = segmentIndex * 6;
    this.positions[offset] = start.x;
    this.positions[offset + 1] = start.y;
    this.positions[offset + 2] = start.z;
    this.positions[offset + 3] = end.x;
    this.positions[offset + 4] = end.y;
    this.positions[offset + 5] = end.z;
  }
}

function pointOnBolt(
  bolt: ActiveBolt,
  t: number,
  index: number,
  jitterScale: number,
  flicker: number,
): { x: number; y: number; z: number } {
  if (t <= 0) return bolt.source;
  if (t >= 1) return bolt.target;
  const dx = bolt.target.x - bolt.source.x;
  const dy = bolt.target.y - bolt.source.y;
  const dz = bolt.target.z - bolt.source.z;
  const length = Math.hypot(dx, dy, dz) || 1;
  const invLength = 1 / length;
  const nx = dx * invLength;
  const ny = dy * invLength;
  const nz = dz * invLength;
  const px = Math.abs(ny) < 0.9 ? 0 : 1;
  const py = Math.abs(ny) < 0.9 ? 1 : 0;
  const pz = 0;
  const qx = ny * pz - nz * py;
  const qy = nz * px - nx * pz;
  const qz = nx * py - ny * px;
  const qLength = Math.hypot(qx, qy, qz) || 1;
  const edgeFade = Math.sin(Math.PI * t);
  const jitterA = (hashUnit(bolt.seed + index * 131 + flicker * 17) - 0.5) * jitterScale * edgeFade;
  const jitterB = (hashUnit(bolt.seed + index * 197 + flicker * 31) - 0.5) * jitterScale * edgeFade;

  return {
    x: bolt.source.x + dx * t + px * jitterA + (qx / qLength) * jitterB,
    y: bolt.source.y + dy * t + py * jitterA + (qy / qLength) * jitterB,
    z: bolt.source.z + dz * t + pz * jitterA + (qz / qLength) * jitterB,
  };
}

function boltSeed(source: FMacroCoord, target: FMacroCoord, nowMs: number): number {
  return (
    (source.x * 73856093) ^
    (source.y * 19349663) ^
    (source.z * 83492791) ^
    (target.x * 2654435761) ^
    (target.y * 805459861) ^
    (target.z * 367465342) ^
    Math.floor(nowMs)
  );
}

function hashUnit(value: number): number {
  let hash = value | 0;
  hash ^= hash << 13;
  hash ^= hash >>> 17;
  hash ^= hash << 5;
  return ((hash >>> 0) % 10000) / 10000;
}
