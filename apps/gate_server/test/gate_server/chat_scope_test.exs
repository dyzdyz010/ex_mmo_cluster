defmodule GateServer.ChatScopeTest do
  use ExUnit.Case, async: true

  alias GateServer.ChatScope

  test "local scope carries server-derived candidate regions when partition context provides them" do
    state = %{
      partition_context: %{
        logical_scene_id: 1,
        region_id: 10,
        chunk_coord: {0, 0, 0},
        candidate_region_ids: [10, 20],
        candidate_region_radius: 4
      },
      chat_context: %{
        logical_scene_id: 1,
        region_id: 10,
        chunk_coord: {0, 0, 0}
      }
    }

    assert {:ok,
            %{
              scope: :local,
              logical_scene_id: 1,
              chunk_coord: {0, 0, 0},
              candidate_region_ids: [10, 20],
              candidate_region_radius: 4,
              channel: {:local, 1, {0, 0, 0}, 4, [10, 20]}
            }} = ChatScope.derive(:local, state, local_radius: 4)
  end

  test "local scope ignores candidate regions when the hint covers less than local radius" do
    state = %{
      partition_context: %{
        logical_scene_id: 1,
        region_id: 10,
        chunk_coord: {0, 0, 0},
        candidate_region_ids: [10],
        candidate_region_radius: 1
      }
    }

    assert {:ok,
            %{
              scope: :local,
              logical_scene_id: 1,
              chunk_coord: {0, 0, 0},
              channel: {:local, 1, {0, 0, 0}, 4}
            }} = ChatScope.derive(:local, state, local_radius: 4)
  end
end
