defmodule DataService.Voxel.RegionEpochStore do
  @moduledoc """
  Linearizable `owner_epoch` allocator backed by `voxel_region_epochs`(梯队1 step1.3,
  CELL-18/23,消除 ANTI-32)。

  `allocate_next/2` 以**单条原子 SQL**(`INSERT ... ON CONFLICT DO UPDATE SET owner_epoch =
  owner_epoch + 1 RETURNING owner_epoch`)分配下一个 epoch。Postgres 行级序列化使其成为 epoch 的
  **唯一线性化点**——并发或重启的多个 `WorldServer.Voxel.MapLedger` 实例都无法分配冲突或回退的
  owner_epoch。这取代了"epoch 仅靠内存单进程 + 整库 blob 自增"(ANTI-32:failover 后 epoch 可能回退/双主)。

  `set_floor/3` 用于从旧 blob 状态迁移时把 DB epoch 抬到不低于既有值(`GREATEST`),保证收敛期单调。

  stateless module,直走 `DataService.Repo`(`opts[:repo]` 可覆盖,测试用)。状态分类见
  `MmoContracts.StateRegistry`(durable_authoritative)。
  """

  alias DataService.Repo

  @doc """
  原子分配并返回该 region 的下一个 `owner_epoch`(首次为 1,其后单调 +1)。
  """
  @spec allocate_next(non_neg_integer(), non_neg_integer(), keyword()) :: non_neg_integer()
  def allocate_next(logical_scene_id, region_id, opts \\ [])
      when is_integer(logical_scene_id) and is_integer(region_id) do
    sql = """
    INSERT INTO voxel_region_epochs (logical_scene_id, region_id, owner_epoch, inserted_at, updated_at)
    VALUES ($1, $2, 1, now(), now())
    ON CONFLICT (logical_scene_id, region_id)
    DO UPDATE SET owner_epoch = voxel_region_epochs.owner_epoch + 1, updated_at = now()
    RETURNING owner_epoch
    """

    %{rows: [[epoch]]} =
      Ecto.Adapters.SQL.query!(repo(opts), sql, [logical_scene_id, region_id])

    epoch
  end

  @doc "返回该 region 当前 epoch(未分配过则 0)。"
  @spec current(non_neg_integer(), non_neg_integer(), keyword()) :: non_neg_integer()
  def current(logical_scene_id, region_id, opts \\ []) do
    sql =
      "SELECT owner_epoch FROM voxel_region_epochs WHERE logical_scene_id = $1 AND region_id = $2"

    case Ecto.Adapters.SQL.query!(repo(opts), sql, [logical_scene_id, region_id]) do
      %{rows: [[epoch]]} -> epoch
      %{rows: []} -> 0
    end
  end

  @doc """
  把该 region 的 DB epoch 抬到不低于 `floor`(迁移收敛用)。返回生效后的 epoch。
  """
  @spec set_floor(non_neg_integer(), non_neg_integer(), non_neg_integer(), keyword()) ::
          non_neg_integer()
  def set_floor(logical_scene_id, region_id, floor, opts \\ [])
      when is_integer(floor) and floor >= 0 do
    sql = """
    INSERT INTO voxel_region_epochs (logical_scene_id, region_id, owner_epoch, inserted_at, updated_at)
    VALUES ($1, $2, $3, now(), now())
    ON CONFLICT (logical_scene_id, region_id)
    DO UPDATE SET owner_epoch = GREATEST(voxel_region_epochs.owner_epoch, EXCLUDED.owner_epoch),
                  updated_at = now()
    RETURNING owner_epoch
    """

    %{rows: [[epoch]]} =
      Ecto.Adapters.SQL.query!(repo(opts), sql, [logical_scene_id, region_id, floor])

    epoch
  end

  @doc "清空全部 region epoch(test-only hatch)。"
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    Ecto.Adapters.SQL.query!(repo(opts), "DELETE FROM voxel_region_epochs", [])
    :ok
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
