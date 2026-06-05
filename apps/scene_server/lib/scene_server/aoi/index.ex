defmodule SceneServer.Aoi.Index do
  @moduledoc """
  Stateless functional facade over the AOI index ETS tables.

  ## 角色(S1:无状态 facade,热路径去单点同步 call)

  `SceneServer.Aoi.IndexStore` 拥有八叉树句柄表与 CID 索引表(权威存储)。`Index` 是这两
  张表之上的**纯函数读写层**:它不是进程,没有 state,所有操作直接落 ETS。

  关键收益:`self_move` 热路径、AOI tick 邻居查询、combat targeting 不再打同步
  `GenServer.call` 到单个管理者进程。

  - 写 location:`update_location/2` 走 `:ets.update_element`,**原子、并发、无串行**。
  - 读 entries / actor_pid / nearby:`:ets.lookup` + 直接调用八叉树 NIF(八叉树本身是
    `Arc<RwLock<..>>`,进程无关、可并发,1.5 已把 insert 改为 parking_lot upgradable_read
    原子化)。

  ## 真相源

  CID 索引的唯一真相源是 `:scene_aoi_entries` 表。八叉树句柄的唯一真相源是
  `:scene_aoi_octree` 表里的 `:octree` 记录。两者都由 `IndexStore` 持有 / hydrate,本模块
  只读写它们,不持有任何平行副本。八叉树空间位置由各 `AoiItem` 通过自己的 `item_ref`
  维护(add/remove);entries 表里的 `location` 是给 partition-window prune 用的缓存视图。
  """

  alias SceneServer.Aoi.IndexStore
  alias SceneServer.Native.Octree

  @type vector :: {float(), float(), float()}
  @type entry :: %{
          cid: integer(),
          aoi_pid: pid(),
          actor_pid: pid(),
          actor_meta: map(),
          location: vector()
        }

  @doc """
  Returns the shared octree handle (the single `OctreeArc` for this Scene node).

  这是所有 `AoiItem` 与查询路径共享的同一棵权威八叉树句柄,从 `IndexStore` 拥有的 ETS
  表读取——因此 `IndexStore` 重启复用同一句柄时,这里读到的永远是当前权威树。
  """
  @spec octree() :: Octree.Types.octree()
  def octree do
    case :ets.lookup(IndexStore.octree_table(), IndexStore.octree_key()) do
      [{_key, octree}] -> octree
      [] -> raise "AOI octree handle not initialized; IndexStore must start before AOI items"
    end
  end

  @doc "Inserts or replaces a CID index entry."
  @spec put_entry(entry()) :: :ok
  def put_entry(%{cid: cid} = entry) do
    :ets.insert(IndexStore.entries_table(), {cid, entry})
    :ok
  end

  @doc "Removes a CID index entry."
  @spec delete_entry(integer()) :: :ok
  def delete_entry(cid) do
    :ets.delete(IndexStore.entries_table(), cid)
    :ok
  end

  @doc """
  Updates only the cached `location` of an existing entry. Atomic, concurrent.

  No-op if the entry is absent (e.g. a stale `self_move` after removal). This is
  the `self_move` hot path — it must never serialize through a single process.
  """
  @spec update_location(integer(), vector()) :: :ok
  def update_location(cid, location) do
    case :ets.lookup(IndexStore.entries_table(), cid) do
      [{^cid, entry}] ->
        :ets.insert(IndexStore.entries_table(), {cid, %{entry | location: location}})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Resolves AOI entries for the provided CIDs, preserving order and dropping unknowns."
  @spec fetch_entries([integer()]) :: [entry()]
  def fetch_entries(cids) do
    table = IndexStore.entries_table()

    cids
    |> Enum.map(fn cid ->
      case :ets.lookup(table, cid) do
        [{^cid, entry}] -> entry
        [] -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Resolves AOI item PIDs for the provided CIDs."
  @spec item_pids([integer()]) :: [pid()]
  def item_pids(cids) do
    cids
    |> fetch_entries()
    |> Enum.map(& &1.aoi_pid)
  end

  @doc "Resolves an authoritative actor PID by CID, or nil."
  @spec actor_pid(integer()) :: pid() | nil
  def actor_pid(cid) do
    case :ets.lookup(IndexStore.entries_table(), cid) do
      [{^cid, %{actor_pid: pid}}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns nearby actor PIDs around a location, excluding the provided CIDs.

  Queries the shared octree (process-independent) then maps CIDs back to actor
  PIDs through the index — no GenServer.call to any single owner.
  """
  @spec nearby_actor_pids(vector(), float(), [integer()]) :: [pid()]
  def nearby_actor_pids(location, radius, exclude_cids \\ []) do
    octree()
    |> Octree.get_in_bound(location, {radius, radius, radius})
    |> Enum.reject(&(&1 in exclude_cids))
    |> Enum.map(&actor_pid/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Test/debug hatch: number of indexed CIDs."
  @spec entry_count() :: non_neg_integer()
  def entry_count do
    case :ets.whereis(IndexStore.entries_table()) do
      :undefined -> 0
      _ -> :ets.info(IndexStore.entries_table(), :size)
    end
  end
end
