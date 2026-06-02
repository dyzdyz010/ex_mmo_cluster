const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildDelayMs,
  buildTransmissionMs,
  nextOrderedWriteAtMs,
  resolveNetworkTimeoutMs,
  resolveNetworkEmulationConfig,
  consumeServerToClientWebSocketFrames,
} = require("./browser_movement_network_emulation");

test("disables network emulation when delay and jitter are absent", () => {
  const config = resolveNetworkEmulationConfig({});

  assert.equal(config.enabled, false);
  assert.equal(config.baseDelayMs, 0);
  assert.equal(config.jitterMs, 0);
  assert.equal(config.bytesPerSecond, 0);
});

test("enables network emulation when base delay, jitter, or bandwidth is configured", () => {
  const config = resolveNetworkEmulationConfig({
    BROWSER_MOVEMENT_NET_DELAY_MS: "45",
    BROWSER_MOVEMENT_NET_JITTER_MS: "15",
    BROWSER_MOVEMENT_NET_BYTES_PER_SEC: "32768",
  });

  assert.equal(config.enabled, true);
  assert.equal(config.baseDelayMs, 45);
  assert.equal(config.jitterMs, 15);
  assert.equal(config.bytesPerSecond, 32_768);
});

test("enables network emulation when server player-move frame loss is configured", () => {
  const config = resolveNetworkEmulationConfig({
    BROWSER_MOVEMENT_NET_DROP_SERVER_MOVE_EVERY_N: "3",
    BROWSER_MOVEMENT_NET_DROP_SERVER_MOVE_PERCENT: "25",
    BROWSER_MOVEMENT_NET_DROP_SEED: "123",
  });

  assert.equal(config.enabled, true);
  assert.equal(config.dropServerMoveEveryN, 3);
  assert.equal(config.dropServerMovePercent, 25);
  assert.equal(config.dropSeed, 123);
});

test("clamps invalid network emulation values", () => {
  const config = resolveNetworkEmulationConfig({
    BROWSER_MOVEMENT_NET_DELAY_MS: "-10",
    BROWSER_MOVEMENT_NET_JITTER_MS: "999999",
    BROWSER_MOVEMENT_NET_BYTES_PER_SEC: "999999999",
  });

  assert.equal(config.enabled, true);
  assert.equal(config.baseDelayMs, 0);
  assert.equal(config.jitterMs, 5_000);
  assert.equal(config.bytesPerSecond, 10_000_000);
});

test("builds a bounded non-negative delay from base and jitter", () => {
  const delay = buildDelayMs({ baseDelayMs: 40, jitterMs: 20 }, () => 1);

  assert.equal(delay, 60);
  assert.equal(buildDelayMs({ baseDelayMs: 40, jitterMs: 20 }, () => 0), 40);
  assert.equal(buildDelayMs({ baseDelayMs: 0, jitterMs: 0 }, () => 1), 0);
});

test("builds transmission delay from configured bandwidth", () => {
  assert.equal(buildTransmissionMs(1024, 1024), 1000);
  assert.equal(buildTransmissionMs(512, 1024), 500);
  assert.equal(buildTransmissionMs(1024, 0), 0);
});

test("preserves write order even when later chunks receive smaller jitter", () => {
  const state = { nextWriteAtMs: 0 };
  const first = nextOrderedWriteAtMs(state, 1_000, 80, 100, 0);
  const second = nextOrderedWriteAtMs(state, 1_001, 5, 100, 0);

  assert.equal(first, 1_080);
  assert.equal(second, 1_085);
  assert.ok(second >= first);
});

test("serializes writes when bandwidth throttling is configured", () => {
  const state = { nextWriteAtMs: 0 };
  const first = nextOrderedWriteAtMs(state, 2_000, 40, 1024, 1024);
  const second = nextOrderedWriteAtMs(state, 2_001, 0, 512, 1024);

  assert.equal(first, 3_040);
  assert.equal(second, 3_540);
});

test("extends smoke wait budgets only when bandwidth throttling is configured", () => {
  assert.equal(resolveNetworkTimeoutMs(15_000, { bytesPerSecond: 0 }), 15_000);
  assert.equal(resolveNetworkTimeoutMs(15_000, { bytesPerSecond: 32_768 }), 60_000);
  assert.equal(resolveNetworkTimeoutMs(90_000, { bytesPerSecond: 32_768 }), 90_000);
});

test("drops every configured server PlayerMove websocket frame without dropping other opcodes", () => {
  const state = {};
  const firstMove = unmaskedBinaryFrame([0x83, 0x01]);
  const timeSync = unmaskedBinaryFrame([0x85, 0x02]);
  const secondMove = unmaskedBinaryFrame([0x83, 0x03]);
  const thirdMove = unmaskedBinaryFrame([0x83, 0x04]);

  const result = consumeServerToClientWebSocketFrames(
    Buffer.concat([firstMove, timeSync, secondMove, thirdMove]),
    { dropServerMoveEveryN: 2 },
    state,
  );

  assert.deepEqual(result.frames, [firstMove, timeSync, thirdMove]);
  assert.equal(result.droppedFrameCount, 1);
  assert.equal(state.serverMoveFrameCount, 3);
  assert.equal(state.droppedServerMoveFrameCount, 1);
});

test("buffers incomplete websocket frames until the whole frame is available", () => {
  const state = {};
  const frame = unmaskedBinaryFrame([0x83, 0x01, 0x02]);
  const first = consumeServerToClientWebSocketFrames(frame.subarray(0, 2), {}, state);
  const second = consumeServerToClientWebSocketFrames(frame.subarray(2), {}, state);

  assert.deepEqual(first.frames, []);
  assert.equal(first.bufferedBytes, 2);
  assert.deepEqual(second.frames, [frame]);
  assert.equal(second.bufferedBytes, 0);
});

test("drops a deterministic subset of PlayerMove frames by seeded percent", () => {
  const state = { proxyStats: { serverMoveFrameCount: 0, droppedServerMoveFrameCount: 0 } };
  const frames = Array.from({ length: 20 }, (_, index) => unmaskedBinaryFrame([0x83, index]));

  const result = consumeServerToClientWebSocketFrames(Buffer.concat(frames), {
    dropServerMovePercent: 50,
    dropSeed: 17,
  }, state);

  assert.ok(result.droppedFrameCount > 0);
  assert.ok(result.droppedFrameCount < frames.length);
  assert.equal(result.frames.length + result.droppedFrameCount, frames.length);
  assert.equal(state.serverMoveFrameCount, frames.length);
  assert.equal(state.droppedServerMoveFrameCount, result.droppedFrameCount);
  assert.equal(state.proxyStats.serverMoveFrameCount, frames.length);
  assert.equal(state.proxyStats.droppedServerMoveFrameCount, result.droppedFrameCount);
});

test("seeded percent drop stays close to the configured rate over a larger sample", () => {
  const state = {};
  const frames = Array.from({ length: 100 }, (_, index) => unmaskedBinaryFrame([0x83, index]));

  const result = consumeServerToClientWebSocketFrames(Buffer.concat(frames), {
    dropServerMovePercent: 20,
    dropSeed: 17,
  }, state);

  assert.ok(result.droppedFrameCount >= 10);
  assert.ok(result.droppedFrameCount <= 30);
});

test("seeded percent drop does not over-cluster the initial smoke window", () => {
  const state = {};
  const frames = Array.from({ length: 20 }, (_, index) => unmaskedBinaryFrame([0x83, index]));

  const result = consumeServerToClientWebSocketFrames(Buffer.concat(frames), {
    dropServerMovePercent: 20,
    dropSeed: 17,
  }, state);

  assert.ok(result.droppedFrameCount >= 3);
  assert.ok(result.droppedFrameCount <= 5);
});

function unmaskedBinaryFrame(payload) {
  const bytes = Buffer.from(payload);
  return Buffer.concat([Buffer.from([0x82, bytes.length]), bytes]);
}
