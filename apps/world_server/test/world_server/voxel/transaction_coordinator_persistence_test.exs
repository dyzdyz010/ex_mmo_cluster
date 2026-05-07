defmodule WorldServer.Voxel.TransactionCoordinatorPersistenceTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelTransactionCoordinatorSnapshot
  alias DataService.Voxel.TransactionCoordinatorStore
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant
  alias WorldServer.Voxel.TransactionRecoveryWatcher

  setup do
    Repo.delete_all(VoxelTransactionCoordinatorSnapshot)
    :ok
  end

  test "begin_transaction state survives restart through Postgres persistence" do
    coordinator = start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_coord)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-restart")
             )

    assert %VoxelTransactionCoordinatorSnapshot{payload: payload} =
             Repo.get(VoxelTransactionCoordinatorSnapshot, 1)

    assert is_binary(payload)
    assert byte_size(payload) > 0

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert Map.has_key?(snapshot.transactions, "tx-restart")

    stop_supervised!(:first_coord)

    revived = start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_coord)

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert Map.has_key?(revived_snapshot.transactions, "tx-restart")
    assert revived_snapshot.transactions["tx-restart"].state == :preparing

    # Replaying begin_transaction with the same fingerprint should return the
    # existing transaction (not raise :transaction_conflict).
    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               revived,
               transaction_attrs("tx-restart")
             )
  end

  test "commit decision_index survives restart through Postgres persistence" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_commit_coord)

    prepare_all!(coordinator, "tx-commit-restart")

    assert {:ok, %BuildTransaction{state: :committed}} =
             TransactionCoordinator.commit_decision(coordinator, "tx-commit-restart", 1)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-commit-restart"].decision == :commit

    stop_supervised!(:first_commit_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_commit_coord)

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.decision_index["tx-commit-restart"].decision == :commit
    assert revived_snapshot.transactions["tx-commit-restart"].state == :committed

    # Replaying the same commit pair must remain idempotent across restart.
    assert {:ok, %BuildTransaction{state: :committed}} =
             TransactionCoordinator.commit_decision(revived, "tx-commit-restart", 1)
  end

  test "abort decision is idempotent through restart" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_abort_coord)

    assert {:ok, _transaction} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-abort-restart")
             )

    assert {:ok, %BuildTransaction{state: :aborting}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-abort-restart", %{
               region_id: 10,
               lease_id: 100,
               status: :failed,
               acked_at_ms: 1
             })

    assert {:ok, %BuildTransaction{state: :aborted}} =
             TransactionCoordinator.abort_decision(coordinator, "tx-abort-restart", 1)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-abort-restart"].decision == :abort

    stop_supervised!(:first_abort_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_abort_coord)

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.decision_index["tx-abort-restart"].decision == :abort
    assert revived_snapshot.transactions["tx-abort-restart"].state == :aborted

    # Replaying the same abort pair after restart must remain idempotent.
    assert {:ok, %BuildTransaction{state: :aborted}} =
             TransactionCoordinator.abort_decision(revived, "tx-abort-restart", 1)

    assert TransactionCoordinator.snapshot(revived) == revived_snapshot
  end

  test "RecoveryWatcher aborts :preparing transaction after coordinator restart" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_recovery_coord)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-recovery-preparing")
             )

    stop_supervised!(:first_recovery_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_recovery_coord)

    revived_pre_sweep = TransactionCoordinator.snapshot(revived)
    assert revived_pre_sweep.transactions["tx-recovery-preparing"].state == :preparing

    _watcher =
      start_supervised!(
        {TransactionRecoveryWatcher, coordinator: revived},
        id: :recovery_watcher_for_revived
      )

    revived_post_sweep = TransactionCoordinator.snapshot(revived)
    assert revived_post_sweep.transactions["tx-recovery-preparing"].state == :aborted

    assert revived_post_sweep.decision_index["tx-recovery-preparing"].decision == :abort

    # The abort decision must have been written through to Postgres so that a
    # second restart cycle does not see the same transaction as :preparing.
    stop_supervised!(:recovery_watcher_for_revived)
    stop_supervised!(:revived_recovery_coord)

    final =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :final_recovery_coord)

    final_snapshot = TransactionCoordinator.snapshot(final)
    assert final_snapshot.transactions["tx-recovery-preparing"].state == :aborted
  end

  test "RecoveryWatcher leaves :prepared transaction parked after restart" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_parked_coord)

    prepare_all!(coordinator, "tx-recovery-prepared")

    assert TransactionCoordinator.snapshot(coordinator).transactions["tx-recovery-prepared"].state ==
             :prepared

    stop_supervised!(:first_parked_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_parked_coord)

    _watcher =
      start_supervised!(
        {TransactionRecoveryWatcher, coordinator: revived},
        id: :recovery_watcher_for_parked
      )

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.transactions["tx-recovery-prepared"].state == :prepared
    refute Map.has_key?(revived_snapshot.decision_index, "tx-recovery-prepared")
  end

  test "init survives an empty Postgres table" do
    refute Repo.get(VoxelTransactionCoordinatorSnapshot, 1)

    coordinator = start_supervised!({TransactionCoordinator, persist_opts()}, id: :empty_coord)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.transactions == %{}
    assert snapshot.decisions == %{}
    assert snapshot.decision_index == %{}
  end

  defp persist_opts do
    [
      persist_fn: TransactionCoordinatorStore.persist_fn(Repo),
      load_fn: TransactionCoordinatorStore.load_fn(Repo)
    ]
  end

  defp prepare_all!(coordinator, transaction_id) do
    assert {:ok, _transaction} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs(transaction_id)
             )

    assert {:ok, _transaction} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 6
             })

    assert {:ok, %BuildTransaction{state: :prepared}} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               region_id: 20,
               lease_id: 200,
               status: :prepared,
               acked_at_ms: 7
             })
  end

  defp transaction_attrs(transaction_id) do
    %{
      transaction_id: transaction_id,
      logical_scene_id: 1,
      parcel_id: 101,
      reservation_id: "reservation-#{transaction_id}",
      intent_hash: "intent-#{transaction_id}",
      decision_version: 1,
      timeout_at_ms: 1_900_000_000_000,
      participants: participants()
    }
  end

  defp participants do
    [
      %TransactionParticipant{
        region_id: 20,
        lease_id: 200,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 1,
        affected_chunks: [{2, 0, 0}]
      },
      %TransactionParticipant{
        region_id: 10,
        lease_id: 100,
        owner_scene_instance_ref: 1_000,
        owner_epoch: 1,
        affected_chunks: [{0, 0, 0}]
      }
    ]
  end
end
