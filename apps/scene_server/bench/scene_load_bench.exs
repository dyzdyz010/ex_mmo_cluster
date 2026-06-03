# Scene-scale movement load bench.
#
# Simulates N independent entities stepping one authoritative tick each via
# `MovementEngine.step/3`, and reports total wall time + per-entity latency
# percentiles. Goal: quantify whether a single shard can sustain the MMO target
# of 1000 entities at the current authoritative movement cadence and how we
# compare to the published Amazon New World "500 players in one shard" parity
# point.
#
# Run with:
#   cd apps/scene_server
#   mix run bench/scene_load_bench.exs
#
# Or override entity count:
#   ENTITIES=2000 mix run bench/scene_load_bench.exs

alias SceneServer.Movement.{InputFrame, Profile, State}
alias SceneServer.Native.MovementEngine

entities =
  case System.get_env("ENTITIES") do
    nil -> 1000
    value -> String.to_integer(value)
  end

ticks =
  case System.get_env("TICKS") do
    nil -> 10
    value -> String.to_integer(value)
  end

profile = Profile.default()
fixed_dt_ms = profile.fixed_dt_ms
target_hz = 1000.0 / fixed_dt_ms

IO.puts("=== Scene-scale movement load ===")

IO.puts(
  "entities=#{entities} ticks=#{ticks} (tick = #{fixed_dt_ms}ms authoritative step, #{Float.round(target_hz, 1)} Hz)"
)

IO.puts(
  "target at #{Float.round(target_hz, 1)} Hz: total wall <= #{fixed_dt_ms} ms per tick for all entities"
)

IO.puts("")

# Seed N entities at small position offsets so they don't all trace the same
# floating-point path.
states =
  for i <- 0..(entities - 1), into: %{} do
    {i, State.idle({i * 1.0, 0.0, 0.0})}
  end

# Build one input frame template (direction per-entity varies so the
# jerk-limited path takes different branches across entities).
input_for = fn entity_id, seq ->
  {dx, dy} =
    case rem(entity_id, 4) do
      0 -> {1.0, 0.0}
      1 -> {0.0, 1.0}
      2 -> {-1.0, 0.0}
      3 -> {0.0, -1.0}
    end

  %InputFrame{
    seq: seq,
    client_tick: seq,
    dt_ms: fixed_dt_ms,
    input_dir: {dx, dy},
    speed_scale: 1.0,
    movement_flags: 0
  }
end

# Warmup: one tick worth
_ =
  states
  |> Enum.map(fn {id, s} -> MovementEngine.step(s, input_for.(id, 1), profile) end)

# Timed run: K ticks, measuring wall time per tick.
{total_us, per_tick_us, latencies_us} =
  Enum.reduce(1..ticks, {0, [], []}, fn tick, {total_acc, per_tick_acc, lat_acc} ->
    tick_start = System.monotonic_time(:microsecond)

    # Per-entity: measure just the NIF step to build a latency distribution.
    {next_states, tick_latencies} =
      Enum.reduce(states, {%{}, []}, fn {id, s}, {acc_states, acc_lat} ->
        t0 = System.monotonic_time(:microsecond)
        next = MovementEngine.step(s, input_for.(id, tick), profile)
        t1 = System.monotonic_time(:microsecond)
        {Map.put(acc_states, id, next), [t1 - t0 | acc_lat]}
      end)

    _ = next_states
    tick_end = System.monotonic_time(:microsecond)
    tick_wall = tick_end - tick_start
    {total_acc + tick_wall, [tick_wall | per_tick_acc], tick_latencies ++ lat_acc}
  end)

percentile = fn list_sorted, p ->
  n = length(list_sorted)
  idx = round((n - 1) * p)
  Enum.at(list_sorted, idx)
end

latencies_sorted = Enum.sort(latencies_us)
p50 = percentile.(latencies_sorted, 0.50)
p95 = percentile.(latencies_sorted, 0.95)
p99 = percentile.(latencies_sorted, 0.99)
max_lat = List.last(latencies_sorted)
avg_tick = total_us / ticks
max_tick = Enum.max(per_tick_us)

IO.puts("--- Per-entity NIF step latency (microseconds) ---")
IO.puts("  p50 = #{p50} us")
IO.puts("  p95 = #{p95} us")
IO.puts("  p99 = #{p99} us")
IO.puts("  max = #{max_lat} us")

IO.puts("")
IO.puts("--- Per-tick total wall time (microseconds) ---")
IO.puts("  avg = #{Float.round(avg_tick, 1)} us")
IO.puts("  max = #{max_tick} us")
IO.puts("  total (#{ticks} ticks) = #{total_us} us")

budget_us = fixed_dt_ms * 1_000
utilization_avg = avg_tick / budget_us * 100
utilization_max = max_tick / budget_us * 100
IO.puts("")

IO.puts(
  "--- #{Float.round(target_hz, 1)} Hz budget utilization (#{fixed_dt_ms} ms = #{budget_us} us per tick) ---"
)

IO.puts("  avg tick = #{Float.round(utilization_avg, 2)}% of #{fixed_dt_ms}ms budget")
IO.puts("  max tick = #{Float.round(utilization_max, 2)}% of #{fixed_dt_ms}ms budget")

headroom_entities =
  if avg_tick > 0 do
    trunc(entities * budget_us / avg_tick)
  else
    :infinity
  end

IO.puts("")
IO.puts("Projected headroom: ~#{headroom_entities} entities before tick deadline")
IO.puts("(linear extrapolation; real scene has AOI + persistence overhead)")
