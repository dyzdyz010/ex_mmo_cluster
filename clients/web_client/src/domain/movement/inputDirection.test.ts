import { describe, expect, it } from "vitest";
import {
  buildMovementWorldDirection,
  clampUnitVec,
  keysToAxes,
} from "./inputDirection";

describe("keysToAxes", () => {
  it("returns zero when no keys are pressed", () => {
    const axes = keysToAxes({ forward: false, backward: false, left: false, right: false });
    expect(axes).toEqual({ strafe: 0, forward: 0 });
  });

  it("returns unit forward when only forward is pressed", () => {
    const axes = keysToAxes({ forward: true, backward: false, left: false, right: false });
    expect(axes).toEqual({ strafe: 0, forward: 1 });
  });

  it("opposing keys cancel out", () => {
    const axes = keysToAxes({ forward: true, backward: true, left: true, right: true });
    expect(axes).toEqual({ strafe: 0, forward: 0 });
  });
});

describe("clampUnitVec", () => {
  it("passes through vectors with length <= 1", () => {
    expect(clampUnitVec({ x: 0.6, y: 0.6 }).x).toBeCloseTo(0.6);
    expect(clampUnitVec({ x: 0.6, y: 0.6 }).y).toBeCloseTo(0.6);
  });

  it("scales vectors longer than 1 to unit length", () => {
    const v = clampUnitVec({ x: 3, y: 4 });
    const length = Math.hypot(v.x, v.y);
    expect(length).toBeCloseTo(1);
    expect(v.x).toBeCloseTo(0.6);
    expect(v.y).toBeCloseTo(0.8);
  });

  it("returns zero for zero input", () => {
    expect(clampUnitVec({ x: 0, y: 0 })).toEqual({ x: 0, y: 0 });
  });
});

describe("buildMovementWorldDirection", () => {
  it("returns zero for zero axes regardless of yaw", () => {
    const v = buildMovementWorldDirection({ strafe: 0, forward: 0 }, 1.5);
    expect(v.x).toBeCloseTo(0);
    expect(v.y).toBeCloseTo(0);
  });

  it("yaw=0 → forward axis maps to -z world", () => {
    const v = buildMovementWorldDirection({ strafe: 0, forward: 1 }, 0);
    expect(v.x).toBeCloseTo(0);
    expect(v.y).toBeCloseTo(-1);
  });

  it("yaw=0 → strafe axis maps to +x world", () => {
    const v = buildMovementWorldDirection({ strafe: 1, forward: 0 }, 0);
    expect(v.x).toBeCloseTo(1);
    expect(v.y).toBeCloseTo(0);
  });
});
