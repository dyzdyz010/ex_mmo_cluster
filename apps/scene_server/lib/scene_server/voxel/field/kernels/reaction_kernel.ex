defmodule SceneServer.Voxel.Field.Kernels.ReactionKernel do
  @moduledoc """
  涌现反应驱动 kernel(功能完善 · 反应层 R3)。

  把"反应层"接进现有 field tick 链:读 region AABB 内**已提交 voxel truth**(材料 +
  `effective_attribute_at "temperature"`),交 `Reaction.Engine` 按数据化规则求值,产
  `{:transform_material, ...}` 效果;由 `FieldTickWorker` 经 `SystemActor`(RULE-11/AUTH-11 桥)
  锁存落 truth。本 kernel **不读/写 field 层**(`required_layers` 仅声明 `:temperature` 依赖),
  读的是权威态——反应是物理(温度场写回 truth)的消费者,不是另一层 overlay。

  安全阀(EMG-7):每 tick 转变数受 `max_transforms_per_tick` 上限截断,防失控级联(如自维持燃烧)。
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ModelCard}
  alias SceneServer.Voxel.{MaterialCatalog, NormalBlockData, Storage, TagCatalog, Types}
  alias SceneServer.Voxel.Reaction.{Engine, Rules}

  @temperature_attribute "temperature"
  @burn_progress_attribute "burn_progress"
  # R5d:安全阀预算覆盖**每 tick 全部效果**(含辐射蔓延向量),而非仅 transform——否则失控级联的真正
  # 传播路径(辐射注热)不受约束。reaction 效果在前优先,radiation 为溢出受剩余预算截断。
  @default_max_effects_per_tick 4096
  # 燃烧蔓延的 truth 级机制:burning cell 每 tick 向相邻 solid cell 辐射热(焦耳)。现有温度扩散只动
  # field 层不动 truth,而反应读 truth——故 truth 级邻居耦合落在本 kernel(知 region 几何)。邻居受热
  # 升温达 ignition → 点燃 → 再辐射 → 级联蔓延。0 = 关辐射(仅单格燃烧生命周期)。
  @default_radiation_joules 15_000_000.0

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
        note: "每 tick **全部**反应效果(含燃烧辐射蔓延向量)总数截断,防失控级联;注热写另在 ChunkProcess clip 到温度上界"
      },
      description: "读已提交 truth(材料+温度)→ 数据化反应规则 → 材料转变 candidate,经 SystemActor 落 truth",
      assumptions: [
        "阈值瞬时相变,无潜热/延迟",
        "chunk-local AABB",
        "truth 温度/材料驱动(非 field 层)"
      ]
    )
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: storage}, opts) do
    opts = opts_map(opts)
    rules = Map.get(opts, :rules, Rules.all())
    cells = cells_in_region(region, storage)

    reaction_effects = Engine.evaluate(cells, rules)
    radiation_effects = radiation_effects(cells, region, opts)

    # R5d:预算覆盖全部效果(reaction 在前优先,radiation 溢出受剩余预算截断)——约束失控级联。
    effects = Enum.take(reaction_effects ++ radiation_effects, max_effects(opts))

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

  # 燃烧蔓延:每个 burning cell 向 region 内相邻 solid cell 辐射热(连续注入,经 SystemActor always-commit)。
  defp radiation_effects(cells, region, opts) do
    joules = radiation_joules(opts)

    if joules <= 0.0 do
      []
    else
      present = MapSet.new(cells, & &1.macro_index)

      cells
      |> Enum.filter(&burning?/1)
      |> Enum.flat_map(fn cell ->
        cell.macro_index
        |> neighbors_in_region(region)
        |> Enum.filter(&MapSet.member?(present, &1))
        |> Enum.map(&radiate_heat_effect(&1, joules))
      end)
    end
  end

  defp radiation_joules(opts) do
    case Map.get(opts, :radiation_joules, @default_radiation_joules) do
      n when is_number(n) and n >= 0 -> n * 1.0
      _other -> @default_radiation_joules
    end
  end

  defp burning?(cell), do: :burning in Map.get(cell, :tags, [])

  defp radiate_heat_effect(macro_index, joules) do
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
