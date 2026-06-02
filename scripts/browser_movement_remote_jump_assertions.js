function buildRemoteJumpVerdict(samples, options = {}) {
  const startY = Number(options.startY);
  const visibleSamples = samples.filter((sample) => sample.visible && Number.isFinite(sample.y));
  const lostSamples = samples.filter((sample) => sample.visible === false).length;
  const maxY =
    visibleSamples.length > 0 ? Math.max(...visibleSamples.map((sample) => sample.y)) : null;
  const rise = maxY === null || !Number.isFinite(startY) ? null : maxY - startY;
  const airborneSamples = visibleSamples.filter((sample) => sample.movementMode === "airborne");
  const firstAirborneMs = airborneSamples.length > 0 ? airborneSamples[0].tMs : null;
  const serverTicks = visibleSamples
    .map((sample) => Number(sample.latestServerTick))
    .filter(Number.isFinite);
  const serverTickProgress =
    serverTicks.length > 0 ? Math.max(...serverTicks) - Math.min(...serverTicks) : 0;
  const highPrioritySamples = visibleSamples.filter(
    (sample) => sample.priorityBand === "high",
  ).length;
  const deliveryIntervals = visibleSamples
    .map((sample) => Number(sample.deliveryInterval))
    .filter(Number.isFinite);
  const maxDeliveryInterval =
    deliveryIntervals.length > 0 ? Math.max(...deliveryIntervals) : null;
  const latencyBudgetMs = resolveRemoteJumpLatencyBudgetMs(options);
  const failures = [];

  if (lostSamples !== 0 || visibleSamples.length === 0) {
    failures.push("remote_jump_visible");
  }
  if (airborneSamples.length === 0) {
    failures.push("remote_jump_airborne");
  }
  if (rise === null || rise < 25) {
    failures.push("remote_jump_rise");
  }
  if (firstAirborneMs === null || firstAirborneMs > latencyBudgetMs) {
    failures.push("remote_jump_latency");
  }
  if (serverTickProgress < 1) {
    failures.push("remote_jump_tick_progress");
  }
  if (highPrioritySamples === 0 || maxDeliveryInterval === null || maxDeliveryInterval > 1) {
    failures.push("remote_jump_realtime_lane");
  }

  return {
    passed: failures.length === 0,
    failures,
    visibleSamples: visibleSamples.length,
    lostSamples,
    maxY,
    rise,
    airborneSamples: airborneSamples.length,
    firstAirborneMs,
    serverTickProgress,
    highPrioritySamples,
    maxDeliveryInterval,
    latencyBudgetMs,
  };
}

function buildRemoteGroundSettledVerdict(samples, options = {}) {
  const normalizedSamples = Array.isArray(samples) ? samples.filter(Boolean) : [];
  const requiredDurationMs = Math.max(0, Number(options.requiredDurationMs) || 0);
  const maxGroundDrift = Math.max(0, Number(options.maxGroundDrift) || 8);
  const maxServerSendAgeMs = Math.max(0, Number(options.maxServerSendAgeMs) || 1_500);
  const failures = [];
  const visibleSamples = normalizedSamples.filter((sample) => sample.visible === true);
  const groundedSamples = visibleSamples.filter((sample) => sample.movementMode === "grounded");
  const latest = visibleSamples[visibleSamples.length - 1] ?? null;

  if (!latest) {
    failures.push("remote_ground_visible");
  }
  if (!latest || latest.movementMode !== "grounded") {
    failures.push("remote_ground_grounded");
  }

  const latestServerSendAgeMs = Number(latest?.latestServerSendAgeMs);
  if (!Number.isFinite(latestServerSendAgeMs) || latestServerSendAgeMs > maxServerSendAgeMs) {
    failures.push("remote_ground_fresh_server_send");
  }

  const stableRun = trailingGroundedRun(visibleSamples);
  const stableDurationMs = stableRun.length < 2 ? 0 : stableRun[stableRun.length - 1].tMs - stableRun[0].tMs;
  const stableYs = stableRun.map((sample) => Number(sample.y)).filter(Number.isFinite);
  const stableDrift =
    stableYs.length > 0 ? Math.max(...stableYs) - Math.min(...stableYs) : Number.POSITIVE_INFINITY;

  if (stableDurationMs < requiredDurationMs) {
    failures.push("remote_ground_stable_duration");
  }
  if (stableDrift > maxGroundDrift) {
    failures.push("remote_ground_stable_position");
  }

  if (
    latest?.priorityBand !== "high" ||
    !Number.isFinite(Number(latest?.deliveryInterval)) ||
    Number(latest?.deliveryInterval) > 1
  ) {
    failures.push("remote_ground_realtime_lane");
  }

  return {
    passed: failures.length === 0,
    failures,
    samples: normalizedSamples,
    visibleSamples: visibleSamples.length,
    groundedSamples: groundedSamples.length,
    stableSamples: stableRun.length,
    stableDurationMs,
    stableDrift,
    latestServerSendAgeMs: Number.isFinite(latestServerSendAgeMs) ? latestServerSendAgeMs : null,
  };
}

function trailingGroundedRun(samples) {
  const run = [];
  for (let index = samples.length - 1; index >= 0; index -= 1) {
    const sample = samples[index];
    if (sample?.movementMode !== "grounded") {
      break;
    }
    run.unshift(sample);
  }
  return run;
}

function resolveRemoteJumpLatencyBudgetMs(options = {}) {
  const override = Number.parseInt(process.env.BROWSER_MOVEMENT_REMOTE_JUMP_MAX_AIRBORNE_MS || "", 10);
  if (Number.isFinite(override)) {
    return Math.max(300, Math.min(override, 5_000));
  }

  const network = options.networkEmulation || {};
  const base = 700;
  const delayPenalty =
    network.enabled === true
      ? (Math.max(0, Number(network.baseDelayMs) || 0) +
          Math.max(0, Number(network.jitterMs) || 0)) *
        4
      : 0;
  const bandwidthPenalty = Number(network.bytesPerSecond) > 0 ? 600 : 0;

  return Math.max(500, Math.min(base + delayPenalty + bandwidthPenalty, 3_000));
}

module.exports = {
  buildRemoteGroundSettledVerdict,
  buildRemoteJumpVerdict,
  resolveRemoteJumpLatencyBudgetMs,
};
