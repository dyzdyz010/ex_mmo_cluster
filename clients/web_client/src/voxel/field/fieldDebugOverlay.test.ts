import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { InstancedMesh, MeshBasicMaterial } from "three";
import { FieldMask, type FFieldRegionSnapshot } from "./fieldProtocol";
import { FieldDebugOverlay } from "./fieldDebugOverlay";

const CELL_COUNT = 4096;
const CENTER_INDEX = 7 + 7 * 16 + 7 * 256;

describe("FieldDebugOverlay", () => {
  beforeEach(() => {
    vi.spyOn(console, "info").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders only the hot plume instead of the whole temperature background", () => {
    const overlay = new FieldDebugOverlay();
    const temps = new Float32Array(CELL_COUNT);
    temps.fill(0.2);
    temps[CENTER_INDEX] = 100;

    overlay.onFieldSnapshot(makeTemperatureSnapshot({ temperatureValues: temps }));

    expect(temperatureMeshCount(overlay)).toBe(1);
  });

  it("suppresses flat warm fields with no visible temperature gradient", () => {
    const overlay = new FieldDebugOverlay();
    const temps = new Float32Array(CELL_COUNT);
    temps.fill(8.5);

    overlay.onFieldSnapshot(makeTemperatureSnapshot({ temperatureValues: temps }));

    expect(temperatureMeshCount(overlay)).toBe(0);
  });

  it("renders sparse server-side temperature anomalies", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        temperatureValues: Float32Array.of(100),
      }),
    );

    expect(temperatureMeshCount(overlay)).toBe(1);
  });

  it("hides unused temperature instance slots so stale buffers cannot flash at the origin", () => {
    const overlay = new FieldDebugOverlay();
    const macroIndices = Uint16Array.from({ length: 10 }, (_value, idx) => CENTER_INDEX + idx);

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 10,
        macroIndices,
        temperatureValues: Float32Array.from({ length: 10 }, () => 50),
      }),
    );

    const maxHotMesh = temperatureMeshes(overlay).find(
      (mesh) => mesh.name === "temperature-hot-0.62",
    );
    if (!maxHotMesh) throw new Error("missing max hot mesh");
    expect(maxHotMesh.count).toBe(10);
    expectVisibleInstance(maxHotMesh, 0);

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        temperatureValues: Float32Array.of(50),
      }),
    );

    expect(maxHotMesh.count).toBe(1);
    expectVisibleInstance(maxHotMesh, 0);
    expectHiddenInstance(maxHotMesh, 1);
    expectHiddenInstance(maxHotMesh, 9);

    for (const mesh of temperatureMeshes(overlay).filter((mesh) =>
      mesh.name.startsWith("temperature-cold-"),
    )) {
      expect(mesh.count).toBe(0);
      expectHiddenInstance(mesh, 0);
    }
  });

  it("renders real-material diffusion deltas below one degree", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 7,
        macroIndices: Uint16Array.of(
          CENTER_INDEX,
          CENTER_INDEX + 1,
          CENTER_INDEX - 1,
          CENTER_INDEX + 16,
          CENTER_INDEX - 16,
          CENTER_INDEX + 256,
          CENTER_INDEX - 256,
        ),
        temperatureValues: Float32Array.of(
          799.99,
          20.0003,
          20.0003,
          20.0003,
          20.0003,
          20.0003,
          20.0003,
        ),
      }),
    );

    expect(temperatureMeshCount(overlay)).toBe(7);
  });

  it("keeps ambient temperature transparent", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        temperatureValues: Float32Array.of(20),
      }),
    );

    expect(temperatureMeshCount(overlay)).toBe(0);
  });

  it("calibrates heat toward red opacity and cold toward purple opacity", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 5,
        macroIndices: Uint16Array.of(
          CENTER_INDEX,
          CENTER_INDEX + 1,
          CENTER_INDEX + 2,
          CENTER_INDEX + 3,
          CENTER_INDEX + 4,
        ),
        temperatureValues: Float32Array.of(50, 34, 26, 22, 18),
      }),
    );

    const cells = temperatureMeshCells(overlay);
    expect(cells).toHaveLength(5);

    const hot = cells.filter((cell) => cell.r > 0.95);
    const cold = cells.filter((cell) => cell.b > 0.95);
    expect(hot).toHaveLength(4);
    expect(cold).toHaveLength(1);
    expect(new Set(hot.map((cell) => cell.opacity.toFixed(2)))).toEqual(
      new Set(["0.28", "0.42", "0.62"]),
    );
    expect(cold[0]!.r).toBeGreaterThan(0.45);
    expect(cold[0]!.opacity).toBeCloseTo(0.28);

    for (const mesh of temperatureMeshes(overlay)) {
      expect(mesh.geometry.getAttribute("instanceOpacity")).toBeUndefined();
    }
  });

  it("can be explicitly shown so heat actions are immediately visible", () => {
    const overlay = new FieldDebugOverlay();

    expect(overlay.isVisible()).toBe(false);
    expect(overlay.rootGroup.visible).toBe(false);

    overlay.show();

    expect(overlay.isVisible()).toBe(true);
    expect(overlay.rootGroup.visible).toBe(true);
    expect(overlay.snapshot()).toMatchObject({ visible: true, regionCount: 0 });
  });
});

function makeTemperatureSnapshot({
  cellCount = CELL_COUNT,
  macroIndices = Uint16Array.from({ length: cellCount }, (_value, idx) => idx),
  temperatureValues,
}: {
  cellCount?: number;
  macroIndices?: Uint16Array;
  temperatureValues: Float32Array;
}): FFieldRegionSnapshot {
  return {
    logicalSceneId: 1,
    chunkCoord: { cx: 0, cy: 0, cz: 0 },
    regionId: 77,
    tickCount: 1,
    fieldMask: FieldMask.Temperature,
    cellCount,
    macroIndices,
    temperatureValues,
    electricValues: new Float32Array(0),
    ionizationValues: new Uint8Array(0),
  };
}

function temperatureMeshCells(
  overlay: FieldDebugOverlay,
): Array<{ r: number; g: number; b: number; opacity: number }> {
  return temperatureMeshes(overlay).flatMap((mesh) => {
    const material = mesh.material;
    if (!(material instanceof MeshBasicMaterial)) {
      throw new Error("unexpected temperature material");
    }
    return Array.from({ length: mesh.count }, () => ({
      r: material.color.r,
      g: material.color.g,
      b: material.color.b,
      opacity: material.opacity,
    }));
  });
}

function temperatureMeshes(overlay: FieldDebugOverlay): InstancedMesh[] {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  const meshes =
    regionGroup?.children.filter(
      (child): child is InstancedMesh =>
        child instanceof InstancedMesh && child.name.startsWith("temperature-"),
    ) ?? [];
  if (meshes.length === 0) {
    throw new Error("missing temperature meshes");
  }
  return meshes;
}

function temperatureMeshCount(overlay: FieldDebugOverlay): number {
  return temperatureMeshes(overlay).reduce((sum, mesh) => sum + mesh.count, 0);
}

function expectVisibleInstance(mesh: InstancedMesh, index: number): void {
  const offset = index * 16;
  const elements = mesh.instanceMatrix.array;
  expect(elements[offset]).toBeCloseTo(1);
  expect(elements[offset + 5]).toBeCloseTo(1);
  expect(elements[offset + 10]).toBeCloseTo(1);
  expect(elements[offset + 15]).toBeCloseTo(1);
}

function expectHiddenInstance(mesh: InstancedMesh, index: number): void {
  const offset = index * 16;
  const elements = mesh.instanceMatrix.array;
  expect(elements[offset]).toBeCloseTo(0);
  expect(elements[offset + 5]).toBeCloseTo(0);
  expect(elements[offset + 10]).toBeCloseTo(0);
  expect(elements[offset + 15]).toBeCloseTo(1);
}
