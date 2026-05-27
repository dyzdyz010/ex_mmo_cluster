defmodule ChatServer.RuntimeDirectoryTest do
  use ExUnit.Case, async: true

  alias ChatServer.RuntimeDirectory

  test "routes world chat to the runtime shard for the authoritative logical scene" do
    directory = start_directory!()

    join!(directory, 701, logical_scene_id: 7, region_id: 70, chunk_coord: {0, 0, 0})
    join!(directory, 702, logical_scene_id: 7, region_id: 70, chunk_coord: {1, 0, 0})
    join!(directory, 801, logical_scene_id: 8, region_id: 80, chunk_coord: {0, 0, 0})

    assert {:ok,
            %{
              channel: {:world, 7},
              route_target: :scene_shard,
              shard_key: 7,
              recipient_cids: [701, 702],
              recipient_count: 2
            }} =
             RuntimeDirectory.say(directory, %{
               cid: 701,
               logical_scene_id: 7,
               channel: {:world, 7},
               text: "scene-seven"
             })

    assert_receive {:"$gen_cast", {:chat_message, 701, "tester-701", "scene-seven"}}
    assert_receive {:"$gen_cast", {:chat_message, 701, "tester-701", "scene-seven"}}
    refute_received {:chat_message, 801, _, _}

    assert %{
             shard_count: 2,
             shards: [
               %{logical_scene_id: 7, session_count: 2, history_count: 1},
               %{logical_scene_id: 8, session_count: 1, history_count: 0}
             ]
           } = RuntimeDirectory.snapshot(directory)
  end

  test "rejects a chat route when attrs scene and channel scene disagree" do
    directory = start_directory!()
    join!(directory, 701, logical_scene_id: 7, region_id: 70, chunk_coord: {0, 0, 0})

    assert {:error, :chat_route_mismatch} =
             RuntimeDirectory.say(directory, %{
               cid: 701,
               logical_scene_id: 7,
               channel: {:world, 8},
               text: "wrong-world"
             })

    assert %{shards: [%{logical_scene_id: 7, history_count: 0}]} =
             RuntimeDirectory.snapshot(directory)
  end

  test "moves presence between scene shards without leaving stale membership" do
    directory = start_directory!()
    join!(directory, 701, logical_scene_id: 7, region_id: 70, chunk_coord: {0, 0, 0})
    join!(directory, 801, logical_scene_id: 8, region_id: 80, chunk_coord: {8, 0, 0})

    assert {:ok, %{logical_scene_id: 8, region_id: 80, chunk_coord: {8, 0, 1}}} =
             RuntimeDirectory.refresh_presence(directory, %{
               cid: 701,
               username: "tester-701",
               connection_pid: self(),
               logical_scene_id: 8,
               region_id: 80,
               chunk_coord: {8, 0, 1}
             })

    assert {:error, :chat_route_mismatch} =
             RuntimeDirectory.say(directory, %{
               cid: 701,
               logical_scene_id: 7,
               channel: {:world, 7},
               text: "old-scene"
             })

    assert {:ok, %{recipient_cids: [701, 801], shard_key: 8}} =
             RuntimeDirectory.say(directory, %{
               cid: 701,
               logical_scene_id: 8,
               channel: {:world, 8},
               text: "new-scene"
             })
  end

  test "keeps only routing metadata and not replayable session payloads" do
    directory = start_directory!()
    join!(directory, 701, logical_scene_id: 7, region_id: 70, chunk_coord: {0, 0, 0})

    state = :sys.get_state(directory)

    refute Map.has_key?(state, :session_attrs)
    assert state.cid_to_scene == %{701 => 7}

    assert Map.keys(state) |> Enum.sort() == [
             :cid_to_scene,
             :refs,
             :runtime_supervisor,
             :shard_refs,
             :shards
           ]
  end

  test "removes crashed shard routes instead of crashing the directory" do
    directory = start_directory!()
    join!(directory, 701, logical_scene_id: 7, region_id: 70, chunk_coord: {0, 0, 0})

    %{shards: [%{logical_scene_id: 7, runtime_pid: runtime_pid}]} =
      RuntimeDirectory.snapshot(directory)

    ref = Process.monitor(runtime_pid)
    Process.exit(runtime_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runtime_pid, :killed}

    assert eventually(fn ->
             match?(%{shard_count: 0}, RuntimeDirectory.snapshot(directory))
           end)

    assert {:error, :sender_not_joined} =
             RuntimeDirectory.say(directory, %{
               cid: 701,
               logical_scene_id: 7,
               channel: {:world, 7},
               text: "after-crash"
             })

    assert Process.alive?(Process.whereis(directory))
  end

  defp start_directory! do
    sup_name = :"chat_runtime_shard_sup_#{System.unique_integer([:positive])}"
    directory_name = :"chat_runtime_directory_#{System.unique_integer([:positive])}"

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup_name})
    start_supervised!({RuntimeDirectory, name: directory_name, runtime_supervisor: sup_name})

    directory_name
  end

  defp join!(directory, cid, opts) do
    assert {:ok, _session} =
             RuntimeDirectory.join(directory, %{
               cid: cid,
               username: "tester-#{cid}",
               connection_pid: self(),
               logical_scene_id: Keyword.fetch!(opts, :logical_scene_id),
               region_id: Keyword.fetch!(opts, :region_id),
               chunk_coord: Keyword.fetch!(opts, :chunk_coord)
             })
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
