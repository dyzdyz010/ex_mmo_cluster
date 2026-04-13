defmodule SceneServer.Npc.NavigationTest do
  use ExUnit.Case, async: true

  alias SceneServer.Movement.Profile, as: MovementProfile
  alias SceneServer.Movement.State, as: MovementState
  alias SceneServer.Npc.Navigation
  alias SceneServer.Npc.Profile, as: NpcProfile
  alias SceneServer.Npc.State, as: NpcState

  test "builds chase input toward target position" do
    frame =
      Navigation.build_input_frame(
        %NpcState{npc_id: 9001, intent: :chase, current_target_cid: 42, last_decision_at_ms: nil},
        MovementState.idle({0.0, 0.0, 0.0}),
        MovementProfile.default(),
        NpcProfile.default(9001, movement_speed_scale: 0.7),
        {100.0, 0.0, 0.0},
        5
      )

    assert frame.seq == 5
    assert frame.input_dir == {1.0, 0.0}
    assert frame.speed_scale == 0.7
    assert frame.movement_flags == 0
  end

  test "brakes when already at destination" do
    frame =
      Navigation.build_input_frame(
        %NpcState{npc_id: 9001, intent: :return_home, current_target_cid: nil, last_decision_at_ms: nil},
        MovementState.idle({32.0, 32.0, 0.0}),
        MovementProfile.default(),
        NpcProfile.default(9001, spawn_position: {32.0, 32.0, 0.0}),
        {32.0, 32.0, 0.0},
        9
      )

    assert frame.input_dir == {0.0, 0.0}
    assert frame.movement_flags == 0b10
  end
end
