const fs = require("node:fs");
const path = require("node:path");

if (typeof WebSocket !== "function") {
  throw new Error("ws_dual_smoke requires Node.js 22+ with the global WebSocket API");
}

const enc = new TextEncoder();

const root = path.resolve(__dirname, "..");
const observeDir =
  process.env.WS_SMOKE_OBSERVE_DIR || path.join(root, ".demo", "observe");
const summaryPath =
  process.env.WS_SMOKE_SUMMARY_PATH ||
  path.join(observeDir, "ws-dual-smoke-summary.json");
const AUTH_BASE_URL = process.env.AUTH_BASE_URL || "http://127.0.0.1:4100";
const WS_URL = process.env.WS_URL || "ws://127.0.0.1:4100/ingame/ws";
const timeoutMs = Number(process.env.WS_SMOKE_TIMEOUT_MS || 30_000);

fs.mkdirSync(observeDir, { recursive: true });

const MovementFlag = {
  None: 0,
  Brake: 1 << 1,
  Jump: 1 << 2,
};

const framePlan = [
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "move-1" },
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "move-2" },
  { dx: 1, dy: 0, flags: MovementFlag.Jump, label: "jump" },
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "air-1" },
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "air-2" },
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "air-3" },
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "air-4" },
  { dx: 1, dy: 0, flags: MovementFlag.None, label: "air-5" },
  { dx: 0, dy: 0, flags: MovementFlag.Brake, label: "stop" },
];

const summary = {
  startedAt: new Date().toISOString(),
  authBaseUrl: AUTH_BASE_URL,
  wsUrl: WS_URL,
  users: {},
  cids: {},
  enter: {},
  sentFrames: [],
  ackedFrames: [],
  remote: {
    observer: "B",
    subject: "A",
    snapshots: 0,
    firstTick: null,
    lastTick: null,
    firstZ: null,
    maxZ: null,
    movementModes: {},
    prioritySamples: [],
  },
  assertions: {
    remoteEnterObserved: false,
    ackObserved: false,
    ackAirborneObserved: false,
    remoteSnapshotsObserved: false,
    remoteTickAdvanced: false,
    aoiPriorityObserved: false,
    remoteAirborneObserved: false,
    remoteJumpRiseObserved: false,
  },
};

function writeSummary(extra = {}) {
  const payload = {
    ...summary,
    ...extra,
    finishedAt: new Date().toISOString(),
  };
  fs.writeFileSync(summaryPath, `${JSON.stringify(payload, null, 2)}\n`);
}

function fail(code, message, detail) {
  if (detail !== undefined) {
    console.error(message, JSON.stringify(detail));
  } else {
    console.error(message);
  }
  writeSummary({ status: "failed", failure: { code, message, detail } });
  process.exit(code);
}

function writeU64(view, offset, value) {
  view.setBigUint64(offset, BigInt(value), false);
}

function writeI64(view, offset, value) {
  view.setBigInt64(offset, BigInt(value), false);
}

function encodeAuth(requestId, username, token) {
  const usernameBytes = enc.encode(username);
  const tokenBytes = enc.encode(token);
  const buffer = new ArrayBuffer(1 + 8 + 2 + usernameBytes.length + 2 + tokenBytes.length);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset++, 0x05);
  writeU64(view, offset, requestId);
  offset += 8;
  view.setUint16(offset, usernameBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, usernameBytes.length).set(usernameBytes);
  offset += usernameBytes.length;
  view.setUint16(offset, tokenBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, tokenBytes.length).set(tokenBytes);
  return new Uint8Array(buffer);
}

function encodeEnterScene(requestId, cid) {
  const buffer = new ArrayBuffer(17);
  const view = new DataView(buffer);
  view.setUint8(0, 0x02);
  writeU64(view, 1, requestId);
  writeI64(view, 9, cid);
  return new Uint8Array(buffer);
}

function encodeMove({ seq, clientTick, dx, dy, flags }) {
  const buffer = new ArrayBuffer(25);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset++, 0x01);
  view.setUint32(offset, seq, false);
  offset += 4;
  view.setUint32(offset, clientTick, false);
  offset += 4;
  view.setUint16(offset, 100, false);
  offset += 2;
  view.setFloat32(offset, dx, false);
  offset += 4;
  view.setFloat32(offset, dy, false);
  offset += 4;
  view.setFloat32(offset, 1, false);
  offset += 4;
  view.setUint16(offset, flags, false);
  return new Uint8Array(buffer);
}

function vec3(view, offset) {
  return {
    x: view.getFloat64(offset, false),
    y: view.getFloat64(offset + 8, false),
    z: view.getFloat64(offset + 16, false),
  };
}

function formatVec3(position) {
  return `${position.x.toFixed(1)},${position.y.toFixed(1)},${position.z.toFixed(1)}`;
}

function decodeMovementMode(raw) {
  if (raw === 1) return "airborne";
  if (raw === 2) return "disabled";
  if (raw === 3) return "scripted";
  return "grounded";
}

function decodePriorityBand(raw) {
  if (raw === 1) return "medium";
  if (raw === 2) return "low";
  return "high";
}

function decodeAoiPriority(view, offset) {
  if (view.byteLength < offset + 11) {
    return null;
  }

  return {
    band: decodePriorityBand(view.getUint8(offset)),
    score: view.getFloat32(offset + 1, false),
    distance: view.getFloat32(offset + 5, false),
    interval: view.getUint16(offset + 9, false),
  };
}

function decodeEnterScene(view) {
  return {
    requestId: Number(view.getBigUint64(1, false)),
    ok: view.getUint8(9) === 0,
    position: vec3(view, 10),
    expectedSeq: view.byteLength >= 38 ? view.getUint32(34, false) : 1,
  };
}

function decodeMovementAck(view) {
  return {
    ackSeq: view.getUint32(1, false),
    authTick: view.getUint32(5, false),
    cid: Number(view.getBigInt64(9, false)),
    position: vec3(view, 17),
    movementMode: decodeMovementMode(view.getUint8(89)),
    correctionFlags: view.getUint32(90, false),
    fixedDtMs: view.getUint16(94, false),
  };
}

function decodePlayerMove(view) {
  return {
    cid: Number(view.getBigInt64(1, false)),
    serverTick: view.getUint32(9, false),
    position: vec3(view, 13),
    movementMode: decodeMovementMode(view.getUint8(85)),
    priority: decodeAoiPriority(view, 86),
  };
}

async function autoLogin(username) {
  const response = await fetch(`${AUTH_BASE_URL}/ingame/auto_login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username }),
  });

  if (!response.ok) {
    throw new Error(`auto_login_failed:${response.status}`);
  }

  return response.json();
}

function connect(label, login, hooks) {
  const state = {
    label,
    login,
    socket: new WebSocket(WS_URL),
    entered: false,
    expectedSeq: 1,
    enterPosition: null,
  };

  const authRequestId = 1;
  const enterSceneRequestId = 2;
  state.socket.binaryType = "arraybuffer";

  state.socket.onopen = () => {
    console.log(label, "open");
    state.socket.send(encodeAuth(authRequestId, login.username, login.token));
  };

  state.socket.onmessage = (event) => {
    const view = new DataView(event.data);
    const msgType = view.getUint8(0);

    if (msgType === 0x80) {
      const requestId = Number(view.getBigUint64(1, false));
      const ok = view.getUint8(9) === 0;
      if (requestId === authRequestId && ok) {
        console.log(label, "auth_ok");
        state.socket.send(encodeEnterScene(enterSceneRequestId, login.cid));
      } else if (!ok) {
        fail(11, `${label}_auth_failed`, { requestId });
      }
      return;
    }

    if (msgType === 0x81) {
      const cid = Number(view.getBigInt64(1, false));
      const position = vec3(view, 9);
      console.log(label, "player_enter", cid, formatVec3(position));
      hooks.onPlayerEnter?.(state, { cid, position });
      return;
    }

    if (msgType === 0x82) {
      console.log(label, "player_leave", Number(view.getBigInt64(1, false)));
      return;
    }

    if (msgType === 0x84) {
      const enter = decodeEnterScene(view);
      if (!enter.ok) {
        fail(12, `${label}_enter_scene_failed`, enter);
      }
      state.entered = true;
      state.expectedSeq = enter.expectedSeq;
      state.enterPosition = enter.position;
      summary.enter[label] = enter;
      console.log(
        label,
        "enter_scene",
        formatVec3(enter.position),
        `expected_seq=${enter.expectedSeq}`,
      );
      hooks.onEnterScene(state, enter);
      return;
    }

    if (msgType === 0x8b) {
      const ack = decodeMovementAck(view);
      console.log(
        label,
        "movement_ack",
        ack.ackSeq,
        `tick=${ack.authTick}`,
        `mode=${ack.movementMode}`,
        formatVec3(ack.position),
      );
      hooks.onMovementAck(state, ack);
      return;
    }

    if (msgType === 0x83) {
      const move = decodePlayerMove(view);
      const priorityText = move.priority
        ? `priority=${move.priority.band}:${move.priority.score.toFixed(3)}:${move.priority.distance.toFixed(1)}:${move.priority.interval}`
        : "priority=missing";
      console.log(
        label,
        "player_move",
        move.cid,
        `tick=${move.serverTick}`,
        `mode=${move.movementMode}`,
        formatVec3(move.position),
        priorityText,
      );
      hooks.onPlayerMove(state, move);
      return;
    }

    console.log(label, "msg", msgType, view.byteLength);
  };

  state.socket.onerror = () => {
    console.log(label, "ws_error");
  };

  state.socket.onclose = (event) => {
    console.log(label, "ws_close", event.code, event.reason || "");
  };

  return state;
}

async function main() {
  const loginA = await autoLogin(process.env.WS_SMOKE_USER_A || "ws_smoke_a");
  const loginB = await autoLogin(process.env.WS_SMOKE_USER_B || "ws_smoke_b");

  summary.users.A = loginA.username;
  summary.users.B = loginB.username;
  summary.cids.A = loginA.cid;
  summary.cids.B = loginB.cid;

  console.log("login_a", JSON.stringify(loginA));
  console.log("login_b", JSON.stringify(loginB));

  let socketA;
  let socketB;
  let frameTimer = null;
  let nextPlanIndex = 0;
  let nextSeq = 1;
  let finished = false;
  let baselineZ = null;

  const timeout = setTimeout(() => {
    fail(2, "timeout", summary.assertions);
  }, timeoutMs);

  const closeAndExit = () => {
    if (finished) return;
    finished = true;
    clearTimeout(timeout);
    if (frameTimer) clearInterval(frameTimer);
    writeSummary({ status: "ok" });
    socketA.socket.close(1000, "done");
    socketB.socket.close(1000, "done");
    console.log("summary", JSON.stringify(summary.assertions));
    console.log("summary_path", path.relative(root, summaryPath));
    setTimeout(() => process.exit(0), 250);
  };

  const maybeFinish = () => {
    const sentAll = nextPlanIndex >= framePlan.length;
    summary.assertions.ackObserved = summary.ackedFrames.length > 0;
    summary.assertions.remoteSnapshotsObserved = summary.remote.snapshots >= 3;
    summary.assertions.remoteTickAdvanced =
      summary.remote.firstTick != null &&
      summary.remote.lastTick != null &&
      summary.remote.lastTick > summary.remote.firstTick;

    if (
      sentAll &&
      summary.assertions.remoteEnterObserved &&
      summary.assertions.ackObserved &&
      summary.assertions.ackAirborneObserved &&
      summary.assertions.remoteSnapshotsObserved &&
      summary.assertions.remoteTickAdvanced &&
      summary.assertions.aoiPriorityObserved &&
      summary.assertions.remoteAirborneObserved &&
      summary.assertions.remoteJumpRiseObserved
    ) {
      closeAndExit();
    }
  };

  const sendNextFrame = () => {
    if (nextPlanIndex >= framePlan.length) {
      if (frameTimer) clearInterval(frameTimer);
      frameTimer = null;
      maybeFinish();
      return;
    }

    const plan = framePlan[nextPlanIndex++];
    const frame = {
      seq: nextSeq,
      clientTick: nextSeq,
      dx: plan.dx,
      dy: plan.dy,
      flags: plan.flags,
    };
    nextSeq += 1;
    socketA.socket.send(encodeMove(frame));
    summary.sentFrames.push({ ...frame, label: plan.label });
    console.log("A", "movement_input", frame.seq, plan.label, `flags=${frame.flags}`);
  };

  const maybeStartFrames = () => {
    if (!socketA.entered || !socketB.entered || !summary.assertions.remoteEnterObserved || frameTimer) {
      return;
    }

    nextSeq = socketA.expectedSeq;
    baselineZ = socketA.enterPosition?.z ?? null;
    sendNextFrame();
    frameTimer = setInterval(sendNextFrame, 110);
  };

  socketA = connect("A", loginA, {
    onEnterScene: () => maybeStartFrames(),
    onMovementAck: (_state, ack) => {
      summary.ackedFrames.push({
        ackSeq: ack.ackSeq,
        authTick: ack.authTick,
        movementMode: ack.movementMode,
        z: ack.position.z,
      });
      if (ack.movementMode === "airborne") {
        summary.assertions.ackAirborneObserved = true;
      }
      maybeFinish();
    },
    onPlayerEnter: () => {},
    onPlayerMove: () => {},
  });

  socketB = connect("B", loginB, {
    onEnterScene: () => maybeStartFrames(),
    onMovementAck: () => {},
    onPlayerEnter: (_state, enter) => {
      if (enter.cid !== loginA.cid) {
        return;
      }
      summary.assertions.remoteEnterObserved = true;
      baselineZ = enter.position.z;
      maybeStartFrames();
    },
    onPlayerMove: (_state, move) => {
      if (move.cid !== loginA.cid) {
        return;
      }

      if (!move.priority) {
        fail(3, "missing_aoi_priority_metadata", move);
      }
      if (!Number.isFinite(move.priority.score) || move.priority.interval < 1) {
        fail(4, "invalid_aoi_priority_metadata", move.priority);
      }

      summary.assertions.aoiPriorityObserved = true;
      summary.remote.snapshots += 1;
      summary.remote.firstTick ??= move.serverTick;
      summary.remote.lastTick = move.serverTick;
      summary.remote.firstZ ??= move.position.z;
      summary.remote.maxZ =
        summary.remote.maxZ == null ? move.position.z : Math.max(summary.remote.maxZ, move.position.z);
      summary.remote.movementModes[move.movementMode] =
        (summary.remote.movementModes[move.movementMode] || 0) + 1;
      summary.remote.prioritySamples.push({
        tick: move.serverTick,
        band: move.priority.band,
        score: Number(move.priority.score.toFixed(3)),
        distance: Number(move.priority.distance.toFixed(1)),
        interval: move.priority.interval,
      });

      if (move.movementMode === "airborne") {
        summary.assertions.remoteAirborneObserved = true;
      }

      const groundZ = baselineZ ?? summary.remote.firstZ;
      if (groundZ != null && move.movementMode === "airborne" && move.position.z > groundZ + 5) {
        summary.assertions.remoteJumpRiseObserved = true;
      }

      maybeFinish();
    },
  });
}

main().catch((error) => {
  fail(1, error.stack || String(error));
});
