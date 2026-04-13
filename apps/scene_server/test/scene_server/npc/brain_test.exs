defmodule SceneServer.Npc.BrainTest do
  use ExUnit.Case, async: true

  alias SceneServer.Npc.{Brain, Facts, Profile}

  test "attacks when target is within attack range" do
    facts = %Facts{
      alive: true,
      position: {0.0, 0.0, 0.0},
      spawn_position: {0.0, 0.0, 0.0},
      target_cid: 42,
      target_distance: 40.0,
      distance_from_spawn: 0.0
    }

    assert {:attack, 42} = Brain.decide(facts, Profile.default(1))
  end

  test "chases when target is in aggro range but outside attack range" do
    facts = %Facts{
      alive: true,
      position: {0.0, 0.0, 0.0},
      spawn_position: {0.0, 0.0, 0.0},
      target_cid: 42,
      target_distance: 120.0,
      distance_from_spawn: 0.0
    }

    assert {:chase, 42} = Brain.decide(facts, Profile.default(1))
  end

  test "returns home when outside leash radius without target" do
    facts = %Facts{
      alive: true,
      position: {0.0, 0.0, 0.0},
      spawn_position: {0.0, 0.0, 0.0},
      target_cid: nil,
      target_distance: nil,
      distance_from_spawn: 400.0
    }

    assert {:return_home, nil} = Brain.decide(facts, Profile.default(1))
  end
end
