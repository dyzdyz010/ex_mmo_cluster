defmodule WorldServer.Voxel.TransactionRecoveryWatcher do
  @moduledoc """
  One-shot recovery sweeper for `WorldServer.Voxel.TransactionCoordinator`.

  When the world node (or this watcher) starts, the watcher reads the current
  coordinator snapshot once and acts on every in-flight transaction:

  - `:preparing` and `:aborting` transactions are aborted via
    `TransactionCoordinator.abort_decision/3`. This is safe because the
    coordinator's state machine accepts abort from those states (the same path
    a runtime executor would take after a participant timed out), and abort is
    idempotent across replay.
  - `:prepared` transactions are auto-resumed via `TransactionExecutor.execute/4`
    when a `:scene_opts_resolver` was injected and `intents_by_participant`
    is present on the transaction (Phase 3-bis). The executor takes the
    `:prepared` fast-path: skip prepare phase, dispatch commit. If the
    resolver is absent or returns `{:error, _}` the transaction stays parked
    and the watcher emits `voxel_transaction_recovery_pending_commit` so
    operators can see what needs manual intervention.
  - `:committed` and `:aborted` transactions are already final and skipped.

  After the sweep the watcher stays alive (idle) so a `Supervisor` can keep it
  in its child list with the default permanent restart strategy. Restarts will
  re-run the sweep, which is safe: every action it takes is idempotent.

  ## `:scene_opts_resolver`

  A 1-arity function `fn participants -> {:ok, executor_opts} | {:error, reason}`
  (Phase A4-1 changed from 0-arity to 1-arity to match `TransactionExecutor`'s
  per-participant scene_opts API). `executor_opts` is a keyword list passed
  straight to `TransactionExecutor.execute/4` and **must** include
  `:scene_opts_by_participant` (a map keyed by `participant_key`); it
  may also include `:scene_caller` and other executor knobs.

  `WorldSup` injects an implementation that reads every participant's explicit
  `assigned_scene_node`, then builds the per-participant map. Tests can inject
  a stub resolver. A `nil` resolver makes the watcher leave prepared
  transactions parked for operator intervention.
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionExecutor

  @doc "Starts the recovery watcher and runs one sweep against the configured coordinator."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Runs a recovery sweep synchronously against `coordinator`.

  Exposed so tests and operators can trigger an extra sweep without restarting
  the supervised watcher.
  """
  def recover(coordinator \\ TransactionCoordinator, opts \\ []) do
    scene_opts_resolver = Keyword.get(opts, :scene_opts_resolver)
    snapshot = TransactionCoordinator.snapshot(coordinator)
    summary = sweep(coordinator, snapshot.transactions, scene_opts_resolver)
    emit_summary(summary)
    summary
  end

  @impl true
  def init(opts) do
    coordinator = Keyword.get(opts, :coordinator, TransactionCoordinator)
    scene_opts_resolver = Keyword.get(opts, :scene_opts_resolver)
    recover(coordinator, scene_opts_resolver: scene_opts_resolver)
    {:ok, %{coordinator: coordinator, scene_opts_resolver: scene_opts_resolver}}
  end

  defp sweep(coordinator, transactions, scene_opts_resolver) do
    Enum.reduce(
      transactions,
      %{
        aborted: 0,
        pending_commit: 0,
        finalized: 0,
        abort_failed: 0,
        resumed_commit: 0,
        resume_partial: 0,
        resume_failed: 0
      },
      fn {_transaction_id, transaction}, acc ->
        case handle_transaction(coordinator, transaction, scene_opts_resolver) do
          :aborted -> Map.update!(acc, :aborted, &(&1 + 1))
          :pending_commit -> Map.update!(acc, :pending_commit, &(&1 + 1))
          :finalized -> Map.update!(acc, :finalized, &(&1 + 1))
          :abort_failed -> Map.update!(acc, :abort_failed, &(&1 + 1))
          :resumed_commit -> Map.update!(acc, :resumed_commit, &(&1 + 1))
          :resume_partial -> Map.update!(acc, :resume_partial, &(&1 + 1))
          :resume_failed -> Map.update!(acc, :resume_failed, &(&1 + 1))
        end
      end
    )
  end

  defp handle_transaction(coordinator, %BuildTransaction{state: state} = transaction, _resolver)
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
         %BuildTransaction{state: :prepared} = transaction,
         resolver
       ) do
    cond do
      is_nil(resolver) ->
        emit("voxel_transaction_recovery_pending_commit", transaction, %{
          reason: :no_scene_opts_resolver
        })

        :pending_commit

      transaction.intents_by_participant == %{} ->
        emit("voxel_transaction_recovery_pending_commit", transaction, %{
          reason: :missing_persisted_intents
        })

        :pending_commit

      true ->
        resume_prepared(coordinator, transaction, resolver)
    end
  end

  defp handle_transaction(_coordinator, %BuildTransaction{state: state} = _transaction, _resolver)
       when state in [:committed, :aborted] do
    :finalized
  end

  # Phase A1-1b 修:如果 transaction 反序列化只得到 plain map(stale snapshot
  # 跨版本字段缺失 / `%BuildTransaction{}` struct 形态变了 / sweep 看到的是
  # `TransactionCoordinator.snapshot/1` 返回的简化视图 etc),把它当 stale
  # 残留处理 — 直接尝试 abort。落到这条 catchall 之前,plain-map 命中不到
  # 任何 struct-pattern clause,recovery_watcher.init 会 raise
  # FunctionClauseError,整个 world_server.WorldSup 起不来,server boot 失败。
  defp handle_transaction(
         coordinator,
         %{transaction_id: tx_id, decision_version: dv, state: state} = stale,
         _resolver
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

  defp resume_prepared(coordinator, transaction, resolver) do
    case safe_resolve(resolver, transaction.participants) do
      {:ok, executor_opts} ->
        run_resume(coordinator, transaction, executor_opts)

      {:error, reason} ->
        emit("voxel_transaction_recovery_scene_opts_unavailable", transaction, %{
          reason: inspect(reason)
        })

        :pending_commit
    end
  end

  defp run_resume(coordinator, transaction, executor_opts) do
    case TransactionExecutor.execute(
           coordinator,
           transaction,
           transaction.intents_by_participant,
           executor_opts
         ) do
      {:ok, %{decision: :commit, participant_results: results} = exec_result} ->
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
