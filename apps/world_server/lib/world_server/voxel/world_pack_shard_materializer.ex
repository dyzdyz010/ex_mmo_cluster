defmodule WorldServer.Voxel.WorldPackShardMaterializer do
  @moduledoc """
  Resumable shard-level materialization for full world-pack authority data.

  The final 32km authority data set is too large for one monolithic in-memory
  coordinate list. This module plans work at the `.vxpack` payload shard level:
  each shard is checked against canonical snapshot coverage, ready shards are
  skipped, missing shards are materialized through the existing
  `WorldPackBootstrapper` path, and coverage is checked again before progress is
  reported.

  This is still an offline/deployment tool. It is not a runtime fallback for
  missing client baseline data.
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.WorldPackBootstrapper

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc """
  Materializes missing canonical snapshots one payload shard at a time.

  Options:

    * `:coverage_store` - module with `coverage/3` or function arity 3
    * `:materializer` - function arity 1; defaults to
      `WorldPackBootstrapper.materialize_once/1`
    * `:shard_coords` - explicit shard coordinates to consider
    * `:max_shards` - max incomplete shards to materialize in this invocation
    * `:batch_size` - forwarded to `WorldPackBootstrapper`
    * `:materializer_opts` - forwarded to `WorldPackBootstrapper`
    * `:seed` - forwarded to default WorldGen materializer

  `:max_shards` limits write work, not skip checks. Already-ready shards do not
  consume the limit, allowing the same command to be rerun until all shards are
  ready.
  """
  @spec materialize(WorldPackIndex.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def materialize(index, opts \\ [])

  def materialize(%WorldPackIndex{} = index, opts) when is_list(opts) do
    with {:ok, index_summary} <- verify_authority_index(index),
         {:ok, grid} <- WorldPackIndex.payload_shard_grid(index),
         {:ok, shard_coords} <- requested_shard_coords(grid, opts),
         {:ok, max_shards} <- max_shards(opts),
         {:ok, materializer_opts} <- materializer_opts(opts) do
      context = %{
        index: index,
        grid: grid,
        index_summary: index_summary,
        coverage_store: Keyword.get(opts, :coverage_store, ChunkSnapshotStore),
        materializer: Keyword.get(opts, :materializer, &WorldPackBootstrapper.materialize_once/1),
        batch_size: Keyword.get(opts, :batch_size, 64),
        materializer_opts: materializer_opts,
        seed: Keyword.get(opts, :seed),
        version: Keyword.get(opts, :version, "worldgen-v1"),
        content_version: Keyword.get(opts, :content_version, index.content_version),
        max_shards: max_shards
      }

      run_shards(context, shard_coords)
    end
  end

  def materialize(_index, _opts),
    do: {:error, :invalid_world_pack_shard_materialization_options}

  defp verify_authority_index(index) do
    case WorldPackIndex.verify(index) do
      {:ok, summary} -> {:ok, summary}
      {:error, summary} -> {:error, {:invalid_world_pack_index, summary}}
    end
  end

  defp requested_shard_coords(grid, opts) do
    case Keyword.get(opts, :shard_coords) do
      nil ->
        {:ok, grid.shard_coords}

      coords when is_list(coords) ->
        valid = MapSet.new(grid.shard_coords)

        if Enum.all?(coords, &MapSet.member?(valid, &1)) do
          {:ok, Enum.uniq(coords)}
        else
          {:error, :world_pack_shard_coord_out_of_bounds}
        end

      _other ->
        {:error, :invalid_world_pack_shard_coords}
    end
  end

  defp max_shards(opts) do
    case Keyword.get(opts, :max_shards) do
      nil -> {:ok, :infinity}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :invalid_world_pack_max_shards}
    end
  end

  defp materializer_opts(opts) do
    case Keyword.get(opts, :materializer_opts, []) do
      materializer_opts when is_list(materializer_opts) -> {:ok, materializer_opts}
      _other -> {:error, :invalid_materializer_opts}
    end
  end

  defp run_shards(context, shard_coords) do
    with {:ok, initial_coverage} <- index_coverage(context) do
      initial =
        %{
          logical_scene_id: context.index.logical_scene_id,
          content_version: context.content_version,
          status: :partial,
          index_expected_chunks: context.index_summary.expected_chunk_count,
          index_region_covered_chunks: context.index_summary.covered_chunk_count,
          expected_shards: context.grid.shard_count,
          selected_shards: length(shard_coords),
          ready_before_shards: 0,
          skipped_shards: 0,
          materialized_shards: 0,
          remaining_unready_shards: 0,
          planned_chunks: 0,
          materialized_chunks: 0,
          errors: 0,
          shards_skipped: [],
          shards_materialized: [],
          chunk_errors: []
        }
        |> put_initial_canonical_coverage(initial_coverage)

      shard_coords
      |> Enum.reduce_while({:ok, initial, 0}, fn shard_coord, {:ok, summary, written_shards} ->
        case materialize_or_skip_shard(context, shard_coord, summary, written_shards) do
          {:ok, next_summary, next_written_shards} ->
            {:cont, {:ok, next_summary, next_written_shards}}

          {:error, reason, failed_summary} ->
            {:halt, {:error, reason, failed_summary}}
        end
      end)
      |> case do
        {:ok, summary, _written_shards} ->
          with {:ok, final_coverage} <- index_coverage(context) do
            {:ok, summary |> put_final_canonical_coverage(final_coverage) |> finalize_status()}
          end

        {:error, reason, summary} ->
          failed_summary =
            summary
            |> Map.put(:status, :failed)
            |> maybe_put_final_canonical_coverage(context)

          {:error, {reason, finalize_status(failed_summary)}}
      end
    end
  end

  defp materialize_or_skip_shard(context, shard_coord, summary, written_shards) do
    with {:ok, shard} <- WorldPackIndex.payload_shard_summary(context.index, shard_coord),
         {:ok, before_status} <- shard_coverage(context, shard) do
      cond do
        before_status.ready? ->
          skipped = %{
            shard_coord: shard_coord,
            path: shard.path,
            status: :skipped_ready,
            expected_chunk_count: shard.chunk_count,
            present_chunk_count: before_status.present_chunk_count
          }

          {:ok,
           summary
           |> Map.update!(:ready_before_shards, &(&1 + 1))
           |> Map.update!(:skipped_shards, &(&1 + 1))
           |> Map.update!(:shards_skipped, &(&1 ++ [skipped])), written_shards}

        reached_work_limit?(context.max_shards, written_shards) ->
          {:ok, Map.update!(summary, :remaining_unready_shards, &(&1 + 1)), written_shards}

        true ->
          materialize_missing_shard(context, shard, summary, written_shards, before_status)
      end
    end
  end

  defp materialize_missing_shard(context, shard, summary, written_shards, before_status) do
    opts = materializer_call_opts(context, shard)

    case call_materializer(context.materializer, opts) do
      {:ok, materializer_summary} ->
        with {:ok, after_status} <- shard_coverage(context, shard) do
          if after_status.ready? do
            materialized = %{
              shard_coord: shard.shard_coord,
              path: shard.path,
              status: :materialized,
              expected_chunk_count: shard.chunk_count,
              present_before_chunk_count: before_status.present_chunk_count,
              present_after_chunk_count: after_status.present_chunk_count,
              materializer_summary: materializer_summary
            }

            {:ok,
             summary
             |> Map.update!(:materialized_shards, &(&1 + 1))
             |> Map.update!(:planned_chunks, &(&1 + shard.chunk_count))
             |> Map.update!(:materialized_chunks, &(&1 + shard.chunk_count))
             |> Map.update!(:shards_materialized, &(&1 ++ [materialized])), written_shards + 1}
          else
            {:error, :world_pack_shard_materialization_incomplete,
             incomplete_summary(summary, shard, after_status)}
          end
        end

      {:error, reason} ->
        {:error, :world_pack_shard_materialization_failed,
         materializer_failed_summary(summary, shard, reason)}

      other ->
        {:error, :world_pack_shard_materialization_failed,
         materializer_failed_summary(summary, shard, {:unexpected_materializer_result, other})}
    end
  end

  defp reached_work_limit?(:infinity, _written_shards), do: false
  defp reached_work_limit?(max_shards, written_shards), do: written_shards >= max_shards

  defp materializer_call_opts(context, shard) do
    opts = [
      logical_scene_id: context.index.logical_scene_id,
      chunk_min: shard.chunk_min,
      chunk_max: shard.chunk_max,
      max_chunks: shard.chunk_count,
      batch_size: context.batch_size,
      materializer_opts: context.materializer_opts,
      version: context.version,
      content_version: context.content_version,
      publish_auth_pack?: false
    ]

    maybe_put_seed(opts, context.seed)
  end

  defp maybe_put_seed(opts, nil), do: opts
  defp maybe_put_seed(opts, seed), do: Keyword.put(opts, :seed, seed)

  defp call_materializer(materializer, opts) when is_function(materializer, 1) do
    materializer.(opts)
  rescue
    exception -> {:error, {:materializer_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:materializer_exit, reason}}
    kind, reason -> {:error, {:materializer_catch, kind, reason}}
  end

  defp call_materializer(_materializer, _opts), do: {:error, :invalid_materializer}

  defp shard_coverage(context, shard) do
    with {:ok, coverage} <-
           call_coverage_store(
             context.coverage_store,
             context.index.logical_scene_id,
             shard.chunk_min,
             shard.chunk_max
           ) do
      present = Map.fetch!(coverage, :in_bounds_chunk_count)

      {:ok,
       %{
         ready?: present == shard.chunk_count,
         present_chunk_count: present,
         expected_chunk_count: shard.chunk_count,
         coverage: coverage
       }}
    end
  end

  defp call_coverage_store(store, logical_scene_id, chunk_min, chunk_max)
       when is_function(store, 3),
       do: store.(logical_scene_id, chunk_min, chunk_max)

  defp call_coverage_store(store, logical_scene_id, chunk_min, chunk_max) when is_atom(store),
    do: store.coverage(logical_scene_id, chunk_min, chunk_max)

  defp call_coverage_store(_store, _logical_scene_id, _chunk_min, _chunk_max),
    do: {:error, :invalid_coverage_store}

  defp index_coverage(context) do
    with {:ok, coverage} <-
           call_coverage_store(
             context.coverage_store,
             context.index.logical_scene_id,
             context.index.chunk_min,
             context.index.chunk_max
           ) do
      {:ok, normalize_index_coverage(context.index, coverage)}
    end
  end

  defp normalize_index_coverage(index, coverage) do
    expected = WorldPackIndex.chunk_count(index)
    in_bounds = Map.fetch!(coverage, :in_bounds_chunk_count)
    out_of_bounds = Map.get(coverage, :out_of_bounds_chunk_count, 0)

    %{
      total_scene_chunks: Map.get(coverage, :total_scene_chunk_count),
      in_bounds_chunks: in_bounds,
      out_of_bounds_chunks: out_of_bounds,
      missing_chunks: max(expected - in_bounds, 0)
    }
  end

  defp put_initial_canonical_coverage(summary, coverage) do
    Map.merge(summary, %{
      canonical_initial_total_scene_chunks: coverage.total_scene_chunks,
      canonical_initial_in_bounds_chunks: coverage.in_bounds_chunks,
      canonical_initial_out_of_bounds_chunks: coverage.out_of_bounds_chunks,
      canonical_initial_missing_chunks: coverage.missing_chunks
    })
  end

  defp put_final_canonical_coverage(summary, coverage) do
    Map.merge(summary, %{
      canonical_final_total_scene_chunks: coverage.total_scene_chunks,
      canonical_final_in_bounds_chunks: coverage.in_bounds_chunks,
      canonical_final_out_of_bounds_chunks: coverage.out_of_bounds_chunks,
      canonical_final_missing_chunks: coverage.missing_chunks
    })
  end

  defp maybe_put_final_canonical_coverage(summary, context) do
    case index_coverage(context) do
      {:ok, coverage} -> put_final_canonical_coverage(summary, coverage)
      {:error, _reason} -> summary
    end
  end

  defp incomplete_summary(summary, shard, after_status) do
    error = %{
      shard_coord: shard.shard_coord,
      path: shard.path,
      error: :shard_materialization_incomplete,
      expected_chunk_count: shard.chunk_count,
      present_chunk_count: after_status.present_chunk_count
    }

    summary
    |> Map.update!(:errors, &(&1 + 1))
    |> Map.update!(:chunk_errors, &(&1 ++ [error]))
  end

  defp materializer_failed_summary(summary, shard, reason) do
    error = %{
      shard_coord: shard.shard_coord,
      path: shard.path,
      error: reason,
      expected_chunk_count: shard.chunk_count
    }

    summary
    |> Map.update!(:errors, &(&1 + 1))
    |> Map.update!(:chunk_errors, &(&1 ++ [error]))
  end

  defp finalize_status(%{status: :failed} = summary), do: summary

  defp finalize_status(summary) do
    full_scope? = summary.selected_shards == summary.expected_shards

    canonical_ready? =
      Map.get(summary, :canonical_final_missing_chunks, 1) == 0 and
        Map.get(summary, :canonical_final_out_of_bounds_chunks, 0) == 0

    if full_scope? and canonical_ready? and summary.remaining_unready_shards == 0 and
         summary.errors == 0 do
      %{summary | status: :ready}
    else
      %{summary | status: :partial}
    end
  end
end
