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
      {:ok,
       Map.merge(
         %{auth_server: nil, scene_server: nil, scene_owner_nodes: %{}, world_server: nil},
         attrs
       )}
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
    def handle_call({:scene_server_for_owner, owner_scene_instance_ref}, _from, state) do
      scene_node =
        Map.get(state.scene_owner_nodes, owner_scene_instance_ref) ||
          Map.get(state.scene_owner_nodes, :default) ||
          state.scene_server

      {:reply, scene_node, state}
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

    assert_receive {:gate_ws_send, bin}
    assert is_binary(bin)
    assert <<0x62, snapshot_payload::binary>> = bin

    assert {:ok, snapshot} = SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot_payload)
    assert snapshot.request_id == 11
    assert snapshot.storage.logical_scene_id == 321
    assert snapshot.storage.chunk_coord == {2, 3, 4}

    assert %{voxel_subscriptions: subscriptions} = :sys.get_state(pid)

    assert %{
             region_id: ^region_id,
             lease_id: 9001,
             owner_scene_instance_ref: 7001,
             owner_epoch: 5,
             scene_node: scene_node
           } = Map.fetch!(subscriptions, {321, {2, 3, 4}})

    assert scene_node == node()

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

  test "rebinds voxel subscriptions after world migration cutover" do
    observe_path = observe_path("ws_chunk_subscribe_rebind.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])
    put_voxel_region(779, region_id: region_id, owner_scene_instance_ref: 7_001)

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(41, 779, {0, 0, 0}))

    assert_receive {:gate_ws_send, initial_bin}
    assert <<0x62, initial_payload::binary>> = initial_bin
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.request_id == 41

    assert %{voxel_subscriptions: subscriptions_before} = :sys.get_state(pid)

    assert %{owner_scene_instance_ref: 7_001, owner_epoch: 1} =
             Map.fetch!(subscriptions_before, {779, {0, 0, 0}})

    assert {:ok, lease_v2} =
             MapLedger.migrate_region(MapLedger, region_id, 8_001,
               lease_id: 91_779,
               owner_epoch: 2,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )

    WsConnection.receive_frame(pid, debug_probe_frame(42, "voxel_rebind 779 #{region_id}"))
    _ = :sys.get_state(pid)

    assert_receive {:gate_ws_send,
                    <<0x6F, 42::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "voxel_rebind=ok"
    assert debug_result =~ "rebound_count=1"

    assert_receive {:gate_ws_send, rebound_bin}
    assert <<0x62, rebound_payload::binary>> = rebound_bin
    assert {:ok, rebound} = SceneVoxelCodec.decode_chunk_snapshot_payload(rebound_payload)
    assert rebound.request_id == 41

    assert %{voxel_subscriptions: subscriptions_after} = :sys.get_state(pid)

    assert %{
             region_id: ^region_id,
             lease_id: 91_779,
             owner_scene_instance_ref: 8_001,
             owner_epoch: 2
           } = Map.fetch!(subscriptions_after, {779, {0, 0, 0}})

    assert lease_v2.lease_id == 91_779

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_subscription_rebind_requested")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_routed")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_subscribed_new")
  end

  test "chunk subscribe forwards initial snapshot then ChunkDelta on later impact" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    put_voxel_region(777, region_id: System.unique_integer([:positive, :monotonic]))

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(21, 777, {0, 0, 0}))

    assert_receive {:gate_ws_send, initial_bin}
    assert is_binary(initial_bin)
    assert <<0x62, initial_payload::binary>> = initial_bin
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

    assert_receive {:gate_ws_send, updated_bin}
    assert is_binary(updated_bin)
    assert <<0x63, delta_payload::binary>> = updated_bin
    assert {:ok, delta} = SceneVoxelCodec.decode_chunk_delta_payload(delta_payload)
    assert delta.logical_scene_id == 777
    assert delta.chunk_coord == {0, 0, 0}
    assert delta.base_chunk_version == 0
    assert delta.new_chunk_version == 1
    assert [%{delta_kind: 1, cell_version: 1}] = delta.ops
  end

  test "build reservation intent in scene returns stub-accepted voxel intent result" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      build_reservation_intent_frame(401, 11, 555, 9_001,
        bounds: {-100, -50, -25, 200, 75, 50},
        ttl_ms: 5_000
      )
    )

    assert_voxel_intent_stub_accepted(
      request_id: 401,
      client_intent_seq: 11,
      logical_scene_id: 555
    )
  end

  test "prefab place intent rasterizes pillar, applies real writes, and emits ChunkDelta per cell" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: 666,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7_001,
               owner_epoch: 0
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7_001,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    # Subscribe first so we observe the per-cell ChunkDelta stream.
    WsConnection.receive_frame(pid, chunk_subscribe_frame(601, 666, {0, 0, 0}))
    assert_receive {:gate_ws_send, initial_bin}
    assert <<0x62, initial_payload::binary>> = initial_bin
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.storage.chunk_version == 0

    # Pillar (blueprint 1) anchored at world-micro (8, 16, 24) → world-macro (1, 2, 3).
    # Three cells all stay in chunk (0, 0, 0) at locals (1,2,3), (1,2,4), (1,2,5).
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(602, 13, 666, 8_888,
        blueprint_id: 1,
        blueprint_version: 1,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    # The accept reply lands first because the dispatch sends it synchronously
    # while still inside the per-frame cast handler. The three ChunkDelta
    # payloads queue up in the WsConnection's mailbox while apply_intent is
    # being called, then drain through `handle_info` and forward to the owner
    # after dispatch returns.
    assert_voxel_intent_accepted(
      request_id: 602,
      client_intent_seq: 13,
      logical_scene_id: 666,
      result_ref: 3
    )

    # Three cells → three ChunkDelta pushes, each with cell_version growing 1..3.
    deltas =
      for _ <- 1..3 do
        assert_receive {:gate_ws_send, delta_bin}
        assert <<0x63, delta_payload::binary>> = delta_bin
        assert {:ok, delta} = SceneVoxelCodec.decode_chunk_delta_payload(delta_payload)
        delta
      end

    # Each delta is for chunk (0,0,0) and contains exactly one put-solid op.
    Enum.each(deltas, fn delta ->
      assert delta.logical_scene_id == 666
      assert delta.chunk_coord == {0, 0, 0}
      assert [%{delta_kind: 1}] = delta.ops
    end)

    versions = Enum.map(deltas, & &1.new_chunk_version)
    assert versions == [1, 2, 3]

    base_versions = Enum.map(deltas, & &1.base_chunk_version)
    assert base_versions == [0, 1, 2]

    cell_versions =
      Enum.map(deltas, fn delta -> delta.ops |> hd() |> Map.fetch!(:cell_version) end)

    assert cell_versions == [1, 2, 3]
  end

  test "prefab place intent rejects unknown blueprint with v1 reason" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(701, 14, 555, 9_999,
        blueprint_id: 4_242,
        blueprint_version: 1,
        anchor: {0, 0, 0},
        rotation: 0
      )
    )

    assert_voxel_intent_result(
      request_id: 701,
      client_intent_seq: 14,
      logical_scene_id: 555,
      reason: ":unknown_blueprint"
    )
  end

  test "prefab place intent rejects unsupported rotation in v1" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(702, 15, 555, 9_999,
        blueprint_id: 1,
        blueprint_version: 1,
        anchor: {0, 0, 0},
        rotation: 90
      )
    )

    assert_voxel_intent_result(
      request_id: 702,
      client_intent_seq: 15,
      logical_scene_id: 555,
      reason: ":unsupported_rotation"
    )
  end

  test "prefab place intent rejects when world routing fails" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    # No FakeInterface started → fetch_world_node fails fast.
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(703, 16, 555, 9_999,
        blueprint_id: 1,
        blueprint_version: 1,
        anchor: {0, 0, 0},
        rotation: 0
      )
    )

    assert_voxel_intent_result(
      request_id: 703,
      client_intent_seq: 16,
      logical_scene_id: 555,
      reason: ":world_unavailable"
    )
  end

  test "prefab place intent outside scene rejects with invalid_state" do
    {:ok, pid} = WsConnection.start_link(self())

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(704, 17, 555, 9_999,
        blueprint_id: 1,
        blueprint_version: 1,
        anchor: {0, 0, 0},
        rotation: 0
      )
    )

    assert_voxel_intent_result(
      request_id: 704,
      client_intent_seq: 17,
      logical_scene_id: 555,
      reason: ":invalid_state"
    )
  end

  test "chunk unsubscribe removes live subscription and stops later snapshot pushes" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    put_voxel_region(778, region_id: System.unique_integer([:positive, :monotonic]))

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(31, 778, {0, 0, 0}))
    assert_receive {:gate_ws_send, initial_bin}
    assert is_binary(initial_bin)
    assert <<0x62, _initial_payload::binary>> = initial_bin

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

  describe "Phase 1c — VoxelEditIntent (0x70) routing" do
    test "voxel_edit_intent outside scene replies with invalid_state intent result" do
      observe_path = observe_path("ws_voxel_edit_intent_dropped.log")
      File.rm(observe_path)
      Application.put_env(:gate_server, :cli_observe_log, observe_path)

      {:ok, pid} = WsConnection.start_link(self())
      # Intentionally NOT calling put_connection_in_scene/1.

      frame =
        voxel_edit_intent_frame(
          request_id: 7000,
          client_intent_seq: 11,
          logical_scene_id: 222
        )

      WsConnection.receive_frame(pid, frame)

      assert_voxel_intent_result(
        request_id: 7000,
        client_intent_seq: 11,
        logical_scene_id: 222,
        reason: ":invalid_state"
      )

      flush_observe_writer()
      log = File.read!(observe_path)

      assert log =~ ~s(event="ws_voxel_edit_intent_dropped_invalid_state")
      assert log =~ "request_id: 7000"
    end

    test "voxel_edit_intent in scene rejects when world lookup is unavailable" do
      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 8001,
          client_intent_seq: 12,
          logical_scene_id: 100,
          action: 0,
          target_granularity: 0
        )
      )

      assert_voxel_intent_result(
        request_id: 8001,
        client_intent_seq: 12,
        logical_scene_id: 100,
        reason: ":world_unavailable"
      )
    end

    test "voxel_edit_intent (Place + Macro) routes through world, applies solid block, persists snapshot" do
      observe_path = observe_path("ws_voxel_edit_intent_macro_place.log")
      File.rm(observe_path)
      Application.put_env(:gate_server, :cli_observe_log, observe_path)

      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 600

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9101,
          client_intent_seq: 7,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 0,
          target_world_micro: {8, 16, 24},
          material_id: 13,
          client_hint_hash: 0xC0FFEE
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9101,
        client_intent_seq: 7,
        logical_scene_id: logical_scene_id,
        result_ref: 1
      )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})
      assert snapshot.chunk_version == 1

      assert {:ok, %{storage: storage}} =
               SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot.data)

      header = Storage.macro_header_at(storage, {1, 2, 3})
      assert header.mode == MacroCellHeader.cell_mode_solid_block()

      flush_observe_writer()
      log = File.read!(observe_path)

      assert log =~ ~s(event="ws_voxel_edit_intent_received")
      assert log =~ "client_hint_hash: 12648430"
      assert log =~ ~s(event="voxel_edit_intent_routed")
      assert log =~ "operation: :put_solid_block"
      assert log =~ ~s(event="ws_voxel_edit_intent_applied")
    end

    test "voxel_edit_intent (Place + Micro) writes a refined slot in the targeted macro cell" do
      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 601

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      # Empty target macro at world_micro (16, 16, 16) → world_macro {2, 2, 2}
      # → chunk {0, 0, 0}, local_macro {2, 2, 2}. With face_normal (0, 0, 0)
      # the resolved target equals (16, 16, 16) → micro_slot {0, 0, 0} = 0.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9201,
          client_intent_seq: 8,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 1,
          target_world_micro: {16, 16, 16},
          face_normal: {0, 0, 0},
          material_id: 5
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9201,
        client_intent_seq: 8,
        logical_scene_id: logical_scene_id,
        result_ref: 1
      )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})

      assert {:ok, %{storage: storage}} =
               SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot.data)

      assert Storage.macro_header_at(storage, {2, 2, 2}).mode ==
               MacroCellHeader.cell_mode_refined()
    end

    test "voxel_edit_intent (Place) consumes face_normal and shifts target by one micro slot" do
      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 602

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      # target_world_micro (7, 0, 0) is in macro {0, 0, 0}; with face_normal
      # (1, 0, 0) the resolved target is (8, 0, 0) → macro {1, 0, 0}.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9301,
          client_intent_seq: 9,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 0,
          target_world_micro: {7, 0, 0},
          face_normal: {1, 0, 0},
          material_id: 17
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9301,
        client_intent_seq: 9,
        logical_scene_id: logical_scene_id,
        result_ref: 1
      )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})

      assert {:ok, %{storage: storage}} =
               SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot.data)

      # The shifted macro {1, 0, 0} is the one that became solid; the original
      # macro {0, 0, 0} stays empty.
      assert Storage.macro_header_at(storage, {1, 0, 0}).mode ==
               MacroCellHeader.cell_mode_solid_block()

      assert Storage.macro_header_at(storage, {0, 0, 0}).mode ==
               MacroCellHeader.cell_mode_empty()
    end

    test "voxel_edit_intent (Place + ObjectPart) is rejected with granularity_object_part_not_implemented" do
      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9401,
          client_intent_seq: 10,
          logical_scene_id: 603,
          action: 0,
          target_granularity: 2
        )
      )

      assert_voxel_intent_result(
        request_id: 9401,
        client_intent_seq: 10,
        logical_scene_id: 603,
        reason: ":granularity_object_part_not_implemented"
      )
    end

    test "voxel_edit_intent (Damage) is rejected wholesale with action_not_implemented" do
      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9501,
          client_intent_seq: 11,
          logical_scene_id: 604,
          action: 2,
          target_granularity: 0
        )
      )

      assert_voxel_intent_result(
        request_id: 9501,
        client_intent_seq: 11,
        logical_scene_id: 604,
        reason: ":action_not_implemented"
      )
    end

    test "voxel_edit_intent rejects with Stale code when expected_chunk_version mismatches" do
      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 605

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      # First write succeeds — current chunk_version becomes 1.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9601,
          client_intent_seq: 12,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 0,
          target_world_micro: {0, 0, 0},
          material_id: 1
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9601,
        client_intent_seq: 12,
        logical_scene_id: logical_scene_id,
        result_ref: 1
      )

      # Second write pins expected_chunk_version=0; current is 1 → Stale.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9602,
          client_intent_seq: 13,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 0,
          target_world_micro: {16, 0, 0},
          material_id: 2,
          expected_chunk_version: 0
        )
      )

      assert_voxel_intent_stale(
        request_id: 9602,
        client_intent_seq: 13,
        logical_scene_id: logical_scene_id,
        reason: ":stale_chunk_version"
      )
    end

    test "voxel_edit_intent (Break + Micro) clears just the targeted slot, leaving siblings" do
      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 606

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      # Place two micro slots in macro {0,0,0}, then break only one.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9701,
          client_intent_seq: 14,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 1,
          target_world_micro: {0, 0, 0},
          face_normal: {0, 0, 0},
          material_id: 5
        )
      )

      assert_receive {:gate_ws_send, <<0x68, _::binary>>}

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9702,
          client_intent_seq: 15,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 1,
          target_world_micro: {1, 0, 0},
          face_normal: {0, 0, 0},
          material_id: 5
        )
      )

      assert_receive {:gate_ws_send, <<0x68, _::binary>>}

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9703,
          client_intent_seq: 16,
          logical_scene_id: logical_scene_id,
          action: 1,
          target_granularity: 1,
          target_world_micro: {0, 0, 0},
          face_normal: {0, 0, 0}
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9703,
        client_intent_seq: 16,
        logical_scene_id: logical_scene_id,
        result_ref: 3
      )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})

      assert {:ok, %{storage: storage}} =
               SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot.data)

      # Macro is still refined because slot 1 remains.
      assert Storage.macro_header_at(storage, {0, 0, 0}).mode ==
               MacroCellHeader.cell_mode_refined()
    end
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

  defp debug_probe_frame(request_id, command) do
    <<0x6F, request_id::64-big, byte_size(command)::16-big, command::binary>>
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

  defp voxel_edit_intent_frame(opts) do
    request_id = Keyword.get(opts, :request_id, 1)
    client_intent_seq = Keyword.get(opts, :client_intent_seq, 0)
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 0)
    action = Keyword.get(opts, :action, 0)
    target_granularity = Keyword.get(opts, :target_granularity, 0)
    {wx, wy, wz} = Keyword.get(opts, :target_world_micro, {0, 0, 0})
    {fnx, fny, fnz} = Keyword.get(opts, :face_normal, {0, 0, 0})
    material_id = Keyword.get(opts, :material_id, 0)
    blueprint_ref = Keyword.get(opts, :blueprint_ref, 0)
    object_ref = Keyword.get(opts, :object_ref, 0)
    part_ref = Keyword.get(opts, :part_ref, 0)
    attribute_patch_ref = Keyword.get(opts, :attribute_patch_ref, 0)
    expected_chunk_version = Keyword.get(opts, :expected_chunk_version, 0xFFFF_FFFF_FFFF_FFFF)
    expected_cell_hash = Keyword.get(opts, :expected_cell_hash, 0xFFFF_FFFF)
    client_hint_hash = Keyword.get(opts, :client_hint_hash, 0)

    <<0x70, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big, action::8,
      target_granularity::8, wx::64-big-signed, wy::64-big-signed, wz::64-big-signed,
      fnx::8-signed, fny::8-signed, fnz::8-signed, material_id::16-big, blueprint_ref::32-big,
      object_ref::64-big, part_ref::32-big, attribute_patch_ref::32-big,
      expected_chunk_version::64-big, expected_cell_hash::32-big, client_hint_hash::64-big>>
  end

  defp build_reservation_intent_frame(
         request_id,
         client_intent_seq,
         logical_scene_id,
         parcel_id,
         opts \\ []
       ) do
    {min_x, min_y, min_z, max_x, max_y, max_z} =
      Keyword.get(opts, :bounds, {-1, -1, -1, 1, 1, 1})

    known_parcel_build_epoch = Keyword.get(opts, :known_parcel_build_epoch, 0)
    intent_hash = Keyword.get(opts, :intent_hash, 0)
    ttl_ms = Keyword.get(opts, :ttl_ms, 1_000)

    <<0x65, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big,
      parcel_id::64-big, known_parcel_build_epoch::64-big, min_x::64-big-signed,
      min_y::64-big-signed, min_z::64-big-signed, max_x::64-big-signed, max_y::64-big-signed,
      max_z::64-big-signed, intent_hash::64-big, ttl_ms::32-big>>
  end

  defp prefab_place_intent_frame(
         request_id,
         client_intent_seq,
         logical_scene_id,
         parcel_id,
         opts \\ []
       ) do
    blueprint_id = Keyword.get(opts, :blueprint_id, 1)
    blueprint_version = Keyword.get(opts, :blueprint_version, 1)
    {ax, ay, az} = Keyword.get(opts, :anchor, {0, 0, 0})
    rotation = Keyword.get(opts, :rotation, 0)
    known_parcel_build_epoch = Keyword.get(opts, :known_parcel_build_epoch, 0)
    placement_flags = Keyword.get(opts, :placement_flags, 0)

    <<0x67, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big,
      parcel_id::64-big, known_parcel_build_epoch::64-big, blueprint_id::64-big,
      blueprint_version::32-big, ax::64-big-signed, ay::64-big-signed, az::64-big-signed,
      rotation::8, 0::16-big, 0::16-big, 0::16-big, placement_flags::32-big>>
  end

  defp assert_voxel_intent_stale(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    client_intent_seq = Keyword.fetch!(opts, :client_intent_seq)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    reason = Keyword.fetch!(opts, :reason)

    assert_receive {:gate_ws_send, iodata}

    assert <<0x68, got_request_id::64-big, got_client_intent_seq::32-big,
             got_logical_scene_id::64-big, 3::8, 0::64-big, 0::16-big, reason_len::16-big,
             got_reason::binary-size(reason_len)>> =
             IO.iodata_to_binary(iodata)

    assert got_request_id == request_id
    assert got_client_intent_seq == client_intent_seq
    assert got_logical_scene_id == logical_scene_id
    assert got_reason == reason
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

  defp assert_voxel_intent_stub_accepted(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    client_intent_seq = Keyword.fetch!(opts, :client_intent_seq)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)

    assert_receive {:gate_ws_send, iodata}

    assert <<0x68, got_request_id::64-big, got_client_intent_seq::32-big,
             got_logical_scene_id::64-big, 0::8, 0::64-big, 0::16-big, 0::16-big>> =
             IO.iodata_to_binary(iodata)

    assert got_request_id == request_id
    assert got_client_intent_seq == client_intent_seq
    assert got_logical_scene_id == logical_scene_id
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
