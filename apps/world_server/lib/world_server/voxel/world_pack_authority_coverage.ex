defmodule WorldServer.Voxel.WorldPackAuthorityCoverage do
  @moduledoc """
  Verifies canonical snapshot coverage against a compact world-pack index.

  This module is intentionally read-only. It compares the already persisted
  authority store with the expected `WorldPackIndex`, then samples payload
  shards and normal sliding windows. It never materializes, repairs, or
  synthesizes missing baseline data.
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias MmoContracts.VoxelSpatialContract
  alias MmoContracts.WorldPackIndex

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc """
  Builds a coverage report for a world-pack index.

  Options:

    * `:coverage_store` - module with `coverage/3` or function arity 3
    * `:snapshot_store` - module with `get_snapshot/2` or function arity 2
    * `:radius` - 完整 XYZ 近场 chunk 半径，默认 `10`
    * `:window_centers` - tile-center chunk 样本，默认 `{3,3,3}`、`{10,3,3}`、`{17,3,3}`
    * `:shard_coords` - payload shards to sample; defaults to edge/center shards
  """
  @spec verify(WorldPackIndex.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(index, opts \\ [])

  def verify(%WorldPackIndex{} = index, opts) when is_list(opts) do
    with {:ok, authority_summary} <- verify_authority_index(index),
         coverage_store <- Keyword.get(opts, :coverage_store, ChunkSnapshotStore),
         snapshot_store <- Keyword.get(opts, :snapshot_store, ChunkSnapshotStore),
         {:ok, raw_coverage} <-
           call_coverage_store(
             coverage_store,
             index.logical_scene_id,
             index.chunk_min,
             index.chunk_max
           ),
         coverage <- normalize_index_coverage(index, raw_coverage),
         {:ok, sampled_shards} <- sample_shards(index, coverage_store, snapshot_store, opts),
         {:ok, sampled_windows} <- sample_windows(index, snapshot_store, opts) do
      status = report_status(coverage, sampled_shards, sampled_windows)

      {:ok,
       %{
         status: status,
         logical_scene_id: index.logical_scene_id,
         content_version: index.content_version,
         expected_chunk_count: authority_summary.expected_chunk_count,
         covered_index_chunk_count: authority_summary.covered_chunk_count,
         coverage: coverage,
         sampled_shards: sampled_shards,
         sampled_windows: sampled_windows
       }}
    end
  end

  def verify(_index, _opts), do: {:error, :invalid_world_pack_authority_coverage_options}

  defp verify_authority_index(index) do
    case WorldPackIndex.verify(index) do
      {:ok, summary} -> {:ok, summary}
      {:error, summary} -> {:error, {:invalid_world_pack_index, summary}}
    end
  end

  defp normalize_index_coverage(index, coverage) when is_map(coverage) do
    expected = WorldPackIndex.chunk_count(index)
    in_bounds = Map.fetch!(coverage, :in_bounds_chunk_count)

    coverage
    |> Map.put(:expected_chunk_count, expected)
    |> Map.put(:missing_in_bounds_chunk_count, max(expected - in_bounds, 0))
  end

  defp sample_shards(index, coverage_store, snapshot_store, opts) do
    with {:ok, shard_coords} <- sample_shard_coords(index, opts) do
      shard_coords
      |> Enum.reduce_while({:ok, []}, fn shard_coord, {:ok, acc} ->
        case sample_shard(index, shard_coord, coverage_store, snapshot_store) do
          {:ok, report} -> {:cont, {:ok, [report | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, reports} -> {:ok, Enum.reverse(reports)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp sample_shard_coords(index, opts) do
    case Keyword.get(opts, :shard_coords) do
      nil -> default_shard_coords(index)
      coords when is_list(coords) -> {:ok, coords}
      _other -> {:error, :invalid_sample_shard_coords}
    end
  end

  defp default_shard_coords(index) do
    with {:ok, grid} <- WorldPackIndex.payload_shard_grid(index) do
      {min_x, min_y, min_z} = grid.shard_min
      {max_x, max_y, max_z} = grid.shard_max

      center = {
        div(min_x + max_x, 2),
        div(min_y + max_y, 2),
        div(min_z + max_z, 2)
      }

      {:ok, Enum.uniq([grid.shard_min, center, grid.shard_max])}
    end
  end

  defp sample_shard(index, shard_coord, coverage_store, snapshot_store) do
    with {:ok, summary} <- WorldPackIndex.payload_shard_summary(index, shard_coord),
         {:ok, coverage} <-
           call_coverage_store(
             coverage_store,
             index.logical_scene_id,
             summary.chunk_min,
             summary.chunk_max
           ) do
      present_count = Map.fetch!(coverage, :in_bounds_chunk_count)
      missing_count = max(summary.chunk_count - present_count, 0)

      first_missing =
        maybe_first_missing(snapshot_store, index.logical_scene_id, summary, missing_count)

      {:ok,
       %{
         shard_coord: summary.shard_coord,
         path: summary.path,
         status: if(missing_count == 0, do: :ready, else: :incomplete),
         chunk_min: summary.chunk_min,
         chunk_max: summary.chunk_max,
         expected_chunk_count: summary.chunk_count,
         present_chunk_count: present_count,
         missing_chunk_count: missing_count,
         first_missing_chunk: missing_coord(first_missing),
         first_missing_error: missing_error(first_missing)
       }}
    end
  end

  defp maybe_first_missing(_snapshot_store, _logical_scene_id, _summary, 0), do: nil

  defp maybe_first_missing(snapshot_store, logical_scene_id, summary, _missing_count) do
    summary.chunk_min
    |> chunk_stream(summary.chunk_max)
    |> Enum.reduce_while(nil, fn chunk_coord, nil ->
      case call_snapshot_store(snapshot_store, logical_scene_id, chunk_coord) do
        {:ok, _snapshot} -> {:cont, nil}
        {:error, reason} -> {:halt, %{chunk_coord: chunk_coord, error: reason}}
      end
    end)
  end

  defp sample_windows(index, snapshot_store, opts) do
    radius = Keyword.get(opts, :radius, VoxelSpatialContract.near_chunk_radius())

    centers =
      Keyword.get(opts, :window_centers, [
        VoxelSpatialContract.tile_center_chunk({0, 0, 0}),
        VoxelSpatialContract.tile_center_chunk({1, 0, 0}),
        VoxelSpatialContract.tile_center_chunk({2, 0, 0})
      ])

    centers
    |> Enum.reduce_while({:ok, []}, fn center, {:ok, acc} ->
      case sample_window(index, center, radius, snapshot_store) do
        {:ok, report} -> {:cont, {:ok, [report | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reports} -> {:ok, Enum.reverse(reports)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sample_window(index, center, radius, snapshot_store) do
    with {:ok, plan} <- WorldPackIndex.window_payload_plan(index, center, radius) do
      refs = plan_refs(plan)

      {present_count, missing_count, first_missing} =
        Enum.reduce(refs, {0, 0, nil}, fn ref, {present, missing, first_missing} ->
          case call_snapshot_store(snapshot_store, index.logical_scene_id, ref.chunk_coord) do
            {:ok, _snapshot} ->
              {present + 1, missing, first_missing}

            {:error, reason} ->
              {present, missing + 1,
               first_missing || %{chunk_coord: ref.chunk_coord, error: reason}}
          end
        end)

      {:ok,
       %{
         center: center,
         radius: radius,
         status: if(missing_count == 0, do: :ready, else: :incomplete),
         expected_chunk_count: plan.chunk_count,
         present_chunk_count: present_count,
         missing_chunk_count: missing_count,
         shard_count: length(plan.shards),
         first_missing_chunk: missing_coord(first_missing),
         first_missing_error: missing_error(first_missing)
       }}
    end
  end

  defp plan_refs(plan) do
    plan.shards
    |> Enum.flat_map(& &1.chunks)
    |> Enum.sort_by(& &1.ordinal)
  end

  defp report_status(coverage, sampled_shards, sampled_windows) do
    if coverage.missing_in_bounds_chunk_count == 0 and coverage.out_of_bounds_chunk_count == 0 and
         Enum.all?(sampled_shards, &(&1.status == :ready)) and
         Enum.all?(sampled_windows, &(&1.status == :ready)) do
      :ready
    else
      :incomplete
    end
  end

  defp chunk_stream({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    min_x..max_x
    |> Stream.flat_map(fn cx ->
      min_y..max_y
      |> Stream.flat_map(fn cy ->
        min_z..max_z
        |> Stream.map(fn cz -> {cx, cy, cz} end)
      end)
    end)
  end

  defp call_coverage_store(store, logical_scene_id, chunk_min, chunk_max)
       when is_function(store, 3),
       do: store.(logical_scene_id, chunk_min, chunk_max)

  defp call_coverage_store(store, logical_scene_id, chunk_min, chunk_max) when is_atom(store),
    do: store.coverage(logical_scene_id, chunk_min, chunk_max)

  defp call_coverage_store(_store, _logical_scene_id, _chunk_min, _chunk_max),
    do: {:error, :invalid_coverage_store}

  defp call_snapshot_store(store, logical_scene_id, chunk_coord) when is_function(store, 2),
    do: store.(logical_scene_id, chunk_coord)

  defp call_snapshot_store(store, logical_scene_id, chunk_coord) when is_atom(store),
    do: store.get_snapshot(logical_scene_id, chunk_coord)

  defp call_snapshot_store(_store, _logical_scene_id, _chunk_coord),
    do: {:error, :invalid_snapshot_store}

  defp missing_coord(nil), do: nil
  defp missing_coord(%{chunk_coord: coord}), do: coord

  defp missing_error(nil), do: nil
  defp missing_error(%{error: error}), do: inspect(error)
end
