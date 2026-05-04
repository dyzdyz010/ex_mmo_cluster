defmodule WorldServer.Voxel.TransactionExecutorTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionExecutor
  alias WorldServer.Voxel.TransactionParticipant

  defmodule StubSceneCaller do
    def prepare(participant, transaction_id, intents_by_chunk, opts) do
      log_call(opts, {:prepare, participant.region_id, transaction_id, intents_by_chunk})

      Keyword.get(opts, :prepare_responses, %{})
      |> Map.get(participant.region_id, {:ok, %{prepared_chunks: []}})
    end

    def commit(participant, transaction_id, opts) do
      log_call(opts, {:commit, participant.region_id, transaction_id})
      {:ok, %{committed_chunks: []}}
    end

    def abort(participant, transaction_id, opts) do
      log_call(opts, {:abort, participant.region_id, transaction_id})
      :ok
    end

    defp log_call(opts, event) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} -> Agent.update(agent, &(&1 ++ [event]))
        :error -> :ok
      end
    end
  end

  test "commits when every participant prepares successfully" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(coordinator, transaction_attrs("tx-commit"))

    assert {:ok, %{decision: :commit, transaction: %BuildTransaction{state: :committed}}} =
             TransactionExecutor.execute(coordinator, transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts: [recorder: recorder]
             )

    calls = Agent.get(recorder, & &1)

    assert Enum.count(calls, fn
             {:prepare, _, _, _} -> true
             _ -> false
           end) == 2

    assert Enum.count(calls, fn
             {:commit, _, _} -> true
             _ -> false
           end) == 2

    refute Enum.any?(calls, fn
             {:abort, _, _} -> true
             _ -> false
           end)
  end

  test "aborts every prepared participant when one prepare fails" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(coordinator, transaction_attrs("tx-abort"))

    assert {:ok, %{decision: :abort, transaction: %BuildTransaction{state: :aborted}}} =
             TransactionExecutor.execute(coordinator, transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts: [
                 recorder: recorder,
                 prepare_responses: %{20 => {:error, {:prepare_failed, {2, 0, 0}, :stale_lease}}}
               ]
             )

    calls = Agent.get(recorder, & &1)

    # Both participants get prepare attempts.
    assert Enum.count(calls, fn
             {:prepare, _, _, _} -> true
             _ -> false
           end) == 2

    # Only the one that prepared OK (region 10) gets abort. The one that failed
    # prepare (region 20) does not need abort since it never held a fence.
    abort_regions =
      for {:abort, region, _tx} <- calls, do: region

    assert abort_regions == [10]

    refute Enum.any?(calls, fn
             {:commit, _, _} -> true
             _ -> false
           end)
  end

  test "aborts cleanly when all participants fail prepare" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(coordinator, transaction_attrs("tx-all-fail"))

    assert {:ok, %{decision: :abort, transaction: %BuildTransaction{state: :aborted}}} =
             TransactionExecutor.execute(coordinator, transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts: [
                 recorder: recorder,
                 prepare_responses: %{
                   10 => {:error, :stale_lease},
                   20 => {:error, :stale_lease}
                 }
               ]
             )

    calls = Agent.get(recorder, & &1)

    refute Enum.any?(calls, fn
             {:abort, _, _} -> true
             _ -> false
           end)

    refute Enum.any?(calls, fn
             {:commit, _, _} -> true
             _ -> false
           end)
  end

  test "is idempotent for replay of an already-committed transaction" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(coordinator, transaction_attrs("tx-replay"))

    assert {:ok, _result} =
             TransactionExecutor.execute(coordinator, transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts: [recorder: recorder]
             )

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.transactions["tx-replay"].state == :committed
    assert snapshot.decision_index["tx-replay"].decision == :commit

    # Replaying begin_transaction returns the existing transaction with the
    # same decision_version, and another execute call must not change the
    # recorded decision.
    {:ok, replay_transaction} =
      TransactionCoordinator.begin_transaction(coordinator, transaction_attrs("tx-replay"))

    assert replay_transaction.state == :committed

    assert {:ok, %{decision: :commit}} =
             TransactionExecutor.execute(coordinator, replay_transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts: [recorder: recorder]
             )

    second_snapshot = TransactionCoordinator.snapshot(coordinator)
    assert second_snapshot.decision_index["tx-replay"].decision == :commit
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
      participants: [
        %TransactionParticipant{
          region_id: 10,
          lease_id: 100,
          owner_scene_instance_ref: 1_000,
          owner_epoch: 1,
          affected_chunks: [{0, 0, 0}]
        },
        %TransactionParticipant{
          region_id: 20,
          lease_id: 200,
          owner_scene_instance_ref: 2_000,
          owner_epoch: 1,
          affected_chunks: [{2, 0, 0}]
        }
      ]
    }
  end
end
