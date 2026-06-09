const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");
const { spawn, spawnSync, execFileSync } = require("node:child_process");

if (typeof WebSocket !== "function") {
  throw new Error("browser smoke requires Node.js 22+ with global WebSocket");
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
    cwd: options.cwd ?? options.root,
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
      throw new Error(
        `boot exited before ready file was written, code=${child.exitCode}`,
      );
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
          path.join(
            process.env.PROGRAMFILES || "",
            "Google",
            "Chrome",
            "Application",
            "chrome.exe",
          ),
          path.join(
            process.env["PROGRAMFILES(X86)"] || "",
            "Google",
            "Chrome",
            "Application",
            "chrome.exe",
          ),
          path.join(
            process.env.LOCALAPPDATA || "",
            "Google",
            "Chrome",
            "Application",
            "chrome.exe",
          ),
          path.join(
            process.env.PROGRAMFILES || "",
            "Microsoft",
            "Edge",
            "Application",
            "msedge.exe",
          ),
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

  const explicit = candidates.find(
    (candidate) => candidate && fs.existsSync(candidate),
  );
  if (explicit) {
    return explicit;
  }
  return findCommandOnPath([
    "chrome",
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "msedge",
  ]);
}

async function createChromeTarget(port, url) {
  const encodedUrl = encodeURIComponent(url);
  let response = await fetch(
    `http://127.0.0.1:${port}/json/new?${encodedUrl}`,
    { method: "PUT" },
  );
  if (!response.ok) {
    response = await fetch(`http://127.0.0.1:${port}/json/new?${encodedUrl}`);
  }
  if (!response.ok) {
    throw new Error(`failed to create chrome target: ${response.status}`);
  }
  const target = await response.json();
  if (!target.webSocketDebuggerUrl) {
    throw new Error(
      `chrome target missing websocket url: ${JSON.stringify(target)}`,
    );
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
    this.socket.addEventListener("message", (event) =>
      this.onMessage(event.data),
    );
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`${this.label} CDP connect timeout`)),
        10_000,
      );
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
      throw new Error(
        `${this.label} evaluate failed: ${formatException(response.exceptionDetails)}`,
      );
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
        pending.reject(
          new Error(
            `${this.label} ${pending.method}: ${JSON.stringify(message.error)}`,
          ),
        );
      } else {
        pending.resolve(message.result || {});
      }
      return;
    }

    if (message.method === "Runtime.consoleAPICalled") {
      const parts = (message.params?.args || []).map((arg) =>
        arg.value !== undefined
          ? String(arg.value)
          : arg.description || arg.type || "",
      );
      fs.appendFileSync(
        this.consoleFile,
        `${new Date().toISOString()} ${parts.join(" ")}\n`,
      );
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
  return (
    details.exception?.description || details.text || JSON.stringify(details)
  );
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

function resolveRunId(startedAt = new Date().toISOString()) {
  return startedAt.replace(/[:.]/g, "-");
}

function relativePath(root, filename) {
  return path.relative(root, filename);
}

async function startBrowserSmokeRuntime(options = {}) {
  const root = options.root ?? path.resolve(__dirname, "..");
  const clientDir =
    options.clientDir ?? path.join(root, "clients", "web_client");
  const demoDir = options.demoDir ?? path.join(root, ".demo");
  const observeDir = options.observeDir ?? path.join(demoDir, "observe");
  const prefix = options.prefix ?? "browser-smoke";
  const runId = options.runId ?? resolveRunId();
  fs.mkdirSync(observeDir, { recursive: true });

  const paths = {
    bootOut: path.join(observeDir, `${prefix}.server.out.log`),
    bootErr: path.join(observeDir, `${prefix}.server.err.log`),
    dbOut: path.join(observeDir, `${prefix}.db.out.log`),
    dbErr: path.join(observeDir, `${prefix}.db.err.log`),
    viteOut: path.join(observeDir, `${prefix}.vite.out.log`),
    viteErr: path.join(observeDir, `${prefix}.vite.err.log`),
    browserOut: path.join(observeDir, `${prefix}.browser.out.log`),
    browserErr: path.join(observeDir, `${prefix}.browser.err.log`),
    gateObserve: path.join(observeDir, `${prefix}.gate-observe.log`),
    sceneObserve: path.join(observeDir, `${prefix}.scene-observe.log`),
    readyFile: path.join(observeDir, `${prefix}-${runId}.ready`),
  };

  for (const filename of Object.values(paths)) {
    fs.writeFileSync(filename, "");
  }

  const authPort = await getFreeTcpPort();
  const visualizePort = await getFreeTcpPort();
  const gateTcpPort = await getFreeTcpPort();
  const gateUdpPort = await getFreeTcpPort();
  const vitePort = await getFreeTcpPort();
  const chromePort = await getFreeTcpPort();
  const ports = {
    authPort,
    visualizePort,
    gateTcpPort,
    gateUdpPort,
    vitePort,
    chromePort,
  };

  const mixEnv = process.env.BROWSER_SMOKE_MIX_ENV || "dev";
  const bootEnv = {
    ...process.env,
    MIX_ENV: mixEnv,
    AUTH_PORT: String(authPort),
    VISUALIZE_PORT: String(visualizePort),
    GATE_TCP_PORT: String(gateTcpPort),
    GATE_UDP_PORT: String(gateUdpPort),
    GATE_SERVER_OBSERVE_LOG: paths.gateObserve,
    SCENE_SERVER_OBSERVE_LOG: paths.sceneObserve,
    WS_SMOKE_READY_FILE: paths.readyFile,
    WS_SMOKE_PRESEED_VOXEL: options.preseedVoxel === false ? "0" : "1",
    ...(options.bootEnv ?? {}),
  };

  if (process.env.BROWSER_SMOKE_SKIP_DB_SETUP !== "1") {
    const db = mixInvocation([
      "run",
      "--no-start",
      "scripts/ws_smoke_db_setup.exs",
    ]);
    runChecked(db.command, db.args, {
      root,
      env: bootEnv,
      stdout: paths.dbOut,
      stderr: paths.dbErr,
      label: "database setup",
    });
  }

  const bootCommand = mixInvocation([
    "run",
    "--no-start",
    "scripts/ws_smoke_boot.exs",
  ]);
  const boot = spawn(bootCommand.command, bootCommand.args, {
    cwd: root,
    env: bootEnv,
    stdio: ["ignore", "pipe", "pipe"],
    detached: process.platform !== "win32",
  });
  appendStream(boot.stdout, paths.bootOut);
  appendStream(boot.stderr, paths.bootErr);

  let vite = null;
  let chrome = null;
  const pages = [];

  const close = () => {
    for (const page of pages) {
      page.close();
    }
    killTree(chrome);
    killTree(vite);
    killTree(boot);
  };

  try {
    await waitForFile(paths.readyFile, boot, 60_000);
    await waitForHttpReady(`http://127.0.0.1:${authPort}`, 60_000);

    const viteArgs =
      process.platform === "win32"
        ? [
            "/c",
            "npm",
            "run",
            "dev",
            "--",
            "--port",
            String(vitePort),
            "--host",
            "127.0.0.1",
          ]
        : [
            "run",
            "dev",
            "--",
            "--port",
            String(vitePort),
            "--host",
            "127.0.0.1",
          ];
    vite = spawn(process.platform === "win32" ? "cmd.exe" : "npm", viteArgs, {
      cwd: clientDir,
      env: {
        ...process.env,
        VITE_INGAME_PROXY_TARGET: `http://127.0.0.1:${authPort}`,
        VITE_GAME_WS_URL: `ws://127.0.0.1:${authPort}/ingame/ws`,
        VITE_RENDER_BACKEND: "webgl",
        VITE_VOXEL_DEV_SEED: "0",
        VITE_VOXEL_SUBSCRIBE_RADIUS: "1",
        ...(options.viteEnv ?? {}),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    appendStream(vite.stdout, paths.viteOut);
    appendStream(vite.stderr, paths.viteErr);
    await waitForHttpReady(`http://127.0.0.1:${vitePort}`, 60_000);

    const browserExecutable = findBrowserExecutable();
    if (!browserExecutable) {
      throw new Error(
        "Chrome/Edge executable not found. Set BROWSER_SMOKE_CHROME_PATH to a Chromium-compatible browser.",
      );
    }

    const userDataDir = path.join(demoDir, `${prefix}-profile-${runId}`);
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
      "--window-size=1280,900",
    ];
    if (process.env.BROWSER_SMOKE_USE_SWIFTSHADER !== "0") {
      chromeArgs.push("--use-angle=swiftshader");
    }
    if (process.env.BROWSER_SMOKE_HEADLESS !== "0") {
      chromeArgs.push("--headless=new");
    }
    chrome = spawn(browserExecutable, chromeArgs, {
      cwd: root,
      stdio: ["ignore", "pipe", "pipe"],
    });
    appendStream(chrome.stdout, paths.browserOut);
    appendStream(chrome.stderr, paths.browserErr);
    await waitForHttpReady(
      `http://127.0.0.1:${chromePort}/json/version`,
      20_000,
    );

    const urlFlag = options.urlFlag ?? prefix.replace(/-/g, "_");
    const baseUrl = `http://127.0.0.1:${vitePort}/?renderer=webgl&${urlFlag}=1`;

    return {
      root,
      clientDir,
      observeDir,
      prefix,
      runId,
      ports,
      paths,
      browser: {
        executable: browserExecutable,
        userDataDir,
        baseUrl,
      },
      createPage: async (label, extraQuery = "") => {
        const suffix = extraQuery ? `&${extraQuery.replace(/^&/, "")}` : "";
        const url = `${baseUrl}&tab=${encodeURIComponent(label)}${suffix}`;
        const consoleFile = path.join(
          observeDir,
          `${prefix}.${label}.console.log`,
        );
        fs.writeFileSync(consoleFile, "");
        const wsUrl = await createChromeTarget(chromePort, url);
        const page = new CdpPage(label, wsUrl, consoleFile);
        await page.connect();
        await page.bringToFront();
        pages.push(page);
        return { page, url, consoleFile };
      },
      close,
    };
  } catch (error) {
    close();
    throw error;
  }
}

module.exports = {
  CdpPage,
  appendStream,
  createChromeTarget,
  findBrowserExecutable,
  getFreeTcpPort,
  killTree,
  mixInvocation,
  relativePath,
  resolveRunId,
  runChecked,
  sleep,
  startBrowserSmokeRuntime,
  waitForCli,
  waitForFile,
  waitForHttpReady,
};
