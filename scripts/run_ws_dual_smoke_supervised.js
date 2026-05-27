const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const dgram = require('node:dgram');
const { spawn, spawnSync, execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const demoDir = path.join(root, '.demo');
const observeDir = path.join(demoDir, 'observe');
fs.mkdirSync(demoDir, { recursive: true });
fs.mkdirSync(observeDir, { recursive: true });

const bootOut = path.join(observeDir, 'ws-dual-supervised.boot.out.log');
const bootErr = path.join(observeDir, 'ws-dual-supervised.boot.err.log');
const dbOut = path.join(observeDir, 'ws-dual-supervised.db.out.log');
const dbErr = path.join(observeDir, 'ws-dual-supervised.db.err.log');
const probeOut = path.join(observeDir, 'ws-dual-supervised.probe.out.log');
const probeErr = path.join(observeDir, 'ws-dual-supervised.probe.err.log');
const readyFile = path.join(observeDir, 'ws-dual-supervised.ready');
const summaryFile = path.join(observeDir, 'ws-dual-smoke-summary.json');

for (const filename of [bootOut, bootErr, dbOut, dbErr, probeOut, probeErr, readyFile, summaryFile]) {
  fs.writeFileSync(filename, '');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function appendStream(stream, filename) {
  const target = fs.createWriteStream(filename, { flags: 'a' });
  stream.on('data', (chunk) => {
    target.write(chunk);
  });
  stream.on('close', () => target.end());
}

function mixInvocation(args) {
  if (process.platform === 'win32') {
    return { command: 'cmd.exe', args: ['/c', 'mix', ...args] };
  }
  return { command: 'mix', args };
}

function runChecked(command, args, options) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: options.env,
    encoding: 'utf8',
    maxBuffer: 10 * 1024 * 1024,
  });

  fs.writeFileSync(options.stdout, result.stdout || '');
  fs.writeFileSync(options.stderr, result.stderr || '');

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
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port = typeof address === 'object' && address ? address.port : null;
      server.close(() => {
        if (port == null) {
          reject(new Error('no free tcp port'));
        } else {
          resolve(port);
        }
      });
    });
    server.on('error', reject);
  });
}

async function getFreeUdpPort() {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket('udp4');
    socket.bind(0, '127.0.0.1', () => {
      const address = socket.address();
      const port = typeof address === 'object' && address ? address.port : null;
      socket.close(() => {
        if (port == null) {
          reject(new Error('no free udp port'));
        } else {
          resolve(port);
        }
      });
    });
    socket.on('error', reject);
  });
}

function killTree(child) {
  if (!child || !child.pid) {
    return;
  }

  if (process.platform === 'win32') {
    try {
      execFileSync('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
    } catch {
      // ignore cleanup failures
    }
    return;
  }

  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {
    try {
      process.kill(child.pid, 'SIGTERM');
    } catch {
      // ignore cleanup failures
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

async function waitForExit(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      killTree(child);
      reject(new Error(`process timeout after ${timeoutMs}ms`));
    }, timeoutMs);

    child.once('exit', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal });
    });

    child.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function main() {
  const authPort = await getFreeTcpPort();
  const visualizePort = await getFreeTcpPort();
  const gateTcpPort = await getFreeTcpPort();
  const gateUdpPort = await getFreeUdpPort();
  const mixEnv = process.env.WS_SMOKE_MIX_ENV || 'dev';

  const bootEnv = {
    ...process.env,
    MIX_ENV: mixEnv,
    AUTH_PORT: String(authPort),
    VISUALIZE_PORT: String(visualizePort),
    GATE_TCP_PORT: String(gateTcpPort),
    GATE_UDP_PORT: String(gateUdpPort),
    WS_SMOKE_READY_FILE: readyFile,
    // ws_smoke_boot.exs only DevSeeds the default voxel region when this is set.
    // Without a seeded region the dual players enter an unrouted chunk, partition
    // refresh fails with :unroutable_center, and no partition window reaches Scene
    // AOI (so B never observes A). Mirrors the browser-movement supervised smoke.
    WS_SMOKE_PRESEED_VOXEL: '1',
  };

  if (process.env.WS_SMOKE_SKIP_DB_SETUP !== '1') {
    const db = mixInvocation(['run', '--no-start', 'scripts/ws_smoke_db_setup.exs']);
    runChecked(db.command, db.args, {
      env: bootEnv,
      stdout: dbOut,
      stderr: dbErr,
      label: 'database setup',
    });
  }

  const bootCommand = mixInvocation(['run', '--no-start', 'scripts/ws_smoke_boot.exs']);
  const boot = spawn(bootCommand.command, bootCommand.args, {
    cwd: root,
    env: bootEnv,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: process.platform !== 'win32',
  });

  appendStream(boot.stdout, bootOut);
  appendStream(boot.stderr, bootErr);

  try {
    await waitForFile(readyFile, boot, 60_000);
    await waitForHttpReady(`http://127.0.0.1:${authPort}`, 60_000);

    const probe = spawn(process.execPath, ['scripts/ws_dual_smoke.js'], {
      cwd: root,
      env: {
        ...process.env,
        MIX_ENV: mixEnv,
        AUTH_BASE_URL: `http://127.0.0.1:${authPort}`,
        WS_URL: `ws://127.0.0.1:${authPort}/ingame/ws`,
        WS_SMOKE_OBSERVE_DIR: observeDir,
        WS_SMOKE_SUMMARY_PATH: summaryFile,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    appendStream(probe.stdout, probeOut);
    appendStream(probe.stderr, probeErr);

    const result = await waitForExit(probe, 45_000);
    if (result.code !== 0) {
      const output = fs.existsSync(probeOut) ? fs.readFileSync(probeOut, 'utf8') : '';
      const error = fs.existsSync(probeErr) ? fs.readFileSync(probeErr, 'utf8') : '';
      throw new Error(`probe failed code=${result.code} signal=${result.signal}\n${output}\n${error}`);
    }

    const output = fs.existsSync(probeOut) ? fs.readFileSync(probeOut, 'utf8') : '';
    process.stdout.write(output);
    process.stdout.write(`summary=${path.relative(root, summaryFile)}\n`);
  } finally {
    killTree(boot);
  }
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
