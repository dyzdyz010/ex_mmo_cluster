defmodule WorldServer.Voxel.TransactionRecoveryReaperTest do
  @moduledoc """
  阶段4 / world-2pc-2 故障注入②:运行期(不重启 world)悬挂事务被周期 reaper /
  coordinator deadline sweep 推进到终态。纯内存,验证 liveness 内生语义。
  """
  use ExUnit.Case, async: false

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant
  alias WorldServer.Voxel.TransactionRecoveryWatcher

  # 注意:nested module 必须定义在使用它的测试**之前**——Elixir 的 nested-module
  # auto-alias 在 `defmodule` 编译点才建立,若放在文件尾部,前面测试里裸写
  # `StubSceneCaller` 会解析成不存在的顶层模块(commit/3 undefined,被
  # safely_invoke 静默吞掉 → resume 永远 partial)。
  defmodule StubSceneCaller do
    def prepare(_p, _tx, _i, _o), do: {:ok, %{prepared_chunks: []}}

    def commit(participant, transaction_id, opts) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} ->
          Agent.update(agent, &(&1 ++ [{:commit, participant.region_id, transaction_id}]))

        :error ->
          :ok
      end

      # 阶段4 / world-2pc-3 契约#3:durable-ack 必须显式 `durable?: true`。
      {:ok, %{committed_chunks: [], durable?: true}}
    end

    def abort(_p, _tx, _o), do: :ok
  end

  test "coordinator's own per-deadline timer aborts a stuck :preparing transaction (不重启)" do
    # deadline 调度开着,timeout 设为很快(50ms 后),验证 coordinator 自己的
    # send_after 到点把卡 :preparing 的事务自我 abort,不依赖外部触发。
    coordinator =
      start_supervised!(
        {TransactionCoordinator,
         name: :"reaper_coord_#{System.unique_integer([:positive])}",
         sweep_interval_ms: 50}
      )

    soon = System.system_time(:millisecond) + 50

    attrs =
      transaction_attrs("tx-self-abort")
      |> Map.put(:timeout_at_ms, soon)

    assert {:ok, %BuildTransaction{state: :preparing}} =
             TransactionCoordinator.begin_transaction(coordinator, attrs)

    # 等 coordinator 内生 deadline 把它推到终态(abort),不调任何外部 sweep。
    wait_until(fn ->
      snapshot = TransactionCoordinator.snapshot(coordinator)

      not Map.has_key?(snapshot.transactions, "tx-self-abort") and
        match?(%{decision: :abort}, Map.get(snapshot.decision_index, "tx-self-abort"))
    end)
  end

  test "periodic reaper sweeps a runtime-suspended :preparing transaction to terminal" do
    coordinator =
      start_supervised!(
        {TransactionCoordinator,
         name: :"reaper_coord2_#{System.unique_integer([:positive])}",
         # 关 coordinator 自己的 deadline timer,单独验证 reaper 的周期推进。
         deadline_scheduling?: false}
      )

    # **先**起短周期 reaper(50ms,boot sweep 此时看到空 coordinator 无事可做),
    # **再**注入悬挂事务——这样推进必然来自运行期周期 reaper,而非 boot sweep,
    # 真正验证"不重启 world 也能自愈"。
    _watcher =
      start_supervised!(
        {TransactionRecoveryWatcher,
         coordinator: coordinator, reaper_interval_ms: 50, reaper_enabled?: true}
      )

    # 注入一笔已过期(过去 timeout)的 :preparing 事务。
    attrs =
      transaction_attrs("tx-reaper-preparing")
      |> Map.put(:timeout_at_ms, 1)

    assert {:ok, _} = TransactionCoordinator.begin_transaction(coordinator, attrs)

    wait_until(fn ->
      snapshot = TransactionCoordinator.snapshot(coordinator)

      not Map.has_key?(snapshot.transactions, "tx-reaper-preparing") and
        match?(%{decision: :abort}, Map.get(snapshot.decision_index, "tx-reaper-preparing"))
    end)
  end

  test "periodic reaper resumes a runtime-suspended :prepared transaction (resume not abort)" do
    coordinator =
      start_supervised!(
        {TransactionCoordinator,
         name: :"reaper_coord3_#{System.unique_integer([:positive])}",
         deadline_scheduling?: false}
      )

    recorder = start_supervised!({Agent, fn -> [] end})

    resolver = fn participants ->
      scene_opts_by_participant =
        Map.new(participants, fn p -> {{p.region_id, p.lease_id}, [recorder: recorder]} end)

      {:ok, scene_caller: StubSceneCaller, scene_opts_by_participant: scene_opts_by_participant}
    end

    # 先起 reaper(boot sweep 看到空 coordinator),再注入 :prepared 残留事务,
    # 验证运行期周期 reaper 同步 resume 把 :prepared 推到 :committed,绝不 abort。
    _watcher =
      start_supervised!(
        {TransactionRecoveryWatcher,
         coordinator: coordinator,
         reaper_interval_ms: 50,
         reaper_enabled?: true,
         scene_opts_resolver: resolver}
      )

    # 一笔 :prepared 但 commit 没推进的事务(driver 崩在 decision 前的典型残留)。
    # timeout 设在近未来(now + 150ms):避免 :preparing 中途被误 abort
    # (prepare_ack 在 timeout 前完成),到 :prepared 后过 timeout → 对运行期
    # reaper 变 stale → 被周期 resume。
    soon = System.system_time(:millisecond) + 150

    attrs =
      transaction_attrs("tx-reaper-prepared")
      |> Map.put(:timeout_at_ms, soon)
      |> Map.put(:intents_by_participant, intents())

    assert {:ok, _} = TransactionCoordinator.begin_transaction(coordinator, attrs)
    prepare_all!(coordinator, "tx-reaper-prepared")

    wait_until(fn ->
      snapshot = TransactionCoordinator.snapshot(coordinator)
      match?(%{decision: :commit}, Map.get(snapshot.decision_index, "tx-reaper-prepared"))
    end)

    # 终态是 commit,绝不是 abort。
    snapshot = TransactionCoordinator.snapshot(coordinator)
    assert snapshot.decision_index["tx-reaper-prepared"].decision == :commit
  end

  defp wait_until(fun, attempts \\ 200)
  defp wait_until(_fun, 0), do: flunk("wait_until condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp prepare_all!(coordinator, transaction_id) do
    {:ok, _} =
      TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
        participant_key: {10, 100},
        region_id: 10,
        lease_id: 100,
        status: :prepared,
        acked_at_ms: 1
      })

    {:ok, %BuildTransaction{state: :prepared}} =
      TransactionCoordinator.prepare_ack(coordinator, transaction_id, %{
        participant_key: {20, 200},
        region_id: 20,
        lease_id: 200,
        status: :prepared,
        acked_at_ms: 2
      })
  end

  defp intents do
    %{
      {10, 100} => %{{0, 0, 0} => [%{operation: :put_solid_block, macro: 0}]},
      {20, 200} => %{{2, 0, 0} => [%{operation: :put_solid_block, macro: 1}]}
    }
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
          participant_key: {10, 100},
          region_id: 10,
          lease_id: 100,
          owner_scene_instance_ref: 1_000,
          owner_epoch: 1,
          assigned_scene_node: :scene_a,
          affected_chunks: [{0, 0, 0}],
          chunk_owners: %{{0, 0, 0} => {10, 100}}
        },
        %TransactionParticipant{
          participant_key: {20, 200},
          region_id: 20,
          lease_id: 200,
          owner_scene_instance_ref: 2_000,
          owner_epoch: 1,
          assigned_scene_node: :scene_b,
          affected_chunks: [{2, 0, 0}],
          chunk_owners: %{{2, 0, 0} => {20, 200}}
        }
      ]
    }
  end
end
