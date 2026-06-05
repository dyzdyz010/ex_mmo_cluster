defmodule SceneServer.Voxel.ChunkHotPathDirectTest do
  @moduledoc """
  阶段5.2 (voxel-storage-1) 验收测试：目录串行咽喉 → Registry 直达 + chunk DB 异步。

  覆盖任务的四条验收：

  ① 落方块写不再 head-of-line block 碰撞查询（并发 apply + collision_query
     不串行）——把 chunk 进程整个挂起，碰撞读仍从 ETS 快照即时返回；
  ② chunk 间并行恢复——多个 coord 的 ensure/直达彼此独立，不经单一串行 mailbox；
  ③ collision_query 的 ETS 快照与权威 storage 一致——同一组 samples 经 ETS 直读
     路径与经 chunk 直达路径（`ChunkProcess.collision_query`）结果逐位相等；
  ④ DB 背压——高速写不无界堆 async persist Task（有界 write-behind pool 钳制）。

  需 PostgreSQL（ChunkSnapshotStore / WriteTokenStore 落 Repo）。
  """
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkOccupancyTable
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.ChunkRegistry
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.VoxelChunkSup

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)
    :ok
  end

  describe "① 读写分离：落方块写不 head-of-line block 碰撞读" do
    test "chunk 进程挂起（模拟写占住 mailbox）时碰撞读仍从 ETS 快照即时返回" do
      ctx = boot()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      # 先落一个方块，使 occupancy 快照里 {1,0,0} 占用。
      assert {:ok, %{chunk_version: 1}} =
               ChunkDirectory.apply_intent_direct(
                 intent(scene_id, lease, {1, 0, 0}),
                 direct_opts(ctx)
               )

      assert {:ok, pid} = ChunkRegistry.lookup(scene_id, {0, 0, 0}, ctx.registry)
      :ok = ChunkProcess.flush_persistence(pid)

      # 挂起 chunk 进程：任何 GenServer.call 都会阻塞到超时。
      :ok = :sys.suspend(pid)

      try do
        started = System.monotonic_time(:millisecond)

        # 读路径直读 ETS——不触达被挂起的 mailbox，立即返回正确占用。
        assert {:ok, %{occupied_count: 1, occupied: [%{macro: {1, 0, 0}, mode: :solid}]}} =
                 ChunkDirectory.collision_query(
                   ChunkDirectory,
                   %{
                     logical_scene_id: scene_id,
                     chunk_coord: {0, 0, 0},
                     samples: [%{macro: {1, 0, 0}, micro_slot: 0}]
                   }
                 )

        assert System.monotonic_time(:millisecond) - started < 200
      after
        _ = :sys.resume(pid)
      end
    end
  end

  describe "② chunk 间并行恢复（直达彼此独立，不经单一串行 mailbox）" do
    test "多个已 hot 的 coord 并发直达写，各打各自 chunk、彼此不串行" do
      ctx = boot()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      coords = for x <- 0..5, do: {x, 0, 0}

      # 先把每个 coord hot 化（首次写经 facade ensure 冷启 + 注册 + 发布 ETS）。
      Enum.each(coords, fn coord ->
        assert {:ok, %{chunk_version: 1}} =
                 ChunkDirectory.apply_intent_direct(
                   intent(scene_id, lease, {1, 0, 0}, coord),
                   direct_opts(ctx)
                 )
      end)

      # 现在全部已注册活 pid：并发对不同 coord 直达写。直达后这些 call 各打到各自
      # 的 ChunkProcess mailbox（不经单一 facade 串行 mailbox），彼此独立并行。
      tasks =
        Enum.map(coords, fn coord ->
          Task.async(fn ->
            ChunkDirectory.apply_intent_direct(
              intent(scene_id, lease, {2, 0, 0}, coord),
              direct_opts(ctx)
            )
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &match?({:ok, %{chunk_version: 2}}, &1))

      # 每个 coord 都是独立的权威进程（6 个不同 pid）。
      pids =
        Enum.map(coords, fn coord ->
          assert {:ok, pid} = ChunkRegistry.lookup(scene_id, coord, ctx.registry)
          pid
        end)

      assert length(Enum.uniq(pids)) == length(coords)
    end
  end

  describe "③ ETS 快照与权威 storage 一致" do
    test "同组 samples 经 ETS 直读路径与经 chunk 直达路径结果逐位相等" do
      ctx = boot()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      # solid 批量（apply_intents_direct，同 chunk 多 macro 一次 persist）。
      assert {:ok, _} =
               ChunkDirectory.apply_intents_direct(
                 [
                   intent(scene_id, lease, {1, 0, 0}),
                   intent(scene_id, lease, {3, 0, 0})
                 ],
                 direct_opts(ctx)
               )

      # refined（put_micro_block，单笔直达）。
      assert {:ok, _} =
               ChunkDirectory.apply_intent_direct(
                 refined_intent(scene_id, lease, {2, 0, 0}, 5),
                 direct_opts(ctx)
               )

      assert {:ok, pid} = ChunkRegistry.lookup(scene_id, {0, 0, 0}, ctx.registry)

      samples = [
        %{macro: {1, 0, 0}, micro_slot: 0},
        %{macro: {3, 0, 0}, micro_slot: 0},
        %{macro: {2, 0, 0}, micro_slot: 5},
        %{macro: {2, 0, 0}, micro_slot: 6},
        %{macro: {5, 0, 0}, micro_slot: 0}
      ]

      # ETS 直读路径（经 facade collision_query → ChunkOccupancyTable）。
      assert {:ok, ets_result} =
               ChunkDirectory.collision_query(ChunkDirectory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: {0, 0, 0},
                 samples: samples
               })

      # 权威路径（直接问 chunk 进程的当前 storage）。
      assert {:ok, authoritative} = ChunkProcess.collision_query(pid, %{samples: samples})

      assert ets_result.chunk_version == authoritative.chunk_version
      assert ets_result.occupied == authoritative.occupied
      assert ets_result.occupied_count == authoritative.occupied_count
    end

    test "写后 ETS 快照即时收敛到新版本（occupancy 一致）" do
      ctx = boot()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      assert {:ok, %{chunk_version: 1}} =
               ChunkDirectory.apply_intent_direct(
                 intent(scene_id, lease, {1, 0, 0}),
                 direct_opts(ctx)
               )

      # 写 {1,0,0} 后，ETS 快照已含该占用且不含 {4,0,0}。
      assert {:ok, snapshot} = ChunkOccupancyTable.read_snapshot(scene_id, {0, 0, 0})
      assert snapshot.chunk_version == 1

      assert {:ok, %{occupied_count: 1}} =
               ChunkDirectory.collision_query(ChunkDirectory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: {0, 0, 0},
                 samples: [%{macro: {1, 0, 0}, micro_slot: 0}]
               })

      # 再写 {4,0,0}，ETS 快照随写收敛。
      assert {:ok, %{chunk_version: 2}} =
               ChunkDirectory.apply_intent_direct(
                 intent(scene_id, lease, {4, 0, 0}),
                 direct_opts(ctx)
               )

      assert {:ok, %{occupied_count: 2}} =
               ChunkDirectory.collision_query(ChunkDirectory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: {0, 0, 0},
                 samples: [
                   %{macro: {1, 0, 0}, micro_slot: 0},
                   %{macro: {4, 0, 0}, micro_slot: 0}
                 ]
               })
    end
  end

  describe "④ DB 背压：高速写不无界堆 async persist Task" do
    test "持久化经有界 write-behind pool；高速写后 in-flight persist 收敛归零" do
      ctx = boot()
      scene_id = unique_scene_id()
      lease = lease(scene_id)
      seed_token!(lease)

      # 高速对同 chunk 连续落 30 个方块（每个触发一次 async persist）。
      Enum.each(0..29, fn x ->
        macro = {rem(x, 16), div(x, 16), 0}

        assert {:ok, _} =
                 ChunkDirectory.apply_intent_direct(
                   intent(scene_id, lease, macro),
                   direct_opts(ctx)
                 )
      end)

      assert {:ok, pid} = ChunkRegistry.lookup(scene_id, {0, 0, 0}, ctx.registry)

      # flush 后所有 in-flight async persist Task 已 join（背压让它们经 pool 有序
      # 完成，而非无界堆积）；debug_state 的 async_persist 计数归零。
      assert :ok = ChunkProcess.flush_persistence(pid, 30_000)

      state = ChunkProcess.debug_state(pid)
      assert state.pending_async_persist_count == 0

      # 最终持久化版本与最后一次写一致（pool 背压未丢写）。
      assert {:ok, persisted} =
               DataService.Voxel.ChunkSnapshotStore.get_snapshot(scene_id, {0, 0, 0})

      assert persisted.chunk_version == state.chunk_version
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp boot do
    # 单例注册表（与生产同），使 apply_intent_direct / collision_query 的默认注册表
    # 解析命中。async: false 保证不与其它用单例的测试并发。
    chunk_sup = start_supervised!(VoxelChunkSup)

    directory =
      start_supervised!(
        {ChunkDirectory, chunk_sup: chunk_sup, chunk_registry: ChunkRegistry.default_name()}
      )

    %{chunk_sup: chunk_sup, directory: directory, registry: ChunkRegistry.default_name()}
  end

  defp direct_opts(ctx), do: [server: ctx.directory, chunk_registry: ctx.registry]

  defp intent(scene_id, lease, macro, chunk_coord \\ {0, 0, 0}) do
    %{
      request_id: 0,
      logical_scene_id: scene_id,
      chunk_coord: chunk_coord,
      lease: lease,
      operation: :put_solid_block,
      macro: macro,
      block: NormalBlockData.new(11, health: 40)
    }
  end

  defp refined_intent(scene_id, lease, macro, micro_slot, chunk_coord \\ {0, 0, 0}) do
    %{
      request_id: 0,
      logical_scene_id: scene_id,
      chunk_coord: chunk_coord,
      lease: lease,
      operation: :put_micro_block,
      macro: macro,
      micro_slot: micro_slot,
      micro_layer: %{material_id: 7}
    }
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
    System.unique_integer([:positive, :monotonic]) + 30_000_000
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
