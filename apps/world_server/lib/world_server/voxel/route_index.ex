defmodule WorldServer.Voxel.RouteIndex do
  @moduledoc """
  Derived read index for voxel region routing.

  `MapLedger` remains the authority for region assignments and leases. This
  module owns only a deterministic, rebuildable projection of active assignment
  bounds grouped by logical scene. It deliberately keeps the public API small so
  a future spatial tree or native index can replace the implementation without
  changing callers.
  """

  alias WorldServer.Voxel.RegionAssignment

  @strategy :scene_bucket_grid_v1
  @default_bucket_size 16

  defstruct bucket_size: @default_bucket_size, scenes: %{}

  @type chunk_coord :: {integer(), integer(), integer()}
  @type bucket_key :: {integer(), integer(), integer()}
  @type scene_index :: %{
          buckets: %{bucket_key() => [non_neg_integer()]},
          region_buckets: %{non_neg_integer() => [bucket_key()]},
          regions: %{non_neg_integer() => RegionAssignment.t()}
        }
  @type t :: %__MODULE__{
          bucket_size: pos_integer(),
          scenes: %{non_neg_integer() => scene_index()}
        }

  @doc "Builds a deterministic route index from a map or list of assignments."
  @spec build(map() | [RegionAssignment.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def build(assignments, opts \\ [])

  def build(assignments, opts) when is_map(assignments),
    do: assignments |> Map.values() |> build(opts)

  def build(assignments, opts) when is_list(assignments) do
    bucket_size = Keyword.get(opts, :bucket_size, @default_bucket_size)

    active_assignments =
      assignments
      |> Enum.filter(&match?(%RegionAssignment{state: :active}, &1))
      |> Enum.sort_by(&assignment_sort_key/1)

    with :ok <- validate_bucket_size(bucket_size),
         :ok <- validate_no_overlaps(active_assignments) do
      scenes =
        active_assignments
        |> Enum.group_by(& &1.logical_scene_id)
        |> Map.new(fn {logical_scene_id, scene_assignments} ->
          {logical_scene_id, build_scene_index(scene_assignments, bucket_size)}
        end)

      {:ok, %__MODULE__{bucket_size: bucket_size, scenes: scenes}}
    end
  end

  @doc "Routes one chunk coordinate to the indexed active assignment."
  @spec route_chunk(t(), non_neg_integer(), chunk_coord()) ::
          {:ok, RegionAssignment.t()} | {:error, :unassigned_chunk}
  def route_chunk(%__MODULE__{} = index, logical_scene_id, chunk_coord) do
    with {:ok, scene} <- fetch_scene(index, logical_scene_id) do
      candidate_region_ids =
        scene.buckets
        |> Map.get(bucket_key(chunk_coord, index.bucket_size), [])
        |> Enum.sort()

      candidate_region_ids
      |> Enum.map(&Map.fetch!(scene.regions, &1))
      |> Enum.find(&RegionAssignment.contains_chunk?(&1, chunk_coord))
      |> case do
        nil -> {:error, :unassigned_chunk}
        assignment -> {:ok, assignment}
      end
    end
  end

  @doc "Routes a list of chunks and keeps misses explicit per chunk."
  @spec route_chunks(t(), non_neg_integer(), [chunk_coord()]) :: %{
          chunk_coord() => {:ok, RegionAssignment.t()} | {:error, :unassigned_chunk}
        }
  def route_chunks(%__MODULE__{} = index, logical_scene_id, chunk_coords)
      when is_list(chunk_coords) do
    Map.new(chunk_coords, fn chunk_coord ->
      {chunk_coord, route_chunk(index, logical_scene_id, chunk_coord)}
    end)
  end

  @doc "Returns stable operational stats for CLI/debug surfaces."
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = index) do
    scenes =
      index.scenes
      |> Enum.map(fn {logical_scene_id, assignments} ->
        candidate_counts = Map.values(assignments.buckets) |> Enum.map(&length/1)

        %{
          logical_scene_id: logical_scene_id,
          region_count: map_size(assignments.regions),
          bucket_count: map_size(assignments.buckets),
          region_ids: assignments.regions |> Map.keys() |> Enum.sort(),
          max_candidates_per_bucket: Enum.max(candidate_counts, fn -> 0 end)
        }
      end)
      |> Enum.sort_by(& &1.logical_scene_id)

    bucket_count = Enum.reduce(scenes, 0, &(&1.bucket_count + &2))
    entry_count = total_bucket_entries(index)

    %{
      strategy: @strategy,
      bucket_size: index.bucket_size,
      scene_count: length(scenes),
      region_count: Enum.reduce(scenes, 0, &(&1.region_count + &2)),
      bucket_count: bucket_count,
      entry_count: entry_count,
      max_candidates_per_bucket:
        Enum.max(Enum.map(scenes, & &1.max_candidates_per_bucket), fn -> 0 end),
      avg_candidates_per_bucket: average(entry_count, bucket_count),
      scenes: scenes
    }
  end

  defp build_scene_index(assignments, bucket_size) do
    Enum.reduce(
      assignments,
      %{buckets: %{}, region_buckets: %{}, regions: %{}},
      fn assignment, scene ->
        bucket_keys = assignment_bucket_keys(assignment, bucket_size)

        buckets =
          Enum.reduce(bucket_keys, scene.buckets, fn bucket_key, buckets ->
            Map.update(buckets, bucket_key, [assignment.region_id], fn region_ids ->
              [assignment.region_id | region_ids] |> Enum.uniq() |> Enum.sort()
            end)
          end)

        %{
          buckets: buckets,
          region_buckets: Map.put(scene.region_buckets, assignment.region_id, bucket_keys),
          regions: Map.put(scene.regions, assignment.region_id, assignment)
        }
      end
    )
  end

  defp fetch_scene(%__MODULE__{} = index, logical_scene_id) do
    case Map.fetch(index.scenes, logical_scene_id) do
      {:ok, scene} -> {:ok, scene}
      :error -> {:error, :unassigned_chunk}
    end
  end

  defp assignment_bucket_keys(%RegionAssignment{} = assignment, bucket_size) do
    {min_x, min_y, min_z} = assignment.bounds_chunk_min
    {max_x, max_y, max_z} = assignment.bounds_chunk_max

    for x <- axis_bucket_range(min_x, max_x, bucket_size),
        y <- axis_bucket_range(min_y, max_y, bucket_size),
        z <- axis_bucket_range(min_z, max_z, bucket_size) do
      {x, y, z}
    end
  end

  defp axis_bucket_range(min, max, _bucket_size) when max <= min, do: []

  defp axis_bucket_range(min, max, bucket_size) do
    floor_div(min, bucket_size)..floor_div(max - 1, bucket_size)//1
  end

  defp bucket_key({x, y, z}, bucket_size) do
    {floor_div(x, bucket_size), floor_div(y, bucket_size), floor_div(z, bucket_size)}
  end

  defp floor_div(value, divisor) do
    quotient = div(value, divisor)
    remainder = rem(value, divisor)

    if remainder != 0 and value < 0 do
      quotient - 1
    else
      quotient
    end
  end

  defp validate_no_overlaps(assignments) do
    assignments
    |> Enum.reduce_while(:ok, fn assignment, :ok ->
      assignments
      |> Enum.find(&conflicting_active_region?(&1, assignment))
      |> case do
        nil ->
          {:cont, :ok}

        conflict ->
          left = min(assignment.region_id, conflict.region_id)
          right = max(assignment.region_id, conflict.region_id)
          {:halt, {:error, {:region_bounds_overlap, left, right}}}
      end
    end)
  end

  defp conflicting_active_region?(left, right) do
    left.region_id != right.region_id and left.logical_scene_id == right.logical_scene_id and
      bounds_overlap?(
        left.bounds_chunk_min,
        left.bounds_chunk_max,
        right.bounds_chunk_min,
        right.bounds_chunk_max
      )
  end

  defp bounds_overlap?(
         {left_min_x, left_min_y, left_min_z},
         {left_max_x, left_max_y, left_max_z},
         {right_min_x, right_min_y, right_min_z},
         {right_max_x, right_max_y, right_max_z}
       ) do
    left_min_x < right_max_x and right_min_x < left_max_x and left_min_y < right_max_y and
      right_min_y < left_max_y and left_min_z < right_max_z and right_min_z < left_max_z
  end

  defp assignment_sort_key(%RegionAssignment{} = assignment) do
    {assignment.logical_scene_id, assignment.bounds_chunk_min, assignment.bounds_chunk_max,
     assignment.region_id}
  end

  defp total_bucket_entries(%__MODULE__{} = index) do
    index.scenes
    |> Map.values()
    |> Enum.flat_map(fn scene -> Map.values(scene.buckets) end)
    |> Enum.reduce(0, &(length(&1) + &2))
  end

  defp average(_count, 0), do: 0.0
  defp average(count, total), do: count / total

  defp validate_bucket_size(bucket_size) when is_integer(bucket_size) and bucket_size > 0, do: :ok
  defp validate_bucket_size(bucket_size), do: {:error, {:invalid_bucket_size, bucket_size}}
end
