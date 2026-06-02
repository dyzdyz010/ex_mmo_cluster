const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");
const { spawn, spawnSync, execFileSync } = require("node:child_process");
const { buildClockSoakVerdict } = require("./browser_movement_clock_assertions");
const {
  resolveNetworkEmulationConfig,
  resolveNetworkTimeoutMs,
  startWebSocketDelayProxy,
} = require("./browser_movement_network_emulation");
const {
  buildReconnectStressVerdict,
  resolveReconnectCycleCount,
} = require("./browser_movement_reconnect_assertions");
const {
  buildRemoteGroundSettledVerdict,
  buildRemoteJumpVerdict,
} = require("./browser_movement_remote_jump_assertions");

if (typeof WebSocket !== "function") {
  throw new Error("browser movement smoke requires Node.js 22+ with global WebSocket");
}

const root = path.resolve(__dirname, "..");
const clientDir = path.join(root, "clients", "web_client");
const demoDir = path.join(root, ".demo");
const observeDir = path.join(demoDir, "observe");
fs.mkdirSync(observeDir, { recursive: true });

const startedAt = new Date().toISOString();
const runId = startedAt.replace(/[:.]/g, "-");
const summaryFile = path.join(observeDir, "browser-movement-smoke-summary.json");
const bootOut = path.join(observeDir, "browser-movement-smoke.server.out.log");
const bootErr = path.join(observeDir, "browser-movement-smoke.server.err.log");
const dbOut = path.join(observeDir, "browser-movement-smoke.db.out.log");
const dbErr = path.join(observeDir, "browser-movement-smoke.db.err.log");
const viteOut = path.join(observeDir, "browser-movement-smoke.vite.out.log");
const viteErr = path.join(observeDir, "browser-movement-smoke.vite.err.log");
const browserOut = path.join(observeDir, "browser-movement-smoke.browser.out.log");
const browserErr = path.join(observeDir, "browser-movement-smoke.browser.err.log");
const consoleA = path.join(observeDir, "browser-movement-smoke.A.console.log");
const consoleB = path.join(observeDir, "browser-movement-smoke.B.console.log");
const gateObserve = path.join(observeDir, "browser-movement-smoke.gate-observe.log");
const sceneObserve = path.join(observeDir, "browser-movement-smoke.scene-observe.log");
const readyFile = path.join(observeDir, `browser-movement-smoke-${runId}.ready`);
let activeWsProxy = null;

for (const filename of [
  summaryFile,
  bootOut,
  bootErr,
  dbOut,
  dbErr,
  viteOut,
  viteErr,
  browserOut,
  browserErr,
  consoleA,
  consoleB,
  gateObserve,
  sceneObserve,
  readyFile,
]) {
  fs.writeFileSync(filename, "");
}

const summary = {
  status: "running",
  startedAt,
  observeDir: path.relative(root, observeDir),
  files: {
    summary: path.relative(root, summaryFile),
    serverOut: path.relative(root, bootOut),
    serverErr: path.relative(root, bootErr),
    viteOut: path.relative(root, viteOut),
    viteErr: path.relative(root, viteErr),
    browserOut: path.relative(root, browserOut),
    browserErr: path.relative(root, browserErr),
    consoleA: path.relative(root, consoleA),
    consoleB: path.relative(root, consoleB),
    gateObserve: path.relative(root, gateObserve),
    sceneObserve: path.relative(root, sceneObserve),
  },
  ports: {},
  browser: {},
  tabs: {},
  overheadBlock: null,
  localJump: null,
  remoteJump: null,
  reconnect: null,
  clockSoak: null,
  longMovement: null,
  networkEmulation: null,
  assertions: {
    tabAReady: false,
    tabBReady: false,
    remoteEnterObserved: false,
    reconnectDisconnected: false,
    reconnectReady: false,
    reconnectRemoteVisible: false,
    overheadBlockCommitted: false,
    overheadBlockDidNotLiftLocal: false,
    overheadBlockDidNotLiftAuthority: false,
    overheadBlockCleaned: false,
    localJumpRenderedRise: false,
    localJumpAuthorityRise: false,
    localJumpAirborneTrace: false,
    localJumpLanded: false,
    remoteJumpVisible: false,
    remoteJumpAirborne: false,
    remoteJumpRise: false,
    remoteJumpLatency: false,
    remoteJumpTickProgress: false,
    remoteJumpRealtimeLane: false,
    clockSoakAuthorityServerSend: false,
    clockSoakRemoteServerSend: false,
    clockSoakAuthorityAcceptedTimeline: false,
    clockSoakRemoteAcceptedTimeline: false,
    clockSoakTimeSyncProgressed: false,
    longMovementContinuous: false,
    longMovementAuthorityMoved: false,
    longMovementAuthorityBounded: false,
    longMovementAckHealthy: false,
    longMovementNoRouteErrors: false,
    longMovementNotBlocked: false,
    longMovementFrameDisplacement: false,
  },
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
  if (summary.networkEmulation && activeWsProxy && typeof activeWsProxy.getStats === "function") {
    summary.networkEmulation.proxyStats = activeWsProxy.getStats();
  }
  writeSummary();
  if (detail !== undefined) {
    console.error(message, JSON.stringify(detail, null, 2));
  } else {
    console.error(message);
  }
  process.exit(code);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function appendStream(stream, filename) {
  const target = fs.createWriteStream(filename, { flags: "a" });
  stream.on("data", (chunk) => target.write(chunk));
  stream.on("close", () => target.end());
}

function mixInvocation(args) {
  if (process.platform === "win32") {
    return { command: "cmd.exe", args: ["/c", "mix", ...args] };
  }
  return { command: "mix", args };
}

function runChecked(command, args, options) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    env: options.env,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });

  fs.writeFileSync(options.stdout, result.stdout || "");
  fs.writeFileSync(options.stderr, result.stderr || "");

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${options.label} failed with exit code ${result.status}\nstdout: ${options.stdout}\nstderr: ${options.stderr}`,
    );
  }
}

async function getFreeTcpPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : null;
      server.close(() => {
        if (port == null) {
          reject(new Error("no free tcp port"));
        } else {
          resolve(port);
        }
      });
    });
    server.on("error", reject);
  });
}

function killTree(child) {
  if (!child || !child.pid) {
    return;
  }
  if (process.platform === "win32") {
    try {
      execFileSync("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], {
        stdio: "ignore",
      });
    } catch {
      // best-effort cleanup
    }
    return;
  }
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    try {
      process.kill(child.pid, "SIGTERM");
    } catch {
      // best-effort cleanup
    }
  }
}

async function waitForHttpReady(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok || response.status === 404) {
        return;
      }
    } catch {
      // retry
    }
    await sleep(500);
  }
  throw new Error(`http readiness timeout for ${url}`);
}

async function waitForFile(filename, child, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(filename) && fs.statSync(filename).size > 0) {
      return;
    }
    if (child.exitCode != null) {
      throw new Error(`boot exited before ready file was written, code=${child.exitCode}`);
    }
    await sleep(250);
  }
  throw new Error(`ready file timeout for ${filename}`);
}

function findCommandOnPath(names) {
  const lookup = process.platform === "win32" ? "where.exe" : "which";
  for (const name of names) {
    const result = spawnSync(lookup, [name], { encoding: "utf8" });
    if (result.status === 0) {
      const candidate = result.stdout.split(/\r?\n/).find(Boolean);
      if (candidate && fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return null;
}

function findBrowserExecutable() {
  for (const value of [
    process.env.BROWSER_SMOKE_CHROME_PATH,
    process.env.CHROME_PATH,
    process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
  ]) {
    if (value && fs.existsSync(value)) {
      return value;
    }
  }

  const candidates =
    process.platform === "win32"
      ? [
          path.join(process.env.PROGRAMFILES || "", "Google", "Chrome", "Application", "chrome.exe"),
          path.join(
            process.env["PROGRAMFILES(X86)"] || "",
            "Google",
            "Chrome",
            "Application",
            "chrome.exe",
          ),
          path.join(process.env.LOCALAPPDATA || "", "Google", "Chrome", "Application", "chrome.exe"),
          path.join(process.env.PROGRAMFILES || "", "Microsoft", "Edge", "Application", "msedge.exe"),
          path.join(
            process.env["PROGRAMFILES(X86)"] || "",
            "Microsoft",
            "Edge",
            "Application",
            "msedge.exe",
          ),
        ]
      : process.platform === "darwin"
        ? [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
          ]
        : [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/microsoft-edge",
          ];

  const explicit = candidates.find((candidate) => candidate && fs.existsSync(candidate));
  if (explicit) {
    return explicit;
  }
  return findCommandOnPath(["chrome", "google-chrome", "google-chrome-stable", "chromium", "msedge"]);
}

async function createChromeTarget(port, url) {
  const encodedUrl = encodeURIComponent(url);
  let response = await fetch(`http://127.0.0.1:${port}/json/new?${encodedUrl}`, {
    method: "PUT",
  });
  if (!response.ok) {
    response = await fetch(`http://127.0.0.1:${port}/json/new?${encodedUrl}`);
  }
  if (!response.ok) {
    throw new Error(`failed to create chrome target: ${response.status}`);
  }
  const target = await response.json();
  if (!target.webSocketDebuggerUrl) {
    throw new Error(`chrome target missing websocket url: ${JSON.stringify(target)}`);
  }
  return target.webSocketDebuggerUrl;
}

class CdpPage {
  constructor(label, websocketUrl, consoleFile) {
    this.label = label;
    this.websocketUrl = websocketUrl;
    this.consoleFile = consoleFile;
    this.nextId = 1;
    this.pending = new Map();
    this.socket = null;
  }

  async connect() {
    this.socket = new WebSocket(this.websocketUrl);
    this.socket.addEventListener("message", (event) => this.onMessage(event.data));
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.label} CDP connect timeout`)), 10_000);
      this.socket.addEventListener(
        "open",
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true },
      );
      this.socket.addEventListener(
        "error",
        () => {
          clearTimeout(timer);
          reject(new Error(`${this.label} CDP connect error`));
        },
        { once: true },
      );
    });

    await this.send("Runtime.enable");
    await this.send("Page.enable");
  }

  async bringToFront() {
    await this.send("Page.bringToFront");
  }

  close() {
    try {
      this.socket?.close();
    } catch {
      // ignore
    }
  }

  async send(method, params = {}) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error(`${this.label} CDP socket not open`);
    }
    const id = this.nextId++;
    const message = { id, method, params };
    const promise = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
    });
    this.socket.send(JSON.stringify(message));
    return promise;
  }

  async evaluate(expression) {
    const response = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (response.exceptionDetails) {
      throw new Error(`${this.label} evaluate failed: ${formatException(response.exceptionDetails)}`);
    }
    return response.result?.value;
  }

  async cli(command) {
    return this.evaluate(`(async () => {
      const deadline = Date.now() + 15000;
      while (!window.__voxelCli) {
        if (Date.now() > deadline) throw new Error("window.__voxelCli not installed");
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      return window.__voxelCli.run(${JSON.stringify(command)});
    })()`);
  }

  onMessage(raw) {
    const message = JSON.parse(raw);
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) {
        return;
      }
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(`${this.label} ${pending.method}: ${JSON.stringify(message.error)}`));
      } else {
        pending.resolve(message.result || {});
      }
      return;
    }

    if (message.method === "Runtime.consoleAPICalled") {
      const parts = (message.params?.args || []).map((arg) =>
        arg.value !== undefined ? String(arg.value) : arg.description || arg.type || "",
      );
      fs.appendFileSync(this.consoleFile, `${new Date().toISOString()} ${parts.join(" ")}\n`);
    } else if (message.method === "Runtime.exceptionThrown") {
      fs.appendFileSync(
        this.consoleFile,
        `${new Date().toISOString()} EXCEPTION ${formatException(message.params?.exceptionDetails)}\n`,
      );
    }
  }
}

function formatException(details) {
  if (!details) {
    return "unknown";
  }
  return details.exception?.description || details.text || JSON.stringify(details);
}

async function waitForCli(page, command, predicate, label, timeoutMs = 30_000) {
  const effectiveTimeoutMs = resolveNetworkTimeoutMs(timeoutMs, summary.networkEmulation);
  const deadline = Date.now() + effectiveTimeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await page.cli(command);
      if (predicate(last)) {
        return last;
      }
    } catch (error) {
      last = { error: error instanceof Error ? error.message : String(error) };
    }
    await sleep(250);
  }
  throw new Error(`${label} timeout; last=${JSON.stringify(last)}`);
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
  const local = parseVector(player.renderedPosition) || parseVector(actorDisplay.local);
  const authority = parseVector(player.authoritativePosition) || parseVector(actorDisplay.authority);
  return { local, authority };
}

function vectorDistance(a, b) {
  if (!a || !b) {
    return null;
  }
  return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
}

function horizontalDistance(a, b) {
  if (!a || !b) {
    return null;
  }
  return Math.hypot(a.x - b.x, a.z - b.z);
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function percentile(sortedValues, percentileValue) {
  if (sortedValues.length === 0) {
    return null;
  }
  const index = Math.min(
    sortedValues.length - 1,
    Math.max(0, Math.ceil((percentileValue / 100) * sortedValues.length) - 1),
  );
  return sortedValues[index];
}

function summarizeNumbers(values) {
  const finiteValues = values.map(finiteNumber).filter((value) => value !== null);
  if (finiteValues.length === 0) {
    return null;
  }
  const sorted = [...finiteValues].sort((a, b) => a - b);
  const sum = finiteValues.reduce((total, value) => total + value, 0);
  return {
    count: finiteValues.length,
    min: sorted[0],
    max: sorted[sorted.length - 1],
    mean: sum / finiteValues.length,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
  };
}

function horizontalDeltaDistance(sample, prefix) {
  const deltaXKey = prefix ? `${prefix}DeltaX` : "deltaX";
  const deltaZKey = prefix ? `${prefix}DeltaZ` : "deltaZ";
  const deltaX = finiteNumber(sample?.[deltaXKey]);
  const deltaZ = finiteNumber(sample?.[deltaZKey]);
  if (deltaX === null || deltaZ === null) {
    return null;
  }
  return Math.hypot(deltaX, deltaZ);
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

function remoteEntity(playersResult, cid) {
  const entities = playersResult.data?.remote?.entities || [];
  return entities.find((entity) => Number(entity.cid) === Number(cid)) || null;
}

async function waitForTransportReady(page, label) {
  const result = await waitForCli(
    page,
    "transport",
    (value) => value?.data?.movementTransport?.ready === true,
    `${label} transport ready`,
    45_000,
  );
  const movement = result.data.movementTransport;
  summary.tabs[label] = {
    username: movement.username,
    cid: movement.cid,
    transportReady: movement.ready,
    connectionStatus: movement.connectionStatus,
    connectionPhase: movement.connectionPhase,
  };
  summary.assertions[`tab${label}Ready`] = true;
  return movement;
}

async function waitForSceneSpawnApplied(page, label) {
  return waitForCli(
    page,
    "snapshot",
    (result) => sceneSpawnApplied(snapshotPositions(result)),
    `${label} scene spawn applied`,
    20_000,
  );
}

async function waitForAuthoritativeChunk(page, chunk, label) {
  const expectedKey = chunkKey(chunk);
  return waitForCli(
    page,
    "chunks 64",
    (result) =>
      Array.isArray(result?.data) &&
      result.data.some((entry) => entry?.key === expectedKey && entry.solidBlocks > 0),
    label,
    15_000,
  );
}

function resolveInitialVoxelSubscribeRadius() {
  const parsed = Number.parseInt(
    process.env.BROWSER_SMOKE_VOXEL_SUBSCRIBE_RADIUS ||
      process.env.VITE_VOXEL_SUBSCRIBE_RADIUS ||
      "1",
    10,
  );
  return Number.isFinite(parsed) && parsed >= 0 ? Math.trunc(parsed) : 1;
}

function expectedInitialAuthoritativeChunks() {
  const radius = resolveInitialVoxelSubscribeRadius();
  const width = radius * 2 + 1;
  return width * width * width;
}

async function waitForInitialAuthoritativeCoverage(page, label) {
  const expected = expectedInitialAuthoritativeChunks();
  return waitForCli(
    page,
    "snapshot",
    (result) => Number(result?.data?.chunks ?? 0) >= expected,
    label,
    60_000,
  );
}

async function runOverheadBlockCheck(page) {
  const beforeSnapshot = await page.cli("snapshot");
  const before = snapshotPositions(beforeSnapshot);
  if (!before.local || !before.authority) {
    throw new Error(`snapshot missing actorDisplay: ${JSON.stringify(beforeSnapshot)}`);
  }

  const macro = {
    x: macroForWorldCm(before.local.x),
    y: macroForWorldCm(before.local.y + 150),
    z: macroForWorldCm(before.local.z),
  };
  const chunk = {
    x: chunkForMacro(macro.x),
    y: chunkForMacro(macro.y),
    z: chunkForMacro(macro.z),
  };

  await page.cli(`voxel_subscribe ${chunk.x} ${chunk.y} ${chunk.z} 0`);
  const subscriptionReadyResult = await waitForAuthoritativeChunk(
    page,
    chunk,
    "overhead block authoritative chunk",
  );
  const placeResult = await page.cli(`place ${macro.x} ${macro.y} ${macro.z} stone`);

  let cellResult = null;
  try {
    cellResult = await waitForCli(
      page,
      `cell ${macro.x} ${macro.y} ${macro.z}`,
      (result) => result?.data?.block !== null,
      "overhead block cell commit",
      8_000,
    );
  } catch (error) {
    cellResult = { ok: false, text: error instanceof Error ? error.message : String(error) };
  }

  await sleep(800);
  const afterSnapshot = await page.cli("snapshot");
  const after = snapshotPositions(afterSnapshot);
  if (!after.local || !after.authority) {
    throw new Error(`after snapshot missing actorDisplay: ${JSON.stringify(afterSnapshot)}`);
  }

  const localDeltaY = after.local.y - before.local.y;
  const authorityDeltaY = after.authority.y - before.authority.y;
  const blockCommitted = cellResult?.ok === true && cellResult?.data?.block !== null;
  const localStable = Math.abs(localDeltaY) <= 2;
  const authorityStable = Math.abs(authorityDeltaY) <= 2;

  summary.assertions.overheadBlockCommitted = blockCommitted;
  summary.assertions.overheadBlockDidNotLiftLocal = localStable;
  summary.assertions.overheadBlockDidNotLiftAuthority = authorityStable;
  summary.overheadBlock = {
    macro,
    chunk,
    placeResult,
    cellResult,
    before,
    after,
    localDeltaY,
    authorityDeltaY,
    subscriptionReadyResult,
    passed: blockCommitted && localStable && authorityStable,
  };

  if (!summary.overheadBlock.passed) {
    throw new Error(`overhead block check failed: ${JSON.stringify(summary.overheadBlock)}`);
  }

  const cleanupBreakResult = await page.cli(`break ${macro.x} ${macro.y} ${macro.z}`);
  const cleanupCellResult = await waitForCli(
    page,
    `cell ${macro.x} ${macro.y} ${macro.z}`,
    (result) => result?.data?.block === null,
    "overhead block cleanup commit",
    8_000,
  );
  summary.assertions.overheadBlockCleaned =
    cleanupBreakResult?.data?.ok === true && cleanupCellResult?.data?.block === null;
  summary.overheadBlock.cleanup = {
    breakResult: cleanupBreakResult,
    cellResult: cleanupCellResult,
    passed: summary.assertions.overheadBlockCleaned,
  };

  if (!summary.overheadBlock.cleanup.passed) {
    throw new Error(`overhead block cleanup failed: ${JSON.stringify(summary.overheadBlock)}`);
  }
}

async function sampleLocalJump(page) {
  await page.cli("frame_trace_clear");
  await page.cli("frame_trace_start 180");
  const beforeSnapshot = await page.cli("snapshot");
  const before = snapshotPositions(beforeSnapshot);
  if (!before.local || !before.authority) {
    throw new Error(`local jump start missing actorDisplay: ${JSON.stringify(beforeSnapshot)}`);
  }

  await page.cli("jump");
  const samples = [];
  for (let i = 0; i < 28; i++) {
    await sleep(100);
    const snapshotResult = await page.cli("snapshot");
    const playerResult = await page.cli("player");
    const positions = snapshotPositions(snapshotResult);
    samples.push({
      tMs: (i + 1) * 100,
      localY: positions.local?.y ?? null,
      authorityY: positions.authority?.y ?? null,
      predictedMode: playerResult.data?.predicted?.movementMode ?? null,
      predictedGroundY: playerResult.data?.predicted?.groundY ?? null,
    });
  }
  const traceResult = await page.cli("frame_trace");
  const traceSamples = traceResult.data?.samples || [];
  const maxLocalY = Math.max(...samples.map((sample) => sample.localY).filter(Number.isFinite));
  const maxAuthorityY = Math.max(
    ...samples.map((sample) => sample.authorityY).filter(Number.isFinite),
  );
  const final = samples[samples.length - 1];
  const airborneTraceCount = traceSamples.filter(
    (sample) => sample.movementMode === "airborne",
  ).length;
  const airbornePollCount = samples.filter((sample) => sample.predictedMode === "airborne").length;
  const renderedRise = maxLocalY - before.local.y;
  const authorityRise = maxAuthorityY - before.authority.y;
  const landed = final && Math.abs(final.localY - before.local.y) <= 8;

  summary.assertions.localJumpRenderedRise = renderedRise >= 30;
  summary.assertions.localJumpAuthorityRise = authorityRise >= 25;
  summary.assertions.localJumpAirborneTrace = airborneTraceCount > 0 || airbornePollCount > 0;
  summary.assertions.localJumpLanded = landed;
  summary.localJump = {
    before,
    maxLocalY,
    maxAuthorityY,
    renderedRise,
    authorityRise,
    airborneTraceCount,
    airbornePollCount,
    final,
    sampleCount: samples.length,
    samples,
    frameTrace: {
      frameCount: traceResult.data?.frameCount ?? traceSamples.length,
      airborneSamples: airborneTraceCount,
      maxRenderedY: Math.max(...traceSamples.map((sample) => sample.renderedY ?? -Infinity)),
      samples: traceSamples.slice(0, 40),
    },
    passed:
      summary.assertions.localJumpRenderedRise &&
      summary.assertions.localJumpAuthorityRise &&
      summary.assertions.localJumpAirborneTrace &&
      summary.assertions.localJumpLanded,
  };

  if (!summary.localJump.passed) {
    throw new Error(`local jump check failed: ${JSON.stringify(summary.localJump)}`);
  }
}

async function triggerJumpAndWaitForLocalDispatch(page, label) {
  const beforeResult = await page.cli("player");
  const beforePredicted = beforeResult.data?.predicted || {};
  const beforeSeq = Number(beforePredicted.seq ?? 0);
  const beforeTick = Number(beforePredicted.tick ?? 0);

  const jumpResult = await page.cli("jump");
  const dispatchedResult = await waitForCli(
    page,
    "player",
    (result) => {
      const predicted = result?.data?.predicted;
      if (!predicted) {
        return false;
      }
      const seq = Number(predicted.seq ?? 0);
      const tick = Number(predicted.tick ?? 0);
      return seq > beforeSeq && tick > beforeTick && predicted.movementMode === "airborne";
    },
    `${label} jump input dispatched`,
    5_000,
  );

  return {
    before: beforeResult.data,
    jumpResult,
    dispatched: dispatchedResult.data,
  };
}

async function waitForRemoteGround(page, cid) {
  return waitForCli(
    page,
    "players",
    (result) => {
      const entity = remoteEntity(result, cid);
      if (!entity) {
        return false;
      }
      return entity.movementMode === "grounded";
    },
    `remote ${cid} grounded`,
    10_000,
  );
}

async function waitForRemoteGroundSettled(page, cid) {
  const startedAt = Date.now();
  const samples = [];
  let latestVerdict = null;
  const result = await waitForCli(
    page,
    "players",
    (playersResult) => {
      const sample = remoteGroundSample(remoteEntity(playersResult, cid), Date.now() - startedAt);
      samples.push(sample);
      latestVerdict = buildRemoteGroundSettledVerdict(samples, {
        requiredDurationMs: 750,
        maxServerSendAgeMs: 2_000,
      });
      return latestVerdict.passed;
    },
    `remote ${cid} grounded and settled`,
    15_000,
  );

  return {
    result,
    verdict: latestVerdict,
    samples,
  };
}

function remoteGroundSample(entity, tMs) {
  if (!entity) {
    return { tMs, visible: false };
  }
  const position = parseVector(entity.renderedPosition);
  const latestServerSendMs = Number(entity.latestServerSendMs);
  return {
    tMs,
    visible: true,
    y: position?.y ?? null,
    movementMode: entity.movementMode,
    latestServerTick: entity.latestServerTick ?? null,
    latestServerSendAgeMs: Number.isFinite(latestServerSendMs)
      ? Math.max(0, Date.now() - latestServerSendMs)
      : null,
    priorityBand: entity.priorityBand ?? null,
    deliveryInterval: entity.deliveryInterval ?? null,
  };
}

async function waitForLocalGroundSettled(page, label) {
  return waitForCli(
    page,
    "player",
    (result) => {
      const data = result?.data;
      const predicted = data?.predicted;
      const rendered = parseVector(data?.renderedPosition);
      const authority = parseVector(data?.authoritativePosition);
      const groundY = Number(predicted?.groundY ?? authority?.y ?? rendered?.y);
      return (
        predicted?.movementMode === "grounded" &&
        rendered !== null &&
        authority !== null &&
        Math.abs(rendered.y - groundY) <= 8 &&
        Math.abs(authority.y - groundY) <= 8
      );
    },
    `${label} local authority grounded`,
    20_000,
  );
}

async function sampleRemoteJump(pageA, pageB, cidA) {
  await pageA.bringToFront();
  const localGroundedResult = await waitForLocalGroundSettled(pageA, `subject ${cidA}`);
  await pageB.bringToFront();
  await waitForRemoteGround(pageB, cidA);
  const settled = await waitForRemoteGroundSettled(pageB, cidA);
  const startEntity = remoteEntity(settled.result, cidA);
  if (!startEntity) {
    throw new Error(`remote entity ${cidA} not visible before jump`);
  }
  const startPosition = parseVector(startEntity.renderedPosition);
  if (!startPosition) {
    throw new Error(`remote entity ${cidA} missing rendered position`);
  }

  await pageA.bringToFront();
  const dispatch = await triggerJumpAndWaitForLocalDispatch(pageA, `subject ${cidA}`);
  await pageB.bringToFront();
  const samples = [];
  let lostSamples = 0;
  for (let i = 0; i < 30; i++) {
    await sleep(100);
    const playersResult = await pageB.cli("players");
    const entity = remoteEntity(playersResult, cidA);
    if (!entity) {
      lostSamples += 1;
      samples.push({ tMs: (i + 1) * 100, visible: false });
      continue;
    }
    const position = parseVector(entity.renderedPosition);
    samples.push({
      tMs: (i + 1) * 100,
      visible: true,
      y: position?.y ?? null,
      movementMode: entity.movementMode,
      movementGroundY: entity.movementGroundY ?? null,
      latestServerTick: entity.latestServerTick ?? null,
      priorityBand: entity.priorityBand ?? null,
      priorityScore: entity.priorityScore ?? null,
      observerDistance: entity.observerDistance ?? null,
      deliveryInterval: entity.deliveryInterval ?? null,
      interpolationMode: entity.interpolationMode ?? null,
    });
  }

  const verdict = buildRemoteJumpVerdict(samples, {
    startY: startPosition.y,
    networkEmulation: summary.networkEmulation,
  });

  summary.assertions.remoteJumpVisible = !verdict.failures.includes("remote_jump_visible");
  summary.assertions.remoteJumpAirborne = !verdict.failures.includes("remote_jump_airborne");
  summary.assertions.remoteJumpRise = !verdict.failures.includes("remote_jump_rise");
  summary.assertions.remoteJumpLatency = !verdict.failures.includes("remote_jump_latency");
  summary.assertions.remoteJumpTickProgress = !verdict.failures.includes(
    "remote_jump_tick_progress",
  );
  summary.assertions.remoteJumpRealtimeLane = !verdict.failures.includes(
    "remote_jump_realtime_lane",
  );
  summary.remoteJump = {
    subjectCid: cidA,
    localGroundedBeforeJump: localGroundedResult.data ?? null,
    remoteGroundSettledBeforeJump: settled.verdict,
    startPosition,
    dispatch,
    maxY: verdict.maxY,
    rise: verdict.rise,
    lostSamples,
    airborneSamples: verdict.airborneSamples,
    firstAirborneMs: verdict.firstAirborneMs,
    latencyBudgetMs: verdict.latencyBudgetMs,
    serverTickProgress: verdict.serverTickProgress,
    highPrioritySamples: verdict.highPrioritySamples,
    maxDeliveryInterval: verdict.maxDeliveryInterval,
    failures: verdict.failures,
    samples,
    passed: verdict.passed,
  };

  if (!summary.remoteJump.passed) {
    throw new Error(`remote jump check failed: ${JSON.stringify(summary.remoteJump)}`);
  }
}

async function runReconnectCheck(pageA, pageB, cidA, wsProxy, cycleCount) {
  if (!wsProxy || typeof wsProxy.dropConnections !== "function") {
    throw new Error("reconnect check requires the WebSocket proxy");
  }

  const cycles = [];
  for (let cycle = 1; cycle <= cycleCount; cycle += 1) {
    await pageA.bringToFront();
    const beforeAResult = await pageA.cli("transport");
    const beforeBResult = await pageB.cli("transport");
    const beforeA = beforeAResult.data?.movementTransport ?? null;
    const beforeB = beforeBResult.data?.movementTransport ?? null;

    const droppedSocketCount = wsProxy.dropConnections();
    const disconnectedAResult = await waitForCli(
      pageA,
      "transport",
      (result) => {
        const transport = result?.data?.movementTransport;
        return (
          transport?.connectionStatus === "disconnected" &&
          Number(transport.reconnectAttemptCount ?? 0) >= 1
        );
      },
      `A transport disconnects under network flash ${cycle}`,
      20_000,
    );
    const disconnectedBResult = await waitForCli(
      pageB,
      "transport",
      (result) => {
        const transport = result?.data?.movementTransport;
        return (
          transport?.connectionStatus === "disconnected" &&
          Number(transport.reconnectAttemptCount ?? 0) >= 1
        );
      },
      `B transport disconnects under network flash ${cycle}`,
      20_000,
    );

    await pageA.bringToFront();
    const readyAResult = await waitForCli(
      pageA,
      "transport",
      (result) => {
        const transport = result?.data?.movementTransport;
        return (
          transport?.ready === true &&
          transport?.connectionStatus === "connected" &&
          transport?.connectionPhase === "ready"
        );
      },
      `A transport reconnects after network flash ${cycle}`,
      60_000,
    );
    await waitForSceneSpawnApplied(pageA, `A reconnect scene spawn ${cycle}`);
    await pageB.bringToFront();
    const readyBResult = await waitForCli(
      pageB,
      "transport",
      (result) => {
        const transport = result?.data?.movementTransport;
        return (
          transport?.ready === true &&
          transport?.connectionStatus === "connected" &&
          transport?.connectionPhase === "ready"
        );
      },
      `B transport reconnects after network flash ${cycle}`,
      60_000,
    );
    await waitForSceneSpawnApplied(pageB, `B reconnect scene spawn ${cycle}`);

    await pageB.bringToFront();
    const remoteVisibleResult = await waitForCli(
      pageB,
      "players",
      (result) => remoteEntity(result, cidA) !== null,
      `B observes A after reconnect ${cycle}`,
      30_000,
    );

    cycles.push({
      cycle,
      droppedSocketCount,
      before: {
        A: beforeA,
        B: beforeB,
      },
      disconnected: {
        A: disconnectedAResult.data?.movementTransport ?? null,
        B: disconnectedBResult.data?.movementTransport ?? null,
      },
      ready: {
        A: readyAResult.data?.movementTransport ?? null,
        B: readyBResult.data?.movementTransport ?? null,
      },
      remoteVisible: remoteEntity(remoteVisibleResult, cidA),
    });
  }

  const verdict = buildReconnectStressVerdict(cycles);
  const lastCycle = cycles[cycles.length - 1] ?? {};
  summary.assertions.reconnectDisconnected =
    !verdict.failures.includes("reconnect_a_disconnect") &&
    !verdict.failures.includes("reconnect_b_disconnect");
  summary.assertions.reconnectReady =
    !verdict.failures.includes("reconnect_a_ready") &&
    !verdict.failures.includes("reconnect_b_ready");
  summary.assertions.reconnectRemoteVisible =
    !verdict.failures.includes("reconnect_remote_visible");
  summary.reconnect = {
    subjectCid: cidA,
    cycleCount: verdict.cycleCount,
    droppedSocketCount: cycles.reduce(
      (sum, cycle) => sum + Number(cycle.droppedSocketCount || 0),
      0,
    ),
    failures: verdict.failures,
    cycles,
    before: lastCycle.before ?? null,
    disconnected: lastCycle.disconnected ?? null,
    ready: lastCycle.ready ?? null,
    remoteVisible: lastCycle.remoteVisible ?? null,
    passed: verdict.passed,
  };

  if (!summary.reconnect.passed) {
    throw new Error(`reconnect check failed: ${JSON.stringify(summary.reconnect)}`);
  }
}

async function runClockSoak(pageA, pageB) {
  const durationMs = resolveClockSoakDurationMs();
  const samples = [];
  const startedMs = Date.now();
  const intervalMs = 1_000;

  do {
    samples.push(await collectClockSoakSample(pageA, "A", startedMs));
    samples.push(await collectClockSoakSample(pageB, "B", startedMs));
    await sleep(intervalMs);
  } while (Date.now() - startedMs < durationMs);

  const minSamples = Math.max(2, Math.min(4, Math.floor(samples.length / 2)));
  const verdict = buildClockSoakVerdict(samples, {
    minSamples,
    minTimeSyncSampleProgress: durationMs >= 2_000 ? 1 : 0,
    maxPlaybackRegressionDelta: 4,
  });

  summary.assertions.clockSoakAuthorityServerState =
    verdict.authority.serverStateSamples >= verdict.thresholds.minSamples;
  summary.assertions.clockSoakRemoteServerState =
    verdict.remote.serverStateSamples >= verdict.thresholds.minSamples;
  summary.assertions.clockSoakAuthorityServerSend =
    summary.assertions.clockSoakAuthorityServerState;
  summary.assertions.clockSoakRemoteServerSend = summary.assertions.clockSoakRemoteServerState;
  summary.assertions.clockSoakAuthorityAcceptedTimeline =
    verdict.authority.timelineSamples >= verdict.thresholds.minSamples;
  summary.assertions.clockSoakRemoteAcceptedTimeline =
    verdict.remote.timelineSamples >= verdict.thresholds.minSamples;
  summary.assertions.clockSoakTimeSyncProgressed =
    (!verdict.authority.timeSyncProgressRequired ||
      verdict.authority.timeSyncSampleProgress >= verdict.thresholds.minTimeSyncSampleProgress) &&
    (!verdict.remote.timeSyncProgressRequired ||
      verdict.remote.timeSyncSampleProgress >= verdict.thresholds.minTimeSyncSampleProgress);
  summary.clockSoak = {
    durationMs,
    passed: verdict.passed,
    verdict,
    recentSamples: samples.slice(-8),
  };

  if (!verdict.passed) {
    throw new Error(`clock soak failed: ${JSON.stringify(summary.clockSoak)}`);
  }
}

async function collectClockSoakSample(page, label, startedMs) {
  const player = await page.cli("player");
  const players = await page.cli("players");
  return {
    label,
    tMs: Date.now() - startedMs,
    player: {
      authorityRender: player.data?.authorityRender ?? null,
    },
    players: {
      remote: {
        clock: players.data?.remote?.clock ?? null,
        entities: players.data?.remote?.entities ?? [],
      },
    },
  };
}

function resolveClockSoakDurationMs() {
  const raw = Number.parseInt(process.env.BROWSER_MOVEMENT_CLOCK_SOAK_MS || "6000", 10);
  if (!Number.isFinite(raw)) {
    return 6_000;
  }
  return Math.max(1_000, Math.min(raw, 60_000));
}

function resolveLongMovementDurationMs() {
  const raw = Number.parseInt(
    process.env.BROWSER_MOVEMENT_LONG_RUN_MS ||
      process.env.BROWSER_MOVEMENT_LONG_DURATION_MS ||
      "30000",
    10,
  );
  if (!Number.isFinite(raw)) {
    return 30_000;
  }
  return Math.max(5_000, Math.min(raw, 180_000));
}

function longMovementKeyConfig(code = process.env.BROWSER_MOVEMENT_LONG_KEY || "KeyD") {
  const configs = {
    KeyA: { code: "KeyA", key: "a", windowsVirtualKeyCode: 65 },
    KeyD: { code: "KeyD", key: "d", windowsVirtualKeyCode: 68 },
    KeyS: { code: "KeyS", key: "s", windowsVirtualKeyCode: 83 },
    KeyW: { code: "KeyW", key: "w", windowsVirtualKeyCode: 87 },
  };
  return configs[code] || configs.KeyA;
}

async function setMovementKey(page, keyConfig, pressed) {
  await page.send("Input.dispatchKeyEvent", {
    type: pressed ? "keyDown" : "keyUp",
    key: keyConfig.key,
    code: keyConfig.code,
    windowsVirtualKeyCode: keyConfig.windowsVirtualKeyCode,
    nativeVirtualKeyCode: keyConfig.windowsVirtualKeyCode,
    autoRepeat: pressed,
  });
}

function compactLongMovementSnapshot(snapshotResult, tMs) {
  const data = snapshotResult.data || {};
  const positions = snapshotPositions(snapshotResult);
  const player = data.player || {};
  const transport = data.transportState?.movementTransport || {};
  const voxelTransport = transport.voxel || {};
  const collision = player.collision || null;
  const actorDisplay = data.actorDisplay || {};
  const displayAuthority = parseVector(actorDisplay.authority);
  return {
    tMs,
    local: positions.local,
    authority: positions.authority,
    displayAuthority,
    localAuthorityDistanceCm: vectorDistance(positions.local, positions.authority),
    localAuthorityHorizontalCm: horizontalDistance(positions.local, positions.authority),
    localDisplayAuthorityDistanceCm: vectorDistance(positions.local, displayAuthority),
    chunks: data.chunks ?? null,
    solidBlocks: data.solidBlocks ?? null,
    collisionStatus: collision?.status ?? null,
    collisionBlockedAxes: collision?.blockedAxes ?? [],
    collisionOccupiedCount: collision?.occupiedCount ?? null,
    sentInputCount: transport.sentInputCount ?? null,
    receivedAckCount: transport.receivedAckCount ?? null,
    lastAckSeq: transport.lastAckSeq ?? null,
    queuedAcks: transport.queuedAcks ?? null,
    transportLastError: transport.lastError ?? null,
    voxelLastError: voxelTransport.lastError ?? data.voxel?.lastError ?? null,
    pendingSubscriptions: data.voxel?.pendingSubscriptions ?? null,
    knownAuthoritativeChunks:
      data.voxel?.authoritativeChunks ?? data.voxel?.knownAuthoritativeChunks ?? null,
  };
}

function buildLongMovementVerdict(samples, options) {
  const first = samples[0] || {};
  const last = samples[samples.length - 1] || {};
  const durationMs = options.durationMs;
  const sampleIntervalMs = options.sampleIntervalMs;
  const localHorizontalCm = horizontalDistance(first.local, last.local) ?? 0;
  const authorityHorizontalCm = horizontalDistance(first.authority, last.authority) ?? 0;
  const maxLocalAuthorityDistanceCm = Math.max(
    0,
    ...samples
      .map((sample) => sample.localAuthorityDistanceCm)
      .filter((value) => Number.isFinite(value)),
  );
  const maxLocalAuthorityDisplayDistanceCm = Math.max(
    0,
    ...samples
      .map((sample) => sample.localDisplayAuthorityDistanceCm)
      .filter((value) => Number.isFinite(value)),
  );
  const startAckCount = Number(first.receivedAckCount ?? 0);
  const endAckCount = Number(last.receivedAckCount ?? 0);
  const ackDelta = Math.max(0, endAckCount - startAckCount);
  const minAckDelta = Math.max(8, Math.floor(durationMs / 1000));
  const noRouteError = samples.every((sample) => {
    const errorText = `${sample.transportLastError ?? ""} ${sample.voxelLastError ?? ""}`;
    return !/unassigned_chunk|unauthorized_voxel_target/.test(errorText);
  });
  const routeErrorSamples = samples.filter((sample) => {
    const errorText = `${sample.transportLastError ?? ""} ${sample.voxelLastError ?? ""}`;
    return /unassigned_chunk|unauthorized_voxel_target/.test(errorText);
  });
  const lateBlockedSamples = samples.filter(
    (sample) => sample.tMs >= 2_000 && sample.collisionStatus === "resolved",
  );
  const lateAuthorityUnavailableSamples = samples.filter(
    (sample) => sample.tMs >= 5_000 && sample.collisionStatus === "authority_unavailable",
  );
  const stuckWindows = [];
  const windowMs = 5_000;
  const minWindowMoveCm = 150;
  for (let i = 0; i < samples.length; i += 1) {
    const start = samples[i];
    if (!start.local) {
      continue;
    }
    const end = samples.find(
      (candidate) => candidate.tMs >= start.tMs + windowMs && candidate.local,
    );
    if (!end) {
      continue;
    }
    const moved = horizontalDistance(start.local, end.local) ?? 0;
    if (moved < minWindowMoveCm) {
      stuckWindows.push({ fromMs: start.tMs, toMs: end.tMs, moved });
    }
  }

  const minLocalHorizontalCm = Math.max(2_000, Math.floor(durationMs * 0.12));
  const minAuthorityHorizontalCm = Math.max(1_500, Math.floor(durationMs * 0.08));
  const maxAuthorityDistanceCm = 1_200;

  const assertions = {
    continuous: localHorizontalCm >= minLocalHorizontalCm && stuckWindows.length === 0,
    authorityMoved: authorityHorizontalCm >= minAuthorityHorizontalCm,
    authorityBounded: maxLocalAuthorityDistanceCm <= maxAuthorityDistanceCm,
    ackHealthy: ackDelta >= minAckDelta,
    noRouteErrors: noRouteError,
    notBlocked: lateBlockedSamples.length === 0 && lateAuthorityUnavailableSamples.length <= 1,
  };
  return {
    key: options.key,
    durationMs,
    sampleIntervalMs,
    thresholds: {
      minAckDelta,
      minLocalHorizontalCm,
      minAuthorityHorizontalCm,
      maxAuthorityDistanceCm,
      minWindowMoveCm,
      windowMs,
    },
    localHorizontalCm,
    authorityHorizontalCm,
    maxLocalAuthorityDistanceCm,
    maxLocalAuthorityDisplayDistanceCm,
    ackDelta,
    startAckCount,
    endAckCount,
    routeErrorSamples,
    lateBlockedSamples,
    lateAuthorityUnavailableSamples,
    stuckWindows,
    assertions,
    passed: Object.values(assertions).every(Boolean),
  };
}

function buildFrameDisplacementVerdict(frameTraceData, options) {
  const samples = Array.isArray(frameTraceData?.samples) ? frameTraceData.samples : [];
  const targetHz = 60;
  const durationMs = options.durationMs;
  const warmupMs = Math.max(
    0,
    Number.parseInt(process.env.BROWSER_MOVEMENT_FRAME_WARMUP_MS || "5000", 10),
  );
  const firstTimedSample = samples.find((sample) => Number.isFinite(Number(sample?.nowMs))) || null;
  const lastTimedSample =
    [...samples].reverse().find((sample) => Number.isFinite(Number(sample?.nowMs))) || null;
  const traceDurationMs =
    firstTimedSample && lastTimedSample
      ? Math.max(0, Number(lastTimedSample.nowMs) - Number(firstTimedSample.nowMs))
      : 0;
  const effectiveHz =
    traceDurationMs > 0 && samples.length > 1
      ? ((samples.length - 1) * 1000) / traceDurationMs
      : null;
  const firstNowMs = firstTimedSample ? Number(firstTimedSample.nowMs) : null;
  const comparedSamples = samples.filter((sample) => {
    if (firstNowMs === null || !Number.isFinite(Number(sample?.nowMs))) {
      return true;
    }
    return Number(sample.nowMs) - firstNowMs >= warmupMs;
  });
  const completeSamples = comparedSamples.filter(
    (sample) =>
      finiteNumber(sample?.deltaDistance) !== null &&
      finiteNumber(sample?.authorityRenderDeltaDistance) !== null &&
      finiteNumber(sample?.authorityProjectedDeltaDistance) !== null &&
      finiteNumber(sample?.authorityDisplayDeltaDistance) !== null &&
      finiteNumber(sample?.localAuthorityRenderDistance) !== null &&
      finiteNumber(sample?.localAuthorityProjectedDistance) !== null &&
      finiteNumber(sample?.localAuthorityDisplayDistance) !== null,
  );
  const localDeltaDistances = completeSamples.map((sample) => finiteNumber(sample.deltaDistance));
  const authorityDeltaDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityDeltaDistance),
  );
  const authorityRenderDeltaDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityRenderDeltaDistance),
  );
  const authorityProjectedDeltaDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityProjectedDeltaDistance),
  );
  const authorityDisplayDeltaDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityDisplayDeltaDistance),
  );
  const deltaDistanceDiffs = completeSamples.map((sample) => {
    const localDelta = finiteNumber(sample.deltaDistance);
    const authorityRenderDelta = finiteNumber(sample.authorityRenderDeltaDistance);
    return localDelta === null || authorityRenderDelta === null
      ? null
      : Math.abs(localDelta - authorityRenderDelta);
  });
  const projectedDeltaDistanceDiffs = completeSamples.map((sample) => {
    const localDelta = finiteNumber(sample.deltaDistance);
    const authorityProjectedDelta = finiteNumber(sample.authorityProjectedDeltaDistance);
    return localDelta === null || authorityProjectedDelta === null
      ? null
      : Math.abs(localDelta - authorityProjectedDelta);
  });
  const displayDeltaDistanceDiffs = completeSamples.map((sample) => {
    const localDelta = finiteNumber(sample.deltaDistance);
    const authorityDisplayDelta = finiteNumber(sample.authorityDisplayDeltaDistance);
    return localDelta === null || authorityDisplayDelta === null
      ? null
      : Math.abs(localDelta - authorityDisplayDelta);
  });
  const horizontalDeltaDistanceDiffs = completeSamples.map((sample) => {
    const localDelta = horizontalDeltaDistance(sample, "");
    const authorityRenderDelta = horizontalDeltaDistance(sample, "authorityRender");
    return localDelta === null || authorityRenderDelta === null
      ? null
      : Math.abs(localDelta - authorityRenderDelta);
  });
  const projectedHorizontalDeltaDistanceDiffs = completeSamples.map((sample) => {
    const localDelta = horizontalDeltaDistance(sample, "");
    const authorityProjectedDelta = horizontalDeltaDistance(sample, "authorityProjected");
    return localDelta === null || authorityProjectedDelta === null
      ? null
      : Math.abs(localDelta - authorityProjectedDelta);
  });
  const displayHorizontalDeltaDistanceDiffs = completeSamples.map((sample) => {
    const localDelta = horizontalDeltaDistance(sample, "");
    const authorityDisplayDelta = horizontalDeltaDistance(sample, "authorityDisplay");
    return localDelta === null || authorityDisplayDelta === null
      ? null
      : Math.abs(localDelta - authorityDisplayDelta);
  });
  const localAuthorityDistances = completeSamples.map((sample) =>
    finiteNumber(sample.localAuthorityDistance),
  );
  const localAuthorityRenderDistances = completeSamples.map((sample) =>
    finiteNumber(sample.localAuthorityRenderDistance),
  );
  const localAuthorityProjectedDistances = completeSamples.map((sample) =>
    finiteNumber(sample.localAuthorityProjectedDistance),
  );
  const localAuthorityDisplayDistances = completeSamples.map((sample) =>
    finiteNumber(sample.localAuthorityDisplayDistance),
  );
  const authorityRenderAuthorityDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityRenderAuthorityDistance),
  );
  const authorityProjectedAuthorityDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityProjectedAuthorityDistance),
  );
  const authorityDisplayAuthorityDistances = completeSamples.map((sample) =>
    finiteNumber(sample.authorityDisplayAuthorityDistance),
  );
  const deltaDiffSummary = summarizeNumbers(deltaDistanceDiffs);
  const projectedDeltaDiffSummary = summarizeNumbers(projectedDeltaDistanceDiffs);
  const displayDeltaDiffSummary = summarizeNumbers(displayDeltaDistanceDiffs);
  const horizontalDeltaDiffSummary = summarizeNumbers(horizontalDeltaDistanceDiffs);
  const projectedHorizontalDeltaDiffSummary = summarizeNumbers(projectedHorizontalDeltaDistanceDiffs);
  const displayHorizontalDeltaDiffSummary = summarizeNumbers(displayHorizontalDeltaDistanceDiffs);
  const localAuthorityRenderSummary = summarizeNumbers(localAuthorityRenderDistances);
  const localAuthorityProjectedSummary = summarizeNumbers(localAuthorityProjectedDistances);
  const localAuthorityDisplaySummary = summarizeNumbers(localAuthorityDisplayDistances);
  const minComparedSamples = Math.max(30, Math.floor(durationMs / 250));
  const maxDeltaDistanceDiffCm = Math.max(
    50,
    Number.parseFloat(process.env.BROWSER_MOVEMENT_FRAME_MAX_DELTA_DIFF_CM || "500"),
  );
  const maxDeltaDistanceDiffP95Cm = Math.max(
    20,
    Number.parseFloat(process.env.BROWSER_MOVEMENT_FRAME_P95_DELTA_DIFF_CM || "180"),
  );
  const maxLocalAuthorityRenderDistanceCm = Math.max(
    200,
    Number.parseFloat(process.env.BROWSER_MOVEMENT_FRAME_MAX_DISPLAY_DISTANCE_CM || "1200"),
  );
  const maxLocalAuthorityRenderDistanceP95Cm = Math.max(
    120,
    Number.parseFloat(process.env.BROWSER_MOVEMENT_FRAME_P95_DISPLAY_DISTANCE_CM || "600"),
  );
  const maxLocalAuthorityDisplayDistanceCm = Math.max(
    2,
    Number.parseFloat(process.env.BROWSER_MOVEMENT_FRAME_MAX_DISPLAY_DISTANCE_CM || "5"),
  );
  const maxLocalAuthorityDisplayDistanceP95Cm = Math.max(
    1,
    Number.parseFloat(process.env.BROWSER_MOVEMENT_FRAME_P95_DISPLAY_DISTANCE_CM || "2"),
  );
  const assertions = {
    samplesCaptured: completeSamples.length >= minComparedSamples,
    deltaDiffBounded:
      (displayDeltaDiffSummary?.max ?? Infinity) <= maxDeltaDistanceDiffCm &&
      (displayDeltaDiffSummary?.p95 ?? Infinity) <= maxDeltaDistanceDiffP95Cm,
    horizontalDeltaDiffBounded:
      (displayHorizontalDeltaDiffSummary?.max ?? Infinity) <= maxDeltaDistanceDiffCm &&
      (displayHorizontalDeltaDiffSummary?.p95 ?? Infinity) <= maxDeltaDistanceDiffP95Cm,
    displayDistanceBounded:
      (localAuthorityDisplaySummary?.max ?? Infinity) <= maxLocalAuthorityDisplayDistanceCm &&
      (localAuthorityDisplaySummary?.p95 ?? Infinity) <= maxLocalAuthorityDisplayDistanceP95Cm,
  };
  return {
    targetHz,
    effectiveHz,
    warmupMs,
    traceDurationMs,
    rawFrameCount: samples.length,
    comparedFrameCount: comparedSamples.length,
    completeFrameCount: completeSamples.length,
    thresholds: {
      minComparedSamples,
      maxDeltaDistanceDiffCm,
      maxDeltaDistanceDiffP95Cm,
      maxLocalAuthorityRenderDistanceCm,
      maxLocalAuthorityRenderDistanceP95Cm,
      maxLocalAuthorityDisplayDistanceCm,
      maxLocalAuthorityDisplayDistanceP95Cm,
    },
    localDeltaDistance: summarizeNumbers(localDeltaDistances),
    authorityDeltaDistance: summarizeNumbers(authorityDeltaDistances),
    authorityRenderDeltaDistance: summarizeNumbers(authorityRenderDeltaDistances),
    authorityProjectedDeltaDistance: summarizeNumbers(authorityProjectedDeltaDistances),
    authorityDisplayDeltaDistance: summarizeNumbers(authorityDisplayDeltaDistances),
    deltaDistanceDiff: displayDeltaDiffSummary,
    horizontalDeltaDistanceDiff: displayHorizontalDeltaDiffSummary,
    rawAuthorityRenderDeltaDistanceDiff: deltaDiffSummary,
    rawAuthorityRenderHorizontalDeltaDistanceDiff: horizontalDeltaDiffSummary,
    projectedDeltaDistanceDiff: projectedDeltaDiffSummary,
    projectedHorizontalDeltaDistanceDiff: projectedHorizontalDeltaDiffSummary,
    localAuthorityDistance: summarizeNumbers(localAuthorityDistances),
    localAuthorityRenderDistance: localAuthorityRenderSummary,
    localAuthorityProjectedDistance: localAuthorityProjectedSummary,
    localAuthorityDisplayDistance: localAuthorityDisplaySummary,
    authorityRenderAuthorityDistance: summarizeNumbers(authorityRenderAuthorityDistances),
    authorityProjectedAuthorityDistance: summarizeNumbers(authorityProjectedAuthorityDistances),
    authorityDisplayAuthorityDistance: summarizeNumbers(authorityDisplayAuthorityDistances),
    assertions,
    passed: Object.values(assertions).every(Boolean),
  };
}

async function runLongContinuousMovement(page) {
  if (process.env.BROWSER_MOVEMENT_LONG_RUN === "0") {
    summary.longMovement = { skipped: true, reason: "BROWSER_MOVEMENT_LONG_RUN=0" };
    return;
  }

  const durationMs = resolveLongMovementDurationMs();
  const rawSampleIntervalMs = Number.parseInt(
    process.env.BROWSER_MOVEMENT_LONG_SAMPLE_MS || "1000",
    10,
  );
  const sampleIntervalMs = Number.isFinite(rawSampleIntervalMs)
    ? Math.max(250, Math.min(rawSampleIntervalMs, 2_000))
    : 1_000;
  const keyConfig = longMovementKeyConfig();
  await page.bringToFront();
  await waitForAuthoritativeChunk(
    page,
    { x: 0, y: 0, z: 0 },
    "long movement starting authoritative chunk",
  );
  await waitForInitialAuthoritativeCoverage(page, "long movement initial authoritative coverage");
  await page.cli("frame_trace_clear");
  await page.cli(`frame_trace_start ${Math.ceil(durationMs / 16) + 120}`);

  const samples = [];
  const startedMs = Date.now();
  samples.push(compactLongMovementSnapshot(await page.cli("snapshot"), 0));
  await setMovementKey(page, keyConfig, true);
  try {
    while (Date.now() - startedMs < durationMs) {
      await sleep(sampleIntervalMs);
      samples.push(
        compactLongMovementSnapshot(await page.cli("snapshot"), Date.now() - startedMs),
      );
    }
  } finally {
    await setMovementKey(page, keyConfig, false);
  }

  await sleep(500);
  samples.push(compactLongMovementSnapshot(await page.cli("snapshot"), Date.now() - startedMs));
  const frameTrace = await page.cli("frame_trace");
  const verdict = buildLongMovementVerdict(samples, {
    key: keyConfig.code,
    durationMs,
    sampleIntervalMs,
  });
  const frameDisplacement = buildFrameDisplacementVerdict(frameTrace.data, { durationMs });

  summary.assertions.longMovementContinuous = verdict.assertions.continuous;
  summary.assertions.longMovementAuthorityMoved = verdict.assertions.authorityMoved;
  summary.assertions.longMovementAuthorityBounded = verdict.assertions.authorityBounded;
  summary.assertions.longMovementAckHealthy = verdict.assertions.ackHealthy;
  summary.assertions.longMovementNoRouteErrors = verdict.assertions.noRouteErrors;
  summary.assertions.longMovementNotBlocked = verdict.assertions.notBlocked;
  summary.assertions.longMovementFrameDisplacement = frameDisplacement.passed;
  summary.longMovement = {
    ...verdict,
    passed: verdict.passed && frameDisplacement.passed,
    firstSample: samples[0] ?? null,
    lastSample: samples[samples.length - 1] ?? null,
    samples,
    frameDisplacement,
    frameTrace: {
      frameCount: frameTrace.data?.frameCount ?? null,
      deltaDistance: frameTrace.data?.deltaDistance ?? null,
      authorityDeltaDistance: frameTrace.data?.authorityDeltaDistance ?? null,
      authorityRenderDeltaDistance: frameTrace.data?.authorityRenderDeltaDistance ?? null,
      authorityProjectedDeltaDistance:
        frameTrace.data?.authorityProjectedDeltaDistance ?? null,
      authorityDisplayDeltaDistance: frameTrace.data?.authorityDisplayDeltaDistance ?? null,
      localAuthorityDistance: frameTrace.data?.localAuthorityDistance ?? null,
      localAuthorityRenderDistance: frameTrace.data?.localAuthorityRenderDistance ?? null,
      localAuthorityProjectedDistance:
        frameTrace.data?.localAuthorityProjectedDistance ?? null,
      localAuthorityDisplayDistance: frameTrace.data?.localAuthorityDisplayDistance ?? null,
      authorityRenderAuthorityDistance:
        frameTrace.data?.authorityRenderAuthorityDistance ?? null,
      authorityProjectedAuthorityDistance:
        frameTrace.data?.authorityProjectedAuthorityDistance ?? null,
      authorityDisplayAuthorityDistance:
        frameTrace.data?.authorityDisplayAuthorityDistance ?? null,
      recentSamples: (frameTrace.data?.samples || []).slice(-40),
    },
  };

  if (!summary.longMovement.passed) {
    throw new Error(`long continuous movement failed: ${JSON.stringify(summary.longMovement)}`);
  }
}

async function main() {
  const authPort = await getFreeTcpPort();
  const visualizePort = await getFreeTcpPort();
  const gateTcpPort = await getFreeTcpPort();
  const gateUdpPort = await getFreeTcpPort();
  const vitePort = await getFreeTcpPort();
  const chromePort = await getFreeTcpPort();
  const networkEmulation = resolveNetworkEmulationConfig(process.env);
  const reconnectSmokeEnabled = process.env.BROWSER_MOVEMENT_RECONNECT_SMOKE !== "0";
  const reconnectCycleCount = reconnectSmokeEnabled ? resolveReconnectCycleCount(process.env) : 0;
  const useWsProxy = networkEmulation.enabled || reconnectSmokeEnabled;
  const wsProxyPort = useWsProxy ? await getFreeTcpPort() : null;
  const longOnly = process.env.BROWSER_MOVEMENT_LONG_ONLY === "1";
  const mixEnv = process.env.BROWSER_SMOKE_MIX_ENV || "dev";

  Object.assign(summary.ports, {
    authPort,
    visualizePort,
    gateTcpPort,
    gateUdpPort,
    vitePort,
    chromePort,
    ...(wsProxyPort === null ? {} : { wsProxyPort }),
  });
  summary.networkEmulation = {
    ...networkEmulation,
    reconnectSmokeEnabled,
    reconnectCycleCount,
    longOnly,
    transport:
      wsProxyPort === null
        ? "direct"
        : networkEmulation.enabled
          ? "websocket-netem-proxy"
          : "websocket-drop-proxy",
  };

  const bootEnv = {
    ...process.env,
    MIX_ENV: mixEnv,
    AUTH_PORT: String(authPort),
    VISUALIZE_PORT: String(visualizePort),
    GATE_TCP_PORT: String(gateTcpPort),
    GATE_UDP_PORT: String(gateUdpPort),
    GATE_SERVER_OBSERVE_LOG: gateObserve,
    SCENE_SERVER_OBSERVE_LOG: sceneObserve,
    WS_SMOKE_READY_FILE: readyFile,
    WS_SMOKE_PRESEED_VOXEL: "1",
    ...(networkEmulation.bytesPerSecond > 0
      ? { AUTH_GAME_WS_BULK_BYTES_PER_SEC: String(networkEmulation.bytesPerSecond) }
      : {}),
  };

  if (process.env.BROWSER_SMOKE_SKIP_DB_SETUP !== "1") {
    const db = mixInvocation(["run", "--no-start", "scripts/ws_smoke_db_setup.exs"]);
    runChecked(db.command, db.args, {
      env: bootEnv,
      stdout: dbOut,
      stderr: dbErr,
      label: "database setup",
    });
  }

  const bootCommand = mixInvocation(["run", "--no-start", "scripts/ws_smoke_boot.exs"]);
  const boot = spawn(bootCommand.command, bootCommand.args, {
    cwd: root,
    env: bootEnv,
    stdio: ["ignore", "pipe", "pipe"],
    detached: process.platform !== "win32",
  });
  appendStream(boot.stdout, bootOut);
  appendStream(boot.stderr, bootErr);

  let vite = null;
  let chrome = null;
  let pageA = null;
  let pageB = null;
  let wsProxy = null;

  try {
    await waitForFile(readyFile, boot, 60_000);
    await waitForHttpReady(`http://127.0.0.1:${authPort}`, 60_000);
    if (useWsProxy) {
      wsProxy = await startWebSocketDelayProxy({
        listenHost: "127.0.0.1",
        listenPort: wsProxyPort,
        upstreamHost: "127.0.0.1",
        upstreamPort: authPort,
        config: networkEmulation,
      });
      activeWsProxy = wsProxy;
    }

    vite = spawn(
      process.platform === "win32" ? "cmd.exe" : "npm",
      process.platform === "win32"
        ? ["/c", "npm", "run", "dev", "--", "--port", String(vitePort), "--host", "127.0.0.1"]
        : ["run", "dev", "--", "--port", String(vitePort), "--host", "127.0.0.1"],
      {
        cwd: clientDir,
        env: {
          ...process.env,
          VITE_INGAME_PROXY_TARGET: `http://127.0.0.1:${authPort}`,
          VITE_GAME_WS_URL: `ws://127.0.0.1:${wsProxyPort ?? authPort}/ingame/ws`,
          VITE_RENDER_BACKEND: "webgl",
          VITE_VOXEL_DEV_SEED: "0",
          VITE_VOXEL_SUBSCRIBE_RADIUS: String(resolveInitialVoxelSubscribeRadius()),
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    appendStream(vite.stdout, viteOut);
    appendStream(vite.stderr, viteErr);
    await waitForHttpReady(`http://127.0.0.1:${vitePort}`, 60_000);

    const browserExecutable = findBrowserExecutable();
    if (!browserExecutable) {
      throw new Error(
        "Chrome/Edge executable not found. Set BROWSER_SMOKE_CHROME_PATH to a Chromium-compatible browser.",
      );
    }
    summary.browser.executable = browserExecutable;
    const userDataDir = path.join(demoDir, `browser-movement-smoke-profile-${runId}`);
    fs.mkdirSync(userDataDir, { recursive: true });

    const chromeArgs = [
      `--remote-debugging-port=${chromePort}`,
      `--user-data-dir=${userDataDir}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-dev-shm-usage",
      "--disable-renderer-backgrounding",
      "--disable-features=CalculateNativeWinOcclusion",
      "--use-angle=swiftshader",
      "--window-size=1280,900",
    ];
    if (process.env.BROWSER_SMOKE_HEADLESS !== "0") {
      chromeArgs.push("--headless=new");
    }
    chrome = spawn(browserExecutable, chromeArgs, {
      cwd: root,
      stdio: ["ignore", "pipe", "pipe"],
    });
    appendStream(chrome.stdout, browserOut);
    appendStream(chrome.stderr, browserErr);
    await waitForHttpReady(`http://127.0.0.1:${chromePort}/json/version`, 20_000);

    const url = `http://127.0.0.1:${vitePort}/?renderer=webgl&browser_movement_smoke=1`;
    summary.browser.url = url;
    const wsA = await createChromeTarget(chromePort, `${url}&tab=A`);
    pageA = new CdpPage("A", wsA, consoleA);
    await pageA.connect();
    await pageA.bringToFront();

    const movementA = await waitForTransportReady(pageA, "A");
    await waitForSceneSpawnApplied(pageA, "A");

    if (longOnly) {
      await runLongContinuousMovement(pageA);

      summary.status = "ok";
      summary.tabs.A = { ...summary.tabs.A, finalTransport: (await pageA.cli("transport")).data };
      summary.tabs.A.finalObserve = await pageA.evaluate("window.__voxelObserve?.recent(80) ?? []");
      if (wsProxy && typeof wsProxy.getStats === "function") {
        summary.networkEmulation.proxyStats = wsProxy.getStats();
      }
      writeSummary();
      process.stdout.write(`summary=${path.relative(root, summaryFile)}\n`);
      return;
    }

    const wsB = await createChromeTarget(chromePort, `${url}&tab=B`);
    pageB = new CdpPage("B", wsB, consoleB);
    await pageB.connect();
    await pageB.bringToFront();

    const movementB = await waitForTransportReady(pageB, "B");
    await waitForSceneSpawnApplied(pageB, "B");
    await waitForCli(
      pageB,
      "players",
      (result) => remoteEntity(result, movementA.cid) !== null,
      "B observes A remote entity",
      20_000,
    );
    summary.assertions.remoteEnterObserved = true;

    if (reconnectSmokeEnabled) {
      await runReconnectCheck(pageA, pageB, movementA.cid, wsProxy, reconnectCycleCount);
    }
    await pageA.bringToFront();
    await runOverheadBlockCheck(pageA);
    await sampleLocalJump(pageA);
    await sampleRemoteJump(pageA, pageB, movementA.cid);
    await runClockSoak(pageA, pageB);
    await runLongContinuousMovement(pageA);

    summary.status = "ok";
    summary.tabs.A = { ...summary.tabs.A, finalTransport: (await pageA.cli("transport")).data };
    summary.tabs.B = { ...summary.tabs.B, finalTransport: (await pageB.cli("transport")).data };
    summary.tabs.A.finalObserve = await pageA.evaluate("window.__voxelObserve?.recent(80) ?? []");
    summary.tabs.B.finalObserve = await pageB.evaluate("window.__voxelObserve?.recent(80) ?? []");
    if (wsProxy && typeof wsProxy.getStats === "function") {
      summary.networkEmulation.proxyStats = wsProxy.getStats();
    }
    writeSummary();
    process.stdout.write(`summary=${path.relative(root, summaryFile)}\n`);
  } finally {
    pageA?.close();
    pageB?.close();
    killTree(chrome);
    killTree(vite);
    killTree(boot);
    if (summary.networkEmulation && wsProxy && typeof wsProxy.getStats === "function") {
      summary.networkEmulation.proxyStats = wsProxy.getStats();
    }
    await wsProxy?.close();
    activeWsProxy = null;
  }
}

main().catch((error) => {
  fail(1, error.stack || String(error));
});
