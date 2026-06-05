defmodule WorldServer.Voxel.TransactionDriverSupervisor do
  @moduledoc """
  DynamicSupervisor owning the per-transaction `TransactionDriver` processes.

  阶段4 / world-2pc-1:**编排所有权收回 world**。一笔事务的"从 begin 推到终态"
  的编排不再由发起方(gate 连接进程)同步驱动,而是由 world 节点上一个**受监督
  的 driver 进程**负责;driver 崩溃由本监督树重启,重启后从协调者**持久状态**
  续推,不依赖发起方进程存活。

  driver 用 `restart: :transient`:正常跑到终态后 `:normal` 退出不重启;异常崩溃
  才重启续推。本监督树用 `:one_for_one`,一笔 driver 崩溃不波及其它在途事务。

  > gate 发起侧(`tcp_connection.ex`)改动属 movement-sync WIP,本阶段跳过;这里
  > 只保证 world 侧 driver 能独立续推。WorldSup 在 boot 时启动本监督树;
  > recovery_watcher 在 boot sweep / 周期 reaper 里对 `:prepared` / `:committing`
  > 事务通过本监督树拉起 driver 续推。
  """

  use DynamicSupervisor

  alias WorldServer.Voxel.TransactionDriver

  @doc "Starts the driver DynamicSupervisor."
  def start_link(opts) do
    {server_opts, _rest} = Keyword.split(opts, [:name])
    DynamicSupervisor.start_link(__MODULE__, :ok, server_opts)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts (or returns the already-running) driver for `transaction_id`.

  `driver_opts` must include `:transaction_id` and `:coordinator`; it usually
  also carries `:intents_by_participant` and `:executor_opts` (with
  `:scene_opts_by_participant`). Two starts for the same `transaction_id` are
  deduplicated through the driver's via-tuple registration: a second start
  returns `{:ok, existing_pid}` instead of spawning a duplicate driver, so a
  boot sweep and a runtime reaper cannot race two drivers onto one transaction.
  """
  @spec ensure_driver(GenServer.server(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_driver(supervisor \\ __MODULE__, driver_opts) do
    case DynamicSupervisor.start_child(supervisor, {TransactionDriver, driver_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> {:error, :already_present}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the count of currently supervised drivers (CLI/test helper)."
  def driver_count(supervisor \\ __MODULE__) do
    %{active: active} = DynamicSupervisor.count_children(supervisor)
    active
  end
end
