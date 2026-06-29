defmodule DataService.Voxel.LodHeightmapStore do
  @moduledoc """
  Persistent derived heightmap LOD projection for authoritative voxel truth.

  This store is intentionally classified as `:derived`: rows are persisted so
  runtime heightmap requests do not rescan full chunk snapshots, but every row
  must be rebuildable from canonical voxel chunks. Missing rows are diagnostic
  errors; this module never falls back to procedural noise or raw snapshots on
  read.
  """

  use MmoContracts.StateClassed, class: :derived

  import Ecto.Query,
    only: [from: 2, group_by: 3, order_by: 3, select: 3]

  alias DataService.Schema.VoxelLodHeightmapCell

  @u16_max 65_535
  @missing_sample_limit 8

  @type cell :: %{
          required(:logical_scene_id) => non_neg_integer(),
          required(:stride) => pos_integer(),
          required(:cell_x) => integer(),
          required(:cell_z) => integer(),
          required(:height) => 0..65_535,
          optional(:material_id) => 0..65_535,
          optional(:source_chunk_coord) => {integer(), integer(), integer()},
          optional(:source_chunk_x) => integer(),
          optional(:source_chunk_y) => integer(),
          optional(:source_chunk_z) => integer(),
          optional(:source_chunk_version) => non_neg_integer()
        }

  @type result :: %{
          required(:heights) => binary(),
          required(:materials) => binary(),
          required(:meta) => map()
        }

  @doc """
  Upserts projection cells in a transaction owned by this function.
  """
  @spec upsert_cells([cell()] | cell(), keyword()) :: :ok | {:error, term()}
  def upsert_cells(cells, opts \\ []) do
    repo = repo(opts)

    case repo.transaction(fn -> upsert_cells_in_repo(repo, cells) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Upserts projection cells using the caller's open transaction.
  """
  @spec upsert_cells_in_repo(Ecto.Repo.t(), [cell()] | cell()) :: :ok | {:error, term()}
  def upsert_cells_in_repo(repo, cells) do
    with {:ok, rows} <- normalize_cells(cells) do
      do_upsert_cells(repo, rows)
    end
  end

  @doc """
  Reads a big-endian u16 heightmap from the persistent LOD projection.

  `origin_x` and `origin_z` are world macro coordinates and must align to
  `stride`; returned bytes are X-fastest and match the existing `0x6B` wire
  layout.
  """
  @spec heightmap_region(
          non_neg_integer(),
          integer(),
          integer(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          keyword()
        ) :: {:ok, result()} | {:error, term()}
  def heightmap_region(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, opts \\ [])

  def heightmap_region(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, opts)
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and is_integer(origin_x) and
             is_integer(origin_z) and is_integer(stride) and stride > 0 and is_integer(count_x) and
             count_x > 0 and is_integer(count_z) and count_z > 0 do
    with :ok <- validate_aligned(origin_x, origin_z, stride) do
      repo = repo(opts)
      cell_x0 = div(origin_x, stride)
      cell_z0 = div(origin_z, stride)
      cell_x1 = cell_x0 + count_x
      cell_z1 = cell_z0 + count_z

      rows =
        repo.all(
          from(c in VoxelLodHeightmapCell,
            where:
              c.logical_scene_id == ^logical_scene_id and c.stride == ^stride and
                c.cell_x >= ^cell_x0 and c.cell_x < ^cell_x1 and c.cell_z >= ^cell_z0 and
                c.cell_z < ^cell_z1
          )
        )

      build_heightmap(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, rows)
    end
  end

  def heightmap_region(
        _logical_scene_id,
        _origin_x,
        _origin_z,
        _stride,
        _count_x,
        _count_z,
        _opts
      ),
      do: {:error, :invalid_heightmap_request}

  @doc """
  Returns per-stride projection coverage metadata for a logical scene.

  This is a diagnostic read path for stdio/CLI observability. It reports what
  has been materialized in the derived LOD projection store; it does not rebuild
  missing rows and does not fall back to chunk snapshots or procedural terrain.
  """
  @spec summary(non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def summary(logical_scene_id, opts \\ [])

  def summary(logical_scene_id, opts)
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and is_list(opts) do
    with {:ok, stride} <- summary_stride(opts) do
      repo = repo(opts)

      rows =
        VoxelLodHeightmapCell
        |> where_logical_scene(logical_scene_id)
        |> where_stride(stride)
        |> group_by([c], c.stride)
        |> order_by([c], asc: c.stride)
        |> select([c], %{
          stride: c.stride,
          cell_count: count(c.cell_x),
          min_cell_x: min(c.cell_x),
          max_cell_x: max(c.cell_x),
          min_cell_z: min(c.cell_z),
          max_cell_z: max(c.cell_z),
          min_height: min(c.height),
          max_height: max(c.height),
          min_source_chunk_x: min(c.source_chunk_x),
          max_source_chunk_x: max(c.source_chunk_x),
          min_source_chunk_y: min(c.source_chunk_y),
          max_source_chunk_y: max(c.source_chunk_y),
          min_source_chunk_z: min(c.source_chunk_z),
          max_source_chunk_z: max(c.source_chunk_z),
          min_source_chunk_version: min(c.source_chunk_version),
          max_source_chunk_version: max(c.source_chunk_version)
        })
        |> repo.all()

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         stride_filter: stride,
         status: if(rows == [], do: :empty, else: :ready),
         total_cell_count: Enum.reduce(rows, 0, &(&1.cell_count + &2)),
         strides: rows
       }}
    end
  end

  def summary(_logical_scene_id, _opts), do: {:error, :invalid_logical_scene_id}

  @doc "Clears every derived LOD row. Test-only hatch."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    repo = repo(opts)
    repo.delete_all(VoxelLodHeightmapCell)
    :ok
  end

  defp do_upsert_cells(_repo, []), do: :ok

  defp do_upsert_cells(repo, rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    replace_fields = [
      :height,
      :material_id,
      :source_chunk_x,
      :source_chunk_y,
      :source_chunk_z,
      :source_chunk_version,
      :updated_at
    ]

    case repo.insert_all(VoxelLodHeightmapCell, rows,
           on_conflict: {:replace, replace_fields},
           conflict_target: [:logical_scene_id, :stride, :cell_x, :cell_z]
         ) do
      {count, _} when count >= length(rows) -> :ok
      _other -> {:error, :lod_heightmap_upsert_failed}
    end
  end

  defp build_heightmap(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, rows) do
    row_index = Map.new(rows, fn row -> {{row.cell_x, row.cell_z}, row} end)
    cell_x0 = div(origin_x, stride)
    cell_z0 = div(origin_z, stride)

    {height_iodata_rev, material_iodata_rev, missing_rev} =
      Enum.reduce(0..(count_z - 1), {[], [], []}, fn j, {heights, materials, missing} ->
        Enum.reduce(0..(count_x - 1), {heights, materials, missing}, fn i,
                                                                        {inner_heights,
                                                                         inner_materials,
                                                                         inner_missing} ->
          cell_x = cell_x0 + i
          cell_z = cell_z0 + j

          case Map.get(row_index, {cell_x, cell_z}) do
            %VoxelLodHeightmapCell{height: height, material_id: material_id} ->
              {[<<clamp_u16(height)::unsigned-big-integer-size(16)>> | inner_heights],
               [<<clamp_u16(material_id)::unsigned-big-integer-size(16)>> | inner_materials],
               inner_missing}

            nil ->
              {inner_heights, inner_materials,
               maybe_add_missing(inner_missing, %{
                 cell_x: cell_x,
                 cell_z: cell_z,
                 wx: origin_x + i * stride,
                 wz: origin_z + j * stride
               })}
          end
        end)
      end)

    sample_count = count_x * count_z
    missing_count = missing_count(missing_rev)

    if missing_count == 0 do
      {:ok,
       %{
         heights: height_iodata_rev |> Enum.reverse() |> IO.iodata_to_binary(),
         materials: material_iodata_rev |> Enum.reverse() |> IO.iodata_to_binary(),
         meta: %{
           logical_scene_id: logical_scene_id,
           origin: {origin_x, origin_z},
           stride: stride,
           count: {count_x, count_z},
           sample_count: sample_count,
           decoded_cell_count: length(rows),
           missing_count: 0,
           source: :authoritative_lod_heightmap_store
         }
       }}
    else
      {:error,
       {:missing_lod_heightmap_cells,
        %{
          logical_scene_id: logical_scene_id,
          origin: {origin_x, origin_z},
          stride: stride,
          count: {count_x, count_z},
          sample_count: sample_count,
          decoded_cell_count: length(rows),
          missing_count: missing_count,
          missing_sample: Enum.reverse(missing_rev)
        }}}
    end
  end

  defp validate_aligned(origin_x, origin_z, stride) do
    if rem(origin_x, stride) == 0 and rem(origin_z, stride) == 0 do
      :ok
    else
      {:error, :unaligned_heightmap_region}
    end
  end

  defp normalize_cells(cells) when is_list(cells) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, acc} ->
      case normalize_cell(cell) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      other -> other
    end
  end

  defp normalize_cells(%{} = cell), do: normalize_cells([cell])
  defp normalize_cells(_cells), do: {:error, :invalid_lod_heightmap_cells}

  defp normalize_cell(attrs) when is_map(attrs) do
    with {:ok, logical_scene_id} <- fetch_non_neg_integer(attrs, :logical_scene_id),
         {:ok, stride} <- fetch_positive_integer(attrs, :stride),
         {:ok, cell_x} <- fetch_integer(attrs, :cell_x),
         {:ok, cell_z} <- fetch_integer(attrs, :cell_z),
         {:ok, height} <- fetch_u16(attrs, :height),
         {:ok, material_id} <- fetch_u16_default(attrs, :material_id, 0),
         {:ok, source_fields} <- normalize_source_fields(attrs) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         stride: stride,
         cell_x: cell_x,
         cell_z: cell_z,
         height: height,
         material_id: material_id
       }
       |> Map.merge(source_fields)}
    end
  end

  defp normalize_cell(_attrs), do: {:error, :invalid_lod_heightmap_cell}

  defp summary_stride(opts) do
    case Keyword.get(opts, :stride) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :invalid_stride}
    end
  end

  defp where_logical_scene(queryable, logical_scene_id) do
    from(c in queryable, where: c.logical_scene_id == ^logical_scene_id)
  end

  defp where_stride(queryable, nil), do: queryable

  defp where_stride(queryable, stride) do
    from(c in queryable, where: c.stride == ^stride)
  end

  defp normalize_source_fields(attrs) do
    with {:ok, {sx, sy, sz}} <- fetch_source_coord(attrs),
         {:ok, source_chunk_version} <- fetch_non_neg_integer_or_nil(attrs, :source_chunk_version) do
      {:ok,
       %{
         source_chunk_x: sx,
         source_chunk_y: sy,
         source_chunk_z: sz,
         source_chunk_version: source_chunk_version
       }}
    end
  end

  defp fetch_source_coord(attrs) do
    case fetch_optional(attrs, :source_chunk_coord) do
      {:ok, {x, y, z}} when is_integer(x) and is_integer(y) and is_integer(z) ->
        {:ok, {x, y, z}}

      {:ok, [x, y, z]} when is_integer(x) and is_integer(y) and is_integer(z) ->
        {:ok, {x, y, z}}

      {:ok, _other} ->
        {:error, :invalid_source_chunk_coord}

      :missing ->
        with {:ok, x} <- fetch_integer_or_nil(attrs, :source_chunk_x),
             {:ok, y} <- fetch_integer_or_nil(attrs, :source_chunk_y),
             {:ok, z} <- fetch_integer_or_nil(attrs, :source_chunk_z) do
          {:ok, {x, y, z}}
        end
    end
  end

  defp fetch_u16(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key) do
      if is_integer(value) and value >= 0 and value <= @u16_max do
        {:ok, value}
      else
        {:error, invalid_reason(key)}
      end
    end
  end

  defp fetch_positive_integer(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key) do
      if is_integer(value) and value > 0, do: {:ok, value}, else: {:error, invalid_reason(key)}
    end
  end

  defp fetch_non_neg_integer(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key) do
      if is_integer(value) and value >= 0, do: {:ok, value}, else: {:error, invalid_reason(key)}
    end
  end

  defp fetch_u16_default(attrs, key, default) do
    case fetch_optional(attrs, key) do
      :missing ->
        {:ok, default}

      {:ok, value} ->
        if is_integer(value) and value >= 0 and value <= @u16_max do
          {:ok, value}
        else
          {:error, invalid_reason(key)}
        end
    end
  end

  defp fetch_non_neg_integer_or_nil(attrs, key) do
    case fetch_optional(attrs, key) do
      :missing -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _other} -> {:error, invalid_reason(key)}
    end
  end

  defp fetch_integer(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key) do
      if is_integer(value), do: {:ok, value}, else: {:error, invalid_reason(key)}
    end
  end

  defp fetch_integer_or_nil(attrs, key) do
    case fetch_optional(attrs, key) do
      :missing -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _other} -> {:error, invalid_reason(key)}
    end
  end

  defp fetch_required(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> {:error, missing_reason(key)}
    end
  end

  defp fetch_optional(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> :missing
    end
  end

  defp missing_count(missing_rev) do
    case missing_rev do
      [%{omitted_count: omitted} | rest] -> omitted + length(rest)
      rest -> length(rest)
    end
  end

  defp maybe_add_missing([%{omitted_count: omitted} | rest], _sample),
    do: [%{omitted_count: omitted + 1} | rest]

  defp maybe_add_missing(missing, sample) when length(missing) < @missing_sample_limit,
    do: [sample | missing]

  defp maybe_add_missing(missing, _sample), do: [%{omitted_count: 1} | missing]

  defp clamp_u16(value) when value < 0, do: 0
  defp clamp_u16(value) when value > @u16_max, do: @u16_max
  defp clamp_u16(value), do: value

  defp repo(opts), do: Keyword.get(opts, :repo, DataService.Repo)

  defp missing_reason(:logical_scene_id), do: :missing_logical_scene_id
  defp missing_reason(:stride), do: :missing_stride
  defp missing_reason(:cell_x), do: :missing_cell_x
  defp missing_reason(:cell_z), do: :missing_cell_z
  defp missing_reason(:height), do: :missing_height
  defp missing_reason(:material_id), do: :missing_material_id
  defp missing_reason(:source_chunk_version), do: :missing_source_chunk_version
  defp missing_reason(_field), do: :missing_lod_heightmap_field

  defp invalid_reason(:logical_scene_id), do: :invalid_logical_scene_id
  defp invalid_reason(:stride), do: :invalid_stride
  defp invalid_reason(:cell_x), do: :invalid_cell_x
  defp invalid_reason(:cell_z), do: :invalid_cell_z
  defp invalid_reason(:height), do: :invalid_height
  defp invalid_reason(:material_id), do: :invalid_material_id
  defp invalid_reason(:source_chunk_x), do: :invalid_source_chunk_x
  defp invalid_reason(:source_chunk_y), do: :invalid_source_chunk_y
  defp invalid_reason(:source_chunk_z), do: :invalid_source_chunk_z
  defp invalid_reason(:source_chunk_version), do: :invalid_source_chunk_version
  defp invalid_reason(_field), do: :invalid_lod_heightmap_field
end
