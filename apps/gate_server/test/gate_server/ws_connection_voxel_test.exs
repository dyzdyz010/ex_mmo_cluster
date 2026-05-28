defmodule GateServer.WsConnectionVoxelTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore
  alias GateServer.ChatAdapter
  alias GateServer.Voxel.{ChunkVersionLedger, ClientAckLedger, DeliveryScheduler}
  alias GateServer.WsConnection
  alias SceneServer.Movement.Ack
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.Storage
  alias WorldServer.Voxel.AuthorityObserve
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
         %{auth_server: nil, chat_server: nil, scene_server: nil, world_server: nil},
         attrs
       )}
    end

    @impl true
    def handle_call(:auth_server, _from, state) do
      {:reply, state.auth_server, state}
    end

    @impl true
    def handle_call(:chat_server, _from, state) do
      {:reply, state.chat_server, state}
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
    ensure_repo_started()

    # Phase 1d: clear the shared `voxel_chunks` table + WriteTokenStore state
    # so every test starts from a known baseline.
    Repo.delete_all(VoxelChunkSnapshot)

    if Process.whereis(WriteTokenStore) do
      WriteTokenStore.reset(WriteTokenStore)
    end

    on_exit(fn ->
      GateServer.CliObserve.flush()
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

  test "closes the browser websocket when the attached scene player exits" do
    scene_ref =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid} = WsConnection.start_link(self())
    gate_ref = Process.monitor(pid)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: :in_scene,
          cid: 42,
          scene_ref: scene_ref,
          scene_monitor_ref: Process.monitor(scene_ref)
      }
    end)

    send(scene_ref, :stop)

    assert_receive {:gate_ws_close, :scene_ref_down}, 500
    assert_receive {:DOWN, ^gate_ref, :process, ^pid, :normal}, 500
  end

  test "movement_ack sends WS ACK before refreshing partition and chat presence" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()
    ensure_chat_directory_started()
    logical_scene_id = unique_id()
    source_region_id = unique_id()
    target_region_id = unique_id()

    put_partition_region(logical_scene_id, source_region_id, {0, 0, 0}, {1, 1, 1}, 92_001)
    put_partition_region(logical_scene_id, target_region_id, {1, 0, 0}, {2, 1, 1}, 92_002)

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})
    {:ok, pid} = WsConnection.start_link(self())

    assert {:ok, _session} =
             ChatAdapter.join(%{
               cid: 42,
               username: "tester",
               connection_pid: pid,
               logical_scene_id: logical_scene_id,
               region_id: source_region_id,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        chat_session_joined?: true,
        chat_context: %{
          logical_scene_id: logical_scene_id,
          region_id: source_region_id,
          chunk_coord: {0, 0, 0}
        },
        partition_context: %{
          logical_scene_id: logical_scene_id,
          region_id: source_region_id,
          chunk_coord: {0, 0, 0}
        }
      })
    end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 315,
         auth_tick: 2719,
         position: {1_650.0, 50.0, 0.0}
       })}
    )

    assert_receive {:gate_ws_send, iodata}, 500

    assert <<0x8B, 1, 315::32-big, 2719::32-big, _server_send_ms_315::64-big, 42::64-big,
             1_650.0::float-64-big, 50.0::float-64-big, _z::float-64-big,
             _::binary>> = IO.iodata_to_binary(iodata)

    wait_until(fn ->
      match?(
        %{chat_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}},
        :sys.get_state(pid)
      )
    end)

    refreshed_state = :sys.get_state(pid)

    assert %{chat_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}} =
             refreshed_state

    assert %{partition_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}} =
             refreshed_state

    assert %{last_partition_refresh: %{subscription_apply_status: :ok}} = refreshed_state
    refute Map.has_key?(refreshed_state, :partition_refresh_pending)
    assert Map.has_key?(refreshed_state.voxel_subscriptions, {logical_scene_id, {1, 0, 0}})
    assert refreshed_state.voxel_subscription_plan.subscribe_count >= 1
  end

  test "movement_ack leaves WS connection responsive while partition refresh is pending" do
    parent = self()
    {:ok, pid} = WsConnection.start_link(parent)

    refresh_fun = blocking_partition_refresh_fun(parent)

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        chat_session_joined?: true,
        chat_context: %{
          logical_scene_id: 700,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        partition_context: %{
          logical_scene_id: 700,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        partition_refresh_fun: refresh_fun
      })
    end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 415,
         auth_tick: 3_001,
         position: {1_650.0, 50.0, 0.0}
       })}
    )

    assert_receive {:partition_refresh_started, refresh_pid, ^pid, ^pid}, 500

    assert_receive {:gate_ws_send, iodata}, 500

    assert <<0x8B, 1, 415::32-big, 3001::32-big, _server_send_ms_415::64-big, 42::64-big,
             1_650.0::float-64-big, 50.0::float-64-big, _z::float-64-big,
             _::binary>> = IO.iodata_to_binary(iodata)

    pending_state = :sys.get_state(pid)
    assert pending_state.partition_context.region_id == 10
    assert pending_state.partition_refresh_pending.generation == 1
    assert pending_state.partition_refresh_pending.status == :pending
    assert pending_state.partition_refresh_pending.auth_tick == 3_001

    WsConnection.receive_frame(pid, debug_probe_frame(416, "voxel_transport"))

    assert_receive {:gate_ws_send,
                    <<0x6F, 416::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "partition_refresh_generation=1"
    assert debug_result =~ "partition_refresh_pending_status=pending"
    assert debug_result =~ "partition_refresh_pending_generation=1"
    assert debug_result =~ "partition_refresh_pending_auth_tick=3001"

    send(refresh_pid, :release_partition_refresh)
  end

  test "movement input dispatch does not block AOI downlinks" do
    scene_ref = blocking_movement_scene_ref(self())
    on_exit(fn -> send(scene_ref, :release_movement_call) end)

    {:ok, pid} = WsConnection.start_link(self())

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        scene_ref: scene_ref
      })
    end)

    WsConnection.receive_frame(pid, movement_input_frame(18))

    assert_receive {:scene_movement_cast_received, 18}, 100

    GenServer.cast(pid, {:player_enter, 99, {10.0, 20.0, 30.0}})

    assert_receive {:gate_ws_send,
                    <<0x81, 99::64-big, 10.0::float-64-big, 20.0::float-64-big,
                      30.0::float-64-big>>},
                   100
  end

  test "bootstrap retry applies partition window for idle scene players after World route appears" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()
    ensure_chat_directory_started()

    logical_scene_id = unique_id()
    region_id = unique_id()
    scene_ref = fake_scene_ref(self())

    put_partition_region(logical_scene_id, region_id, {0, 0, 0}, {1, 1, 1}, 92_301)
    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})
    {:ok, pid} = WsConnection.start_link(self())

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        scene_ref: scene_ref,
        partition_context: %{
          logical_scene_id: logical_scene_id,
          region_id: nil,
          chunk_coord: {0, 0, 0}
        },
        last_partition_refresh: %{
          status: :failed,
          reason: :unroutable_center,
          logical_scene_id: logical_scene_id,
          chunk_coord: {0, 0, 0}
        }
      })
    end)

    send(
      pid,
      {:partition_bootstrap_retry,
       %{cid: 42, ack_seq: 0, auth_tick: 0, position: {100.0, 100.0, 0.0}}, 1}
    )

    assert_receive {:scene_cast, {:partition_window, window}}, 500
    assert window.logical_scene_id == logical_scene_id
    assert window.center_chunk == {0, 0, 0}

    wait_until(fn ->
      match?(
        %{last_partition_refresh: %{status: :updated, region_id: ^region_id}},
        :sys.get_state(pid)
      )
    end)
  end

  test "partition refresh completion with mismatched auth_tick is dropped by WS owner process" do
    parent = self()
    {:ok, pid} = WsConnection.start_link(parent)

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        partition_refresh_generation: 1,
        partition_refresh_pending: %{status: :pending, generation: 1, auth_tick: 4_001},
        partition_context: %{
          logical_scene_id: 700,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        chat_context: %{
          logical_scene_id: 700,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        partition_refresh_apply_fun: fn current_state, _decision, _opts ->
          send(parent, :mismatched_auth_tick_apply_called)
          {:ok, current_state, %{status: :applied_by_wrong_tick}}
        end
      })
    end)

    send(
      pid,
      {:partition_refresh_completed, 1, 4_000,
       {:ok,
        %{
          kind: :last_refresh,
          status: :ok,
          outcome: %{status: :updated, boundary_kind: :region, region_id: 20}
        }}}
    )

    Process.sleep(50)
    refute_received :mismatched_auth_tick_apply_called

    state = :sys.get_state(pid)
    assert state.partition_refresh_pending.auth_tick == 4_001
    assert state.last_partition_refresh == nil
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
               owner_epoch: 0,
               assigned_scene_node: node()
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
    observe_path = observe_path("ws_chunk_subscribe_missing_center_plan.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

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

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_subscription_window_planned")
    assert observe_log =~ "requested_chunk_count: 1"
    assert observe_log =~ "missing_chunk_count: 1"
    assert observe_log =~ "skipped_count: 1"
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
               owner_epoch: 4,
               assigned_scene_node: node()
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

  test "chunk subscribe rejects a client scene outside the authoritative partition context" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    allowed_scene_id = unique_id()
    forged_scene_id = unique_id()
    allowed_region_id = unique_id()
    forged_region_id = unique_id()

    put_partition_region(allowed_scene_id, allowed_region_id, {0, 0, 0}, {1, 1, 1}, 70_001)
    put_partition_region(forged_scene_id, forged_region_id, {0, 0, 0}, {1, 1, 1}, 70_002)

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: :in_scene,
          cid: 42,
          partition_context: %{
            logical_scene_id: allowed_scene_id,
            region_id: allowed_region_id,
            chunk_coord: {0, 0, 0}
          }
      }
    end)

    _ = :sys.get_state(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(901, forged_scene_id, {0, 0, 0}))

    assert_voxel_intent_result(
      request_id: 901,
      logical_scene_id: forged_scene_id,
      reason: ":unauthorized_voxel_target"
    )
  end

  test "chunk subscribe uses partition window and skips missing halo chunks" do
    observe_path = observe_path("ws_chunk_subscribe_partition_window.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: 654,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7_001,
               owner_epoch: 1,
               assigned_scene_node: node()
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7_001,
               lease_id: 91_654,
               owner_epoch: 2,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(12, 654, {0, 0, 0}, 1))

    assert_receive {:gate_ws_send, bin}
    assert <<0x62, snapshot_payload::binary>> = bin
    assert {:ok, snapshot} = SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot_payload)
    assert snapshot.request_id == 12
    assert snapshot.storage.logical_scene_id == 654
    assert snapshot.storage.chunk_coord == {0, 0, 0}

    assert %{voxel_subscriptions: subscriptions} = :sys.get_state(pid)
    assert Map.keys(subscriptions) == [{654, {0, 0, 0}}]

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_subscription_window_planned")
    assert observe_log =~ "assigned_chunk_count: 1"
    assert observe_log =~ "missing_chunk_count: 26"
    assert observe_log =~ "requested_chunk_count: 27"
    assert observe_log =~ "near_radius: 0"
    assert observe_log =~ "halo_radius: 1"
    assert observe_log =~ "near_vertical_radius: 0"
    assert observe_log =~ "halo_vertical_radius: 1"
    assert observe_log =~ "subscribe_count: 1"
    assert observe_log =~ "subscribed_chunk_count: 1"
    assert observe_log =~ "skipped_count: 26"
    assert observe_log =~ "pressure: :normal"
    assert observe_log =~ "priority: :critical"

    WsConnection.receive_frame(pid, debug_probe_frame(13, "voxel_transport"))

    assert_receive {:gate_ws_send,
                    <<0x6F, 13::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "voxel_subscription_plan_pressure=normal"
    assert debug_result =~ "voxel_subscription_plan_center_chunk={0, 0, 0}"
    assert debug_result =~ "voxel_subscription_plan_near_radius=0"
    assert debug_result =~ "voxel_subscription_plan_halo_radius=1"
    assert debug_result =~ "voxel_subscription_plan_near_vertical_radius=0"
    assert debug_result =~ "voxel_subscription_plan_halo_vertical_radius=1"
    assert debug_result =~ "voxel_subscription_plan_subscribe_count=1"
    assert debug_result =~ "voxel_subscription_plan_skipped_count=26"
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

    :sys.replace_state(pid, fn state ->
      update_in(state.voxel_subscriptions[{779, {0, 0, 0}}].scene_node, fn _old ->
        :old_scene@nohost
      end)
    end)

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
    assert observe_log =~ ~s(event="voxel_subscription_rebind_unsubscribed_old")
  end

  test "debug rebind failure records pending recovery and later restores it" do
    observe_path = observe_path("ws_chunk_subscribe_rebind_failure.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    logical_scene_id = 781
    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 8_101,
               owner_epoch: 0,
               assigned_scene_node: :missing_scene@nohost
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 8_101,
               lease_id: 91_781,
               owner_epoch: 2,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :voxel_subscriptions, %{
        {logical_scene_id, {0, 0, 0}} => %{
          logical_scene_id: logical_scene_id,
          chunk_coord: {0, 0, 0},
          request_id: 45,
          scene_node: node(),
          region_id: region_id,
          lease_id: 100,
          owner_scene_instance_ref: 7_101,
          owner_epoch: 1
        }
      })
    end)

    WsConnection.receive_frame(
      pid,
      debug_probe_frame(45, "voxel_rebind #{logical_scene_id} #{region_id}")
    )

    _ = :sys.get_state(pid)

    assert_receive {:gate_ws_send,
                    <<0x6F, 45::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "voxel_rebind=ok"
    assert debug_result =~ "rebound_count=0"
    assert debug_result =~ "error_count=1"
    assert debug_result =~ "invalidated_subscription_count=1"
    assert debug_result =~ "pending_rebind_count=1"

    state = :sys.get_state(pid)
    key = {logical_scene_id, {0, 0, 0}}
    refute Map.has_key?(state.voxel_subscriptions, key)

    assert %{
             old_lease_id: 100,
             old_owner_scene_instance_ref: 7_101,
             reason: :scene_unavailable,
             rebind_reason: :debug_probe
           } = state.voxel_subscription_rebind_pending[key]

    ensure_scene_voxel_started()

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 8_101,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    WsConnection.receive_frame(
      pid,
      debug_probe_frame(46, "voxel_rebind #{logical_scene_id} #{region_id}")
    )

    _ = :sys.get_state(pid)

    assert_receive {:gate_ws_send,
                    <<0x6F, 46::64-big, recovered_len::16-big,
                      recovered_result::binary-size(recovered_len)>>}

    assert recovered_result =~ "voxel_rebind=ok"
    assert recovered_result =~ "rebound_count=1"
    assert recovered_result =~ "pending_rebind_count=0"

    assert_receive {:gate_ws_send, rebound_bin}
    assert <<0x62, rebound_payload::binary>> = rebound_bin
    assert {:ok, rebound} = SceneVoxelCodec.decode_chunk_snapshot_payload(rebound_payload)
    assert rebound.request_id == 45

    recovered_state = :sys.get_state(pid)
    assert recovered_state.voxel_subscription_rebind_pending == %{}

    current_node = node()

    assert %{
             scene_node: ^current_node,
             region_id: ^region_id,
             lease_id: 91_781,
             owner_scene_instance_ref: 8_101,
             owner_epoch: 2
           } = recovered_state.voxel_subscriptions[key]

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_subscription_rebind_aggregate_requested")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_error")
    assert observe_log =~ "active_subscription_removed?: true"
    assert observe_log =~ "pending_rebind_count: 1"
    assert observe_log =~ ~s(event="voxel_subscription_rebind_subscribed_new")
    assert observe_log =~ "pending_rebind_count: 0"
  end

  test "migration cutover invalidate automatically rebinds websocket voxel subscriptions" do
    observe_path = observe_path("ws_chunk_subscribe_auto_rebind.log")
    logical_scene_id = 780
    File.rm(observe_path)

    {:ok, gate_route} = GateServer.CliObserve.register_route(logical_scene_id, observe_path)
    {:ok, world_route} = WorldServer.CliObserve.register_route(logical_scene_id, observe_path)
    {:ok, scene_route} = SceneServer.CliObserve.register_route(logical_scene_id, observe_path)

    on_exit(fn ->
      GateServer.CliObserve.flush()
      WorldServer.CliObserve.flush()
      SceneServer.CliObserve.flush_path(observe_path)
      configure_map_ledger_scene_invalidator(nil)
      GateServer.CliObserve.unregister_route(logical_scene_id, gate_route)
      WorldServer.CliObserve.unregister_route(logical_scene_id, world_route)
      SceneServer.CliObserve.unregister_route(logical_scene_id, scene_route)
    end)

    ensure_scene_voxel_started()

    ensure_map_ledger_started(
      scene_invalidator:
        AuthorityObserve.scene_directory_invalidator(SceneServer.Voxel.ChunkDirectory)
    )

    region_id = System.unique_integer([:positive, :monotonic])
    put_voxel_region(logical_scene_id, region_id: region_id, owner_scene_instance_ref: 7_001)

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(43, logical_scene_id, {0, 0, 0}))

    assert_receive {:gate_ws_send, initial_bin}
    assert <<0x62, initial_payload::binary>> = initial_bin
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.request_id == 43

    assert {:ok, lease_v2} =
             MapLedger.migrate_region(MapLedger, region_id, 8_001,
               lease_id: 91_780,
               owner_epoch: 2,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic]),
               target_scene_node: node()
             )

    assert_receive {:gate_ws_send, <<0x69, invalidate_payload::binary>>}
    assert {:ok, invalidate} = SceneVoxelCodec.decode_chunk_invalidate_payload(invalidate_payload)
    assert invalidate.reason_name == :migration_cutover
    assert invalidate.logical_scene_id == logical_scene_id
    assert invalidate.chunk_coord == {0, 0, 0}

    assert_receive {:gate_ws_send, rebound_bin}
    assert <<0x62, rebound_payload::binary>> = rebound_bin
    assert {:ok, rebound} = SceneVoxelCodec.decode_chunk_snapshot_payload(rebound_payload)
    assert rebound.request_id == 43

    assert %{voxel_subscriptions: subscriptions_after} = :sys.get_state(pid)

    assert %{
             region_id: ^region_id,
             lease_id: 91_780,
             owner_scene_instance_ref: 8_001,
             owner_epoch: 2
           } = Map.fetch!(subscriptions_after, {logical_scene_id, {0, 0, 0}})

    assert lease_v2.lease_id == 91_780

    flush_observe_writer()
    WorldServer.CliObserve.flush()
    SceneServer.CliObserve.flush_path(observe_path)
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_migration_cutover_invalidate_emitted")
    assert observe_log =~ ~s(event="voxel_chunk_invalidate_pushed")
    assert observe_log =~ ~s(event="ws_voxel_chunk_invalidate_forwarded")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_requested")
    assert observe_log =~ ~s(reason: :migration_cutover_invalidate)
    assert observe_log =~ ~s(event="voxel_subscription_rebind_subscribed_new")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_completed")
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

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 777) ==
             %{{0, 0, 0} => 0}

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

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 777) ==
             %{{0, 0, 0} => 1}

    WsConnection.receive_frame(pid, debug_probe_frame(23, "voxel_transport"))

    assert_receive {:gate_ws_send,
                    <<0x6F, 23::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "forwarded_chunk_versions=[{777, {0, 0, 0}, 1}]"
  end

  test "websocket chunk ACK records retained client versions and reuses them after unsubscribe" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    put_voxel_region(790, region_id: System.unique_integer([:positive, :monotonic]))

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(26, 790, {0, 0, 0}))

    assert_receive {:gate_ws_send, <<0x62, initial_payload::binary>>}
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.storage.chunk_version == 0

    WsConnection.receive_frame(pid, chunk_ack_frame(27, 790, [{{0, 0, 0}, 0}]))

    assert_receive {:gate_ws_send, <<0x80, 27::64-big, 0x00>>}

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 790) ==
             %{{0, 0, 0} => 0}

    WsConnection.receive_frame(pid, debug_probe_frame(28, "voxel_transport"))

    assert_receive {:gate_ws_send,
                    <<0x6F, 28::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "client_ack_versions=[{790, {0, 0, 0}, 0}]"

    WsConnection.receive_frame(pid, chunk_unsubscribe_frame(29, 790, [{0, 0, 0}]))
    assert_receive {:gate_ws_send, <<0x80, 29::64-big, 0x00>>}

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 790) ==
             %{}

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 790) ==
             %{{0, 0, 0} => 0}

    WsConnection.receive_frame(pid, chunk_subscribe_frame(30, 790, {0, 0, 0}))

    refute_receive {:gate_ws_send, <<0x62, _payload::binary>>}, 50
    assert Map.has_key?(:sys.get_state(pid).voxel_subscriptions, {790, {0, 0, 0}})
  end

  test "websocket resync-required chunks do not reuse retained ACK after unsubscribe" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    logical_scene_id = unique_id()
    chunk_coord = {0, 0, 0}

    put_voxel_region(logical_scene_id, region_id: System.unique_integer([:positive, :monotonic]))

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(31, logical_scene_id, chunk_coord))

    assert_receive {:gate_ws_send, <<0x62, initial_payload::binary>>}
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.storage.chunk_version == 0

    WsConnection.receive_frame(pid, chunk_ack_frame(32, logical_scene_id, [{chunk_coord, 0}]))
    assert_receive {:gate_ws_send, <<0x80, 32::64-big, 0x00>>}

    :sys.replace_state(pid, fn state ->
      scheduler = %{
        DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
        | resync_required_chunks: MapSet.new([{logical_scene_id, chunk_coord}])
      }

      Map.put(state, :voxel_delivery, scheduler)
    end)

    WsConnection.receive_frame(pid, chunk_unsubscribe_frame(33, logical_scene_id, [chunk_coord]))
    assert_receive {:gate_ws_send, <<0x80, 33::64-big, 0x00>>}

    assert DeliveryScheduler.resync_required_chunks(
             :sys.get_state(pid).voxel_delivery,
             logical_scene_id
           ) == [chunk_coord]

    WsConnection.receive_frame(pid, chunk_subscribe_frame(34, logical_scene_id, chunk_coord))

    assert_receive {:gate_ws_send, <<0x62, resync_payload::binary>>}
    assert {:ok, resync_snapshot} = SceneVoxelCodec.decode_chunk_snapshot_payload(resync_payload)
    assert resync_snapshot.storage.logical_scene_id == logical_scene_id
    assert resync_snapshot.storage.chunk_coord == chunk_coord
  end

  test "chunk invalidate clears forwarded version cache before forwarding over websocket" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(778, {0, 0, 0}, 7)

    {client_acks, %{status: :ok}} =
      ClientAckLedger.record_known_versions(ClientAckLedger.new(), forwarded, 778, [
        {{0, 0, 0}, 7}
      ])

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        forwarded_chunk_versions: forwarded,
        client_ack_versions: client_acks
      })
    end)

    payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 778,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    send(pid, {:voxel_chunk_invalidate_payload, payload})

    assert_receive {:gate_ws_send, <<0x69, ^payload::binary>>}

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 778) ==
             %{}

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 778) == %{}
  end

  test "websocket live voxel delivery queues over-budget snapshots without advancing forwarded versions" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(782, {0, 0, 0}, 1)
    second_payload = snapshot_payload(782, {1, 0, 0}, 1)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_chunk_snapshot_payload, second_payload})
    refute_receive {:gate_ws_send, <<0x62, _payload::binary>>}, 50

    state = :sys.get_state(pid)

    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 782) ==
             %{{0, 0, 0} => 1}

    assert DeliveryScheduler.summary(state.voxel_delivery).queued_count == 1

    WsConnection.receive_frame(pid, debug_probe_frame(25, "voxel_transport"))

    assert_receive {:gate_ws_send,
                    <<0x6F, 25::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>}

    assert debug_result =~ "voxel_delivery_queue_count=1"
    assert debug_result =~ "voxel_delivery_deferred_count=1"
  end

  test "websocket live voxel delivery drains queued data on the real scheduler timer" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(784, {0, 0, 0}, 1)
    second_payload = snapshot_payload(784, {1, 0, 0}, 1)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128,
          window_interval_ms: 20
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_chunk_snapshot_payload, second_payload})
    assert_receive {:gate_ws_send, <<0x62, ^second_payload::binary>>}, 500

    state = :sys.get_state(pid)

    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 784) == %{
             {0, 0, 0} => 1,
             {1, 0, 0} => 1
           }

    assert DeliveryScheduler.summary(state.voxel_delivery).queued_count == 0
    assert state.voxel_delivery_timer_ref == nil
  end

  test "websocket object state deltas bypass field backlog as event traffic" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(785, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(785, {0, 0, 0}, 44, 3)

    object_payload =
      object_state_delta_payload(785,
        object_id: 501,
        object_version: 2,
        affected_chunks: [{0, 0, 0}]
      )

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_field_region_snapshot_payload, field_payload})
    refute_receive {:gate_ws_send, ^field_payload}, 50

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    send(pid, {:voxel_object_state_delta_payload, object_payload})
    assert_receive {:gate_ws_send, <<0x6C, ^object_payload::binary>>}

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1
  end

  test "websocket delivery envelopes enter the same live voxel send window" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(788, {0, 0, 0}, 1)
    opaque_field_payload = <<1, 2, 3>>

    :sys.replace_state(pid, fn state ->
      state
      |> put_voxel_test_subscription(788, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
      |> Map.put(
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(opaque_field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_delivery_envelope, field_region_envelope(788, opaque_field_payload)})
    refute_receive {:gate_ws_send, ^opaque_field_payload}, 50

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    send(pid, :voxel_delivery_window)
    assert_receive {:gate_ws_send, ^opaque_field_payload}
  end

  test "websocket delivery invalidate envelopes forward and clear retained chunk ledgers" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 789,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    :sys.replace_state(pid, fn state ->
      state
      |> put_voxel_test_subscription(789, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
      |> Map.put(
        :forwarded_chunk_versions,
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(789, {0, 0, 0}, 7)
      )
      |> Map.put(
        :client_ack_versions,
        record_test_client_ack(789, {0, 0, 0}, 7)
      )
    end)

    send(pid, {:voxel_delivery_envelope, invalidate_envelope(789, payload)})

    assert_receive {:gate_ws_send, <<0x69, ^payload::binary>>}

    state = :sys.get_state(pid)
    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 789) == %{}
    assert ClientAckLedger.known_versions(state.client_ack_versions, 789) == %{}
    assert DeliveryScheduler.summary(state.voxel_delivery).control_sent_count == 1
  end

  test "websocket rejects delivery envelopes whose lease no longer matches the subscription" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      put_voxel_test_subscription(state, 790, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
    end)

    payload = <<1, 2, 3>>

    send(
      pid,
      {:voxel_delivery_envelope,
       field_region_envelope(790, payload, lease_id: 999, owner_epoch: 2)}
    )

    refute_receive {:gate_ws_send, ^payload}, 50

    summary = DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "websocket rejects delivery envelopes whose owner epoch no longer matches the subscription" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      put_voxel_test_subscription(state, 791, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
    end)

    payload = <<1, 2, 3>>

    send(
      pid,
      {:voxel_delivery_envelope,
       field_region_envelope(791, payload, lease_id: 101, owner_epoch: 9)}
    )

    refute_receive {:gate_ws_send, ^payload}, 50

    summary = DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "websocket rejects delivery envelopes whose region no longer matches the subscription" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      put_voxel_test_subscription(state, 792, {0, 0, 0},
        region_id: 45,
        lease_id: 101,
        owner_epoch: 2
      )
    end)

    payload = <<1, 2, 3>>

    send(
      pid,
      {:voxel_delivery_envelope,
       field_region_envelope(792, payload, lease_id: 101, owner_epoch: 2)}
    )

    refute_receive {:gate_ws_send, ^payload}, 50

    summary = DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "websocket field region snapshots are queued and destroyed messages prune them" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(786, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(786, {0, 0, 0}, 44, 3)
    destroyed_payload = field_region_destroyed_payload(786, {0, 0, 0}, 44)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_field_region_snapshot_payload, field_payload})
    refute_receive {:gate_ws_send, ^field_payload}, 50

    send(pid, {:voxel_field_region_destroyed_payload, destroyed_payload})
    assert_receive {:gate_ws_send, ^destroyed_payload}

    send(pid, :voxel_delivery_window)
    refute_receive {:gate_ws_send, ^field_payload}, 50

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 0
  end

  test "websocket malformed field region destroyed is rejected and does not prune queued snapshots" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(787, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(787, {0, 0, 0}, 44, 3)
    malformed_destroyed_payload = field_region_destroyed_payload(787, {0, 0, 0}, 44) <> <<0xFF>>

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_field_region_snapshot_payload, field_payload})
    refute_receive {:gate_ws_send, ^field_payload}, 50

    send(pid, {:voxel_field_region_destroyed_payload, malformed_destroyed_payload})
    refute_receive {:gate_ws_send, ^malformed_destroyed_payload}, 50

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    send(pid, :voxel_delivery_window)
    assert_receive {:gate_ws_send, ^field_payload}
  end

  test "websocket chunk invalidate bypasses budget and drops queued live data for the same chunk" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(783, {0, 0, 0}, 1)

    queued_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 783,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 1,
        new_chunk_version: 2,
        ops: []
      })

    invalidate_payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 783,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(queued_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert_receive {:gate_ws_send, <<0x62, ^first_payload::binary>>}

    send(pid, {:voxel_chunk_delta_payload, queued_payload})
    refute_receive {:gate_ws_send, <<0x63, ^queued_payload::binary>>}, 50

    send(pid, {:voxel_chunk_invalidate_payload, invalidate_payload})
    assert_receive {:gate_ws_send, <<0x69, ^invalidate_payload::binary>>}

    send(pid, :voxel_delivery_window)
    refute_receive {:gate_ws_send, <<0x63, ^queued_payload::binary>>}, 50

    state = :sys.get_state(pid)
    assert DeliveryScheduler.summary(state.voxel_delivery).queued_count == 0
    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 783) == %{}
  end

  test "chunk unsubscribe clears forwarded version cache over websocket" do
    {:ok, pid} = WsConnection.start_link(self())

    state =
      :sys.replace_state(pid, fn state ->
        Map.merge(state, %{
          status: :in_scene,
          cid: 42,
          forwarded_chunk_versions:
            ChunkVersionLedger.new()
            |> ChunkVersionLedger.record_version!(780, {0, 0, 0}, 7),
          voxel_subscriptions: %{
            {780, {0, 0, 0}} => %{
              logical_scene_id: 780,
              chunk_coord: {0, 0, 0},
              scene_node: node()
            }
          }
        })
      end)

    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 780) ==
             %{{0, 0, 0} => 7}

    first_payload = snapshot_payload(780, {0, 0, 0}, 8)

    queued_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 780,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 8,
        new_chunk_version: 9,
        ops: []
      })

    :sys.replace_state(pid, fn state ->
      scheduler =
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(queued_payload) + 128,
          window_interval_ms: 1_000
        )

      {scheduler, %{action: :send_now}} =
        DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

      {scheduler, %{action: :queued}} =
        DeliveryScheduler.offer(scheduler, :delta, queued_payload)

      Map.put(state, :voxel_delivery, scheduler)
    end)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    WsConnection.receive_frame(pid, chunk_unsubscribe_frame(24, 780, [{0, 0, 0}]))

    assert_receive {:gate_ws_send, <<0x80, 24::64-big, 0x00>>}

    next_state = :sys.get_state(pid)

    assert ChunkVersionLedger.known_versions(next_state.forwarded_chunk_versions, 780) == %{}
    assert DeliveryScheduler.summary(next_state.voxel_delivery).queued_count == 0
  end

  test "malformed voxel payloads still forward unchanged and keep websocket cache unchanged" do
    observe_path = observe_path("ws_malformed_voxel_forwarding.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :forwarded_chunk_versions,
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(781, {0, 0, 0}, 7)
      )
    end)

    expected = %{{0, 0, 0} => 7}

    for {opcode, message} <- [
          {0x62, {:voxel_chunk_snapshot_payload, <<1, 2, 3>>}},
          {0x63, {:voxel_chunk_delta_payload, <<4, 5, 6>>}},
          {0x69, {:voxel_chunk_invalidate_payload, <<7, 8, 9>>}}
        ] do
      send(pid, message)
      assert_receive {:gate_ws_send, <<^opcode, _payload::binary>>}

      assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 781) ==
               expected
    end

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ "status: :decode_failed"
    assert observe_log =~ "frame_kind: :snapshot"
    assert observe_log =~ "frame_kind: :delta"
    assert observe_log =~ "frame_kind: :invalidate"
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

  test "prefab place intent rasterizes sphere and lands through the single-chunk fast path" do
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
               owner_epoch: 0,
               assigned_scene_node: node()
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

    # Subscribe first so we observe the post-commit snapshot push.
    WsConnection.receive_frame(pid, chunk_subscribe_frame(601, 666, {0, 0, 0}))
    assert_receive {:gate_ws_send, initial_bin}
    assert <<0x62, initial_payload::binary>> = initial_bin
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.storage.chunk_version == 0

    # Phase A1-1:Sphere (blueprint 1) anchored at world-micro (8, 16, 24) →
    # world-macro (1, 2, 3) → chunk (0,0,0) local macro (1,2,3). All ~248 micro
    # slots land on the SAME macro cell (sphere mask is single-macro).
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(602, 13, 666, 8_888,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    # Single-chunk prefabs bypass the World transaction coordinator and land
    # through ChunkDirectory.apply_intents/2. The chunk version bumps once
    # (0 -> 1), and subscribers receive one compact delta.
    assert_voxel_intent_accepted(
      request_id: 602,
      client_intent_seq: 13,
      logical_scene_id: 666,
      result_ref: 1,
      timeout: 1_000
    )

    # The whole batch produces one compact ChunkDelta fan-out instead of a full
    # chunk snapshot. New joiners still get ChunkSnapshot through subscribe.
    assert_receive {:gate_ws_send, delta_bin}, 5_000
    assert <<0x63, delta_payload::binary>> = delta_bin
    assert {:ok, delta} = SceneVoxelCodec.decode_chunk_delta_payload(delta_payload)
    assert delta.logical_scene_id == 666
    assert delta.chunk_coord == {0, 0, 0}
    assert delta.base_chunk_version == 0
    assert delta.new_chunk_version == 1
    assert [%{delta_kind: 2, macro_index: 801}] = delta.ops

    # No further pushes for this prefab.
    refute_receive {:gate_ws_send, _}, 100
  end

  test "prefab place intent uses same-owner fast path across multiple chunks" do
    observe_path = observe_path("ws_prefab_same_owner_fast_path.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])
    logical_scene_id = 667

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {2, 1, 1},
               owner_scene_instance_ref: 7_001,
               owner_epoch: 0,
               assigned_scene_node: node()
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

    anchor = find_cross_chunk_prefab_anchor!()

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(603, 14, logical_scene_id, 8_888,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: anchor,
        rotation: 0
      )
    )

    assert_voxel_intent_accepted(
      request_id: 603,
      client_intent_seq: 14,
      logical_scene_id: logical_scene_id,
      result_ref: 1,
      timeout: 2_000
    )

    flush_chunk_persistence!(logical_scene_id, {0, 0, 0})
    flush_chunk_persistence!(logical_scene_id, {1, 0, 0})

    assert {:ok, snap_a} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})
    assert {:ok, snap_b} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {1, 0, 0})

    assert snap_a.chunk_version == 1
    assert snap_b.chunk_version == 1

    flush_observe_writer()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="ws_voxel_prefab_same_owner_fast_path_applied")
  end

  test "Phase A1-1 e2e: sphere prefab lands as 248 micro slots matching BlueprintCatalog mask" do
    # Phase A1-1 端到端冒烟测试:
    # 1. 启 stdio observe log (scene + gate + world) 写到 .demo/observe/a1-sphere-e2e/
    # 2. 通过 gate WsConnection 发 0x67 PrefabPlaceIntent (sphere blueprint)
    # 3. 解码 chunk snapshot 拿 storage,断言 macro (1,2,3) 处的 refined cell
    #    占用 mask 跟 BlueprintCatalog.occupancy_words/1 完全一致(像素级)
    # 4. flush observe writers 后读 scene/gate log 确认关键事件 emit
    # 5. IO.puts 总结到测试输出,便于 mix test 报告里直接看到 e2e 数据
    log_root = Path.join(System.tmp_dir!(), "a1-sphere-e2e-#{System.unique_integer([:positive])}")
    File.rm_rf!(log_root)
    File.mkdir_p!(log_root)
    scene_log = Path.join(log_root, "scene.log")
    gate_log = Path.join(log_root, "gate.log")
    world_log = Path.join(log_root, "world.log")
    logical_scene_id = 7_777

    route_observe_logs(logical_scene_id,
      scene_log: scene_log,
      gate_log: gate_log,
      world_log: world_log
    )

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7_002,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7_002,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    # Subscribe to chunk (0,0,0) so we get post-commit snapshot push.
    WsConnection.receive_frame(pid, chunk_subscribe_frame(701, logical_scene_id, {0, 0, 0}))
    assert_receive {:gate_ws_send, _initial_bin}, 5_000

    # Place sphere: blueprint_id=1, version=2, anchor world-micro (8, 16, 24)
    # → world-macro (1, 2, 3) → chunk (0,0,0) local macro (1, 2, 3).
    place_started_at = System.monotonic_time(:millisecond)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(702, 14, logical_scene_id, 9_001,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    assert_voxel_intent_accepted(
      request_id: 702,
      client_intent_seq: 14,
      logical_scene_id: logical_scene_id,
      result_ref: 1,
      timeout: 10_000
    )

    place_elapsed_ms = System.monotonic_time(:millisecond) - place_started_at

    # Macro (1, 2, 3) → linear index 1 + 2*16 + 3*256 = 801.
    macro_index = 1 + 2 * 16 + 3 * 256

    # Pull the hot-path ChunkDelta fan-out and decode the changed refined cell.
    assert_receive {:gate_ws_send, delta_bin}, 5_000
    assert <<0x63, delta_payload::binary>> = delta_bin
    assert {:ok, delta} = SceneVoxelCodec.decode_chunk_delta_payload(delta_payload)
    assert delta.logical_scene_id == logical_scene_id
    assert delta.chunk_coord == {0, 0, 0}
    assert delta.base_chunk_version == 0
    assert delta.new_chunk_version == 1
    assert [%{delta_kind: 2, macro_index: ^macro_index, payload: refined_payload}] = delta.ops
    assert {:ok, refined_cell} = SceneVoxelCodec.decode_refined_cell_payload(refined_payload)
    storage_words = refined_cell.occupancy_words

    {:ok, sphere} = SceneServer.Voxel.BlueprintCatalog.fetch(1, 2)
    expected_words = SceneServer.Voxel.BlueprintCatalog.occupancy_words(sphere)
    expected_slot_count = length(sphere.occupied_slots)

    storage_slot_count =
      Enum.reduce(storage_words, 0, fn word, acc -> acc + popcount(word) end)

    # Pixel-perfect mask match — sphere shape really sphere on disk.
    assert storage_words == expected_words,
           """
           sphere occupancy mask mismatch with BlueprintCatalog!
           storage popcount: #{storage_slot_count}
           expected popcount: #{expected_slot_count}
           """

    assert storage_slot_count == expected_slot_count

    # Verify cold-path snapshot persistence eventually lands in Postgres.
    flush_chunk_persistence!(logical_scene_id, {0, 0, 0})
    assert {:ok, persisted_row} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})
    assert persisted_row.chunk_version == 1

    assert {:ok, %{storage: persisted_storage}} =
             SceneVoxelCodec.decode_chunk_snapshot_payload(persisted_row.data)

    assert persisted_storage.chunk_version == 1
    persisted_header = Enum.at(persisted_storage.macro_headers, macro_index)
    assert persisted_header.mode == MacroCellHeader.cell_mode_refined()
    persisted_cell = Enum.at(persisted_storage.refined_cells, persisted_header.payload_index)
    assert persisted_cell.occupancy_words == expected_words

    # Flush observe writers + sample the logs.
    SceneServer.CliObserve.flush_path(scene_log)
    GateServer.CliObserve.flush()
    WorldServer.CliObserve.flush()

    scene_log_lines = read_log_lines(scene_log)
    gate_log_lines = read_log_lines(gate_log)
    world_log_lines = read_log_lines(world_log)

    # Spot-check key events on the single-chunk fast apply path.
    assert Enum.any?(scene_log_lines, &String.contains?(&1, "voxel_intents_applied")),
           "scene log missing voxel_intents_applied event"

    assert Enum.any?(
             gate_log_lines,
             &String.contains?(&1, "ws_voxel_prefab_single_chunk_fast_path_applied")
           ),
           "gate log missing ws_voxel_prefab_single_chunk_fast_path_applied event"

    assert Enum.any?(
             gate_log_lines,
             &String.contains?(&1, "ws_voxel_prefab_place_intent_applied")
           ),
           "gate log missing ws_voxel_prefab_place_intent_applied event"

    # Smoke summary — visible in mix test output for human review.
    IO.puts("""

    ── Phase A1-1 sphere e2e smoke ──────────────────────────────
      placement elapsed:        #{place_elapsed_ms} ms
      sphere occupied slots:    #{storage_slot_count}
      catalog occupied slots:   #{expected_slot_count}
      mask pixel-perfect match: #{storage_words == expected_words}
      chunk_version after place: #{delta.new_chunk_version}
      persisted to Postgres:    yes (chunk_version=#{persisted_storage.chunk_version})
      observe log root:         #{log_root}
      scene log lines:          #{length(scene_log_lines)}
      gate log lines:           #{length(gate_log_lines)}
      world log lines:          #{length(world_log_lines)}
    ─────────────────────────────────────────────────────────────
    """)
  end

  test "Phase A1-2 e2e: second sphere on same anchor is rejected by occupancy precheck" do
    # Phase A1-2:防覆盖。第一次放 sphere → accept;第二次同 anchor → reject
    # `:micro_slot_already_occupied`(prepare 阶段 occupancy precheck 拦截,
    # fence 未写入 Postgres,zero-cost cleanup);chunk_version 不再 bump,
    # 第二次结果是纯 reject 而非 silent overwrite。
    log_root =
      Path.join(System.tmp_dir!(), "a1-2-occupancy-#{System.unique_integer([:positive])}")

    File.rm_rf!(log_root)
    File.mkdir_p!(log_root)
    scene_log = Path.join(log_root, "scene.log")
    gate_log = Path.join(log_root, "gate.log")
    logical_scene_id = 7_778

    route_observe_logs(logical_scene_id,
      scene_log: scene_log,
      gate_log: gate_log
    )

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7_003,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7_003,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    # Subscribe so we observe both snapshot pushes.
    WsConnection.receive_frame(pid, chunk_subscribe_frame(801, logical_scene_id, {0, 0, 0}))
    assert_receive {:gate_ws_send, _initial_bin}, 5_000

    # Place 1: sphere at world-micro (8, 16, 24) → world-macro (1, 2, 3).
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(802, 20, logical_scene_id, 9_002,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    assert_voxel_intent_accepted(
      request_id: 802,
      client_intent_seq: 20,
      logical_scene_id: logical_scene_id,
      result_ref: 1,
      timeout: 10_000
    )

    # Drain the post-commit snapshot push.
    assert_receive {:gate_ws_send, _snapshot_bin}, 5_000

    # Place 2: same blueprint, same anchor → 280 micro slots already occupied.
    reject_started_at = System.monotonic_time(:millisecond)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(803, 21, logical_scene_id, 9_002,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    assert_voxel_intent_result(
      request_id: 803,
      client_intent_seq: 21,
      logical_scene_id: logical_scene_id,
      reason: ":micro_slot_already_occupied",
      timeout: 5_000
    )

    reject_elapsed_ms = System.monotonic_time(:millisecond) - reject_started_at

    # No further pushes for the rejected place — chunk version不变。
    refute_receive {:gate_ws_send, _}, 200

    # Verify storage still at chunk_version=1 (rejected place doesn't bump).
    assert {:ok, persisted_row} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})
    assert persisted_row.chunk_version == 1

    # Flush observe + sample logs.
    SceneServer.CliObserve.flush_path(scene_log)
    GateServer.CliObserve.flush()

    scene_log_lines = read_log_lines(scene_log)
    gate_log_lines = read_log_lines(gate_log)

    # Scene should record a hot-path rejection (second place), while Gate
    # records one fast-path success and one fast-path failure.
    rejected_lines =
      Enum.filter(scene_log_lines, &String.contains?(&1, "voxel_intent_rejected"))

    assert length(rejected_lines) >= 1,
           "scene log missing voxel_intent_rejected event"

    # Gate should record one applied (first) and one error (second) for prefab.
    applied_count =
      Enum.count(
        gate_log_lines,
        &observe_line_for?(&1, "ws_voxel_prefab_place_intent_applied", 802, logical_scene_id)
      )

    error_count =
      Enum.count(
        gate_log_lines,
        &observe_line_for?(&1, "ws_voxel_prefab_place_intent_error", 803, logical_scene_id)
      )

    fast_path_applied_count =
      Enum.count(
        gate_log_lines,
        &observe_line_for?(
          &1,
          "ws_voxel_prefab_single_chunk_fast_path_applied",
          802,
          logical_scene_id
        )
      )

    fast_path_failed_count =
      Enum.count(
        gate_log_lines,
        &observe_line_for?(
          &1,
          "ws_voxel_prefab_single_chunk_fast_path_failed",
          803,
          logical_scene_id
        )
      )

    assert applied_count == 1, "expected exactly 1 prefab applied, got #{applied_count}"
    assert error_count == 1, "expected exactly 1 prefab error, got #{error_count}"
    assert fast_path_applied_count == 1
    assert fast_path_failed_count == 1

    # Smoke summary — visible in mix test output.
    IO.puts("""

    ── Phase A1-2 occupancy reject e2e smoke ────────────────────
      first place result:        accepted (chunk_version 0 → 1)
      second place result:       rejected (:micro_slot_already_occupied)
      reject elapsed:            #{reject_elapsed_ms} ms
      chunk_version after reject: #{persisted_row.chunk_version} (unchanged)
      observe log root:          #{log_root}
      scene rejected events:      #{length(rejected_lines)}
      gate applied events:       #{applied_count}
      gate error events:         #{error_count}
    ─────────────────────────────────────────────────────────────
    """)
  end

  defp read_log_lines(path) do
    case File.read(path) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp route_observe_logs(logical_scene_id, opts) do
    previous_envs =
      [:scene_server, :gate_server, :world_server]
      |> Map.new(fn app -> {app, Application.get_env(app, :cli_observe_log)} end)

    Enum.each(previous_envs, fn {app, _value} ->
      Application.delete_env(app, :cli_observe_log)
    end)

    routes =
      [
        scene: {SceneServer.CliObserve, Keyword.get(opts, :scene_log)},
        gate: {GateServer.CliObserve, Keyword.get(opts, :gate_log)},
        world: {WorldServer.CliObserve, Keyword.get(opts, :world_log)}
      ]
      |> Enum.reduce([], fn
        {_scope, {_module, nil}}, acc ->
          acc

        {scope, {module, path}}, acc ->
          {:ok, token} = apply(module, :register_route, [logical_scene_id, path])
          [{scope, module, path, token} | acc]
      end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(routes, fn
        {:scene, _module, path, _token} -> SceneServer.CliObserve.flush_path(path)
        {:gate, _module, _path, _token} -> GateServer.CliObserve.flush()
        {:world, _module, _path, _token} -> WorldServer.CliObserve.flush()
      end)

      Enum.each(routes, fn {_scope, module, _path, token} ->
        apply(module, :unregister_route, [logical_scene_id, token])
      end)

      restore_observe_envs(previous_envs)
    end)
  end

  defp restore_observe_envs(previous_envs) do
    Enum.each(previous_envs, fn
      {app, nil} -> Application.delete_env(app, :cli_observe_log)
      {app, value} -> Application.put_env(app, :cli_observe_log, value)
    end)
  end

  defp observe_line_for?(line, event, request_id, logical_scene_id) do
    String.contains?(line, ~s(event="#{event}")) and
      String.contains?(line, "request_id: #{request_id}") and
      String.contains?(line, "logical_scene_id: #{logical_scene_id}")
  end

  defp find_cross_chunk_prefab_anchor! do
    candidates = [
      {124, 8, 8},
      {120, 8, 8},
      {126, 16, 24},
      {124, 16, 24},
      {120, 24, 32}
    ]

    Enum.find(candidates, fn anchor ->
      case SceneServer.Voxel.PrefabRaster.rasterize(1, 2, anchor, 0) do
        {:ok, cells} ->
          chunks = cells |> Enum.map(& &1.chunk_coord) |> Enum.uniq()
          {0, 0, 0} in chunks and {1, 0, 0} in chunks

        _ ->
          false
      end
    end) ||
      flunk(
        "no candidate anchor produces a sphere that straddles chunks (0,0,0) and (1,0,0); " <>
          "调整 candidates / blueprint 半径"
      )
  end

  defp flush_chunk_persistence!(logical_scene_id, chunk_coord) do
    assert {:ok, chunk_pid} =
             SceneServer.Voxel.ChunkDirectory.lookup_chunk_pid(
               SceneServer.Voxel.ChunkDirectory,
               logical_scene_id,
               chunk_coord
             )

    assert :ok = ChunkProcess.flush_persistence(chunk_pid)
  end

  defp popcount(word) when is_integer(word) and word >= 0 do
    do_popcount(word, 0)
  end

  defp do_popcount(0, acc), do: acc
  defp do_popcount(n, acc), do: do_popcount(Bitwise.band(n, n - 1), acc + 1)

  test "prefab place intent rejects unknown blueprint with v1 reason" do
    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(701, 14, 555, 9_999,
        blueprint_id: 4_242,
        blueprint_version: 2,
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
        blueprint_version: 2,
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

  test "prefab place intent rejects when any chunk fails to route" do
    ensure_map_ledger_started()
    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    logical_scene_id = 987_650

    # No region is registered for this logical scene. The World node is
    # reachable, so this verifies route failure classification rather than
    # world availability.
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(703, 16, logical_scene_id, 9_999,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {0, 0, 0},
        rotation: 0
      )
    )

    assert_voxel_intent_result(
      request_id: 703,
      client_intent_seq: 16,
      logical_scene_id: logical_scene_id,
      reason: ":no_route_for_chunk"
    )
  end

  test "prefab place intent outside scene rejects with invalid_state" do
    {:ok, pid} = WsConnection.start_link(self())

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(704, 17, 555, 9_999,
        blueprint_id: 1,
        blueprint_version: 2,
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

  describe "Phase 1c-6 — VoxelEditIntent (0x70) hardening" do
    test "voxel_edit_intent rejects unknown action codes" do
      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9801,
          client_intent_seq: 1,
          logical_scene_id: 700,
          action: 99,
          target_granularity: 0
        )
      )

      assert_voxel_intent_result(
        request_id: 9801,
        client_intent_seq: 1,
        logical_scene_id: 700,
        reason: ":invalid_voxel_edit_intent"
      )
    end

    test "voxel_edit_intent rejects unknown granularity codes" do
      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9802,
          client_intent_seq: 2,
          logical_scene_id: 701,
          action: 0,
          target_granularity: 99
        )
      )

      assert_voxel_intent_result(
        request_id: 9802,
        client_intent_seq: 2,
        logical_scene_id: 701,
        reason: ":invalid_voxel_edit_intent"
      )
    end

    test "voxel_edit_intent (Place + Micro) rejects object_ref outside u63 range" do
      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9803,
          client_intent_seq: 3,
          logical_scene_id: 702,
          action: 0,
          target_granularity: 1,
          object_ref: 0x8000_0000_0000_0000
        )
      )

      assert_voxel_intent_result(
        request_id: 9803,
        client_intent_seq: 3,
        logical_scene_id: 702,
        reason: ":invalid_object_ref"
      )
    end

    test "voxel_edit_intent (Break) ignores face_normal — target stays at the clicked cell" do
      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 703

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      # Seed a solid macro at chunk-local {0, 0, 0} (world_micro {0..7, 0..7, 0..7}).
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9810,
          client_intent_seq: 10,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 0,
          target_world_micro: {0, 0, 0},
          material_id: 1
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9810,
        client_intent_seq: 10,
        logical_scene_id: logical_scene_id,
        result_ref: 1
      )

      # Break with face_normal=(1,0,0); decision 6 says Break ignores
      # face_normal, so the clicked macro {0, 0, 0} is the cell that gets
      # cleared (NOT the +1 neighbour at {1, 0, 0}).
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9811,
          client_intent_seq: 11,
          logical_scene_id: logical_scene_id,
          action: 1,
          target_granularity: 0,
          target_world_micro: {0, 0, 0},
          face_normal: {1, 0, 0}
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9811,
        client_intent_seq: 11,
        logical_scene_id: logical_scene_id,
        result_ref: 2
      )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(logical_scene_id, {0, 0, 0})

      assert {:ok, %{storage: storage}} =
               SceneVoxelCodec.decode_chunk_snapshot_payload(snapshot.data)

      # The clicked macro {0, 0, 0} is empty (the Break landed there);
      # the offset-by-face_normal macro {1, 0, 0} is still empty (never
      # touched).
      assert Storage.macro_header_at(storage, {0, 0, 0}).mode ==
               MacroCellHeader.cell_mode_empty()

      assert Storage.macro_header_at(storage, {1, 0, 0}).mode ==
               MacroCellHeader.cell_mode_empty()
    end

    test "voxel_edit_intent (Place + Micro) on solid macro rejects with :cannot_micro_edit_solid_macro" do
      ensure_map_ledger_started()
      ensure_scene_voxel_started()

      logical_scene_id = 704

      put_voxel_region(logical_scene_id,
        region_id: System.unique_integer([:positive, :monotonic])
      )

      start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

      {:ok, pid} = WsConnection.start_link(self())
      put_connection_in_scene(pid)

      # Seed solid macro at world_macro {2, 2, 2} → world_micro {16, 16, 16}.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9820,
          client_intent_seq: 20,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 0,
          target_world_micro: {16, 16, 16},
          material_id: 1
        )
      )

      assert_voxel_intent_accepted(
        request_id: 9820,
        client_intent_seq: 20,
        logical_scene_id: logical_scene_id,
        result_ref: 1
      )

      # Now try to Place a Micro slot inside that solid macro — decision 2
      # rejects this without coercing the macro into refined mode.
      WsConnection.receive_frame(
        pid,
        voxel_edit_intent_frame(
          request_id: 9821,
          client_intent_seq: 21,
          logical_scene_id: logical_scene_id,
          action: 0,
          target_granularity: 1,
          target_world_micro: {16, 16, 16},
          face_normal: {0, 0, 0},
          material_id: 7
        )
      )

      assert_voxel_intent_result(
        request_id: 9821,
        client_intent_seq: 21,
        logical_scene_id: logical_scene_id,
        reason: ":cannot_micro_edit_solid_macro"
      )
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

  defp chunk_ack_frame(request_id, logical_scene_id, acks) do
    IO.iodata_to_binary([
      <<0x76, request_id::64-big, logical_scene_id::64-big, length(acks)::16-big>>,
      Enum.map(acks, fn {{cx, cy, cz}, chunk_version} ->
        <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, chunk_version::64-big>>
      end)
    ])
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

  defp snapshot_payload(logical_scene_id, chunk_coord, chunk_version) do
    storage = Storage.empty(logical_scene_id, chunk_coord, chunk_version: chunk_version)
    SceneVoxelCodec.encode_chunk_snapshot_payload(%{request_id: 101, storage: storage})
  end

  defp object_state_delta_payload(logical_scene_id, opts) do
    SceneVoxelCodec.encode_voxel_object_state_delta_payload(%{
      logical_scene_id: logical_scene_id,
      object_id: Keyword.fetch!(opts, :object_id),
      object_version: Keyword.fetch!(opts, :object_version),
      state_flags: Keyword.get(opts, :state_flags, 0x01),
      affected_chunks: Keyword.fetch!(opts, :affected_chunks)
    })
  end

  defp field_region_snapshot_payload(logical_scene_id, {cx, cy, cz}, region_id, tick_count) do
    <<0x73, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed, cz::32-big-signed,
      region_id::64-big, tick_count::32-big, 0::8, 0::16-big>>
  end

  defp field_region_envelope(logical_scene_id, payload, opts \\ []) do
    %{
      frame_kind: :field_region_snapshot,
      logical_scene_id: logical_scene_id,
      chunk_coord: {0, 0, 0},
      region_id: 44,
      tick_count: 3,
      tier: :halo,
      stream_class: :field_state,
      byte_size: byte_size(payload),
      server_version: 12,
      lease_id: Keyword.get(opts, :lease_id, 101),
      owner_epoch: Keyword.get(opts, :owner_epoch, 2),
      payload: payload
    }
  end

  defp invalidate_envelope(logical_scene_id, payload) do
    %{
      frame_kind: :invalidate,
      logical_scene_id: logical_scene_id,
      chunk_coord: {0, 0, 0},
      tier: :near,
      stream_class: :reliable_control,
      byte_size: byte_size(payload),
      server_version: 8,
      lease_id: 101,
      owner_epoch: 2,
      reason: 0x01,
      reason_name: :lease_revoked,
      payload: payload
    }
  end

  defp put_voxel_test_subscription(state, logical_scene_id, chunk_coord, opts) do
    Map.update!(state, :voxel_subscriptions, fn subscriptions ->
      Map.put(subscriptions, {logical_scene_id, chunk_coord}, %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        region_id: Keyword.get(opts, :region_id, 44),
        lease_id: Keyword.fetch!(opts, :lease_id),
        owner_epoch: Keyword.fetch!(opts, :owner_epoch),
        tier: Keyword.get(opts, :tier, :halo),
        scene_node: node()
      })
    end)
  end

  defp record_test_client_ack(logical_scene_id, chunk_coord, version) do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(logical_scene_id, chunk_coord, version)

    {:ok, ledger, _event} =
      ClientAckLedger.record_ack(
        ClientAckLedger.new(),
        forwarded,
        logical_scene_id,
        chunk_coord,
        version
      )

    ledger
  end

  defp field_region_destroyed_payload(logical_scene_id, {cx, cy, cz}, region_id) do
    <<0x74, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed, cz::32-big-signed,
      region_id::64-big, 0::8>>
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
         opts
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
         opts
       ) do
    blueprint_id = Keyword.get(opts, :blueprint_id, 1)
    blueprint_version = Keyword.get(opts, :blueprint_version, 2)
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
    timeout = Keyword.get(opts, :timeout, 1_000)

    assert_receive {:gate_ws_send, iodata}, timeout

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
    timeout = Keyword.get(opts, :timeout, 1_000)

    assert_receive {:gate_ws_send, iodata}, timeout

    assert <<0x68, got_request_id::64-big, got_client_intent_seq::32-big,
             got_logical_scene_id::64-big, 0::8, got_result_ref::64-big, 0::16-big, 2::16-big,
             "ok">> = IO.iodata_to_binary(iodata)

    assert got_request_id == request_id
    assert got_client_intent_seq == client_intent_seq
    assert got_logical_scene_id == logical_scene_id
    assert got_result_ref == result_ref
  end

  defp ensure_map_ledger_started(opts \\ []) do
    ensure_data_voxel_started()

    case Process.whereis(MapLedger) do
      nil ->
        start_supervised!(
          {MapLedger, [name: MapLedger, write_token_store: DataService.Voxel.WriteTokenStore]}
        )

      _pid ->
        :ok
    end

    configure_map_ledger_scene_invalidator(Keyword.get(opts, :scene_invalidator))
  end

  defp configure_map_ledger_scene_invalidator(invalidator)
       when is_nil(invalidator) or is_function(invalidator, 1) do
    case Process.whereis(MapLedger) do
      nil ->
        :ok

      pid ->
        :sys.replace_state(pid, fn state -> %{state | scene_invalidator: invalidator} end)
        :ok
    end
  end

  defp ensure_scene_voxel_started do
    ensure_data_voxel_started()

    if is_nil(Process.whereis(SceneServer.CliObserve.Manager)) do
      start_supervised!({SceneServer.CliObserve.Manager, []})
    end

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
               owner_epoch: 0,
               assigned_scene_node: Keyword.get(opts, :assigned_scene_node, node())
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, owner_scene_instance_ref,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )
  end

  defp put_partition_region(logical_scene_id, region_id, bounds_min, bounds_max, owner_ref) do
    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: bounds_min,
               bounds_chunk_max: bounds_max,
               owner_scene_instance_ref: owner_ref,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, owner_ref,
               lease_id: unique_id(),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: unique_id()
             )
  end

  defp ensure_chat_directory_started do
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

  defp ack(overrides) do
    attrs =
      Map.merge(
        %{
          cid: 42,
          ack_seq: 1,
          auth_tick: 1,
          position: {0.0, 0.0, 0.0},
          velocity: {0.0, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0},
          movement_mode: :grounded,
          correction_flags: 0,
          fixed_dt_ms: 50,
          ground_z: 0.0
        },
        overrides
      )

    struct!(Ack, attrs)
  end

  defp blocking_partition_refresh_fun(parent) do
    fn _state, ack, opts ->
      connection_pid = Keyword.fetch!(opts, :connection_pid)
      subscriber = Keyword.fetch!(opts, :subscriber)
      send(parent, {:partition_refresh_started, self(), connection_pid, subscriber})

      receive do
        :release_partition_refresh ->
          outcome = %{
            status: :updated,
            cid: ack.cid,
            logical_scene_id: 700,
            boundary_kind: :region,
            previous_region_id: 10,
            region_id: 20,
            previous_chunk_coord: {0, 0, 0},
            chunk_coord: {1, 0, 0},
            auth_tick: ack.auth_tick,
            ack_seq: ack.ack_seq,
            subscription_apply_status: :ok
          }

          {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok}}
      end
    end
  end

  defp fake_scene_ref(parent) do
    spawn(fn -> fake_scene_loop(parent) end)
  end

  defp blocking_movement_scene_ref(parent) do
    spawn(fn -> blocking_movement_scene_loop(parent) end)
  end

  defp blocking_movement_scene_loop(parent) do
    receive do
      {:"$gen_call", from, {:movement_input, frame}} ->
        send(parent, {:scene_movement_call_started, frame.seq})

        receive do
          :release_movement_call -> GenServer.reply(from, {:ok, :accepted})
        end

        blocking_movement_scene_loop(parent)

      {:"$gen_cast", {:movement_input, frame}} ->
        send(parent, {:scene_movement_cast_received, frame.seq})
        blocking_movement_scene_loop(parent)

      :release_movement_call ->
        blocking_movement_scene_loop(parent)
    end
  end

  defp fake_scene_loop(parent) do
    receive do
      {:"$gen_cast", message} ->
        send(parent, {:scene_cast, message})
        fake_scene_loop(parent)

      :stop ->
        :ok
    end
  end

  defp movement_input_frame(seq) do
    <<0x01, 1, seq::32-big, seq::32-big, 50::16-big, 0.0::float-32-big, 0.0::float-32-big,
      0.0::float-32-big, 0::16-big>>
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp wait_until(fun, attempts \\ 30)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp ensure_data_voxel_started do
    if is_nil(Process.whereis(DataService.Voxel.WriteTokenStore)) do
      start_supervised!(
        {DataService.Voxel.WriteTokenStore, name: DataService.Voxel.WriteTokenStore}
      )
    end

    # Phase 1d: ChunkSnapshotStore is a stateless module backed by
    # `DataService.Repo`; the test_helper boots the Repo, so there is
    # nothing else to start here. The shared `voxel_chunks` table is
    # cleared per-test via `setup do Repo.delete_all(...) end`.

    :ok
  end

  defp flush_observe_writer do
    GateServer.CliObserve.flush()
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

  defp ensure_repo_started do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
