defmodule ChatServer.RuntimePresenceRefreshTest do
  use ExUnit.Case, async: true

  alias ChatServer.Runtime

  test "refreshes existing session region and chunk without changing membership" do
    runtime = :"chat_presence_runtime_#{System.unique_integer([:positive])}"
    start_supervised!({Runtime, name: runtime})

    assert {:ok, _session} =
             Runtime.join(runtime, %{
               cid: 42,
               username: "tester",
               connection_pid: self(),
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, updated} =
             Runtime.refresh_presence(runtime, %{
               cid: 42,
               logical_scene_id: 1,
               region_id: 20,
               chunk_coord: {1, 0, 0}
             })

    assert updated.region_id == 20
    assert updated.chunk_coord == {1, 0, 0}

    assert %{session_count: 1, sessions: [session]} = Runtime.snapshot(runtime)
    assert session.region_id == 20
    assert session.chunk_coord == {1, 0, 0}
  end

  test "rejects presence refresh for an unknown session" do
    runtime = :"chat_presence_runtime_#{System.unique_integer([:positive])}"
    start_supervised!({Runtime, name: runtime})

    assert Runtime.refresh_presence(runtime, %{
             cid: 99,
             logical_scene_id: 1,
             region_id: 20,
             chunk_coord: {1, 0, 0}
           }) == {:error, :session_not_joined}
  end

  test "rejoining the same cid replaces stale monitor bookkeeping" do
    runtime = start_supervised!({Runtime, name: nil})

    attrs = %{
      cid: 42,
      username: "tester",
      connection_pid: self(),
      logical_scene_id: 1,
      region_id: 10,
      chunk_coord: {0, 0, 0}
    }

    assert {:ok, _session} = Runtime.join(runtime, attrs)
    assert {:ok, _session} = Runtime.join(runtime, %{attrs | username: "tester-rejoined"})

    state = :sys.get_state(runtime)
    assert map_size(state.sessions) == 1
    assert map_size(state.monitors) == 1
  end

  test "region and local delivery use refreshed presence indexes" do
    runtime = :"chat_presence_runtime_#{System.unique_integer([:positive])}"
    start_supervised!({Runtime, name: runtime})

    join!(runtime, 1, region_id: 10, chunk_coord: {0, 0, 0})
    join!(runtime, 2, region_id: 10, chunk_coord: {1, 0, 0})
    join!(runtime, 3, region_id: 20, chunk_coord: {4, 0, 0})

    assert %{presence_index: index_before} = Runtime.snapshot(runtime)
    assert index_before.world_membership_count == 3
    assert index_before.region_membership_count == 3
    assert index_before.local_membership_count == 3

    assert {:ok, moved} =
             Runtime.refresh_presence(runtime, %{
               cid: 2,
               logical_scene_id: 1,
               region_id: 20,
               chunk_coord: {4, 0, 0}
             })

    assert moved.region_id == 20

    assert {:ok, region_summary} =
             Runtime.say(runtime, %{
               cid: 1,
               channel: {:region, 1, 20},
               text: "region hello"
             })

    assert region_summary.plan_source == :presence_index
    assert region_summary.recipient_cids == [2, 3]
    assert region_summary.recipient_count == 2

    assert {:ok, local_summary} =
             Runtime.say(runtime, %{
               cid: 2,
               channel: {:local, 1, {4, 0, 0}, 0},
               text: "local hello"
             })

    assert local_summary.plan_source == :presence_index
    assert local_summary.recipient_cids == [2, 3]
    assert local_summary.recipient_count == 2

    assert %{presence_index: index_after} = Runtime.snapshot(runtime)
    assert index_after.region_channel_count == 2
    assert index_after.local_channel_count == 2
  end

  test "system delivery is runtime-only and uses presence indexes by scene or all sessions" do
    runtime = :"chat_presence_runtime_#{System.unique_integer([:positive])}"
    start_supervised!({Runtime, name: runtime})

    join!(runtime, 1, region_id: 10, chunk_coord: {0, 0, 0})
    join!(runtime, 2, region_id: 20, chunk_coord: {1, 0, 0})

    assert {:ok, _session} =
             Runtime.join(runtime, %{
               cid: 3,
               username: "tester-3",
               connection_pid: self(),
               logical_scene_id: 2,
               region_id: 30,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, scene_summary} =
             Runtime.say(runtime, %{
               cid: 1,
               channel: {:system, 1},
               text: "scene maintenance"
             })

    assert scene_summary.plan_source == :presence_index
    assert scene_summary.recipient_cids == [1, 2]
    assert scene_summary.recipient_count == 2
    assert scene_summary.skipped_count == 1

    assert {:ok, all_summary} =
             Runtime.say(runtime, %{
               cid: 1,
               channel: {:system, :all},
               text: "global maintenance"
             })

    assert all_summary.plan_source == :presence_index
    assert all_summary.recipient_cids == [1, 2, 3]
    assert all_summary.recipient_count == 3
    assert all_summary.skipped_count == 0
  end

  defp join!(runtime, cid, opts) do
    attrs =
      %{
        cid: cid,
        username: "tester-#{cid}",
        connection_pid: self(),
        logical_scene_id: 1,
        region_id: Keyword.fetch!(opts, :region_id),
        chunk_coord: Keyword.fetch!(opts, :chunk_coord)
      }

    assert {:ok, _session} = Runtime.join(runtime, attrs)
  end
end
