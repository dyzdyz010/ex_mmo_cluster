defmodule SceneServer.Voxel.LodProjection do
  @moduledoc """
  Builds heightmap LOD projection rows from authoritative chunk truth.

  The rows produced here are persisted by
  `DataService.Voxel.LodHeightmapStore`. They are a derived cache, not a new
  source of truth. Rebuild uses the changed storage plus authoritative
  persisted snapshots for the same X/Z chunk column so vertical neighbors can
  participate in column-top selection. Each row carries both the aggregate
  height and the top-surface material id derived from the same authoritative
  column data.
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @default_strides [2, 4, 8, 16]
  @chunk_size Types.chunk_size_in_macro()

  @doc """
  Returns LOD projection rows affected by one chunk storage.

  Options:

    * `:strides` - positive divisors of the chunk size; defaults to
      `Application.get_env(:scene_server, :voxel_lod_projection_strides, [2,4,8,16])`.
    * `:snapshot_index` - explicit snapshot index for tests/rebuild tools.
    * `:snapshot_store` - module exposing `snapshot_columns/3`.
  """
  @spec cells_for_storage(Storage.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def cells_for_storage(storage, opts \\ [])

  def cells_for_storage(%Storage{} = storage, opts) do
    storage = Storage.normalize!(storage)

    with {:ok, strides} <- projection_strides(opts),
         {:ok, snapshot_index} <- snapshot_index_for_storage(storage, opts) do
      build_cells(storage, strides, snapshot_index)
    end
  end

  def cells_for_storage(_storage, _opts), do: {:error, :invalid_storage}

  defp build_cells(%Storage{} = storage, strides, snapshot_index) do
    {cx, _cy, cz} = storage.chunk_coord
    origin_x = cx * @chunk_size
    origin_z = cz * @chunk_size

    with {:ok, fine_surface} <-
           fine_surface_for_chunk(storage.logical_scene_id, origin_x, origin_z, snapshot_index) do
      Enum.reduce_while(strides, {:ok, []}, fn stride, {:ok, acc} ->
        cells_per_axis = div(@chunk_size, stride)

        cells =
          cells_for_stride(storage, fine_surface, origin_x, origin_z, stride, cells_per_axis)

        {:cont, {:ok, acc ++ cells}}
      end)
    end
  end

  defp cells_for_stride(storage, fine_surface, origin_x, origin_z, stride, cells_per_axis) do
    for cell_z_offset <- 0..(cells_per_axis - 1),
        cell_x_offset <- 0..(cells_per_axis - 1) do
      wx = origin_x + cell_x_offset * stride
      wz = origin_z + cell_z_offset * stride
      surface = aggregate_cell_surface(fine_surface, cell_x_offset, cell_z_offset, stride)

      %{
        logical_scene_id: storage.logical_scene_id,
        stride: stride,
        cell_x: Types.floor_div(wx, stride),
        cell_z: Types.floor_div(wz, stride),
        height: surface.height,
        material_id: surface.material_id,
        source_chunk_coord: storage.chunk_coord,
        source_chunk_version: storage.chunk_version
      }
    end
  end

  defp fine_surface_for_chunk(logical_scene_id, origin_x, origin_z, snapshot_index) do
    with {:ok, cx, cz} <- aligned_chunk_origin(origin_x, origin_z),
         {:ok, column} <- load_column(logical_scene_id, cx, cz, snapshot_index) do
      fine_surface =
        for mz <- 0..(@chunk_size - 1),
            mx <- 0..(@chunk_size - 1) do
          column_surface(column, mx, mz)
        end
        |> List.to_tuple()

      if tuple_size(fine_surface) == @chunk_size * @chunk_size do
        {:ok, fine_surface}
      else
        {:error, {:lod_projection_height_failed, :invalid_fine_surface_count}}
      end
    end
  end

  defp aligned_chunk_origin(origin_x, origin_z) do
    case {Types.chunk_and_local_macro_axis(origin_x), Types.chunk_and_local_macro_axis(origin_z)} do
      {{cx, 0}, {cz, 0}} -> {:ok, cx, cz}
      _other -> {:error, {:lod_projection_height_failed, :unaligned_chunk_origin}}
    end
  end

  defp aggregate_cell_surface(fine_surface, cell_x_offset, cell_z_offset, stride) do
    for dz <- 0..(stride - 1),
        dx <- 0..(stride - 1),
        reduce: %{height: 0, material_id: 0} do
      max_surface ->
        x = cell_x_offset * stride + dx
        z = cell_z_offset * stride + dz
        surface = elem(fine_surface, z * @chunk_size + x)

        if surface.height > max_surface.height do
          surface
        else
          max_surface
        end
    end
  end

  defp load_column(logical_scene_id, cx, cz, snapshot_index) do
    snapshot_index
    |> Enum.reduce_while({:ok, []}, fn
      {{^logical_scene_id, {^cx, _cy, ^cz}}, snapshot}, {:ok, acc} ->
        case decode_storage(snapshot) do
          {:ok, storage} -> {:cont, {:ok, [storage | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_authoritative_snapshot, reason}}}
        end

      {_other_key, _snapshot}, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, []} ->
        {:error, {:lod_projection_height_failed, :missing_authoritative_column}}

      {:ok, storages} ->
        column =
          storages
          |> Enum.sort_by(fn %Storage{chunk_coord: {_cx, cy, _cz}} -> cy end, :desc)
          |> Enum.map(&column_source/1)

        {:ok, column}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp column_surface(column_sources, mx, mz) do
    column_sources
    |> Enum.find_value(fn %{storage: %Storage{chunk_coord: {_cx, cy, _cz}}} = source ->
      case top_local_surface(source, mx, mz) do
        nil ->
          nil

        %{local_y: my, material_id: material_id} ->
          %{height: cy * @chunk_size + my + 1, material_id: material_id}
      end
    end)
    |> case do
      nil -> %{height: 0, material_id: 0}
      surface -> surface
    end
  end

  defp top_local_surface(%{storage: %Storage{} = storage, headers: headers}, mx, mz) do
    Enum.find_value((@chunk_size - 1)..0//-1, fn my ->
      macro_index = Types.macro_index!({mx, my, mz})
      header = Storage.header_at_index(headers, macro_index)

      if occupied_macro?(storage, header) do
        %{local_y: my, material_id: material_id_for_header(storage, header)}
      end
    end)
  end

  defp material_id_for_header(%Storage{} = storage, %MacroCellHeader{} = header) do
    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        case Storage.normal_block_with_header(storage, header) do
          %NormalBlockData{material_id: material_id} -> material_id
          _other -> 0
        end

      header.mode == MacroCellHeader.cell_mode_refined() ->
        case Enum.at(storage.refined_cells, header.payload_index) do
          %RefinedCellData{} = cell -> refined_top_material_id(cell)
          _other -> 0
        end

      true ->
        0
    end
  end

  defp refined_top_material_id(%RefinedCellData{} = cell) do
    Enum.find_value(7..0//-1, 0, fn micro_y ->
      Enum.find_value(0..7, fn micro_z ->
        Enum.find_value(0..7, fn micro_x ->
          micro_slot = micro_x + micro_y * 8 + micro_z * 64

          if slot_currently_occupied?(cell, micro_slot) do
            material_id_for_micro_slot(cell, micro_slot)
          end
        end)
      end)
    end)
  end

  defp material_id_for_micro_slot(%RefinedCellData{} = cell, micro_slot) do
    Enum.find_value(cell.layers, 0, fn %MicroLayer{} = layer ->
      if slot_currently_occupied?(layer.mask_words, micro_slot), do: layer.material_id
    end)
  end

  defp occupied_macro?(%Storage{} = storage, %MacroCellHeader{} = header) do
    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        true

      header.mode == MacroCellHeader.cell_mode_refined() ->
        case Enum.at(storage.refined_cells, header.payload_index) do
          %RefinedCellData{occupancy_words: words} -> Enum.any?(words, &(&1 != 0))
          _other -> false
        end

      true ->
        false
    end
  end

  defp column_source(%Storage{} = storage) do
    %{storage: storage, headers: List.to_tuple(storage.macro_headers)}
  end

  defp slot_currently_occupied?(%RefinedCellData{occupancy_words: words}, micro_slot) do
    slot_currently_occupied?(words, micro_slot)
  end

  defp slot_currently_occupied?(words, micro_slot) when is_list(words) do
    word_index = div(micro_slot, 64)
    bit_index = rem(micro_slot, 64)

    case Enum.at(words, word_index) do
      word when is_integer(word) -> Bitwise.band(word, Bitwise.bsl(1, bit_index)) != 0
      _other -> false
    end
  end

  defp decode_storage(%Storage{} = storage), do: {:ok, Storage.normalize!(storage)}
  defp decode_storage(%{storage: %Storage{} = storage}), do: {:ok, Storage.normalize!(storage)}
  defp decode_storage(%{data: data}) when is_binary(data), do: decode_storage(data)

  defp decode_storage(data) when is_binary(data) do
    case Codec.decode_chunk_snapshot_payload(data) do
      {:ok, %{storage: %Storage{} = storage}} -> {:ok, Storage.normalize!(storage)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_storage(other), do: {:error, {:unsupported_snapshot_value, other}}

  defp snapshot_index_for_storage(%Storage{} = storage, opts) do
    base_index_result =
      case Keyword.fetch(opts, :snapshot_index) do
        {:ok, index} when is_map(index) ->
          {:ok, index}

        {:ok, _other} ->
          {:error, :invalid_snapshot_index}

        :error ->
          {cx, _cy, cz} = storage.chunk_coord
          store = Keyword.get(opts, :snapshot_store, ChunkSnapshotStore)

          try do
            {:ok, store.snapshot_columns(storage.logical_scene_id, [{cx, cz}])}
          catch
            :exit, reason -> {:error, {:snapshot_store_unavailable, reason}}
          end
      end

    case base_index_result do
      {:ok, index} ->
        {:ok,
         Map.put(index, {storage.logical_scene_id, storage.chunk_coord}, %{storage: storage})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp projection_strides(opts) do
    strides =
      Keyword.get_lazy(opts, :strides, fn ->
        Application.get_env(:scene_server, :voxel_lod_projection_strides, @default_strides)
      end)

    cond do
      not is_list(strides) ->
        {:error, :invalid_lod_projection_strides}

      Enum.all?(strides, &valid_stride?/1) ->
        {:ok, Enum.uniq(strides)}

      true ->
        {:error, :invalid_lod_projection_strides}
    end
  end

  defp valid_stride?(stride) do
    is_integer(stride) and stride > 0 and rem(@chunk_size, stride) == 0
  end
end
