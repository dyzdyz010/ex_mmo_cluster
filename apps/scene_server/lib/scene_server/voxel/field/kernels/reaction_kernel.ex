defmodule SceneServer.Voxel.Field.Kernels.ReactionKernel do
  @moduledoc """
  涌现反应驱动 kernel(功能完善 · 反应层 R3)。

  把"反应层"接进现有 field tick 链:读 region AABB 内**已提交 voxel truth**(材料 +
  `effective_attribute_at "temperature"`),交 `Reaction.Engine` 按数据化规则求值,产
  `{:transform_material, ...}` 效果;由 `FieldTickWorker` 经 `SystemActor`(RULE-11/AUTH-11 桥)
  锁存落 truth。本 kernel **不读/写 field 层**(`required_layers` 仅声明 `:temperature` 依赖),
  读的是权威态——反应是物理(温度场写回 truth)的消费者,不是另一层 overlay。

  ## truth 级邻居热扩散(R6c,守恒 Fourier)
  现有温度扩散只动 field 层不动 truth,而反应读 truth——故 truth 级跨格热传播落在本 kernel(知 region
  几何)。每 tick 对每对相邻 solid cell 按温差传热:`Q = rate × ΔT / (1/C_hot + 1/C_cold)`(C = 密度 ×
  比热 × 体积),**源放热 = 冷端得热(能量守恒)**;rate<1 保不过冲、自限平衡(ΔT→0 停)。这使:
  (a) 任意热源(电加热的铁/岩浆)烤燃/熔化相邻物 → 电→火、热→火;(b) 燃烧 cell 自加热很烫 → 自然扩散
  点燃邻居(**统一取代** R5c 临时的"flat 辐射")。

  安全阀(EMG-7):每 tick 全部效果数受 `max_effects_per_tick` 截断,防失控级联(注热另在 ChunkProcess
  clip 到温度上界)。
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ModelCard}
  alias SceneServer.Voxel.{MaterialCatalog, NormalBlockData, Storage, TagCatalog, Types}
  alias SceneServer.Voxel.Reaction.{Engine, Rules}

  @temperature_attribute "temperature"
  @burn_progress_attribute "burn_progress"
  @density_attribute "density"
  @specific_heat_attribute "specific_heat_capacity"
  # R5d:安全阀预算覆盖**每 tick 全部效果**(含热扩散),而非仅 transform——否则失控级联真正传播路径不受约束。
  @default_max_effects_per_tick 4096
  # R6c 守恒 Fourier 热扩散参数。rate = 每 tick 传 ΔT/(1/C_h+1/C_c) 的比例(<1 自限不过冲)。
  @default_diffusion_rate 0.25
  @voxel_volume_cubic_meter 1.0
  @min_heat_capacity 1.0
  # 噪声地板:净传热 < 此(焦耳)不发效果,避免每 tick 海量微小写。
  @min_transfer_joules 1_000.0

  @impl true
  def kernel_id, do: :reaction

  @impl true
  def required_layers(_opts), do: [:temperature]

  @impl true
  def model_card do
    ModelCard.new!(
      kernel_id: :reaction,
      fidelity_class: :qualitative,
      model_version: 1,
      safety_valve: %{
        type: :reaction_budget,
        max_effects_per_tick: @default_max_effects_per_tick,
        note: "每 tick 全部效果(含守恒热扩散)总数截断,防失控级联;注热写另在 ChunkProcess clip 到温度上界"
      },
      description:
        "读已提交 truth(材料+温度+tag)→ 数据化反应规则 + 守恒 Fourier 邻居热扩散 → candidate,经 SystemActor 落 truth",
      assumptions: [
        "阈值瞬时相变,无潜热/延迟",
        "chunk-local AABB",
        "truth 温度/材料驱动(非 field 层)",
        "热扩散显式 Fourier(rate<1 自限,守恒)"
      ]
    )
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: storage}, opts) do
    opts = opts_map(opts)
    rules = Map.get(opts, :rules, Rules.all())
    cells = cells_in_region(region, storage)

    reaction_effects = Engine.evaluate(cells, rules)
    diffusion_effects = heat_diffusion_effects(cells, region, opts)

    # R5d:预算覆盖全部效果(reaction 在前优先,热扩散溢出受剩余预算截断)——约束失控级联。
    effects = Enum.take(reaction_effects ++ diffusion_effects, max_effects(opts))

    {:cont, region, effects}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}

  defp max_effects(opts) do
    case Map.get(opts, :max_effects_per_tick, @default_max_effects_per_tick) do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_max_effects_per_tick
    end
  end

  # R6c 守恒 Fourier 热扩散:对每对相邻 solid cell 按温差传热,源放热=冷端得热(能量守恒)。
  # 每 cell 净焦耳(可正可负)汇总成一条连续注热效果(经 SystemActor always-commit + ChunkProcess clip)。
  defp heat_diffusion_effects(cells, region, opts) do
    rate = diffusion_rate(opts)

    if rate <= 0.0 do
      []
    else
      by_index = Map.new(cells, &{&1.macro_index, &1})
      present = MapSet.new(cells, & &1.macro_index)

      cells
      |> Enum.reduce(%{}, fn cell, acc ->
        cell.macro_index
        |> neighbors_in_region(region)
        # 每无序对只处理一次(邻居 index > 本 cell);邻居须在 region 内 solid。
        |> Enum.filter(fn n -> n > cell.macro_index and MapSet.member?(present, n) end)
        |> Enum.reduce(acc, fn n_index, acc2 ->
          accumulate_transfer(acc2, cell, Map.fetch!(by_index, n_index), rate)
        end)
      end)
      |> Enum.filter(fn {_idx, q} -> abs(q) >= @min_transfer_joules end)
      |> Enum.map(fn {idx, q} -> heat_effect(idx, q) end)
    end
  end

  defp accumulate_transfer(acc, a, b, rate) do
    {hot, cold} = if a.temperature_celsius >= b.temperature_celsius, do: {a, b}, else: {b, a}
    dt = hot.temperature_celsius - cold.temperature_celsius
    q = rate * dt / (1.0 / hot.heat_capacity + 1.0 / cold.heat_capacity)

    if q > 0.0 do
      acc
      |> Map.update(hot.macro_index, -q, &(&1 - q))
      |> Map.update(cold.macro_index, q, &(&1 + q))
    else
      acc
    end
  end

  defp diffusion_rate(opts) do
    case Map.get(opts, :diffusion_rate, @default_diffusion_rate) do
      n when is_number(n) and n >= 0 -> n * 1.0
      _other -> @default_diffusion_rate
    end
  end

  defp heat_effect(macro_index, joules) do
    {:write_voxel_attribute,
     %{attribute: :temperature, macro_index: macro_index, heat_energy_joules: joules}}
  end

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

  defp cells_in_region(_region, nil), do: []

  defp cells_in_region(
         %FieldRegion{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}},
         %Storage{} = storage
       ) do
    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        cell = cell_state(storage, {x, y, z}),
        cell != nil do
      cell
    end
  end

  defp cells_in_region(_region, _storage), do: []

  defp cell_state(storage, coord) do
    macro_index = Types.macro_index!(coord)

    case Storage.normal_block_at(storage, macro_index) do
      %NormalBlockData{material_id: material_id} = block ->
        %{
          macro_index: macro_index,
          material_id: material_id,
          temperature_celsius: scaled_attribute(storage, macro_index, @temperature_attribute),
          burn_progress: scaled_attribute(storage, macro_index, @burn_progress_attribute),
          heat_capacity: heat_capacity(storage, macro_index),
          tags: cell_tags(storage, block)
        }

      _other ->
        nil
    end
  end

  defp scaled_attribute(storage, macro_index, attr_name) do
    raw = Storage.effective_attribute_at(storage, macro_index, attr_name)
    raw / MaterialCatalog.fixed32_scale()
  end

  # 热容 C = 密度 × 比热 × 体积(J/K);热扩散用。
  defp heat_capacity(storage, macro_index) do
    density = scaled_attribute(storage, macro_index, @density_attribute)
    specific_heat = scaled_attribute(storage, macro_index, @specific_heat_attribute)
    max(density * specific_heat * @voxel_volume_cubic_meter, @min_heat_capacity)
  end

  # per-cell 动态 tag id → atom 名(规则用 atom 名;tag 已在 catalog 定义,to_existing_atom 安全)。
  defp cell_tags(storage, %NormalBlockData{tag_set_ref: ref}) do
    storage
    |> tag_ids(ref)
    |> Enum.map(&tag_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tag_ids(_storage, ref) when ref in [0, nil], do: []

  defp tag_ids(storage, ref) when is_integer(ref) and ref > 0 do
    case Enum.at(storage.tag_sets, ref - 1) do
      %{tag_ids: ids} -> ids
      _other -> []
    end
  end

  defp tag_ids(_storage, _ref), do: []

  defp tag_name(id) do
    case TagCatalog.lookup_by_id(id) do
      {:ok, %{name: name}} -> safe_existing_atom(name)
      _other -> nil
    end
  end

  defp safe_existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
