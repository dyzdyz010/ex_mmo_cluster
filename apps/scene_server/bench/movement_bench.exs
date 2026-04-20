# Movement integrator throughput benchmark.
#
# Compares the authoritative NIF path (Rust f64) against the reference Elixir
# `Integrator.step/3` implementation. Goal: quantify Rustler boundary overhead
# so we know whether the NIF is worth calling for small batches (the boundary
# per-call cost would be amortized differently across call sizes).
#
# Run with:
#   cd apps/scene_server
#   mix run bench/movement_bench.exs
#
# Scenarios:
#   1. Single-step (1 frame)      — worst-case Rustler overhead amortization
#   2. Small batch (10 frames)    — typical client replay window
#   3. Medium batch (100 frames)  — 10-second reconciliation window
#   4. Large batch (1000 frames)  — stress test the replay helper
#
# Profile + input configuration mirrors `integrator_golden_test.exs` so the
# numbers are comparable to the parity test's fixed-input-direction workload.

alias SceneServer.Movement.{InputFrame, Integrator, Profile, State}
alias SceneServer.Native.MovementEngine

profile = Profile.default()
anchor = State.idle({0.0, 0.0, 0.0})

make_frames = fn count ->
  for seq <- 1..count do
    %InputFrame{
      seq: seq,
      client_tick: seq,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }
  end
end

frames_1 = make_frames.(1)
frames_10 = make_frames.(10)
frames_100 = make_frames.(100)
frames_1000 = make_frames.(1000)

elixir_replay = fn anchor, frames, profile ->
  Enum.reduce(frames, anchor, fn frame, prev ->
    Integrator.step(prev, frame, profile)
  end)
end

IO.puts("=== Movement Integrator Throughput: NIF f64 vs Elixir reference ===")
IO.puts("profile.max_speed=#{profile.max_speed} profile.max_jerk=#{profile.max_jerk}")
IO.puts("")

Benchee.run(
  %{
    "NIF replay 1 frame" => fn -> MovementEngine.replay(anchor, frames_1, profile) end,
    "Elixir replay 1 frame" => fn -> elixir_replay.(anchor, frames_1, profile) end
  },
  time: 3,
  warmup: 1,
  print: [configuration: false]
)

Benchee.run(
  %{
    "NIF replay 10 frames" => fn -> MovementEngine.replay(anchor, frames_10, profile) end,
    "Elixir replay 10 frames" => fn -> elixir_replay.(anchor, frames_10, profile) end
  },
  time: 3,
  warmup: 1,
  print: [configuration: false]
)

Benchee.run(
  %{
    "NIF replay 100 frames" => fn -> MovementEngine.replay(anchor, frames_100, profile) end,
    "Elixir replay 100 frames" => fn -> elixir_replay.(anchor, frames_100, profile) end
  },
  time: 3,
  warmup: 1,
  print: [configuration: false]
)

Benchee.run(
  %{
    "NIF replay 1000 frames" => fn -> MovementEngine.replay(anchor, frames_1000, profile) end,
    "Elixir replay 1000 frames" => fn -> elixir_replay.(anchor, frames_1000, profile) end
  },
  time: 3,
  warmup: 1,
  print: [configuration: false]
)
