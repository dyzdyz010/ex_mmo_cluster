defmodule WorldServer.Voxel.TransactionDriverTest do
  @moduledoc """
  阶段4 / world-2pc-1 driver 故障注入测试①:driver kill 后事务被续推到终态,
  不悬挂。

  这些测试是纯内存(coordinator 不配持久化),验证 driver 编排 + 崩溃续推语义。
  需 PG 的端到端持久化恢复另由 transaction_coordinator_persistence_test 覆盖。
  """
  use ExUnit.Case, async: false

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionDriver
  alias WorldServer.Voxel.TransactionDriverSupervisor
  alias WorldServer.Voxel.TransactionParticipant

  # commit response 受 Agent 控制:可让某 region 第一次崩溃(模拟 driver 在
  # commit 中途死),之后成功,以验证 driver 重启续推到终态。
  defmodule ControlledSceneCaller do
    def prepare(participant, transaction_id, _intents, opts) do
      log(opts, {:prepare, participant.region_id, transaction_id})
      {:ok, %{prepared_chunks: []}}
    end

    def commit(participant, transaction_id, opts) do
      log(opts, {:commit, participant.region_id, transaction_id})
      region = participant.region_id

      case Keyword.get(opts, :commit_control) do
        nil ->
          # 阶段4 / world-2pc-3 契约#3:durable-ack 必须显式 `durable?: true`。
          {:ok, %{committed_chunks: [], durable?: true}}

        agent ->
          # 每个 region 的 behavior 取一次后清掉(模拟"第一次崩、之后成功")。
          behavior =
            Agent.get_and_update(agent, fn m ->
              {Map.get(m, region), Map.delete(m, region)}
            end)

          case behavior do
            :crash -> raise "controlled commit crash for region #{region}"
            _ -> {:ok, %{committed_chunks: [], durable?: true}}
          end
      end
    end

    def abort(participant, transaction_id, opts) do
      log(opts, {:abort, participant.region_id, transaction_id})
      :ok
    end

    defp log(opts, event) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} -> Agent.update(agent, &(&1 ++ [event]))
        :error -> :ok
      end
    end
  end

  # nested module 必须定义在使用它的测试**之前**(见 reaper_test 同样注释):
  # Elixir nested-module auto-alias 在 defmodule 编译点建立,放文件尾会让前面
  # 测试里裸写 `SlowSceneCaller` 解析成不存在的顶层模块,commit/3 被 safely_invoke
  # 静默吞掉 → 事务永远续推不到终态。
  defmodule SlowSceneCaller do
    def prepare(_p, _tx, _i, _o), do: {:ok, %{prepared_chunks: []}}

    def commit(participant, transaction_id, opts) do
      case Keyword.fetch(opts, :recorder) do
        {:ok, agent} ->
          Agent.update(agent, &(&1 ++ [{:commit, participant.region_id, transaction_id}]))

        :error ->
          :ok
      end

      blocker = Keyword.get(opts, :blocker)
      wait_until_go(blocker)
      # 阶段4 / world-2pc-3 契约#3:durable-ack 必须显式 `durable?: true`。
      {:ok, %{committed_chunks: [], durable?: true}}
    end

    def abort(_p, _tx, _o), do: :ok

    defp wait_until_go(nil), do: :ok

    defp wait_until_go(blocker) do
      case Agent.get(blocker, & &1) do
        :go ->
          :ok

        _ ->
          Process.sleep(20)
          wait_until_go(blocker)
      end
    end
  end

  setup do
    registry_name = :"driver_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    sup_name = :"driver_sup_#{System.unique_integer([:positive])}"
    start_supervised!({TransactionDriverSupervisor, name: sup_name})

    coordinator =
      start_supervised!(
        {TransactionCoordinator,
         name: :"driver_coord_#{System.unique_integer([:positive])}",
         deadline_scheduling?: false}
      )

    %{registry: registry_name, supervisor: sup_name, coordinator: coordinator}
  end

  test "driver drives a fresh transaction to :committed", ctx do
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, _t} = TransactionCoordinator.begin_transaction(ctx.coordinator, attrs("tx-drive"))

    {:ok, pid} =
      TransactionDriverSupervisor.ensure_driver(ctx.supervisor,
        transaction_id: "tx-drive",
        coordinator: ctx.coordinator,
        registry: ctx.registry,
        intents_by_participant: intents(),
        executor_opts: [
          scene_caller: ControlledSceneCaller,
          scene_opts_by_participant: opts_for(recorder)
        ]
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    snapshot = TransactionCoordinator.snapshot(ctx.coordinator)
    assert snapshot.decision_index["tx-drive"].decision == :commit
    refute Map.has_key?(snapshot.transactions, "tx-drive")
  end

  test "driver killed mid-commit is restarted and resumes to terminal (故障注入①)", ctx do
    recorder = start_supervised!({Agent, fn -> [] end})

    {:ok, _t} = TransactionCoordinator.begin_transaction(ctx.coordinator, attrs("tx-kill"))

    # 让 driver 跑到 :committing 后 kill 它(模拟 driver 崩在 commit 中途)。
    # 用一个 commit_control agent,让 region 20 第一次 raise(driver 崩)。
    # 先把事务推进到 :prepared,driver 启动即走 :prepared fast-path → :committing。
    prepare_all!(ctx.coordinator, "tx-kill")

    # blocker 让 commit 阻塞,这样 driver 卡在 commit dispatch 中,可在它跑完前
    # Process.exit(:kill) 掉它(模拟 driver 真的崩在 commit 中途)。
    blocker = start_supervised!({Agent, fn -> :block end}, id: :kill_blocker)

    {:ok, pid} =
      TransactionDriverSupervisor.ensure_driver(ctx.supervisor,
        transaction_id: "tx-kill",
        coordinator: ctx.coordinator,
        registry: ctx.registry,
        executor_opts: [
          scene_caller: SlowSceneCaller,
          scene_opts_by_participant: opts_for(recorder, blocker: blocker)
        ]
      )

    # 等 driver 实际进入 commit dispatch(至少一个 commit 被记录)再 kill。
    wait_until(fn ->
      Enum.any?(Agent.get(recorder, & &1), &match?({:commit, _, "tx-kill"}, &1))
    end)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    # 此时事务已决 commit(:committing),绝不会因 driver 死而变 abort。
    snapshot_mid = TransactionCoordinator.snapshot(ctx.coordinator)
    assert snapshot_mid.transactions["tx-kill"].state == :committing

    # 监督树用 restart: :transient,异常退出(:killed)会**自动重启** driver(同
    # opts:SlowSceneCaller + blocker)。重启后 driver 走 :committing fast-path
    # 续推,只对未 durable 的 participant 重投递 commit。放行 blocker 让续推完成。
    Agent.update(blocker, fn _ -> :go end)

    # 续推到终态,不悬挂;且是 commit(已决,绝不 abort)。
    wait_until(fn ->
      snapshot = TransactionCoordinator.snapshot(ctx.coordinator)
      match?(%{decision: :commit}, Map.get(snapshot.decision_index, "tx-kill"))
    end)

    snapshot = TransactionCoordinator.snapshot(ctx.coordinator)
    assert snapshot.decision_index["tx-kill"].decision == :commit
    refute Map.has_key?(snapshot.transactions, "tx-kill")
  end

  test "ensure_driver dedups: a second start for the same transaction returns the same pid", ctx do
    recorder = start_supervised!({Agent, fn -> [] end})

    # 用一个会一直阻塞 commit 的 scene caller,让 driver 停在运行中,这样我们能
    # 观察两次 ensure_driver 返回同一 pid。
    blocker = start_supervised!({Agent, fn -> :block end}, id: :blocker)

    {:ok, _t} = TransactionCoordinator.begin_transaction(ctx.coordinator, attrs("tx-dedup"))
    prepare_all!(ctx.coordinator, "tx-dedup")

    driver_opts = [
      transaction_id: "tx-dedup",
      coordinator: ctx.coordinator,
      registry: ctx.registry,
      executor_opts: [
        scene_caller: SlowSceneCaller,
        scene_opts_by_participant: opts_for(recorder, blocker: blocker)
      ]
    ]

    {:ok, pid1} = TransactionDriverSupervisor.ensure_driver(ctx.supervisor, driver_opts)
    {:ok, pid2} = TransactionDriverSupervisor.ensure_driver(ctx.supervisor, driver_opts)

    assert pid1 == pid2

    # 放行 blocker 让 driver 完成。
    Agent.update(blocker, fn _ -> :go end)
  end

  defp opts_for(recorder, extra \\ []) do
    base = [recorder: recorder] ++ extra

    %{
      {10, 100} => base,
      {20, 200} => base
    }
  end

  defp wait_until(fun, attempts \\ 100)
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

  defp attrs(transaction_id) do
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
