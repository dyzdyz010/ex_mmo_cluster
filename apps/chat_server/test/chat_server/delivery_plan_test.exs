defmodule ChatServer.DeliveryPlanTest do
  use ExUnit.Case, async: true

  alias ChatServer.DeliveryPlan

  test "indexed local delivery can preselect candidate regions before exact chunk filtering" do
    sessions = %{
      1 => session(1, region_id: 10, chunk_coord: {0, 0, 0}),
      2 => session(2, region_id: 20, chunk_coord: {2, 0, 0}),
      3 => session(3, region_id: 30, chunk_coord: {3, 0, 0}),
      4 => session(4, region_id: 20, chunk_coord: {9, 0, 0})
    }

    presence_index = presence_index(sessions)

    plan =
      DeliveryPlan.plan_indexed(%{
        sessions: sessions,
        presence_index: presence_index,
        channel: {:local, 1, {0, 0, 0}, 4, [10, 20]}
      })

    assert plan.plan_source == :presence_index
    assert plan.recipient_cids == [1, 2]
    assert plan.recipient_count == 2
    assert plan.skipped_count == 2
  end

  test "indexed local delivery without candidate regions can reach nearby cross-region sessions" do
    sessions = %{
      1 => session(1, region_id: 10, chunk_coord: {0, 0, 0}),
      2 => session(2, region_id: 20, chunk_coord: {2, 0, 0}),
      3 => session(3, region_id: 30, chunk_coord: {9, 0, 0})
    }

    plan =
      DeliveryPlan.plan_indexed(%{
        sessions: sessions,
        presence_index: presence_index(sessions),
        channel: {:local, 1, {0, 0, 0}, 4}
      })

    assert plan.plan_source == :presence_index
    assert plan.recipient_cids == [1, 2]
    assert plan.recipient_count == 2
    assert plan.skipped_count == 1
  end

  defp session(cid, opts) do
    %{
      cid: cid,
      username: "tester-#{cid}",
      connection_pid: self(),
      logical_scene_id: 1,
      region_id: Keyword.fetch!(opts, :region_id),
      chunk_coord: Keyword.fetch!(opts, :chunk_coord)
    }
  end

  defp presence_index(sessions) do
    sessions
    |> Enum.reduce(%{world: %{}, region: %{}, local: %{}}, fn {cid, session}, index ->
      index
      |> put_presence(:world, session.logical_scene_id, cid)
      |> put_presence(:region, {session.logical_scene_id, session.region_id}, cid)
      |> put_presence(:local, {session.logical_scene_id, session.chunk_coord}, cid)
    end)
  end

  defp put_presence(index, kind, key, cid) do
    Map.update!(index, kind, fn table ->
      Map.update(table, key, MapSet.new([cid]), &MapSet.put(&1, cid))
    end)
  end
end
