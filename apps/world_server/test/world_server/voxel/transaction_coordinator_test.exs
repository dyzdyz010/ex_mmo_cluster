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
               participant_key: {10, 100},
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 1
             })

    assert {:ok, %BuildTransaction{state: :prepared, participants: participants}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-prepared", %{
               participant_key: {20, 200},
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
               participant_key: {10, 100},
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
               participant_key: {10, 100},
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
               participant_key: {10, 100},
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

  describe "intents_by_participant (Phase 3-bis)" do
    test "defaults to %{} when caller does not pass it" do
      coordinator = start_supervised!(TransactionCoordinator)

      assert {:ok, %BuildTransaction{intents_by_participant: %{}}} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-no-intents")
               )
    end

    test "round-trips the supplied intents_by_participant on begin_transaction" do
      coordinator = start_supervised!(TransactionCoordinator)
      attrs = Map.put(transaction_attrs("tx-with-intents"), :intents_by_participant, intents())

      assert {:ok, %BuildTransaction{intents_by_participant: stored}} =
               TransactionCoordinator.begin_transaction(coordinator, attrs)

      assert stored == intents()

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-with-intents"].intents_by_participant == intents()
    end

    test "begin_fingerprint ignores intents — replay returns the original transaction" do
      coordinator = start_supervised!(TransactionCoordinator)
      first_attrs = Map.put(transaction_attrs("tx-replay-intents"), :intents_by_participant, %{})

      assert {:ok, %BuildTransaction{intents_by_participant: %{}}} =
               TransactionCoordinator.begin_transaction(coordinator, first_attrs)

      # Replay with a different intents map — same identity / fingerprint, so
      # the coordinator returns the original transaction without overwriting
      # intents.
      replay_attrs = Map.put(first_attrs, :intents_by_participant, intents())

      assert {:ok, %BuildTransaction{intents_by_participant: %{}}} =
               TransactionCoordinator.begin_transaction(coordinator, replay_attrs)
    end

    test "rejects a non-map intents_by_participant" do
      coordinator = start_supervised!(TransactionCoordinator)
      attrs = Map.put(transaction_attrs("tx-bad-intents"), :intents_by_participant, :nope)

      assert {:error, :invalid_intents_by_participant} =
               TransactionCoordinator.begin_transaction(coordinator, attrs)
    end
  end

  test "Scene-owner participant_key drives prepare ack while chunk_owners derive object owner" do
    participant_key = {:scene_owner, :chunk_directory_a, :scene_a}

    coordinator =
      start_supervised!(
        {TransactionCoordinator,
         name: :"coord_#{System.unique_integer([:positive])}",
         next_object_id_fn: fn -> {:ok, 9_001} end}
      )

    attrs =
      transaction_attrs("tx-scene-owner")
      |> Map.put(:participants, [
        %TransactionParticipant{
          participant_key: participant_key,
          region_id: 10,
          lease_id: 100,
          owner_scene_instance_ref: 1_000,
          owner_epoch: 1,
          assigned_scene_node: :scene_a,
          affected_chunks: [{0, 0, 0}, {2, 0, 0}],
          chunk_owners: %{
            {0, 0, 0} => {10, 100},
            {2, 0, 0} => {20, 200}
          }
        }
      ])
      |> Map.put(:scene_objects, [
        scene_object_seed(blueprint_id: 71, covered_chunks: [{2, 0, 0}])
      ])

    assert {:ok,
            %BuildTransaction{
              state: :preparing,
              participants: [participant],
              scene_objects: [scene_object]
            }} = TransactionCoordinator.begin_transaction(coordinator, attrs)

    assert participant.participant_key == participant_key
    assert scene_object.owner_region_id == 20
    assert scene_object.owner_lease_id == 200

    assert {:ok, %BuildTransaction{state: :prepared}} =
             TransactionCoordinator.prepare_ack(coordinator, "tx-scene-owner", %{
               participant_key: participant_key,
               status: :prepared,
               acked_at_ms: 9
             })
  end

  defp prepare_all!(coordinator, transaction_id) do
    assert {:ok, _transaction} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs(transaction_id)
             )

    assert {:ok, _transaction} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               participant_key: {10, 100},
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 6
             })

    assert {:ok, %BuildTransaction{state: :prepared}} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               participant_key: {20, 200},
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
        participant_key: {20, 200},
        region_id: 20,
        lease_id: 200,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 1,
        assigned_scene_node: :scene_b,
        affected_chunks: [{2, 0, 0}],
        chunk_owners: %{{2, 0, 0} => {20, 200}}
      },
      %TransactionParticipant{
        participant_key: {10, 100},
        region_id: 10,
        lease_id: 100,
        owner_scene_instance_ref: 1_000,
        owner_epoch: 1,
        assigned_scene_node: :scene_a,
        affected_chunks: [{0, 0, 0}],
        chunk_owners: %{{0, 0, 0} => {10, 100}}
      }
    ]
  end

  defp intents do
    %{
      {10, 100} => %{
        {0, 0, 0} => [%{operation: :put_solid_block, macro: 0}]
      },
      {20, 200} => %{
        {2, 0, 0} => [%{operation: :put_solid_block, macro: 1}]
      }
    }
  end

  defp scene_object_seed(overrides) do
    base = %{
      blueprint_id: 7,
      blueprint_version: 1,
      parcel_id: 13,
      anchor_world_micro: {0, 0, 0},
      rotation: 0,
      owner_actor_id: 1_001,
      covered_chunks: [{0, 0, 0}],
      part_states: [%{part_id: 1, health: 80, state_flags: 0}],
      object_version: 1
    }

    Map.merge(base, Map.new(overrides))
  end
end
