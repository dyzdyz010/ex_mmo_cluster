defmodule SceneServer.Movement.IntegratorTest do
  use ExUnit.Case, async: true

  alias SceneServer.Movement.{Engine, InputFrame, Integrator, Profile, State}

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
end
