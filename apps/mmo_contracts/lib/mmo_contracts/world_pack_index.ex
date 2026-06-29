defmodule MmoContracts.WorldPackIndex do
  @moduledoc """
  紧凑 world-pack 覆盖索引工具。

  本模块描述完整权威 baseline 覆盖，但不枚举或物化每个 chunk。
  每个 region 是一个轴对齐、两端都包含的 chunk 盒子，并携带内容 hash。
  校验会证明 region 都落在声明世界边界内、彼此不重叠，并覆盖声明的
  chunk 数量。

  runtime streaming 与 baseline 覆盖分离：`sliding_window/2` 和
  `window_transition/2` 只建模 Voxia 从已验证本地包加载的 active radius
  窗口，然后客户端再订阅在线权威 diff。
  """

  @type chunk_coord :: {integer(), integer(), integer()}
  @type region :: %{
          required(:id) => String.t(),
          required(:chunk_min) => chunk_coord(),
          required(:chunk_max) => chunk_coord(),
          required(:chunk_count) => non_neg_integer(),
          required(:hash) => String.t()
        }
  @type payload_layout :: %{
          required(:layout) => String.t(),
          required(:chunk_payload_format) => String.t(),
          required(:shard_chunk_shape) => chunk_coord(),
          required(:shard_origin) => chunk_coord(),
          required(:file_template) => String.t(),
          required(:footer_format) => String.t(),
          required(:compression) => String.t()
        }
  @type t :: %__MODULE__{
          logical_scene_id: non_neg_integer(),
          content_version: String.t(),
          chunk_min: chunk_coord(),
          chunk_max: chunk_coord(),
          payload_layout: payload_layout() | nil,
          regions: [region()]
        }
  @type window :: %{
          center: chunk_coord(),
          radius: non_neg_integer(),
          chunk_min: chunk_coord(),
          chunk_max: chunk_coord(),
          chunk_count: pos_integer()
        }
  @type payload_shard_grid :: %{
          shard_min: chunk_coord(),
          shard_max: chunk_coord(),
          shard_count: pos_integer(),
          shard_coords: [chunk_coord()]
        }
  @type payload_shard_summary :: %{
          shard_coord: chunk_coord(),
          path: String.t(),
          chunk_min: chunk_coord(),
          chunk_max: chunk_coord(),
          chunk_count: pos_integer()
        }
  @type payload_shard_plan :: %{
          shard_coord: chunk_coord(),
          path: String.t(),
          chunk_min: chunk_coord(),
          chunk_max: chunk_coord(),
          chunk_count: pos_integer(),
          chunks: [map()]
        }

  defstruct logical_scene_id: nil,
            content_version: nil,
            chunk_min: nil,
            chunk_max: nil,
            payload_layout: nil,
            regions: []

  @doc """
  构建紧凑 world-pack 索引；构造输入非法时抛出异常。
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    with {:ok, index} <- new(opts) do
      index
    else
      {:error, reason} -> raise ArgumentError, "invalid world pack index: #{inspect(reason)}"
    end
  end

  @doc """
  构建紧凑 world-pack 索引。
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id)
    content_version = Keyword.get(opts, :content_version)
    chunk_min = normalize_chunk_coord(Keyword.get(opts, :chunk_min))
    chunk_max = normalize_chunk_coord(Keyword.get(opts, :chunk_max))
    payload_layout = Keyword.get(opts, :payload_layout)
    regions = Keyword.get(opts, :regions, [])

    with :ok <- validate_logical_scene_id(logical_scene_id),
         :ok <- validate_content_version(content_version),
         :ok <- validate_bounds(chunk_min, chunk_max),
         {:ok, normalized_payload_layout} <- normalize_payload_layout(payload_layout),
         {:ok, normalized_regions} <- normalize_regions(regions) do
      {:ok,
       %__MODULE__{
         logical_scene_id: logical_scene_id,
         content_version: content_version,
         chunk_min: chunk_min,
         chunk_max: chunk_max,
         payload_layout: normalized_payload_layout,
         regions: normalized_regions
       }}
    end
  end

  def new(_opts), do: {:error, :invalid_world_pack_index_options}

  @doc "返回索引或边界覆盖的 3D chunk 总数，边界两端都包含。"
  @spec chunk_count(t() | {chunk_coord(), chunk_coord()}) :: non_neg_integer()
  def chunk_count(%__MODULE__{chunk_min: min, chunk_max: max}), do: bounds_chunk_count(min, max)
  def chunk_count({min, max}), do: bounds_chunk_count(min, max)

  @doc "返回索引覆盖的水平 chunk 列数。"
  @spec horizontal_chunk_count(t()) :: non_neg_integer()
  def horizontal_chunk_count(%__MODULE__{
        chunk_min: {min_x, _min_y, min_z},
        chunk_max: {max_x, _max_y, max_z}
      }) do
    axis_count(min_x, max_x) * axis_count(min_z, max_z)
  end

  @doc "返回索引覆盖的垂直 chunk 层数。"
  @spec vertical_chunk_layers(t()) :: non_neg_integer()
  def vertical_chunk_layers(%__MODULE__{
        chunk_min: {_min_x, min_y, _min_z},
        chunk_max: {_max_x, max_y, _max_z}
      }) do
    axis_count(min_y, max_y)
  end

  @doc """
  在不枚举单个 chunk 的前提下校验 region 覆盖。
  """
  @spec verify(t()) :: {:ok, map()} | {:error, map()}
  def verify(%__MODULE__{} = index) do
    expected_count = chunk_count(index)

    with :ok <- validate_regions_inside_bounds(index),
         :ok <- validate_region_counts(index),
         :ok <- validate_no_overlaps(index) do
      covered_count = covered_chunk_count(index.regions)

      if covered_count == expected_count do
        {:ok,
         %{
           status: :ready,
           logical_scene_id: index.logical_scene_id,
           content_version: index.content_version,
           expected_chunk_count: expected_count,
           covered_chunk_count: covered_count,
           region_count: length(index.regions)
         }}
      else
        {:error,
         %{
           status: :incomplete,
           reason: :bounds_not_fully_covered,
           logical_scene_id: index.logical_scene_id,
           content_version: index.content_version,
           expected_chunk_count: expected_count,
           covered_chunk_count: covered_count,
           missing_chunk_count: expected_count - covered_count,
           region_count: length(index.regions)
         }}
      end
    else
      {:error, reason, extra} ->
        {:error,
         %{
           status: :invalid,
           reason: reason,
           logical_scene_id: index.logical_scene_id,
           content_version: index.content_version
         }
         |> Map.merge(extra)}
    end
  end

  def verify(_index), do: {:error, %{status: :invalid, reason: :invalid_world_pack_index}}

  @doc """
  根据中心点和 L-infinity 半径构建 active chunk 窗口。
  """
  @spec sliding_window(chunk_coord(), non_neg_integer()) :: window()
  def sliding_window({center_x, center_y, center_z} = center, radius)
      when is_integer(radius) and radius >= 0 do
    chunk_min = {center_x - radius, center_y - radius, center_z - radius}
    chunk_max = {center_x + radius, center_y + radius, center_z + radius}

    %{
      center: center,
      radius: radius,
      chunk_min: chunk_min,
      chunk_max: chunk_max,
      chunk_count: bounds_chunk_count(chunk_min, chunk_max)
    }
  end

  @doc "返回滑动窗口的包含式 chunk 边界。"
  @spec window_bounds(window()) :: %{chunk_min: chunk_coord(), chunk_max: chunk_coord()}
  def window_bounds(%{chunk_min: chunk_min, chunk_max: chunk_max}) do
    %{chunk_min: chunk_min, chunk_max: chunk_max}
  end

  @doc """
  计算两个窗口之间进入、离开、保留的 chunk 数量。
  """
  @spec window_transition(window(), window()) :: map()
  def window_transition(%{chunk_count: from_count} = from, %{chunk_count: to_count} = to) do
    kept = intersection_chunk_count(from.chunk_min, from.chunk_max, to.chunk_min, to.chunk_max)

    %{
      from: from.center,
      to: to.center,
      kept_chunks: kept,
      leaving_chunks: from_count - kept,
      entering_chunks: to_count - kept
    }
  end

  @doc """
  校验滑动窗口是否完全落在已验证 pack 边界内。
  """
  @spec validate_window(t(), chunk_coord(), non_neg_integer()) :: :ok | {:error, map()}
  def validate_window(%__MODULE__{} = index, center, radius) do
    window = sliding_window(center, radius)

    if bounds_contains?(index.chunk_min, index.chunk_max, window.chunk_min, window.chunk_max) do
      :ok
    else
      {:error,
       %{
         reason: :window_out_of_bounds,
         center: center,
         radius: radius,
         window: window_bounds(window),
         pack_bounds: %{chunk_min: index.chunk_min, chunk_max: index.chunk_max}
       }}
    end
  end

  @doc """
  为一个 active sliding window 生成本地 payload shard 读取计划。

  计划只枚举当前窗口里的 chunk，不枚举完整 world-pack。
  """
  @spec window_payload_plan(t(), chunk_coord(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def window_payload_plan(%__MODULE__{payload_layout: nil}, _center, _radius),
    do: {:error, :payload_layout_missing}

  def window_payload_plan(%__MODULE__{payload_layout: payload_layout} = index, center, radius) do
    with :ok <- validate_window(index, center, radius) do
      window = sliding_window(center, radius)

      chunks =
        for cx <- elem(window.chunk_min, 0)..elem(window.chunk_max, 0),
            cy <- elem(window.chunk_min, 1)..elem(window.chunk_max, 1),
            cz <- elem(window.chunk_min, 2)..elem(window.chunk_max, 2) do
          {cx, cy, cz}
        end

      shards =
        chunks
        |> Enum.map(&payload_ref(payload_layout, &1))
        |> Enum.group_by(& &1.shard_coord)
        |> Enum.map(fn {shard_coord, refs} ->
          refs = Enum.sort_by(refs, & &1.ordinal)

          %{
            shard_coord: shard_coord,
            path: refs |> hd() |> Map.fetch!(:path),
            chunk_count: length(refs),
            chunks: refs
          }
        end)
        |> Enum.sort_by(& &1.shard_coord)

      {:ok, %{window: window, chunk_count: length(chunks), shards: shards}}
    end
  end

  @doc """
  返回完整 payload shard 网格摘要。

  这个函数只枚举 shard 坐标，不枚举每个 chunk payload ref。32km 默认布局下
  结果是 16,384 个 shard，而不是 444,596,224 个 chunk。
  """
  @spec payload_shard_grid(t()) :: {:ok, payload_shard_grid()} | {:error, term()}
  def payload_shard_grid(%__MODULE__{payload_layout: nil}), do: {:error, :payload_layout_missing}

  def payload_shard_grid(%__MODULE__{payload_layout: payload_layout} = index) do
    shard_min = payload_ref(payload_layout, index.chunk_min).shard_coord
    shard_max = payload_ref(payload_layout, index.chunk_max).shard_coord
    {min_sx, min_sy, min_sz} = shard_min
    {max_sx, max_sy, max_sz} = shard_max

    shard_coords =
      for sx <- min_sx..max_sx,
          sy <- min_sy..max_sy,
          sz <- min_sz..max_sz do
        {sx, sy, sz}
      end

    {:ok,
     %{
       shard_min: shard_min,
       shard_max: shard_max,
       shard_count: length(shard_coords),
       shard_coords: shard_coords
     }}
  end

  @doc """
  返回单个 payload shard 的路径、边界和 chunk 数，不展开 chunk refs。
  """
  @spec payload_shard_summary(t(), chunk_coord()) ::
          {:ok, payload_shard_summary()} | {:error, term()}
  def payload_shard_summary(%__MODULE__{payload_layout: nil}, _shard_coord),
    do: {:error, :payload_layout_missing}

  def payload_shard_summary(%__MODULE__{} = index, shard_coord) do
    with {:ok, grid} <- payload_shard_grid(index) do
      payload_shard_summary_in_grid(index, grid, shard_coord)
    end
  end

  @doc """
  返回完整 payload shard 集合的轻量摘要，不展开 chunk refs。

  与对每个 shard 调 `payload_shard_summary/2` 不同，本函数只计算一次完整
  shard grid，适合作为 32km release pack manifest 验证的输入。
  """
  @spec payload_shard_summaries(t()) :: {:ok, [payload_shard_summary()]} | {:error, term()}
  def payload_shard_summaries(%__MODULE__{payload_layout: nil}),
    do: {:error, :payload_layout_missing}

  def payload_shard_summaries(%__MODULE__{} = index) do
    with {:ok, grid} <- payload_shard_grid(index) do
      grid.shard_coords
      |> Enum.reduce_while({:ok, []}, fn shard_coord, {:ok, acc} ->
        case payload_shard_summary_in_grid(index, grid, shard_coord) do
          {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  展开单个 payload shard 内的 chunk refs。

  full-pack 生成器应按 shard 调用本函数并逐 shard 写 `.vxpack`，不能为了生成
  完整 32km 包而把所有 chunk refs 一次性放进内存。
  """
  @spec payload_shard_plan(t(), chunk_coord()) :: {:ok, payload_shard_plan()} | {:error, term()}
  def payload_shard_plan(%__MODULE__{payload_layout: nil}, _shard_coord),
    do: {:error, :payload_layout_missing}

  def payload_shard_plan(%__MODULE__{payload_layout: payload_layout} = index, shard_coord) do
    with {:ok, summary} <- payload_shard_summary(index, shard_coord) do
      chunk_min = summary.chunk_min
      chunk_max = summary.chunk_max

      chunks =
        for cx <- elem(chunk_min, 0)..elem(chunk_max, 0),
            cy <- elem(chunk_min, 1)..elem(chunk_max, 1),
            cz <- elem(chunk_min, 2)..elem(chunk_max, 2) do
          payload_ref(payload_layout, {cx, cy, cz})
        end
        |> Enum.sort_by(& &1.ordinal)

      {:ok,
       %{
         shard_coord: summary.shard_coord,
         path: summary.path,
         chunk_min: chunk_min,
         chunk_max: chunk_max,
         chunk_count: summary.chunk_count,
         chunks: chunks
       }}
    end
  end

  defp normalize_regions(regions) when is_list(regions) do
    Enum.reduce_while(regions, {:ok, []}, fn region, {:ok, acc} ->
      case normalize_region(region) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_regions(_regions), do: {:error, :invalid_regions}

  defp normalize_payload_layout(nil), do: {:ok, nil}

  defp normalize_payload_layout(value) do
    layout = layout_value(value, :layout)
    chunk_payload_format = layout_value(value, :chunk_payload_format)
    shard_chunk_shape = normalize_positive_chunk_shape(layout_value(value, :shard_chunk_shape))
    shard_origin = normalize_chunk_coord(layout_value(value, :shard_origin))
    file_template = layout_value(value, :file_template)
    footer_format = layout_value(value, :footer_format) || "chunk_offset_table_v1"
    compression = layout_value(value, :compression) || "none"

    cond do
      layout != "regular_shard_grid_v1" ->
        {:error, :invalid_payload_layout}

      not valid_nonempty_binary?(chunk_payload_format) ->
        {:error, :invalid_payload_chunk_payload_format}

      shard_chunk_shape == :invalid_chunk_coord ->
        {:error, :invalid_payload_shard_chunk_shape}

      shard_origin == :invalid_chunk_coord ->
        {:error, :invalid_payload_shard_origin}

      not valid_nonempty_binary?(file_template) ->
        {:error, :invalid_payload_file_template}

      not valid_nonempty_binary?(footer_format) ->
        {:error, :invalid_payload_footer_format}

      not valid_nonempty_binary?(compression) ->
        {:error, :invalid_payload_compression}

      true ->
        {:ok,
         %{
           layout: layout,
           chunk_payload_format: chunk_payload_format,
           shard_chunk_shape: shard_chunk_shape,
           shard_origin: shard_origin,
           file_template: file_template,
           footer_format: footer_format,
           compression: compression
         }}
    end
  end

  defp layout_value(%{} = value, key) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp layout_value(value, key) when is_list(value) do
    Keyword.get(value, key) || list_key_value(value, Atom.to_string(key))
  end

  defp layout_value(_value, _key), do: nil

  defp list_key_value(value, key) do
    case List.keyfind(value, key, 0) do
      {^key, found} -> found
      _other -> nil
    end
  end

  defp normalize_positive_chunk_shape(value) do
    case normalize_chunk_coord(value) do
      {x, y, z} = coord when x > 0 and y > 0 and z > 0 -> coord
      _other -> :invalid_chunk_coord
    end
  end

  defp normalize_region(%{} = region) do
    normalized = %{
      id: to_string(Map.get(region, :id) || Map.get(region, "id")),
      chunk_min:
        normalize_chunk_coord(Map.get(region, :chunk_min) || Map.get(region, "chunk_min")),
      chunk_max:
        normalize_chunk_coord(Map.get(region, :chunk_max) || Map.get(region, "chunk_max")),
      chunk_count: Map.get(region, :chunk_count) || Map.get(region, "chunk_count"),
      hash: to_string(Map.get(region, :hash) || Map.get(region, "hash"))
    }

    with :ok <- validate_region_id(normalized.id),
         :ok <- validate_region_hash(normalized.hash),
         :ok <- validate_bounds(normalized.chunk_min, normalized.chunk_max),
         :ok <- validate_non_negative_count(normalized.chunk_count) do
      {:ok, normalized}
    end
  end

  defp normalize_region(_region), do: {:error, :invalid_region}

  defp validate_regions_inside_bounds(%__MODULE__{} = index) do
    bad =
      Enum.find(index.regions, fn region ->
        not bounds_contains?(index.chunk_min, index.chunk_max, region.chunk_min, region.chunk_max)
      end)

    case bad do
      nil -> :ok
      region -> {:error, :region_out_of_bounds, %{region_id: region.id}}
    end
  end

  defp validate_region_counts(%__MODULE__{} = index) do
    bad =
      Enum.find(index.regions, fn region ->
        bounds_chunk_count(region.chunk_min, region.chunk_max) != region.chunk_count
      end)

    case bad do
      nil ->
        :ok

      region ->
        {:error, :region_chunk_count_mismatch,
         %{
           region_id: region.id,
           declared_chunk_count: region.chunk_count,
           actual_chunk_count: bounds_chunk_count(region.chunk_min, region.chunk_max)
         }}
    end
  end

  defp validate_no_overlaps(%__MODULE__{} = index) do
    overlaps =
      index.regions
      |> region_pairs()
      |> Enum.reduce(0, fn {left, right}, acc ->
        acc +
          intersection_chunk_count(
            left.chunk_min,
            left.chunk_max,
            right.chunk_min,
            right.chunk_max
          )
      end)

    if overlaps == 0 do
      :ok
    else
      {:error, :overlapping_regions, %{overlap_count: overlaps}}
    end
  end

  defp region_pairs(regions) do
    regions
    |> Enum.with_index()
    |> Enum.flat_map(fn {left, index} ->
      regions
      |> Enum.drop(index + 1)
      |> Enum.map(&{left, &1})
    end)
  end

  defp covered_chunk_count(regions) do
    Enum.reduce(regions, 0, fn region, acc -> acc + region.chunk_count end)
  end

  defp payload_ref(payload_layout, {cx, cy, cz} = chunk_coord) do
    {origin_x, origin_y, origin_z} = payload_layout.shard_origin
    {shape_x, shape_y, shape_z} = payload_layout.shard_chunk_shape
    shard_x = floor_div(cx - origin_x, shape_x)
    shard_y = floor_div(cy - origin_y, shape_y)
    shard_z = floor_div(cz - origin_z, shape_z)
    local_x = cx - origin_x - shard_x * shape_x
    local_y = cy - origin_y - shard_y * shape_y
    local_z = cz - origin_z - shard_z * shape_z
    shard_coord = {shard_x, shard_y, shard_z}
    local_coord = {local_x, local_y, local_z}

    %{
      chunk_coord: chunk_coord,
      shard_coord: shard_coord,
      local_coord: local_coord,
      ordinal: local_x + local_y * shape_x + local_z * shape_x * shape_y,
      path: payload_shard_path(payload_layout.file_template, shard_coord)
    }
  end

  defp payload_shard_path(template, {shard_x, shard_y, shard_z}) do
    template
    |> String.replace("{sx}", Integer.to_string(shard_x))
    |> String.replace("{sy}", Integer.to_string(shard_y))
    |> String.replace("{sz}", Integer.to_string(shard_z))
  end

  defp payload_shard_bounds(payload_layout, {shard_x, shard_y, shard_z}) do
    {origin_x, origin_y, origin_z} = payload_layout.shard_origin
    {shape_x, shape_y, shape_z} = payload_layout.shard_chunk_shape

    shard_min = {
      origin_x + shard_x * shape_x,
      origin_y + shard_y * shape_y,
      origin_z + shard_z * shape_z
    }

    shard_max = {
      elem(shard_min, 0) + shape_x - 1,
      elem(shard_min, 1) + shape_y - 1,
      elem(shard_min, 2) + shape_z - 1
    }

    {shard_min, shard_max}
  end

  defp normalize_payload_shard_coord(value) do
    case normalize_chunk_coord(value) do
      :invalid_chunk_coord -> {:error, :invalid_payload_shard_coord}
      coord -> {:ok, coord}
    end
  end

  defp validate_payload_shard_coord(grid, shard_coord) do
    if bounds_contains?(grid.shard_min, grid.shard_max, shard_coord, shard_coord) do
      :ok
    else
      {:error, %{reason: :payload_shard_out_of_bounds, shard_coord: shard_coord}}
    end
  end

  defp payload_shard_summary_in_grid(
         %__MODULE__{payload_layout: payload_layout} = index,
         grid,
         shard_coord
       ) do
    with {:ok, normalized_shard_coord} <- normalize_payload_shard_coord(shard_coord),
         :ok <- validate_payload_shard_coord(grid, normalized_shard_coord),
         {shard_min, shard_max} <- payload_shard_bounds(payload_layout, normalized_shard_coord),
         {chunk_min, chunk_max} <-
           intersection_bounds(index.chunk_min, index.chunk_max, shard_min, shard_max) do
      {:ok,
       %{
         shard_coord: normalized_shard_coord,
         path: payload_shard_path(payload_layout.file_template, normalized_shard_coord),
         chunk_min: chunk_min,
         chunk_max: chunk_max,
         chunk_count: bounds_chunk_count(chunk_min, chunk_max)
       }}
    else
      nil ->
        {:error, %{reason: :payload_shard_out_of_bounds, shard_coord: shard_coord}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_chunk_coord({x, y, z} = coord)
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: coord

  defp normalize_chunk_coord([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {x, y, z}

  defp normalize_chunk_coord(_value), do: :invalid_chunk_coord

  defp bounds_chunk_count({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    axis_count(min_x, max_x) * axis_count(min_y, max_y) * axis_count(min_z, max_z)
  end

  defp intersection_chunk_count(min_a, max_a, min_b, max_b) do
    case intersection_bounds(min_a, max_a, min_b, max_b) do
      nil -> 0
      {min_i, max_i} -> bounds_chunk_count(min_i, max_i)
    end
  end

  defp intersection_bounds(
         {min_ax, min_ay, min_az},
         {max_ax, max_ay, max_az},
         {min_bx, min_by, min_bz},
         {max_bx, max_by, max_bz}
       ) do
    min_i = {max(min_ax, min_bx), max(min_ay, min_by), max(min_az, min_bz)}
    max_i = {min(max_ax, max_bx), min(max_ay, max_by), min(max_az, max_bz)}

    if valid_bounds?(min_i, max_i), do: {min_i, max_i}
  end

  defp bounds_contains?(
         {outer_min_x, outer_min_y, outer_min_z},
         {outer_max_x, outer_max_y, outer_max_z},
         {inner_min_x, inner_min_y, inner_min_z},
         {inner_max_x, inner_max_y, inner_max_z}
       ) do
    inner_min_x >= outer_min_x and inner_min_y >= outer_min_y and inner_min_z >= outer_min_z and
      inner_max_x <= outer_max_x and inner_max_y <= outer_max_y and inner_max_z <= outer_max_z
  end

  defp axis_count(min_value, max_value), do: max_value - min_value + 1

  defp floor_div(value, divisor) when value >= 0, do: div(value, divisor)
  defp floor_div(value, divisor), do: -div(-value + divisor - 1, divisor)

  defp validate_logical_scene_id(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_logical_scene_id(_value), do: {:error, :invalid_logical_scene_id}

  defp validate_content_version(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_content_version(_value), do: {:error, :invalid_content_version}

  defp validate_region_id(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_region_id(_value), do: {:error, :invalid_region_id}

  defp validate_region_hash(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_region_hash(_value), do: {:error, :invalid_region_hash}

  defp validate_non_negative_count(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative_count(_value), do: {:error, :invalid_region_chunk_count}

  defp valid_nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp validate_bounds(chunk_min, chunk_max) do
    if valid_bounds?(chunk_min, chunk_max), do: :ok, else: {:error, :invalid_chunk_bounds}
  end

  defp valid_bounds?({min_x, min_y, min_z}, {max_x, max_y, max_z})
       when is_integer(min_x) and is_integer(min_y) and is_integer(min_z) and
              is_integer(max_x) and is_integer(max_y) and is_integer(max_z) do
    min_x <= max_x and min_y <= max_y and min_z <= max_z
  end

  defp valid_bounds?(_chunk_min, _chunk_max), do: false
end
