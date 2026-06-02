const fs = require("node:fs");
const path = require("node:path");
const protocol = require("./ws_dual_protocol");

if (typeof WebSocket !== "function") {
  throw new Error("ws_dual_smoke requires Node.js 22+ with the global WebSocket API");
}

const root = path.resolve(__dirname, "..");
const observeDir =
  process.env.WS_SMOKE_OBSERVE_DIR || path.join(root, ".demo", "observe");
const summaryPath =
  process.env.WS_SMOKE_SUMMARY_PATH ||
  path.join(observeDir, "ws-dual-smoke-summary.json");
const AUTH_BASE_URL = process.env.AUTH_BASE_URL || "http://127.0.0.1:20000";
const WS_URL = process.env.WS_URL || "ws://127.0.0.1:20000/ingame/ws";
const timeoutMs = Number(process.env.WS_SMOKE_TIMEOUT_MS || 30_000);

fs.mkdirSync(observeDir, { recursive: true });

const framePlan = [
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "move-1" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "move-2" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.Jump, label: "jump" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "air-1" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "air-2" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "air-3" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "air-4" },
  { dx: 1, dy: 0, flags: protocol.MovementFlag.None, label: "air-5" },
  { dx: 0, dy: 0, flags: protocol.MovementFlag.Brake, label: "stop" },
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
  downlinks: {},
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

function vec3(view, offset) {
  return {
    x: view.getFloat64(offset, false),
    y: view.getFloat64(offset + 8, false),
    z: view.getFloat64(offset + 16, false),
  };
}

function recordDownlink(name) {
  summary.downlinks[name] = (summary.downlinks[name] || 0) + 1;
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
    state.socket.send(protocol.encodeAuth(authRequestId, login.username, login.token));
  };

  state.socket.onmessage = (event) => {
    const view = new DataView(event.data);
    const msgType = view.getUint8(0);

    if (msgType === 0x80) {
      const requestId = Number(view.getBigUint64(1, false));
      const ok = view.getUint8(9) === 0;
      if (requestId === authRequestId && ok) {
        console.log(label, "auth_ok");
        state.socket.send(protocol.encodeEnterScene(enterSceneRequestId, login.cid));
      } else if (!ok) {
        fail(11, `${label}_result_error`, { requestId });
      }
      return;
    }

    if (msgType === 0x81) {
      const cid = Number(view.getBigInt64(1, false));
      const position = vec3(view, 9);
      console.log(label, "player_enter", cid, protocol.formatVec3(position));
      hooks.onPlayerEnter?.(state, { cid, position });
      return;
    }

    if (msgType === 0x82) {
      console.log(label, "player_leave", Number(view.getBigInt64(1, false)));
      return;
    }

    if (msgType === 0x84) {
      const enter = protocol.decodeEnterScene(view);
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
        protocol.formatVec3(enter.position),
        `expected_seq=${enter.expectedSeq}`,
      );
      hooks.onEnterScene(state, enter);
      return;
    }

    if (msgType === 0x8b) {
      const ack = protocol.decodeMovementAck(view);
      console.log(
        label,
        "movement_ack",
        ack.ackSeq,
        `tick=${ack.authTick}`,
        `mode=${ack.movementMode}`,
        protocol.formatVec3(ack.position),
      );
      hooks.onMovementAck(state, ack);
      return;
    }

    if (msgType === 0x83) {
      const move = protocol.decodePlayerMove(view);
      const priorityText = move.priority
        ? `priority=${move.priority.band}:${move.priority.score.toFixed(3)}:${move.priority.distance.toFixed(1)}:${move.priority.interval}`
        : "priority=missing";
      console.log(
        label,
        "player_move",
        move.cid,
        `tick=${move.serverTick}`,
        `mode=${move.movementMode}`,
        protocol.formatVec3(move.position),
        priorityText,
      );
      hooks.onPlayerMove(state, move);
      return;
    }

    if (msgType === 0x8c && view.byteLength === 14) {
      const state = protocol.decodePlayerState(view);
      recordDownlink("player_state");
      console.log(
        label,
        "player_state",
        state.cid,
        `hp=${state.hp}/${state.maxHp}`,
        `alive=${state.alive}`,
      );
      return;
    }

    if (msgType === 0x8e) {
      const identity = protocol.decodeActorIdentity(view);
      recordDownlink("actor_identity");
      console.log(
        label,
        "actor_identity",
        identity.cid,
        `kind=${identity.actorKind}`,
        `name=${identity.name || "<empty>"}`,
      );
      return;
    }

    const knownName = protocol.knownDownlinkName(msgType);
    if (knownName) {
      recordDownlink(knownName);
      console.log(label, "known_downlink_unhandled", knownName, `opcode=${msgType}`, `bytes=${view.byteLength}`);
      return;
    }

    console.log(label, "unknown_msg", `opcode=${msgType}`, `bytes=${view.byteLength}`);
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
    socketA.socket.send(protocol.encodeMove(frame));
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
