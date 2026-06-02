function buildClockSoakVerdict(samples, options = {}) {
  const minSamples = options.minSamples ?? 3;
  const minTimeSyncSampleProgress = options.minTimeSyncSampleProgress ?? 1;
  const maxPlaybackRegressionDelta = options.maxPlaybackRegressionDelta ?? 4;
  const maxOffsetJitterMs = options.maxOffsetJitterMs ?? 250;

  const authorityClocks = samples
    .map((sample) => sample?.player?.authorityRender)
    .filter((clock) => clock && typeof clock === "object");
  const remoteClocks = samples.flatMap((sample) => {
    const entities = sample?.players?.remote?.entities;
    return Array.isArray(entities) ? entities : [];
  });

  const authority = summarizeClockSeries(authorityClocks, minSamples);
  const remote = summarizeClockSeries(remoteClocks, minSamples);
  const failures = [];

  if (authority.timelineSamples < minSamples) {
    failures.push(
      `authority render did not use server_state_ms or explicit server_tick fallback: ${authority.timelineSamples}/${minSamples}`,
    );
  }
  if (remote.timelineSamples < minSamples) {
    failures.push(
      `remote entities did not use server_state_ms or explicit server_tick fallback: ${remote.timelineSamples}/${minSamples}`,
    );
  }
  if (
    authority.timeSyncProgressRequired &&
    authority.timeSyncSampleProgress < minTimeSyncSampleProgress
  ) {
    failures.push(
      `authority TimeSync samples did not progress: ${authority.timeSyncSampleProgress}/${minTimeSyncSampleProgress}`,
    );
  }
  if (remote.timeSyncProgressRequired && remote.timeSyncSampleProgress < minTimeSyncSampleProgress) {
    failures.push(
      `remote TimeSync samples did not progress: ${remote.timeSyncSampleProgress}/${minTimeSyncSampleProgress}`,
    );
  }
  if (authority.playbackRegressionDelta > maxPlaybackRegressionDelta) {
    failures.push(
      `authority playback regression delta too high: ${authority.playbackRegressionDelta}/${maxPlaybackRegressionDelta}`,
    );
  }
  if (remote.playbackRegressionDelta > maxPlaybackRegressionDelta) {
    failures.push(
      `remote playback regression delta too high: ${remote.playbackRegressionDelta}/${maxPlaybackRegressionDelta}`,
    );
  }
  if (authority.maxOffsetJitterMs > maxOffsetJitterMs) {
    failures.push(
      `authority offset jitter too high: ${authority.maxOffsetJitterMs}/${maxOffsetJitterMs}`,
    );
  }
  if (remote.maxOffsetJitterMs > maxOffsetJitterMs) {
    failures.push(`remote offset jitter too high: ${remote.maxOffsetJitterMs}/${maxOffsetJitterMs}`);
  }

  return {
    passed: failures.length === 0,
    sampleCount: samples.length,
    authority,
    remote,
    thresholds: {
      minSamples,
      minTimeSyncSampleProgress,
      maxPlaybackRegressionDelta,
      maxOffsetJitterMs,
    },
    failures,
  };
}

function summarizeClockSeries(clocks, minSamples) {
  const serverStateClocks = clocks.filter(isServerStateClock);
  const serverTickFallbackClocks = clocks.filter(isServerTickFallbackClock);
  const acceptedClocks = [...serverStateClocks, ...serverTickFallbackClocks];
  return {
    observedSamples: clocks.length,
    serverStateSamples: serverStateClocks.length,
    serverSendSamples: serverStateClocks.length,
    serverTickFallbackSamples: serverTickFallbackClocks.length,
    timelineSamples: acceptedClocks.length,
    finitePlaybackSamples: acceptedClocks.filter((clock) =>
      Number.isFinite(clock.playbackServerTimeMs),
    ).length,
    finiteOffsetSamples: acceptedClocks.filter((clock) => Number.isFinite(clock.serverClockOffsetMs))
      .length,
    timeSyncProgressRequired: serverStateClocks.length >= minSamples,
    timeSyncSampleProgress: numericDelta(acceptedClocks, "timeSyncSampleCount"),
    playbackRegressionDelta: numericDelta(acceptedClocks, "playbackTimeRegressionCount"),
    maxOffsetJitterMs: maxNumber(acceptedClocks, "timeSyncOffsetJitterMs"),
    maxOffsetJumpCount: maxNumber(acceptedClocks, "timeSyncOffsetJumpCount"),
  };
}

function isServerStateClock(clock) {
  return (
    clock?.interpolationTimeAxis === "server_state_ms" &&
    Number.isFinite(clock.playbackServerTimeMs) &&
    Number.isFinite(clock.serverClockOffsetMs)
  );
}

function isServerTickFallbackClock(clock) {
  return (
    clock?.interpolationTimeAxis === "server_tick" &&
    (clock?.serverStateTimelineHealthy === false || clock?.serverSendTimelineHealthy === false) &&
    Number.isFinite(clock.playbackServerTimeMs)
  );
}

function numericDelta(items, key) {
  const values = items.map((item) => Number(item?.[key])).filter(Number.isFinite);
  if (values.length === 0) {
    return 0;
  }
  return Math.max(...values) - Math.min(...values);
}

function maxNumber(items, key) {
  const values = items.map((item) => Number(item?.[key])).filter(Number.isFinite);
  return values.length === 0 ? 0 : Math.max(...values);
}

module.exports = { buildClockSoakVerdict };
