defmodule SceneServer.AoiManager do
  @moduledoc """
  Stateless facade for AOI registration and lookup.

  ## 从单点 GenServer 到无状态 facade(S1)

  历史上 `AoiManager` 是一个 GenServer,在 `init/1` 里创建八叉树句柄,并在自己的 state 里
  同时持有八叉树句柄和一份与八叉树平行的 `aois` CID map。这造成两个根因缺陷:

  1. **句柄孤儿化**:管理者崩溃重启会创建一棵全新空树,存活 `AoiItem` 仍持旧句柄 →
     AOI 视图脑裂。
  2. **双真相源 + 热路径串行**:`aois` map 是第二真相源;每次 `self_move` 同步
     `GenServer.call` 串行到单进程。

  现在 `AoiManager` **不再是进程**,而是一个无状态模块 facade:

  - 八叉树句柄的所有权移交给极简、近乎不崩的 `SceneServer.Aoi.IndexStore`(由
    `SceneServer.Aoi.IndexHeir` 做 ETS heir,跨重启复用同一句柄,重启从权威 hydrate)。
  - CID 索引的唯一真相源是 `SceneServer.Aoi.IndexStore` 拥有的 `:scene_aoi_entries` ETS
    表;`AoiManager` 不再保留任何平行 map。
  - 所有读写经无状态的 `SceneServer.Aoi.Index` 直接落 ETS / 八叉树 NIF,**没有任何
    GenServer.call 到单点**。

  Player 与 NPC actor 仍然通过本模块注册;combat targeting 仍然 actor-agnostic。
  """

  alias SceneServer.Aoi.Index

  @type vector :: {float(), float(), float()}

  @spec add_aoi_item(
          integer(),
          integer(),
          vector(),
          pid(),
          pid(),
          %{kind: atom(), name: String.t()}
        ) ::
          {:ok, pid()} | {:err, any()}
  @doc """
  Registers one actor in the AOI system and returns its dedicated AOI item PID.

  Spawns the `AoiItem` under `SceneServer.AoiItemSup` and writes the CID index
  entry into the authoritative ETS table. The AOI item reads the shared octree
  handle from `SceneServer.Aoi.Index` itself, so it never receives a stale
  handle that could be orphaned by a restart.
  """
  def add_aoi_item(cid, client_timestamp, location, connection_pid, actor_pid, actor_meta) do
    case DynamicSupervisor.start_child(
           SceneServer.AoiItemSup,
           {SceneServer.Aoi.AoiItem,
            {cid, client_timestamp, location, connection_pid, actor_pid, actor_meta}}
         ) do
      {:ok, apid} ->
        Index.put_entry(%{
          cid: cid,
          aoi_pid: apid,
          actor_pid: actor_pid,
          actor_meta: actor_meta,
          location: location
        })

        {:ok, apid}

      {:error, reason} ->
        {:err, reason}
    end
  end

  @spec remove_aoi_item(integer()) :: {:ok, any()}
  @doc "Removes an actor from the AOI index by CID."
  def remove_aoi_item(cid) do
    Index.delete_entry(cid)
    {:ok, ""}
  end

  @spec get_items_with_cids([integer()]) :: [pid()]
  @doc "Resolves AOI item PIDs for the provided CIDs."
  def get_items_with_cids(cids) do
    Index.item_pids(cids)
  end

  @spec get_entries_with_cids([integer()]) :: [map()]
  @doc """
  Resolves AOI entries for the provided CIDs.

  Entries include `:cid`, `:aoi_pid`, actor metadata, and the latest AOI
  location. This is the read side used by priority sync; the entry index is the
  single CID truth source while each `AoiItem` owns its process-local
  subscription list.
  """
  def get_entries_with_cids(cids) do
    Index.fetch_entries(cids)
  end

  @spec update_item_location(integer(), vector()) :: :ok
  @doc """
  Updates the cached location for one AOI item.

  This is the `self_move` hot path. It is an atomic, concurrent `:ets`
  write — it does **not** serialize through any single process anymore.
  """
  def update_item_location(cid, location) do
    Index.update_location(cid, location)
  end

  @spec get_nearby_actor_pids(vector(), float(), [integer()]) :: [pid()]
  @doc "Returns nearby actor PIDs around a location, excluding specified CIDs."
  def get_nearby_actor_pids(location, radius, exclude_cids \\ []) do
    Index.nearby_actor_pids(location, radius, exclude_cids)
  end

  @spec get_actor_pid(integer()) :: pid() | nil
  @doc "Resolves an authoritative actor PID by CID."
  def get_actor_pid(cid) do
    Index.actor_pid(cid)
  end
end
