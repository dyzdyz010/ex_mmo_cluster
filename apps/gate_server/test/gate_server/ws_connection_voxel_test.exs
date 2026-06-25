defmodule GateServer.WsConnectionVoxelTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.CommandLog
  alias DataService.Voxel.WriteTokenStore
  alias GateServer.WsConnection
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.ChunkProcess
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
         %{auth_server: nil, scene_server: nil, world_server: nil},
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

    # 梯队4:WriteTokenStore 模块级无状态(DB durable),无进程守卫,直接清表。
    WriteTokenStore.reset()

    # 梯队1 step1.5b-2:prefab 现走 CommandLog idempotency-key(claim/confirm),清共享
    # voxel_command_log 表,避免跨测试 command_id 命中 :duplicate 让 prefab 不实际执行。
    CommandLog.reset()

    # 阶段4-B(测试隔离):清 durable 的 region 目录 + epoch 表。MapLedger 每测试由
    # start_supervised 新建,boot 会**从目录重启自愈重载**——不清则前序测试的 region 行被本测试
    # 的 MapLedger 重载,陈旧 region 被 scan 命中、epoch 分配器(owner_epoch+1)跨测试漂移,
    # 造成 rebind epoch / prefab 占用 / edit 路由的顺序相关 flaky。清表使每测试 boot 自洁。
    DataService.Voxel.RegionDirectoryStore.reset()
    DataService.Voxel.RegionEpochStore.reset()

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

  test "chunk subscribe surfaces scene-node-unassigned when World cannot place the region" do
    # 阶段1:route miss 不再返回 :unassigned_chunk(世界无界,World 会在隐式 grid 上懒物化
    # region)。但物化需要一个已注册的 Scene 节点来承载热执行;这里 MapLedger 未配
    # scene_node_registry,所以物化无处可放,客户端得到明确的 :scene_node_unassigned,
    # 而非旧的"越界"拒绝。
    ensure_map_ledger_started()
    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(10, 98_765, {1234, 0, 0}))

    assert_voxel_intent_result(
      request_id: 10,
      logical_scene_id: 98_765,
      reason: ":scene_node_unassigned"
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

    subscriptions = voxel_subscriptions(pid)

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

  test "re-subscribing an already-subscribed chunk is a diff no-op (阶段4 step4.2)" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    put_voxel_region(781, region_id: System.unique_integer([:positive, :monotonic]))
    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    # 首订阅:worker 异步 route+subscribe,推首帧快照,落 voxel_subscriptions。
    WsConnection.receive_frame(pid, chunk_subscribe_frame(61, 781, {0, 0, 0}))
    assert_receive {:gate_ws_send, <<0x62, _first::binary>>}
    _ = :sys.get_state(pid)
    subscriptions = voxel_subscriptions(pid)
    assert map_size(subscriptions) == 1

    # 再订阅同一 chunk:差集判定已订阅 → 不再投 worker / 不再打 ChunkDirectory → 不再推快照。
    WsConnection.receive_frame(pid, chunk_subscribe_frame(62, 781, {0, 0, 0}))
    refute_receive {:gate_ws_send, <<0x62, _second::binary>>}, 100

    subscriptions_after = voxel_subscriptions(pid)
    assert map_size(subscriptions_after) == 1
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

    subscriptions_before = voxel_subscriptions(pid)

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

    subscriptions_after = voxel_subscriptions(pid)

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

    subscriptions = voxel_subscriptions(pid)
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

  # 梯队1 step1.5b-2(AUTH-4):同 client_intent_seq 的 prefab 重试经 CommandLog
  # idempotency-key 去重——返回缓存摘要,不重新分配 object_id、不二次写 chunk。
  test "duplicate prefab place intent is idempotent (cached ack, no second write)" do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])
    # 唯一 scene_id:MapLedger 是全局持久单例,bounds overlap 检查 per-logical-scene,
    # 复用固定 scene 会与其它测试的同 bounds 区域冲突。
    scene_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7_101,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, 7_101,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(pid, chunk_subscribe_frame(610, scene_id, {0, 0, 0}))
    assert_receive {:gate_ws_send, initial_bin}
    assert <<0x62, _initial_payload::binary>> = initial_bin

    # 首次放置(client_intent_seq 21)→ applied,chunk 0 -> 1,一条 delta。
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(611, 21, scene_id, 8_888,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    assert_voxel_intent_accepted(
      request_id: 611,
      client_intent_seq: 21,
      logical_scene_id: scene_id,
      result_ref: 1,
      timeout: 1_000
    )

    assert_receive {:gate_ws_send, delta_bin}, 5_000
    assert <<0x63, delta_payload::binary>> = delta_bin
    assert {:ok, delta} = SceneVoxelCodec.decode_chunk_delta_payload(delta_payload)
    assert delta.new_chunk_version == 1

    # 重试:同 client_intent_seq 21、新 request_id 612。派生 command_id 撞键 →
    # CommandLog.claim 得 {:duplicate, 缓存摘要} → 直接返回缓存,不进 fast-path、
    # 不分配 object_id、不二次写 chunk。
    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(612, 21, scene_id, 8_888,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: {8, 16, 24},
        rotation: 0
      )
    )

    # 缓存 ack 回显重试的 request_id + 同 result_ref(缓存 max_chunk_version)。
    assert_voxel_intent_accepted(
      request_id: 612,
      client_intent_seq: 21,
      logical_scene_id: scene_id,
      result_ref: 1,
      timeout: 1_000
    )

    # 没有第二条 chunk delta —— 重试未触碰 chunk。
    refute_receive {:gate_ws_send, _}, 200

    # canonical chunk_version 仍是 1(无二次写)。
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {0, 0, 0})
    assert snapshot.chunk_version == 1
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
    File.mkdir_p!(log_root)
    scene_log = Path.join(log_root, "scene.log")
    gate_log = Path.join(log_root, "gate.log")
    world_log = Path.join(log_root, "world.log")

    Application.put_env(:scene_server, :cli_observe_log, scene_log)
    Application.put_env(:gate_server, :cli_observe_log, gate_log)
    Application.put_env(:world_server, :cli_observe_log, world_log)

    on_exit(fn ->
      Application.delete_env(:scene_server, :cli_observe_log)
      Application.delete_env(:gate_server, :cli_observe_log)
      Application.delete_env(:world_server, :cli_observe_log)
    end)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])
    logical_scene_id = 7_777

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
    SceneServer.CliObserve.flush()
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

    File.mkdir_p!(log_root)
    scene_log = Path.join(log_root, "scene.log")
    gate_log = Path.join(log_root, "gate.log")

    Application.put_env(:scene_server, :cli_observe_log, scene_log)
    Application.put_env(:gate_server, :cli_observe_log, gate_log)

    on_exit(fn ->
      Application.delete_env(:scene_server, :cli_observe_log)
      Application.delete_env(:gate_server, :cli_observe_log)
    end)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    region_id = System.unique_integer([:positive, :monotonic])
    logical_scene_id = 7_778

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
    SceneServer.CliObserve.flush()
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
    subscriptions = voxel_subscriptions(pid)
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

  # 阶段4:订阅集是 worker 的权威状态(连接只持 worker pid)。introspection 走 worker。
  defp voxel_subscriptions(pid) do
    GateServer.Voxel.SubscriptionWorker.subscriptions(:sys.get_state(pid).voxel_worker)
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

  defp ensure_data_voxel_started do
    # 梯队4:WriteTokenStore 与 ChunkSnapshotStore 均为无状态模块,真相在 `DataService.Repo`
    # (test_helper 已启 Repo);无进程可启。共享 `voxel_chunks` 表每测试 `Repo.delete_all` 清。
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

  defp ensure_repo_started do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
