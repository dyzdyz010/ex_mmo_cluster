const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");
const { spawn, spawnSync, execFileSync } = require("node:child_process");

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
const readyFile = path.join(observeDir, `browser-movement-smoke-${runId}.ready`);

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
  },
  ports: {},
  browser: {},
  tabs: {},
  overheadBlock: null,
  localJump: null,
  remoteJump: null,
  assertions: {
    tabAReady: false,
    tabBReady: false,
    remoteEnterObserved: false,
    overheadBlockCommitted: false,
    overheadBlockDidNotLiftLocal: false,
    overheadBlockDidNotLiftAuthority: false,
    localJumpRenderedRise: false,
    localJumpAuthorityRise: false,
    localJumpAirborneTrace: false,
    localJumpLanded: false,
    remoteJumpVisible: false,
    remoteJumpAirborne: false,
    remoteJumpRise: false,
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
  const deadline = Date.now() + timeoutMs;
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

function snapshotPositions(snapshotResult) {
  const data = snapshotResult.data || {};
  const actorDisplay = data.actorDisplay || {};
  const local = parseVector(actorDisplay.local);
  const authority = parseVector(actorDisplay.authority);
  return { local, authority };
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
  await sleep(500);
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
    passed: blockCommitted && localStable && authorityStable,
  };

  if (!summary.overheadBlock.passed) {
    throw new Error(`overhead block check failed: ${JSON.stringify(summary.overheadBlock)}`);
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

async function sampleRemoteJump(pageA, pageB, cidA) {
  const startResult = await waitForRemoteGround(pageB, cidA);
  const startEntity = remoteEntity(startResult, cidA);
  if (!startEntity) {
    throw new Error(`remote entity ${cidA} not visible before jump`);
  }
  const startPosition = parseVector(startEntity.renderedPosition);
  if (!startPosition) {
    throw new Error(`remote entity ${cidA} missing rendered position`);
  }

  await pageA.cli("jump");
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
      interpolationMode: entity.interpolationMode ?? null,
    });
  }

  const visibleSamples = samples.filter((sample) => sample.visible && Number.isFinite(sample.y));
  const maxY = Math.max(...visibleSamples.map((sample) => sample.y));
  const airborneSamples = visibleSamples.filter((sample) => sample.movementMode === "airborne");
  const rise = maxY - startPosition.y;

  summary.assertions.remoteJumpVisible = lostSamples === 0 && visibleSamples.length > 0;
  summary.assertions.remoteJumpAirborne = airborneSamples.length > 0;
  summary.assertions.remoteJumpRise = rise >= 25;
  summary.remoteJump = {
    subjectCid: cidA,
    startPosition,
    maxY,
    rise,
    lostSamples,
    airborneSamples: airborneSamples.length,
    samples,
    passed:
      summary.assertions.remoteJumpVisible &&
      summary.assertions.remoteJumpAirborne &&
      summary.assertions.remoteJumpRise,
  };

  if (!summary.remoteJump.passed) {
    throw new Error(`remote jump check failed: ${JSON.stringify(summary.remoteJump)}`);
  }
}

async function main() {
  const authPort = await getFreeTcpPort();
  const visualizePort = await getFreeTcpPort();
  const gateTcpPort = await getFreeTcpPort();
  const gateUdpPort = await getFreeTcpPort();
  const vitePort = await getFreeTcpPort();
  const chromePort = await getFreeTcpPort();
  const mixEnv = process.env.BROWSER_SMOKE_MIX_ENV || "dev";

  Object.assign(summary.ports, {
    authPort,
    visualizePort,
    gateTcpPort,
    gateUdpPort,
    vitePort,
    chromePort,
  });

  const bootEnv = {
    ...process.env,
    MIX_ENV: mixEnv,
    AUTH_PORT: String(authPort),
    VISUALIZE_PORT: String(visualizePort),
    GATE_TCP_PORT: String(gateTcpPort),
    GATE_UDP_PORT: String(gateUdpPort),
    WS_SMOKE_READY_FILE: readyFile,
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

  try {
    await waitForFile(readyFile, boot, 60_000);
    await waitForHttpReady(`http://127.0.0.1:${authPort}`, 60_000);

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
          VITE_GAME_WS_URL: `ws://127.0.0.1:${authPort}/ingame/ws`,
          VITE_RENDER_BACKEND: "webgl",
          VITE_VOXEL_DEV_SEED: "1",
          VITE_VOXEL_DIAGNOSTIC_PARTIAL_WINDOW: "1",
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
      "--disable-dev-shm-usage",
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
    const wsB = await createChromeTarget(chromePort, `${url}&tab=B`);
    pageA = new CdpPage("A", wsA, consoleA);
    pageB = new CdpPage("B", wsB, consoleB);
    await pageA.connect();
    await pageB.connect();

    const movementA = await waitForTransportReady(pageA, "A");
    const movementB = await waitForTransportReady(pageB, "B");
    await waitForCli(
      pageB,
      "players",
      (result) => remoteEntity(result, movementA.cid) !== null,
      "B observes A remote entity",
      20_000,
    );
    summary.assertions.remoteEnterObserved = true;

    await runOverheadBlockCheck(pageA);
    await sampleLocalJump(pageA);
    await sampleRemoteJump(pageA, pageB, movementA.cid);

    summary.status = "ok";
    summary.tabs.A = { ...summary.tabs.A, finalTransport: (await pageA.cli("transport")).data };
    summary.tabs.B = { ...summary.tabs.B, finalTransport: (await pageB.cli("transport")).data };
    summary.tabs.A.finalObserve = await pageA.evaluate("window.__voxelObserve?.recent(80) ?? []");
    summary.tabs.B.finalObserve = await pageB.evaluate("window.__voxelObserve?.recent(80) ?? []");
    writeSummary();
    process.stdout.write(`summary=${path.relative(root, summaryFile)}\n`);
  } finally {
    pageA?.close();
    pageB?.close();
    killTree(chrome);
    killTree(vite);
    killTree(boot);
  }
}

main().catch((error) => {
  fail(1, error.stack || String(error));
});
