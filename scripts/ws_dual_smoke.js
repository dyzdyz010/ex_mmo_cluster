const enc = new TextEncoder();

const AUTH_BASE_URL = process.env.AUTH_BASE_URL || "http://127.0.0.1:4100";
const WS_URL = process.env.WS_URL || "ws://127.0.0.1:4100/ingame/ws";

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

function encodeMove(seq) {
  const buffer = new ArrayBuffer(25);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset++, 0x01);
  view.setUint32(offset, seq, false);
  offset += 4;
  view.setUint32(offset, seq, false);
  offset += 4;
  view.setUint16(offset, 100, false);
  offset += 2;
  view.setFloat32(offset, 1, false);
  offset += 4;
  view.setFloat32(offset, 0, false);
  offset += 4;
  view.setFloat32(offset, 1, false);
  offset += 4;
  view.setUint16(offset, 0, false);
  return new Uint8Array(buffer);
}

function formatVec3(view, offset) {
  return [
    view.getFloat64(offset, false).toFixed(1),
    view.getFloat64(offset + 8, false).toFixed(1),
    view.getFloat64(offset + 16, false).toFixed(1),
  ].join(",");
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
  const socket = new WebSocket(WS_URL);
  socket.binaryType = "arraybuffer";
  const authRequestId = 1;
  const enterSceneRequestId = 2;

  socket.onopen = () => {
    console.log(label, "open");
    socket.send(encodeAuth(authRequestId, login.username, login.token));
  };

  socket.onmessage = (event) => {
    const view = new DataView(event.data);
    const msgType = view.getUint8(0);

    if (msgType === 0x80) {
      const requestId = Number(view.getBigUint64(1, false));
      const status = view.getUint8(9);
      if (requestId === authRequestId && status === 0) {
        console.log(label, "auth_ok");
        socket.send(encodeEnterScene(enterSceneRequestId, login.cid));
      }
      return;
    }

    if (msgType === 0x84) {
      console.log(label, "enter_scene", formatVec3(view, 10));
      hooks.onEnterScene(socket);
      return;
    }

    if (msgType === 0x8B) {
      console.log(label, "movement_ack", view.getUint32(1, false), formatVec3(view, 17));
      hooks.onMovementAck(socket);
      return;
    }

    if (msgType === 0x83) {
      const priority = decodeAoiPriority(view, 86);
      const priorityText = priority
        ? `priority=${priority.band}:${priority.score.toFixed(3)}:${priority.distance.toFixed(1)}:${priority.interval}`
        : "priority=missing";
      console.log(label, "player_move", Number(view.getBigInt64(1, false)), view.getUint32(9, false), formatVec3(view, 13), priorityText);
      hooks.onPlayerMove(socket, priority);
      return;
    }

    console.log(label, "msg", msgType, view.byteLength);
  };

  socket.onerror = () => {
    console.log(label, "ws_error");
  };

  socket.onclose = (event) => {
    console.log(label, "ws_close", event.code, event.reason || "");
  };

  return socket;
}

async function main() {
  const loginA = await autoLogin("web_a");
  const loginB = await autoLogin("web_b");

  console.log("login_a", JSON.stringify(loginA));
  console.log("login_b", JSON.stringify(loginB));

  let enteredA = false;
  let enteredB = false;
  let acked = false;
  let moved = false;
  let priorityObserved = false;
  let moveSent = false;
  let socketA;
  let socketB;

  const maybeSendMove = () => {
    if (enteredA && enteredB && !moveSent) {
      moveSent = true;
      socketA.send(encodeMove(1));
    }
  };

  const maybeFinish = () => {
    if (acked && moved && priorityObserved) {
      socketA.close(1000, "done");
      socketB.close(1000, "done");
      setTimeout(() => process.exit(0), 250);
    }
  };

  const timeout = setTimeout(() => {
    console.log("timeout");
    process.exit(2);
  }, 20_000);

  socketA = connect("A", loginA, {
    onEnterScene: () => {
      enteredA = true;
      maybeSendMove();
    },
    onMovementAck: () => {
      acked = true;
      clearTimeout(timeout);
      maybeFinish();
    },
    onPlayerMove: () => {},
  });

  socketB = connect("B", loginB, {
    onEnterScene: () => {
      enteredB = true;
      maybeSendMove();
    },
    onMovementAck: () => {},
    onPlayerMove: (_socket, priority) => {
      if (!priority) {
        console.error("missing_aoi_priority_metadata");
        process.exit(3);
      }
      if (!Number.isFinite(priority.score) || priority.interval < 1) {
        console.error("invalid_aoi_priority_metadata", JSON.stringify(priority));
        process.exit(4);
      }
      moved = true;
      priorityObserved = true;
      clearTimeout(timeout);
      maybeFinish();
    },
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
