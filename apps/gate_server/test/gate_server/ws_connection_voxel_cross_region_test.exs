defmodule GateServer.WsConnectionVoxelCrossRegionTest do
  # Phase A4-5:跨 region prefab placement / damage cascade e2e。
  #
  # 单 BEAM 内启动两个 named ChunkDirectory(`ChunkDirectory.RegionA` /
  # `ChunkDirectory.RegionB`),通过 gate `:voxel_chunk_directory_resolver`
  # env fn 把 participant 路由到对应 named instance,模拟"两个 region 在两个
  # scene_node 上"的部署。ObjectRegistry / ObjectOwnerLookup 仍用 default
  # name 单 instance(对齐 D10.B);0x6C 跨 region fan-out 通过 ObjectRegistry
  # 的 `:region_routing_fn` opt 注入分桶。
  #
  # MapLedger 持有两个不重叠 region(region_a bounds = chunk(0,0,0)、
  # region_b bounds = chunk(1,0,0)),sphere prefab 锚点选在 chunk x 边界
  # 附近,让 prefab 自然跨两 chunks。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.SceneObjectStore
  alias DataService.Voxel.WriteTokenStore
  alias GateServer.WsConnection
  alias SceneServer.Combat.VoxelDamageRouter
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.ObjectOwnerLookup
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PrefabRaster
  alias SceneServer.Voxel.Types
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
    def handle_call(:auth_server, _from, state), do: {:reply, state.auth_server, state}
    def handle_call(:scene_server, _from, state), do: {:reply, state.scene_server, state}
    def handle_call(:world_server, _from, state), do: {:reply, state.world_server, state}
  end

  setup do
    ensure_repo_started()
    Repo.delete_all(VoxelChunkSnapshot)
    DataService.Voxel.SceneObjectStore.reset()
    stop_named(GateServer.Interface)

    ensure_started!(WriteTokenStore, {WriteTokenStore, name: WriteTokenStore})

    if Process.whereis(WriteTokenStore) do
      WriteTokenStore.reset(WriteTokenStore)
    end

    chunk_sup_a = SceneServer.VoxelChunkSup.RegionA
    chunk_sup_b = SceneServer.VoxelChunkSup.RegionB
    chunk_dir_a = ChunkDirectory.RegionA
    chunk_dir_b = ChunkDirectory.RegionB

    start_supervised!({SceneServer.VoxelChunkSup, name: chunk_sup_a}, id: chunk_sup_a)
    start_supervised!({SceneServer.VoxelChunkSup, name: chunk_sup_b}, id: chunk_sup_b)

    start_supervised!(
      {ChunkDirectory, name: chunk_dir_a, chunk_sup: chunk_sup_a},
      id: chunk_dir_a
    )

    start_supervised!(
      {ChunkDirectory, name: chunk_dir_b, chunk_sup: chunk_sup_b},
      id: chunk_dir_b
    )

    ensure_started!(MapLedger, {MapLedger, name: MapLedger, write_token_store: WriteTokenStore})

    ensure_started!(
      WorldServer.Voxel.TransactionCoordinator,
      {WorldServer.Voxel.TransactionCoordinator, name: WorldServer.Voxel.TransactionCoordinator}
    )

    logical_scene_id = System.unique_integer([:positive, :monotonic])

    region_a_id = System.unique_integer([:positive, :monotonic])
    region_b_id = System.unique_integer([:positive, :monotonic])
    owner_ref_a = 8_001
    owner_ref_b = 8_002

    # bounds_chunk_max 是 **exclusive** 上界(`RegionAssignment.contains?` 用
    # `cx < max_x`)。region_a 覆盖 chunk x=0 那一侧:bounds_min={0,0,0},
    # bounds_max={1,1,1}(只含 chunk (0,0,0));region_b 覆盖 chunk x=1 一侧:
    # bounds_min={1,0,0}, bounds_max={2,1,1}(只含 chunk (1,0,0))。两 region
    # bounds 不重叠(x range 分别是 [0,1) 和 [1,2)),`validate_region_bounds_available`
    # 不会 reject。sphere prefab 跨 chunk x=0/x=1 边界时同时落两 region。
    {:ok, _} =
      MapLedger.put_region(MapLedger, %{
        region_id: region_a_id,
        logical_scene_id: logical_scene_id,
        bounds_chunk_min: {0, 0, 0},
        bounds_chunk_max: {1, 1, 1},
        owner_scene_instance_ref: owner_ref_a,
        owner_epoch: 0,
        assigned_scene_node: node()
      })

    {:ok, lease_a} =
      MapLedger.issue_lease(MapLedger, region_a_id, owner_ref_a,
        lease_id: System.unique_integer([:positive, :monotonic]),
        owner_epoch: 1,
        expires_at_ms: System.system_time(:millisecond) + 60_000,
        token_version: System.unique_integer([:positive, :monotonic])
      )

    {:ok, _} =
      MapLedger.put_region(MapLedger, %{
        region_id: region_b_id,
        logical_scene_id: logical_scene_id,
        bounds_chunk_min: {1, 0, 0},
        bounds_chunk_max: {2, 1, 1},
        owner_scene_instance_ref: owner_ref_b,
        owner_epoch: 0,
        assigned_scene_node: node()
      })

    {:ok, lease_b} =
      MapLedger.issue_lease(MapLedger, region_b_id, owner_ref_b,
        lease_id: System.unique_integer([:positive, :monotonic]),
        owner_epoch: 1,
        expires_at_ms: System.system_time(:millisecond) + 60_000,
        token_version: System.unique_integer([:positive, :monotonic])
      )

    region_routing_fn = fn
      {rid, _lease_id} when rid == region_a_id -> chunk_dir_a
      {rid, _lease_id} when rid == region_b_id -> chunk_dir_b
      _ -> chunk_dir_a
    end

    # ObjectOwnerLookup + ObjectRegistry default name(BuildTransactionApplier
    # 用 default 寻址,所以 fixture 必须用 default name 启动)。
    ensure_started!(ObjectOwnerLookup, {ObjectOwnerLookup, name: ObjectOwnerLookup})

    ensure_started!(
      ObjectRegistry,
      {ObjectRegistry,
       name: ObjectRegistry, chunk_directory: chunk_dir_a, region_routing_fn: region_routing_fn}
    )

    Application.put_env(:gate_server, :voxel_chunk_directory_resolver, region_routing_fn)

    on_exit(fn ->
      Application.delete_env(:gate_server, :voxel_chunk_directory_resolver)
      stop_named(GateServer.Interface)
    end)

    start_supervised!({FakeInterface, world_server: node(), scene_server: node()})

    %{
      logical_scene_id: logical_scene_id,
      region_a_id: region_a_id,
      region_b_id: region_b_id,
      lease_a: lease_a,
      lease_b: lease_b,
      chunk_dir_a: chunk_dir_a,
      chunk_dir_b: chunk_dir_b
    }
  end

  test "跨 region prefab placement: 两 region 各 commit 自己的 chunk + 双 storage 都被写", ctx do
    # 找一个让 sphere 跨 chunk x=0/x=1 边界的 anchor。chunk_size_in_macro=16,
    # micro_resolution=8 → chunk x 边界在 world_micro x = 128。anchor 选 x=124
    # (距边界 4 micros),sphere 半径会让 occupancy 至少触及 macro x=16(chunk 1)。
    # 验证一下 PrefabRaster 出来的 cells 真的跨 chunks,否则调 anchor。
    anchor = find_cross_chunk_anchor!()

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(701, 1, ctx.logical_scene_id, 9_001,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: anchor,
        rotation: 0
      )
    )

    assert_voxel_intent_accepted(
      request_id: 701,
      client_intent_seq: 1,
      logical_scene_id: ctx.logical_scene_id,
      timeout: 10_000
    )

    # 两 chunk 的 hot delta 已经 fan-out;冷路径 snapshot persist 在后台,这里
    # 通过 ChunkProcess flush 明确等待后再查 PG。
    flush_chunk_persistence!(ctx.chunk_dir_a, ctx.logical_scene_id, {0, 0, 0})
    flush_chunk_persistence!(ctx.chunk_dir_b, ctx.logical_scene_id, {1, 0, 0})

    # 两 chunk 的 storage 都被持久化(走的是各自 ChunkDirectory.Region* 路径)。
    assert {:ok, snap_a} = ChunkSnapshotStore.get_snapshot(ctx.logical_scene_id, {0, 0, 0})
    assert {:ok, snap_b} = ChunkSnapshotStore.get_snapshot(ctx.logical_scene_id, {1, 0, 0})

    {:ok, %{storage: storage_a}} = SceneVoxelCodec.decode_chunk_snapshot_payload(snap_a.data)
    {:ok, %{storage: storage_b}} = SceneVoxelCodec.decode_chunk_snapshot_payload(snap_b.data)

    assert non_empty_macro?(storage_a),
           "chunk (0,0,0) 应该有 sphere 占用的 macro,storage 看起来是空"

    assert non_empty_macro?(storage_b),
           "chunk (1,0,0) 应该有 sphere 占用的 macro(prefab 跨 chunk x 边界),storage 看起来是空"

    assert [object] =
             ObjectRegistry.list_objects_in_chunk(ObjectRegistry, ctx.logical_scene_id, {0, 0, 0})

    assert object.object_id > 0
    assert object.covered_chunks == [{0, 0, 0}, {1, 0, 0}]
    assert Enum.any?(object.part_states, &(&1.part_id == 1))
    assert {:ok, persisted} = SceneObjectStore.get_object(object.object_id)
    assert persisted.covered_chunks == object.covered_chunks

    # ChunkDirectory.RegionA 应该只持有 chunk (0,0,0) 的 chunk_pid,RegionB
    # 只持有 (1,0,0)(per-region 路由生效);用 lookup_chunk_pid 反向验证。
    assert {:ok, _pid_a_local} =
             ChunkDirectory.lookup_chunk_pid(ctx.chunk_dir_a, ctx.logical_scene_id, {0, 0, 0})

    assert :not_started =
             ChunkDirectory.lookup_chunk_pid(ctx.chunk_dir_a, ctx.logical_scene_id, {1, 0, 0})

    assert {:ok, _pid_b_local} =
             ChunkDirectory.lookup_chunk_pid(ctx.chunk_dir_b, ctx.logical_scene_id, {1, 0, 0})

    assert :not_started =
             ChunkDirectory.lookup_chunk_pid(ctx.chunk_dir_b, ctx.logical_scene_id, {0, 0, 0})
  end

  test "跨 region damage cascade: 攻击 region B 的 chunk → 通过 prefab owner 路由到 scene_object",
       ctx do
    # Prefab placement 必须分配真实 scene_object，并把同一 prefab 的所有
    # micro slots 写上同一个 owner pair。这里从 region B 的 chunk 读持久化
    # snapshot 反查 owner，再通过 ObjectOwnerLookup 路由到 owning registry。
    anchor = find_cross_chunk_anchor!()

    {:ok, pid} = WsConnection.start_link(self())
    put_connection_in_scene(pid)

    WsConnection.receive_frame(
      pid,
      prefab_place_intent_frame(801, 1, ctx.logical_scene_id, 9_001,
        blueprint_id: 1,
        blueprint_version: 2,
        anchor: anchor,
        rotation: 0
      )
    )

    assert_voxel_intent_accepted(
      request_id: 801,
      client_intent_seq: 1,
      logical_scene_id: ctx.logical_scene_id,
      timeout: 10_000
    )

    # 攻击 region B 的 chunk(1,0,0)中 prefab 占用的某个 micro slot。chunk x
    # 边界 = world_micro 128;sphere 跨边界进入 chunk(1,0,0)的占用区在 macro
    # x=16(world_macro 16 = chunk 1 local macro 0)附近。
    flush_chunk_persistence!(ctx.chunk_dir_a, ctx.logical_scene_id, {0, 0, 0})
    flush_chunk_persistence!(ctx.chunk_dir_b, ctx.logical_scene_id, {1, 0, 0})

    assert [object] =
             ObjectRegistry.list_objects_in_chunk(ObjectRegistry, ctx.logical_scene_id, {1, 0, 0})

    target_world_micro = damage_target_in_region_b(anchor)

    # 直接调 VoxelDamageRouter,不走 wire 0x64 帧(0x64 路径在 ws_connection 中
    # 还没接 router,wire 测试覆盖在 voxel_damage_router_test;本测试覆盖跨节点
    # 路由的 damage 路径在 fixture 双 ChunkDirectory 下不 crash)。
    outcome = VoxelDamageRouter.try_apply_damage(ctx.logical_scene_id, target_world_micro, 25)

    assert {:applied, %{object_id: object.object_id, part_id: 1}} == outcome
  end

  ## Helpers

  defp find_cross_chunk_anchor! do
    candidates = [
      {124, 8, 8},
      {120, 8, 8},
      {126, 16, 24},
      {124, 16, 24},
      {120, 24, 32}
    ]

    Enum.find(candidates, fn anchor ->
      case PrefabRaster.rasterize(1, 2, anchor, 0) do
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

  defp damage_target_in_region_b(anchor) do
    {:ok, cells} = PrefabRaster.rasterize(1, 2, anchor, 0)

    cell =
      Enum.find(cells, &(&1.chunk_coord == {1, 0, 0})) ||
        flunk("expected prefab raster to occupy chunk {1,0,0}")

    {local_macro_x, local_macro_y, local_macro_z} = cell.local_macro
    {local_micro_x, local_micro_y, local_micro_z} = Types.micro_coord!(cell.micro_slot)
    chunk_size = Types.chunk_size_in_macro()
    micro = Types.micro_resolution()

    {
      (chunk_size + local_macro_x) * micro + local_micro_x,
      local_macro_y * micro + local_micro_y,
      local_macro_z * micro + local_micro_z
    }
  end

  defp non_empty_macro?(storage) do
    Enum.any?(storage.macro_headers, fn header ->
      header.mode == MacroCellHeader.cell_mode_refined()
    end)
  end

  defp flush_chunk_persistence!(chunk_directory, logical_scene_id, chunk_coord) do
    assert {:ok, chunk_pid} =
             ChunkDirectory.lookup_chunk_pid(chunk_directory, logical_scene_id, chunk_coord)

    assert :ok = ChunkProcess.flush_persistence(chunk_pid)
  end

  defp ensure_started!(name, child_spec) do
    if is_nil(Process.whereis(name)) do
      start_supervised!(child_spec, id: name)
    end

    :ok
  end

  defp put_connection_in_scene(pid) do
    :sys.replace_state(pid, fn state -> %{state | status: :in_scene, cid: 42} end)
    _ = :sys.get_state(pid)
    :ok
  end

  defp prefab_place_intent_frame(
         request_id,
         client_intent_seq,
         logical_scene_id,
         parcel_id,
         opts
       ) do
    blueprint_id = Keyword.fetch!(opts, :blueprint_id)
    blueprint_version = Keyword.fetch!(opts, :blueprint_version)
    {ax, ay, az} = Keyword.fetch!(opts, :anchor)
    rotation = Keyword.get(opts, :rotation, 0)
    known_parcel_build_epoch = Keyword.get(opts, :known_parcel_build_epoch, 0)
    placement_flags = Keyword.get(opts, :placement_flags, 0)

    <<0x67, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big,
      parcel_id::64-big, known_parcel_build_epoch::64-big, blueprint_id::64-big,
      blueprint_version::32-big, ax::64-big-signed, ay::64-big-signed, az::64-big-signed,
      rotation::8, 0::16-big, 0::16-big, 0::16-big, placement_flags::32-big>>
  end

  defp assert_voxel_intent_accepted(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    client_intent_seq = Keyword.fetch!(opts, :client_intent_seq)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    timeout = Keyword.get(opts, :timeout, 5_000)

    receive do
      {:gate_ws_send, iodata} ->
        bin = IO.iodata_to_binary(iodata)

        case bin do
          <<0x68, ^request_id::64-big, ^client_intent_seq::32-big, ^logical_scene_id::64-big,
            0::8, _result_ref::64-big, _padding::binary>> ->
            :ok

          <<0x68, ^request_id::64-big, ^client_intent_seq::32-big, ^logical_scene_id::64-big,
            result_code::8, _result_ref::64-big, _padding::binary>> = full ->
            flunk(
              "voxel intent result_code = #{result_code} (expected 0 = accepted)。" <>
                "full payload: #{inspect(full)}"
            )

          other ->
            assert_voxel_intent_accepted_drain(other, opts, timeout)
        end
    after
      timeout -> flunk("expected 0x68 voxel intent result within #{timeout}ms")
    end
  end

  defp assert_voxel_intent_accepted_drain(_skipped, opts, timeout) do
    # 0x6C / 0x62 等可能先到;继续等 0x68。
    assert_voxel_intent_accepted(Keyword.put(opts, :timeout, timeout))
  end

  defp ensure_repo_started do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end
  end
end
