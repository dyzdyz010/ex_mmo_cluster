const test = require("node:test");
const assert = require("node:assert/strict");

const {
  allCellsInChunk,
  buildCombustionFieldVerdict,
  chooseAnchor,
  combustionCellPlan,
  fieldOverlayHasCombustionSmoke,
  inertProbeShowsStoneControl,
  sourceProbeShowsCombustion,
  summarizeFieldOverlaySnapshot,
} = require("./run_browser_combustion_field_smoke_supervised");

test("plans the browser combustion cells in one authoritative chunk", () => {
  const anchor = chooseAnchor({
    local: { x: 1000, y: 1000, z: 100 },
    authority: { x: 1000, y: 1000, z: 100 },
  });
  const cells = combustionCellPlan(anchor);

  assert.deepEqual(
    cells.map((cell) => [cell.role, cell.material, cell.expectedMaterialId]),
    [
      ["source", "wood", 3],
      ["fast_fuel", "dry_grass", 10],
      ["ash_fuel", "cloth", 11],
      ["inert_control", "stone", 2],
    ],
  );
  assert.equal(allCellsInChunk(cells, { x: 0, y: 0, z: 0 }), true);
});

test("requires smoke density and oxygen deficit, not just a hot field", () => {
  const hotOnly = summarizeFieldOverlaySnapshot({
    visible: true,
    regions: [
      {
        regionId: 9,
        temperatureCells: 4,
        smokeDensityCells: 0,
        maxSmokeDensityPercent: 0,
        oxygenCells: 0,
        maxOxygenDeficitPercent: 0,
      },
    ],
  });
  const combustion = summarizeFieldOverlaySnapshot({
    visible: true,
    regions: [
      {
        regionId: 10,
        temperatureCells: 4,
        smokeDensityCells: 3,
        maxSmokeDensityPercent: 12.5,
        oxygenCells: 3,
        maxOxygenDeficitPercent: 18.25,
        smokeParticles: 8,
      },
    ],
  });

  assert.equal(fieldOverlayHasCombustionSmoke(hotOnly), false);
  assert.equal(fieldOverlayHasCombustionSmoke(combustion), true);
  assert.deepEqual(combustion, {
    visible: true,
    regionCount: 1,
    regionIds: [10],
    temperatureCells: 4,
    smokeDensityCells: 3,
    maxSmokeDensityPercent: 12.5,
    oxygenCells: 3,
    maxOxygenDeficitPercent: 18.25,
    smokeParticles: 8,
  });
});

test("accepts authoritative source combustion and rejects inert stone ignition", () => {
  const sourceProbe = {
    materialId: 3,
    materialName: "wood",
    combustible: true,
    activeCombustion: true,
    stage: "burning",
    attributes: {
      smoke_density_percent: 6,
      oxygen_percent: 74,
    },
  };
  const inertProbe = {
    materialId: 2,
    materialName: "stone",
    combustible: false,
    activeCombustion: false,
    stage: "not_combustible",
    attributes: {},
  };

  assert.equal(sourceProbeShowsCombustion(sourceProbe), true);
  assert.equal(inertProbeShowsStoneControl(inertProbe), true);
});

test("builds a failing verdict when browser only observes temperature", () => {
  const verdict = buildCombustionFieldVerdict({
    fieldSummary: {
      visible: true,
      regionCount: 1,
      temperatureCells: 1,
      smokeDensityCells: 0,
      maxSmokeDensityPercent: 0,
      oxygenCells: 0,
      maxOxygenDeficitPercent: 0,
    },
    sourceProbe: {
      materialId: 3,
      materialName: "wood",
      combustible: true,
      activeCombustion: true,
      stage: "burning",
      attributes: {
        smoke_density_percent: 3,
        oxygen_percent: 90,
      },
    },
    inertProbe: {
      materialId: 2,
      materialName: "stone",
      combustible: false,
      activeCombustion: false,
    },
  });

  assert.equal(verdict.assertions.combustionProbeObserved, true);
  assert.equal(verdict.assertions.inertControlObserved, true);
  assert.equal(verdict.assertions.smokeFieldObserved, false);
  assert.equal(verdict.assertions.oxygenDeficitObserved, false);
  assert.equal(verdict.passed, false);
});

test("builds a passing verdict for live combustion field evidence", () => {
  const verdict = buildCombustionFieldVerdict({
    fieldSummary: {
      visible: true,
      regionCount: 1,
      temperatureCells: 2,
      smokeDensityCells: 2,
      maxSmokeDensityPercent: 14.5,
      oxygenCells: 2,
      maxOxygenDeficitPercent: 23.75,
    },
    sourceProbe: {
      materialId: 9,
      materialName: "charcoal",
      combustible: true,
      activeCombustion: false,
      stage: "extinguished",
      attributes: {
        smoke_density_percent: 5,
        oxygen_percent: 64,
      },
    },
    inertProbe: {
      materialId: 2,
      materialName: "stone",
      combustible: false,
      activeCombustion: false,
    },
  });

  assert.deepEqual(verdict.assertions, {
    smokeFieldObserved: true,
    oxygenDeficitObserved: true,
    combustionProbeObserved: true,
    inertControlObserved: true,
  });
  assert.equal(verdict.passed, true);
});
