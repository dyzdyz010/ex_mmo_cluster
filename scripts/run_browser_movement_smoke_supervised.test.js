const fs = require("node:fs");
const path = require("node:path");
const Module = require("node:module");
const test = require("node:test");
const assert = require("node:assert/strict");

function loadSmokeHelpers() {
  const filename = path.resolve(__dirname, "run_browser_movement_smoke_supervised.js");
  const source = fs.readFileSync(filename, "utf8").replace(
    /\nmain\(\)\.catch\(\(error\) => \{\n  fail\(1, error\.stack \|\| String\(error\)\);\n\}\);\s*$/,
    "\nmodule.exports = { buildLongMovementVerdict, buildFrameDisplacementVerdict };\n",
  );

  const smokeModule = new Module(filename, module);
  smokeModule.filename = filename;
  smokeModule.paths = Module._nodeModulePaths(path.dirname(filename));
  smokeModule._compile(source, filename);
  return smokeModule.exports;
}

const { buildLongMovementVerdict, buildFrameDisplacementVerdict } = loadSmokeHelpers();

function frameSample(index, nowMs) {
  return {
    nowMs,
    deltaDistance: 10,
    authorityDeltaDistance: 10,
    authorityRenderDeltaDistance: 10,
    authorityProjectedDeltaDistance: 10,
    authorityDisplayDeltaDistance: 10,
    localAuthorityDistance: 0.5,
    localAuthorityRenderDistance: 0.5,
    localAuthorityProjectedDistance: 0.5,
    localAuthorityDisplayDistance: 0.5,
    authorityRenderAuthorityDistance: 0.5,
    authorityProjectedAuthorityDistance: 0.5,
    authorityDisplayAuthorityDistance: 0.5,
    seq: index,
  };
}

function movementSample(tMs, x, z, overrides = {}) {
  return {
    tMs,
    local: { x, y: 0, z },
    authority: { x, y: 0, z },
    displayAuthority: { x, y: 0, z },
    localAuthorityDistanceCm: 0,
    localDisplayAuthorityDistanceCm: 0,
    receivedAckCount: 20 + Math.floor(tMs / 1000),
    collisionStatus: "ok",
    transportLastError: null,
    voxelLastError: null,
    ...overrides,
  };
}

test("fails when effective sampling rate drops below the 60Hz acceptance target", () => {
  const samples = Array.from({ length: 211 }, (_, index) => frameSample(index, index * 33.333));

  const verdict = buildFrameDisplacementVerdict({ samples }, { durationMs: 12_000 });

  assert.equal(verdict.targetHz, 60);
  assert.ok(verdict.effectiveHz < 40, `expected a degraded sample rate, got ${verdict.effectiveHz}`);
  assert.equal(verdict.assertions.samplingHzHealthy, false);
  assert.equal(verdict.passed, false);
});

test("accepts a zigzag path as continuous movement instead of requiring large net displacement", () => {
  const samples = [
    movementSample(0, 0, 0),
    movementSample(1_000, 400, 0),
    movementSample(2_000, 400, 400),
    movementSample(3_000, 0, 400),
    movementSample(4_000, 0, 800),
    movementSample(5_000, 400, 800),
    movementSample(6_000, 400, 1_200),
    movementSample(7_000, 0, 1_200),
    movementSample(8_000, 0, 1_600),
    movementSample(9_000, 400, 1_600),
    movementSample(10_000, 400, 2_000),
  ];

  const verdict = buildLongMovementVerdict(samples, {
    key: "KeyD",
    durationMs: 10_000,
    sampleIntervalMs: 1_000,
  });

  assert.equal(verdict.turnCount >= 4, true);
  assert.equal(verdict.pathPattern, "zigzag");
  assert.equal(verdict.assertions.continuous, true);
});

test("reports display acceptance separately from projected and raw ack diagnostics", () => {
  const samples = Array.from({ length: 401 }, (_, index) => ({
    ...frameSample(index, 5_000 + index * 16.666),
    localAuthorityDistance: 120,
    localAuthorityRenderDistance: 8,
    localAuthorityProjectedDistance: 3,
    localAuthorityDisplayDistance: 1,
  }));
  const verdict = buildFrameDisplacementVerdict({ samples }, { durationMs: 12_000 });

  assert.equal(verdict.acceptanceChannel, "display");
  assert.deepEqual(Object.keys(verdict.channels).sort(), ["display", "projected", "rawAck"]);
  assert.ok(verdict.channels.display.deltaDistanceDiff);
  assert.ok(verdict.channels.projected.deltaDistanceDiff);
  assert.ok(verdict.channels.rawAck.deltaDistanceDiff);
  assert.equal(verdict.channels.display.localAuthorityDistance.max, 1);
  assert.equal(verdict.channels.projected.localAuthorityDistance.max, 3);
  assert.equal(verdict.channels.rawAck.localAuthorityDistance.max, 120);
});
