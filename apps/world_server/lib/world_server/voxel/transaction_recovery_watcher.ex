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
  - `:prepared` transactions stay parked. The watcher emits a
    `voxel_transaction_recovery_pending_commit` observe event so operators (or
    a future Phase 3-bis auto-resume mechanism) can see which transactions
    need an explicit `commit_decision` to finish. We deliberately do not
    auto-commit here because the original `intents_by_participant` payload is
    not persisted in this phase.
  - `:committed` and `:aborted` transactions are already final and skipped.

  After the sweep the watcher stays alive (idle) so a `Supervisor` can keep it
  in its child list with the default permanent restart strategy. Restarts will
  re-run the sweep, which is safe: every action it takes is idempotent.
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator

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
  def recover(coordinator \\ TransactionCoordinator) do
    snapshot = TransactionCoordinator.snapshot(coordinator)
    summary = sweep(coordinator, snapshot.transactions)
    emit_summary(summary)
    summary
  end

  @impl true
  def init(opts) do
    coordinator = Keyword.get(opts, :coordinator, TransactionCoordinator)
    recover(coordinator)
    {:ok, %{coordinator: coordinator}}
  end

  defp sweep(coordinator, transactions) do
    Enum.reduce(
      transactions,
      %{aborted: 0, pending_commit: 0, finalized: 0, abort_failed: 0},
      fn {_transaction_id, transaction}, acc ->
        case handle_transaction(coordinator, transaction) do
          :aborted -> Map.update!(acc, :aborted, &(&1 + 1))
          :pending_commit -> Map.update!(acc, :pending_commit, &(&1 + 1))
          :finalized -> Map.update!(acc, :finalized, &(&1 + 1))
          :abort_failed -> Map.update!(acc, :abort_failed, &(&1 + 1))
        end
      end
    )
  end

  defp handle_transaction(coordinator, %BuildTransaction{state: state} = transaction)
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

  defp handle_transaction(_coordinator, %BuildTransaction{state: :prepared} = transaction) do
    emit("voxel_transaction_recovery_pending_commit", transaction, %{})
    :pending_commit
  end

  defp handle_transaction(_coordinator, %BuildTransaction{state: state} = _transaction)
       when state in [:committed, :aborted] do
    :finalized
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
