import { describe, expect, it, vi } from "vitest";
import type { Camera, Object3D } from "three";
import {
  createRendererBackend,
  normalizeRendererPreference,
  type RendererBackendOptions,
} from "./rendererBackend";

class FakeWebGPUBackend {}
class FakeWebGLBackend {}

class FakeRenderer {
  readonly backend: object;
  readonly initSpy = vi.fn<() => Promise<void>>();
  readonly renderSpy = vi.fn<(scene: Object3D, camera: Camera) => void>();
  readonly disposeSpy = vi.fn<() => void>();
  readonly setPixelRatioSpy = vi.fn<(value?: number) => void>();
  readonly setSizeSpy = vi.fn<(width: number, height: number, updateStyle?: boolean) => void>();

  constructor(backend: object, initError?: Error) {
    this.backend = backend;
    this.initSpy.mockImplementation(async () => {
      if (initError) {
        throw initError;
      }
    });
  }

  init(): Promise<void> {
    return this.initSpy();
  }

  render(scene: Object3D, camera: Camera): void {
    this.renderSpy(scene, camera);
  }

  dispose(): void {
    this.disposeSpy();
  }

  setPixelRatio(value?: number): void {
    this.setPixelRatioSpy(value);
  }

  setSize(width: number, height: number, updateStyle?: boolean): void {
    this.setSizeSpy(width, height, updateStyle);
  }
}

function fakeCanvas(): HTMLCanvasElement {
  return {} as HTMLCanvasElement;
}

function optionsWithWebGPU(renderer: FakeRenderer): RendererBackendOptions {
  return {
    isWebGPUAvailable: () => true,
    loadWebGPURenderer: async () =>
      class {
        constructor() {
          return renderer;
        }
      } as never,
  };
}

describe("createRendererBackend", () => {
  it("uses WebGPURenderer when the initialized backend is WebGPU", async () => {
    const fake = new FakeRenderer(new FakeWebGPUBackend());
    const backend = await createRendererBackend(fakeCanvas(), optionsWithWebGPU(fake));

    expect(fake.initSpy).toHaveBeenCalledOnce();
    expect(backend.getDebugSnapshot()).toMatchObject({
      requested: "webgpu",
      active: "webgpu",
      renderer: "WebGPURenderer",
      backend: "FakeWebGPUBackend",
      fallbackReason: null,
    });
  });

  it("reports WebGPURenderer WebGL2 fallback when the initialized backend is WebGL", async () => {
    const fake = new FakeRenderer(new FakeWebGLBackend());
    const backend = await createRendererBackend(fakeCanvas(), optionsWithWebGPU(fake));

    expect(backend.getDebugSnapshot()).toMatchObject({
      requested: "webgpu",
      active: "webgl",
      renderer: "WebGPURenderer",
      backend: "FakeWebGLBackend",
      fallbackReason: "webgpu_unavailable",
    });
  });

  it("falls back to legacy WebGLRenderer when WebGPU initialization fails", async () => {
    const webgpu = new FakeRenderer(new FakeWebGPUBackend(), new Error("adapter missing"));
    const webgl = new FakeRenderer(new FakeWebGLBackend());
    const backend = await createRendererBackend(fakeCanvas(), {
      ...optionsWithWebGPU(webgpu),
      createWebGLRenderer: () => webgl,
    });

    expect(webgpu.initSpy).toHaveBeenCalledOnce();
    expect(backend.getDebugSnapshot()).toMatchObject({
      requested: "webgpu",
      active: "webgl",
      renderer: "WebGLRenderer",
      backend: "WebGLRenderer",
      fallbackReason: "webgpu_renderer_failed:adapter missing",
    });
  });

  it("honors forced WebGL without loading WebGPU", async () => {
    const webgl = new FakeRenderer(new FakeWebGLBackend());
    const loadWebGPURenderer = vi.fn();
    const backend = await createRendererBackend(fakeCanvas(), {
      preference: "webgl",
      loadWebGPURenderer,
      createWebGLRenderer: () => webgl,
    });

    expect(loadWebGPURenderer).not.toHaveBeenCalled();
    expect(backend.getDebugSnapshot()).toMatchObject({
      requested: "webgl",
      active: "webgl",
      renderer: "WebGLRenderer",
      fallbackReason: "forced_webgl",
    });
  });
});

describe("normalizeRendererPreference", () => {
  it("accepts webgpu/webgl and treats unknown values as auto", () => {
    expect(normalizeRendererPreference("webgpu")).toBe("webgpu");
    expect(normalizeRendererPreference("WEBGL")).toBe("webgl");
    expect(normalizeRendererPreference("latest")).toBe("auto");
    expect(normalizeRendererPreference(null)).toBe("auto");
  });
});
