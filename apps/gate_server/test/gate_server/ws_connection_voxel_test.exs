defmodule GateServer.WsConnectionVoxelTest do
  use ExUnit.Case, async: false

  alias DataService.Voxel.ChunkSnapshotStore
  alias GateServer.WsConnection
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.Storage
  alias WorldServer.Voxel.MapLedger

  defmodule FakeInterface do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, Map.new(opts), name: GateServer.Interface)
    end

    @impl true
    def init(attrs) do
      {:ok, Map.merge(%{auth_server: nil, scene_server: nil, world_server: nil}, attrs)}
    end

    @impl true
    def handle_call(:auth_server, _from, state) do
      {:reply, state.auth_server, state}
    end

    @impl true
    def handle_call(:scene_server, _from, state) do
      {:reply, state.scene_server, state}
    end

    @impl true
    def handle_call(:world_server, _from, state) do
      {:reply, state.world_server, state}
    end
  end

  setup do
    old_observe_log = Application.get_env(:gate_server, :cli_observe_log)
    stop_named(GateServer.Interface)

    on_exit(fn ->
      stop_named(GateServer.Interface)

      if is_nil(old_observe_log) do
        Application.delete_env(:gate_server, :cli_observe_log)
      else
        Application.put_env(:gate_server, :cli_observe_log, old_observe_log)
      end
    end)

    :ok
  end

  test "voxel debug probe returns CLI-readable transport state" do
    {:ok, pid} = WsConnection.start_link(self())

    command = "voxel_transport"

    WsConnection.receive_frame(
      pid,
      <<0x6F, 7::64-big, byte_size(command)::16-big, command::binary>>
    )

    assert_receive {:gate_ws_send, <<0x6F, 7::64-big, len::16-big, result::binary-size(len)>>}

    assert result =~ "voxel_sync=server-authoritative"
    assert result =~ "voxel_truth_source=server"
    assert result =~ "voxel_codec_endian=big"
    assert result =~ "micro_resolution=8"
  end

  test "chunk subscribe outside scene returns voxel intent result error" do
    {:ok, pid} = WsConnection.start_link(self())

    WsConnection.receive_frame(
      pid,
      <<0x60, 8::64-big, 1::64-big, 0::32-big-signed, 0::32-big-signed, 0::32-big-signed, 1::8,
        1::8, 0::16-big>>
    )

    assert_receive {:gate_ws_send, iodata}

    assert <<0x68, 8::64-big, 0::32-big, 1::64-big, 2::8, 0::64-big, 0::16-big,
             reason_len::16-big, reason::binary-size(reason_len)>> = IO.iodata_to_binary(iodata)

    assert reason == ":invalid_state"
  end

  test "impact intent outside scene returns voxel intent result error with client seq" do
    {:ok, pid} = WsConnection.start_link(self())

    WsConnection.receive_frame(pid, voxel_impact_frame(12, 99, 100, {8, 16, 24}))

    assert_voxel_intent_result(
      request_id: 12,
      client_intent_seq: 99,
      logical_scene_id: 100,
      reason: ":invalid_state"
    )
  end

  test "impact intent in scene rejects when world lookup is unavailable" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, voxel_impact_frame(13, 100, 101, {8, 16, 24}))

    assert_voxel_intent_result(
      request_id: 13,
      client_intent_seq: 100,
      logical_scene_id: 101,
      reason: ":world_unavailable"
    )
  end

  test "impact intent rejects unknown skill before world routing" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      voxel_impact_frame(15, 102, 101, {8, 16, 24}, source_skill_id: 999)
    )

    assert_voxel_intent_result(
      request_id: 15,
      client_intent_seq: 102,
      logical_scene_id: 101,
      reason: ":invalid_skill"
    )
  end

  test "impact intent in scene routes through world, applies scene intent, and persists snapshot" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: 555,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7_001,
               owner_epoch: 0
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7_001,
               lease_id: 9_101,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: 1
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, voxel_impact_frame(14, 101, 555, {8, 16, 24}))

    assert_voxel_intent_accepted(
      request_id: 14,
      client_intent_seq: 101,
      logical_scene_id: 555,
      result_ref: 1
    )

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(555, {0, 0, 0})
    assert snapshot.chunk_version == 1

    assert {:ok, %{storage: storage}} =
             SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot.data)

    assert storage.chunk_version == 1

    assert Storage.macro_header_at(storage, {1, 2, 3}).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "chunk subscribe in scene rejects when world lookup is unavailable" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(9, 100, {0, 0, 0}))

    assert_voxel_intent_result(
      request_id: 9,
      logical_scene_id: 100,
      reason: ":world_unavailable"
    )
  end

  test "chunk subscribe returns world route failure reason before scene snapshot" do
    ensure_map_ledger_started()
    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(10, 98_765, {1234, 0, 0}))

    assert_voxel_intent_result(
      request_id: 10,
      logical_scene_id: 98_765,
      reason: ":unassigned_chunk"
    )
  end

  test "chunk subscribe routes through world before scene snapshot" do
    observe_path = observe_path("ws_chunk_subscribe_routed.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: 321,
               bounds_chunk_min: {2, 3, 4},
               bounds_chunk_max: {3, 4, 5},
               owner_scene_instance_ref: 7001,
               owner_epoch: 4
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7001,
               lease_id: 9001,
               owner_epoch: 5,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(11, 321, {2, 3, 4}))

    assert_receive {:gate_ws_send, iodata}
    assert <<0x62, snapshot_payload::binary>> = IO.iodata_to_binary(iodata)

    assert {:ok, snapshot} = SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot_payload)
    assert snapshot.request_id == 11
    assert snapshot.storage.logical_scene_id == 321
    assert snapshot.storage.chunk_coord == {2, 3, 4}

    assert {:ok, chunk_pid} =
             SceneServer.Voxel.ChunkDirectory.ensure_chunk(SceneServer.Voxel.ChunkDirectory, %{
               logical_scene_id: 321,
               chunk_coord: {2, 3, 4}
             })

    assert %{lease: %{lease_id: 9001, owner_scene_instance_ref: 7001, owner_epoch: 5}} =
             SceneServer.Voxel.ChunkProcess.debug_state(chunk_pid)

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_chunk_subscribe_routed")
    assert observe_log =~ "lease_id: 9001"
  end

  test "chunk subscribe forwards later authoritative snapshot pushes after impact" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    put_voxel_region(777, region_id: System.unique_integer([:positive, :monotonic]))

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(21, 777, {0, 0, 0}))

    assert_receive {:gate_ws_send, initial_iodata}
    assert <<0x62, initial_payload::binary>> = IO.iodata_to_binary(initial_iodata)
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.request_id == 21
    assert initial.storage.chunk_version == 0

    assert %{voxel_subscriptions: subscriptions} = :sys.get_state(pid)
    assert Map.has_key?(subscriptions, {777, {0, 0, 0}})

    WsConnection.receive_frame(pid, voxel_impact_frame(22, 201, 777, {8, 16, 24}))

    assert_voxel_intent_accepted(
      request_id: 22,
      client_intent_seq: 201,
      logical_scene_id: 777,
      result_ref: 1
    )

    assert_receive {:gate_ws_send, updated_iodata}
    assert <<0x62, updated_payload::binary>> = IO.iodata_to_binary(updated_iodata)
    assert {:ok, updated} = SceneVoxelCodec.decode_chunk_snapshot_payload(updated_payload)
    assert updated.request_id == 21
    assert updated.storage.chunk_version == 1

    assert Storage.macro_header_at(updated.storage, {1, 2, 3}).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "chunk unsubscribe removes live subscription and stops later snapshot pushes" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    put_voxel_region(778, region_id: System.unique_integer([:positive, :monotonic]))

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(31, 778, {0, 0, 0}))
    assert_receive {:gate_ws_send, initial_iodata}
    assert <<0x62, _initial_payload::binary>> = IO.iodata_to_binary(initial_iodata)

    WsConnection.receive_frame(pid, chunk_unsubscribe_frame(32, 778, [{0, 0, 0}]))
    assert_receive {:gate_ws_send, <<0x80, 32::64-big, 0x00>>}
    assert %{voxel_subscriptions: subscriptions} = :sys.get_state(pid)
    assert subscriptions == %{}

    WsConnection.receive_frame(pid, voxel_impact_frame(33, 202, 778, {8, 16, 24}))

    assert_voxel_intent_accepted(
      request_id: 33,
      client_intent_seq: 202,
      logical_scene_id: 778,
      result_ref: 1
    )

    refute_receive {:gate_ws_send, <<0x62, _payload::binary>>}, 100
  end

  defp put_connection_in_scene(pid) do
    :sys.replace_state(pid, fn state -> %{state | status: :in_scene, cid: 42} end)
    _ = :sys.get_state(pid)
    :ok
  end

  defp chunk_subscribe_frame(request_id, logical_scene_id, {cx, cy, cz}, radius \\ 0) do
    <<0x60, request_id::64-big, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed,
      cz::32-big-signed, radius::8, 1::8, 0::16-big>>
  end

  defp chunk_unsubscribe_frame(request_id, logical_scene_id, chunks) do
    IO.iodata_to_binary([
      <<0x61, request_id::64-big, logical_scene_id::64-big, length(chunks)::16-big>>,
      Enum.map(chunks, fn {cx, cy, cz} ->
        <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed>>
      end)
    ])
  end

  defp voxel_impact_frame(request_id, client_intent_seq, logical_scene_id, {x, y, z}, opts \\ []) do
    source_skill_id = Keyword.get(opts, :source_skill_id, 1)

    <<0x64, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big,
      source_skill_id::32-big, x::64-big-signed, y::64-big-signed, z::64-big-signed, 2::16-big,
      0::64-big>>
  end

  defp assert_voxel_intent_result(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    client_intent_seq = Keyword.get(opts, :client_intent_seq, 0)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    reason = Keyword.fetch!(opts, :reason)

    assert_receive {:gate_ws_send, iodata}

    assert <<0x68, got_request_id::64-big, got_client_intent_seq::32-big,
             got_logical_scene_id::64-big, 2::8, 0::64-big, 0::16-big, reason_len::16-big,
             got_reason::binary-size(reason_len)>> =
             IO.iodata_to_binary(iodata)

    assert got_request_id == request_id
    assert got_client_intent_seq == client_intent_seq
    assert got_logical_scene_id == logical_scene_id
    assert got_reason == reason
  end

  defp assert_voxel_intent_accepted(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    client_intent_seq = Keyword.fetch!(opts, :client_intent_seq)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    result_ref = Keyword.fetch!(opts, :result_ref)

    assert_receive {:gate_ws_send, iodata}

    assert <<0x68, got_request_id::64-big, got_client_intent_seq::32-big,
             got_logical_scene_id::64-big, 0::8, got_result_ref::64-big, 0::16-big, 2::16-big,
             "ok">> = IO.iodata_to_binary(iodata)

    assert got_request_id == request_id
    assert got_client_intent_seq == client_intent_seq
    assert got_logical_scene_id == logical_scene_id
    assert got_result_ref == result_ref
  end

  defp ensure_map_ledger_started do
    ensure_data_voxel_started()

    case Process.whereis(MapLedger) do
      nil ->
        start_supervised!(
          {MapLedger, name: MapLedger, write_token_store: DataService.Voxel.WriteTokenStore}
        )

      _pid ->
        :ok
    end
  end

  defp ensure_scene_voxel_started do
    ensure_data_voxel_started()

    if is_nil(Process.whereis(SceneServer.VoxelChunkSup)) do
      start_supervised!({SceneServer.VoxelChunkSup, name: SceneServer.VoxelChunkSup})
    end

    if is_nil(Process.whereis(SceneServer.Voxel.ChunkDirectory)) do
      start_supervised!(
        {SceneServer.Voxel.ChunkDirectory,
         name: SceneServer.Voxel.ChunkDirectory, chunk_sup: SceneServer.VoxelChunkSup}
      )
    end

    :ok
  end

  defp put_voxel_region(logical_scene_id, opts) do
    region_id = Keyword.fetch!(opts, :region_id)
    owner_scene_instance_ref = Keyword.get(opts, :owner_scene_instance_ref, 7_001)

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: owner_scene_instance_ref,
               owner_epoch: 0
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, owner_scene_instance_ref,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )
  end

  defp ensure_data_voxel_started do
    if is_nil(Process.whereis(DataService.Voxel.WriteTokenStore)) do
      start_supervised!(
        {DataService.Voxel.WriteTokenStore, name: DataService.Voxel.WriteTokenStore}
      )
    end

    if is_nil(Process.whereis(DataService.Voxel.ChunkSnapshotStore)) do
      start_supervised!(
        {DataService.Voxel.ChunkSnapshotStore,
         name: DataService.Voxel.ChunkSnapshotStore,
         write_token_store: DataService.Voxel.WriteTokenStore}
      )
    end

    :ok
  end

  defp flush_observe_writer do
    case Process.whereis(GateServer.CliObserve.Writer) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end
  end

  defp observe_path(name) do
    Path.expand("../../../../.demo/observe/#{name}", __DIR__)
  end

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        :ok
    end
  end
end
