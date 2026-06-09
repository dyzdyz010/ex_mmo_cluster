defmodule SceneServer.Voxel.ChunkProcessCommitDurableJoinTest do
  @moduledoc """
  阶段4 (4.5 voxel-storage-3 + 2.2 world-2pc-6) 故障注入测试。

  覆盖统一 2PC 契约在 scene participant 一侧的落实：

  * commit durable join —— commit 只有在快照**持久化到 DB**（DB chunk_version >=
    本次 commit version）后才 reply {:ok, durable-ack} 并删 fence；persist 未确认
    时保留 fence 且不 reply {:ok}。
  * fence TTL 兜底 —— coordinator/driver 死亡导致的孤儿 prepared fence 过 TTL
    自愈作废（主路径仍是 World reaper）。

  所有用例都需要 PostgreSQL（ChunkSnapshotStore / ChunkPendingTransactionStore
  直走 DataService.Repo），故 `async: false` 并逐测清表。
  """
  # 需要 PostgreSQL：共享 voxel_chunk_snapshots / voxel_chunk_pending_transactions
  # 表，强制串行 + 逐测清理。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkPendingTransactionStore
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.NormalBlockData

  @logical_scene_id 1
  @chunk_coord {0, 0, 0}
  @region_id 10
  @lease_id 100
  @owner_scene_instance_ref 1_000
  @owner_epoch 1

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)
    Application.delete_env(:scene_server, :voxel_persist_fault)

    chunk_registry = :"#{__MODULE__}.ChunkRegistry.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: chunk_registry})
    Process.put(:chunk_registry, chunk_registry)

    on_exit(fn -> Application.delete_env(:scene_server, :voxel_persist_fault) end)

    :ok
  end

  describe "① commit durable join — 已提交写在崩溃后不丢" do
    test "commit returns durable-ack, then kill+restart re-hydrates the committed write" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-durable-1", [intent_attrs(lease)])

      # commit 的 {:ok} 仅在 durable join 成功后返回：携带 durable? + 版本。
      assert {:ok, reply} = ChunkProcess.commit_transaction(chunk, "tx-durable-1")
      assert reply.durable? == true
      assert reply.durable_chunk_version == 1
      assert reply.persist_result == :durable

      # durable join 成功后 fence 已删；in-flight commit ack 清零。
      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      state = ChunkProcess.debug_state(chunk)
      assert state.pending_commit_ack_count == 0
      assert state.pending_fence == nil

      # commit 返回即意味着已落库：直接读 DB 应已是 version 1。
      assert {:ok, persisted} = ChunkSnapshotStore.get_snapshot(@logical_scene_id, @chunk_coord)
      assert persisted.chunk_version == 1

      # kill 进程并重启，hydrate（阶段3）不应丢失已提交写。
      committed_version = persisted.chunk_version
      stop_chunk!()

      reborn = boot_chunk(lease)
      reborn_state = ChunkProcess.debug_state(reborn)
      assert reborn_state.chunk_version == committed_version
      assert reborn_state.chunk_version == 1
    end
  end

  describe "② persist 失败 — commit 不被误记 durable、fence 保留、reply error" do
    test "forced persist error keeps the fence and replies {:error, :persist_failed}" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-fail-1", [intent_attrs(lease)])

      # 强制 async persist 返回 stale（模拟 DB 版本围栏拒绝 / 落库失败）。
      Application.put_env(
        :scene_server,
        :voxel_persist_fault,
        {:result, {:error, :stale_chunk_version}}
      )

      assert {:error, :persist_failed} = ChunkProcess.commit_transaction(chunk, "tx-fail-1")

      # 契约 #3：persist 未确认 → fence 保留，pending_fence 不清，ack 清零（已 reply）。
      assert {:ok, persisted_fence} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      assert persisted_fence.transaction_id == "tx-fail-1"

      state = ChunkProcess.debug_state(chunk)
      assert state.pending_commit_ack_count == 0
      assert state.pending_fence.transaction_id == "tx-fail-1"

      # 没有快照被误记 durable：DB 里没有该 chunk 的快照。
      assert {:error, :snapshot_not_found} =
               ChunkSnapshotStore.get_snapshot(@logical_scene_id, @chunk_coord)

      # 决定不可逆 + 重投递：清除故障后再 commit 同一事务应成功 durable。
      Application.delete_env(:scene_server, :voxel_persist_fault)

      assert {:ok, retry_reply} = ChunkProcess.commit_transaction(chunk, "tx-fail-1")
      assert retry_reply.durable? == true

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      assert {:ok, snap} = ChunkSnapshotStore.get_snapshot(@logical_scene_id, @chunk_coord)
      assert snap.chunk_version >= 1
    end

    test "durable barrier rejects when DB version is behind the commit version" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-barrier-1", [intent_attrs(lease)])

      # 强制 persist 返回 {:ok, :unchanged} 但实际不写库：DB 仍无快照，
      # durable barrier 的版本回读校验应判定 DB 落后 → 失败 → 保留 fence。
      Application.put_env(:scene_server, :voxel_persist_fault, {:result, {:ok, :unchanged}})

      assert {:error, :persist_failed} = ChunkProcess.commit_transaction(chunk, "tx-barrier-1")

      assert {:ok, _fence} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)
    end
  end

  describe "③ async persist Task :DOWN — reply error 不挂起 caller" do
    test "persist task crash before finished replies {:error, :persist_failed}" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-down-1", [intent_attrs(lease)])

      # 让 persist Task 直接 exit（不发 finished）→ chunk 收 :DOWN → reply error。
      Application.put_env(:scene_server, :voxel_persist_fault, :crash)

      # caller 不应挂起：commit_transaction 的 GenServer.call 必须在合理时限内
      # 拿到 {:error, :persist_failed}（来自 :DOWN 分支的 GenServer.reply）。
      assert {:error, :persist_failed} = ChunkProcess.commit_transaction(chunk, "tx-down-1")

      # chunk 进程本身没有因 unlinked Task 崩溃而一起死。
      assert Process.alive?(chunk)

      state = ChunkProcess.debug_state(chunk)
      assert state.pending_commit_ack_count == 0
      # fence 保留，等 coordinator 重投递。
      assert state.pending_fence.transaction_id == "tx-down-1"

      assert {:ok, _fence} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)
    end
  end

  describe "④ 孤儿 prepared fence — 过 TTL 自愈作废" do
    test "an orphan fence past its deadline is self-voided by the TTL sweep" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      # prepare 时下发一个已经过期的 deadline（绝对毫秒时间戳，过去时刻），
      # 模拟 coordinator deadline 已过且 driver/reaper 缺席的孤儿场景。
      past_deadline = System.system_time(:millisecond) - 1

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(
                 chunk,
                 "tx-orphan-1",
                 [intent_attrs(lease)],
                 fence_deadline_ms: past_deadline
               )

      assert ChunkProcess.debug_state(chunk).pending_fence.transaction_id == "tx-orphan-1"

      # 周期 TTL 检查（@fence_ttl_check_interval_ms = 1s）应在数秒内作废孤儿 fence。
      assert eventually(fn ->
               ChunkProcess.debug_state(chunk).pending_fence == nil
             end)

      # DB fence 行也被删除（TTL 作废会删持久化行）。
      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      # 作废后 chunk 重新可写（不再被孤儿事务围栏）。
      assert {:ok, %{chunk_version: 1}} =
               ChunkProcess.apply_intent(chunk, intent_attrs(lease))
    end

    test "a fence whose deadline is still in the future is NOT voided" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      future_deadline = System.system_time(:millisecond) + 60_000

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(
                 chunk,
                 "tx-live-1",
                 [intent_attrs(lease)],
                 fence_deadline_ms: future_deadline
               )

      # 给 TTL 周期检查充分机会跑（> 一个检查间隔），fence 仍应在。
      Process.sleep(1_300)

      state = ChunkProcess.debug_state(chunk)
      assert state.pending_fence.transaction_id == "tx-live-1"
      assert state.pending_fence.deadline_ms == future_deadline
    end
  end

  describe "⑤ B2 跨侧幂等 — scene 已 durable、world 尚未记 durable-ack 的崩溃窗口" do
    test "re-delivered commit for an already-durable transaction returns idempotent durable-ack (not :transaction_not_prepared)" do
      # 裂缝 B2:崩溃窗口——scene 已 durable(fence 删、hot swap),但 world 尚未把
      # 该 participant 记成 durable-ack(commit_acks 仍 :pending)。恢复后 world
      # **重投递 commit**。修复前 scene 因 fence 已释放回 {:error,
      # :transaction_not_prepared} → world 把 {:error} 当非 durable → key 永远
      # :pending → 事务永远 :committing → reaper 无限重投递 → 永久 stranding
      # (跨侧 liveness 死锁)。修复后:scene 记录"最近 durable 提交的 tx + version",
      # 对**已提交事务**的 commit 重投递**幂等回 {:ok, durable?: true}**。
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-idem-1", [intent_attrs(lease)])

      # 第一次 commit:durable 成功,fence 删除。
      assert {:ok, first} = ChunkProcess.commit_transaction(chunk, "tx-idem-1")
      assert first.durable? == true
      assert first.durable_chunk_version == 1

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      # 模拟 world 重投递同一笔 commit(fence 早已释放)。修复前会
      # {:error, :transaction_not_prepared};修复后幂等回 durable-ack。
      assert {:ok, redelivered} = ChunkProcess.commit_transaction(chunk, "tx-idem-1")
      assert redelivered.durable? == true
      assert redelivered.idempotent? == true
      assert redelivered.durable_chunk_version == 1

      # 幂等重投递不二次推进版本、不破坏 hot 状态。
      state = ChunkProcess.debug_state(chunk)
      assert state.chunk_version == 1
      assert state.pending_fence == nil
      assert state.pending_commit_ack_count == 0

      # 多次重投递仍幂等。
      assert {:ok, %{durable?: true, idempotent?: true}} =
               ChunkProcess.commit_transaction(chunk, "tx-idem-1")
    end

    test "re-delivered commit stays idempotent even after another transaction fences the chunk" do
      # 边界:本事务已 durable(fence 释放)后,另一笔事务又 prepare 占住 fence。
      # 对**已 durable 的本事务**重投递 commit 仍应幂等回 durable,而不是误报
      # {:chunk_fence_owned_by_another_transaction, _}。
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-idem-a", [intent_attrs(lease)])

      assert {:ok, %{durable?: true}} = ChunkProcess.commit_transaction(chunk, "tx-idem-a")

      # 另一笔事务 prepare,占住 fence。
      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, "tx-idem-b", [intent_attrs(lease)])

      # 对已 durable 的 tx-idem-a 重投递 commit:幂等 durable,不被新 fence 误判。
      assert {:ok, %{durable?: true, idempotent?: true}} =
               ChunkProcess.commit_transaction(chunk, "tx-idem-a")

      # 真正未 prepare 过的事务仍报 :transaction_not_prepared 之外的占用错误。
      assert {:error, {:chunk_fence_owned_by_another_transaction, "tx-idem-b"}} =
               ChunkProcess.commit_transaction(chunk, "tx-never-prepared")
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp eventually(fun, attempts \\ 60, interval_ms \\ 100)

  defp eventually(_fun, 0, _interval_ms), do: false

  defp eventually(fun, attempts, interval_ms) do
    if fun.() do
      true
    else
      Process.sleep(interval_ms)
      eventually(fun, attempts - 1, interval_ms)
    end
  end

  defp lease(overrides \\ []) do
    base = %{
      logical_scene_id: @logical_scene_id,
      region_id: @region_id,
      lease_id: @lease_id,
      owner_scene_instance_ref: @owner_scene_instance_ref,
      owner_epoch: @owner_epoch,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    Map.merge(base, Map.new(overrides))
  end

  defp seed_token!(lease) do
    {:ok, _} =
      WriteTokenStore.upsert_token(
        WriteTokenStore,
        Map.put(lease, :token_version, lease.owner_epoch)
      )

    :ok
  end

  defp boot_chunk(lease) do
    start_supervised!({
      ChunkProcess,
      [
        logical_scene_id: @logical_scene_id,
        chunk_coord: @chunk_coord,
        lease: lease,
        chunk_registry: chunk_registry!()
      ]
    })
  end

  defp stop_chunk! do
    stop_supervised!(ChunkProcess)
    wait_for_unregistered_chunk()
  end

  defp wait_for_unregistered_chunk(attempts \\ 20)
  defp wait_for_unregistered_chunk(0), do: :ok

  defp wait_for_unregistered_chunk(attempts) do
    case Registry.lookup(chunk_registry!(), {@logical_scene_id, @chunk_coord}) do
      [] ->
        :ok

      _entries ->
        Process.sleep(10)
        wait_for_unregistered_chunk(attempts - 1)
    end
  end

  defp chunk_registry! do
    Process.get(:chunk_registry) || raise "missing chunk registry"
  end

  defp intent_attrs(lease) do
    %{
      request_id: 0,
      logical_scene_id: @logical_scene_id,
      chunk_coord: @chunk_coord,
      lease: lease,
      operation: :put_solid_block,
      macro: 0,
      block: NormalBlockData.new(2, health: 50)
    }
  end
end
