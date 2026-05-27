defmodule GateServer.WsConnectionChatTest do
  use ExUnit.Case, async: false

  alias GateServer.{ChatAdapter, WsConnection}

  defmodule ChatCollector do
    use GenServer

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :tag)},
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Map.new(opts))
    end

    @impl true
    def init(opts) do
      {:ok, opts}
    end

    @impl true
    def handle_cast(message, %{owner: owner, tag: tag} = state) do
      send(owner, {:chat_collector, tag, message})
      {:noreply, state}
    end
  end

  setup do
    ensure_directory_started()

    :ok
  end

  test "chat_say in scene is delivered through Chat runtime" do
    {:ok, pid} = WsConnection.start_link(self())

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: :in_scene,
          cid: 42,
          auth_username: "tester",
          chat_session_joined?: true
      }
    end)

    join_chat_session(pid, 42, "tester", 1, 10, {0, 0, 0})

    WsConnection.receive_frame(pid, chat_say_frame(9, "hello-ws"))

    assert_receive {:gate_ws_send, result_payload}
    assert <<0x80, 9::64-big, 0x00>> = IO.iodata_to_binary(result_payload)

    assert_receive {:gate_ws_send, chat_payload}

    assert <<0x89, 42::64-big, 6::16-big, "tester", 8::16-big, "hello-ws">> =
             IO.iodata_to_binary(chat_payload)
  end

  test "scoped region chat is routed from server partition context" do
    {:ok, pid} = WsConnection.start_link(self())

    :sys.replace_state(pid, fn state ->
      context = %{logical_scene_id: 9, region_id: 10, chunk_coord: {0, 0, 0}}

      %{
        state
        | status: :in_scene,
          cid: 42,
          auth_username: "tester",
          chat_session_joined?: true,
          chat_context: context,
          partition_context: context
      }
    end)

    same_region = start_supervised!({ChatCollector, owner: self(), tag: :same_region})
    other_region = start_supervised!({ChatCollector, owner: self(), tag: :other_region})

    join_chat_session(pid, 42, "tester", 9, 10, {0, 0, 0})
    join_chat_session(same_region, 43, "nearby", 9, 10, {1, 0, 0})
    join_chat_session(other_region, 44, "far", 9, 20, {4, 0, 0})

    WsConnection.receive_frame(pid, scoped_chat_say_frame(11, :region, "region-ws"))

    assert_receive {:gate_ws_send, result_payload}
    assert <<0x80, 11::64-big, 0x00>> = IO.iodata_to_binary(result_payload)

    assert_receive {:gate_ws_send, chat_payload}

    assert <<0x89, 42::64-big, 6::16-big, "tester", 9::16-big, "region-ws">> =
             IO.iodata_to_binary(chat_payload)

    assert_receive {:chat_collector, :same_region, {:chat_message, 42, "tester", "region-ws"}}

    refute_receive {:chat_collector, :other_region, {:chat_message, 42, "tester", "region-ws"}},
                   100
  end

  test "scoped local chat uses server candidate regions and exact chunk radius" do
    {:ok, pid} = WsConnection.start_link(self())

    :sys.replace_state(pid, fn state ->
      context = %{
        logical_scene_id: 9,
        region_id: 10,
        chunk_coord: {0, 0, 0},
        candidate_region_ids: [10],
        candidate_region_radius: 1
      }

      %{
        state
        | status: :in_scene,
          cid: 42,
          auth_username: "tester",
          chat_session_joined?: true,
          chat_context: context,
          partition_context: context
      }
    end)

    nearby = start_supervised!({ChatCollector, owner: self(), tag: :nearby})
    same_region_far_chunk = start_supervised!({ChatCollector, owner: self(), tag: :far_chunk})

    other_region_near_chunk =
      start_supervised!({ChatCollector, owner: self(), tag: :other_region})

    join_chat_session(pid, 42, "tester", 9, 10, {0, 0, 0})
    join_chat_session(nearby, 43, "nearby", 9, 10, {1, 0, 0})
    join_chat_session(same_region_far_chunk, 44, "far-chunk", 9, 10, {9, 0, 0})
    join_chat_session(other_region_near_chunk, 45, "near-other-region", 9, 20, {1, 0, 0})

    WsConnection.receive_frame(pid, scoped_chat_say_frame(12, :local, "local-ws"))

    assert_receive {:gate_ws_send, result_payload}
    assert <<0x80, 12::64-big, 0x00>> = IO.iodata_to_binary(result_payload)

    assert_receive {:gate_ws_send, chat_payload}

    assert <<0x89, 42::64-big, 6::16-big, "tester", 8::16-big, "local-ws">> =
             IO.iodata_to_binary(chat_payload)

    assert_receive {:chat_collector, :nearby, {:chat_message, 42, "tester", "local-ws"}}

    refute_receive {:chat_collector, :far_chunk, {:chat_message, 42, "tester", "local-ws"}},
                   100

    refute_receive {:chat_collector, :other_region, {:chat_message, 42, "tester", "local-ws"}},
                   100
  end

  test "scoped local chat over ws falls back when candidate radius is too small" do
    previous_radius = Application.fetch_env(:gate_server, :local_chat_radius)
    Application.put_env(:gate_server, :local_chat_radius, 4)

    try do
      {:ok, pid} = WsConnection.start_link(self())

      :sys.replace_state(pid, fn state ->
        context = %{
          logical_scene_id: 9,
          region_id: 10,
          chunk_coord: {0, 0, 0},
          candidate_region_ids: [10],
          candidate_region_radius: 1
        }

        %{
          state
          | status: :in_scene,
            cid: 42,
            auth_username: "tester",
            chat_session_joined?: true,
            chat_context: context,
            partition_context: context
        }
      end)

      cross_region_near = start_supervised!({ChatCollector, owner: self(), tag: :cross_region})

      join_chat_session(pid, 42, "tester", 9, 10, {0, 0, 0})
      join_chat_session(cross_region_near, 43, "near-cross-region", 9, 20, {2, 0, 0})

      WsConnection.receive_frame(pid, scoped_chat_say_frame(13, :local, "fallback-ws"))

      assert_receive {:gate_ws_send, result_payload}
      assert <<0x80, 13::64-big, 0x00>> = IO.iodata_to_binary(result_payload)

      assert_receive {:gate_ws_send, _chat_payload}

      assert_receive {:chat_collector, :cross_region,
                      {:chat_message, 42, "tester", "fallback-ws"}}
    after
      restore_local_chat_radius(previous_radius)
    end
  end

  test "world and scoped chat stay available when Scene AOI is unavailable" do
    {:ok, pid} = WsConnection.start_link(self())
    cid = System.unique_integer([:positive]) + 200_000

    :sys.replace_state(pid, fn state ->
      context = %{logical_scene_id: 19, region_id: 33, chunk_coord: {2, 0, 0}}

      %{
        state
        | status: :in_scene,
          cid: cid,
          auth_username: "tester",
          chat_session_joined?: true,
          chat_context: context,
          partition_context: context
      }
    end)

    region_peer = start_supervised!({ChatCollector, owner: self(), tag: :region_peer})
    other_region = start_supervised!({ChatCollector, owner: self(), tag: :other_region})

    join_chat_session(pid, cid, "tester", 19, 33, {2, 0, 0})
    join_chat_session(region_peer, cid + 1, "nearby", 19, 33, {2, 0, 1})
    join_chat_session(other_region, cid + 2, "far", 19, 44, {9, 0, 0})

    WsConnection.receive_frame(pid, chat_say_frame(21, "world-without-scene-aoi"))

    assert_receive {:gate_ws_send, world_result_payload}
    assert <<0x80, 21::64-big, 0x00>> = IO.iodata_to_binary(world_result_payload)

    assert_receive {:gate_ws_send, world_chat_payload}

    assert <<0x89, ^cid::64-big, 6::16-big, "tester", 23::16-big, "world-without-scene-aoi">> =
             IO.iodata_to_binary(world_chat_payload)

    assert_receive {:chat_collector, :region_peer,
                    {:chat_message, ^cid, "tester", "world-without-scene-aoi"}}

    assert_receive {:chat_collector, :other_region,
                    {:chat_message, ^cid, "tester", "world-without-scene-aoi"}}

    WsConnection.receive_frame(pid, scoped_chat_say_frame(22, :region, "region-without-aoi"))

    assert_receive {:gate_ws_send, region_result_payload}
    assert <<0x80, 22::64-big, 0x00>> = IO.iodata_to_binary(region_result_payload)

    assert_receive {:gate_ws_send, region_chat_payload}

    assert <<0x89, ^cid::64-big, 6::16-big, "tester", 18::16-big, "region-without-aoi">> =
             IO.iodata_to_binary(region_chat_payload)

    assert_receive {:chat_collector, :region_peer,
                    {:chat_message, ^cid, "tester", "region-without-aoi"}}

    refute_receive {:chat_collector, :other_region,
                    {:chat_message, ^cid, "tester", "region-without-aoi"}},
                   100
  end

  defp chat_say_frame(request_id, text) do
    <<0x08, request_id::64-big, byte_size(text)::16-big, text::binary>>
  end

  defp scoped_chat_say_frame(request_id, scope, text) do
    <<0x0A, request_id::64-big, encode_scope(scope)::8, byte_size(text)::16-big, text::binary>>
  end

  defp encode_scope(:world), do: 0
  defp encode_scope(:region), do: 1
  defp encode_scope(:local), do: 2

  defp restore_local_chat_radius({:ok, value}),
    do: Application.put_env(:gate_server, :local_chat_radius, value)

  defp restore_local_chat_radius(:error),
    do: Application.delete_env(:gate_server, :local_chat_radius)

  defp join_chat_session(connection_pid, cid, username, logical_scene_id, region_id, chunk_coord) do
    assert {:ok, _} =
             ChatAdapter.join(%{
               cid: cid,
               username: username,
               connection_pid: connection_pid,
               logical_scene_id: logical_scene_id,
               region_id: region_id,
               chunk_coord: chunk_coord,
               location: {0.0, 0.0, 0.0}
             })
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
end
