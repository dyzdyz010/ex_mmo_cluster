defmodule SceneServer.Voxel.ChunkProcessRegistryTest do
  @moduledoc """
  阶段3.1 故障注入验收测试：ChunkProcess 进程身份注册化 + 重启 hydrate。

  覆盖 S1 修复的三个验收核心：

  1. kill 一个 ChunkProcess 后 —— 注册表无重复 / 幽灵进程，重启后从持久化
     hydrate（storage 非空），原订阅被重路由到正确的新进程；
  2. kill ChunkDirectory（facade）后 —— 重启不产生第二个权威进程（注册表
     保证单主）；
  3. hydrate 失败 → 进 degraded 态而非用空 storage 静默服务。

  每个测试用**隔离的** (Registry + VoxelChunkSup + ChunkDirectory) 三件套，
  与全局单例互不串扰；用真实 `Registry.lookup` / `Registry.count` 断言单实例。
  """
  # ChunkSnapshotStore 写 PostgreSQL，共享 voxel_chunks 表 → 同步执行 + 清理。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.ChunkRegistry
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.VoxelChunkSup

  @chunk_coord {2, 3, 4}

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)
    :ok
  end

  describe "① kill ChunkProcess: 单实例 + 重启 hydrate + 订阅重路由" do
    test "重启后从持久化 hydrate(storage 非空), 注册表无幽灵进程" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      # 写一笔可见 voxel 进权威进程, 它会持久化进 ChunkSnapshotStore。
      assert {:ok, %{chunk_version: 1, persist_result: :inserted}} =
               ChunkDirectory.apply_intent(ctx.directory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: lease,
                 operation: :put_solid_block,
                 macro: {1, 0, 0},
                 block: NormalBlockData.new(11, health: 40)
               })

      assert {:ok, first_pid} =
               ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry)

      assert :ok = ChunkProcess.flush_persistence(first_pid)
      assert {:ok, persisted} = ChunkSnapshotStore.get_snapshot(scene_id, @chunk_coord)
      assert persisted.chunk_version == 1

      # 故障注入: 直接 kill 权威进程。
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}

      # 注册表去重核心: 让监督树重启并重新注册, 再断言 *恰好一个* 实例。
      second_pid = await_registered(scene_id, @chunk_coord, ctx.registry, first_pid)

      refute second_pid == first_pid
      assert single_instance!(scene_id, @chunk_coord, ctx.registry) == second_pid

      # 重启 hydrate 不变式: 新进程从持久化恢复, storage 非空 + version 保留。
      new_state = ChunkProcess.debug_state(second_pid)
      assert new_state.chunk_version == 1
      assert new_state.hydrate_status == :loaded

      assert Storage.macro_header_at(new_state.storage, {1, 0, 0}).mode ==
               MacroCellHeader.cell_mode_solid_block()
    end

    test "原订阅经 facade 重路由到重启后的新权威进程" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      # 先建 chunk + 订阅 self()。
      assert {:ok, _payload} =
               ChunkDirectory.subscribe(ctx.directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: lease,
                 subscriber: self()
               })

      assert_receive {:voxel_chunk_snapshot_payload, _}

      assert {:ok, first_pid} =
               ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry)

      # kill → 等重启 → 新 pid。
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}

      second_pid = await_registered(scene_id, @chunk_coord, ctx.registry, first_pid)
      assert single_instance!(scene_id, @chunk_coord, ctx.registry) == second_pid

      # facade 经注册表把新订阅路由到 *新* 权威进程。
      assert {:ok, _payload} =
               ChunkDirectory.subscribe(ctx.directory, %{
                 request_id: 2,
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: lease,
                 subscriber: self()
               })

      assert_receive {:voxel_chunk_snapshot_payload, _}
      assert ChunkProcess.debug_state(second_pid).subscriber_count == 1

      # lookup_chunk_pid 经注册表解析到的就是新 pid(无幽灵 / 死 pid)。
      assert {:ok, ^second_pid} =
               ChunkDirectory.lookup_chunk_pid(ctx.directory, scene_id, @chunk_coord)
    end
  end

  describe "② kill ChunkDirectory(facade): 不产生第二个权威进程" do
    test "facade 重启后注册表仍是单主, 复用既有权威进程" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(ctx.directory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: lease
               })

      assert single_instance!(scene_id, @chunk_coord, ctx.registry) == chunk_pid

      # 故障注入: kill facade。权威进程独立挂在 VoxelChunkSup 下, 不随 facade 死。
      facade_ref = Process.monitor(ctx.directory)
      Process.exit(ctx.directory, :kill)
      assert_receive {:DOWN, ^facade_ref, :process, _, _}

      # 权威进程仍然活着, 注册表条目未变。
      assert Process.alive?(chunk_pid)
      assert single_instance!(scene_id, @chunk_coord, ctx.registry) == chunk_pid

      # 重启一个 facade(同注册表 + 同 sup), 再 ensure 同 coord —— 复用既有
      # 权威进程, 绝不起第二个(注册表保证单主)。
      directory2 =
        start_supervised!(
          {ChunkDirectory, chunk_sup: ctx.chunk_sup, chunk_registry: ctx.registry},
          id: :facade2
        )

      assert {:ok, ^chunk_pid} =
               ChunkDirectory.ensure_chunk(directory2, %{
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: lease
               })

      assert single_instance!(scene_id, @chunk_coord, ctx.registry) == chunk_pid
    end

    test "并发 start_child 竞态由 already_started 去重(无双权威)" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()

      chunk_opts = [
        logical_scene_id: scene_id,
        chunk_coord: @chunk_coord,
        chunk_registry: ctx.registry
      ]

      # 同 key 启两次: 第二次必然撞 via-tuple 去重。
      assert {:ok, pid1} = VoxelChunkSup.start_chunk(ctx.chunk_sup, chunk_opts)

      assert {:error, {:already_started, ^pid1}} =
               VoxelChunkSup.start_chunk(ctx.chunk_sup, chunk_opts)

      assert single_instance!(scene_id, @chunk_coord, ctx.registry) == pid1
    end
  end

  describe "③ hydrate 失败 → degraded 而非空 storage 静默服务" do
    test "持久化行损坏时 init 进 degraded, 不用空 storage 服务" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      # 直接写一行 *损坏 payload* 的持久化快照(data 不是合法 snapshot 编码),
      # 模拟磁盘/编码损坏。绕过 ChunkSnapshotStore 校验直接插 Repo 行。
      plant_corrupt_snapshot!(scene_id, @chunk_coord, lease)

      # 携带有效 lease 启动 → init 无条件 hydrate → 解码失败 → degraded。
      chunk =
        start_supervised!(
          {ChunkProcess,
           [
             logical_scene_id: scene_id,
             chunk_coord: @chunk_coord,
             lease: lease,
             chunk_registry: ctx.registry
           ]}
        )

      state = ChunkProcess.debug_state(chunk)

      # 关键: 不是 :loaded 也不是 :authorized 空跑, 而是 degraded。
      assert state.mode == :degraded
      assert {:degraded, _reason} = state.hydrate_status
      # storage 是空占位, 但 degraded 态禁止模拟/授权写, 不会把空当真相服务。
      assert state.chunk_version == 0
    end

    test ":snapshot_not_found 是合法全新 chunk(never_persisted, 非 degraded)" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      chunk =
        start_supervised!(
          {ChunkProcess,
           [
             logical_scene_id: scene_id,
             chunk_coord: @chunk_coord,
             lease: lease,
             chunk_registry: ctx.registry
           ]}
        )

      state = ChunkProcess.debug_state(chunk)
      assert state.mode == :authorized
      assert state.hydrate_status == :never_persisted
      assert state.chunk_version == 0
    end

    test "无 lease 启动进 unauthorized, 不读权威存储 / 不模拟" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()

      chunk =
        start_supervised!(
          {ChunkProcess,
           [
             logical_scene_id: scene_id,
             chunk_coord: @chunk_coord,
             chunk_registry: ctx.registry
           ]}
        )

      state = ChunkProcess.debug_state(chunk)
      assert state.mode == :unauthorized
      refute state.has_lease?

      # World 下发 lease 后转入授权态(并 hydrate, 此处无持久化 → never_persisted)。
      lease = lease(scene_id)
      seed_token!(lease)
      assert {:ok, _} = ChunkProcess.apply_lease(chunk, lease)

      authorized = ChunkProcess.debug_state(chunk)
      assert authorized.mode == :authorized
      assert authorized.hydrate_status == :never_persisted
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp start_isolated_runtime do
    registry_name = :"chunk_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, keys: :unique, name: registry_name},
      id: {:registry, registry_name}
    )

    chunk_sup = start_supervised!(VoxelChunkSup, id: {:chunk_sup, registry_name})

    directory =
      start_supervised!(
        {ChunkDirectory, chunk_sup: chunk_sup, chunk_registry: registry_name},
        id: {:directory, registry_name}
      )

    %{registry: registry_name, chunk_sup: chunk_sup, directory: directory}
  end

  # 等待监督树重启并把新进程注册进表(新 pid != old_pid)。
  defp await_registered(scene_id, chunk_coord, registry, old_pid, attempts \\ 100) do
    case ChunkRegistry.lookup(scene_id, chunk_coord, registry) do
      {:ok, pid} when pid != old_pid ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        await_registered(scene_id, chunk_coord, registry, old_pid, attempts - 1)

      _ ->
        flunk("chunk #{inspect(chunk_coord)} 未在重启后重新注册")
    end
  end

  # 用 Registry 真值断言"恰好一个实例", 返回该唯一 pid。
  defp single_instance!(scene_id, chunk_coord, registry) do
    key = ChunkRegistry.key(scene_id, chunk_coord)

    case Registry.lookup(registry, key) do
      [{pid, _}] ->
        pid

      other ->
        flunk("expected exactly one chunk instance for #{inspect(key)}, got: #{inspect(other)}")
    end
  end

  defp plant_corrupt_snapshot!(scene_id, {x, y, z}, lease) do
    {:ok, _row} =
      Repo.insert(
        VoxelChunkSnapshot.changeset(%VoxelChunkSnapshot{}, %{
          logical_scene_id: scene_id,
          coord_x: x,
          coord_y: y,
          coord_z: z,
          schema_version: 1,
          chunk_size_in_macro: 16,
          micro_resolution: 8,
          region_id: lease.region_id,
          lease_id: lease.lease_id,
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          owner_epoch: lease.owner_epoch,
          chunk_version: 5,
          # 8 字节合法 hash 字段, 但 data 是垃圾 → decode_chunk_snapshot_payload 失败。
          chunk_hash: <<0, 1, 2, 3, 4, 5, 6, 7>>,
          data: <<"not-a-valid-chunk-snapshot-payload">>
        })
      )

    :ok
  end

  defp seed_token!(lease) do
    {:ok, _} =
      WriteTokenStore.upsert_token(
        WriteTokenStore,
        Map.put(lease, :token_version, lease.owner_epoch)
      )

    :ok
  end

  defp unique_scene_id do
    System.unique_integer([:positive, :monotonic]) + 20_000_000
  end

  defp lease(scene_id, overrides \\ []) do
    base = %{
      logical_scene_id: scene_id,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {8, 8, 8},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    Map.merge(base, Map.new(overrides))
  end
end
