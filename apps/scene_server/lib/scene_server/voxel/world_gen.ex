defmodule SceneServer.Voxel.WorldGen do
  @moduledoc """
  服务端部署期 canonical XYZ 世界生成器。

  WorldGen 不是在线 runtime fallback。它只供 dev migration / world-pack materialization
  使用：Rust NIF 从完整世界 XYZ 生成固定 16x16x16 材质体，本模块在一次信任边界校验后
  构造成 canonical `Storage`，再由 `WorldGenMaterializer` 在 World-issued lease fence 下写入
  权威 store。

  `column_height/3` 与 `heightmap_region/6` 仅为历史 XZ 离线迁移保留；新的 chunk 生成不调用
  heightmap，也不向 runtime、streaming、LOD 或客户端暴露 column 语义。
  """

  alias SceneServer.Native.WorldGenNoise
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @chunk_size Types.chunk_size_in_macro()
  @macro_cell_count @chunk_size * @chunk_size * @chunk_size
  @material_binary_bytes @macro_cell_count * 2
  @i32_min -2_147_483_648
  @i32_max 2_147_483_647
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @max_u63 9_223_372_036_854_775_807

  @default_seed 1337
  @sea_level 64
  @max_height 1600
  @soil_depth 4

  @type opts :: keyword()
  @type chunk_observation :: %{
          algorithm_version: String.t(),
          chunk_coord: Types.chunk_coord(),
          seed: integer(),
          total_cells: pos_integer(),
          solid_cells: non_neg_integer(),
          natural_air_cells: non_neg_integer(),
          cave_air_cells: non_neg_integer(),
          surface_cells: non_neg_integer(),
          subsurface_cells: non_neg_integer(),
          generation_us: non_neg_integer()
        }

  @doc "当前 canonical XYZ 材质体算法身份；算法输出变化必须换版并发布新 content version。"
  @spec algorithm_version() :: String.t()
  def algorithm_version, do: WorldGenNoise.algorithm_version()

  @doc "未显式提供 seed 时使用的单一开发世界种子。"
  @spec default_seed() :: integer()
  def default_seed, do: @default_seed

  @doc """
  历史 XZ 离线迁移 helper：返回 `(wx, wz)` 列的第一个 air world-y。

  canonical chunk 生成不调用本函数；在线 runtime 也不得把它当作 truth 或 fallback。
  """
  @deprecated "archived XZ column helper only"
  @spec column_height(integer(), integer(), opts()) :: integer()
  def column_height(wx, wz, opts \\ []) do
    seed = Keyword.get(opts, :seed, @default_seed)
    sea_level = Keyword.get(opts, :sea_level, @sea_level)
    max_height = Keyword.get(opts, :max_height, @max_height)

    WorldGenNoise.column_height(wx, wz, seed, sea_level, max_height)
  end

  @doc """
  历史 XZ heightmap 离线迁移 helper。在线 `0x6A` 已归档并明确拒绝，新的 canonical
  materialization 不调用本函数。
  """
  @deprecated "archived XZ heightmap offline migration helper only"
  @spec heightmap_region(
          integer(),
          integer(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          opts()
        ) :: binary()
  def heightmap_region(origin_x, origin_z, stride, count_x, count_z, opts \\ [])
      when stride > 0 and count_x > 0 and count_z > 0 do
    seed = Keyword.get(opts, :seed, @default_seed)
    sea_level = Keyword.get(opts, :sea_level, @sea_level)
    max_height = Keyword.get(opts, :max_height, @max_height)

    WorldGenNoise.heightmap_region(
      origin_x,
      origin_z,
      stride,
      count_x,
      count_z,
      seed,
      sea_level,
      max_height
    )
  end

  @doc """
  从完整 XYZ 世界坐标生成一个 pristine canonical chunk。

  返回同一次生成得到的 `Storage` 与结构化 observation。非法输入、NIF 失败或 NIF 契约不一致
  均返回显式错误，不发布半个 Storage。
  """
  @spec generate_chunk(non_neg_integer(), Types.chunk_coord(), opts()) ::
          {:ok, Storage.t(), chunk_observation()} | {:error, term()}
  def generate_chunk(logical_scene_id, chunk_coord, opts \\ []) do
    started_at = System.monotonic_time()

    with :ok <- validate_logical_scene_id(logical_scene_id),
         {:ok, config} <- normalize_config(opts),
         {:ok, origin} <- chunk_origin(chunk_coord),
         {:ok, algorithm_version} <- fetch_algorithm_version(),
         {:ok, raw_volume} <- generate_material_volume(origin, config),
         {:ok, volume} <- validate_material_volume(raw_volume),
         {:ok, decoded} <- material_entries(volume.materials, config),
         :ok <- verify_decoded_counts(volume, decoded),
         storage <-
           logical_scene_id
           |> Storage.empty(chunk_coord)
           |> Storage.put_solid_blocks(decoded.entries) do
      generation_us =
        System.monotonic_time()
        |> Kernel.-(started_at)
        |> System.convert_time_unit(:native, :microsecond)

      observation = %{
        algorithm_version: algorithm_version,
        chunk_coord: chunk_coord,
        seed: config.seed,
        total_cells: @macro_cell_count,
        solid_cells: volume.solid_cells,
        natural_air_cells: @macro_cell_count - volume.solid_cells - volume.cave_air_cells,
        cave_air_cells: volume.cave_air_cells,
        surface_cells: volume.surface_cells,
        subsurface_cells: volume.subsurface_cells,
        generation_us: generation_us
      }

      {:ok, storage, observation}
    end
  rescue
    exception -> {:error, {:worldgen_generation_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:worldgen_generation_exit, reason}}
    kind, reason -> {:error, {:worldgen_generation_catch, kind, reason}}
  end

  @doc """
  `generate_chunk/3` 的既有 Storage-only 兼容入口。

  生成失败会携带稳定 reason 抛出 `ArgumentError`；需要类型化失败的 migration/materializer
  调用方应直接使用 `generate_chunk/3`。
  """
  @spec generate_chunk_storage(non_neg_integer(), Types.chunk_coord(), opts()) :: Storage.t()
  def generate_chunk_storage(logical_scene_id, chunk_coord, opts \\ []) do
    case generate_chunk(logical_scene_id, chunk_coord, opts) do
      {:ok, storage, _observation} ->
        storage

      {:error, reason} ->
        raise ArgumentError, "WorldGen chunk generation failed: #{inspect(reason)}"
    end
  end

  @doc "生成并精确判断 canonical chunk 是否没有 solid macro；不使用 XZ 高度近似。"
  @spec air_chunk?(Types.chunk_coord(), opts()) :: boolean()
  def air_chunk?(chunk_coord, opts \\ []) do
    case generate_chunk(0, chunk_coord, opts) do
      {:ok, _storage, %{solid_cells: 0}} -> true
      {:ok, _storage, _observation} -> false
      {:error, reason} -> raise ArgumentError, "WorldGen air check failed: #{inspect(reason)}"
    end
  end

  defp normalize_config(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      config = %{
        seed: Keyword.get(opts, :seed, @default_seed),
        sea_level: Keyword.get(opts, :sea_level, @sea_level),
        max_height: Keyword.get(opts, :max_height, @max_height),
        soil_depth: Keyword.get(opts, :soil_depth, @soil_depth),
        surface_material_id: MaterialCatalog.material_id(:dirt),
        subsurface_material_id: MaterialCatalog.material_id(:stone)
      }

      validate_config(config)
    else
      {:error, :invalid_worldgen_options}
    end
  end

  defp normalize_config(_opts), do: {:error, :invalid_worldgen_options}

  defp validate_config(config) do
    cond do
      not is_integer(config.seed) or config.seed < @i64_min or config.seed > @i64_max ->
        {:error, {:invalid_worldgen_option, :seed}}

      not is_integer(config.sea_level) or config.sea_level < 0 or
          config.sea_level > @i64_max ->
        {:error, {:invalid_worldgen_option, :sea_level}}

      not is_integer(config.max_height) or config.max_height < config.sea_level or
          config.max_height > @i64_max ->
        {:error, {:invalid_worldgen_option, :max_height}}

      not is_integer(config.soil_depth) or config.soil_depth <= 0 or
          config.soil_depth > @i64_max ->
        {:error, {:invalid_worldgen_option, :soil_depth}}

      not valid_material_id?(config.surface_material_id) ->
        {:error, {:invalid_worldgen_material, :surface}}

      not valid_material_id?(config.subsurface_material_id) ->
        {:error, {:invalid_worldgen_material, :subsurface}}

      true ->
        {:ok, config}
    end
  end

  defp valid_material_id?(material_id),
    do: is_integer(material_id) and material_id > 0 and material_id <= 65_535

  defp validate_logical_scene_id(value)
       when is_integer(value) and value >= 0 and value <= @max_u63,
       do: :ok

  defp validate_logical_scene_id(_value), do: {:error, :invalid_logical_scene_id}

  defp chunk_origin({cx, cy, cz})
       when is_integer(cx) and is_integer(cy) and is_integer(cz) do
    if Enum.all?([cx, cy, cz], &(&1 >= @i32_min and &1 <= @i32_max)) do
      origins = {cx * @chunk_size, cy * @chunk_size, cz * @chunk_size}

      if origins
         |> Tuple.to_list()
         |> Enum.all?(&valid_origin_axis?/1) do
        {:ok, origins}
      else
        {:error, :worldgen_coordinate_out_of_range}
      end
    else
      {:error, :worldgen_chunk_coord_out_of_range}
    end
  end

  defp chunk_origin(_chunk_coord), do: {:error, :invalid_chunk_coord}

  defp valid_origin_axis?(origin),
    do: origin >= @i64_min and origin <= @i64_max - (@chunk_size - 1)

  defp fetch_algorithm_version do
    case WorldGenNoise.algorithm_version() do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      other -> {:error, {:invalid_worldgen_algorithm_version, other}}
    end
  end

  defp generate_material_volume({origin_x, origin_y, origin_z}, config) do
    {:ok,
     WorldGenNoise.chunk_materials(
       origin_x,
       origin_y,
       origin_z,
       config.seed,
       config.sea_level,
       config.max_height,
       config.soil_depth,
       config.surface_material_id,
       config.subsurface_material_id
     )}
  rescue
    exception -> {:error, {:worldgen_nif_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:worldgen_nif_exit, reason}}
    kind, reason -> {:error, {:worldgen_nif_catch, kind, reason}}
  end

  defp validate_material_volume(
         {materials, solid_cells, cave_air_cells, surface_cells, subsurface_cells}
       )
       when is_binary(materials) and byte_size(materials) == @material_binary_bytes and
              is_integer(solid_cells) and solid_cells >= 0 and
              is_integer(cave_air_cells) and cave_air_cells >= 0 and
              is_integer(surface_cells) and surface_cells >= 0 and
              is_integer(subsurface_cells) and subsurface_cells >= 0 and
              solid_cells == surface_cells + subsurface_cells and
              solid_cells + cave_air_cells <= @macro_cell_count do
    {:ok,
     %{
       materials: materials,
       solid_cells: solid_cells,
       cave_air_cells: cave_air_cells,
       surface_cells: surface_cells,
       subsurface_cells: subsurface_cells
     }}
  end

  defp validate_material_volume(other),
    do: {:error, {:invalid_worldgen_material_volume, summarize_nif_result(other)}}

  defp summarize_nif_result({materials, solid, cave, surface, subsurface}) do
    %{
      material_bytes: if(is_binary(materials), do: byte_size(materials), else: :not_binary),
      solid_cells: solid,
      cave_air_cells: cave,
      surface_cells: surface,
      subsurface_cells: subsurface
    }
  end

  defp summarize_nif_result(other), do: inspect(other)

  defp material_entries(materials, config) do
    decode_material_entries(materials, 0, config, [], 0, 0)
  end

  defp decode_material_entries(
         <<>>,
         @macro_cell_count,
         _config,
         entries,
         surface_cells,
         subsurface_cells
       ) do
    {:ok,
     %{
       entries: Enum.reverse(entries),
       solid_cells: surface_cells + subsurface_cells,
       surface_cells: surface_cells,
       subsurface_cells: subsurface_cells
     }}
  end

  defp decode_material_entries(
         <<0::unsigned-big-16, rest::binary>>,
         index,
         config,
         entries,
         surface_cells,
         subsurface_cells
       ),
       do:
         decode_material_entries(
           rest,
           index + 1,
           config,
           entries,
           surface_cells,
           subsurface_cells
         )

  defp decode_material_entries(
         <<material_id::unsigned-big-16, rest::binary>>,
         index,
         config,
         entries,
         surface_cells,
         subsurface_cells
       )
       when material_id == config.surface_material_id do
    entry = {index, NormalBlockData.new(material_id), [cell_version: 0, cell_hash: 0]}

    decode_material_entries(
      rest,
      index + 1,
      config,
      [entry | entries],
      surface_cells + 1,
      subsurface_cells
    )
  end

  defp decode_material_entries(
         <<material_id::unsigned-big-16, rest::binary>>,
         index,
         config,
         entries,
         surface_cells,
         subsurface_cells
       )
       when material_id == config.subsurface_material_id do
    entry = {index, NormalBlockData.new(material_id), [cell_version: 0, cell_hash: 0]}

    decode_material_entries(
      rest,
      index + 1,
      config,
      [entry | entries],
      surface_cells,
      subsurface_cells + 1
    )
  end

  defp decode_material_entries(
         <<material_id::unsigned-big-16, _rest::binary>>,
         index,
         _config,
         _entries,
         _surface_cells,
         _subsurface_cells
       ),
       do: {:error, {:unexpected_worldgen_material_id, index, material_id}}

  defp verify_decoded_counts(volume, decoded) do
    actual =
      Map.take(decoded, [
        :solid_cells,
        :surface_cells,
        :subsurface_cells
      ])

    expected =
      Map.take(volume, [
        :solid_cells,
        :surface_cells,
        :subsurface_cells
      ])

    if actual == expected do
      :ok
    else
      {:error, {:worldgen_material_count_mismatch, expected, actual}}
    end
  end
end
