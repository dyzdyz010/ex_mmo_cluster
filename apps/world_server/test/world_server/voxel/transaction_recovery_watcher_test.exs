defmodule WorldServer.Voxel.TransactionRecoveryWatcherTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant
  alias WorldServer.Voxel.TransactionRecoveryWatcher

  describe "recover/1" do
    test "aborts transactions stuck in :preparing" do
      coordinator = start_supervised!(TransactionCoordinator)

      assert {:ok, %BuildTransaction{state: :preparing}} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-preparing")
               )

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{aborted: 1, pending_commit: 0, finalized: 0, abort_failed: 0}

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-preparing"].state == :aborted
      assert snapshot.decision_index["tx-preparing"].decision == :abort
    end

    test "aborts transactions stuck in :aborting" do
      coordinator = start_supervised!(TransactionCoordinator)

      assert {:ok, _transaction} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-aborting")
               )

      assert {:ok, %BuildTransaction{state: :aborting}} =
               TransactionCoordinator.prepare_ack(coordinator, "tx-aborting", %{
                 region_id: 10,
                 lease_id: 100,
                 status: :failed,
                 acked_at_ms: 1
               })

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{aborted: 1, pending_commit: 0, finalized: 0, abort_failed: 0}

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-aborting"].state == :aborted
    end

    test "leaves :prepared transactions parked and counts pending_commit" do
      coordinator = start_supervised!(TransactionCoordinator)
      prepare_all!(coordinator, "tx-prepared")

      assert TransactionCoordinator.snapshot(coordinator).transactions["tx-prepared"].state ==
               :prepared

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{aborted: 0, pending_commit: 1, finalized: 0, abort_failed: 0}

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-prepared"].state == :prepared
      refute Map.has_key?(snapshot.decision_index, "tx-prepared")
    end

    test "skips already-finalized :committed and :aborted transactions" do
      coordinator = start_supervised!(TransactionCoordinator)

      prepare_all!(coordinator, "tx-committed")

      assert {:ok, _} =
               TransactionCoordinator.commit_decision(coordinator, "tx-committed", 1)

      assert {:ok, _} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-already-aborted")
               )

      assert {:ok, _} =
               TransactionCoordinator.abort_decision(coordinator, "tx-already-aborted", 1)

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{aborted: 0, pending_commit: 0, finalized: 2, abort_failed: 0}

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-committed"].state == :committed
      assert snapshot.transactions["tx-already-aborted"].state == :aborted
    end

    test "mixed in-flight transactions are swept in one pass" do
      coordinator = start_supervised!(TransactionCoordinator)

      assert {:ok, _} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-mixed-preparing")
               )

      prepare_all!(coordinator, "tx-mixed-prepared")
      prepare_all!(coordinator, "tx-mixed-committed")

      assert {:ok, _} =
               TransactionCoordinator.commit_decision(coordinator, "tx-mixed-committed", 1)

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{aborted: 1, pending_commit: 1, finalized: 1, abort_failed: 0}

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-mixed-preparing"].state == :aborted
      assert snapshot.transactions["tx-mixed-prepared"].state == :prepared
      assert snapshot.transactions["tx-mixed-committed"].state == :committed
    end

    test "sweeping an empty coordinator is a no-op" do
      coordinator = start_supervised!(TransactionCoordinator)

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{aborted: 0, pending_commit: 0, finalized: 0, abort_failed: 0}
    end
  end

  describe "supervised init" do
    test "running watcher under supervisor sweeps once at startup" do
      coordinator =
        start_supervised!({TransactionCoordinator, name: :recovery_watcher_init_coord},
          id: :recovery_watcher_init_coord
        )

      assert {:ok, _} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-supervised-preparing")
               )

      _watcher =
        start_supervised!(
          {TransactionRecoveryWatcher, coordinator: coordinator},
          id: :recovery_watcher_init_watcher
        )

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-supervised-preparing"].state == :aborted
    end
  end

  defp prepare_all!(coordinator, transaction_id) do
    assert {:ok, _} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs(transaction_id)
             )

    assert {:ok, _} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 1
             })

    assert {:ok, %BuildTransaction{state: :prepared}} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               region_id: 20,
               lease_id: 200,
               status: :prepared,
               acked_at_ms: 2
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
