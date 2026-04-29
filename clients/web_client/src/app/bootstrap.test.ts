import { describe, expect, it } from "vitest";
import { resolveRendererPreferenceFrom } from "./bootstrap";

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
