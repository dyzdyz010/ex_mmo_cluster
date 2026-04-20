defmodule SceneServer.Movement.IntegratorGoldenTest do
  use ExUnit.Case, async: true

  alias SceneServer.Movement.{InputFrame, Integrator, Profile, State}
  alias SceneServer.Native.MovementEngine

  @eps 1.0e-9

  describe "Elixir Integrator ↔ NIF movement_core golden parity" do
    test "straight-line run holds parity under <1e-9 for 12 ticks" do
      frames = build_frames(12, {1.0, 0.0}, 100, 1.0, 0)
      assert_golden_parity(State.idle({0.0, 0.0, 0.0}), frames)
    end

    test "braking sequence holds parity under <1e-9 across accel → brake" do
      run_frames = build_frames(8, {1.0, 0.0}, 100, 1.0, 0)

      brake_frames =
        for tick <- 9..16 do
          %InputFrame{
            seq: tick,
            client_tick: tick,
            dt_ms: 100,
            input_dir: {0.0, 0.0},
            speed_scale: 1.0,
            movement_flags: 0b10
          }
        end

      assert_golden_parity(State.idle({0.0, 0.0, 0.0}), run_frames ++ brake_frames)
    end

    test "turning sequence holds parity under <1e-9 across 3 heading changes" do
      north = build_frames_from(1, 6, {1.0, 0.0}, 100, 1.0, 0)
      east = build_frames_from(7, 12, {0.0, 1.0}, 100, 1.0, 0)
      diagonal_back = build_frames_from(13, 18, {-0.70710678, -0.70710678}, 100, 1.0, 0)

      assert_golden_parity(State.idle({5.0, -5.0, 0.0}), north ++ east ++ diagonal_back)
    end
  end

  defp build_frames(count, dir, dt_ms, speed_scale, flags) do
    build_frames_from(1, count, dir, dt_ms, speed_scale, flags)
  end

  defp build_frames_from(start_tick, end_tick, {dx, dy}, dt_ms, speed_scale, flags) do
    for tick <- start_tick..end_tick do
      %InputFrame{
        seq: tick,
        client_tick: tick,
        dt_ms: dt_ms,
        input_dir: {dx, dy},
        speed_scale: speed_scale,
        movement_flags: flags
      }
    end
  end

  defp assert_golden_parity(anchor, frames) do
    profile = Profile.default()
    native_states = MovementEngine.replay(anchor, frames, profile)

    elixir_states =
      Enum.scan(frames, anchor, fn frame, previous ->
        Integrator.step(previous, frame, profile)
      end)

    assert length(native_states) == length(elixir_states)

    Enum.zip(native_states, elixir_states)
    |> Enum.with_index()
    |> Enum.each(fn {{native, elixir}, index} ->
      assert native.tick == elixir.tick,
             "tick mismatch at step #{index}: native=#{native.tick} elixir=#{elixir.tick}"

      assert native.movement_mode == elixir.movement_mode,
             "movement_mode mismatch at step #{index}"

      assert_vec_close(native.position, elixir.position, @eps, "position", index)
      assert_vec_close(native.velocity, elixir.velocity, @eps, "velocity", index)
      assert_vec_close(native.acceleration, elixir.acceleration, @eps, "acceleration", index)
    end)
  end

  defp assert_vec_close({nx, ny, nz}, {ex, ey, ez}, eps, field, index) do
    assert abs(nx - ex) < eps,
           "#{field}.x diverged at step #{index}: native=#{nx} elixir=#{ex}"

    assert abs(ny - ey) < eps,
           "#{field}.y diverged at step #{index}: native=#{ny} elixir=#{ey}"

    assert abs(nz - ez) < eps,
           "#{field}.z diverged at step #{index}: native=#{nz} elixir=#{ez}"
  end
end
