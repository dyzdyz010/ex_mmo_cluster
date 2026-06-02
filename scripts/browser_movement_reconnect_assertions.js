function buildReconnectStressVerdict(cycles = []) {
  const failures = [];

  if (!Array.isArray(cycles) || cycles.length === 0) {
    failures.push("reconnect_cycles_missing");
  }

  for (const cycle of cycles) {
    if (Number(cycle?.droppedSocketCount ?? 0) <= 0) {
      failures.push("reconnect_drop_missing");
    }
    if (Number(cycle?.disconnected?.A?.reconnectAttemptCount ?? 0) <= 0) {
      failures.push("reconnect_a_disconnect");
    }
    if (Number(cycle?.disconnected?.B?.reconnectAttemptCount ?? 0) <= 0) {
      failures.push("reconnect_b_disconnect");
    }
    if (cycle?.ready?.A?.ready !== true) {
      failures.push("reconnect_a_ready");
    }
    if (cycle?.ready?.B?.ready !== true) {
      failures.push("reconnect_b_ready");
    }
    if (!cycle?.remoteVisible) {
      failures.push("reconnect_remote_visible");
    }
  }

  return {
    passed: failures.length === 0,
    cycleCount: Array.isArray(cycles) ? cycles.length : 0,
    failures: [...new Set(failures)],
  };
}

function resolveReconnectCycleCount(env = process.env) {
  const parsed = Number.parseInt(env.BROWSER_MOVEMENT_RECONNECT_CYCLES || "", 10);
  if (!Number.isFinite(parsed)) {
    return 2;
  }
  return Math.max(1, Math.min(parsed, 5));
}

module.exports = {
  buildReconnectStressVerdict,
  resolveReconnectCycleCount,
};
