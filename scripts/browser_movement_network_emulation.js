const http = require("node:http");
const net = require("node:net");

function resolveNetworkEmulationConfig(env = process.env) {
  const baseDelayMs = parseClampedInteger(env.BROWSER_MOVEMENT_NET_DELAY_MS, 0, 5_000);
  const jitterMs = parseClampedInteger(env.BROWSER_MOVEMENT_NET_JITTER_MS, 0, 5_000);
  const bytesPerSecond = parseClampedInteger(env.BROWSER_MOVEMENT_NET_BYTES_PER_SEC, 0, 10_000_000);
  const dropServerMoveEveryN = parseClampedInteger(
    env.BROWSER_MOVEMENT_NET_DROP_SERVER_MOVE_EVERY_N,
    0,
    1_000,
  );
  const dropServerMovePercent = parseClampedInteger(
    env.BROWSER_MOVEMENT_NET_DROP_SERVER_MOVE_PERCENT,
    0,
    100,
  );
  const dropSeed = parseClampedInteger(env.BROWSER_MOVEMENT_NET_DROP_SEED, 1, 2_147_483_647);
  return {
    enabled:
      env.BROWSER_MOVEMENT_NET_EMULATION === "1" ||
      baseDelayMs > 0 ||
      jitterMs > 0 ||
      bytesPerSecond > 0 ||
      dropServerMoveEveryN > 0 ||
      dropServerMovePercent > 0,
    baseDelayMs,
    jitterMs,
    bytesPerSecond,
    dropServerMoveEveryN,
    dropServerMovePercent,
    dropSeed,
  };
}

function buildDelayMs(config, random = Math.random) {
  const base = Math.max(0, Number(config.baseDelayMs) || 0);
  const jitter = Math.max(0, Number(config.jitterMs) || 0);
  return Math.max(0, Math.round(base + random() * jitter));
}

function buildTransmissionMs(byteLength, bytesPerSecond) {
  const size = Math.max(0, Number(byteLength) || 0);
  const rate = Math.max(0, Number(bytesPerSecond) || 0);
  if (size <= 0 || rate <= 0) {
    return 0;
  }
  return Math.ceil((size / rate) * 1_000);
}

function resolveNetworkTimeoutMs(baseTimeoutMs, config) {
  const base = Math.max(0, Number(baseTimeoutMs) || 0);
  const bytesPerSecond = Math.max(0, Number(config?.bytesPerSecond) || 0);
  if (bytesPerSecond <= 0) {
    return base;
  }
  return Math.max(base, 60_000);
}

async function startWebSocketDelayProxy(options) {
  const {
    listenHost = "127.0.0.1",
    listenPort,
    upstreamHost = "127.0.0.1",
    upstreamPort,
    config,
  } = options;
  const server = http.createServer();
  const connections = new Set();
  const timers = new Set();
  const proxyStats = {
    serverMoveFrameCount: 0,
    droppedServerMoveFrameCount: 0,
  };

  server.on("upgrade", (request, clientSocket, head) => {
    const upstreamSocket = net.connect({ host: upstreamHost, port: upstreamPort });
    const clientToUpstream = makeWriteState(timers);
    const upstreamToClient = makeWriteState(timers, proxyStats);
    connections.add(clientSocket);
    connections.add(upstreamSocket);

    const closeBoth = () => {
      clientSocket.destroy();
      upstreamSocket.destroy();
      connections.delete(clientSocket);
      connections.delete(upstreamSocket);
    };

    clientSocket.on("error", closeBoth);
    upstreamSocket.on("error", closeBoth);
    clientSocket.on("close", closeBoth);
    upstreamSocket.on("close", closeBoth);

    upstreamSocket.once("connect", () => {
      upstreamSocket.write(buildUpgradeRequest(request, upstreamHost, upstreamPort));
      if (head.length > 0) {
        scheduleWrite(upstreamSocket, head, config, clientToUpstream);
      }
    });

    clientSocket.on("data", (chunk) => {
      scheduleWrite(upstreamSocket, chunk, config, clientToUpstream);
    });

    let upstreamHandshakeDone = false;
    let upstreamBuffer = Buffer.alloc(0);
    upstreamSocket.on("data", (chunk) => {
      if (upstreamHandshakeDone) {
        scheduleServerToClientWrite(clientSocket, chunk, config, upstreamToClient);
        return;
      }

      upstreamBuffer = Buffer.concat([upstreamBuffer, chunk]);
      const headerEnd = upstreamBuffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) {
        return;
      }

      const header = upstreamBuffer.subarray(0, headerEnd + 4);
      const rest = upstreamBuffer.subarray(headerEnd + 4);
      upstreamHandshakeDone = true;
      upstreamBuffer = Buffer.alloc(0);
      clientSocket.write(header);
      if (rest.length > 0) {
        scheduleServerToClientWrite(clientSocket, rest, config, upstreamToClient);
      }
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(listenPort, listenHost, () => {
      server.off("error", reject);
      resolve();
    });
  });

  return {
    getStats: () => ({ ...proxyStats }),
    dropConnections: () => {
      const droppedCount = connections.size;
      for (const timer of timers) {
        clearTimeout(timer);
      }
      timers.clear();
      for (const connection of Array.from(connections)) {
        connection.destroy();
      }
      connections.clear();
      return droppedCount;
    },
    close: () =>
      new Promise((resolve) => {
        for (const timer of timers) {
          clearTimeout(timer);
        }
        timers.clear();
        for (const connection of connections) {
          connection.destroy();
        }
        connections.clear();
        server.close(() => resolve());
      }),
  };
}

function buildUpgradeRequest(request, upstreamHost, upstreamPort) {
  const headers = [];
  let hasHost = false;
  const rawHeaders = request.rawHeaders || [];
  for (let index = 0; index < rawHeaders.length; index += 2) {
    const name = rawHeaders[index];
    const value = rawHeaders[index + 1];
    if (!name || value === undefined) {
      continue;
    }
    if (name.toLowerCase() === "host") {
      hasHost = true;
      headers.push(`Host: ${upstreamHost}:${upstreamPort}`);
    } else {
      headers.push(`${name}: ${value}`);
    }
  }
  if (!hasHost) {
    headers.push(`Host: ${upstreamHost}:${upstreamPort}`);
  }
  return `GET ${request.url || "/"} HTTP/1.1\r\n${headers.join("\r\n")}\r\n\r\n`;
}

function makeWriteState(timers, proxyStats = null) {
  return {
    timers,
    nextWriteAtMs: 0,
    webSocketFrameBuffer: Buffer.alloc(0),
    serverMoveFrameCount: 0,
    droppedServerMoveFrameCount: 0,
    proxyStats,
  };
}

function scheduleServerToClientWrite(socket, chunk, config, state) {
  if (
    Math.max(0, Number(config.dropServerMoveEveryN) || 0) <= 0 &&
    Math.max(0, Number(config.dropServerMovePercent) || 0) <= 0
  ) {
    scheduleWrite(socket, chunk, config, state);
    return;
  }

  const result = consumeServerToClientWebSocketFrames(chunk, config, state);
  for (const frame of result.frames) {
    scheduleWrite(socket, frame, config, state);
  }
}

function scheduleWrite(socket, chunk, config, state) {
  const delayMs = buildDelayMs(config);
  const transmissionMs = buildTransmissionMs(chunk.length, config.bytesPerSecond);
  const now = Date.now();
  if (delayMs <= 0 && transmissionMs <= 0 && state.nextWriteAtMs <= now) {
    if (!socket.destroyed) {
      socket.write(chunk);
    }
    return;
  }

  const writeAtMs = nextOrderedWriteAtMs(
    state,
    now,
    delayMs,
    chunk.length,
    config.bytesPerSecond,
  );
  const timer = setTimeout(() => {
    state.timers.delete(timer);
    if (!socket.destroyed) {
      socket.write(chunk);
    }
  }, Math.max(0, writeAtMs - now));
  state.timers.add(timer);
}

function consumeServerToClientWebSocketFrames(chunk, config = {}, state = {}) {
  const dropEvery = Math.max(0, Number(config.dropServerMoveEveryN) || 0);
  const dropPercent = Math.max(0, Number(config.dropServerMovePercent) || 0);
  const buffer =
    state.webSocketFrameBuffer && state.webSocketFrameBuffer.length > 0
      ? Buffer.concat([state.webSocketFrameBuffer, chunk])
      : Buffer.from(chunk);
  const frames = [];
  let offset = 0;
  let droppedFrameCount = 0;

  while (offset < buffer.length) {
    const parsed = parseWebSocketFrame(buffer, offset);
    if (!parsed) {
      break;
    }

    const frame = Buffer.from(buffer.subarray(offset, parsed.nextOffset));
    if (shouldDropServerFrame(buffer, parsed, { dropEvery, dropPercent }, config, state)) {
      droppedFrameCount += 1;
      state.droppedServerMoveFrameCount = Number(state.droppedServerMoveFrameCount || 0) + 1;
      if (state.proxyStats) {
        state.proxyStats.droppedServerMoveFrameCount =
          Number(state.proxyStats.droppedServerMoveFrameCount || 0) + 1;
      }
    } else {
      frames.push(frame);
    }
    offset = parsed.nextOffset;
  }

  state.webSocketFrameBuffer = Buffer.from(buffer.subarray(offset));
  return {
    frames,
    droppedFrameCount,
    bufferedBytes: state.webSocketFrameBuffer.length,
  };
}

function parseWebSocketFrame(buffer, offset) {
  if (buffer.length - offset < 2) {
    return null;
  }

  const first = buffer[offset];
  const second = buffer[offset + 1];
  const opcode = first & 0x0f;
  const masked = (second & 0x80) !== 0;
  let payloadLength = second & 0x7f;
  let headerLength = 2;

  if (payloadLength === 126) {
    if (buffer.length - offset < 4) {
      return null;
    }
    payloadLength = buffer.readUInt16BE(offset + 2);
    headerLength = 4;
  } else if (payloadLength === 127) {
    if (buffer.length - offset < 10) {
      return null;
    }
    const extendedLength = buffer.readBigUInt64BE(offset + 2);
    if (extendedLength > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error("websocket frame too large for smoke proxy");
    }
    payloadLength = Number(extendedLength);
    headerLength = 10;
  }

  const maskLength = masked ? 4 : 0;
  const payloadOffset = offset + headerLength + maskLength;
  const nextOffset = payloadOffset + payloadLength;
  if (buffer.length < nextOffset) {
    return null;
  }

  return {
    opcode,
    payloadOffset,
    payloadLength,
    nextOffset,
  };
}

function shouldDropServerFrame(buffer, frame, drop, config, state) {
  if (
    (drop.dropEvery <= 0 && drop.dropPercent <= 0) ||
    frame.opcode !== 0x02 ||
    frame.payloadLength <= 0
  ) {
    return false;
  }

  const applicationOpcode = buffer[frame.payloadOffset];
  if (applicationOpcode !== 0x83) {
    return false;
  }

  state.serverMoveFrameCount = Number(state.serverMoveFrameCount || 0) + 1;
  if (state.proxyStats) {
    state.proxyStats.serverMoveFrameCount = Number(state.proxyStats.serverMoveFrameCount || 0) + 1;
  }
  if (drop.dropEvery > 0 && state.serverMoveFrameCount % drop.dropEvery === 0) {
    return true;
  }
  if (drop.dropPercent > 0) {
    return pseudoRandomPercent(Number(config.dropSeed) || 1, state.serverMoveFrameCount) < drop.dropPercent;
  }
  return false;
}

function pseudoRandomPercent(seed, count) {
  const offset = Math.imul(Number(seed) || 1, 17) % 100;
  return (offset + Math.imul(Math.max(1, Number(count) || 1), 37)) % 100;
}

function nextOrderedWriteAtMs(state, nowMs, delayMs, byteLength = 0, bytesPerSecond = 0) {
  const writeAtMs =
    Math.max(nowMs, state.nextWriteAtMs) +
    Math.max(0, delayMs) +
    buildTransmissionMs(byteLength, bytesPerSecond);
  state.nextWriteAtMs = writeAtMs;
  return writeAtMs;
}

function parseClampedInteger(value, min, max) {
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) {
    return min;
  }
  return Math.min(max, Math.max(min, parsed));
}

module.exports = {
  buildDelayMs,
  buildTransmissionMs,
  nextOrderedWriteAtMs,
  resolveNetworkTimeoutMs,
  resolveNetworkEmulationConfig,
  consumeServerToClientWebSocketFrames,
  startWebSocketDelayProxy,
};
