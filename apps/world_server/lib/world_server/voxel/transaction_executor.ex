defmodule WorldServer.Voxel.TransactionExecutor do
  @moduledoc """
  Synchronous driver that runs a `BuildTransaction` through Scene participants.

  The coordinator owns the world-side state machine; this module turns a
  `begin_transaction` into the actual prepare/commit/abort calls against each
  participant's Scene-side adapter, and posts ACKs and the final decision back
  to the coordinator.

  Phase summary:

  1. Call the scene caller's `prepare/4` for every participant in declared order.
  2. Post a `prepare_ack` to the coordinator for each participant (`:prepared`
     when prepare succeeded, `:failed` otherwise).
  3. Read the resulting transaction state from the coordinator. If it reached
     `:prepared`, dispatch `commit/3` on every Scene participant and record the
     coordinator's commit decision. Otherwise (the coordinator moved to
     `:aborting` because of a failure ack, or any other unexpected state),
     dispatch `abort/3` on the participants that did manage to prepare and
     record the coordinator's abort decision.

  This first version is synchronous and runs in the calling process. It does
  not start a background timeout watcher, and it does not recover in-flight
  transactions across coordinator restarts. Both are deferred to a follow-up
  slice that pairs with a durable transaction backend.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator

  @default_scene_caller SceneServer.Voxel.BuildTransactionApplier

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
  """
  def execute(coordinator, %BuildTransaction{} = transaction, intents_by_participant, opts \\ [])
      when is_map(intents_by_participant) and is_list(opts) do
    scene_caller = Keyword.get(opts, :scene_caller, @default_scene_caller)
    base_scene_opts = Keyword.get(opts, :scene_opts, [])
    now_fun = Keyword.get(opts, :now_ms_fun, &default_now_ms/0)

    scene_opts =
      base_scene_opts
      |> Keyword.put(:logical_scene_id, transaction.logical_scene_id)

    case transaction.state do
      already_decided when already_decided in [:committed, :aborted] ->
        emit("voxel_transaction_executor_replay_skipped", transaction, %{
          decision: already_decided
        })

        {:ok,
         %{
           transaction: transaction,
           decision: replay_decision(already_decided),
           participant_results: []
         }}

      _ ->
        emit("voxel_transaction_executor_started", transaction, %{
          participant_count: length(transaction.participants)
        })

        prepare_results =
          run_prepare(transaction, intents_by_participant, scene_caller, scene_opts)

        record_prepare_acks(coordinator, transaction, prepare_results, now_fun)

        transaction = fetch_transaction!(coordinator, transaction.transaction_id)

        case transaction.state do
          :prepared ->
            run_commit(coordinator, transaction, prepare_results, scene_caller, scene_opts)

          _other ->
            run_abort(coordinator, transaction, prepare_results, scene_caller, scene_opts)
        end
    end
  end

  defp replay_decision(:committed), do: :commit
  defp replay_decision(:aborted), do: :abort

  defp run_prepare(transaction, intents_by_participant, scene_caller, scene_opts) do
    Enum.map(transaction.participants, fn participant ->
      key = {participant.region_id, participant.lease_id}
      intents_by_chunk = Map.get(intents_by_participant, key, %{})

      result =
        apply(scene_caller, :prepare, [
          participant,
          transaction.transaction_id,
          intents_by_chunk,
          scene_opts
        ])

      {participant, result}
    end)
  end

  defp record_prepare_acks(coordinator, transaction, prepare_results, now_fun) do
    Enum.each(prepare_results, fn {participant, result} ->
      status =
        case result do
          {:ok, _summary} -> :prepared
          {:error, _reason} -> :failed
        end

      TransactionCoordinator.prepare_ack(coordinator, transaction.transaction_id, %{
        region_id: participant.region_id,
        lease_id: participant.lease_id,
        status: status,
        acked_at_ms: now_fun.()
      })
    end)
  end

  defp run_commit(coordinator, transaction, prepare_results, scene_caller, scene_opts) do
    participant_results =
      Enum.map(prepare_results, fn {participant, prepare_result} ->
        case prepare_result do
          {:ok, _summary} ->
            {participant,
             apply(scene_caller, :commit, [
               participant,
               transaction.transaction_id,
               scene_opts
             ])}

          {:error, _reason} = error ->
            {participant, error}
        end
      end)

    {:ok, transaction} =
      TransactionCoordinator.commit_decision(
        coordinator,
        transaction.transaction_id,
        transaction.decision_version
      )

    emit("voxel_transaction_executor_committed", transaction, %{
      participant_count: length(participant_results)
    })

    {:ok,
     %{
       transaction: transaction,
       decision: :commit,
       participant_results: participant_results
     }}
  end

  defp run_abort(coordinator, transaction, prepare_results, scene_caller, scene_opts) do
    participant_results =
      Enum.map(prepare_results, fn {participant, prepare_result} ->
        case prepare_result do
          {:ok, _summary} ->
            {participant,
             apply(scene_caller, :abort, [
               participant,
               transaction.transaction_id,
               scene_opts
             ])}

          {:error, _reason} ->
            {participant, :ok}
        end
      end)

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
       participant_results: participant_results
     }}
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
end
