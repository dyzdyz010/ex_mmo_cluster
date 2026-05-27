defmodule GateServer.ChatAdapterTest do
  use ExUnit.Case, async: false

  alias GateServer.ChatAdapter

  test "builds chat chunk context from canonical world centimeter voxel coordinates" do
    assert %{
             logical_scene_id: 7,
             region_id: nil,
             chunk_coord: {1, 2, -1},
             location: {1_650.0, 3_250.0, -0.1}
           } =
             ChatAdapter.context_from_character(
               %{logical_scene_id: 7},
               {1_650.0, 3_250.0, -0.1}
             )
  end

  test "ignores stale character chunk metadata when authoritative location disagrees" do
    assert %{chunk_coord: {1, 2, -1}} =
             ChatAdapter.context_from_character(
               %{
                 logical_scene_id: 7,
                 position: %{chunk_coord: {99, 99, 99}}
               },
               {1_650.0, 3_250.0, -0.1}
             )
  end

  test "does not treat character region metadata as partition authority" do
    assert %{region_id: nil, chunk_coord: {1, 2, -1}} =
             ChatAdapter.context_from_character(
               %{
                 logical_scene_id: 7,
                 region_id: 999,
                 position: %{region_id: 888}
               },
               {1_650.0, 3_250.0, -0.1}
             )
  end

  test "publishes explicit region channel without collapsing to world" do
    ensure_directory_started()
    logical_scene_id = System.unique_integer([:positive])
    cid_base = System.unique_integer([:positive]) * 10
    sender_cid = cid_base + 1
    neighbor_cid = cid_base + 2

    assert {:ok, _sender} =
             ChatAdapter.join(%{
               cid: sender_cid,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: logical_scene_id,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, _neighbor} =
             ChatAdapter.join(%{
               cid: neighbor_cid,
               username: "neighbor",
               connection_pid: self(),
               logical_scene_id: logical_scene_id,
               region_id: 10,
               chunk_coord: {0, 0, 1},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok,
            %{
              channel: {:region, ^logical_scene_id, 10},
              plan_source: :presence_index,
              route_target: :scene_shard,
              shard_key: ^logical_scene_id,
              recipient_cids: [^sender_cid, ^neighbor_cid],
              recipient_count: 2
            }} =
             ChatAdapter.publish(%{
               cid: sender_cid,
               username: "sender",
               logical_scene_id: logical_scene_id,
               channel: {:region, logical_scene_id, 10},
               text: "region-only"
             })
  end

  test "can publish through an explicit isolated runtime" do
    runtime = start_supervised!({ChatServer.Runtime, name: nil})

    assert {:ok, _sender} =
             ChatAdapter.join(%{
               chat_runtime: runtime,
               cid: 501,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: 77,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, _neighbor} =
             ChatAdapter.join(%{
               chat_runtime: runtime,
               cid: 502,
               username: "neighbor",
               connection_pid: self(),
               logical_scene_id: 77,
               region_id: 10,
               chunk_coord: {1, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, %{recipient_cids: [501, 502], recipient_count: 2}} =
             ChatAdapter.publish(%{
               chat_runtime: runtime,
               cid: 501,
               username: "sender",
               logical_scene_id: 77,
               channel: {:region, 77, 10},
               text: "isolated-region"
             })
  end

  test "can publish through an explicit scene-sharded chat directory" do
    directory = start_chat_directory!()

    assert {:ok, _sender} =
             ChatAdapter.join(%{
               chat_runtime: directory,
               cid: 701,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: 7,
               region_id: 70,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, _neighbor} =
             ChatAdapter.join(%{
               chat_runtime: directory,
               cid: 702,
               username: "neighbor",
               connection_pid: self(),
               logical_scene_id: 7,
               region_id: 70,
               chunk_coord: {1, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, _other_scene} =
             ChatAdapter.join(%{
               chat_runtime: directory,
               cid: 801,
               username: "other-scene",
               connection_pid: self(),
               logical_scene_id: 8,
               region_id: 80,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok,
            %{
              route_target: :scene_shard,
              shard_key: 7,
              recipient_cids: [701, 702],
              recipient_count: 2
            }} =
             ChatAdapter.publish(%{
               chat_runtime: directory,
               cid: 701,
               username: "sender",
               logical_scene_id: 7,
               channel: {:world, 7},
               text: "scene-sharded-world"
             })

    assert {:error, :chat_route_mismatch} =
             ChatAdapter.publish(%{
               chat_runtime: directory,
               cid: 701,
               username: "sender",
               logical_scene_id: 7,
               channel: {:world, 8},
               text: "wrong-scene"
             })
  end

  test "default chat adapter entry uses the scene-sharded runtime directory" do
    ensure_directory_started()
    logical_scene_id = System.unique_integer([:positive])
    sender_cid = logical_scene_id * 10 + 1
    neighbor_cid = logical_scene_id * 10 + 2

    assert {:ok, _sender} =
             ChatAdapter.join(%{
               cid: sender_cid,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: logical_scene_id,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, _neighbor} =
             ChatAdapter.join(%{
               cid: neighbor_cid,
               username: "neighbor",
               connection_pid: self(),
               logical_scene_id: logical_scene_id,
               region_id: 10,
               chunk_coord: {1, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok,
            %{
              route_target: :scene_shard,
              shard_key: ^logical_scene_id,
              recipient_cids: [^sender_cid, ^neighbor_cid]
            }} =
             ChatAdapter.publish(%{
               cid: sender_cid,
               username: "sender",
               logical_scene_id: logical_scene_id,
               channel: {:world, logical_scene_id},
               text: "default-shard"
             })

    directory_snapshot = ChatServer.RuntimeDirectory.snapshot(ChatServer.RuntimeDirectory)
    assert Enum.any?(directory_snapshot.shards, &(&1.logical_scene_id == logical_scene_id))

    case Process.whereis(ChatServer.Runtime) do
      nil ->
        :ok

      _pid ->
        singleton_snapshot = ChatServer.Runtime.snapshot(ChatServer.Runtime)
        refute Enum.any?(singleton_snapshot.sessions, &(&1.cid in [sender_cid, neighbor_cid]))
    end
  end

  test "default chat adapter entry fails closed when the runtime directory is unavailable" do
    chat_server_was_started? = app_started?(:chat_server)
    _ = Application.stop(:chat_server)

    on_exit(fn ->
      if chat_server_was_started? do
        {:ok, _apps} = Application.ensure_all_started(:chat_server)
      end
    end)

    ensure_runtime_started()
    refute Process.whereis(ChatServer.RuntimeDirectory)

    assert {:error, :chat_unavailable} =
             ChatAdapter.join(%{
               cid: 901,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: 90,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert ChatServer.Runtime.snapshot(ChatServer.Runtime).sessions == []
  end

  test "refresh presence can migrate a session between default scene shards" do
    ensure_directory_started()
    logical_scene_id = System.unique_integer([:positive])
    next_logical_scene_id = logical_scene_id + 1_000_000
    cid = logical_scene_id * 10 + 3

    assert {:ok, _sender} =
             ChatAdapter.join(%{
               cid: cid,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: logical_scene_id,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert {:ok, %{logical_scene_id: ^next_logical_scene_id, chunk_coord: {9, 0, 0}}} =
             ChatAdapter.refresh_presence(%{
               cid: cid,
               username: "sender",
               connection_pid: self(),
               logical_scene_id: next_logical_scene_id,
               region_id: 90,
               chunk_coord: {9, 0, 0}
             })

    assert {:error, :chat_route_mismatch} =
             ChatAdapter.publish(%{
               cid: cid,
               username: "sender",
               logical_scene_id: logical_scene_id,
               channel: {:world, logical_scene_id},
               text: "old-scene"
             })

    assert {:ok, %{route_target: :scene_shard, shard_key: ^next_logical_scene_id}} =
             ChatAdapter.publish(%{
               cid: cid,
               username: "sender",
               logical_scene_id: next_logical_scene_id,
               channel: {:world, next_logical_scene_id},
               text: "new-scene"
             })
  end

  test "leaves an explicit isolated runtime without touching the singleton runtime" do
    ensure_runtime_started()

    runtime =
      start_supervised!(
        Supervisor.child_spec({ChatServer.Runtime, name: nil},
          id: {:private_chat_runtime, System.unique_integer([:positive])}
        )
      )

    cid = System.unique_integer([:positive]) + 300_000

    assert {:ok, _singleton_session} =
             ChatServer.Runtime.join(ChatServer.Runtime, %{
               cid: cid,
               username: "singleton",
               connection_pid: self(),
               logical_scene_id: 88,
               region_id: 10,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _private_session} =
             ChatAdapter.join(%{
               chat_runtime: runtime,
               cid: cid,
               username: "private",
               connection_pid: self(),
               logical_scene_id: 88,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    assert :ok = ChatAdapter.leave(%{chat_runtime: runtime, cid: cid})

    assert ChatServer.Runtime.snapshot(runtime).sessions == []

    assert Enum.any?(
             ChatServer.Runtime.snapshot(ChatServer.Runtime).sessions,
             &(&1.cid == cid and &1.username == "singleton")
           )
  end

  defp ensure_runtime_started do
    case Process.whereis(ChatServer.Runtime) do
      nil -> start_supervised!({ChatServer.Runtime, name: ChatServer.Runtime})
      _pid -> :ok
    end
  end

  defp app_started?(app) do
    app in Enum.map(Application.started_applications(), fn {started_app, _desc, _vsn} ->
      started_app
    end)
  end

  defp ensure_directory_started do
    case Process.whereis(ChatServer.RuntimeDirectory) do
      nil ->
        start_supervised!(
          {DynamicSupervisor, strategy: :one_for_one, name: ChatServer.RuntimeShardSup}
        )

        start_supervised!(
          {ChatServer.RuntimeDirectory,
           name: ChatServer.RuntimeDirectory, runtime_supervisor: ChatServer.RuntimeShardSup}
        )

      _pid ->
        :ok
    end
  end

  defp start_chat_directory! do
    sup_name = :"gate_chat_runtime_shard_sup_#{System.unique_integer([:positive])}"
    directory_name = :"gate_chat_runtime_directory_#{System.unique_integer([:positive])}"

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup_name})

    start_supervised!(
      {ChatServer.RuntimeDirectory, name: directory_name, runtime_supervisor: sup_name}
    )

    directory_name
  end
end
