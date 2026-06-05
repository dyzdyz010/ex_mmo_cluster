defmodule SceneServer.Aoi.IndexStore do
  @moduledoc """
  Authoritative owner of the AOI octree handle and the CID → entry index.

  ## 为什么存在(S1:进程身份 / 句柄所有权与易崩的管理者分离)

  历史上 `SceneServer.AoiManager` 是一个 GenServer,它在 `init/1` 里
  `Octree.new_tree/2` 创建八叉树句柄(`OctreeArc`),并把这个句柄连同 CID 索引一起
  放进自己的进程 state。这带来两类单点缺陷:

  1. **句柄孤儿化**:`AoiManager` 崩溃重启后,`init/1` 会创建一棵**全新的空八叉树**,
     而仍然存活的 `AoiItem` 进程继续持有**旧**句柄(`system_ref`)。于是同一场景里
     出现两棵树——存活 item 往旧树读写,新管理者查新空树——AOI 视图直接脑裂。
  2. **双真相源 + 热路径串行**:管理者 state 里那份 `aois` map 是与八叉树平行的第二
     真相源;每次 `self_move` 都要同步 `GenServer.call` 打到这个单进程,所有 actor 的
     移动被串行化到一个咽喉。

  `IndexStore` 把"谁是 AOI 索引的权威持有者"这件事从易崩的管理者里抽出来,做成一个
  **极简、近乎不会崩的存储进程**:它只拥有两张具名 public ETS 表,不跑任何热路径逻辑。

  ## 拥有的状态(authority)

  - `:scene_aoi_octree`(`:set`, `:public`, `read_concurrency`):key `:octree` 下持有**唯一**
    的 `OctreeArc`。这是整个 Scene 节点共享的空间索引句柄;只有 `IndexStore` 写它(冷启动 /
    认领时各一次),所有进程并发读。
  - `:scene_aoi_entries`(`:set`, `:public`, `read_concurrency` + `write_concurrency`):
    `cid => entry` 索引,entry 形如
    `%{cid, aoi_pid, actor_pid, actor_meta, location}`。**这是 CID 索引的唯一真相源**,
    管理者 state 里不再保留任何平行 map。

  两张表都是 `:public`,所以 `AoiManager` facade、每个 `AoiItem`、combat targeting 都能
  **并发直接读写,不经过任何 GenServer.call**——单点串行咽喉被彻底删除。

  ## hydrate 不变式(重启即从权威重建)

  - ETS 表的生命周期跟随 owner;为了让"句柄所有权"在 `IndexStore` 自身重启时不丢,本
    进程把表的 `heir` 设为 `SceneServer.Aoi.IndexHeir`。`IndexStore` 崩溃时 ETS 自动把
    表所有权转交 heir(`{:"ETS-TRANSFER", ...}`),重启后的 `IndexStore` 在 `init/1` 里
    向 heir **认领**回这两张表(`adopt`),从而复用**同一个** `OctreeArc` 和**同一份**
    entries。存活的 `AoiItem` 持有的 `system_ref` 因此永远指向当前权威八叉树,不会悬空。
  - 只有在确实没有任何表(冷启动)时,`IndexStore` 才 `Octree.new_tree/2` 造一棵新树。
    它**绝不**清空一张已经有内容的表——这就是"重启从权威 hydrate,而不是用空默认兜底
    覆盖真相"。
  - 若认领过程发生异常(heir 不可用等),退化为冷启动新建空树,并发 observe 事件
    `aoi_index_store_degraded` 标注 degraded,而不是静默吞掉。

  ## 边界

  `IndexStore` 不感知 actor 语义、不广播、不做优先级。它只回答"当前权威八叉树句柄是
  哪个"和"维护 CID 索引表"。读写策略由无状态的 `SceneServer.Aoi.Index` facade 表达。
  """

  use GenServer

  require Logger

  alias SceneServer.Native.Octree

  @octree_table :scene_aoi_octree
  @entries_table :scene_aoi_entries
  @octree_key :octree

  @octree_half_size {5000.0, 5000.0, 5000.0}
  @octree_center {0.0, 0.0, 0.0}

  # 两张表(octree + entries)都要从 heir 拿到才能认领,避免只转交了一张就 give_away
  # 丢掉另一张。
  @expected_table_count 2

  @doc "Returns the octree ETS table name."
  @spec octree_table() :: atom()
  def octree_table, do: @octree_table

  @doc "Returns the entries ETS table name."
  @spec entries_table() :: atom()
  def entries_table, do: @entries_table

  @doc "Returns the ETS key under which the shared octree handle lives."
  @spec octree_key() :: atom()
  def octree_key, do: @octree_key

  @doc "Starts the AOI index store (octree handle + CID index owner)."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(_init_arg) do
    # heir 必须在建表前存在;AoiSup 保证 IndexHeir 在 IndexStore 之前启动。
    heir = Process.whereis(SceneServer.Aoi.IndexHeir)

    {octree, source} = hydrate_tables(heir)

    SceneServer.CliObserve.emit("aoi_index_store_ready", %{
      source: source,
      entry_count: safe_table_size(@entries_table)
    })

    {:ok, %{octree: octree, heir: heir, source: source}}
  end

  # 重启即从权威 hydrate。返回 {octree_handle, source}。
  #
  # 两条互斥路径:
  #   1. 表已存在(上一代 IndexStore 死亡 → ETS 把表转交了 heir)→ 等 heir 真正收到转交
  #      消息后认领回来,复用同一句柄 + 同一份 entries(hydrate 不变式)。
  #   2. 表不存在 → 冷启动,造新八叉树并把 heir 设为表的 heir。
  # 注意 ETS-TRANSFER 是异步的:上一代刚被 kill 时表已属于 heir,但 heir 可能还没处理完
  # 转交消息。因此用一个有界等待循环等到 heir.has_tables? 为真再认领,避免竞态下误判成
  # "没有 heir 可认领"而走旁路。
  defp hydrate_tables(heir) do
    cond do
      tables_exist?() ->
        adopt_existing(heir)

      true ->
        cold_start(heir)
    end
  rescue
    error ->
      Logger.warning("AOI IndexStore hydrate failed, degrading to cold start: #{inspect(error)}")

      SceneServer.CliObserve.emit("aoi_index_store_degraded", %{
        reason: inspect(error)
      })

      cold_start(heir)
  end

  # 表已存在但不属于本进程:它们正在 / 已经转交给 heir。等 heir 拿到后认领回来。
  defp adopt_existing(heir) when is_pid(heir) do
    if wait_for_heir_tables(heir, 40) do
      adopt_from_heir(heir)
    else
      # 极端兜底:heir 始终没收到转交(不应发生)。表仍然存在且 :public,直接复用句柄,
      # 不清空——绝不用空默认覆盖权威 entries。标 degraded 以可观测。
      SceneServer.CliObserve.emit("aoi_index_store_degraded", %{
        reason: :heir_transfer_timeout
      })

      octree = read_octree_from_table()
      {octree, :existing_tables_unadopted}
    end
  end

  defp adopt_existing(_no_heir) do
    octree = read_octree_from_table()
    {octree, :existing_tables}
  end

  defp wait_for_heir_tables(_heir, 0), do: false

  defp wait_for_heir_tables(heir, attempts) do
    if heir_holds_all_tables?(heir) do
      true
    else
      Process.sleep(5)
      wait_for_heir_tables(heir, attempts - 1)
    end
  end

  defp heir_holds_all_tables?(heir) do
    GenServer.call(heir, :held_table_count, 1000) >= @expected_table_count
  catch
    :exit, _reason -> false
  end

  defp adopt_from_heir(heir) do
    :ok = GenServer.call(heir, {:give_away, self()}, 5000)
    octree = read_octree_from_table()

    SceneServer.CliObserve.emit("aoi_index_store_hydrated", %{
      from: :heir,
      entry_count: safe_table_size(@entries_table)
    })

    {octree, :adopted_from_heir}
  end

  defp cold_start(heir) do
    create_tables(heir)
    # read_octree_from_table 只在确实没有句柄时造新树。即便落到 rescue 兜底路径,也绝不
    # 覆盖一个已存在的权威句柄——否则就重新引入了"管理者重启造新空树 → 存活 item 孤儿化"
    # 的根因。
    {read_octree_from_table(), :cold_start}
  end

  defp create_tables(heir) do
    heir_opt = if is_pid(heir), do: [{:heir, heir, :aoi_index_tables}], else: [{:heir, :none}]

    # octree 表:单条记录,本进程写、其它进程读 → :public 读,写仍走本进程串行(只在
    # 冷启动/认领时写一次)。
    unless table_exists?(@octree_table) do
      :ets.new(@octree_table, [:set, :public, :named_table, {:read_concurrency, true} | heir_opt])
    end

    # entries 表:CID 索引唯一真相源,所有 AoiItem 并发写 location、facade 并发读 → 同时
    # 开 read/write concurrency。
    unless table_exists?(@entries_table) do
      :ets.new(@entries_table, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
        | heir_opt
      ])
    end
  end

  defp tables_exist?, do: table_exists?(@octree_table) and table_exists?(@entries_table)

  defp table_exists?(name), do: :ets.whereis(name) != :undefined

  defp read_octree_from_table do
    case :ets.lookup(@octree_table, @octree_key) do
      [{@octree_key, octree}] ->
        octree

      [] ->
        # 表存在但句柄丢失(不应发生)→ 重新造树写回,避免空句柄。
        octree = Octree.new_tree(@octree_center, @octree_half_size)
        :ets.insert(@octree_table, {@octree_key, octree})
        octree
    end
  end

  defp safe_table_size(name) do
    case :ets.whereis(name) do
      :undefined -> 0
      _ -> :ets.info(name, :size)
    end
  end

  # heir 在 IndexStore 重启时把表所有权交还本进程。
  @impl true
  def handle_info({:"ETS-TRANSFER", _tab, _from_pid, _heir_data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
