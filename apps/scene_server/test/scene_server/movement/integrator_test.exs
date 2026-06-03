defmodule SceneServer.Movement.IntegratorTest do
  use ExUnit.Case, async: true

  alias SceneServer.Movement.{CorrectionFlags, Engine, InputFrame, Integrator, Profile, State}

  test "integrator builds acceleration and velocity from directional input" do
    state = State.idle({0.0, 0.0, 0.0})

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    next_state = Integrator.step(state, frame, Profile.default())

    {vx, _vy, _vz} = next_state.velocity
    {ax, _ay, _az} = next_state.acceleration
    {px, _py, _pz} = next_state.position

    assert vx > 0.0
    assert ax > 0.0
    assert px > 0.0
  end

  test "default movement profile runs at 16ms fixed dt" do
    assert Profile.default().fixed_dt_ms == 16
  end

  test "engine returns authoritative ack with seq and tick" do
    state = State.idle({0.0, 0.0, 0.0})

    frame = %InputFrame{
      seq: 9,
      client_tick: 27,
      dt_ms: 100,
      input_dir: {0.0, 1.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    {next_state, ack} = Engine.step(42, state, frame, Profile.default())

    assert ack.cid == 42
    assert ack.ack_seq == 9
    assert ack.auth_tick == 27
    assert ack.position == next_state.position
    assert ack.velocity == next_state.velocity
  end

  test "native engine step matches Elixir integrator output" do
    state = State.idle({10.0, 20.0, 0.0})

    frame = %InputFrame{
      seq: 2,
      client_tick: 5,
      dt_ms: 80,
      input_dir: {0.6, 0.8},
      speed_scale: 1.0,
      movement_flags: 0
    }

    profile = Profile.default()
    native_state = SceneServer.Native.MovementEngine.step(state, frame, profile)
    elixir_state = Integrator.step(state, frame, profile)

    assert native_state.tick == elixir_state.tick
    assert native_state.movement_mode == elixir_state.movement_mode
    assert native_state.position == elixir_state.position
    assert native_state.velocity == elixir_state.velocity
    assert native_state.acceleration == elixir_state.acceleration
  end

  test "native replay matches iterative Elixir integrator" do
    anchor_state = State.idle({0.0, 0.0, 0.0})
    profile = Profile.default()

    frames = [
      %InputFrame{
        seq: 1,
        client_tick: 1,
        dt_ms: 100,
        input_dir: {1.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0
      },
      %InputFrame{
        seq: 2,
        client_tick: 2,
        dt_ms: 100,
        input_dir: {1.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0
      },
      %InputFrame{
        seq: 3,
        client_tick: 3,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0b10
      }
    ]

    native_states = SceneServer.Native.MovementEngine.replay(anchor_state, frames, profile)

    expected_states =
      Enum.scan(frames, anchor_state, fn frame, previous ->
        Integrator.step(previous, frame, profile)
      end)

    assert native_states == expected_states
  end

  test "jump flag moves grounded state into airborne arc" do
    state = State.idle({0.0, 0.0, 90.0})

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: InputFrame.jump_flag()
    }

    profile = Profile.default()
    next_state = SceneServer.Native.MovementEngine.step(state, frame, profile)

    assert next_state.movement_mode == :airborne
    {_vx, _vy, vz} = next_state.velocity
    {_px, _py, pz} = next_state.position
    assert vz > 0.0
    assert pz > 90.0
    assert_in_delta(vz, profile.jump_impulse - profile.gravity * 0.1, 1.0e-9)
  end

  test "jump arc lands back on the original grounded height" do
    profile = Profile.default()

    frames =
      for tick <- 1..20 do
        %InputFrame{
          seq: tick,
          client_tick: tick,
          dt_ms: 100,
          input_dir: {0.0, 0.0},
          speed_scale: 1.0,
          movement_flags: if(tick == 1, do: InputFrame.jump_flag(), else: 0)
        }
      end

    [last_state | _] =
      State.idle({0.0, 0.0, 90.0})
      |> SceneServer.Native.MovementEngine.replay(frames, profile)
      |> Enum.reverse()

    assert last_state.movement_mode == :grounded
    assert last_state.position == {0.0, 0.0, 90.0}
    assert last_state.velocity == {0.0, 0.0, 0.0}
  end

  describe "correction flags (C.2)" do
    # build_ack is the legacy path (no input frame available): it must emit
    # zero flags so existing callers that don't know about the bitfield
    # stay wire-compatible.
    test "build_ack emits zero correction_flags" do
      state = %State{
        tick: 3,
        position: {0.0, 0.0, 0.0},
        velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded
      }

      ack = Engine.build_ack(1, state, 7, 100)
      assert ack.correction_flags == 0
      assert ack.fixed_dt_ms == 100
    end

    # Heuristic: player pushes in a direction but the resulting horizontal
    # velocity opposes the ask AND is tiny → something is holding us in
    # place (wall, knockback, collider). Flag COLLISION_PUSH so the client
    # can force-replay regardless of positional error.
    test "build_ack_with_intent flags COLLISION_PUSH when input is blocked" do
      state = %State{
        tick: 4,
        position: {0.0, 0.0, 0.0},
        velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded
      }

      frame = %InputFrame{
        seq: 9,
        client_tick: 4,
        dt_ms: 100,
        input_dir: {1.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0
      }

      ack = Engine.build_ack_with_intent(1, state, frame, 0, 100)
      assert CorrectionFlags.collision_push?(ack.correction_flags)
    end

    # Velocity follows input at a healthy magnitude → no push flag.
    test "build_ack_with_intent does not flag collision when velocity follows input" do
      state = %State{
        tick: 4,
        position: {0.0, 0.0, 0.0},
        velocity: {50.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded
      }

      frame = %InputFrame{
        seq: 9,
        client_tick: 4,
        dt_ms: 100,
        input_dir: {1.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0
      }

      ack = Engine.build_ack_with_intent(1, state, frame, 0, 100)
      assert ack.correction_flags == 0
    end

    # Zero input_dir → heuristic must not produce a false-positive push.
    test "build_ack_with_intent ignores zero input_dir" do
      state = %State{
        tick: 4,
        position: {0.0, 0.0, 0.0},
        velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded
      }

      frame = %InputFrame{
        seq: 9,
        client_tick: 4,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0
      }

      ack = Engine.build_ack_with_intent(1, state, frame, 0, 100)
      assert ack.correction_flags == 0
    end

    # Explicit TELEPORT passes through and combines with auto-detected bits.
    test "build_ack_with_intent ORs explicit flags with auto-detected collision" do
      state = %State{
        tick: 4,
        position: {0.0, 0.0, 0.0},
        velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded
      }

      frame = %InputFrame{
        seq: 9,
        client_tick: 4,
        dt_ms: 100,
        input_dir: {1.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0
      }

      status = CorrectionFlags.status_override()
      ack = Engine.build_ack_with_intent(1, state, frame, status, 100)

      assert CorrectionFlags.status_override?(ack.correction_flags)
      assert CorrectionFlags.collision_push?(ack.correction_flags)
    end
  end
end
