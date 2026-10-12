defmodule NpcServer.Bootstrap do
  @moduledoc "随 NPC 根常驻的启动协调器；上游监督器恢复时重新拉起持久化登记角色。"
  use GenServer
  require Logger

  @doc "由正式监督树启动，不持有角色真值。"
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "从当前持久化登记和进程登记派生控制进程状态；Scene ready 请读 Body.observe/1。"
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(nil), do: {:ok, nil, {:continue, :restore}}

  @impl true
  def handle_continue(:restore, nil) do
    results = NpcServer.Registry.start_all()
    failed = Enum.count(results, fn {_, result} -> match?({:error, _}, result) end)
    Logger.info("npc_bootstrap_ready enabled=#{length(results)} failed=#{failed}")
    {:noreply, nil}
  end

  @impl true
  def handle_call(:status, _from, nil) do
    enabled = Enum.filter(NpcServer.Registry.list(), & &1.enabled)
    running = Enum.count(enabled, & &1.running)
    status = if running == length(enabled), do: :running, else: :degraded
    {:reply, %{status: status, enabled: length(enabled), running: running}, nil}
  end
end
