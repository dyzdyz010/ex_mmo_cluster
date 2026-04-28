import type { Camera, Object3D } from "three";
import { WebGLRenderer } from "three";
import type { WebGPURenderer } from "three/webgpu";

export type RendererPreference = "auto" | "webgpu" | "webgl";
export type RendererBackendKind = "webgpu" | "webgl";
export type RendererName = "WebGPURenderer" | "WebGLRenderer";

export interface RendererDebugSnapshot {
  requested: RendererPreference;
  active: RendererBackendKind;
  renderer: RendererName;
  backend: string;
  webgpuAvailable: boolean;
  fallbackReason: string | null;
}

interface ThreeRendererLike {
  setPixelRatio(value?: number): void;
  setSize(width: number, height: number, updateStyle?: boolean): void;
  render(scene: Object3D, camera: Camera): void;
  dispose(): void;
}

type WebGPURendererLike = ThreeRendererLike &
  Pick<WebGPURenderer, "init"> & {
    readonly isWebGPURenderer?: true;
    readonly backend?: { constructor?: { name?: string } };
  };

type WebGPURendererParameters = {
  canvas: HTMLCanvasElement;
  antialias: boolean;
};

type WebGPURendererConstructor = new (parameters?: WebGPURendererParameters) => WebGPURendererLike;

type WebGLRendererFactory = (parameters: {
  canvas: HTMLCanvasElement;
  antialias: boolean;
}) => ThreeRendererLike;

export interface RendererBackend {
  readonly renderer: ThreeRendererLike;
  setPixelRatio(value?: number): void;
  setSize(width: number, height: number, updateStyle?: boolean): void;
  render(scene: Object3D, camera: Camera): void;
  dispose(): void;
  getDebugSnapshot(): RendererDebugSnapshot;
}

export interface RendererBackendOptions {
  preference?: RendererPreference;
  isWebGPUAvailable?: () => boolean;
  loadWebGPURenderer?: () => Promise<WebGPURendererConstructor>;
  createWebGLRenderer?: WebGLRendererFactory;
}

export async function createRendererBackend(
  canvas: HTMLCanvasElement,
  options: RendererBackendOptions = {},
): Promise<RendererBackend> {
  const requested = options.preference ?? "auto";
  const webgpuAvailable = (options.isWebGPUAvailable ?? detectWebGPUAvailability)();

  if (requested === "webgl") {
    return createLegacyWebGLBackend({
      canvas,
      requested,
      webgpuAvailable,
      fallbackReason: "forced_webgl",
      ...(options.createWebGLRenderer ? { createWebGLRenderer: options.createWebGLRenderer } : {}),
    });
  }

  try {
    const Renderer = await (options.loadWebGPURenderer ?? loadDefaultWebGPURenderer)();
    const renderer = new Renderer({ canvas, antialias: true });
    await renderer.init();

    const backend = readRendererBackendName(renderer);
    const active = backend.includes("WebGPU") ? "webgpu" : "webgl";
    return wrapRenderer(renderer, {
      requested,
      active,
      renderer: "WebGPURenderer",
      backend,
      webgpuAvailable,
      fallbackReason:
        active === "webgpu" ? null : webgpuFallbackReason(webgpuAvailable, "webgpu_unavailable"),
    });
  } catch (error) {
    return createLegacyWebGLBackend({
      canvas,
      requested,
      webgpuAvailable,
      fallbackReason: `webgpu_renderer_failed:${formatError(error)}`,
      ...(options.createWebGLRenderer ? { createWebGLRenderer: options.createWebGLRenderer } : {}),
    });
  }
}

export function normalizeRendererPreference(value: string | null | undefined): RendererPreference {
  switch (value?.toLowerCase()) {
    case "webgpu":
      return "webgpu";
    case "webgl":
      return "webgl";
    default:
      return "auto";
  }
}

function createLegacyWebGLBackend({
  canvas,
  requested,
  webgpuAvailable,
  fallbackReason,
  createWebGLRenderer = (parameters) => new WebGLRenderer(parameters),
}: {
  canvas: HTMLCanvasElement;
  requested: RendererPreference;
  webgpuAvailable: boolean;
  fallbackReason: string;
  createWebGLRenderer?: WebGLRendererFactory;
}): RendererBackend {
  const renderer = createWebGLRenderer({ canvas, antialias: true });
  return wrapRenderer(renderer, {
    requested,
    active: "webgl",
    renderer: "WebGLRenderer",
    backend: "WebGLRenderer",
    webgpuAvailable,
    fallbackReason,
  });
}

function wrapRenderer(
  renderer: ThreeRendererLike,
  snapshot: RendererDebugSnapshot,
): RendererBackend {
  return {
    renderer,
    setPixelRatio: (value) => renderer.setPixelRatio(value),
    setSize: (width, height, updateStyle) => renderer.setSize(width, height, updateStyle),
    render: (scene, camera) => renderer.render(scene, camera),
    dispose: () => renderer.dispose(),
    getDebugSnapshot: () => ({ ...snapshot }),
  };
}

function detectWebGPUAvailability(): boolean {
  if (typeof window === "undefined" || typeof navigator === "undefined") {
    return false;
  }
  const navigatorWithGPU = navigator as Navigator & { gpu?: unknown };
  return window.isSecureContext !== false && navigatorWithGPU.gpu !== undefined;
}

async function loadDefaultWebGPURenderer(): Promise<WebGPURendererConstructor> {
  const module = await import("three/webgpu");
  return module.WebGPURenderer as WebGPURendererConstructor;
}

function readRendererBackendName(renderer: WebGPURendererLike): string {
  return renderer.backend?.constructor?.name ?? "unknown";
}

function webgpuFallbackReason(webgpuAvailable: boolean, defaultReason: string): string {
  return webgpuAvailable ? defaultReason : "navigator_gpu_unavailable_or_insecure_context";
}

function formatError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
