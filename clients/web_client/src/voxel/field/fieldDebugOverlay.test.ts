import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { InstancedMesh } from "three";
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

function temperatureMeshCount(overlay: FieldDebugOverlay): number {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  const mesh = regionGroup?.children.find(
    (child): child is InstancedMesh => child instanceof InstancedMesh,
  );
  if (!mesh) {
    throw new Error("missing temperature mesh");
  }
  return mesh.count;
}
