defmodule WorldServer.Voxel.TransactionCoordinatorPersistenceTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant

  setup do
    tmp_dir = System.tmp_dir!()
    name = "voxel_transaction_coordinator_#{System.unique_integer([:positive, :monotonic])}.bin"
    path = Path.join(tmp_dir, name)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "begin_transaction state survives restart through file persistence", %{path: path} do
    coordinator =
      start_supervised!({TransactionCoordinator, persistence_path: path}, id: :first_coord)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-restart")
             )

    assert File.exists?(path)
    payload = File.read!(path)
    assert byte_size(payload) > 0

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert Map.has_key?(snapshot.transactions, "tx-restart")

    stop_supervised!(:first_coord)

    revived =
      start_supervised!({TransactionCoordinator, persistence_path: path}, id: :revived_coord)

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

  test "commit decision_index survives restart through file persistence", %{path: path} do
    coordinator =
      start_supervised!({TransactionCoordinator, persistence_path: path}, id: :first_commit_coord)

    prepare_all!(coordinator, "tx-commit-restart")

    assert {:ok, %BuildTransaction{state: :committed}} =
             TransactionCoordinator.commit_decision(coordinator, "tx-commit-restart", 1)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-commit-restart"].decision == :commit

    stop_supervised!(:first_commit_coord)

    revived =
      start_supervised!({TransactionCoordinator, persistence_path: path},
        id: :revived_commit_coord
      )

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.decision_index["tx-commit-restart"].decision == :commit
    assert revived_snapshot.transactions["tx-commit-restart"].state == :committed

    # Replaying the same commit pair must remain idempotent across restart.
    assert {:ok, %BuildTransaction{state: :committed}} =
             TransactionCoordinator.commit_decision(revived, "tx-commit-restart", 1)
  end

  test "abort decision is idempotent through restart", %{path: path} do
    coordinator =
      start_supervised!({TransactionCoordinator, persistence_path: path}, id: :first_abort_coord)

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
      start_supervised!({TransactionCoordinator, persistence_path: path},
        id: :revived_abort_coord
      )

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.decision_index["tx-abort-restart"].decision == :abort
    assert revived_snapshot.transactions["tx-abort-restart"].state == :aborted

    # Replaying the same abort pair after restart must remain idempotent.
    assert {:ok, %BuildTransaction{state: :aborted}} =
             TransactionCoordinator.abort_decision(revived, "tx-abort-restart", 1)

    assert TransactionCoordinator.snapshot(revived) == revived_snapshot
  end

  test "init survives an empty/missing persistence file", %{path: path} do
    refute File.exists?(path)

    coordinator =
      start_supervised!({TransactionCoordinator, persistence_path: path}, id: :empty_coord)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.transactions == %{}
    assert snapshot.decisions == %{}
    assert snapshot.decision_index == %{}
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
