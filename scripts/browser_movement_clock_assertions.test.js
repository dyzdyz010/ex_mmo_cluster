const test = require("node:test");
const assert = require("node:assert/strict");

const { buildClockSoakVerdict } = require("./browser_movement_clock_assertions");

function clock(overrides = {}) {
  return {
    interpolationTimeAxis: "server_state_ms",
    playbackServerTimeMs: 2_000_050,
    serverClockOffsetMs: 120,
    timeSyncSampleCount: 3,
    timeSyncOffsetJitterMs: 12,
    timeSyncOffsetJumpCount: 0,
    playbackTimeRegressionCount: 0,
    ...overrides,
  };
}

function sample(index, overrides = {}) {
  const authority = clock({ timeSyncSampleCount: 3 + index });
  const remote = clock({ cid: 42, timeSyncSampleCount: 3 + index });
  return {
    label: `sample-${index}`,
    player: { authorityRender: authority },
    players: {
      remote: {
        entities: [remote],
      },
    },
    ...overrides,
  };
}

test("passes when authority render and remote entities stay on server_state_ms", () => {
  const verdict = buildClockSoakVerdict([sample(0), sample(1), sample(2)], {
    minSamples: 2,
    minTimeSyncSampleProgress: 1,
  });

  assert.equal(verdict.passed, true);
  assert.equal(verdict.authority.serverStateSamples, 3);
  assert.equal(verdict.remote.serverStateSamples, 3);
  assert.equal(verdict.authority.serverSendSamples, 3);
  assert.equal(verdict.remote.serverSendSamples, 3);
  assert.equal(verdict.authority.timelineSamples, 3);
  assert.equal(verdict.remote.timelineSamples, 3);
  assert.deepEqual(verdict.failures, []);
});

test("passes with explicit server_tick fallback when server_state_ms spacing is unhealthy", () => {
  const fallbackClock = (overrides = {}) =>
    clock({
      interpolationTimeAxis: "server_tick",
      serverStateTimelineHealthy: false,
      serverSendTimelineHealthy: false,
      serverClockOffsetMs: null,
      timeSyncSampleCount: 3,
      ...overrides,
    });
  const verdict = buildClockSoakVerdict(
    [
      sample(0, {
        player: { authorityRender: fallbackClock() },
        players: { remote: { entities: [fallbackClock({ cid: 42 })] } },
      }),
      sample(1, {
        player: { authorityRender: fallbackClock({ playbackServerTimeMs: 2_000_150 }) },
        players: {
          remote: { entities: [fallbackClock({ cid: 42, playbackServerTimeMs: 2_000_150 })] },
        },
      }),
    ],
    { minSamples: 2, minTimeSyncSampleProgress: 1 },
  );

  assert.equal(verdict.passed, true);
  assert.equal(verdict.authority.serverTickFallbackSamples, 2);
  assert.equal(verdict.remote.serverTickFallbackSamples, 2);
  assert.equal(verdict.authority.timeSyncProgressRequired, false);
  assert.deepEqual(verdict.failures, []);
});

test("fails when authority render never leaves unannotated tick fallback", () => {
  const verdict = buildClockSoakVerdict(
    [
      sample(0, { player: { authorityRender: clock({ interpolationTimeAxis: "server_tick" }) } }),
      sample(1, { player: { authorityRender: clock({ interpolationTimeAxis: "server_tick" }) } }),
    ],
    { minSamples: 2 },
  );

  assert.equal(verdict.passed, false);
  assert.match(
    verdict.failures.join("\n"),
    /authority render did not use server_state_ms or explicit server_tick fallback/,
  );
});

test("fails when no remote entity uses an accepted timeline", () => {
  const verdict = buildClockSoakVerdict(
    [
      sample(0, {
        players: { remote: { entities: [clock({ cid: 42, interpolationTimeAxis: "server_tick" })] } },
      }),
      sample(1, {
        players: { remote: { entities: [clock({ cid: 42, interpolationTimeAxis: "server_tick" })] } },
      }),
    ],
    { minSamples: 2 },
  );

  assert.equal(verdict.passed, false);
  assert.match(
    verdict.failures.join("\n"),
    /remote entities did not use server_state_ms or explicit server_tick fallback/,
  );
});

test("fails when accepted server_state_ms clocks have excessive offset jitter", () => {
  const verdict = buildClockSoakVerdict(
    [
      sample(0, {
        player: { authorityRender: clock({ timeSyncSampleCount: 3, timeSyncOffsetJitterMs: 120 }) },
        players: {
          remote: { entities: [clock({ cid: 42, timeSyncSampleCount: 3, timeSyncOffsetJitterMs: 100 })] },
        },
      }),
      sample(1, {
        player: { authorityRender: clock({ timeSyncSampleCount: 4, timeSyncOffsetJitterMs: 520 }) },
        players: {
          remote: { entities: [clock({ cid: 42, timeSyncSampleCount: 4, timeSyncOffsetJitterMs: 480 })] },
        },
      }),
    ],
    { minSamples: 2, maxOffsetJitterMs: 250 },
  );

  assert.equal(verdict.passed, false);
  assert.match(verdict.failures.join("\n"), /authority offset jitter too high: 520\/250/);
  assert.match(verdict.failures.join("\n"), /remote offset jitter too high: 480\/250/);
});
