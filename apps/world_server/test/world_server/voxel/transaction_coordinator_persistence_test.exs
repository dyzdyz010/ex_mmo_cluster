defmodule WorldServer.Voxel.TransactionCoordinatorPersistenceTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelTransactionCoordinatorRow
  alias DataService.Voxel.TransactionCoordinatorStore
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant
  alias WorldServer.Voxel.TransactionRecoveryWatcher

  setup do
    Repo.delete_all(VoxelTransactionCoordinatorRow)
    :ok
  end

  test "begin_transaction state survives restart through row-level Postgres persistence" do
    coordinator = start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_coord)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-restart")
             )

    # 给异步 flush 一拍落库,然后断言确实写了行。
    wait_for_flush(coordinator)
    assert Repo.aggregate(VoxelTransactionCoordinatorRow, :count) >= 1

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

  test "commit decision_index survives restart and durable barrier resumes correctly" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_commit_coord)

    prepare_all!(coordinator, "tx-commit-restart")

    # 阶段4 / world-2pc-3:commit_decision 只进 :committing。
    assert {:ok, %BuildTransaction{state: :committing}} =
             TransactionCoordinator.commit_decision(coordinator, "tx-commit-restart", 1)

    # 全 participant durable-ack → :committed。
    assert {:ok, %BuildTransaction{state: :committing}} =
             TransactionCoordinator.commit_durable_ack(coordinator, "tx-commit-restart", {10, 100})

    assert {:ok, %BuildTransaction{state: :committed}} =
             TransactionCoordinator.commit_durable_ack(coordinator, "tx-commit-restart", {20, 200})

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-commit-restart"].decision == :commit

    wait_for_flush(coordinator)
    stop_supervised!(:first_commit_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_commit_coord)

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.decision_index["tx-commit-restart"].decision == :commit

    # 重启后 begin replay 命中归档,返回幂等 committed 视图(不 conflict)。
    assert {:ok, %BuildTransaction{state: :committed}} =
             TransactionCoordinator.begin_transaction(
               revived,
               transaction_attrs("tx-commit-restart")
             )
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
               participant_key: {10, 100},
               region_id: 10,
               lease_id: 100,
               status: :failed,
               acked_at_ms: 1
             })

    assert {:ok, %BuildTransaction{state: :aborted}} =
             TransactionCoordinator.abort_decision(coordinator, "tx-abort-restart", 1)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-abort-restart"].decision == :abort

    wait_for_flush(coordinator)
    stop_supervised!(:first_abort_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_abort_coord)

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.decision_index["tx-abort-restart"].decision == :abort
    # 终态事务被裁出活跃集,只剩归档。
    refute Map.has_key?(revived_snapshot.transactions, "tx-abort-restart")

    # Replaying the same abort pair after restart must remain idempotent.
    # 阶段4 / world-2pc-4 不变式:"终态移出活跃集"(同进程归档)与"重启从库恢复
    # 活跃集"(load 后只剩归档)对同一笔归档事务的同 (decision, version) 重决策
    # 必须一致——都幂等回 {:ok, 终态视图}(与 transaction_coordinator_test 里
    # 同进程归档后重 abort 的语义一致),而不是 :unknown_transaction。
    assert {:ok, %BuildTransaction{state: :aborted}} =
             TransactionCoordinator.abort_decision(revived, "tx-abort-restart", 1)

    # 不同 decision(对已 abort 的事务发 commit)仍按 {:already_decided, :abort, 1}
    # 拒绝(契约#2 已决不可逆)。
    assert {:error, {:already_decided, :abort, 1}} =
             TransactionCoordinator.commit_decision(revived, "tx-abort-restart", 1)
  end

  test "RecoveryWatcher aborts :preparing transaction after coordinator restart" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_recovery_coord)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-recovery-preparing")
             )

    wait_for_flush(coordinator)
    stop_supervised!(:first_recovery_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_recovery_coord)

    revived_pre_sweep = TransactionCoordinator.snapshot(revived)
    assert revived_pre_sweep.transactions["tx-recovery-preparing"].state == :preparing

    _watcher =
      start_supervised!(
        {TransactionRecoveryWatcher, coordinator: revived, reaper_enabled?: false},
        id: :recovery_watcher_for_revived
      )

    revived_post_sweep = TransactionCoordinator.snapshot(revived)
    refute Map.has_key?(revived_post_sweep.transactions, "tx-recovery-preparing")
    assert revived_post_sweep.decision_index["tx-recovery-preparing"].decision == :abort

    # The abort decision must have been written through to Postgres so that a
    # second restart cycle does not see the same transaction as :preparing.
    wait_for_flush(revived)
    stop_supervised!(:recovery_watcher_for_revived)
    stop_supervised!(:revived_recovery_coord)

    final =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :final_recovery_coord)

    final_snapshot = TransactionCoordinator.snapshot(final)
    assert final_snapshot.decision_index["tx-recovery-preparing"].decision == :abort
  end

  test "RecoveryWatcher leaves :prepared transaction parked after restart" do
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_parked_coord)

    prepare_all!(coordinator, "tx-recovery-prepared")

    assert TransactionCoordinator.snapshot(coordinator).transactions["tx-recovery-prepared"].state ==
             :prepared

    wait_for_flush(coordinator)
    stop_supervised!(:first_parked_coord)

    revived =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_parked_coord)

    _watcher =
      start_supervised!(
        {TransactionRecoveryWatcher, coordinator: revived, reaper_enabled?: false},
        id: :recovery_watcher_for_parked
      )

    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert revived_snapshot.transactions["tx-recovery-prepared"].state == :prepared
    refute Map.has_key?(revived_snapshot.decision_index, "tx-recovery-prepared")
  end

  test "init survives an empty Postgres table" do
    assert Repo.aggregate(VoxelTransactionCoordinatorRow, :count) == 0

    coordinator = start_supervised!({TransactionCoordinator, persist_opts()}, id: :empty_coord)

    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.transactions == %{}
    assert snapshot.decisions == %{}
    assert snapshot.decision_index == %{}
  end

  # Phase 3-bis: BuildTransaction.intents_by_participant must round-trip
  # through Postgres so a coordinator restart can reconstruct the commit
  # dispatch payload.
  test "intents_by_participant survives restart through row-level persistence" do
    coordinator = start_supervised!({TransactionCoordinator, persist_opts()}, id: :first_intents)

    intents = %{
      {10, 100} => %{
        {0, 0, 0} => [%{operation: :put_solid_block, macro: 0, lease_id: 100}]
      },
      {20, 200} => %{
        {2, 0, 0} => [%{operation: :put_solid_block, macro: 1, lease_id: 200}]
      }
    }

    attrs =
      "tx-intents-restart"
      |> transaction_attrs()
      |> Map.put(:intents_by_participant, intents)

    assert {:ok, %BuildTransaction{intents_by_participant: ^intents}} =
             TransactionCoordinator.begin_transaction(coordinator, attrs)

    wait_for_flush(coordinator)
    stop_supervised!(:first_intents)

    revived = start_supervised!({TransactionCoordinator, persist_opts()}, id: :revived_intents)

    revived_snapshot = TransactionCoordinator.snapshot(revived)

    assert revived_snapshot.transactions["tx-intents-restart"].intents_by_participant == intents
  end

  test "incremental persistence keeps the active map bounded after many terminal transactions" do
    # 故障注入④:长跑后活跃 map 有界(终态事务被裁出),重启从库恢复活跃集。
    coordinator =
      start_supervised!({TransactionCoordinator, persist_opts()}, id: :bounded_coord)

    # 跑 30 笔完整 commit 事务(都到终态)。
    for i <- 1..30 do
      tx_id = "tx-bounded-#{i}"
      prepare_all!(coordinator, tx_id)
      assert {:ok, _} = TransactionCoordinator.commit_decision(coordinator, tx_id, 1)
      assert {:ok, _} = TransactionCoordinator.commit_durable_ack(coordinator, tx_id, {10, 100})
      assert {:ok, _} = TransactionCoordinator.commit_durable_ack(coordinator, tx_id, {20, 200})
    end

    # 再留一笔活跃(未 commit)。
    assert {:ok, _} =
             TransactionCoordinator.begin_transaction(
               coordinator,
               transaction_attrs("tx-bounded-active")
             )

    snapshot = TransactionCoordinator.snapshot(coordinator)

    # 活跃集只剩那一笔未决事务(30 笔终态全裁出)。
    assert map_size(snapshot.transactions) == 1
    assert Map.has_key?(snapshot.transactions, "tx-bounded-active")
    # decision_index 仍保留 30 笔 commit 归档(幂等重放)。
    assert map_size(snapshot.decision_index) == 30

    wait_for_flush(coordinator)
    stop_supervised!(:bounded_coord)

    # 重启从库恢复:活跃集仍只 1 笔,归档仍 30 笔。
    revived = start_supervised!({TransactionCoordinator, persist_opts()}, id: :bounded_revived)
    revived_snapshot = TransactionCoordinator.snapshot(revived)
    assert map_size(revived_snapshot.transactions) == 1
    assert Map.has_key?(revived_snapshot.transactions, "tx-bounded-active")
    assert map_size(revived_snapshot.decision_index) == 30
    assert revived_snapshot.decision_index["tx-bounded-1"].decision == :commit
  end

  defp persist_opts do
    [
      persist_rows_fn: TransactionCoordinatorStore.persist_rows_fn(Repo),
      load_fn: TransactionCoordinatorStore.load_fn(Repo),
      # 关掉自动 deadline timer / 周期 sweep,避免 1_900_000_000_000 远期 timeout
      # 的事务在测试期间被意外推进;本测试只验证持久化 round-trip。
      deadline_scheduling?: false
    ]
  end

  # 异步 flush 落库后才稳定。用一个同步 snapshot call 作为 flush barrier:
  # snapshot 之前排队的 :flush_dirty_rows 消息已被处理(send_after 是 0 / send
  # 是同进程 mailbox,snapshot call 排在它后面)。再额外用 sync 调用确保 mailbox
  # drain。
  defp wait_for_flush(coordinator) do
    # 两次 snapshot:第一次让已排队的 flush 消息先处理,第二次确保 drain。
    TransactionCoordinator.snapshot(coordinator)
    TransactionCoordinator.snapshot(coordinator)
    :ok
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
end
