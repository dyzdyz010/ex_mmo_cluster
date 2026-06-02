const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildReconnectStressVerdict,
  resolveReconnectCycleCount,
} = require("./browser_movement_reconnect_assertions");

test("passes when every reconnect cycle disconnects, restores both tabs, and preserves remote visibility", () => {
  const verdict = buildReconnectStressVerdict([
    {
      cycle: 1,
      droppedSocketCount: 4,
      disconnected: { A: { reconnectAttemptCount: 1 }, B: { reconnectAttemptCount: 1 } },
      ready: { A: { ready: true }, B: { ready: true } },
      remoteVisible: { cid: 42 },
    },
    {
      cycle: 2,
      droppedSocketCount: 4,
      disconnected: { A: { reconnectAttemptCount: 1 }, B: { reconnectAttemptCount: 1 } },
      ready: { A: { ready: true }, B: { ready: true } },
      remoteVisible: { cid: 42 },
    },
  ]);

  assert.equal(verdict.passed, true);
  assert.equal(verdict.cycleCount, 2);
  assert.equal(verdict.failures.length, 0);
});

test("fails when a cycle reconnects but loses the remote subject", () => {
  const verdict = buildReconnectStressVerdict([
    {
      cycle: 1,
      droppedSocketCount: 4,
      disconnected: { A: { reconnectAttemptCount: 1 }, B: { reconnectAttemptCount: 1 } },
      ready: { A: { ready: true }, B: { ready: true } },
      remoteVisible: null,
    },
  ]);

  assert.equal(verdict.passed, false);
  assert.ok(verdict.failures.includes("reconnect_remote_visible"));
});

test("clamps reconnect cycle count to a bounded smoke budget", () => {
  assert.equal(resolveReconnectCycleCount({}), 2);
  assert.equal(resolveReconnectCycleCount({ BROWSER_MOVEMENT_RECONNECT_CYCLES: "1" }), 1);
  assert.equal(resolveReconnectCycleCount({ BROWSER_MOVEMENT_RECONNECT_CYCLES: "12" }), 5);
  assert.equal(resolveReconnectCycleCount({ BROWSER_MOVEMENT_RECONNECT_CYCLES: "bad" }), 2);
});
