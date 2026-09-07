defmodule DataService.Voxel.OverlayLogStore do
  # PERS:durable_authoritative（Voxim R6 region 世界的权威 overlay 日志）。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  @moduledoc """
  `voxel_overlay_log` 表的读写：`VoxelRegion.World` 的 overlay 日志（决策稿 §9 第 1 项）。

  行 = 事务内一个条目 `%{seq, ordinal, kind, level, region: {x, y, z}, payload}`，按 `content_version` 分世界；
  `read_all/2` 按 `(seq, ordinal)` 升序返回整个世界的日志，`append/3` 追加一笔事务的行，`replace/3` 在一个数据库事务里
  删掉该世界全部行并写入检查点事务（World 压实规则）。stateless，直走 `DataService.Repo`（`opts[:repo]` 可覆盖）。
  `content_version` 是 u64，这里按 64 位补码存进 bigint。
  """

  alias DataService.Repo

  @type row :: %{
          seq: non_neg_integer(),
          ordinal: non_neg_integer(),
          kind: 0..2,
          level: non_neg_integer(),
          region: {integer(), integer(), integer()},
          payload: binary()
        }

  # 一次 INSERT 多行：压实会整表重写（检查点上千行），逐行 round trip 实测占了稠密事务的大头。Postgres 参数上限 65535，9 列 → 每批 500 行。
  @columns 9
  @batch 500

  @spec append(non_neg_integer(), [row()], keyword()) :: :ok
  def append(content_version, rows, opts \\ []) do
    repo = repo(opts)
    {:ok, :ok} = repo.transaction(fn -> insert_rows(repo, signed(content_version), rows) end)
    :ok
  end

  @spec replace(non_neg_integer(), [row()], keyword()) :: :ok
  def replace(content_version, rows, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)

    {:ok, :ok} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM voxel_overlay_log WHERE content_version = $1", [cv])
        insert_rows(repo, cv, rows)
      end)

    :ok
  end

  @spec read_all(non_neg_integer(), keyword()) :: [row()]
  def read_all(content_version, opts \\ []) do
    sql = """
    SELECT seq, ordinal, kind, level, region_x, region_y, region_z, payload
    FROM voxel_overlay_log WHERE content_version = $1
    ORDER BY seq ASC, ordinal ASC
    """

    %{rows: rows} = Ecto.Adapters.SQL.query!(repo(opts), sql, [signed(content_version)])

    Enum.map(rows, fn [seq, ordinal, kind, level, x, y, z, payload] ->
      %{seq: seq, ordinal: ordinal, kind: kind, level: level, region: {x, y, z}, payload: payload}
    end)
  end

  @doc "清空（test-only）。"
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    Ecto.Adapters.SQL.query!(repo(opts), "DELETE FROM voxel_overlay_log", [])
    :ok
  end

  defp insert_rows(repo, cv, rows) do
    rows
    |> Enum.chunk_every(@batch)
    |> Enum.each(fn chunk ->
      values =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_row, i} ->
          "(" <> Enum.map_join(1..@columns, ", ", &"$#{i * @columns + &1}") <> ")"
        end)

      params =
        Enum.flat_map(chunk, fn %{seq: seq, ordinal: ordinal, kind: kind, level: level, region: {x, y, z}, payload: payload} ->
          [cv, seq, ordinal, kind, level, x, y, z, payload]
        end)

      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO voxel_overlay_log (content_version, seq, ordinal, kind, level, region_x, region_y, region_z, payload) VALUES " <> values,
        params
      )
    end)

    :ok
  end

  defp signed(cv) do
    <<value::64-signed>> = <<cv::64>>
    value
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
