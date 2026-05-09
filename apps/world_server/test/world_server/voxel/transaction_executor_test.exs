defmodule WorldServer.Voxel.TransactionExecutorTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionExecutor
  alias WorldServer.Voxel.TransactionParticipant

  defmodule StubSceneCaller do
    def prepare(participant, transaction_id, intents_by_chunk, opts) do
      log_call(opts, {:prepare, participant.region_id, transaction_id, intents_by_chunk})

      maybe_sleep(opts, :prepare_sleeps_ms, participant.region_id)
      maybe_raise(opts, :prepare_raises, participant.region_id)

      Keyword.get(opts, :prepare_responses, %{})
      |> Map.get(participant.region_id, {:ok, %{prepared_chunks: []}})
    end

    def commit(participant, transaction_id, opts) do
      log_call(opts, {:commit, participant.region_id, transaction_id})
      maybe_sleep(opts, :commit_sleeps_ms, participant.region_id)
      {:ok, %{committed_chunks: []}}
    end

    def abort(participant, transaction_id, opts) do
      log_call(opts, {:abort, participant.region_id, transaction_id})
      maybe_sleep(opts, :abort_sleeps_ms, participant.region_id)
      :ok
    end

    defp log_call(opts, event) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} -> Agent.update(agent, &(&1 ++ [event]))
        :error -> :ok
      end
    end

    defp maybe_sleep(opts, key, region_id) do
      sleeps = Keyword.get(opts, key, %{})

      case Map.get(sleeps, region_id) do
        nil -> :ok
        ms when is_integer(ms) -> Process.sleep(ms)
      end
    end

    defp maybe_raise(opts, key, region_id) do
      raises = Keyword.get(opts, key, %{})

      case Map.get(raises, region_id) do
        nil -> :ok
        reason -> raise reason
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
               scene_opts_by_participant: uniform_opts(recorder: recorder)
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
               scene_opts_by_participant:
                 uniform_opts(
                   recorder: recorder,
                   prepare_responses: %{
                     20 => {:error, {:prepare_failed, {2, 0, 0}, :stale_lease}}
                   }
                 )
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
               scene_opts_by_participant:
                 uniform_opts(
                   recorder: recorder,
                   prepare_responses: %{
                     10 => {:error, :stale_lease},
                     20 => {:error, :stale_lease}
                   }
                 )
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
               scene_opts_by_participant: uniform_opts(recorder: recorder)
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
               scene_opts_by_participant: uniform_opts(recorder: recorder)
             )

    second_snapshot = TransactionCoordinator.snapshot(coordinator)
    assert second_snapshot.decision_index["tx-replay"].decision == :commit
  end

  test "fails the slow participant on per-participant prepare timeout and aborts the prepared one" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(
        coordinator,
        transaction_attrs("tx-prepare-timeout")
      )

    assert {:ok, %{decision: :abort, prepare_results: prepare_results} = result} =
             TransactionExecutor.execute(coordinator, transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts_by_participant:
                 uniform_opts(
                   recorder: recorder,
                   # Region 20 sleeps longer than its per-participant budget.
                   prepare_sleeps_ms: %{20 => 200}
                 ),
               per_participant_timeout_ms: 50
             )

    assert result.transaction.state == :aborted

    prepare_by_region =
      Map.new(prepare_results, fn {participant, result} -> {participant.region_id, result} end)

    assert prepare_by_region[20] == {:error, :timeout}
    assert match?({:ok, _}, prepare_by_region[10])

    calls = Agent.get(recorder, & &1)

    # Region 10 prepared OK so it must receive an abort. Region 20 timed out
    # before returning, so it must NOT receive a commit.
    abort_regions =
      for {:abort, region, _tx} <- calls, do: region

    assert abort_regions == [10]

    refute Enum.any?(calls, fn
             {:commit, _, _} -> true
             _ -> false
           end)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    persisted = snapshot.transactions["tx-prepare-timeout"]

    assert persisted.state == :aborted

    region_20_status =
      persisted.participants
      |> Enum.find(&(&1.region_id == 20))
      |> Map.get(:prepare_status)

    assert region_20_status == :failed
  end

  test "treats a participant prepare crash as :failed and aborts the transaction" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(
        coordinator,
        transaction_attrs("tx-prepare-crash")
      )

    # Silence the unavoidable Task crash report so the test output stays clean.
    ExUnit.CaptureLog.with_log(fn ->
      assert {:ok, %{decision: :abort, prepare_results: prepare_results} = result} =
               TransactionExecutor.execute(coordinator, transaction, %{},
                 scene_caller: StubSceneCaller,
                 scene_opts_by_participant:
                   uniform_opts(
                     recorder: recorder,
                     prepare_raises: %{20 => "boom in prepare"}
                   )
               )

      assert result.transaction.state == :aborted

      prepare_by_region =
        Map.new(prepare_results, fn {participant, result} -> {participant.region_id, result} end)

      assert match?({:error, {:participant_crashed, _}}, prepare_by_region[20])
      assert match?({:ok, _}, prepare_by_region[10])
    end)
  end

  test "abandons every participant when the overall transaction timeout elapses" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(
        coordinator,
        transaction_attrs("tx-overall-timeout")
      )

    assert {:ok, %{decision: :abort, prepare_results: prepare_results} = result} =
             TransactionExecutor.execute(coordinator, transaction, %{},
               scene_caller: StubSceneCaller,
               scene_opts_by_participant:
                 uniform_opts(
                   recorder: recorder,
                   prepare_sleeps_ms: %{10 => 1_000, 20 => 1_000}
                 ),
               per_participant_timeout_ms: 5_000,
               transaction_timeout_ms: 50
             )

    assert result.transaction.state == :aborted

    # Every participant must end up :failed at the executor layer; the
    # specific reason can be either :timeout (per-item kill triggered first)
    # or :transaction_timeout (overall deadline cut the stream loose). Both
    # are valid "abandoned" outcomes for the spec.
    for {_participant, prepare_result} <- prepare_results do
      assert match?(
               {:error, reason} when reason in [:timeout, :transaction_timeout],
               prepare_result
             )
    end

    snapshot = TransactionCoordinator.snapshot(coordinator)
    persisted = snapshot.transactions["tx-overall-timeout"]

    assert persisted.state == :aborted

    for participant <- persisted.participants do
      assert participant.prepare_status == :failed
    end
  end

  describe "Phase A4-1 per-participant scene_opts" do
    test "feeds each participant its own scene_opts during prepare / commit" do
      coordinator = start_supervised!(TransactionCoordinator)
      recorder_a = start_supervised!({Agent, fn -> [] end}, id: :recorder_a)
      recorder_b = start_supervised!({Agent, fn -> [] end}, id: :recorder_b)

      {:ok, transaction} =
        TransactionCoordinator.begin_transaction(
          coordinator,
          transaction_attrs("tx-per-participant-opts")
        )

      # Each participant gets its own recorder. After execute we must see
      # *exactly one* prepare event in each recorder, addressed to its own
      # region — proving the executor routed per-participant opts correctly.
      assert {:ok, %{decision: :commit}} =
               TransactionExecutor.execute(coordinator, transaction, %{},
                 scene_caller: StubSceneCaller,
                 scene_opts_by_participant: %{
                   {10, 100} => [recorder: recorder_a],
                   {20, 200} => [recorder: recorder_b]
                 }
               )

      calls_a = Agent.get(recorder_a, & &1)
      calls_b = Agent.get(recorder_b, & &1)

      assert Enum.count(calls_a, &match?({:prepare, 10, _, _}, &1)) == 1
      assert Enum.count(calls_a, &match?({:commit, 10, _}, &1)) == 1
      refute Enum.any?(calls_a, &match?({:prepare, 20, _, _}, &1))
      refute Enum.any?(calls_a, &match?({:commit, 20, _}, &1))

      assert Enum.count(calls_b, &match?({:prepare, 20, _, _}, &1)) == 1
      assert Enum.count(calls_b, &match?({:commit, 20, _}, &1)) == 1
      refute Enum.any?(calls_b, &match?({:prepare, 10, _, _}, &1))
      refute Enum.any?(calls_b, &match?({:commit, 10, _}, &1))
    end

    test "raises when :scene_opts_by_participant is missing (no double-path with old :scene_opts)" do
      coordinator = start_supervised!(TransactionCoordinator)

      {:ok, transaction} =
        TransactionCoordinator.begin_transaction(
          coordinator,
          transaction_attrs("tx-missing-opts")
        )

      assert_raise ArgumentError, ~r/scene_opts_by_participant/, fn ->
        TransactionExecutor.execute(coordinator, transaction, %{}, scene_caller: StubSceneCaller)
      end
    end

    test "raises when a participant has no entry in scene_opts_by_participant" do
      coordinator = start_supervised!(TransactionCoordinator)

      {:ok, transaction} =
        TransactionCoordinator.begin_transaction(
          coordinator,
          transaction_attrs("tx-partial-opts")
        )

      assert_raise ArgumentError, ~r/missing scene_opts.*\{20, 200\}/, fn ->
        TransactionExecutor.execute(coordinator, transaction, %{},
          scene_caller: StubSceneCaller,
          scene_opts_by_participant: %{{10, 100} => []}
        )
      end
    end
  end

  test "runs prepare in parallel: total wall-clock time is well under sequential" do
    coordinator = start_supervised!(TransactionCoordinator)
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, transaction} =
      TransactionCoordinator.begin_transaction(
        coordinator,
        transaction_attrs("tx-parallel")
      )

    {time_us, {:ok, %{decision: :commit}}} =
      :timer.tc(fn ->
        TransactionExecutor.execute(coordinator, transaction, %{},
          scene_caller: StubSceneCaller,
          scene_opts_by_participant:
            uniform_opts(
              recorder: recorder,
              prepare_sleeps_ms: %{10 => 200, 20 => 200}
            ),
          per_participant_timeout_ms: 1_000,
          transaction_timeout_ms: 5_000
        )
      end)

    elapsed_ms = div(time_us, 1_000)

    # Sequential would be >= 400ms (200 + 200). Parallel should be just
    # above 200ms with a slack budget for scheduling, BEAM startup, and
    # the synchronous coordinator GenServer round-trips. We allow up to 350ms.
    assert elapsed_ms < 350,
           "expected parallel prepare to finish in < 350ms, got #{elapsed_ms}ms"
  end

  describe "Phase 3-bis :prepared fast-path" do
    test "skips prepare dispatch and runs commit directly when transaction is already :prepared" do
      coordinator = start_supervised!(TransactionCoordinator)
      recorder = start_supervised!({Agent, fn -> [] end})

      {:ok, transaction} =
        TransactionCoordinator.begin_transaction(coordinator, transaction_attrs("tx-resume"))

      # Push the transaction to :prepared via direct prepare_ack (simulates
      # the coordinator state we'd reload from Postgres after a crash that
      # happened between :prepared and commit dispatch).
      assert {:ok, _} =
               TransactionCoordinator.prepare_ack(coordinator, transaction.transaction_id, %{
                 region_id: 10,
                 lease_id: 100,
                 status: :prepared,
                 acked_at_ms: 1
               })

      assert {:ok, %BuildTransaction{state: :prepared} = prepared} =
               TransactionCoordinator.prepare_ack(coordinator, transaction.transaction_id, %{
                 region_id: 20,
                 lease_id: 200,
                 status: :prepared,
                 acked_at_ms: 2
               })

      assert {:ok,
              %{
                decision: :commit,
                transaction: %BuildTransaction{state: :committed},
                participant_results: results,
                prepare_results: prepare_results
              }} =
               TransactionExecutor.execute(coordinator, prepared, %{},
                 scene_caller: StubSceneCaller,
                 scene_opts_by_participant: uniform_opts(recorder: recorder)
               )

      # No prepare calls should have hit the scene caller — the executor
      # short-circuited that phase.
      calls = Agent.get(recorder, & &1)
      refute Enum.any?(calls, &match?({:prepare, _, _, _}, &1))

      # Commit was dispatched for both participants.
      assert Enum.count(calls, &match?({:commit, _, _}, &1)) == 2

      # Synthetic prepare_results carry the resumed? marker.
      assert Enum.all?(prepare_results, fn {_participant, outcome} ->
               match?({:ok, %{resumed?: true}}, outcome)
             end)

      assert Enum.count(results, &match?({_p, {:ok, _}}, &1)) == 2
    end

    test "marks failed prepare participants as prepare_failed_before_resume" do
      coordinator = start_supervised!(TransactionCoordinator)
      recorder = start_supervised!({Agent, fn -> [] end})

      attrs = transaction_attrs("tx-resume-mixed")
      {:ok, _transaction} = TransactionCoordinator.begin_transaction(coordinator, attrs)

      # One participant prepared, the other failed — coordinator transitions
      # to :aborting, not :prepared. We force it to :prepared in this test by
      # only acking the prepared one and not the other; that leaves state
      # :preparing. Switch the test to :prepared by acking both as prepared
      # then mutating one's prepare_status via a direct snapshot inspection
      # is brittle, so instead test the :failed-before-resume path through
      # `derive_prepare_results_from_prepared_state` with a hand-rolled
      # transaction that has `:prepared` overall but a participant whose
      # status is anomalous.
      assert {:ok, _} =
               TransactionCoordinator.prepare_ack(coordinator, "tx-resume-mixed", %{
                 region_id: 10,
                 lease_id: 100,
                 status: :prepared,
                 acked_at_ms: 1
               })

      assert {:ok, prepared} =
               TransactionCoordinator.prepare_ack(coordinator, "tx-resume-mixed", %{
                 region_id: 20,
                 lease_id: 200,
                 status: :prepared,
                 acked_at_ms: 2
               })

      # Force one participant's status to :failed while keeping transaction
      # state == :prepared. This shape can occur after a crash recovery
      # where a participant was reverted while the transaction stayed
      # in the prepared bucket; the executor must not redispatch commit on it.
      forced_transaction = force_participant_failure(prepared, 20)

      assert {:ok, %{participant_results: results, prepare_results: prepare_results}} =
               TransactionExecutor.execute(coordinator, forced_transaction, %{},
                 scene_caller: StubSceneCaller,
                 scene_opts_by_participant: uniform_opts(recorder: recorder)
               )

      assert {_failed_p, {:error, :prepare_failed_before_resume}} =
               Enum.find(prepare_results, fn {p, _} -> p.region_id == 20 end)

      # Only the prepared participant got a commit dispatch.
      calls = Agent.get(recorder, & &1)
      assert Enum.count(calls, &match?({:commit, 10, _}, &1)) == 1
      refute Enum.any?(calls, &match?({:commit, 20, _}, &1))

      # The participant that was already failed shows up in participant_results
      # carrying the same prepare-time error.
      assert {_failed_p, {:error, :prepare_failed_before_resume}} =
               Enum.find(results, fn {p, _} -> p.region_id == 20 end)
    end
  end

  # Uniform helper: every participant in `transaction_attrs/1` gets the same
  # base opts. Multi-region tests (A4-1 onward) inject per-participant opts
  # directly via the by_participant map.
  defp uniform_opts(base_opts) do
    %{
      {10, 100} => base_opts,
      {20, 200} => base_opts
    }
  end

  defp force_participant_failure(transaction, region_id) do
    participants =
      Enum.map(transaction.participants, fn participant ->
        if participant.region_id == region_id do
          %{participant | prepare_status: :failed}
        else
          participant
        end
      end)

    %{transaction | participants: participants}
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
