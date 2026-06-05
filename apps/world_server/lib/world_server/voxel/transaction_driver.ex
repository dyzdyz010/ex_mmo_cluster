defmodule WorldServer.Voxel.TransactionDriver do
  @moduledoc """
  Per-transaction supervised driver that pushes one `BuildTransaction` to a
  terminal state.

  阶段4 / world-2pc-1:**编排所有权收回 world**。每笔事务一个受监督 driver
  (挂 `WorldServer.Voxel.TransactionDriverSupervisor`),负责把一笔事务从
  prepare 经 decision 推到终态(`:committed` / `:aborted`),并在 commit 已决后
  把 commit 持续投递给所有 participant 直到全部 durable-ack(契约#2/#3)。

  ## 崩溃续推

  driver 用 `restart: :transient`:跑到终态 `:normal` 退出不重启;异常崩溃才由
  监督树重启。重启后 driver **不**依赖任何调用方传入的内存状态,而是从协调者
  **持久状态**(`TransactionCoordinator.fetch_active/2`)重新读取事务当前状态,
  然后调 `TransactionExecutor.execute/4` 续推:

  - `:preparing` → 重新跑 prepare/commit/abort(prepare 幂等:participant fence
    已存在则复用)。
  - `:prepared` → executor `:prepared` fast-path,跳过 prepare 直接 commit。
  - `:committing` → executor `:committing` fast-path,**重投递 commit**给尚未
    durable-ack 的 participant(绝不 abort 已决事务)。
  - `:committed` / `:aborted` → 终态,driver 立刻 `:normal` 退出。

  via-tuple 注册保证同一 `transaction_id` 同节点只有一个 driver,boot sweep 与
  运行期 reaper 拉起同一笔不会产生两个并发 driver。

  > driver 不持有 scene caller 配置以外的任何权威状态:事务真相在协调者(持久),
  > fence 真相在 participant chunk(持久)。driver 只是"内生 liveness"的执行臂。
  """

  use GenServer, restart: :transient

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionExecutor

  @registry WorldServer.Voxel.TransactionDriverRegistry

  @doc """
  Starts a driver for one transaction.

  Required `opts`:

  - `:transaction_id` — the coordinator transaction id (drives via-tuple
    identity).
  - `:coordinator` — coordinator GenServer reference.
  - `:executor_opts` — keyword list passed straight to
    `TransactionExecutor.execute/4`; **must** include
    `:scene_opts_by_participant`, may include `:scene_caller`.

  Optional `opts`:

  - `:intents_by_participant` — per-participant intent batch for the prepare
    phase. Defaults to the transaction's persisted `intents_by_participant`
    (so a resume driver started by the reaper does not need to re-supply it).
  - `:registry` — override the via-tuple registry (test isolation).
  - `:notify` — `{pid, ref}` to send `{:transaction_driver_result, ref,
    result}` to when the driver reaches a terminal decision (best-effort; the
    durable truth is always the coordinator). gate-originator subscription is
    WIP; this hook lets a future gate side observe completion without owning
    the orchestration.
  """
  def start_link(opts) do
    transaction_id = Keyword.fetch!(opts, :transaction_id)
    registry = Keyword.get(opts, :registry, @registry)
    GenServer.start_link(__MODULE__, opts, name: via(registry, transaction_id))
  end

  @doc "Returns the via-tuple for a transaction driver (so callers can address it)."
  def via(registry \\ @registry, transaction_id) do
    {:via, Registry, {registry, {:transaction_driver, transaction_id}}}
  end

  @impl true
  def init(opts) do
    state = %{
      transaction_id: Keyword.fetch!(opts, :transaction_id),
      coordinator: Keyword.fetch!(opts, :coordinator),
      executor_opts: Keyword.fetch!(opts, :executor_opts),
      intents_by_participant: Keyword.get(opts, :intents_by_participant),
      notify: Keyword.get(opts, :notify)
    }

    # 续推用 handle_continue,让 init 立刻返回(via-tuple 注册即生效,避免
    # boot sweep 期间被重复拉起)。
    {:ok, state, {:continue, :drive}}
  end

  @impl true
  def handle_continue(:drive, state) do
    case TransactionCoordinator.fetch_active(state.coordinator, state.transaction_id) do
      {:ok, %BuildTransaction{} = transaction} ->
        drive(state, transaction)

      :error ->
        # 事务已不在活跃集 → 已经到终态(被裁出)或从未存在。两种情况 driver
        # 都无事可做,正常退出。
        emit("voxel_transaction_driver_already_final", state, %{})
        {:stop, :normal, state}
    end
  end

  defp drive(state, %BuildTransaction{} = transaction) do
    cond do
      BuildTransaction.final?(transaction) ->
        notify_result(state, {:ok, terminal_decision(transaction)})
        {:stop, :normal, state}

      true ->
        intents = state.intents_by_participant || transaction.intents_by_participant || %{}

        emit("voxel_transaction_driver_started", state, %{from_state: transaction.state})

        # execute/4 同步跑 prepare/commit/abort + durable barrier。它崩了就让
        # driver 崩,监督树重启后从协调者持久状态续推(idempotent)。
        result =
          TransactionExecutor.execute(
            state.coordinator,
            transaction,
            intents,
            state.executor_opts
          )

        notify_result(state, result)

        emit("voxel_transaction_driver_finished", state, %{
          decision: decision_from_result(result)
        })

        {:stop, :normal, state}
    end
  end

  defp terminal_decision(%BuildTransaction{state: :committed}), do: :commit
  defp terminal_decision(%BuildTransaction{state: :aborted}), do: :abort

  defp decision_from_result({:ok, %{decision: decision}}), do: decision
  defp decision_from_result(_other), do: :unknown

  defp notify_result(%{notify: nil}, _result), do: :ok

  defp notify_result(%{notify: {pid, ref}}, result) when is_pid(pid) do
    send(pid, {:transaction_driver_result, ref, result})
    :ok
  end

  defp notify_result(_state, _result), do: :ok

  defp emit(event, state, payload) do
    CliObserve.emit(event, fn ->
      Map.merge(%{transaction_id: state.transaction_id}, payload)
    end)
  end
end
