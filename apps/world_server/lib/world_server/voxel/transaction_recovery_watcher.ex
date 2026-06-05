defmodule WorldServer.Voxel.TransactionRecoveryWatcher do
  @moduledoc """
  Recovery sweeper + runtime reaper for `WorldServer.Voxel.TransactionCoordinator`.

  阶段4 / world-2pc-2:从 Phase 3-2 的 **one-shot boot sweeper** 升级为
  **boot sweep + 运行期周期 reaper + 独立 fence 对账**:

  - **boot sweep**:`init` 时跑一次 `recover/2`,对所有 in-flight 事务动作
    (与旧版一致)。
  - **运行期周期 reaper**:每 `@reaper_interval_ms` 触发一次,既调
    `TransactionCoordinator.sweep_deadlines/1`(coordinator 内生 deadline 推进
    的兜底),又跑一次 `recover/2` 把卡住的事务推到终态——**不重启 world** 也能
    自愈悬挂事务。
  - **fence 对账**:周期检查持久化的 chunk fence 与 coordinator 活跃事务集是否
    一致,孤儿 fence(coordinator 已无对应活跃事务)上报
    `voxel_transaction_recovery_orphan_fence`,供 scene 侧 TTL 兜底 / 运维处理
    (scene 侧 fence TTL 是另一支柱,这里只做 world 侧对账观测,不跨 app 删
    scene fence)。

  ## 各状态的处理

  - `:preparing` / `:aborting` → `abort_decision/3` 滚回(idempotent)。
  - `:prepared` → 自动 resume:dispatch commit。
  - `:committing` → **重投递 commit**(事务已决,绝不 abort):只对尚未 durable-ack
    的 participant 再发 commit,直到全 durable → `:committed`。
  - `:committed` / `:aborted` → 已终态,跳过。

  ## resume 路由:driver vs 同步

  - 配置了 `:driver_supervisor` 时(生产 `WorldSup` 路径),`:prepared` /
    `:committing` 的 resume 通过 `TransactionDriverSupervisor.ensure_driver/2`
    拉起一个**受监督 driver**异步续推(编排所有权在 world 受监督进程,driver
    崩了能重启续推)。via-tuple 去重保证同一笔不会拉起两个 driver。
  - 未配置 `:driver_supervisor` 时(聚焦单测),resume 在 reaper 进程内**同步**
    跑 `TransactionExecutor.execute/4`,方便断言。

  ## `:scene_opts_resolver`

  A 1-arity function `fn participants -> {:ok, executor_opts} | {:error, reason}`.
  `executor_opts` is a keyword list passed straight to
  `TransactionExecutor.execute/4` and **must** include
  `:scene_opts_by_participant` (a map keyed by `participant_key`); it may also
  include `:scene_caller`. A `nil` resolver leaves prepared/committing
  transactions parked for operator intervention.
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionDriverSupervisor
  alias WorldServer.Voxel.TransactionExecutor

  # 运行期周期 reaper 间隔。
  @reaper_interval_ms :timer.seconds(10)

  @doc "Starts the recovery watcher and runs one sweep against the configured coordinator."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Runs a recovery sweep synchronously against `coordinator`.

  Exposed so tests and operators can trigger an extra sweep without restarting
  the supervised watcher. Opts:

  - `:scene_opts_resolver` — see module doc.
  - `:driver_supervisor` — route `:prepared` / `:committing` resume through a
    supervised driver (async). Omitted → synchronous resume in the caller.
  - `:fence_snapshot_fn` — 0-arity returning persisted fences as
    `%{{logical_scene_id, chunk_coord} => fence}` for orphan-fence
    reconciliation. Omitted → skip fence reconciliation.
  """
  def recover(coordinator \\ TransactionCoordinator, opts \\ []) do
    snapshot = TransactionCoordinator.snapshot(coordinator)
    summary = sweep(coordinator, snapshot.transactions, opts)
    reconcile_fences(coordinator, snapshot.transactions, opts)
    emit_summary(summary)
    summary
  end

  @impl true
  def init(opts) do
    coordinator = Keyword.get(opts, :coordinator, TransactionCoordinator)

    state = %{
      coordinator: coordinator,
      scene_opts_resolver: Keyword.get(opts, :scene_opts_resolver),
      driver_supervisor: Keyword.get(opts, :driver_supervisor),
      fence_snapshot_fn: Keyword.get(opts, :fence_snapshot_fn),
      reaper_interval_ms: Keyword.get(opts, :reaper_interval_ms, @reaper_interval_ms),
      reaper_enabled?: Keyword.get(opts, :reaper_enabled?, true)
    }

    # boot sweep
    recover(coordinator, recover_opts(state))
    schedule_reaper(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:reaper_tick, state) do
    # 运行期周期 reaper:先让 coordinator 自己消费 deadline(内生 liveness),
    # 再跑一次 recover 把**仍卡住(过 deadline)**的事务推到终态。
    #
    # 关键:运行期只对 stale(timeout 已过)的事务动作。健康在途事务(刚
    # prepare、driver 正在推)不被 reaper 抢着重新 dispatch——避免 reaper 与
    # 正常路径打架。boot sweep(init 路径)则对所有 in-flight 动作(重启后没有
    # driver,必须全量续推)。
    TransactionCoordinator.sweep_deadlines(state.coordinator)
    recover(state.coordinator, Keyword.put(recover_opts(state), :only_stale?, true))
    schedule_reaper(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp recover_opts(state) do
    [
      scene_opts_resolver: state.scene_opts_resolver,
      driver_supervisor: state.driver_supervisor,
      fence_snapshot_fn: state.fence_snapshot_fn
    ]
  end

  defp schedule_reaper(%{reaper_enabled?: false}), do: :ok

  defp schedule_reaper(%{reaper_interval_ms: interval}) when is_integer(interval) do
    Process.send_after(self(), :reaper_tick, interval)
    :ok
  end

  defp sweep(coordinator, transactions, opts) do
    only_stale? = Keyword.get(opts, :only_stale?, false)
    now = System.system_time(:millisecond)

    Enum.reduce(
      transactions,
      %{
        aborted: 0,
        pending_commit: 0,
        finalized: 0,
        abort_failed: 0,
        resumed_commit: 0,
        resume_partial: 0,
        resume_failed: 0,
        resume_dispatched: 0,
        skipped_healthy: 0
      },
      fn {_transaction_id, transaction}, acc ->
        if skip_healthy?(transaction, only_stale?, now) do
          Map.update!(acc, :skipped_healthy, &(&1 + 1))
        else
          case handle_transaction(coordinator, transaction, opts) do
            :aborted -> Map.update!(acc, :aborted, &(&1 + 1))
            :pending_commit -> Map.update!(acc, :pending_commit, &(&1 + 1))
            :finalized -> Map.update!(acc, :finalized, &(&1 + 1))
            :abort_failed -> Map.update!(acc, :abort_failed, &(&1 + 1))
            :resumed_commit -> Map.update!(acc, :resumed_commit, &(&1 + 1))
            :resume_partial -> Map.update!(acc, :resume_partial, &(&1 + 1))
            :resume_failed -> Map.update!(acc, :resume_failed, &(&1 + 1))
            :resume_dispatched -> Map.update!(acc, :resume_dispatched, &(&1 + 1))
          end
        end
      end
    )
  end

  # 运行期 reaper(only_stale? == true)只处理 timeout 已过的事务,避免抢着重
  # dispatch 健康在途事务。`:committing` 始终处理(已决,必须推进到全 durable;
  # 没有 stale 概念,driver 重投递是幂等的)。终态 / plain-map 不在这里跳过。
  defp skip_healthy?(_transaction, false, _now), do: false

  defp skip_healthy?(%BuildTransaction{state: :committing}, true, _now), do: false

  defp skip_healthy?(%BuildTransaction{} = transaction, true, now) do
    transaction.state in [:preparing, :aborting, :prepared] and transaction.timeout_at_ms > now
  end

  defp skip_healthy?(_other, _only_stale?, _now), do: false

  defp handle_transaction(coordinator, %BuildTransaction{state: state} = transaction, _opts)
       when state in [:preparing, :aborting] do
    case TransactionCoordinator.abort_decision(
           coordinator,
           transaction.transaction_id,
           transaction.decision_version
         ) do
      {:ok, _aborted} ->
        emit("voxel_transaction_recovery_aborted", transaction, %{from_state: state})
        :aborted

      {:error, reason} ->
        emit("voxel_transaction_recovery_abort_failed", transaction, %{
          from_state: state,
          reason: inspect(reason)
        })

        :abort_failed
    end
  end

  defp handle_transaction(
         coordinator,
         %BuildTransaction{state: resume_state} = transaction,
         opts
       )
       when resume_state in [:prepared, :committing] do
    resolver = Keyword.get(opts, :scene_opts_resolver)

    cond do
      is_nil(resolver) ->
        emit("voxel_transaction_recovery_pending_commit", transaction, %{
          reason: :no_scene_opts_resolver,
          from_state: resume_state
        })

        :pending_commit

      # 阶段4 / world-2pc:**intents 为空 guard 只限定到 `:prepared`**。
      #
      # `:prepared` resume 要重新 dispatch prepare→commit,确需 persisted intents
      # 重建 scene-side apply 批;intents 为空说明没有可重放的工作,停泊待运维。
      #
      # `:committing`(commit **已决,不可逆**)resume **不**检查 intents:commit
      # 重投递不靠 intents——它靠每个 chunk 上已存在的 prepared fence(fence 内已
      # 持有 intent 批)。break-only / 无 intent 事务到 `:committing` 时
      # intents_by_participant 天然为空;若在此被拦下,重启后既无 driver、reaper 又
      # 拒绝续推,已决 commit 事务会**永久停泊**(liveness 缺口)。因此 :committing
      # 一律进入 resume,由 executor 的 :committing fast-path 只对仍 :pending 的
      # participant 重投递 commit,直到全 durable → :committed。
      resume_state == :prepared and transaction.intents_by_participant == %{} ->
        emit("voxel_transaction_recovery_pending_commit", transaction, %{
          reason: :missing_persisted_intents,
          from_state: resume_state
        })

        :pending_commit

      true ->
        resume_transaction(coordinator, transaction, resolver, opts)
    end
  end

  defp handle_transaction(_coordinator, %BuildTransaction{state: state} = _transaction, _opts)
       when state in [:committed, :aborted] do
    :finalized
  end

  # Phase A1-1b 修:如果 transaction 反序列化只得到 plain map(stale snapshot
  # 跨版本字段缺失 / `%BuildTransaction{}` struct 形态变了 etc),把它当 stale
  # 残留处理 — 直接尝试 abort。落到这条 catchall 之前,plain-map 命中不到任何
  # struct-pattern clause,recovery_watcher.init 会 raise FunctionClauseError,
  # 整个 world_server.WorldSup 起不来,server boot 失败。
  defp handle_transaction(
         coordinator,
         %{transaction_id: tx_id, decision_version: dv, state: state} = stale,
         _opts
       )
       when not is_struct(stale, BuildTransaction) do
    case TransactionCoordinator.abort_decision(coordinator, tx_id, dv) do
      {:ok, _aborted} ->
        emit("voxel_transaction_recovery_stale_aborted", stale, %{
          from_state: state,
          stale_shape: :plain_map
        })

        :aborted

      {:error, reason} ->
        emit("voxel_transaction_recovery_stale_abort_failed", stale, %{
          from_state: state,
          reason: inspect(reason),
          stale_shape: :plain_map
        })

        :abort_failed
    end
  end

  # resume 路由:有 driver_supervisor → 拉起受监督 driver 异步续推;否则同步跑
  # executor(测试路径)。
  defp resume_transaction(coordinator, transaction, resolver, opts) do
    case safe_resolve(resolver, transaction.participants) do
      {:ok, executor_opts} ->
        case Keyword.get(opts, :driver_supervisor) do
          nil ->
            run_resume_sync(coordinator, transaction, executor_opts)

          supervisor ->
            dispatch_resume_driver(supervisor, coordinator, transaction, executor_opts)
        end

      {:error, reason} ->
        emit("voxel_transaction_recovery_scene_opts_unavailable", transaction, %{
          reason: inspect(reason),
          from_state: transaction.state
        })

        :pending_commit
    end
  end

  # 阶段4 / world-2pc-1:把 resume 编排交给受监督 driver。via-tuple 去重保证同一
  # 笔事务只一个 driver。driver 异步推进,reaper 不阻塞;下一轮 reaper 若事务
  # 仍未终态会再拉一次(driver 已存在 → 复用,不重复)。
  defp dispatch_resume_driver(supervisor, coordinator, transaction, executor_opts) do
    driver_opts = [
      transaction_id: transaction.transaction_id,
      coordinator: coordinator,
      executor_opts: executor_opts
    ]

    case TransactionDriverSupervisor.ensure_driver(supervisor, driver_opts) do
      {:ok, _pid} ->
        emit("voxel_transaction_recovery_resume_dispatched", transaction, %{
          from_state: transaction.state
        })

        :resume_dispatched

      {:error, reason} ->
        emit("voxel_transaction_recovery_resume_dispatch_failed", transaction, %{
          reason: inspect(reason),
          from_state: transaction.state
        })

        :resume_failed
    end
  end

  defp run_resume_sync(coordinator, transaction, executor_opts) do
    case TransactionExecutor.execute(
           coordinator,
           transaction,
           transaction.intents_by_participant,
           executor_opts
         ) do
      {:ok, %{decision: :commit, committed?: true, participant_results: results}} ->
        emit("voxel_transaction_recovery_resumed_commit", transaction, %{
          participant_count: length(results)
        })

        :resumed_commit

      {:ok, %{decision: :commit, committed?: false, participant_results: results} = exec_result} ->
        # 阶段4 / world-2pc-3:commit 已决但还没全 durable-ack。事务停在
        # :committing(绝不 abort),resume_partial 信号供运维诊断;下一轮 reaper
        # 会再重投递剩余 participant。
        emit("voxel_transaction_recovery_resume_partial", transaction, %{
          committed_state: exec_result.transaction.state,
          participant_count: length(results),
          failure_count: count_failures(results)
        })

        :resume_partial

      {:ok, %{decision: :commit, participant_results: results} = exec_result} ->
        # committed? 缺省(防御:旧 result 形态)。按是否有失败 participant 判定。
        if Enum.any?(results, fn {_participant, outcome} -> match?({:error, _}, outcome) end) do
          emit("voxel_transaction_recovery_resume_partial", transaction, %{
            committed_state: exec_result.transaction.state,
            participant_count: length(results),
            failure_count: count_failures(results)
          })

          :resume_partial
        else
          emit("voxel_transaction_recovery_resumed_commit", transaction, %{
            participant_count: length(results)
          })

          :resumed_commit
        end

      {:ok, %{decision: other_decision} = exec_result} ->
        emit("voxel_transaction_recovery_resume_unexpected_decision", transaction, %{
          decision: other_decision,
          committed_state: exec_result.transaction.state
        })

        :resume_failed
    end
  rescue
    exception ->
      emit("voxel_transaction_recovery_resume_crashed", transaction, %{
        error: inspect(exception),
        stacktrace: inspect(__STACKTRACE__)
      })

      :resume_failed
  end

  # 阶段4 / world-2pc-2 独立 fence 对账:孤儿 fence = 持久化 fence 指向一个
  # coordinator 活跃集里已经没有的 transaction_id。这里只上报观测,不跨 app
  # 删 scene fence(scene 侧 fence TTL 是另一支柱负责的兜底)。
  defp reconcile_fences(_coordinator, transactions, opts) do
    case Keyword.get(opts, :fence_snapshot_fn) do
      nil ->
        :ok

      fence_snapshot_fn when is_function(fence_snapshot_fn, 0) ->
        active_ids = active_transaction_ids(transactions)

        fence_snapshot_fn.()
        |> safe_fence_snapshot()
        |> Enum.each(fn {{logical_scene_id, chunk_coord}, fence} ->
          tx_id = Map.get(fence, :transaction_id)

          if not MapSet.member?(active_ids, tx_id) do
            CliObserve.emit("voxel_transaction_recovery_orphan_fence", fn ->
              %{
                logical_scene_id: logical_scene_id,
                chunk_coord: inspect(chunk_coord),
                transaction_id: inspect(tx_id),
                fenced_at_ms: Map.get(fence, :fenced_at_ms)
              }
            end)
          end
        end)
    end
  rescue
    exception ->
      CliObserve.emit("voxel_transaction_recovery_fence_reconcile_failed", fn ->
        %{reason: inspect(exception)}
      end)
  end

  defp active_transaction_ids(transactions) do
    transactions
    |> Map.values()
    |> Enum.reduce(MapSet.new(), fn
      %BuildTransaction{transaction_id: id}, acc -> MapSet.put(acc, id)
      %{transaction_id: id}, acc -> MapSet.put(acc, id)
      _other, acc -> acc
    end)
  end

  defp safe_fence_snapshot(snapshot) when is_map(snapshot), do: snapshot
  defp safe_fence_snapshot(_other), do: %{}

  defp safe_resolve(resolver, participants) when is_function(resolver, 1) do
    case resolver.(participants) do
      {:ok, executor_opts} when is_list(executor_opts) -> {:ok, executor_opts}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_resolver_return, other}}
    end
  rescue
    exception -> {:error, {:resolver_crashed, exception}}
  end

  defp safe_resolve(_resolver, _participants), do: {:error, :resolver_not_callable}

  defp count_failures(results) do
    Enum.count(results, fn
      {_p, {:error, _}} -> true
      _ -> false
    end)
  end

  defp emit(event, transaction, payload) do
    CliObserve.emit(event, fn ->
      Map.merge(
        %{
          transaction_id: transaction.transaction_id,
          decision_version: transaction.decision_version,
          state: transaction.state
        },
        payload
      )
    end)
  end

  defp emit_summary(summary) do
    CliObserve.emit("voxel_transaction_recovery_swept", fn -> summary end)
  end
end
