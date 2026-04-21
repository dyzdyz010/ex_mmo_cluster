const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const dgram = require('node:dgram');
const { spawn, execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const demoDir = path.join(root, '.demo');
fs.mkdirSync(demoDir, { recursive: true });

const bootOut = path.join(demoDir, 'ws-dual-supervised.boot.out.log');
const bootErr = path.join(demoDir, 'ws-dual-supervised.boot.err.log');
const probeOut = path.join(demoDir, 'ws-dual-supervised.probe.out.log');
const probeErr = path.join(demoDir, 'ws-dual-supervised.probe.err.log');

for (const filename of [bootOut, bootErr, probeOut, probeErr]) {
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

function killTree(pid) {
  if (!pid) {
    return;
  }

  try {
    execFileSync('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
  } catch {
    // ignore cleanup failures
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

async function waitForExit(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
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

  const bootEnv = {
    ...process.env,
    AUTH_PORT: String(authPort),
    VISUALIZE_PORT: String(visualizePort),
    GATE_TCP_PORT: String(gateTcpPort),
    GATE_UDP_PORT: String(gateUdpPort),
  };

  const boot = spawn('cmd.exe', ['/c', 'mix run --no-start scripts/ws_smoke_boot.exs'], {
    cwd: root,
    env: bootEnv,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  appendStream(boot.stdout, bootOut);
  appendStream(boot.stderr, bootErr);

  try {
    await waitForHttpReady(`http://127.0.0.1:${authPort}`, 60_000);

    const probe = spawn(process.execPath, ['scripts/ws_dual_smoke.js'], {
      cwd: root,
      env: {
        ...process.env,
        AUTH_BASE_URL: `http://127.0.0.1:${authPort}`,
        WS_URL: `ws://127.0.0.1:${authPort}/ingame/ws`,
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
  } finally {
    killTree(boot.pid);
  }
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
