import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { InstancedMesh, LineSegments, MeshBasicMaterial } from "three";
import { FieldMask, type FFieldRegionSnapshot } from "./fieldProtocol";
import { FieldDebugOverlay } from "./fieldDebugOverlay";
import { buildPrefabRasterSurfaceOutlineGeometry } from "../../render/prefabPreviewGeometry";
import type { PrefabRasterCell } from "../prefab";

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

  it("renders formal hot and cold set-temperature snapshots", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 1),
        temperatureValues: Float32Array.of(800, -20),
      }),
    );

    const cells = temperatureMeshCells(overlay);
    expect(cells).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ r: 1, g: 0, b: 0, opacity: 0.62 }),
        expect.objectContaining({ r: 0.55, g: 0, b: 1, opacity: 0.62 }),
      ]),
    );
  });

  it("reports temperature strength stats for CLI/debug verification", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeTemperatureSnapshot({
        cellCount: 3,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 1, CENTER_INDEX + 2),
        temperatureValues: Float32Array.of(800, 35, 18),
      }),
    );

    expect(overlay.snapshot().regions[0]).toMatchObject({
      maxTemperatureCelsius: 800,
      maxAbsTemperatureDeltaCelsius: 780,
      averageAbsTemperatureDeltaCelsius: (780 + 15 + 2) / 3,
    });
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

  it("renders electric cells without a full-chunk debug wireframe", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 16),
        electricValues: Float32Array.of(120, 60),
      }),
    );

    const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
    expect(regionGroup?.children.some((child) => child.name.includes("chunk"))).toBe(false);
    expect(electricMesh(overlay).count).toBe(2);
  });

  it("projects electric overlay from macro cells onto prefab micro wires", () => {
    const overlay = new FieldDebugOverlay();
    const prefabCells: PrefabRasterCell[] = [
      {
        macro: { x: 0, y: 0, z: 0 },
        microOccupancyMask: 0b1111n,
        microMaterialIds: [],
        microStateFlags: [],
        microPartIds: [],
      },
    ];

    overlay.setProjector((worldMacro) => ({
      granularity: "prefab",
      key: "prefab:test",
      label: "prefab test",
      macro: worldMacro,
      prefabInstanceId: 99,
      cells: prefabCells.map((cell) => ({ ...cell, macro: worldMacro })),
    }));

    overlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricValues: Float32Array.of(120),
      }),
    );

    const line = electricMicroLines(overlay);
    const snapshot = overlay.snapshot().regions[0];
    const surfaceOutline = buildPrefabRasterSurfaceOutlineGeometry(prefabCells);
    const renderedSegmentCount = line.geometry.getAttribute("position").count / 2;

    expect(electricMesh(overlay).count).toBe(0);
    expect(line.visible).toBe(true);
    expect(renderedSegmentCount).toBe(surfaceOutline.wireSegmentCount);
    expect(snapshot).toMatchObject({
      electricCells: 4,
      electricMicroCells: 4,
      electricMicroGroups: 1,
    });
  });

  it("renders electric current as its own overlay layer", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 16),
        electricCurrentValues: Float32Array.of(4.5, 4.5),
      }),
    );

    expect(currentMesh(overlay).count).toBe(2);
    expect(overlay.snapshot().regions[0]).toMatchObject({
      electricCells: 0,
      currentCells: 2,
    });
  });

  it("renders electric current with the warm conduction color family", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(20),
      }),
    );

    const colors = currentMeshColors(overlay);
    expect(colors[0]).toMatchObject({
      r: expect.closeTo(1, 3),
      g: expect.closeTo(0.82, 2),
    });
    expect(colors[0]!.b).toBeLessThan(0.25);
  });

  it("spawns smoke from current snapshots even before an accepted request event", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 16),
        electricCurrentValues: Float32Array.of(20, 20),
      }),
    );

    expect(overlay.snapshot().regions[0]?.smokeParticles).toBeGreaterThan(0);
  });

  it("clears electric smoke immediately when an active circuit snapshot goes empty", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 16),
        electricCurrentValues: Float32Array.of(20, 20),
      }),
    );

    expect(overlay.snapshot().regions[0]?.smokeParticles).toBeGreaterThan(0);
    expect(currentMesh(overlay).visible).toBe(true);

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 0,
        macroIndices: new Uint16Array(0),
        electricCurrentValues: new Float32Array(0),
      }),
    );

    expect(overlay.snapshot().regions[0]).toMatchObject({
      currentCells: 0,
      smokeParticles: 0,
    });
    expect(currentMesh(overlay).count).toBe(0);
    expect(currentMesh(overlay).visible).toBe(false);
    expectHiddenInstance(currentMesh(overlay), 0);
  });

  it("hides electric potential meshes when a field snapshot goes empty", () => {
    const overlay = new FieldDebugOverlay();

    overlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricValues: Float32Array.of(120),
      }),
    );

    expect(electricMesh(overlay).count).toBe(1);
    expect(electricMesh(overlay).visible).toBe(true);

    overlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 0,
        macroIndices: new Uint16Array(0),
        electricValues: new Float32Array(0),
      }),
    );

    expect(electricMesh(overlay).count).toBe(0);
    expect(electricMesh(overlay).visible).toBe(false);
    expectHiddenInstance(electricMesh(overlay), 0);
  });

  it("projects electric current overlay from macro cells onto prefab micro wires", () => {
    const overlay = new FieldDebugOverlay();
    const prefabCells: PrefabRasterCell[] = [
      {
        macro: { x: 0, y: 0, z: 0 },
        microOccupancyMask: 0b1111n,
        microMaterialIds: [],
        microStateFlags: [],
        microPartIds: [],
      },
    ];

    overlay.setProjector((worldMacro) => ({
      granularity: "prefab",
      key: "prefab:current",
      label: "prefab current",
      macro: worldMacro,
      prefabInstanceId: 101,
      cells: prefabCells.map((cell) => ({ ...cell, macro: worldMacro })),
    }));

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(4.5),
      }),
    );

    const line = currentMicroLines(overlay);
    const snapshot = overlay.snapshot().regions[0];
    const surfaceOutline = buildPrefabRasterSurfaceOutlineGeometry(prefabCells);
    const renderedSegmentCount = line.geometry.getAttribute("position").count / 2;

    expect(currentMesh(overlay).count).toBe(0);
    expect(line.visible).toBe(true);
    expect(renderedSegmentCount).toBe(surfaceOutline.wireSegmentCount);
    expect(snapshot).toMatchObject({
      currentCells: 4,
      currentMicroCells: 4,
      currentMicroGroups: 1,
    });
  });

  it("reuses prefab current micro geometry when only field strength changes", () => {
    const overlay = new FieldDebugOverlay();
    const prefabCells: PrefabRasterCell[] = [
      {
        macro: { x: 0, y: 0, z: 0 },
        microOccupancyMask: 0b1111n,
        microMaterialIds: [],
        microStateFlags: [],
        microPartIds: [],
      },
    ];

    overlay.setProjector((worldMacro) => ({
      granularity: "prefab",
      key: "prefab:current-cache",
      label: "prefab current cache",
      macro: worldMacro,
      prefabInstanceId: 102,
      cells: prefabCells.map((cell) => ({ ...cell, macro: worldMacro })),
    }));

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(4.5),
      }),
    );
    const firstGeometry = currentMicroLines(overlay).geometry;

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(9),
      }),
    );

    expect(currentMicroLines(overlay).geometry).toBe(firstGeometry);
    expect(overlay.snapshot().regions[0]).toMatchObject({
      currentMicroCells: 4,
      currentMicroGroups: 1,
    });
  });

  it("rebuilds prefab current micro geometry when the projection shape changes", () => {
    const overlay = new FieldDebugOverlay();
    let microOccupancyMask = 0b1111n;

    overlay.setProjector((worldMacro) => ({
      granularity: "prefab",
      key: "prefab:current-cache",
      label: "prefab current cache",
      macro: worldMacro,
      prefabInstanceId: 102,
      cells: [
        {
          macro: worldMacro,
          microOccupancyMask,
          microMaterialIds: [],
          microStateFlags: [],
          microPartIds: [],
        },
      ],
    }));

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(4.5),
      }),
    );
    const firstGeometry = currentMicroLines(overlay).geometry;

    microOccupancyMask = 0b111111n;
    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(4.5),
      }),
    );

    expect(currentMicroLines(overlay).geometry).not.toBe(firstGeometry);
    expect(overlay.snapshot().regions[0]).toMatchObject({
      currentMicroCells: 6,
      currentMicroGroups: 1,
    });
  });

  it("turns electric heat into smoke particles instead of coloring the block body", () => {
    const lowHeatOverlay = new FieldDebugOverlay();
    lowHeatOverlay.setRegionHeatSmokeSource(77, 240);
    lowHeatOverlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 16),
        electricValues: Float32Array.of(120, 60),
      }),
    );

    const highHeatOverlay = new FieldDebugOverlay();
    highHeatOverlay.setRegionHeatSmokeSource(77, 2400);
    highHeatOverlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 2,
        macroIndices: Uint16Array.of(CENTER_INDEX, CENTER_INDEX + 16),
        electricValues: Float32Array.of(120, 60),
      }),
    );

    const lowSmoke = lowHeatOverlay.snapshot().regions[0]?.smokeParticles ?? 0;
    const highSmoke = highHeatOverlay.snapshot().regions[0]?.smokeParticles ?? 0;

    expect(lowSmoke).toBeGreaterThan(0);
    expect(highSmoke).toBeGreaterThan(lowSmoke);
    expect(temperatureMeshesMaybe(highHeatOverlay)).toHaveLength(0);
  });

  it("lets heat smoke rise and expire as a particle effect", () => {
    const overlay = new FieldDebugOverlay();
    overlay.show();
    overlay.setRegionHeatSmokeSource(77, 2400);
    overlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricValues: Float32Array.of(120),
      }),
    );

    expect(overlay.snapshot().regions[0]?.smokeParticles).toBeGreaterThan(0);
    expect(smokeMesh(overlay).visible).toBe(true);

    overlay.updateSmoke(2500);

    expect(overlay.snapshot().regions[0]?.smokeParticles).toBe(0);
    expect(smokeMesh(overlay).visible).toBe(false);
  });

  it("does not upload smoke instance matrices on every tiny frame", () => {
    const overlay = new FieldDebugOverlay();
    overlay.show();
    overlay.setRegionHeatSmokeSource(77, 2400);
    overlay.onFieldSnapshot(
      makeElectricSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricValues: Float32Array.of(120),
      }),
    );

    const mesh = smokeMesh(overlay);
    const firstVersion = mesh.instanceMatrix.version;

    overlay.updateSmoke(8);

    expect(mesh.instanceMatrix.version).toBe(firstVersion);

    overlay.updateSmoke(42);

    expect(mesh.instanceMatrix.version).toBeGreaterThan(firstVersion);
  });

  it("spawns one smoke instance per prefab projection instead of per occupied micro slot", () => {
    const overlay = new FieldDebugOverlay();
    overlay.show();
    overlay.setRegionHeatSmokeSource(77, 2400);
    overlay.setProjector((worldMacro) => ({
      granularity: "prefab",
      key: "prefab:single-smoke",
      label: "prefab single smoke",
      macro: worldMacro,
      prefabInstanceId: 501,
      cells: [
        {
          macro: worldMacro,
          microOccupancyMask: 0xffffffffffffffffffffffffffffffffn,
          microMaterialIds: [],
          microStateFlags: [],
          microPartIds: [],
        },
      ],
    }));

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(20),
      }),
    );

    expect(overlay.snapshot().regions[0]?.smokeParticles).toBe(1);
    expect(smokeMesh(overlay).count).toBe(1);

    overlay.onFieldSnapshot(
      makeCurrentSnapshot({
        cellCount: 1,
        macroIndices: Uint16Array.of(CENTER_INDEX),
        electricCurrentValues: Float32Array.of(20),
      }),
    );

    expect(overlay.snapshot().regions[0]?.smokeParticles).toBe(1);
    expect(smokeMesh(overlay).count).toBe(1);
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
    electricCurrentValues: new Float32Array(0),
    ionizationValues: new Uint8Array(0),
    smokeDensityValues: new Float32Array(0),
    oxygenValues: new Float32Array(0),
    moistureValues: new Float32Array(0),
  };
}

function makeElectricSnapshot({
  cellCount,
  macroIndices,
  electricValues,
}: {
  cellCount: number;
  macroIndices: Uint16Array;
  electricValues: Float32Array;
}): FFieldRegionSnapshot {
  return {
    logicalSceneId: 1,
    chunkCoord: { cx: 0, cy: 0, cz: 0 },
    regionId: 77,
    tickCount: 1,
    fieldMask: FieldMask.ElectricPotential,
    cellCount,
    macroIndices,
    temperatureValues: new Float32Array(0),
    electricValues,
    electricCurrentValues: new Float32Array(0),
    ionizationValues: new Uint8Array(0),
    smokeDensityValues: new Float32Array(0),
    oxygenValues: new Float32Array(0),
    moistureValues: new Float32Array(0),
  };
}

function makeCurrentSnapshot({
  cellCount,
  macroIndices,
  electricCurrentValues,
}: {
  cellCount: number;
  macroIndices: Uint16Array;
  electricCurrentValues: Float32Array;
}): FFieldRegionSnapshot {
  return {
    logicalSceneId: 1,
    chunkCoord: { cx: 0, cy: 0, cz: 0 },
    regionId: 77,
    tickCount: 1,
    fieldMask: FieldMask.ElectricCurrent,
    cellCount,
    macroIndices,
    temperatureValues: new Float32Array(0),
    electricValues: new Float32Array(0),
    electricCurrentValues,
    ionizationValues: new Uint8Array(0),
    smokeDensityValues: new Float32Array(0),
    oxygenValues: new Float32Array(0),
    moistureValues: new Float32Array(0),
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

function temperatureMeshesMaybe(overlay: FieldDebugOverlay): InstancedMesh[] {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  return (
    regionGroup?.children.filter(
      (child): child is InstancedMesh =>
        child instanceof InstancedMesh && child.name.startsWith("temperature-"),
    ) ?? []
  );
}

function temperatureMeshCount(overlay: FieldDebugOverlay): number {
  return temperatureMeshes(overlay).reduce((sum, mesh) => sum + mesh.count, 0);
}

function electricMesh(overlay: FieldDebugOverlay): InstancedMesh {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  const mesh = regionGroup?.children.find(
    (child): child is InstancedMesh =>
      child instanceof InstancedMesh && child.name === "electric-potential",
  );
  if (!mesh) {
    throw new Error("missing electric mesh");
  }
  return mesh;
}

function electricMicroLines(overlay: FieldDebugOverlay): LineSegments {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  const lines = regionGroup?.children.find(
    (child): child is LineSegments =>
      child instanceof LineSegments && child.name === "electric-micro-wire",
  );
  if (!lines) {
    throw new Error("missing electric micro lines");
  }
  return lines;
}

function currentMicroLines(overlay: FieldDebugOverlay): LineSegments {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  const lines = regionGroup?.children.find(
    (child): child is LineSegments =>
      child instanceof LineSegments && child.name === "electric-current-micro-wire",
  );
  if (!lines) {
    throw new Error("missing current micro lines");
  }
  return lines;
}

function currentMesh(overlay: FieldDebugOverlay): InstancedMesh {
  const regionGroup = overlay.rootGroup.getObjectByName("field-region-77");
  const mesh = regionGroup?.children.find(
    (child): child is InstancedMesh =>
      child instanceof InstancedMesh && child.name === "electric-current",
  );
  if (!mesh) {
    throw new Error("missing current mesh");
  }
  return mesh;
}

function smokeMesh(overlay: FieldDebugOverlay): InstancedMesh {
  const mesh = overlay.rootGroup.getObjectByName("heat-smoke-particles");
  if (!(mesh instanceof InstancedMesh)) {
    throw new Error("missing smoke mesh");
  }
  return mesh;
}

function currentMeshColors(overlay: FieldDebugOverlay): Array<{ r: number; g: number; b: number }> {
  const mesh = currentMesh(overlay);
  const colors = mesh.instanceColor?.array;
  if (!colors) {
    throw new Error("missing current instance colors");
  }
  return Array.from({ length: mesh.count }, (_value, index) => ({
    r: Number(colors[index * 3] ?? 0),
    g: Number(colors[index * 3 + 1] ?? 0),
    b: Number(colors[index * 3 + 2] ?? 0),
  }));
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
