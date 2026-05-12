import { describe, expect, it } from "vitest";
import { CAMERA_MAX_PITCH, CAMERA_MIN_PITCH, clampCameraOrbitPitch } from "./scene";

describe("camera orbit pitch", () => {
  it("allows nearly vertical free orbit above and below the target", () => {
    expect(CAMERA_MIN_PITCH).toBeLessThan(-1.5);
    expect(CAMERA_MAX_PITCH).toBeGreaterThan(1.5);
    expect(clampCameraOrbitPitch(0)).toBe(0);
    expect(clampCameraOrbitPitch(-10)).toBe(CAMERA_MIN_PITCH);
    expect(clampCameraOrbitPitch(10)).toBe(CAMERA_MAX_PITCH);
  });
});
