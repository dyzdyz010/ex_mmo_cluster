defmodule WorldServer.Voxel.TransactionExecutor do
  @moduledoc """
  Async driver that runs a `BuildTransaction` through Scene participants.

  The coordinator owns the world-side state machine; this module turns a
  `begin_transaction` into the actual prepare/commit/abort calls against each
  participant's Scene-side adapter, and posts ACKs and the final decision back
  to the coordinator.

  Phase summary:

  1. Call the scene caller's `prepare/4` for every participant in parallel.
     Each call has a per-participant timeout (`:per_participant_timeout_ms`,
     default 5_000) and the whole executor pass has an overall transaction
     timeout (`:transaction_timeout_ms`, default 30_000) starting from the
     beginning of `execute/4`.
  2. Post a `prepare_ack` to the coordinator for each participant (`:prepared`
     when prepare succeeded, `:failed` otherwise — including timeout, exit, and
     `{:error, _}` returns).
  3. Read the resulting transaction state from the coordinator. If it reached
     `:prepared`, dispatch `commit/3` on every Scene participant (also in
     parallel, with `:commit_timeout_ms`) and record the coordinator's commit
     decision. Otherwise (the coordinator moved to `:aborting` because of a
     failure ack, or any other unexpected state), dispatch `abort/3` on the
     participants that did manage to prepare (with `:abort_timeout_ms`) and
     record the coordinator's abort decision.

  Failure modes that map to `:failed` ack with a structured reason:

  - `{:error, reason}` returned from the scene caller → reason kept as-is.
  - Per-participant timeout → reason `:timeout`.
  - Task crash / exit → reason `{:participant_crashed, exit_reason}`.
  - Overall transaction timeout cancels in-flight tasks; pending participants
    are reported with reason `:transaction_timeout` and the executor proceeds
    to the abort decision.

  Replay short-circuit: when the transaction is already `:committed` or
  `:aborted`, no scene caller side-effects are triggered.

  This version still does not start a long-running watcher process. The overall
  timeout uses the running task stream's deadline; once the executor returns,
  the durable state in the coordinator (plus the structured ack reasons logged
  through `CliObserve`) is the source of truth.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator

  @default_scene_caller SceneServer.Voxel.BuildTransactionApplier

  @default_per_participant_timeout_ms 5_000
  @default_transaction_timeout_ms 30_000

  @doc """
  Drives a previously begun transaction through prepare and the coordinator
  decision, then dispatches commit or abort on the Scene participants.

  - `coordinator` — coordinator GenServer reference. Same value passed to
    `TransactionCoordinator.begin_transaction/2`.
  - `transaction` — the `BuildTransaction` returned from
    `TransactionCoordinator.begin_transaction/2`.
  - `intents_by_participant` — `%{ {region_id, lease_id} => intents_by_chunk }`
    where `intents_by_chunk` is `%{chunk_coord => intent_attrs}`. Each
    `intent_attrs` is the `apply_intent` payload (`:lease`, `:operation`,
    `:macro`, `:block`, …) the chunk's prepare/commit will use.

  Optional `opts`:

  - `:scene_caller` — module exposing `prepare/4`, `commit/3`, `abort/3` with
    the same signature as `SceneServer.Voxel.BuildTransactionApplier`. Defaults
    to that module.
  - `:scene_opts` — base keyword list passed through to the scene caller. The
    executor merges in the transaction's `:logical_scene_id` automatically.
  - `:now_ms_fun` — 0-arity function returning a monotonic-ish timestamp; used
    in the prepare ACK timestamps. Defaults to `System.system_time/1`.
  - `:per_participant_timeout_ms` — per-participant prepare timeout in ms.
    Defaults to `5_000`. Used as the default for commit / abort dispatch when
    those phase-specific options are not supplied.
  - `:transaction_timeout_ms` — overall executor pass timeout from begin to
    decision in ms. Defaults to `30_000`. Pending participants when this
    deadline elapses are treated as `:failed` with reason
    `:transaction_timeout`, and the executor proceeds to the abort decision.
  - `:commit_timeout_ms` — per-participant commit timeout. Defaults to
    `:per_participant_timeout_ms`.
  - `:abort_timeout_ms` — per-participant abort timeout. Defaults to
    `:per_participant_timeout_ms`.
  """
  def execute(coordinator, %BuildTransaction{} = transaction, intents_by_participant, opts \\ [])
      when is_map(intents_by_participant) and is_list(opts) do
    scene_caller = Keyword.get(opts, :scene_caller, @default_scene_caller)
    base_scene_opts = Keyword.get(opts, :scene_opts, [])
    now_fun = Keyword.get(opts, :now_ms_fun, &default_now_ms/0)

    per_participant_timeout =
      Keyword.get(opts, :per_participant_timeout_ms, @default_per_participant_timeout_ms)

    transaction_timeout =
      Keyword.get(opts, :transaction_timeout_ms, @default_transaction_timeout_ms)

    commit_timeout = Keyword.get(opts, :commit_timeout_ms, per_participant_timeout)
    abort_timeout = Keyword.get(opts, :abort_timeout_ms, per_participant_timeout)

    scene_opts =
      base_scene_opts
      |> Keyword.put(:logical_scene_id, transaction.logical_scene_id)

    deadline = monotonic_now_ms() + transaction_timeout

    case transaction.state do
      already_decided when already_decided in [:committed, :aborted] ->
        emit("voxel_transaction_executor_replay_skipped", transaction, %{
          decision: already_decided
        })

        {:ok,
         %{
           transaction: transaction,
           decision: replay_decision(already_decided),
           participant_results: [],
           prepare_results: []
         }}

      :prepared ->
        # Phase 3-bis fast-path: the coordinator is already past prepare —
        # this is a recovery resume, not a fresh transaction. Skip prepare /
        # record_prepare_acks entirely and dispatch commit directly. The
        # `intents_by_participant` argument is accepted for API symmetry but
        # commit phase does not consume per-chunk intents (the fence on each
        # ChunkProcess already holds them).
        emit("voxel_transaction_executor_resume_started", transaction, %{
          participant_count: length(transaction.participants),
          commit_timeout_ms: commit_timeout
        })

        prepare_results = derive_prepare_results_from_prepared_state(transaction)

        run_commit(
          coordinator,
          transaction,
          prepare_results,
          scene_caller,
          scene_opts,
          commit_timeout,
          deadline
        )

      _ ->
        emit("voxel_transaction_executor_started", transaction, %{
          participant_count: length(transaction.participants),
          per_participant_timeout_ms: per_participant_timeout,
          transaction_timeout_ms: transaction_timeout
        })

        prepare_results =
          run_prepare(
            transaction,
            intents_by_participant,
            scene_caller,
            scene_opts,
            per_participant_timeout,
            deadline
          )

        record_prepare_acks(coordinator, transaction, prepare_results, now_fun)

        transaction = fetch_transaction!(coordinator, transaction.transaction_id)

        case transaction.state do
          :prepared ->
            run_commit(
              coordinator,
              transaction,
              prepare_results,
              scene_caller,
              scene_opts,
              commit_timeout,
              deadline
            )

          _other ->
            run_abort(
              coordinator,
              transaction,
              prepare_results,
              scene_caller,
              scene_opts,
              abort_timeout,
              deadline
            )
        end
    end
  end

  # Phase 3-bis: synthesize a `prepare_results` list from a coordinator
  # transaction that is already in `:prepared` state. Every participant whose
  # `prepare_status` is `:prepared` becomes a runnable commit target;
  # `:failed` participants are pre-baked as errors so `run_commit` can split
  # them off without dispatching scene-side calls. The `resumed?: true`
  # marker lets observers distinguish a Phase 3-bis resume from a fresh
  # prepare ack.
  defp derive_prepare_results_from_prepared_state(transaction) do
    Enum.map(transaction.participants, fn participant ->
      case participant.prepare_status do
        :prepared -> {participant, {:ok, %{resumed?: true}}}
        :failed -> {participant, {:error, :prepare_failed_before_resume}}
        :pending -> {participant, {:error, :prepare_status_pending_at_resume}}
      end
    end)
  end

  defp replay_decision(:committed), do: :commit
  defp replay_decision(:aborted), do: :abort

  defp run_prepare(
         transaction,
         intents_by_participant,
         scene_caller,
         scene_opts,
         per_participant_timeout,
         deadline
       ) do
    participants = transaction.participants

    work_items =
      Enum.map(participants, fn participant ->
        key = {participant.region_id, participant.lease_id}
        intents_by_chunk = Map.get(intents_by_participant, key, %{})
        {participant, intents_by_chunk}
      end)

    fun = fn {participant, intents_by_chunk} ->
      safely_invoke(fn ->
        apply(scene_caller, :prepare, [
          participant,
          transaction.transaction_id,
          intents_by_chunk,
          scene_opts
        ])
      end)
    end

    work_items
    |> stream_with_deadline(fun, per_participant_timeout, deadline)
    |> Enum.zip(participants)
    |> Enum.map(fn {stream_outcome, participant} ->
      {participant, normalize_prepare_outcome(stream_outcome)}
    end)
  end

  defp normalize_prepare_outcome({:ok, {:scene_result, {:ok, summary}}}), do: {:ok, summary}
  defp normalize_prepare_outcome({:ok, {:scene_result, {:error, reason}}}), do: {:error, reason}

  defp normalize_prepare_outcome({:ok, {:scene_result, other}}) do
    # Defensive: scene caller returned something that is neither {:ok, _} nor
    # {:error, _}. Treat as failure and surface the unexpected shape.
    {:error, {:invalid_prepare_result, other}}
  end

  defp normalize_prepare_outcome({:ok, {:scene_crash, reason}}) do
    {:error, {:participant_crashed, reason}}
  end

  # Per-item timeout from Task.async_stream surfaces as {:exit, :timeout}.
  defp normalize_prepare_outcome({:exit, :timeout}), do: {:error, :timeout}
  defp normalize_prepare_outcome({:exit, reason}), do: {:error, {:participant_crashed, reason}}
  defp normalize_prepare_outcome(:transaction_timeout), do: {:error, :transaction_timeout}

  defp record_prepare_acks(coordinator, transaction, prepare_results, now_fun) do
    Enum.each(prepare_results, fn {participant, result} ->
      status =
        case result do
          {:ok, _summary} -> :prepared
          {:error, _reason} -> :failed
        end

      ack = %{
        region_id: participant.region_id,
        lease_id: participant.lease_id,
        status: status,
        acked_at_ms: now_fun.()
      }

      ack =
        case result do
          {:error, reason} -> Map.put(ack, :reason, reason)
          _ -> ack
        end

      TransactionCoordinator.prepare_ack(coordinator, transaction.transaction_id, ack)
    end)
  end

  defp run_commit(
         coordinator,
         transaction,
         prepare_results,
         scene_caller,
         scene_opts,
         commit_timeout,
         deadline
       ) do
    {to_run, prebaked} =
      Enum.split_with(prepare_results, fn
        {_participant, {:ok, _summary}} -> true
        _ -> false
      end)

    fun = fn {participant, _prepare_result} ->
      safely_invoke(fn ->
        apply(scene_caller, :commit, [
          participant,
          transaction.transaction_id,
          scene_opts
        ])
      end)
    end

    runnable_participants = Enum.map(to_run, fn {participant, _} -> participant end)

    commit_results =
      to_run
      |> stream_with_deadline(fun, commit_timeout, deadline)
      |> Enum.zip(runnable_participants)
      |> Enum.map(fn {stream_outcome, participant} ->
        {participant, normalize_dispatch_outcome(stream_outcome)}
      end)

    prebaked_results =
      Enum.map(prebaked, fn {participant, prepare_result} ->
        {participant, prepare_result}
      end)

    participant_results = commit_results ++ prebaked_results

    {:ok, transaction} =
      TransactionCoordinator.commit_decision(
        coordinator,
        transaction.transaction_id,
        transaction.decision_version
      )

    # Phase 4 (D5):after coordinator records the commit decision, register
    # all scene_objects allocated at begin_transaction with the Scene-side
    # ObjectRegistry. This is the last write of the commit phase;
    # failures are non-blocking (registry can re-load from SceneObjectStore
    # if it misses an upsert; rows are persisted by ObjectRegistry itself).
    register_scene_objects_after_commit(scene_caller, transaction, scene_opts)

    emit("voxel_transaction_executor_committed", transaction, %{
      participant_count: length(participant_results)
    })

    {:ok,
     %{
       transaction: transaction,
       decision: :commit,
       participant_results: participant_results,
       prepare_results: prepare_results
     }}
  end

  defp register_scene_objects_after_commit(scene_caller, transaction, scene_opts) do
    case Map.get(transaction, :scene_objects, []) do
      [] ->
        :ok

      scene_objects when is_list(scene_objects) ->
        if function_exported?(scene_caller, :register_scene_objects, 2) do
          safely_invoke(fn ->
            apply(scene_caller, :register_scene_objects, [scene_objects, scene_opts])
          end)
        end

        :ok
    end
  end

  defp run_abort(
         coordinator,
         transaction,
         prepare_results,
         scene_caller,
         scene_opts,
         abort_timeout,
         deadline
       ) do
    {to_run, prebaked} =
      Enum.split_with(prepare_results, fn
        {_participant, {:ok, _summary}} -> true
        _ -> false
      end)

    fun = fn {participant, _prepare_result} ->
      safely_invoke(fn ->
        apply(scene_caller, :abort, [
          participant,
          transaction.transaction_id,
          scene_opts
        ])
      end)
    end

    runnable_participants = Enum.map(to_run, fn {participant, _} -> participant end)

    abort_results =
      to_run
      |> stream_with_deadline(fun, abort_timeout, deadline)
      |> Enum.zip(runnable_participants)
      |> Enum.map(fn {stream_outcome, participant} ->
        {participant, normalize_dispatch_outcome(stream_outcome)}
      end)

    prebaked_results =
      Enum.map(prebaked, fn {participant, _prepare_result} ->
        # Participants that did not prepare never held a fence; we ack them as
        # :ok so the caller can see a uniform participant_results list without
        # racing them through abort.
        {participant, :ok}
      end)

    participant_results = abort_results ++ prebaked_results

    {:ok, transaction} =
      TransactionCoordinator.abort_decision(
        coordinator,
        transaction.transaction_id,
        transaction.decision_version
      )

    emit("voxel_transaction_executor_aborted", transaction, %{
      participant_count: length(participant_results)
    })

    {:ok,
     %{
       transaction: transaction,
       decision: :abort,
       participant_results: participant_results,
       prepare_results: prepare_results
     }}
  end

  defp normalize_dispatch_outcome({:ok, {:scene_result, result}}), do: result

  defp normalize_dispatch_outcome({:ok, {:scene_crash, reason}}) do
    {:error, {:participant_crashed, reason}}
  end

  defp normalize_dispatch_outcome({:exit, :timeout}), do: {:error, :timeout}
  defp normalize_dispatch_outcome({:exit, reason}), do: {:error, {:participant_crashed, reason}}
  defp normalize_dispatch_outcome(:transaction_timeout), do: {:error, :transaction_timeout}

  # Wraps a 0-arity invocation that calls into the scene caller. Normal returns
  # surface as `{:scene_result, value}`; exceptions / throws / exits surface as
  # `{:scene_crash, reason}` so the participant is still reported as `:failed`
  # without bringing down the executor.
  defp safely_invoke(fun) when is_function(fun, 0) do
    {:scene_result, fun.()}
  rescue
    error ->
      {:scene_crash, {error, __STACKTRACE__}}
  catch
    :throw, value ->
      {:scene_crash, {:throw, value}}

    :exit, reason ->
      {:scene_crash, {:exit, reason}}
  end

  # Runs `fun` over `enumerable` using `Task.async_stream/3` while respecting
  # both a per-item timeout and an overall deadline. Items that did not finish
  # before the overall deadline are returned as `:transaction_timeout`. Per-item
  # timeouts surface as `:timeout`. Task crashes surface as `{:exit, reason}`.
  #
  # The result is the same length as `enumerable` and preserves order, so the
  # caller can zip it back against the source list.
  defp stream_with_deadline([], _fun, _per_item_timeout, _deadline), do: []

  defp stream_with_deadline(enumerable, fun, per_item_timeout, deadline) do
    items = Enum.to_list(enumerable)
    count = length(items)

    overall_remaining = max(deadline - monotonic_now_ms(), 0)

    if overall_remaining == 0 do
      List.duplicate(:transaction_timeout, count)
    else
      effective_timeout = min(per_item_timeout, overall_remaining)

      stream =
        Task.async_stream(items, fun,
          timeout: effective_timeout,
          on_timeout: :kill_task,
          ordered: true,
          max_concurrency: max(count, 1)
        )

      collect_with_deadline(stream, count, deadline)
    end
  end

  # Drains `stream` collecting up to `count` outcomes. If the overall deadline
  # passes before the stream finishes, the remaining slots are filled with
  # `:transaction_timeout`. We use `Enum.reduce_while/3` so we can pull one
  # element at a time and bail out the moment the deadline elapses; tasks that
  # are still in flight are linked to the temporary supervisor that
  # `Task.async_stream` owns, so letting the stream go out of scope tears them
  # down without leaking processes.
  defp collect_with_deadline(stream, count, deadline) do
    {acc, taken} =
      Enum.reduce_while(stream, {[], 0}, fn outcome, {acc, taken} ->
        if monotonic_now_ms() >= deadline do
          {:halt, {acc, taken}}
        else
          {:cont, {[outcome | acc], taken + 1}}
        end
      end)

    Enum.reverse(acc) ++ List.duplicate(:transaction_timeout, count - taken)
  end

  defp fetch_transaction!(coordinator, transaction_id) do
    snapshot = TransactionCoordinator.snapshot(coordinator)

    case Map.fetch(snapshot.transactions, transaction_id) do
      {:ok, transaction} ->
        transaction

      :error ->
        raise ArgumentError,
              "transaction #{inspect(transaction_id)} disappeared from coordinator snapshot"
    end
  end

  defp emit(event, %BuildTransaction{} = transaction, payload) do
    CliObserve.emit(event, fn ->
      Map.merge(
        %{
          transaction_id: transaction.transaction_id,
          logical_scene_id: transaction.logical_scene_id,
          state: transaction.state,
          decision_version: transaction.decision_version
        },
        payload
      )
    end)
  end

  defp default_now_ms, do: System.system_time(:millisecond)

  defp monotonic_now_ms, do: System.monotonic_time(:millisecond)
end
