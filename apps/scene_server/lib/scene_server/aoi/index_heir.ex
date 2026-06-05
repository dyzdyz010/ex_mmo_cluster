defmodule SceneServer.Aoi.IndexHeir do
  @moduledoc """
  Minimal, crash-resistant ETS heir for the AOI index tables.

  ## 角色(S1:让权威存储活过 facade 的崩溃)

  `SceneServer.Aoi.IndexStore` 拥有 AOI 八叉树句柄表和 CID 索引表。ETS 表的生命周期跟随
  owner 进程,如果 `IndexStore` 崩溃,表(以及里面唯一的 `OctreeArc`)会随之消失,重启
  后的 `IndexStore` 只能造一棵新空树——这正是要根治的"句柄孤儿化"。

  `IndexHeir` 是 `IndexStore` 两张 ETS 表的 `heir`。它本身**不跑任何业务逻辑**,只做一件
  事:当 `IndexStore` 死亡时,ETS 自动把表所有权转交给 `IndexHeir`(`{:"ETS-TRANSFER",
  ...}`),`IndexHeir` 暂存这些表;`IndexStore` 重启后向 `IndexHeir` `give_away` 认领回去。
  因为它逻辑近乎为空,自身几乎不会崩,从而成为权威存储跨 facade 重启的稳定锚点。

  这与 3.1 的注册化 / hydrate 同构:**身份/句柄所有权(谁持有权威八叉树)与执行 facade
  (谁回答查询)分离,重启从权威 ETS 重建,而不是用空默认覆盖真相。**

  `IndexHeir` 必须在 `IndexStore` **之前**启动(见 `SceneServer.AoiSup`)。
  """

  use GenServer

  require Logger

  @doc "Starts the AOI index ETS heir."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{tables: MapSet.new()}}
  end

  @doc "Whether the heir currently holds any AOI index tables (waiting to be re-adopted)."
  @spec has_tables?(GenServer.server()) :: boolean()
  def has_tables?(server \\ __MODULE__) do
    GenServer.call(server, :has_tables?)
  end

  @doc "How many AOI index tables the heir currently holds (used to wait for a full handoff)."
  @spec held_table_count(GenServer.server()) :: non_neg_integer()
  def held_table_count(server \\ __MODULE__) do
    GenServer.call(server, :held_table_count)
  end

  @impl true
  def handle_call(:has_tables?, _from, state) do
    {:reply, not Enum.empty?(state.tables), state}
  end

  @impl true
  def handle_call(:held_table_count, _from, state) do
    {:reply, MapSet.size(state.tables), state}
  end

  @impl true
  def handle_call({:give_away, new_owner}, _from, state) when is_pid(new_owner) do
    Enum.each(state.tables, fn tab ->
      if table_alive?(tab) do
        :ets.give_away(tab, new_owner, :aoi_index_tables)
      end
    end)

    {:reply, :ok, %{state | tables: MapSet.new()}}
  end

  # IndexStore 崩溃时,ETS 把表所有权转给本 heir 进程。
  @impl true
  def handle_info({:"ETS-TRANSFER", tab, _from_pid, _heir_data}, state) do
    Logger.debug("AOI IndexHeir inherited table #{inspect(tab)} after IndexStore crash.")

    SceneServer.CliObserve.emit("aoi_index_heir_inherited", %{
      table: inspect(tab),
      held_tables: MapSet.size(state.tables) + 1
    })

    {:noreply, %{state | tables: MapSet.put(state.tables, tab)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp table_alive?(tab) do
    :ets.info(tab, :size) != :undefined
  rescue
    ArgumentError -> false
  end
end
