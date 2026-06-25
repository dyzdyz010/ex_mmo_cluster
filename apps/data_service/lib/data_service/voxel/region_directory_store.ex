defmodule DataService.Voxel.RegionDirectoryStore do
  @moduledoc """
  Durable per-region ownership directory backend for `WorldServer.Voxel.MapLedger`
  (阶段2,CELL-23)。

  **scale-first**:每个 region 一行(主键 `region_id`,全局唯一且编码 `logical_scene_id`),
  物化 / 续约 / 迁移只 upsert **一行**(O(1) per change),GC 删一行。boot 时按全量或按
  `logical_scene_id` **分片**载入。这取代了 `MapLedgerStore` 把整个 ledger 快照塞进单行
  blob(O(N) per change)的 dev 级反模式。

  API 全用**纯 map**(不引 `world_server` 的 `RegionAssignment`/`SceneLease` 结构,保持
  data_service 不反向依赖 world_server);行 ↔ 结构的转换在世界侧
  (`WorldServer.Voxel.RegionDirectory`)做。

  `*_in_repo` 变体在调用方已开启的 `Repo.transaction` 内执行(无自带事务),供 MapLedger
  把"目录行 upsert"与"写令牌发布"放进**同一事务边界**(评审 F3:发布成功但落盘失败导致
  客户端见成功而重启丢失的窗口被消除)。
  """

  # PERS-5:durable_authoritative(region 所有权目录)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  import Ecto.Query, only: [from: 2]

  alias DataService.Schema.VoxelRegionDirectory

  @row_fields [
    :region_id,
    :logical_scene_id,
    :bounds_chunk_min_x,
    :bounds_chunk_min_y,
    :bounds_chunk_min_z,
    :bounds_chunk_max_x,
    :bounds_chunk_max_y,
    :bounds_chunk_max_z,
    :owner_scene_instance_ref,
    :owner_epoch,
    :lease_id,
    :assigned_scene_node,
    :region_state,
    :region_version,
    :expires_at_ms
  ]

  # ── upsert ───────────────────────────────────────────────────────────────────

  @doc "Upserts one region row in its own transaction (last-writer-wins; the ledger serializes per-region writes)."
  @spec upsert_region(map(), keyword()) :: :ok | {:error, term()}
  def upsert_region(attrs, opts \\ []) when is_map(attrs) do
    repo = repo(opts)

    case repo.transaction(fn -> upsert_region_in_repo(repo, attrs) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Upserts one region row using the caller's `repo` **without opening its own
  transaction** — for use inside a `Repo.transaction` the caller already holds, so
  the directory write commits atomically with whatever else is in that boundary.
  """
  @spec upsert_region_in_repo(Ecto.Repo.t(), map()) :: :ok | {:error, term()}
  def upsert_region_in_repo(repo, attrs) when is_map(attrs) do
    row = normalize_row(attrs)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    row = row |> Map.put(:inserted_at, now) |> Map.put(:updated_at, now)

    replace_fields = @row_fields |> List.delete(:region_id) |> Kernel.++([:updated_at])

    case repo.insert_all(VoxelRegionDirectory, [row],
           on_conflict: {:replace, replace_fields},
           conflict_target: :region_id
         ) do
      {count, _} when count >= 1 -> :ok
      _other -> {:error, :persist_failed}
    end
  end

  # ── delete (GC) ──────────────────────────────────────────────────────────────

  @doc "Deletes one region row (region GC) in its own transaction."
  @spec delete_region(non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def delete_region(region_id, opts \\ []) when is_integer(region_id) do
    repo = repo(opts)
    repo.delete_all(from(r in VoxelRegionDirectory, where: r.region_id == ^region_id))
    :ok
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc "Deletes one region row using the caller's open transaction `repo`."
  @spec delete_region_in_repo(Ecto.Repo.t(), non_neg_integer()) :: :ok
  def delete_region_in_repo(repo, region_id) when is_integer(region_id) do
    repo.delete_all(from(r in VoxelRegionDirectory, where: r.region_id == ^region_id))
    :ok
  end

  # ── load ─────────────────────────────────────────────────────────────────────

  @doc "Loads every region row as a plain map. boot 全量载入(单 shard)。"
  @spec load_all(keyword()) :: [map()]
  def load_all(opts \\ []) do
    repo = repo(opts)
    repo.all(VoxelRegionDirectory) |> Enum.map(&row_to_map/1)
  end

  @doc "Loads all region rows for one logical scene — the shard-load query path."
  @spec load_by_logical_scene(non_neg_integer(), keyword()) :: [map()]
  def load_by_logical_scene(logical_scene_id, opts \\ []) when is_integer(logical_scene_id) do
    repo = repo(opts)

    repo.all(from(r in VoxelRegionDirectory, where: r.logical_scene_id == ^logical_scene_id))
    |> Enum.map(&row_to_map/1)
  end

  @doc "Fetches one region row by id as a plain map (lazy-load path)."
  @spec get_region(non_neg_integer(), keyword()) :: {:ok, map()} | :error
  def get_region(region_id, opts \\ []) when is_integer(region_id) do
    repo = repo(opts)

    case repo.one(from(r in VoxelRegionDirectory, where: r.region_id == ^region_id)) do
      nil -> :error
      row -> {:ok, row_to_map(row)}
    end
  end

  @doc "Clears every region row. Test-only hatch."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    repo = repo(opts)
    repo.delete_all(VoxelRegionDirectory)
    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp normalize_row(attrs) do
    Map.new(@row_fields, fn field ->
      {field, fetch_field(attrs, field)}
    end)
  end

  # default region_state/region_version so partial maps (e.g. a put_region without
  # an explicit state) still produce a valid row.
  defp fetch_field(attrs, :region_state), do: Map.get(attrs, :region_state) || "active"
  defp fetch_field(attrs, :region_version), do: Map.get(attrs, :region_version) || 0
  defp fetch_field(attrs, field), do: Map.get(attrs, field)

  defp row_to_map(%VoxelRegionDirectory{} = row) do
    Map.new(@row_fields, fn field -> {field, Map.get(row, field)} end)
  end

  defp repo(opts), do: Keyword.get(opts, :repo, DataService.Repo)
end
