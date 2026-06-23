defmodule SceneServer.Voxel.Field.Kernels.LightPropagationKernel do
  @moduledoc """
  光传播 kernel(光学正交系统,2026-06-23)。读 region AABB 内已提交 truth(材料 `light_emission`
  + `opacity`,以及 `temperature` 派生热致发光),交纯 `LightPropagation` flood,把权威 `:light`
  场层写回 region。

  ## 光源(属性派生,非白名单)

  单 cell 发射强度 = `max(emission_light, thermal_light)`,皆物理态派生:
    * `emission_light` —— 材料 `light_emission`(W)线性映射到 0..255(`@emission_full_w` → 满 255)。
      灯/余烬等自发光材料。
    * `thermal_light` —— 温度过 Draper 点(~525℃)的热致白炽,(T-Draper)/(white_hot-Draper) → 0..255。
      统一「金属高温发光」(电加热铁、岩浆、燃烧物因热发光)。

  ## 输出

  **只写 `:light` 场层,不动 truth**(同温度场层的 observe/wire 角色)。`光成真机制`经反应:
  ReactionKernel 同 tick(排其后)读 `:light` 层 gate 光敏反应,产 `:illuminated` tag 落 truth——
  故本 kernel emit **零** effect。**kernel 顺序硬约束:LightPropagationKernel 必须排在
  ReactionKernel 之前**(同 tick region 线程,光层先写后读)。

  ## 形式属性

  见 model_card assumptions(单调衰减/确定性/有界/遮挡),由 `LightPropagation` 纯核 +
  `light_propagation_test`(形式属性 200 例)守。本 kernel 只做 truth→源/opacity 投影 + 场层写回。
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{
    FieldLayer,
    FieldRegion,
    KernelContext,
    LightPropagation,
    ModelCard
  }

  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

  @fixed32_scale 65_536.0

  # 发光/温度 → 0..255 光强映射。
  @max_light 255.0
  # light_emission(W)达此即满亮 255(ember = 1500 W)。
  @emission_full_w 1_500.0
  # 固体可见发光起点(热致白炽 Draper 点)。
  @draper_celsius 525.0
  # 热致满白。
  @white_hot_celsius 2_200.0

  # 传播参数(可经 opts 覆盖)。
  @default_attenuation 0.7
  @default_threshold 1.0
  @default_max_frontier 4096

  @impl true
  def kernel_id, do: :light_propagation

  @impl true
  def required_layers(_opts), do: [:light, :light_color]

  # 彩色光:无光源默认白(packed RGB888 0xFFFFFF)。
  @default_light_color 0xFFFFFF

  @impl true
  def model_card do
    ModelCard.new!(
      kernel_id: :light_propagation,
      fidelity_class: :qualitative,
      model_version: 1,
      safety_valve: %{
        type: :flood_budget,
        max_frontier: @default_max_frontier,
        note: "最亮优先 BFS flood settled cell 数熔断,防失控扩散"
      },
      description:
        "发光源(light_emission + 热致 ≥Draper)flood 成权威 :light 场层,opacity 衰减/遮挡;纯传播只写场层不动 truth",
      assumptions: [
        "单调衰减:光强随离源距离非增(无凭空增亮)",
        "确定性:给定源集 + opacity 场逐字节确定(无随机/时钟)",
        "有界:光强 ∈ [threshold, 255]",
        "遮挡:全不透明 cell onward=0 → 墙后暗(墙受光面亮)",
        "辐射定性档(非守恒光子计数);chunk-local AABB"
      ]
    )
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: storage}, opts) when is_map(opts) do
    sources_by_color = light_sources_by_color(region, storage)
    opacity = opacity_map(region, storage)
    neighbors_fn = fn macro_index -> neighbors_in_region(macro_index, region) end

    flood_opts = [
      attenuation: attenuation(opts),
      threshold: threshold(opts),
      max_frontier: max_frontier(opts)
    ]

    # 彩色光:按源颜色分组各 flood,再逐 cell 取最亮组(强度 = 全源 max,与单次合并 flood 等价;
    # 颜色 = 最亮组的颜色)。intensity 输出与无色版逐字节相同,颜色为附加层。
    combined =
      Enum.reduce(sources_by_color, %{}, fn {color, sources}, acc ->
        light = LightPropagation.flood(sources, opacity, neighbors_fn, flood_opts)

        Enum.reduce(light, acc, fn {idx, intensity}, acc2 ->
          case Map.get(acc2, idx) do
            {prev_i, _prev_c} when prev_i >= intensity -> acc2
            _ -> Map.put(acc2, idx, {intensity, color})
          end
        end)
      end)

    {:cont, write_light_layers(region, combined), []}
  end

  def tick(%FieldRegion{} = region, _context, _opts), do: {:cont, region, []}

  # ---- 光源 / opacity 投影(读已提交 truth) ----

  # 彩色光:光源按颜色分组 %{packed_rgb => %{idx => intensity}}(各组独立 flood 后逐 cell 取最亮组)。
  defp light_sources_by_color(region, %Storage{} = storage) do
    region
    |> region_solid_cells(storage)
    |> Enum.reduce(%{}, fn macro_index, acc ->
      case source_intensity(storage, macro_index) do
        intensity when intensity > 0.0 ->
          color = source_color(storage, macro_index)

          Map.update(acc, color, %{macro_index => intensity}, fn group ->
            Map.put(group, macro_index, intensity)
          end)

        _zero ->
          acc
      end
    end)
  end

  defp light_sources_by_color(_region, _storage), do: %{}

  # 源颜色 packed RGB888(default 白)。读 raw 整数(非定点缩放)。
  defp source_color(storage, macro_index) do
    raw =
      Storage.effective_attribute_at_normalized(storage, macro_index, "light_color")

    color = round(raw)

    if color >= 0 and color <= 0xFFFFFF, do: color, else: @default_light_color
  rescue
    _ -> @default_light_color
  end

  defp source_intensity(storage, macro_index) do
    emission_w = scaled_attribute(storage, macro_index, "light_emission", 0.0)
    temp_c = scaled_attribute(storage, macro_index, "temperature", 0.0)

    emission_light = clamp(0.0, @max_light, emission_w / @emission_full_w * @max_light)
    max(emission_light, thermal_light(temp_c))
  end

  defp thermal_light(temp_c) when is_number(temp_c) do
    if temp_c >= @draper_celsius do
      clamp(
        0.0,
        @max_light,
        (temp_c - @draper_celsius) / (@white_hot_celsius - @draper_celsius) * @max_light
      )
    else
      0.0
    end
  end

  defp thermal_light(_temp_c), do: 0.0

  defp opacity_map(region, %Storage{} = storage) do
    region
    |> region_solid_cells(storage)
    |> Map.new(fn macro_index ->
      {macro_index, clamp(0.0, 1.0, scaled_attribute(storage, macro_index, "opacity", 1.0))}
    end)
  end

  defp opacity_map(_region, _storage), do: %{}

  # region AABB 内的实心 macro cell(光源/opacity 只取实心;空 cell 透明由传播缺省 opacity 0 处理)。
  defp region_solid_cells(
         %FieldRegion{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}},
         %Storage{} = storage
       ) do
    # 性能:tuple 化 headers,逐 cell O(1) 判实心(否则 normal_block_at 的 Enum.at O(idx)
    # 扫 AABB 跑成 O(n²)——空 cell 占多数时尤甚)。
    storage = Storage.normalize!(storage)
    headers = Storage.index_macro_headers(storage)

    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        macro_index = Types.macro_index!({x, y, z}),
        match?(
          %NormalBlockData{},
          Storage.normal_block_with_header(storage, Storage.header_at_index(headers, macro_index))
        ),
        do: macro_index
  end

  defp region_solid_cells(_region, _storage), do: []

  # 六向邻居(region AABB 内;含空 cell——光穿空气传播)。
  defp neighbors_in_region(
         macro_index,
         %FieldRegion{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}}
       ) do
    {x, y, z} = Types.macro_coord!(macro_index)

    [
      {x + 1, y, z},
      {x - 1, y, z},
      {x, y + 1, z},
      {x, y - 1, z},
      {x, y, z + 1},
      {x, y, z - 1}
    ]
    |> Enum.filter(fn {nx, ny, nz} ->
      nx in min_x..max_x and ny in min_y..max_y and nz in min_z..max_z
    end)
    |> Enum.map(&Types.macro_index!/1)
  end

  # ---- 场层写回 ----

  # 写 :light(强度)+ :light_color(packed RGB,存为 float,≤2^24 精确)。combined = %{idx => {i, color}}。
  defp write_light_layers(region, combined) do
    intensity_layer =
      region |> FieldRegion.get_layer(:light) |> clear_layer_in_aabb(region.aabb)

    color_layer =
      region |> FieldRegion.get_layer(:light_color) |> clear_layer_in_aabb(region.aabb)

    {intensity_layer, color_layer} =
      Enum.reduce(combined, {intensity_layer, color_layer}, fn {idx, {intensity, color}},
                                                               {i_acc, c_acc} ->
        {FieldLayer.put(i_acc, idx, intensity), FieldLayer.put(c_acc, idx, color * 1.0)}
      end)

    region
    |> FieldRegion.put_layer(:light, intensity_layer)
    |> FieldRegion.put_layer(:light_color, color_layer)
  end

  defp clear_layer_in_aabb(layer, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z})
    |> Enum.reduce(layer, fn coord, acc ->
      FieldLayer.put(acc, Types.macro_index!(coord), 0.0)
    end)
  end

  # ---- helpers ----

  defp scaled_attribute(storage, macro_index, attr_name, fallback) do
    storage
    |> Storage.effective_attribute_at_normalized(macro_index, attr_name)
    |> Kernel./(@fixed32_scale)
  rescue
    _ -> fallback * 1.0
  end

  defp attenuation(opts), do: float_opt(opts, :attenuation, @default_attenuation)
  defp threshold(opts), do: float_opt(opts, :threshold, @default_threshold)

  defp max_frontier(opts) do
    case Map.get(opts, :max_frontier, @default_max_frontier) do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_max_frontier
    end
  end

  defp float_opt(opts, key, default) do
    case Map.get(opts, key, default) do
      v when is_number(v) -> v * 1.0
      _other -> default
    end
  end

  defp clamp(lo, _hi, x) when x < lo, do: lo
  defp clamp(_lo, hi, x) when x > hi, do: hi
  defp clamp(_lo, _hi, x), do: x * 1.0
end
