const fs = require("node:fs");
const path = require("node:path");
const {
  relativePath,
  resolveRunId,
  sleep,
  startBrowserSmokeRuntime,
  waitForCli,
} = require("./browser_smoke_runtime");

const root = path.resolve(__dirname, "..");
const demoDir = path.join(root, ".demo");
const observeDir = path.join(demoDir, "observe");
fs.mkdirSync(observeDir, { recursive: true });

const startedAt = new Date().toISOString();
const runId = resolveRunId(startedAt);
const summaryFile = path.join(
  observeDir,
  "browser-combustion-field-smoke-summary.json",
);

const MATERIALS = {
  stone: 2,
  wood: 3,
  dry_grass: 10,
  cloth: 11,
};

const summary = {
  status: "running",
  startedAt,
  observeDir: relativePath(root, observeDir),
  files: {
    summary: relativePath(root, summaryFile),
  },
  ports: {},
  browser: {},
  assertions: {
    tabReady: false,
    sceneSpawnApplied: false,
    chunkSubscribed: false,
    materialsCommitted: false,
    temperatureSubmitted: false,
    smokeFieldObserved: false,
    oxygenDeficitObserved: false,
    combustionProbeObserved: false,
    inertControlObserved: false,
  },
  scenario: null,
};

function writeSummary(extra = {}) {
  const payload = {
    ...summary,
    ...extra,
    finishedAt: new Date().toISOString(),
  };
  fs.writeFileSync(summaryFile, `${JSON.stringify(payload, null, 2)}\n`);
}

function fail(code, message, detail) {
  summary.status = "failed";
  summary.failure = { code, message, detail };
  writeSummary();
  if (detail !== undefined) {
    console.error(message, JSON.stringify(detail, null, 2));
  } else {
    console.error(message);
  }
  process.exit(code);
}

function parseVector(value) {
  if (value && typeof value === "object") {
    const { x, y, z } = value;
    if ([x, y, z].every((item) => Number.isFinite(Number(item)))) {
      return { x: Number(x), y: Number(y), z: Number(z) };
    }
  }
  if (typeof value === "string") {
    const [x, y, z] = value.split(",").map((part) => Number.parseFloat(part));
    if ([x, y, z].every(Number.isFinite)) {
      return { x, y, z };
    }
  }
  return null;
}

function floorDiv(value, divisor) {
  return Math.floor(value / divisor);
}

function macroForWorldCm(valueCm) {
  return floorDiv(valueCm, 100);
}

function chunkForMacro(valueMacro) {
  return floorDiv(valueMacro, 16);
}

function chunkKey(coord) {
  return `${coord.x},${coord.y},${coord.z}`;
}

function snapshotPositions(snapshotResult) {
  const data = snapshotResult.data || {};
  const player = data.player || {};
  const actorDisplay = data.actorDisplay || {};
  const local =
    parseVector(player.renderedPosition) || parseVector(actorDisplay.local);
  const authority =
    parseVector(player.authoritativePosition) ||
    parseVector(actorDisplay.authority);
  return { local, authority };
}

function sceneSpawnApplied(positions) {
  return (
    positions.local &&
    positions.authority &&
    positions.local.x > 0 &&
    positions.local.y > 100 &&
    positions.local.z > 0 &&
    Math.abs(positions.local.x - positions.authority.x) <= 1 &&
    Math.abs(positions.local.y - positions.authority.y) <= 1 &&
    Math.abs(positions.local.z - positions.authority.z) <= 1
  );
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function combustionCellPlan(anchor) {
  const cells = [
    {
      role: "source",
      material: "wood",
      expectedMaterialId: MATERIALS.wood,
      offsetX: 0,
    },
    {
      role: "fast_fuel",
      material: "dry_grass",
      expectedMaterialId: MATERIALS.dry_grass,
      offsetX: 1,
    },
    {
      role: "ash_fuel",
      material: "cloth",
      expectedMaterialId: MATERIALS.cloth,
      offsetX: 2,
    },
    {
      role: "inert_control",
      material: "stone",
      expectedMaterialId: MATERIALS.stone,
      offsetX: 3,
    },
  ];

  return cells.map((cell) => ({
    ...cell,
    coord: {
      x: anchor.x + cell.offsetX,
      y: anchor.y,
      z: anchor.z,
    },
  }));
}

function chooseAnchor(positions) {
  const local = positions.local || { x: 1000, y: 1000, z: 100 };
  return {
    x: clamp(macroForWorldCm(local.x) - 2, 2, 10),
    y: clamp(macroForWorldCm(local.y + 150), 2, 12),
    z: clamp(macroForWorldCm(local.z) + 2, 2, 10),
  };
}

function chunkForCellPlan(cells) {
  const source = cells[0].coord;
  return {
    x: chunkForMacro(source.x),
    y: chunkForMacro(source.y),
    z: chunkForMacro(source.z),
  };
}

function allCellsInChunk(cells, chunk) {
  return cells.every((cell) => {
    const coord = cell.coord;
    return (
      chunkForMacro(coord.x) === chunk.x &&
      chunkForMacro(coord.y) === chunk.y &&
      chunkForMacro(coord.z) === chunk.z
    );
  });
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function summarizeFieldOverlaySnapshot(snapshot) {
  const regions = Array.isArray(snapshot?.regions) ? snapshot.regions : [];
  return regions.reduce(
    (acc, region) => {
      const smokeDensityCells = finiteNumber(region?.smokeDensityCells) ?? 0;
      const maxSmokeDensityPercent =
        finiteNumber(region?.maxSmokeDensityPercent) ?? 0;
      const oxygenCells = finiteNumber(region?.oxygenCells) ?? 0;
      const maxOxygenDeficitPercent =
        finiteNumber(region?.maxOxygenDeficitPercent) ?? 0;
      const temperatureCells = finiteNumber(region?.temperatureCells) ?? 0;
      acc.regionIds.push(region?.regionId ?? null);
      acc.regionCount += 1;
      acc.temperatureCells += temperatureCells;
      acc.smokeDensityCells += smokeDensityCells;
      acc.maxSmokeDensityPercent = Math.max(
        acc.maxSmokeDensityPercent,
        maxSmokeDensityPercent,
      );
      acc.oxygenCells += oxygenCells;
      acc.maxOxygenDeficitPercent = Math.max(
        acc.maxOxygenDeficitPercent,
        maxOxygenDeficitPercent,
      );
      acc.smokeParticles += finiteNumber(region?.smokeParticles) ?? 0;
      return acc;
    },
    {
      visible: Boolean(snapshot?.visible),
      regionCount: 0,
      regionIds: [],
      temperatureCells: 0,
      smokeDensityCells: 0,
      maxSmokeDensityPercent: 0,
      oxygenCells: 0,
      maxOxygenDeficitPercent: 0,
      smokeParticles: 0,
    },
  );
}

function fieldOverlayHasCombustionSmoke(summary) {
  return (
    summary.visible === true &&
    summary.regionCount > 0 &&
    summary.temperatureCells > 0 &&
    summary.smokeDensityCells > 0 &&
    summary.maxSmokeDensityPercent > 0 &&
    summary.oxygenCells > 0 &&
    summary.maxOxygenDeficitPercent > 0
  );
}

function probeMatchesCoord(probe, coord) {
  const worldMacro = probe?.worldMacro;
  return (
    worldMacro &&
    Number(worldMacro.x) === coord.x &&
    Number(worldMacro.y) === coord.y &&
    Number(worldMacro.z) === coord.z
  );
}

function sourceProbeShowsCombustion(probe) {
  const attrs = probe?.attributes || {};
  const smokeDensity = finiteNumber(attrs.smoke_density_percent) ?? 0;
  const oxygen = finiteNumber(attrs.oxygen_percent) ?? 100;
  const materialId = Number(probe?.materialId);
  const sourceMaterialObserved =
    probe?.materialName === "wood" ||
    probe?.materialName === "charcoal" ||
    materialId === MATERIALS.wood ||
    materialId === 9;
  return (
    sourceMaterialObserved &&
    (probe?.activeCombustion === true ||
      ["burning", "smoldering", "extinguished"].includes(
        String(probe?.stage),
      )) &&
    (smokeDensity > 0 || oxygen < 100)
  );
}

function inertProbeShowsStoneControl(probe) {
  return (
    (probe?.materialName === "stone" ||
      Number(probe?.materialId) === MATERIALS.stone) &&
    probe?.combustible === false &&
    probe?.activeCombustion === false
  );
}

function buildCombustionFieldVerdict({
  fieldSummary,
  sourceProbe,
  inertProbe,
}) {
  const assertions = {
    smokeFieldObserved: fieldOverlayHasCombustionSmoke(fieldSummary),
    oxygenDeficitObserved: (fieldSummary?.maxOxygenDeficitPercent ?? 0) > 0,
    combustionProbeObserved: sourceProbeShowsCombustion(sourceProbe),
    inertControlObserved: inertProbeShowsStoneControl(inertProbe),
  };
  return {
    assertions,
    passed: Object.values(assertions).every(Boolean),
  };
}

async function waitForTransportReady(page) {
  const result = await waitForCli(
    page,
    "transport",
    (value) => value?.data?.movementTransport?.ready === true,
    "combustion tab transport ready",
    45_000,
  );
  summary.assertions.tabReady = true;
  summary.browser.transport = result.data.movementTransport;
  return result;
}

async function waitForSceneSpawn(page) {
  const result = await waitForCli(
    page,
    "snapshot",
    (value) => sceneSpawnApplied(snapshotPositions(value)),
    "combustion tab scene spawn applied",
    20_000,
  );
  summary.assertions.sceneSpawnApplied = true;
  return result;
}

async function waitForAuthoritativeChunk(page, chunk) {
  const expectedKey = chunkKey(chunk);
  const result = await waitForCli(
    page,
    "chunks 128",
    (value) =>
      Array.isArray(value?.data) &&
      value.data.some((entry) => entry?.key === expectedKey),
    `authoritative chunk ${expectedKey}`,
    20_000,
  );
  summary.assertions.chunkSubscribed = true;
  return result;
}

async function waitForCellMaterial(page, cell) {
  return waitForCli(
    page,
    `cell ${cell.coord.x} ${cell.coord.y} ${cell.coord.z}`,
    (value) =>
      Number(value?.data?.block?.materialId) === cell.expectedMaterialId,
    `${cell.role} material ${cell.material} committed`,
    12_000,
  );
}

async function waitForFieldSmoke(page) {
  return waitForCli(
    page,
    "field_overlay",
    (value) =>
      fieldOverlayHasCombustionSmoke(
        summarizeFieldOverlaySnapshot(value?.data),
      ),
    "combustion smoke and oxygen field overlay",
    75_000,
  );
}

async function waitForCombustionProbe(page, coord, predicate, label) {
  const deadline = Date.now() + 45_000;
  let last = null;
  while (Date.now() < deadline) {
    await page.cli(`voxel_combustion ${coord.x} ${coord.y} ${coord.z}`);
    await sleep(300);
    last = await page.cli("voxel");
    const probe = last?.data?.lastCombustionProbe;
    if (probeMatchesCoord(probe, coord) && predicate(probe)) {
      return probe;
    }
  }
  throw new Error(`${label} timeout; last=${JSON.stringify(last)}`);
}

async function runScenario(page) {
  await waitForTransportReady(page);
  const spawn = await waitForSceneSpawn(page);
  const positions = snapshotPositions(spawn);
  const anchor = chooseAnchor(positions);
  const cells = combustionCellPlan(anchor);
  const chunk = chunkForCellPlan(cells);
  if (!allCellsInChunk(cells, chunk)) {
    throw new Error(
      `combustion cell plan crosses chunk boundary: ${JSON.stringify({ cells, chunk })}`,
    );
  }

  await page.cli(`voxel_subscribe ${chunk.x} ${chunk.y} ${chunk.z} 0`);
  const subscription = await waitForAuthoritativeChunk(page, chunk);

  const placementResults = [];
  for (const cell of cells) {
    placementResults.push(
      await page.cli(
        `place ${cell.coord.x} ${cell.coord.y} ${cell.coord.z} ${cell.material}`,
      ),
    );
    await waitForCellMaterial(page, cell);
  }
  summary.assertions.materialsCommitted = true;

  const overlayOn = await page.cli("field_overlay on");
  const source = cells.find((cell) => cell.role === "source");
  const inert = cells.find((cell) => cell.role === "inert_control");
  const temperatureResult = await page.cli(
    `voxel_temp ${source.coord.x} ${source.coord.y} ${source.coord.z} 1150 900`,
  );
  if (temperatureResult?.ok !== true) {
    throw new Error(
      `temperature command failed: ${JSON.stringify(temperatureResult)}`,
    );
  }
  summary.assertions.temperatureSubmitted = true;

  const fieldResult = await waitForFieldSmoke(page);
  const fieldSummary = summarizeFieldOverlaySnapshot(fieldResult.data);
  const sourceProbe = await waitForCombustionProbe(
    page,
    source.coord,
    sourceProbeShowsCombustion,
    "source combustion probe",
  );
  const inertProbe = await waitForCombustionProbe(
    page,
    inert.coord,
    inertProbeShowsStoneControl,
    "inert stone control probe",
  );
  const verdict = buildCombustionFieldVerdict({
    fieldSummary,
    sourceProbe,
    inertProbe,
  });

  Object.assign(summary.assertions, verdict.assertions);
  return {
    positions,
    anchor,
    chunk,
    cells,
    subscription,
    placementResults,
    overlayOn,
    temperatureResult,
    fieldOverlay: {
      text: fieldResult.text,
      summary: fieldSummary,
      raw: fieldResult.data,
    },
    probes: {
      source: sourceProbe,
      inertControl: inertProbe,
    },
    verdict,
  };
}

async function main() {
  fs.writeFileSync(summaryFile, "");
  let runtime = null;
  try {
    runtime = await startBrowserSmokeRuntime({
      root,
      observeDir,
      prefix: "browser-combustion-field-smoke",
      runId,
      urlFlag: "browser_combustion_field_smoke",
      viteEnv: {
        VITE_GAME_CLIENT_USERNAME: "browser_combustion_smoke",
        VITE_VOXEL_SUBSCRIBE_RADIUS: "0",
      },
    });
    Object.assign(summary.ports, runtime.ports);
    Object.assign(summary.files, {
      serverOut: relativePath(root, runtime.paths.bootOut),
      serverErr: relativePath(root, runtime.paths.bootErr),
      viteOut: relativePath(root, runtime.paths.viteOut),
      viteErr: relativePath(root, runtime.paths.viteErr),
      browserOut: relativePath(root, runtime.paths.browserOut),
      browserErr: relativePath(root, runtime.paths.browserErr),
      gateObserve: relativePath(root, runtime.paths.gateObserve),
      sceneObserve: relativePath(root, runtime.paths.sceneObserve),
    });
    summary.browser = runtime.browser;
    summary.browser.userDataDir = relativePath(
      root,
      runtime.browser.userDataDir,
    );

    const { page, url, consoleFile } = await runtime.createPage("A");
    summary.browser.url = url;
    summary.files.consoleA = relativePath(root, consoleFile);
    summary.scenario = await runScenario(page);

    if (!summary.scenario.verdict.passed) {
      throw new Error(
        `combustion field verdict failed: ${JSON.stringify(summary.scenario.verdict)}`,
      );
    }

    summary.status = "ok";
    writeSummary();
    process.stdout.write(`summary=${relativePath(root, summaryFile)}\n`);
  } finally {
    runtime?.close();
  }
}

if (require.main === module) {
  main().catch((error) => {
    fail(1, error.stack || String(error));
  });
}

module.exports = {
  allCellsInChunk,
  buildCombustionFieldVerdict,
  chooseAnchor,
  combustionCellPlan,
  fieldOverlayHasCombustionSmoke,
  inertProbeShowsStoneControl,
  sourceProbeShowsCombustion,
  summarizeFieldOverlaySnapshot,
};
