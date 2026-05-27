import { describe, expect, it } from "vitest";
import { LocalVoxelWorldAdapter } from "../voxel/worldAdapter";
import { resolveMovementCollisionResolver, resolveRendererPreferenceFrom } from "./bootstrap";

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

  it("does not let server-authoritative prediction use the mirrored client voxel store", () => {
    const world = new ServerAuthoritativeWorld();

    expect(resolveMovementCollisionResolver(world)).toBeNull();
  });
});

class ServerAuthoritativeWorld extends LocalVoxelWorldAdapter {
  override readonly mode = "server-authoritative";
}
