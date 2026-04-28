import type { FMacroCoord, FMicroCoord } from "../voxel/core/types";

export interface VectorLike {
  x: number;
  y: number;
  z: number;
}

export function formatVector(vector: VectorLike): string {
  return `${vector.x.toFixed(1)},${vector.y.toFixed(1)},${vector.z.toFixed(1)}`;
}

export function formatVectorLike(vector: VectorLike): string {
  return formatVector(vector);
}

export function formatCoord(coord: VectorLike): string {
  return `${coord.x},${coord.y},${coord.z}`;
}

export function formatMicroTarget(target: { macro: FMacroCoord; micro: FMicroCoord }): string {
  return `${formatCoord(target.macro)}:${formatCoord(target.micro)}`;
}

export function summarizeSeries(
  values: number[],
): { min: number; max: number; mean: number } | null {
  if (values.length === 0) {
    return null;
  }
  const min = Math.min(...values);
  const max = Math.max(...values);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return { min, max, mean };
}
