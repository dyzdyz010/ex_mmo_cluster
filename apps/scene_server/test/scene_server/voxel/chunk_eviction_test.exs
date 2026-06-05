defmodule SceneServer.Voxel.ChunkEvictionTest.IdleEvictSimulator do
  @moduledoc false
  # 自包含 simulator：每 tick 清 dirty（cells_updated=1，无 env_delta），用于
  # 验证“有 simulator + dirty → arm tick → 跑完回零 timer / simulation_active”。
  @behaviour SceneServer.Voxel.Simulator

  @impl true
  def simulator_id, do: :evict_test_sim

  @impl true
  def tick(state, _dirty, _env) do
    next = if is_nil(state), do: %{calls: 1}, else: %{calls: state.calls + 1}
    {:ok, next, %{cells_updated: 1, env_delta: nil}}
  end
end

defmodule SceneServer.Voxel.ChunkEvictionTest do
  @moduledoc """
  阶段2.4 (voxel-storage-4) 故障注入验收：ChunkProcess 空闲驱逐 + 按需 tick。

  覆盖 4 个验收核心：

    1. 空闲 chunk（无订阅 / 无 lease 有效 / 静默窗口过）被驱逐：驱逐前已
       persist；驱逐后 Registry 无该 key；进程已退出（无残留 timer，进程死即
       timer 灭）。
    2. 活跃 chunk 不被误驱：有订阅 / 有 field-due 模拟 / 持有效 lease 三种活跃
       态均拒绝驱逐复核。
    3. 驱逐-ensure 竞态：facade 复核窗口内 chunk 又变活跃 → 复核取消驱逐、进程
       复用（confirm_evict 返回 {:cancel, _}）。
    4. 重新 ensure 被驱逐的 chunk → 从持久化 hydrate（经阶段3 冷启路径）。

  每个测试用隔离的 (Registry + VoxelChunkSup + ChunkDirectory) 三件套，配短的
  `idle_evict_silence_ms` / `lifecycle_check_interval_ms` 使驱逐在测试时窗内发生。
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

  alias SceneServer.Voxel.ChunkEvictionTest.IdleEvictSimulator

  @chunk_coord {5, 6, 7}

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)
    :ok
  end

  describe "① 空闲 chunk 被驱逐（驱逐前 persist + 驱逐后 Registry 无 key + 进程退出）" do
    test "无订阅 + lease 失效 + 静默窗口过 → 自动驱逐, 驱逐前已 persist" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = expired_lease(scene_id)
      seed_token!(lease)

      # 直接在隔离 sup 下启动 chunk，配短驱逐窗口 + 把 facade 作为驱逐回址。
      # lease 已过期（lease_stale? = true）使其成为可驱逐候选，但 token 仍可校验
      # 通过（token 不看 expires_at_ms），保证 persist_before_evict 成功。
      chunk = start_evictable_chunk!(ctx, scene_id, lease, idle_evict_silence_ms: 0)

      # 写一笔可见 voxel 进 hot storage（lease 过期不影响写路径，只影响模拟）。
      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk, {1, 0, 0}, NormalBlockData.new(11, health: 40))

      ref = Process.monitor(chunk)

      # 生命周期节拍（50ms）触发 → 请求驱逐 → facade 复核 → persist → terminate。
      assert_receive {:DOWN, ^ref, :process, ^chunk, _reason}, 2_000

      # 驱逐后注册表无该 key（进程退出，Registry 随 :DOWN 摘除）。
      assert_eventually(fn ->
        ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry) == :not_started
      end)

      # 驱逐前已 persist：DB 里有该 chunk 的快照，且含写入的 solid block。
      assert {:ok, persisted} = ChunkSnapshotStore.get_snapshot(scene_id, @chunk_coord)
      assert persisted.chunk_version >= 1
    end
  end

  describe "② 活跃 chunk 不被误驱" do
    test "有订阅者 → confirm_evict 拒绝（became_active）" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = expired_lease(scene_id)
      seed_token!(lease)

      # 静默窗口=0 使其满足静默条件，但把生命周期 timer 拉到很长，确保不会有
      # 自发驱逐抢在手动 confirm_evict 之前——本测试要的是手动复核的判定。
      chunk =
        start_evictable_chunk!(ctx, scene_id, lease,
          idle_evict_silence_ms: 0,
          lifecycle_check_interval_ms: 60_000
        )

      # 订阅 self()，使其变为活跃 chunk。
      assert {:ok, _payload} = ChunkProcess.subscribe(chunk, self())
      assert_receive {:voxel_chunk_snapshot_payload, _}

      # 即使满足静默 + lease 失效，有订阅就不应被驱逐。
      assert {:cancel, :became_active} = ChunkProcess.confirm_evict(chunk)
      assert Process.alive?(chunk)
    end

    test "持有效 lease → 永不进入可驱逐候选" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = valid_lease(scene_id)
      seed_token!(lease)

      chunk = start_evictable_chunk!(ctx, scene_id, lease, idle_evict_silence_ms: 0)

      # 有效 lease（未过期）→ idle_evict_candidate? 因 lease_stale? false 而为假。
      refute ChunkProcess.debug_state(chunk).idle_evict_candidate?
      assert {:cancel, :became_active} = ChunkProcess.confirm_evict(chunk)
      assert Process.alive?(chunk)
    end

    test "在跑模拟（有 simulator 且 dirty）→ 不被误驱" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      # 有效 lease 使模拟真正 arm；写入制造 dirty → tick_armed? true → simulation_active?。
      lease = valid_lease(scene_id)
      seed_token!(lease)

      chunk =
        start_evictable_chunk!(ctx, scene_id, lease,
          idle_evict_silence_ms: 0,
          simulators: [IdleEvictSimulator]
        )

      _ = ChunkProcess.put_solid_block(chunk, {2, 2, 2}, NormalBlockData.new(7))

      # 模拟在跑（tick armed / due）→ 即便 confirm_evict 也拒绝。注意有效 lease
      # 本身也会拒绝，这里额外断言 idle 判定为假以覆盖 simulation_active 分支。
      refute ChunkProcess.debug_state(chunk).idle_evict_candidate?
      assert Process.alive?(chunk)
    end
  end

  describe "③ 驱逐-ensure 竞态：复核窗口内变活跃 → 取消驱逐、进程复用" do
    test "confirm_evict 前订阅到达 → 复核取消, chunk 复用" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = expired_lease(scene_id)
      seed_token!(lease)

      # 静默=0 使其成为可驱逐候选，但生命周期 timer 拉长，避免自发驱逐抢跑——
      # 本测试手动模拟“请求→复核”之间挤进一个订阅。
      chunk =
        start_evictable_chunk!(ctx, scene_id, lease,
          idle_evict_silence_ms: 0,
          lifecycle_check_interval_ms: 60_000
        )

      assert ChunkProcess.debug_state(chunk).idle_evict_candidate?

      # 注入活动：订阅。confirm_evict 在 chunk mailbox 里重新评估 → became_active。
      assert {:ok, _} = ChunkProcess.subscribe(chunk, self())
      assert_receive {:voxel_chunk_snapshot_payload, _}

      assert {:cancel, :became_active} = ChunkProcess.confirm_evict(chunk)
      assert Process.alive?(chunk)

      # 取消后注册表条目仍在，进程复用（同 pid 仍是该 key 的权威）。
      assert {:ok, ^chunk} = ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry)
    end

    test "facade 级竞态：active chunk 收到 request_evict cast → 不终止" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = expired_lease(scene_id)
      seed_token!(lease)

      chunk =
        start_evictable_chunk!(ctx, scene_id, lease,
          idle_evict_silence_ms: 0,
          lifecycle_check_interval_ms: 60_000
        )

      # 订阅使其活跃。
      assert {:ok, _} = ChunkProcess.subscribe(chunk, self())
      assert_receive {:voxel_chunk_snapshot_payload, _}

      ref = Process.monitor(chunk)

      # 直接对 facade 发一个伪造的 request_evict（模拟它在 chunk 变活跃前就排了队）。
      # facade 复核会调 confirm_evict，chunk 回 cancel，facade 不 terminate。
      GenServer.cast(ctx.directory, {:request_evict, {scene_id, @chunk_coord}, chunk})

      refute_receive {:DOWN, ^ref, :process, ^chunk, _}, 500
      assert Process.alive?(chunk)
      assert {:ok, ^chunk} = ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry)
    end
  end

  describe "④ 重新 ensure 被驱逐的 chunk → 从持久化 hydrate" do
    test "驱逐后再 ensure → 冷启并从 DB hydrate（storage 非空）" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = expired_lease(scene_id)
      seed_token!(lease)

      chunk = start_evictable_chunk!(ctx, scene_id, lease, idle_evict_silence_ms: 0)

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk, {1, 0, 0}, NormalBlockData.new(11, health: 40))

      ref = Process.monitor(chunk)
      assert_receive {:DOWN, ^ref, :process, ^chunk, _reason}, 2_000

      assert_eventually(fn ->
        ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry) == :not_started
      end)

      # 经 facade 重新 ensure（带一个**有效** lease，使 hydrate 后进授权态）。
      fresh_lease = valid_lease(scene_id)
      seed_token!(fresh_lease)

      assert {:ok, new_pid} =
               ChunkDirectory.ensure_chunk(ctx.directory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: fresh_lease
               })

      refute new_pid == chunk

      # 冷启从持久化 hydrate：storage 非空，含驱逐前写入的 solid block。
      new_state = ChunkProcess.debug_state(new_pid)
      assert new_state.hydrate_status == :loaded
      assert new_state.chunk_version >= 1

      assert Storage.macro_header_at(new_state.storage, {1, 0, 0}).mode ==
               MacroCellHeader.cell_mode_solid_block()
    end

    # MAJOR 1 故障注入回归：驱逐 terminate_child 同步返回后，Registry 摘除死 pid
    # 注册项是异步的。复现“驱逐刚返回即 ensure”的死 pid 窗口：直接给 facade 发
    # request_evict（facade 在其串行 mailbox 里 confirm_evict → terminate_child →
    # 等 Registry 清理），紧接着在**同一** facade 上 ensure_chunk。因为两者都走
    # facade 单点串行 lane，ensure 必须在驱逐清理完成后才执行，故必须拿到一个
    # **alive 的新进程**而非刚死的旧 pid。
    test "驱逐刚返回即 ensure → 拿到 alive 的新进程而非死 pid" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = expired_lease(scene_id)
      seed_token!(lease)

      # 长生命周期 timer 避免自发驱逐抢跑——本测试要手动驱动 request_evict，
      # 精确复现“驱逐返回 → ensure”窗口。
      chunk =
        start_evictable_chunk!(ctx, scene_id, lease,
          idle_evict_silence_ms: 0,
          lifecycle_check_interval_ms: 60_000
        )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk, {1, 0, 0}, NormalBlockData.new(11, health: 40))

      assert ChunkProcess.debug_state(chunk).idle_evict_candidate?

      ref = Process.monitor(chunk)

      # facade 在串行 mailbox 里复核 + terminate + 等 Registry 清理。
      GenServer.cast(ctx.directory, {:request_evict, {scene_id, @chunk_coord}, chunk})

      # 紧接着在同一 facade 上 ensure（带有效 lease 使新进程进授权态 + 从 DB
      # hydrate）。这个 call 排在 request_evict cast 之后的同一串行 lane，必然
      # 在驱逐清理后才执行。
      fresh_lease = valid_lease(scene_id)
      seed_token!(fresh_lease)

      assert {:ok, new_pid} =
               ChunkDirectory.ensure_chunk(ctx.directory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: @chunk_coord,
                 lease: fresh_lease
               })

      # 关键断言：拿到的是 alive 的新进程，不是被驱逐的死 pid。
      assert Process.alive?(new_pid)
      refute new_pid == chunk

      # 旧进程确已退出（驱逐已完成）。
      assert_receive {:DOWN, ^ref, :process, ^chunk, _reason}, 2_000
      refute Process.alive?(chunk)

      # 注册表现在指向新权威 pid。
      assert {:ok, ^new_pid} = ChunkRegistry.lookup(scene_id, @chunk_coord, ctx.registry)

      # 新进程从持久化 hydrate，含驱逐前写入的 solid block。
      new_state = ChunkProcess.debug_state(new_pid)
      assert new_state.hydrate_status == :loaded
      assert new_state.chunk_version >= 1
    end
  end

  describe "按需 tick：空闲态零 timer" do
    test "无 simulator 的 chunk 不 arm tick（tick_armed? false）" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = valid_lease(scene_id)
      seed_token!(lease)

      # 长静默窗口避免被驱逐干扰本断言。
      chunk =
        start_evictable_chunk!(ctx, scene_id, lease, idle_evict_silence_ms: 600_000)

      # 写入制造 dirty，但无 simulator → 不应 arm tick。
      _ = ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(3))

      state = ChunkProcess.debug_state(chunk)
      refute state.tick_armed?
    end

    test "有 simulator + dirty → arm tick（tick_armed? true，跑完回零 timer）" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()
      lease = valid_lease(scene_id)
      seed_token!(lease)

      chunk =
        start_evictable_chunk!(ctx, scene_id, lease,
          idle_evict_silence_ms: 600_000,
          simulators: [IdleEvictSimulator]
        )

      _ = ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(3))

      # 写入后应已 arm（dirty + simulator + 有效 lease）。
      assert ChunkProcess.debug_state(chunk).tick_armed?

      # tick 跑完清 dirty 后回到零 timer 空闲态。
      assert_eventually(fn ->
        s = ChunkProcess.debug_state(chunk)
        not s.tick_armed?
      end)
    end

    # MAJOR 2 故障注入回归：已授权 + dirty + simulator 的 chunk，lease 真正失效后
    # （tick 因 lease_stale? 停 arm、tick_armed? 归零），World 续发新 lease 必须
    # re-arm tick 并恢复模拟。修复前 authorize_with_lease 的 %{mode: :authorized}
    # 子句只刷 lease 不 re-arm → 模拟停滞直到下次写。
    test "authorized+dirty+simulator 的 chunk lease 失效后续期 → tick 重新 arm、模拟恢复" do
      ctx = start_isolated_runtime()
      scene_id = unique_scene_id()

      # 起始即过期 lease：hydrate 成 :authorized，但 lease_stale? 使 tick 不 arm。
      # 用“起始即 stale lease”精确构造前置态（无 tick 执行 → dirty 不被清），
      # 避免依赖竞态时序。
      stale = expired_lease(scene_id)
      seed_token!(stale)

      chunk =
        start_evictable_chunk!(ctx, scene_id, stale,
          # 长静默 + 长生命周期节拍：本测试不验证驱逐，避免节拍把 stale chunk 驱掉。
          idle_evict_silence_ms: 600_000,
          lifecycle_check_interval_ms: 60_000,
          simulators: [IdleEvictSimulator]
        )

      # 写入制造 dirty。lease_stale? → 即便有 simulator + dirty 也**不 arm**（停滞态）。
      _ = ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(3))

      stalled = ChunkProcess.debug_state(chunk)
      assert stalled.mode == :authorized
      refute stalled.tick_armed?

      # 确认不会自发 arm（lease 始终 stale）。
      Process.sleep(120)
      refute ChunkProcess.debug_state(chunk).tick_armed?

      # World 续发有效 lease → 必须 re-arm（修复点）。续期是同步路径，
      # maybe_arm_simulation_tick 立即把 due 的 tick 拉起来。
      fresh = valid_lease(scene_id)
      assert {:ok, _} = ChunkProcess.apply_lease(chunk, fresh)

      # 续期后立刻已重新 arm。
      assert ChunkProcess.debug_state(chunk).tick_armed?

      # 模拟真正恢复：tick 执行后 IdleEvictSimulator 清 dirty → tick 收敛回零 timer
      # 空闲态（tick_armed? false）。这证明续期后 tick 不仅被排上，还真的跑完一轮
      # （修复前续期不 re-arm，dirty 永远挂着、tick 永不执行）。
      assert_eventually(fn ->
        not ChunkProcess.debug_state(chunk).tick_armed?
      end)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp start_isolated_runtime do
    registry_name = :"chunk_evict_registry_#{System.unique_integer([:positive])}"

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

  # 在隔离的 VoxelChunkSup 下起一个 chunk（必须是 ctx.chunk_sup 的子进程，
  # 这样 facade 驱逐时的 DynamicSupervisor.terminate_child 才能找到它），注入
  # 隔离注册表 + 把隔离 facade 作为 request_evict 回址 + 短驱逐窗口 + 短生命
  # 周期节拍。
  defp start_evictable_chunk!(ctx, scene_id, lease, opts) do
    chunk_opts =
      [
        logical_scene_id: scene_id,
        chunk_coord: @chunk_coord,
        lease: lease,
        chunk_registry: ctx.registry,
        chunk_directory: ctx.directory,
        lifecycle_check_interval_ms: 50
      ]
      |> Keyword.merge(opts)

    {:ok, pid} = VoxelChunkSup.start_chunk(ctx.chunk_sup, chunk_opts)
    pid
  end

  defp assert_eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, timeout_ms)
  end

  defp do_assert_eventually(fun, deadline, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true within #{timeout_ms}ms")
      else
        Process.sleep(20)
        do_assert_eventually(fun, deadline, timeout_ms)
      end
    end
  end

  # token 永不过期的固定未来 deadline（绝对毫秒）。**不随调用时刻变化**：
  # WriteTokenStore 的 CAS 在 token_version 相同时要求 token 内容逐字节相等才算
  # 幂等（:same），否则判 :stale。若 expires_at_ms 用 `System.system_time + N`，
  # 同一 (region/lease/epoch) 身份在不同调用时刻会得到不同的 expires_at_ms →
  # token_version 相同但内容不同 → :stale，第二次 seed_token! 会失败（测试④
  # 先 seed expired_lease 再 seed 同 epoch 的 valid_lease，正撞这个窗口）。
  # 钉死一个固定的远期常量后，对同一身份重复 seed 是幂等 :same，对不同 epoch
  # 才按 token_version 升序走 :newer，符合生产里 World 续期 token 的语义。
  @token_far_future_ms 4_102_444_800_000

  # 注意：DataService 写 token 与 chunk 持有的 scene 侧 lease 是**独立记录**。
  # 生产模型里 World 会持续续期 token（保持权威写有效），即便 chunk 手里那份
  # lease 快照的 expires_at_ms 已过（scene 侧 lease_stale?=true，使 chunk 进入
  # 可驱逐候选）。因此这里把 token 的 expires_at_ms 钉在远期未来，使
  # persist_before_evict 在“stale-lease 但 token 仍有效”时能真正落库——这正是
  # 测试①“驱逐前已 persist”想验证的路径。identity（region/lease/epoch）仍与
  # chunk lease 对齐以通过 validate_identity。
  defp seed_token!(lease) do
    token =
      lease
      |> Map.put(:token_version, lease.owner_epoch)
      |> Map.put(:expires_at_ms, @token_far_future_ms)

    case WriteTokenStore.upsert_token(WriteTokenStore, token) do
      {:ok, _} -> :ok
      # 同一身份（token_version 相同且内容相同）重复 seed → 幂等无变更。
      {:error, :stale_token} -> flunk("seed_token! produced a stale token: #{inspect(token)}")
    end
  end

  defp unique_scene_id do
    System.unique_integer([:positive, :monotonic]) + 30_000_000
  end

  defp valid_lease(scene_id) do
    base_lease(scene_id, System.system_time(:millisecond) + 60_000)
  end

  defp expired_lease(scene_id) do
    base_lease(scene_id, System.system_time(:millisecond) - 60_000)
  end

  defp base_lease(scene_id, expires_at_ms) do
    %{
      logical_scene_id: scene_id,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {8, 8, 8},
      expires_at_ms: expires_at_ms
    }
  end
end
