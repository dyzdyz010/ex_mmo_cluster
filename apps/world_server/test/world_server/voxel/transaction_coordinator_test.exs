defmodule WorldServer.Voxel.TransactionCoordinatorTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant

  test "moves to prepared after every participant prepares" do
    coordinator = start_supervised!(TransactionCoordinator)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-prepared")
             )

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-prepared", %{
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 1
             })

    assert {:ok, %BuildTransaction{state: :prepared, participants: participants}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-prepared", %{
               region_id: 20,
               lease_id: 200,
               status: :prepared,
               acked_at_ms: 2
             })

    assert Enum.all?(participants, &(&1.prepare_status == :prepared))

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.transactions["tx-prepared"].state == :prepared
  end

  test "failed prepare makes the transaction abortable" do
    coordinator = start_supervised!(TransactionCoordinator)

    assert {:ok, _transaction} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-abortable")
             )

    assert {:ok, %BuildTransaction{state: :aborting}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-abortable", %{
               region_id: 10,
               lease_id: 100,
               status: :failed,
               acked_at_ms: 3
             })

    assert {:ok, %BuildTransaction{state: :aborted, participants: participants}} =
             TransactionCoordinator.abort_decision(coordinator, "tx-abortable", 1)

    assert Enum.all?(participants, &(&1.commit_status == :aborted))

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-abortable"].decision == :abort

    assert {:ok, %BuildTransaction{state: :aborted}} =
             TransactionCoordinator.abort_decision(coordinator, "tx-abortable", 1)

    assert TransactionCoordinator.snapshot(coordinator) == snapshot
  end

  test "commit decision is idempotent for the same decision version" do
    coordinator = start_supervised!(TransactionCoordinator)

    prepare_all!(coordinator, "tx-commit")

    assert {:ok, %BuildTransaction{state: :committed} = committed} =
             TransactionCoordinator.commit_decision(coordinator, "tx-commit", 1)

    snapshot = TransactionCoordinator.snapshot(coordinator)

    assert {:ok, ^committed} =
             TransactionCoordinator.commit_decision(coordinator, "tx-commit", 1)

    assert TransactionCoordinator.snapshot(coordinator) == snapshot
  end

  test "commit before every participant prepared is rejected" do
    coordinator = start_supervised!(TransactionCoordinator)

    assert {:ok, _transaction} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-not-ready")
             )

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-not-ready", %{
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 4
             })

    assert {:error, :not_prepared} =
             TransactionCoordinator.commit_decision(coordinator, "tx-not-ready", 1)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.transactions["tx-not-ready"].state == :preparing
    assert snapshot.decisions == %{}
  end

  test "replaying the same transaction does not reset participant state" do
    coordinator = start_supervised!(TransactionCoordinator)
    attrs = transaction_attrs("tx-replay")

    assert {:ok, _transaction} = TransactionCoordinator.begin_transaction(coordinator, attrs)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-replay", %{
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 5
             })

    snapshot = TransactionCoordinator.snapshot(coordinator)

    assert {:ok, %BuildTransaction{state: :preparing, participants: participants}} =
             TransactionCoordinator.begin_transaction(coordinator, attrs)

    assert Enum.count(participants, &(&1.prepare_status == :prepared)) == 1
    assert TransactionCoordinator.snapshot(coordinator) == snapshot
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
