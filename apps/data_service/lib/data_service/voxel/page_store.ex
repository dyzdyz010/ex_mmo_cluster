defmodule DataService.Voxel.PageStore do
  @moduledoc """
  PERS:durable_authoritative —— M2a 页表（`voxel_page_segment` / `voxel_world_globals` / `voxel_safe_prefix`，见迁移
  `20261026000001_create_voxel_page_store.exs` 与 `m2a-page-store.md` §6）。

  只存行，不解释段内容（段编码与归属由 `VoxelRegion.World.Pages` 唯一定义）。所有语句按 `content_version` 隔离。

  写回尝试（§6.1）：`clear_unpublished/3` 删掉高于已发布前缀的残留 → `write/4` 分批新增切点 C 的段 → `publish/5` 在同一 PG 事务里
  写最后一批、全局行并把前缀推进到 C（只增不减）。恢复（§6.2）：`load/2` 在一个只读 REPEATABLE READ 事务里读前缀、每段可见版本、
  同前缀的全局行与日志后缀。删除（§6.2）：`collect/4` 每次最多删一批已退休的日志行、被取代的段版本与旧全局行。
  """

  alias DataService.Repo

  @type segment_row :: %{
          level: integer(),
          region: {integer(), integer(), integer()},
          segment: integer(),
          chunk: {integer(), integer(), integer()},
          payload: binary()
        }

  @columns 11
  @batch 400

  @doc "已发布的安全前缀；没有（未初始化 / 未迁移）为 nil。"
  def prefix(content_version, opts \\ []) do
    case Ecto.Adapters.SQL.query!(repo(opts), "SELECT seq FROM voxel_safe_prefix WHERE content_version = $1", [signed(content_version)]) do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> nil
    end
  end

  @doc "删除高于 `prefix`（nil = 全部）的段版本与全局行：未发布尝试的残留，或迁移前清空。"
  def clear_unpublished(content_version, prefix, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)
    floor = prefix || -1

    {:ok, :ok} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM voxel_page_segment WHERE content_version = $1 AND cut_seq > $2", [cv, floor])
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM voxel_world_globals WHERE content_version = $1 AND cut_seq > $2", [cv, floor])
        :ok
      end)

    :ok
  end

  @doc """
  新增切点 `cut_seq` 的一批段（不可见，直到该切点发布）。`rows` 里带 `:locator` 键的是身份定位行（M2b），与段同一 PG 事务写入；
  定位行只插入（根与根 home 不变，`ON CONFLICT DO NOTHING`），不随切点版本化。
  """
  def write(content_version, cut_seq, rows, opts \\ []) do
    repo = repo(opts)
    {:ok, :ok} = repo.transaction(fn -> insert_rows(repo, signed(content_version), cut_seq, rows) end)
    :ok
  end

  @doc """
  发布切点 `cut_seq`：最后一批段、全局行与前缀推进在同一 PG 事务；前缀只增不减。事务先锁住并读前缀：已不低于 `cut_seq`
  （确认丢失后重发，或已被取代的旧尝试）即什么都不写、回滚并返回 `{:error, {:prefix, p}}`，由调用方按 `p == cut_seq`
  判定为已发布、否则失败（§6.1 第 3 步，不把影响 0 行当成功）。推进影响 0 行同样回滚并返回该错误。
  """
  def publish(content_version, cut_seq, rows, globals, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)

    repo.transaction(fn ->
      case Ecto.Adapters.SQL.query!(repo, "SELECT seq FROM voxel_safe_prefix WHERE content_version = $1 FOR UPDATE", [cv]).rows do
        [[p]] when p >= cut_seq -> repo.rollback({:prefix, p})
        _ -> :ok
      end

      insert_rows(repo, cv, cut_seq, rows)
      Ecto.Adapters.SQL.query!(repo, "INSERT INTO voxel_world_globals (content_version, cut_seq, payload) VALUES ($1, $2, $3)", [cv, cut_seq, globals])

      %{num_rows: n} =
        Ecto.Adapters.SQL.query!(
          repo,
          "INSERT INTO voxel_safe_prefix (content_version, seq) VALUES ($1, $2) " <>
            "ON CONFLICT (content_version) DO UPDATE SET seq = EXCLUDED.seq WHERE voxel_safe_prefix.seq < EXCLUDED.seq",
          [cv, cut_seq]
        )

      if n != 1, do: repo.rollback({:prefix, prefix(content_version, opts)})
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  恢复读取：前缀、每个段 `max(cut_seq) <= 前缀` 的版本、前缀的全局行与日志 `seq > 前缀` 的行，同一只读 REPEATABLE READ 快照。
  没有前缀时返回 `%{prefix: nil}`。
  """
  def load(content_version, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)

    {:ok, loaded} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])

        case Ecto.Adapters.SQL.query!(repo, "SELECT seq FROM voxel_safe_prefix WHERE content_version = $1", [cv]).rows do
          [] ->
            %{prefix: nil}

          [[p]] ->
            %{rows: segments} =
              Ecto.Adapters.SQL.query!(
                repo,
                "SELECT DISTINCT ON (level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z) " <>
                  "level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z, payload FROM voxel_page_segment " <>
                  "WHERE content_version = $1 AND cut_seq <= $2 " <>
                  "ORDER BY level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z, cut_seq DESC",
                [cv, p]
              )

            %{rows: [[globals]]} =
              Ecto.Adapters.SQL.query!(repo, "SELECT payload FROM voxel_world_globals WHERE content_version = $1 AND cut_seq = $2", [cv, p])

            %{rows: log} =
              Ecto.Adapters.SQL.query!(
                repo,
                "SELECT seq, ordinal, kind, level, region_x, region_y, region_z, payload FROM voxel_overlay_log " <>
                  "WHERE content_version = $1 AND seq > $2 ORDER BY seq ASC, ordinal ASC",
                [cv, p]
              )

            %{
              prefix: p,
              globals: globals,
              segments:
                Enum.map(segments, fn [l, x, y, z, s, cx, cy, cz, payload] ->
                  %{level: l, region: {x, y, z}, segment: s, chunk: {cx, cy, cz}, payload: payload}
                end),
              log:
                Enum.map(log, fn [seq, ordinal, kind, level, x, y, z, payload] ->
                  %{seq: seq, ordinal: ordinal, kind: kind, level: level, region: {x, y, z}, payload: payload}
                end)
            }
        end
      end)

    loaded
  end

  @doc "按已发布前缀渐进删除：每类最多 `limit` 行（日志 `seq <= 前缀`、被可见版本取代的段、旧全局行）；返回删掉的总行数。"
  def collect(content_version, prefix, limit, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)

    statements = [
      "DELETE FROM voxel_overlay_log WHERE ctid IN (SELECT ctid FROM voxel_overlay_log WHERE content_version = $1 AND seq <= $2 LIMIT $3)",
      "DELETE FROM voxel_page_segment WHERE ctid IN (SELECT o.ctid FROM voxel_page_segment o WHERE o.content_version = $1 AND o.cut_seq < $2 " <>
        "AND EXISTS (SELECT 1 FROM voxel_page_segment n WHERE n.content_version = o.content_version AND n.level = o.level " <>
        "AND n.region_x = o.region_x AND n.region_y = o.region_y AND n.region_z = o.region_z AND n.segment = o.segment " <>
        "AND n.chunk_x = o.chunk_x AND n.chunk_y = o.chunk_y AND n.chunk_z = o.chunk_z AND n.cut_seq > o.cut_seq AND n.cut_seq <= $2) LIMIT $3)",
      "DELETE FROM voxel_world_globals WHERE ctid IN (SELECT ctid FROM voxel_world_globals WHERE content_version = $1 AND cut_seq < $2 LIMIT $3)"
    ]

    Enum.reduce(statements, 0, fn sql, n -> n + Ecto.Adapters.SQL.query!(repo, sql, [cv, prefix, limit]).num_rows end)
  end

  @doc """
  M2b 启动读取（按需装页，`m2b-on-demand-pages.md` §2.5）：同一只读 REPEATABLE READ 快照里读前缀、前缀的全局行、日志 `seq > 前缀`
  与活动索引（`activity_segment` 段在前缀下的可见版本：`[%{region, payload}]`，L0 页）。不读其他页段。没有前缀时 `%{prefix: nil}`。
  """
  def load_head(content_version, activity_segment, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)

    {:ok, loaded} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])

        case Ecto.Adapters.SQL.query!(repo, "SELECT seq FROM voxel_safe_prefix WHERE content_version = $1", [cv]).rows do
          [] ->
            %{prefix: nil}

          [[p]] ->
            %{rows: [[globals]]} =
              Ecto.Adapters.SQL.query!(repo, "SELECT payload FROM voxel_world_globals WHERE content_version = $1 AND cut_seq = $2", [cv, p])

            %{rows: log} =
              Ecto.Adapters.SQL.query!(
                repo,
                "SELECT seq, ordinal, kind, level, region_x, region_y, region_z, payload FROM voxel_overlay_log " <>
                  "WHERE content_version = $1 AND seq > $2 ORDER BY seq ASC, ordinal ASC",
                [cv, p]
              )

            %{rows: activity} =
              Ecto.Adapters.SQL.query!(
                repo,
                "SELECT DISTINCT ON (region_x, region_y, region_z) region_x, region_y, region_z, payload FROM voxel_page_segment " <>
                  "WHERE content_version = $1 AND level = 0 AND segment = $2 AND cut_seq <= $3 " <>
                  "ORDER BY region_x, region_y, region_z, cut_seq DESC",
                [cv, activity_segment, p]
              )

            %{
              prefix: p,
              globals: globals,
              log:
                Enum.map(log, fn [seq, ordinal, kind, level, x, y, z, payload] ->
                  %{seq: seq, ordinal: ordinal, kind: kind, level: level, region: {x, y, z}, payload: payload}
                end),
              activity: Enum.map(activity, fn [x, y, z, payload] -> %{region: {x, y, z}, payload: payload} end)
            }
        end
      end)

    loaded
  end

  @doc """
  M2b 按需装页：当前已发布前缀下这些页的可见段版本，同一只读 REPEATABLE READ 快照（前缀与段一致）。
  - L0 页 `{0, p}`：`level = 0` 且区域为 p 的全部段，加区域为 p、段在 `fragment_segments` 的粗层片段行（`level` 1..5）；
  - 粗层页 `{L, r}`：`level = L` 且区域为 r、段不在片段段内的行，加 `level = L`、段在片段段内、区域（L0 坐标）落在 r 覆盖的 L0 页内的片段行。
  返回 `%{prefix, rows}`（行同 `load/2` 的段行）；没有前缀时 `rows` 为空。页段语义由调用方解释。
  """
  def read_pages(content_version, keys, fragment_segments, opts \\ []) do
    repo = repo(opts)
    cv = signed(content_version)
    {l0, coarse} = Enum.split_with(keys, fn {level, _} -> level == 0 end)
    columns = "level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z, payload"
    distinct = "SELECT DISTINCT ON (level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z) "
    order = " ORDER BY level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z, cut_seq DESC"

    {:ok, loaded} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])

        case Ecto.Adapters.SQL.query!(repo, "SELECT seq FROM voxel_safe_prefix WHERE content_version = $1", [cv]).rows do
          [] ->
            %{prefix: nil, rows: []}

          [[p]] ->
            {xs, ys, zs} = axes(Enum.map(l0, &elem(&1, 1)))

            l0_rows =
              if l0 == [] do
                []
              else
                Ecto.Adapters.SQL.query!(
                  repo,
                  distinct <> columns <>
                    " FROM voxel_page_segment s JOIN unnest($3::int[], $4::int[], $5::int[]) AS k(x, y, z) " <>
                    "ON s.region_x = k.x AND s.region_y = k.y AND s.region_z = k.z " <>
                    "WHERE s.content_version = $1 AND s.cut_seq <= $2 AND (s.level = 0 OR s.segment = ANY($6::smallint[]))" <> order,
                  [cv, p, xs, ys, zs, fragment_segments]
                ).rows
              end

            # 粗层页按级一条查询（同级的全部页键一次 unnest）：本页的非片段行按区域相等；片段行的区域是 L0 坐标，算术右移 level 位
            # （= 向负无穷整除 2^level）即所属粗层页。窗口预备一次带上百个粗层页键，逐键查询会让首次装页慢一个数量级。
            coarse_rows =
              coarse
              |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
              |> Enum.flat_map(fn {level, regions} ->
                {cx, cy, cz} = axes(regions)

                Ecto.Adapters.SQL.query!(
                  repo,
                  distinct <> columns <>
                    " FROM voxel_page_segment s JOIN unnest($4::int[], $5::int[], $6::int[]) AS k(x, y, z) ON " <>
                    "(NOT s.segment = ANY($7::smallint[]) AND s.region_x = k.x AND s.region_y = k.y AND s.region_z = k.z) OR " <>
                    "(s.segment = ANY($7::smallint[]) AND (s.region_x >> $3) = k.x AND (s.region_y >> $3) = k.y AND (s.region_z >> $3) = k.z) " <>
                    "WHERE s.content_version = $1 AND s.cut_seq <= $2 AND s.level = $3" <> order,
                  [cv, p, level, cx, cy, cz, fragment_segments]
                ).rows
              end)

            %{prefix: p, rows: Enum.map(l0_rows ++ coarse_rows, &segment_row/1)}
        end
      end)

    loaded
  end

  @doc "身份定位：`ids` 为 `{kind, a, b}`；返回 `%{{kind, a, b} => %{root: {ra, rb}, home: {x, y, z}}}`（查不到的 id 不在结果里）。"
  def locate(content_version, ids, opts \\ []) do
    if ids == [] do
      %{}
    else
      {kinds, as, bs} = axes(ids)

      Ecto.Adapters.SQL.query!(
        repo(opts),
        "SELECT l.kind, l.id_a, l.id_b, l.root_a, l.root_b, l.home_x, l.home_y, l.home_z FROM voxel_identity_locator l " <>
          "JOIN unnest($2::smallint[], $3::bigint[], $4::bigint[]) AS k(kind, a, b) ON l.kind = k.kind AND l.id_a = k.a AND l.id_b = k.b " <>
          "WHERE l.content_version = $1",
        [signed(content_version), kinds, as, bs]
      ).rows
      |> Map.new(fn [kind, a, b, ra, rb, x, y, z] -> {{kind, a, b}, %{root: {ra, rb}, home: {x, y, z}}} end)
    end
  end

  @doc "已发布前缀下有可见段的全部 `{level, region, segment}`（维护入口装全部页用；O(页数)）。"
  def page_keys(content_version, opts \\ []) do
    case prefix(content_version, opts) do
      nil ->
        []

      p ->
        Ecto.Adapters.SQL.query!(
          repo(opts),
          "SELECT DISTINCT level, region_x, region_y, region_z, segment FROM voxel_page_segment WHERE content_version = $1 AND cut_seq <= $2",
          [signed(content_version), p]
        ).rows
        |> Enum.map(fn [l, x, y, z, s] -> {l, {x, y, z}, s} end)
    end
  end

  defp axes(tuples) do
    {Enum.map(tuples, &elem(&1, 0)), Enum.map(tuples, &elem(&1, 1)), Enum.map(tuples, &elem(&1, 2))}
  end

  defp segment_row([l, x, y, z, s, cx, cy, cz, payload]),
    do: %{level: l, region: {x, y, z}, segment: s, chunk: {cx, cy, cz}, payload: payload}

  defp insert_rows(repo, cv, cut_seq, rows) do
    {locators, segments} = Enum.split_with(rows, &Map.has_key?(&1, :locator))
    insert_segments(repo, cv, cut_seq, segments)

    locators
    |> Enum.chunk_every(@batch)
    |> Enum.each(fn chunk ->
      values = chunk |> Enum.with_index() |> Enum.map_join(", ", fn {_, i} -> "(" <> Enum.map_join(1..9, ", ", &"$#{i * 9 + &1}") <> ")" end)

      params =
        Enum.flat_map(chunk, fn %{locator: {kind, a, b}, root: {ra, rb}, home: {x, y, z}} -> [cv, kind, a, b, ra, rb, x, y, z] end)

      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO voxel_identity_locator (content_version, kind, id_a, id_b, root_a, root_b, home_x, home_y, home_z) VALUES " <>
          values <> " ON CONFLICT DO NOTHING",
        params
      )
    end)

    :ok
  end

  defp insert_segments(repo, cv, cut_seq, rows) do
    rows
    |> Enum.chunk_every(@batch)
    |> Enum.each(fn chunk ->
      values =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_row, i} -> "(" <> Enum.map_join(1..@columns, ", ", &"$#{i * @columns + &1}") <> ")" end)

      params =
        Enum.flat_map(chunk, fn %{level: l, region: {x, y, z}, segment: s, chunk: {cx, cy, cz}, payload: payload} ->
          [cv, l, x, y, z, s, cx, cy, cz, cut_seq, payload]
        end)

      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO voxel_page_segment (content_version, level, region_x, region_y, region_z, segment, chunk_x, chunk_y, chunk_z, cut_seq, payload) VALUES " <>
          values,
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
