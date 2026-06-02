import { describe, expect, it } from "vitest";
import { LocalVoxelWorldAdapter } from "../voxel/worldAdapter";
import {
  resolveInitialVoxelSubscriptions,
  resolveMovementCollisionResolver,
  resolveRendererPreferenceFrom,
} from "./bootstrap";

describe("resolveRendererPreferenceFrom", () => {
  it("defaults to explicit WebGPU preference", () => {
    expect(resolveRendererPreferenceFrom(null, undefined)).toBe("webgpu");
    expect(resolveRendererPreferenceFrom("", undefined)).toBe("webgpu");
  });

  it("lets query parameters override env preference", () => {
    expect(resolveRendererPreferenceFrom("webgl", "webgpu")).toBe("webgl");
    expect(resolveRendererPreferenceFrom("auto", "webgl")).toBe("auto");
  });

  it("uses env preference when query parameter is absent", () => {
    expect(resolveRendererPreferenceFrom(null, "webgl")).toBe("webgl");
  });
});

describe("resolveMovementCollisionResolver", () => {
  it("keeps local voxel collision for offline prediction", () => {
    const world = new LocalVoxelWorldAdapter();

    expect(resolveMovementCollisionResolver(world)).not.toBeNull();
  });

  it("uses the server-authoritative voxel mirror for local prediction collision", () => {
    const world = new ServerAuthoritativeWorld();

    expect(resolveMovementCollisionResolver(world)).not.toBeNull();
  });
});

describe("resolveInitialVoxelSubscriptions", () => {
  it("uses the configured center radius instead of hard-coding a neighbor chunk", () => {
    expect(resolveInitialVoxelSubscriptions({ x: 0, y: 0, z: 0 }, 2)).toEqual([
      { centerChunk: { x: 0, y: 0, z: 0 }, radiusLInf: 2 },
    ]);
  });
});

class ServerAuthoritativeWorld extends LocalVoxelWorldAdapter {
  override readonly mode = "server-authoritative";
}
