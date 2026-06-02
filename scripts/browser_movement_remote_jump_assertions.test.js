const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildRemoteGroundSettledVerdict,
  buildRemoteJumpVerdict,
} = require("./browser_movement_remote_jump_assertions");

test("passes when the remote airborne frame arrives inside the degraded-network budget", () => {
  const verdict = buildRemoteJumpVerdict(
    [
      {
        tMs: 100,
        visible: true,
        y: 185,
        movementMode: "grounded",
        latestServerTick: 10,
        priorityBand: "high",
        deliveryInterval: 1,
      },
      {
        tMs: 900,
        visible: true,
        y: 185,
        movementMode: "grounded",
        latestServerTick: 10,
        priorityBand: "high",
        deliveryInterval: 1,
      },
      {
        tMs: 1_000,
        visible: true,
        y: 570,
        movementMode: "airborne",
        latestServerTick: 11,
        priorityBand: "high",
        deliveryInterval: 1,
      },
    ],
    {
      startY: 185,
      networkEmulation: {
        enabled: true,
        baseDelayMs: 40,
        jitterMs: 40,
        bytesPerSecond: 32_768,
      },
    },
  );

  assert.equal(verdict.passed, true);
  assert.equal(verdict.firstAirborneMs, 1_000);
  assert.equal(verdict.failures.length, 0);
});

test("fails when the remote jump is visible but airborne latency exceeds budget", () => {
  const verdict = buildRemoteJumpVerdict(
    [
      { tMs: 100, visible: true, y: 185, movementMode: "grounded" },
      { tMs: 1_200, visible: true, y: 570, movementMode: "airborne" },
    ],
    { startY: 185, networkEmulation: { enabled: false } },
  );

  assert.equal(verdict.passed, false);
  assert.equal(verdict.firstAirborneMs, 1_200);
  assert.ok(verdict.failures.includes("remote_jump_latency"));
});

test("fails when any remote sample loses the subject entity", () => {
  const verdict = buildRemoteJumpVerdict(
    [
      { tMs: 100, visible: true, y: 185, movementMode: "grounded" },
      { tMs: 200, visible: false },
      { tMs: 300, visible: true, y: 570, movementMode: "airborne" },
    ],
    { startY: 185, networkEmulation: { enabled: false } },
  );

  assert.equal(verdict.passed, false);
  assert.ok(verdict.failures.includes("remote_jump_visible"));
});

test("fails when the remote stream never receives a newer server tick", () => {
  const verdict = buildRemoteJumpVerdict(
    [
      {
        tMs: 100,
        visible: true,
        y: 185,
        movementMode: "grounded",
        latestServerTick: 7,
        priorityBand: "high",
        deliveryInterval: 1,
      },
      {
        tMs: 500,
        visible: true,
        y: 570,
        movementMode: "airborne",
        latestServerTick: 7,
        priorityBand: "high",
        deliveryInterval: 1,
      },
    ],
    { startY: 185, networkEmulation: { enabled: false } },
  );

  assert.equal(verdict.passed, false);
  assert.ok(verdict.failures.includes("remote_jump_tick_progress"));
});

test("fails when nearby remote movement is not delivered through the high-priority realtime lane", () => {
  const verdict = buildRemoteJumpVerdict(
    [
      {
        tMs: 100,
        visible: true,
        y: 185,
        movementMode: "grounded",
        latestServerTick: 7,
        priorityBand: "medium",
        deliveryInterval: 3,
      },
      {
        tMs: 500,
        visible: true,
        y: 570,
        movementMode: "airborne",
        latestServerTick: 8,
        priorityBand: "medium",
        deliveryInterval: 3,
      },
    ],
    { startY: 185, networkEmulation: { enabled: false } },
  );

  assert.equal(verdict.passed, false);
  assert.ok(verdict.failures.includes("remote_jump_realtime_lane"));
});

test("requires the remote subject to stay freshly grounded before timing a new jump", () => {
  const early = buildRemoteGroundSettledVerdict(
    [
      {
        tMs: 0,
        visible: true,
        y: 185,
        movementMode: "grounded",
        latestServerSendAgeMs: 120,
        priorityBand: "high",
        deliveryInterval: 1,
      },
      {
        tMs: 250,
        visible: true,
        y: 186,
        movementMode: "grounded",
        latestServerSendAgeMs: 180,
        priorityBand: "high",
        deliveryInterval: 1,
      },
    ],
    { requiredDurationMs: 600 },
  );

  assert.equal(early.passed, false);
  assert.ok(early.failures.includes("remote_ground_stable_duration"));

  const settled = buildRemoteGroundSettledVerdict(
    [
      ...early.samples,
      {
        tMs: 750,
        visible: true,
        y: 185,
        movementMode: "grounded",
        latestServerSendAgeMs: 220,
        priorityBand: "high",
        deliveryInterval: 1,
      },
    ],
    { requiredDurationMs: 600 },
  );

  assert.equal(settled.passed, true);
  assert.equal(settled.failures.length, 0);
});
