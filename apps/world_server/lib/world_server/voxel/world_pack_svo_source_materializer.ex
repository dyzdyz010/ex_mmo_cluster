defmodule WorldServer.Voxel.WorldPackSvoSourceMaterializer do
  @moduledoc """
  SVO confirmed-source 的服务端权威源物化入口。

  Voxia 远景 SVO 使用 tile 空间 coverage：水平 L∞ 半径、可选 near-skip，
  以及 `macro_cell_tiles` 步长。这里用同一套规则把客户端请求映射到
  canonical chunk snapshot store 的 coverage/materialization 计划。它只用于
  部署或显式工具链，不是客户端 runtime 缺包兜底。
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias WorldServer.Voxel.WorldPackBootstrapper

  @tile_size_chunks 7
  @default_max_chunks 100_000

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc """
  只读统计 SVO confirmed-source 的 canonical coverage。

  返回的计数与 `materialize/1` preflight 使用同一套规划规则，可直接用于
  CLI/observe 判断本次请求是否会超出预算。
  """
  @spec coverage(keyword()) :: {:ok, map()} | {:error, term()}
  def coverage(opts) when is_list(opts) do
    with {:ok, context} <- build_context(opts),
         {:ok, coverage} <- analyze_coverage(context) do
      status = if(coverage.missing_source_chunk_count == 0, do: :ready, else: :incomplete)
      {:ok, coverage_summary(context, coverage, status)}
    end
  end

  def coverage(_opts), do: {:error, :invalid_svo_source_materialization_options}

  @doc """
  按 SVO confirmed-source coverage 需求补 canonical snapshots。

  必填 option：

    * `:logical_scene_id`

  常用 option：

    * `:center_tile` - 默认 `{0, 0, 0}`
    * `:radius_tiles` - 默认 `72`
    * `:near_skip_radius_tiles` - 默认 `1`
    * `:macro_cell_tiles` - 默认 `1`，会 clamp 到 `1..4`
    * `:max_chunks` - 本次允许提交给 materializer 的 chunk 数预算
    * `:coverage_store` - 默认 `DataService.Voxel.ChunkSnapshotStore`
    * `:materializer` - 默认 `WorldPackBootstrapper.materialize_once/1`

  函数先做 coverage preflight；超预算时返回结构化拒绝，且不会调用
  materializer。
  """
  @spec materialize(keyword()) :: {:ok, map()} | {:error, term()}
  def materialize(opts) when is_list(opts) do
    with {:ok, context} <- build_context(opts),
         {:ok, coverage} <- analyze_coverage(context) do
      cond do
        coverage.planned_materialization_chunk_count > context.max_chunks ->
          summary = coverage_summary(context, coverage, :rejected)
          {:error, {:svo_source_materialization_exceeds_budget, summary}}

        coverage.missing_source_chunk_count == 0 ->
          {:ok, coverage_summary(context, coverage, :ready)}

        true ->
          materialize_missing_ranges(context, coverage)
      end
    end
  end

  def materialize(_opts), do: {:error, :invalid_svo_source_materialization_options}

  defp build_context(opts) do
    with {:ok, logical_scene_id} <-
           non_negative_integer(Keyword.get(opts, :logical_scene_id), :invalid_logical_scene_id),
         {:ok, center_tile} <- chunk_coord(Keyword.get(opts, :center_tile, {0, 0, 0})),
         {:ok, radius_tiles} <-
           non_negative_integer(Keyword.get(opts, :radius_tiles, 72), :invalid_radius_tiles),
         {:ok, near_skip_radius_tiles} <-
           near_skip_radius_tiles(Keyword.get(opts, :near_skip_radius_tiles, 1), radius_tiles),
         {:ok, macro_cell_tiles} <-
           macro_cell_tiles(Keyword.get(opts, :macro_cell_tiles, 1)),
         {:ok, max_chunks} <- max_chunks(Keyword.get(opts, :max_chunks, @default_max_chunks)),
         {:ok, materializer_opts} <- materializer_opts(opts) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         center_tile: center_tile,
         radius_tiles: radius_tiles,
         near_skip_radius_tiles: near_skip_radius_tiles,
         macro_cell_tiles: macro_cell_tiles,
         max_chunks: max_chunks,
         coverage_store: Keyword.get(opts, :coverage_store, ChunkSnapshotStore),
         materializer:
           Keyword.get(opts, :materializer, &WorldPackBootstrapper.materialize_once/1),
         batch_size: Keyword.get(opts, :batch_size, 64),
         materializer_opts: materializer_opts,
         seed: Keyword.get(opts, :seed),
         version: Keyword.get(opts, :version, "worldgen-v1"),
         content_version: Keyword.get(opts, :content_version, "svo-confirmed-source@1")
       }}
    end
  end

  defp analyze_coverage(context) do
    ranges = source_ranges(context)

    with {:empty, false} <- {:empty, ranges == []},
         {:ok, bounds_coverage} <-
           call_coverage_store(
             context.coverage_store,
             context.logical_scene_id,
             coverage_chunk_min(ranges),
             coverage_chunk_max(ranges)
           ),
         0 <- Map.fetch!(bounds_coverage, :in_bounds_chunk_count) do
      {:ok, empty_coverage(ranges)}
    else
      {:empty, true} ->
        {:ok, empty_coverage([])}

      {:error, reason} ->
        {:error, {:svo_source_coverage_failed, reason}}

      _needs_exact_scan ->
        analyze_ranges(context, ranges)
    end
  end

  defp analyze_ranges(context, ranges) do
    ranges
    |> Enum.reduce_while(
      {:ok,
       %{
         ranges: [],
         macro_cell_count: length(ranges),
         expected_source_chunk_count: 0,
         present_source_chunk_count: 0,
         missing_source_chunk_count: 0,
         planned_materialization_chunk_count: 0
       }},
      fn range, {:ok, acc} ->
        case call_coverage_store(
               context.coverage_store,
               context.logical_scene_id,
               range.chunk_min,
               range.chunk_max
             ) do
          {:ok, coverage} ->
            present = min(Map.fetch!(coverage, :in_bounds_chunk_count), range.chunk_count)
            missing = max(range.chunk_count - present, 0)
            incomplete? = missing > 0

            range =
              range
              |> Map.put(:present_chunk_count, present)
              |> Map.put(:missing_chunk_count, missing)
              |> Map.put(:status, if(incomplete?, do: :incomplete, else: :ready))

            {:cont,
             {:ok,
              %{
                acc
                | ranges: [range | acc.ranges],
                  expected_source_chunk_count:
                    acc.expected_source_chunk_count + range.chunk_count,
                  present_source_chunk_count: acc.present_source_chunk_count + present,
                  missing_source_chunk_count: acc.missing_source_chunk_count + missing,
                  planned_materialization_chunk_count:
                    acc.planned_materialization_chunk_count +
                      if(incomplete?, do: range.chunk_count, else: 0)
              }}}

          {:error, reason} ->
            {:halt, {:error, {:svo_source_coverage_failed, reason}}}
        end
      end
    )
    |> case do
      {:ok, coverage} -> {:ok, %{coverage | ranges: Enum.reverse(coverage.ranges)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp empty_coverage(ranges) do
    ranges =
      Enum.map(ranges, fn range ->
        range
        |> Map.put(:present_chunk_count, 0)
        |> Map.put(:missing_chunk_count, range.chunk_count)
        |> Map.put(:status, :incomplete)
      end)

    expected = Enum.reduce(ranges, 0, &(&1.chunk_count + &2))

    %{
      ranges: ranges,
      macro_cell_count: length(ranges),
      expected_source_chunk_count: expected,
      present_source_chunk_count: 0,
      missing_source_chunk_count: expected,
      planned_materialization_chunk_count: expected
    }
  end

  defp coverage_chunk_min(ranges) do
    Enum.reduce(ranges, nil, fn range, acc ->
      min_coord(acc, range.chunk_min)
    end)
  end

  defp coverage_chunk_max(ranges) do
    Enum.reduce(ranges, nil, fn range, acc ->
      max_coord(acc, range.chunk_max)
    end)
  end

  defp min_coord(nil, coord), do: coord

  defp min_coord({ax, ay, az}, {bx, by, bz}) do
    {min(ax, bx), min(ay, by), min(az, bz)}
  end

  defp max_coord(nil, coord), do: coord

  defp max_coord({ax, ay, az}, {bx, by, bz}) do
    {max(ax, bx), max(ay, by), max(az, bz)}
  end

  defp materialize_missing_ranges(context, coverage) do
    initial = coverage_summary(context, coverage, :materializing)

    coverage.ranges
    |> Enum.filter(&(&1.status == :incomplete))
    |> Enum.reduce_while({:ok, initial}, fn range, {:ok, acc} ->
      case call_materializer(context.materializer, materializer_call_opts(context, range)) do
        {:ok, summary} ->
          {:cont,
           {:ok,
            acc
            |> Map.update!(:materialized_macro_cell_count, &(&1 + 1))
            |> Map.update!(:materialized_chunk_count, &(&1 + range.chunk_count))
            |> Map.update!(:materialized_ranges, &(&1 ++ [range_summary(range, summary)]))}}

        {:error, reason} ->
          {:halt, {:error, materializer_failed_summary(acc, range, reason)}}

        other ->
          {:halt, {:error, materializer_failed_summary(acc, range, {:unexpected_result, other})}}
      end
    end)
    |> case do
      {:ok, summary} -> verify_after_materialization(context, summary)
      {:error, summary} -> {:error, {:svo_source_materialization_failed, summary}}
    end
  end

  defp verify_after_materialization(context, summary) do
    case analyze_coverage(context) do
      {:ok, coverage} ->
        summary = Map.merge(summary, final_coverage_fields(coverage))

        if coverage.missing_source_chunk_count == 0 do
          {:ok, Map.put(summary, :status, :ready)}
        else
          {:error, {:svo_source_materialization_incomplete, Map.put(summary, :status, :failed)}}
        end

      {:error, reason} ->
        {:error,
         {:svo_source_materialization_verification_failed,
          summary |> Map.put(:status, :failed) |> Map.put(:verification_error, inspect(reason))}}
    end
  end

  defp coverage_summary(context, coverage, status) do
    %{
      status: status,
      logical_scene_id: context.logical_scene_id,
      center_tile: context.center_tile,
      radius_tiles: context.radius_tiles,
      near_skip_radius_tiles: context.near_skip_radius_tiles,
      macro_cell_tiles: context.macro_cell_tiles,
      macro_cell_count: coverage.macro_cell_count,
      expected_source_chunk_count: coverage.expected_source_chunk_count,
      present_source_chunk_count: coverage.present_source_chunk_count,
      missing_source_chunk_count: coverage.missing_source_chunk_count,
      planned_materialization_chunk_count: coverage.planned_materialization_chunk_count,
      max_chunks: context.max_chunks,
      materialized_macro_cell_count: 0,
      materialized_chunk_count: 0,
      materialized_ranges: [],
      chunk_errors: []
    }
  end

  defp final_coverage_fields(coverage) do
    %{
      final_present_source_chunk_count: coverage.present_source_chunk_count,
      final_missing_source_chunk_count: coverage.missing_source_chunk_count,
      final_planned_materialization_chunk_count: coverage.planned_materialization_chunk_count
    }
  end

  defp source_ranges(context) do
    safe_step = context.macro_cell_tiles
    safe_radius = context.radius_tiles
    {center_x, center_y, center_z} = context.center_tile

    for tz <- (center_z - safe_radius)..(center_z + safe_radius)//safe_step,
        tx <- (center_x - safe_radius)..(center_x + safe_radius)//safe_step,
        should_cover?(context, {tx, center_y, tz}) do
      source_range_for_tile({tx, center_y, tz}, context.macro_cell_tiles)
    end
  end

  defp should_cover?(%{near_skip_radius_tiles: near_skip} = context, tile) do
    chebyshev_2d(tile, context.center_tile) <= context.radius_tiles and
      (near_skip < 0 or chebyshev_2d(tile, context.center_tile) > near_skip)
  end

  defp chebyshev_2d({x, _y, z}, {center_x, _center_y, center_z}) do
    max(abs(x - center_x), abs(z - center_z))
  end

  defp source_range_for_tile({tile_x, tile_y, tile_z} = tile, macro_cell_tiles) do
    chunks_per_axis = @tile_size_chunks * macro_cell_tiles

    chunk_min =
      {tile_x * @tile_size_chunks, tile_y * @tile_size_chunks, tile_z * @tile_size_chunks}

    chunk_max = {
      elem(chunk_min, 0) + chunks_per_axis - 1,
      elem(chunk_min, 1) + chunks_per_axis - 1,
      elem(chunk_min, 2) + chunks_per_axis - 1
    }

    %{
      tile: tile,
      chunk_min: chunk_min,
      chunk_max: chunk_max,
      chunk_count: chunks_per_axis * chunks_per_axis * chunks_per_axis
    }
  end

  defp materializer_call_opts(context, range) do
    [
      logical_scene_id: context.logical_scene_id,
      chunk_min: range.chunk_min,
      chunk_max: range.chunk_max,
      max_chunks: range.chunk_count,
      batch_size: context.batch_size,
      materializer_opts: context.materializer_opts,
      version: context.version,
      content_version: context.content_version,
      publish_auth_pack?: false
    ]
    |> maybe_put(:seed, context.seed)
  end

  defp range_summary(range, materializer_summary) do
    %{
      tile: range.tile,
      chunk_min: range.chunk_min,
      chunk_max: range.chunk_max,
      expected_chunk_count: range.chunk_count,
      present_before_chunk_count: range.present_chunk_count,
      missing_before_chunk_count: range.missing_chunk_count,
      materializer_summary: materializer_summary
    }
  end

  defp materializer_failed_summary(summary, range, reason) do
    error = %{
      tile: range.tile,
      chunk_min: range.chunk_min,
      chunk_max: range.chunk_max,
      expected_chunk_count: range.chunk_count,
      error: reason
    }

    summary
    |> Map.put(:status, :failed)
    |> Map.update!(:chunk_errors, &(&1 ++ [error]))
  end

  defp call_coverage_store(store, logical_scene_id, chunk_min, chunk_max)
       when is_function(store, 3),
       do: store.(logical_scene_id, chunk_min, chunk_max)

  defp call_coverage_store(store, logical_scene_id, chunk_min, chunk_max) when is_atom(store),
    do: store.coverage(logical_scene_id, chunk_min, chunk_max)

  defp call_coverage_store(_store, _logical_scene_id, _chunk_min, _chunk_max),
    do: {:error, :invalid_coverage_store}

  defp call_materializer(materializer, opts) when is_function(materializer, 1) do
    materializer.(opts)
  rescue
    exception -> {:error, {:materializer_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:materializer_exit, reason}}
    kind, reason -> {:error, {:materializer_catch, kind, reason}}
  end

  defp call_materializer(_materializer, _opts), do: {:error, :invalid_materializer}

  defp materializer_opts(opts) do
    case Keyword.get(opts, :materializer_opts, lod_projection?: false) do
      materializer_opts when is_list(materializer_opts) -> {:ok, materializer_opts}
      _other -> {:error, :invalid_materializer_opts}
    end
  end

  defp non_negative_integer(value, _reason) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp non_negative_integer(value, reason) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _other -> {:error, reason}
    end
  end

  defp non_negative_integer(_value, reason), do: {:error, reason}

  defp near_skip_radius_tiles(value, radius_tiles) do
    with {:ok, parsed} <- integer(value, :invalid_near_skip_radius_tiles) do
      {:ok, parsed |> max(-1) |> min(radius_tiles)}
    end
  end

  defp macro_cell_tiles(value) do
    with {:ok, parsed} <- integer(value, :invalid_macro_cell_tiles) do
      {:ok, parsed |> max(1) |> min(4)}
    end
  end

  defp max_chunks(value), do: non_negative_integer(value, :invalid_max_chunks)

  defp integer(value, _reason) when is_integer(value), do: {:ok, value}

  defp integer(value, reason) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _other -> {:error, reason}
    end
  end

  defp integer(_value, reason), do: {:error, reason}

  defp chunk_coord({x, y, z} = coord)
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {:ok, coord}

  defp chunk_coord([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp chunk_coord(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> case do
      [x, y, z] ->
        with {cx, ""} <- Integer.parse(x),
             {cy, ""} <- Integer.parse(y),
             {cz, ""} <- Integer.parse(z) do
          {:ok, {cx, cy, cz}}
        else
          _other -> {:error, :invalid_chunk_coord}
        end

      _other ->
        {:error, :invalid_chunk_coord}
    end
  end

  defp chunk_coord(_value), do: {:error, :invalid_chunk_coord}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
