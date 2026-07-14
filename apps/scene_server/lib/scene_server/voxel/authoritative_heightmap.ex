defmodule SceneServer.Voxel.AuthoritativeHeightmap do
  @moduledoc """
  已归档 XZ heightmap 的离线读取与迁移适配器。

  TCP 在线 `0x6A` 链路已明确返回 `:unsupported_legacy_contract`，不得调用本模块。
  默认读取 `DataService.Voxel.LodHeightmapStore`；显式 snapshot 选项仅供历史投影
  rebuild、数据审计和测试从 canonical chunks 派生旧格式行。
  """

  alias DataService.Voxel.LodHeightmapStore
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @chunk_size Types.chunk_size_in_macro()
  @u16_max 65_535
  @missing_sample_limit 8

  @type result :: %{
          required(:heights) => binary(),
          required(:materials) => binary(),
          required(:meta) => map()
        }

  @doc """
  为离线迁移/对照读取 big-endian u16 历史 heightmap projection。

  `origin_x` / `origin_z` are world macro coordinates. `stride` is measured in
  macro cells. The returned binary is X-fastest and compatible with the existing
  `0x6B` wire layout.

  Options:

    * `:lod_store` - projection store module exposing `heightmap_region/7`;
      defaults to `DataService.Voxel.LodHeightmapStore`.
    * `:snapshot_store` - module exposing `snapshot/0`; defaults to
      `DataService.Voxel.ChunkSnapshotStore`; enables direct snapshot scanning.
    * `:snapshot_index` - test/debug override using the same map shape as
      `ChunkSnapshotStore.snapshot/0`, or values that are `%Storage{}`,
      `%{data: binary}`, `%{storage: %Storage{}}`, or raw snapshot payloads.
    * `:source` - `:snapshot_store` or `:chunk_snapshot_store` forces direct
      snapshot scanning.
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
    if snapshot_source?(opts) do
      derive_from_snapshot_store(
        logical_scene_id,
        origin_x,
        origin_z,
        stride,
        count_x,
        count_z,
        opts
      )
    else
      read_lod_projection(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, opts)
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
      ) do
    {:error, :invalid_heightmap_request}
  end

  defp read_lod_projection(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, opts) do
    store = Keyword.get(opts, :lod_store, LodHeightmapStore)

    try do
      store.heightmap_region(logical_scene_id, origin_x, origin_z, stride, count_x, count_z, opts)
    catch
      :exit, reason -> {:error, {:lod_heightmap_store_unavailable, reason}}
    end
  end

  defp derive_from_snapshot_store(
         logical_scene_id,
         origin_x,
         origin_z,
         stride,
         count_x,
         count_z,
         opts
       ) do
    with {:ok, column_index, decode_meta} <- load_column_index(logical_scene_id, opts) do
      build_heightmap(
        logical_scene_id,
        origin_x,
        origin_z,
        stride,
        count_x,
        count_z,
        column_index,
        decode_meta
      )
    end
  end

  defp snapshot_source?(opts) do
    Keyword.has_key?(opts, :snapshot_index) or Keyword.has_key?(opts, :snapshot_store) or
      Keyword.get(opts, :source) in [:snapshot_store, :chunk_snapshot_store, :direct_snapshot]
  end

  defp build_heightmap(
         logical_scene_id,
         origin_x,
         origin_z,
         stride,
         count_x,
         count_z,
         column_index,
         decode_meta
       ) do
    {height_iodata_rev, material_iodata_rev, missing_rev} =
      Enum.reduce(0..(count_z - 1), {[], [], []}, fn j, {heights, materials, missing} ->
        Enum.reduce(0..(count_x - 1), {heights, materials, missing}, fn i,
                                                                        {inner_heights,
                                                                         inner_materials,
                                                                         inner_missing} ->
          wx = origin_x + i * stride
          wz = origin_z + j * stride
          {cx, mx} = Types.chunk_and_local_macro_axis(wx)
          {cz, mz} = Types.chunk_and_local_macro_axis(wz)

          case column_surface(column_index, cx, cz, mx, mz) do
            {:ok, %{height: height, material_id: material_id}} ->
              {[<<clamp_u16(height)::unsigned-big-integer-size(16)>> | inner_heights],
               [<<clamp_u16(material_id)::unsigned-big-integer-size(16)>> | inner_materials],
               inner_missing}

            :missing ->
              {inner_heights, inner_materials,
               maybe_add_missing(inner_missing, %{wx: wx, wz: wz, cx: cx, cz: cz})}
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
         meta:
           Map.merge(decode_meta, %{
             logical_scene_id: logical_scene_id,
             origin: {origin_x, origin_z},
             stride: stride,
             count: {count_x, count_z},
             sample_count: sample_count,
             missing_count: 0,
             source: :authoritative_chunk_snapshot_store
           })
       }}
    else
      {:error,
       {:missing_authoritative_columns,
        %{
          logical_scene_id: logical_scene_id,
          origin: {origin_x, origin_z},
          stride: stride,
          count: {count_x, count_z},
          sample_count: sample_count,
          missing_count: missing_count,
          missing_sample: Enum.reverse(missing_rev)
        }}}
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

  defp load_column_index(logical_scene_id, opts) do
    with {:ok, raw_index} <- load_raw_snapshot_index(opts),
         {:ok, storages, decode_meta} <- decode_scene_storages(raw_index, logical_scene_id) do
      columns =
        storages
        |> Enum.group_by(fn %Storage{chunk_coord: {cx, _cy, cz}} -> {cx, cz} end)
        |> Map.new(fn {key, column_storages} ->
          sorted =
            Enum.sort_by(
              column_storages,
              fn %Storage{chunk_coord: {_cx, cy, _cz}} -> cy end,
              :desc
            )

          {key, sorted}
        end)

      {:ok, columns, Map.put(decode_meta, :decoded_column_count, map_size(columns))}
    end
  end

  defp load_raw_snapshot_index(opts) do
    case Keyword.fetch(opts, :snapshot_index) do
      {:ok, index} when is_map(index) ->
        {:ok, index}

      {:ok, _other} ->
        {:error, :invalid_snapshot_index}

      :error ->
        store = Keyword.get(opts, :snapshot_store, DataService.Voxel.ChunkSnapshotStore)

        try do
          case store.snapshot() do
            index when is_map(index) -> {:ok, index}
            _other -> {:error, :invalid_snapshot_index}
          end
        catch
          :exit, reason -> {:error, {:snapshot_store_unavailable, reason}}
        end
    end
  end

  defp decode_scene_storages(raw_index, logical_scene_id) do
    raw_index
    |> Enum.reduce_while({:ok, [], %{decoded_chunk_count: 0}}, fn
      {{^logical_scene_id, _chunk_coord}, value}, {:ok, storages, meta} ->
        case decode_storage(value) do
          {:ok, %Storage{} = storage} ->
            {:cont,
             {:ok, [storage | storages],
              %{meta | decoded_chunk_count: meta.decoded_chunk_count + 1}}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_authoritative_snapshot, reason}}}
        end

      {_other_key, _value}, acc ->
        {:cont, acc}
    end)
  end

  defp decode_storage(%Storage{} = storage), do: {:ok, Storage.normalize!(storage)}

  defp decode_storage(%{storage: %Storage{} = storage}), do: {:ok, Storage.normalize!(storage)}

  defp decode_storage(%{data: data}) when is_binary(data), do: decode_storage(data)

  defp decode_storage(data) when is_binary(data) do
    case Codec.decode_chunk_snapshot_payload(data) do
      {:ok, %{storage: %Storage{} = storage}} -> {:ok, storage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_storage(other), do: {:error, {:unsupported_snapshot_value, other}}

  defp column_surface(column_index, cx, cz, mx, mz) do
    case Map.get(column_index, {cx, cz}) do
      nil ->
        :missing

      storages ->
        column_loaded? = true

        storages
        |> Enum.find_value(fn %Storage{chunk_coord: {_cx, cy, _cz}} = storage ->
          storage
          |> top_local_surface(mx, mz)
          |> case do
            nil ->
              nil

            %{local_y: my, material_id: material_id} ->
              {:ok, %{height: cy * @chunk_size + my + 1, material_id: material_id}}
          end
        end)
        |> case do
          nil when column_loaded? -> {:ok, %{height: 0, material_id: 0}}
          {:ok, surface} -> {:ok, surface}
        end
    end
  end

  defp top_local_surface(%Storage{} = storage, mx, mz) do
    headers = Storage.index_macro_headers(storage)

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

  defp clamp_u16(value) when value < 0, do: 0
  defp clamp_u16(value) when value > @u16_max, do: @u16_max
  defp clamp_u16(value), do: value
end
