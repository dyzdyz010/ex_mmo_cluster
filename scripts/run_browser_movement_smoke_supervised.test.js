const fs = require("node:fs");
const path = require("node:path");
const Module = require("node:module");
const test = require("node:test");
const assert = require("node:assert/strict");

function loadSmokeHelpers() {
  const filename = path.resolve(
    __dirname,
    "run_browser_movement_smoke_supervised.js",
  );
  const source = fs
    .readFileSync(filename, "utf8")
    .replace(
      /\nmain\(\)\.catch\(\(error\) => \{\n  fail\(1, error\.stack \|\| String\(error\)\);\n\}\);\s*$/,
      "\nmodule.exports = { buildLongMovementVerdict, buildFrameDisplacementVerdict, longMovementInputDriver, longMovementInitialCoverageMode };\n",
    );

  const smokeModule = new Module(filename, module);
  smokeModule.filename = filename;
  smokeModule.paths = Module._nodeModulePaths(path.dirname(filename));
  smokeModule._compile(source, filename);
  return smokeModule.exports;
}

const {
  buildLongMovementVerdict,
  buildFrameDisplacementVerdict,
  longMovementInputDriver,
  longMovementInitialCoverageMode,
} = loadSmokeHelpers();

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
    ackSeq: index,
    inputSeqGap: 1,
    lastAckRttMs: 24,
    lastAckPendingInputs: 1,
    lastAckReplayedFrames: 1,
    serverStateAgeMs: 32,
    serverSendAgeMs: 16,
    sceneAckAgeMs: 18,
    browserApplyDelayMs: 4,
    gateSendDelayMs: 2,
    sceneInputAgeMs: 8,
    sceneQueueLen: 1,
    sceneReplayCount: 1,
    sceneMailboxLen: 0,
    sceneTickDriftMs: -1,
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
  const samples = Array.from({ length: 211 }, (_, index) =>
    frameSample(index, index * 33.333),
  );

  const verdict = buildFrameDisplacementVerdict(
    { samples },
    { durationMs: 12_000 },
  );

  assert.equal(verdict.targetHz, 60);
  assert.ok(
    verdict.effectiveHz < 40,
    `expected a degraded sample rate, got ${verdict.effectiveHz}`,
  );
  assert.equal(verdict.assertions.samplingHzHealthy, false);
  assert.equal(verdict.passed, false);
});

test("uses fixed movement steps for the 60Hz trace rate instead of headless render frames", () => {
  const samples = Array.from({ length: 331 }, (_, index) => ({
    ...frameSample(index, index * 33.333),
    fixedSteps: index === 0 ? 1 : 2,
  }));

  const verdict = buildFrameDisplacementVerdict(
    { samples },
    { durationMs: 11_000 },
  );

  assert.ok(
    verdict.renderEffectiveHz < 40,
    `expected low render-frame Hz, got ${verdict.renderEffectiveHz}`,
  );
  assert.ok(
    verdict.effectiveHz >= 55,
    `expected healthy fixed-step Hz, got ${verdict.effectiveHz}`,
  );
  assert.equal(verdict.assertions.samplingHzHealthy, true);
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
  const verdict = buildFrameDisplacementVerdict(
    { samples },
    { durationMs: 12_000 },
  );

  assert.equal(verdict.acceptanceChannel, "local");
  assert.deepEqual(Object.keys(verdict.channels).sort(), [
    "display",
    "projected",
    "rawAck",
  ]);
  assert.ok(verdict.channels.display.deltaDistanceDiff);
  assert.ok(verdict.channels.projected.deltaDistanceDiff);
  assert.ok(verdict.channels.rawAck.deltaDistanceDiff);
  assert.equal(verdict.channels.display.localAuthorityDistance.max, 1);
  assert.equal(verdict.channels.projected.localAuthorityDistance.max, 3);
  assert.equal(verdict.channels.rawAck.localAuthorityDistance.max, 120);
});

test("summarizes latency-chain diagnostics without making them acceptance thresholds", () => {
  const samples = Array.from({ length: 401 }, (_, index) => ({
    ...frameSample(index, 5_000 + index * 16.666),
    browserApplyDelayMs: index % 2 === 0 ? 4 : 8,
    gateSendDelayMs: 3,
    sceneQueueLen: index % 3,
  }));

  const verdict = buildFrameDisplacementVerdict(
    { samples },
    { durationMs: 12_000 },
  );

  assert.equal(verdict.diagnosticsPresent, true);
  assert.equal(verdict.diagnostics.browserApplyDelayMs.max, 8);
  assert.equal(verdict.diagnostics.gateSendDelayMs.max, 3);
  assert.equal(verdict.diagnostics.sceneQueueLen.max, 2);
  assert.equal(verdict.acceptanceChannel, "local");
  assert.equal(verdict.passed, true);
});

test("uses CLI movement input and movement-only readiness by default", () => {
  const previousDriver = process.env.BROWSER_MOVEMENT_INPUT_DRIVER;
  const previousCoverage = process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE;
  try {
    delete process.env.BROWSER_MOVEMENT_INPUT_DRIVER;
    delete process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE;

    assert.equal(longMovementInputDriver(), "cli");
    assert.equal(longMovementInitialCoverageMode(), "movement");
  } finally {
    if (previousDriver === undefined)
      delete process.env.BROWSER_MOVEMENT_INPUT_DRIVER;
    else process.env.BROWSER_MOVEMENT_INPUT_DRIVER = previousDriver;
    if (previousCoverage === undefined)
      delete process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE;
    else process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE = previousCoverage;
  }
});

test("keeps keyboard input and full initial coverage as explicit long-smoke opt-ins", () => {
  const previousDriver = process.env.BROWSER_MOVEMENT_INPUT_DRIVER;
  const previousCoverage = process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE;
  try {
    process.env.BROWSER_MOVEMENT_INPUT_DRIVER = "keyboard";
    process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE = "1";

    assert.equal(longMovementInputDriver(), "keyboard");
    assert.equal(longMovementInitialCoverageMode(), "full");
  } finally {
    if (previousDriver === undefined)
      delete process.env.BROWSER_MOVEMENT_INPUT_DRIVER;
    else process.env.BROWSER_MOVEMENT_INPUT_DRIVER = previousDriver;
    if (previousCoverage === undefined)
      delete process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE;
    else process.env.BROWSER_MOVEMENT_REQUIRE_FULL_COVERAGE = previousCoverage;
  }
});
