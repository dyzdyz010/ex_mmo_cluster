defmodule WorldServer.Voxel.TransactionRecoveryWatcherTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant
  alias WorldServer.Voxel.TransactionRecoveryWatcher

  defmodule StubSceneCaller do
    def commit(participant, transaction_id, opts) do
      log(opts, {:commit, participant.region_id, transaction_id})

      # 阶段4 / world-2pc-3 契约#3:durable-ack 必须显式 `durable?: true`。
      case Map.get(Keyword.get(opts, :commit_responses, %{}), participant.region_id) do
        nil -> {:ok, %{committed_chunks: [], durable?: true}}
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

  # 故障注入③专用:commit response 由一个 0-arity 函数动态产出,可在多轮
  # re-投递间改变(第一次失败、第二次成功),用于验证"重投递直至成功"。
  defmodule DynamicStubSceneCaller do
    def commit(participant, transaction_id, opts) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} -> Agent.update(agent, &(&1 ++ [{:commit, participant.region_id, transaction_id}]))
        :error -> :ok
      end

      case Keyword.get(opts, :dynamic_commit_response) do
        nil -> {:ok, %{committed_chunks: [], durable?: true}}
        fun when is_function(fun, 0) -> fun.()
      end
    end

    def abort(_participant, _transaction_id, _opts), do: :ok

    def prepare(_participant, _transaction_id, _intents, _opts) do
      raise "DynamicStubSceneCaller.prepare must not be invoked on resume"
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

      # 阶段4 / world-2pc-4:aborted 事务被裁出活跃集,只在 decision_index 留归档。
      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-preparing")
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
                 participant_key: {10, 100},
                 region_id: 10,
                 lease_id: 100,
                 status: :failed,
                 acked_at_ms: 1
               })

      summary = TransactionRecoveryWatcher.recover(coordinator)

      assert summary.aborted == 1
      assert summary.pending_commit == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-aborting")
      assert snapshot.decision_index["tx-aborting"].decision == :abort
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

    test "skips already-finalized :committed and :aborted transactions (now archived out of active)" do
      coordinator = start_supervised!(TransactionCoordinator)

      # 阶段4 / world-2pc-3:到 :committed 需 commit_decision + 全 durable-ack。
      commit_all!(coordinator, "tx-committed")

      assert {:ok, _} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 transaction_attrs("tx-already-aborted")
               )

      assert {:ok, _} =
               TransactionCoordinator.abort_decision(coordinator, "tx-already-aborted", 1)

      summary = TransactionRecoveryWatcher.recover(coordinator)

      # 终态事务都已被裁出活跃集 → sweep 看不到它们 → 0 个动作。
      assert summary.finalized == 0
      assert summary.aborted == 0
      assert summary.resumed_commit == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-committed")
      refute Map.has_key?(snapshot.transactions, "tx-already-aborted")
      assert snapshot.decision_index["tx-committed"].decision == :commit
      assert snapshot.decision_index["tx-already-aborted"].decision == :abort
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

      # tx-mixed-committed 全 durable → :committed → 裁出活跃集。
      assert {:ok, _} =
               TransactionCoordinator.commit_decision(coordinator, "tx-mixed-committed", 1)

      assert {:ok, _} =
               TransactionCoordinator.commit_durable_ack(coordinator, "tx-mixed-committed", {10, 100})

      assert {:ok, _} =
               TransactionCoordinator.commit_durable_ack(coordinator, "tx-mixed-committed", {20, 200})

      summary = TransactionRecoveryWatcher.recover(coordinator)

      # preparing → abort;prepared(无 resolver)→ pending_commit;committed 已裁出。
      assert summary.aborted == 1
      assert summary.pending_commit == 1
      assert summary.finalized == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-mixed-preparing")
      assert snapshot.decision_index["tx-mixed-preparing"].decision == :abort
      assert snapshot.transactions["tx-mixed-prepared"].state == :prepared
      refute Map.has_key?(snapshot.transactions, "tx-mixed-committed")
      assert snapshot.decision_index["tx-mixed-committed"].decision == :commit
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
               resume_failed: 0,
               resume_dispatched: 0,
               skipped_healthy: 0
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

      # 阶段4 / world-2pc-4:committed 事务被裁出活跃集,只在 decision_index 留归档。
      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-resume")
      assert snapshot.decision_index["tx-resume"].decision == :commit
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

    test "A4-6 verify: multi-participant resume 喂 per-participant scene_opts,跳过 prepare 直接 commit" do
      # 决策稿 A4-6:Recovery watcher resume 路径在 multi-participant transaction
      # 上自然支持(intents_by_participant 已经在 BuildTransaction 持久化,
      # scene_opts_resolver 是 1-arity 接 participants list)。本测试明确断言:
      #   1. 两个 participant 各自的 commit 都被调到(executor :prepared fast-path)
      #   2. 没调 prepare(resume 跳过 prepare phase)
      #   3. 每个 participant 用各自的 scene_opts(用 recorder_a / recorder_b 区分)
      #   4. transaction 落 :committed
      coordinator = start_supervised!(TransactionCoordinator)
      recorder_a = start_supervised!({Agent, fn -> [] end}, id: :recorder_a)
      recorder_b = start_supervised!({Agent, fn -> [] end}, id: :recorder_b)

      prepare_all!(coordinator, "tx-a4-6-multi-resume", with_intents: true)

      resolver = fn participants ->
        scene_opts_by_participant =
          Map.new(participants, fn p ->
            recorder = if p.region_id == 10, do: recorder_a, else: recorder_b
            {{p.region_id, p.lease_id}, [recorder: recorder]}
          end)

        {:ok, scene_caller: StubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
      end

      summary =
        TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)

      assert summary.resumed_commit == 1
      assert summary.pending_commit == 0

      calls_a = Agent.get(recorder_a, & &1)
      calls_b = Agent.get(recorder_b, & &1)

      # 每个 recorder 看到自己 region 的 commit,且只一次。
      assert [{:commit, 10, "tx-a4-6-multi-resume"}] = calls_a
      assert [{:commit, 20, "tx-a4-6-multi-resume"}] = calls_b

      # 两 recorder 都不应记录 prepare(resume 跳过 prepare phase,
      # `derive_prepare_results_from_prepared_state` 直接 prebake)。
      refute Enum.any?(calls_a, &match?({:prepare, _, _, _}, &1))
      refute Enum.any?(calls_b, &match?({:prepare, _, _, _}, &1))

      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-a4-6-multi-resume")
      assert snapshot.decision_index["tx-a4-6-multi-resume"].decision == :commit
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

      # 阶段4 / world-2pc-3 契约变更:participant 20 的 commit 失败 → 它没
      # durable-ack,事务**停在 :committing**(已决,绝不 abort),等下一轮 reaper
      # 重投递。participant 10 已 durable;只差 20。
      snapshot = TransactionCoordinator.snapshot(coordinator)
      tx = snapshot.transactions["tx-resume-partial"]
      assert tx.state == :committing
      assert tx.commit_acks[{10, 100}] == :durable
      assert tx.commit_acks[{20, 200}] == :pending
    end

    test "re-dispatching after a transient commit failure reaches :committed (re-投递 not abort)" do
      # 故障注入③:participant commit 失败时事务不被误记 committed、不 abort,
      # 重投递直至成功。这里第一轮 20 失败 → :committing;第二轮 20 成功 →
      # :committed。
      coordinator = start_supervised!(TransactionCoordinator)
      recorder = start_supervised!({Agent, fn -> [] end})
      prepare_all!(coordinator, "tx-redeliver", with_intents: true)

      # Agent 控制 participant 20 第一次失败、第二次成功。
      attempt = start_supervised!({Agent, fn -> 0 end}, id: :attempt_counter)

      resolver = fn participants ->
        scene_opts_by_participant =
          Map.new(participants, fn p ->
            response =
              if p.region_id == 20 do
                fn ->
                  n = Agent.get_and_update(attempt, fn n -> {n, n + 1} end)
                  if n == 0,
                    do: {:error, :transient_commit_fail},
                    else: {:ok, %{committed_chunks: [], durable?: true}}
                end
              else
                nil
              end

            {{p.region_id, p.lease_id},
             [recorder: recorder, dynamic_commit_response: response]}
          end)

        {:ok, scene_caller: DynamicStubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
      end

      # 第一轮:20 失败 → :committing。
      summary1 = TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)
      assert summary1.resume_partial == 1

      snapshot1 = TransactionCoordinator.snapshot(coordinator)
      assert snapshot1.transactions["tx-redeliver"].state == :committing
      refute Map.has_key?(snapshot1.decision_index, "tx-redeliver")

      # 第二轮重投递:20 成功 → :committed,绝不 abort。
      summary2 = TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)
      assert summary2.resumed_commit == 1

      snapshot2 = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot2.transactions, "tx-redeliver")
      assert snapshot2.decision_index["tx-redeliver"].decision == :commit
    end

    test "B1 故障注入:无-intent 事务到 :committing 后 reaper 仍能续推到 :committed(不被空-intent guard 永久停泊)" do
      # 裂缝 B1:`:committing`(已决 commit)事务 resume 时**绝不**能被
      # `intents_by_participant == %{}` guard 拦截。break-only / 无 intent 的事务
      # 到 :committing 时 intents 天然为空;commit 重投递不靠 intents(靠 chunk 上
      # 已存在的 prepared fence)。若被拦下,重启后无 driver、reaper 又拒绝续推 →
      # 已决 commit 事务永久停泊(liveness 缺口)。
      #
      # 这里构造一笔**无 intents_by_participant** 的事务,推进到 :committing(模拟
      # driver 崩在 durable-ack 全部回来之前),然后用一个**没有 driver_supervisor**
      # 的 recover(纯 reaper / 重启续推路径)验证它能被续推到 :committed,而不是
      # 停在 :pending_commit。
      coordinator = start_supervised!(TransactionCoordinator)
      recorder = start_supervised!({Agent, fn -> [] end})

      # prepare_all! 默认不带 intents → intents_by_participant 为空。
      prepare_all!(coordinator, "tx-no-intent-committing")

      # 进入 :committing(commit 已决,绝不可逆),但尚未任何 durable-ack。
      assert {:ok, %BuildTransaction{state: :committing, intents_by_participant: %{}}} =
               TransactionCoordinator.commit_decision(coordinator, "tx-no-intent-committing", 1)

      resolver = fn participants ->
        scene_opts_by_participant =
          Map.new(participants, fn p -> {{p.region_id, p.lease_id}, [recorder: recorder]} end)

        {:ok, scene_caller: StubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
      end

      # reaper / 重启续推(无 driver_supervisor → 同步 resume)。修复前:
      # :committing + 空 intents → :pending_commit(永久停泊);修复后:resume 续推
      # commit(commit 重投递不需要 intents),全 durable → :committed。
      summary = TransactionRecoveryWatcher.recover(coordinator, scene_opts_resolver: resolver)

      assert summary.resumed_commit == 1
      assert summary.pending_commit == 0

      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-no-intent-committing")
      assert snapshot.decision_index["tx-no-intent-committing"].decision == :commit
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
          {TransactionRecoveryWatcher, coordinator: coordinator, reaper_enabled?: false},
          id: :recovery_watcher_init_watcher
        )

      snapshot = TransactionCoordinator.snapshot(coordinator)
      refute Map.has_key?(snapshot.transactions, "tx-supervised-preparing")
      assert snapshot.decision_index["tx-supervised-preparing"].decision == :abort
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
               participant_key: {10, 100},
               region_id: 10,
               lease_id: 100,
               status: :prepared,
               acked_at_ms: 1
             })

    assert {:ok, %BuildTransaction{state: :prepared}} =
             TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
               participant_key: {20, 200},
               region_id: 20,
               lease_id: 200,
               status: :prepared,
               acked_at_ms: 2
             })
  end

  # 把事务一路推到 :committed(prepare_all + commit_decision + 全 durable-ack)。
  defp commit_all!(coordinator, transaction_id) do
    prepare_all!(coordinator, transaction_id)
    assert {:ok, _} = TransactionCoordinator.commit_decision(coordinator, transaction_id, 1)
    assert {:ok, _} = TransactionCoordinator.commit_durable_ack(coordinator, transaction_id, {10, 100})
    assert {:ok, _} = TransactionCoordinator.commit_durable_ack(coordinator, transaction_id, {20, 200})
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
end
