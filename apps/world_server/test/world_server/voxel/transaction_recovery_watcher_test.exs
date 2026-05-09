defmodule WorldServer.Voxel.TransactionRecoveryWatcherTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant
  alias WorldServer.Voxel.TransactionRecoveryWatcher

  defmodule StubSceneCaller do
    def commit(participant, transaction_id, opts) do
      log(opts, {:commit, participant.region_id, transaction_id})

      case Map.get(Keyword.get(opts, :commit_responses, %{}), participant.region_id) do
        nil -> {:ok, %{committed_chunks: []}}
        response -> response
      end
    end

    def abort(participant, transaction_id, opts) do
      log(opts, {:abort, participant.region_id, transaction_id})
      :ok
    end

    def prepare(_participant, _transaction_id, _intents_by_chunk, _opts) do
      raise "StubSceneCaller.prepare must not be invoked on the :prepared fast-path"
    end

    defp log(opts, event) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} -> Agent.update(agent, &(&1 ++ [event]))
        :error -> :ok
      end
    end
  end

  describe "recover/1" do
    test "aborts transactions stuck in :preparing" do
      coordinator = start_supervised!(TransactionCoordinator)

      assert {:ok, %BuildTransaction{state: :preparing}} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-preparing")
               )

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary.aborted == 1
      assert summary.pending_commit == 0
      assert summary.finalized == 0
      assert summary.abort_failed == 0
      assert summary.resumed_commit == 0
      assert summary.resume_partial == 0
      assert summary.resume_failed == 0

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

      assert summary.aborted == 1
      assert summary.pending_commit == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-aborting"].state == :aborted
    end

    test "leaves :prepared transactions parked and counts pending_commit" do
      coordinator = start_supervised!(TransactionCoordinator)
      prepare_all!(coordinator, "tx-prepared")

      assert TransactionCoordinator.snapshot(coordinator).transactions["tx-prepared"].state ==
               :prepared

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary.pending_commit == 1
      assert summary.resumed_commit == 0

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

      assert summary.finalized == 2
      assert summary.aborted == 0

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

      assert summary.aborted == 1
      assert summary.pending_commit == 1
      assert summary.finalized == 1

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-mixed-preparing"].state == :aborted
      assert snapshot.transactions["tx-mixed-prepared"].state == :prepared
      assert snapshot.transactions["tx-mixed-committed"].state == :committed
    end

    test "sweeping an empty coordinator is a no-op" do
      coordinator = start_supervised!(TransactionCoordinator)

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary == %{
               aborted: 0,
               pending_commit: 0,
               finalized: 0,
               abort_failed: 0,
               resumed_commit: 0,
               resume_partial: 0,
               resume_failed: 0
             }
    end
  end

  describe "Phase 3-bis :prepared resume" do
    test "without a resolver, :prepared transactions stay parked" do
      coordinator = start_supervised!(TransactionCoordinator)
      prepare_all!(coordinator, "tx-no-resolver", with_intents: true)

      summary = TransactionRecoveryWatcher.recover(coordinator)
      assert summary.pending_commit == 1
      assert summary.resumed_commit == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-no-resolver"].state == :prepared
    end

    test "with a resolver, :prepared dispatches commit through the executor" do
      coordinator = start_supervised!(TransactionCoordinator)
      recorder = start_supervised!({Agent, fn -> [] end})
      prepare_all!(coordinator, "tx-resume", with_intents: true)

      pre_sweep = TransactionCoordinator.snapshot(coordinator).transactions["tx-resume"]
      assert pre_sweep.state == :prepared
      assert pre_sweep.intents_by_participant != %{}

      resolver = fn participants ->
        scene_opts_by_participant =
          Map.new(participants, fn p ->
            {{p.region_id, p.lease_id}, [recorder: recorder]}
          end)

        {:ok, scene_caller: StubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
      end

      summary =
        TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)

      assert summary.resumed_commit == 1
      assert summary.pending_commit == 0

      calls = Agent.get(recorder, & &1)
      assert Enum.count(calls, &match?({:commit, _, "tx-resume"}, &1)) == 2

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-resume"].state == :committed
    end

    test "resolver errors keep the transaction parked and emit unavailable" do
      coordinator = start_supervised!(TransactionCoordinator)
      prepare_all!(coordinator, "tx-resume-unavailable", with_intents: true)

      resolver = fn _participants -> {:error, :scene_unavailable} end

      summary =
        TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)

      assert summary.pending_commit == 1
      assert summary.resumed_commit == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-resume-unavailable"].state == :prepared
    end

    test "missing intents_by_participant falls back to pending_commit even with a resolver" do
      coordinator = start_supervised!(TransactionCoordinator)
      prepare_all!(coordinator, "tx-no-intents", with_intents: false)

      resolver = fn participants ->
        scene_opts_by_participant =
          Map.new(participants, fn p -> {{p.region_id, p.lease_id}, []} end)

        {:ok, scene_caller: StubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
      end

      summary =
        TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)

      assert summary.pending_commit == 1
      assert summary.resumed_commit == 0
    end

    test "partial commit failures bubble up as resume_partial" do
      coordinator = start_supervised!(TransactionCoordinator)
      recorder = start_supervised!({Agent, fn -> [] end})
      prepare_all!(coordinator, "tx-resume-partial", with_intents: true)

      resolver = fn participants ->
        scene_opts_by_participant =
          Map.new(participants, fn p ->
            {{p.region_id, p.lease_id},
             [recorder: recorder, commit_responses: %{20 => {:error, :commit_blew_up}}]}
          end)

        {:ok, scene_caller: StubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
      end

      summary =
        TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)

      assert summary.resume_partial == 1
      assert summary.resumed_commit == 0

      # Coordinator still reaches :committed state because the decision is
      # already past prepare; per-participant commit failures are surfaced
      # via observe but do not roll back the transaction.
      snapshot = TransactionCoordinator.snapshot(coordinator)
      assert snapshot.transactions["tx-resume-partial"].state == :committed
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

  defp prepare_all!(coordinator, transaction_id, opts \\ []) do
    base_attrs = transaction_attrs(transaction_id)

    attrs =
      if Keyword.get(opts, :with_intents, false) do
        Map.put(base_attrs, :intents_by_participant, %{
          {10, 100} => %{{0, 0, 0} => [%{operation: :put_solid_block, macro: 0}]},
          {20, 200} => %{{2, 0, 0} => [%{operation: :put_solid_block, macro: 1}]}
        })
      else
        base_attrs
      end

    assert {:ok, _} = TransactionCoordinator.begin_transaction(coordinator, attrs)

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
