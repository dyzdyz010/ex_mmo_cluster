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
  alias SceneServer.Voxel.{MaterialCatalog, NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Reaction.{Engine, Rules}

  @temperature_attribute "temperature"
  @default_max_transforms_per_tick 4096

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
        max_transforms_per_tick: @default_max_transforms_per_tick,
        note: "每 tick 转变数截断,防失控级联涌现"
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
    budget = max_transforms(opts)

    effects =
      region
      |> cells_in_region(storage)
      |> Engine.evaluate(rules)
      |> Enum.take(budget)

    {:cont, region, effects}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}

  defp max_transforms(opts) do
    case Map.get(opts, :max_transforms_per_tick, @default_max_transforms_per_tick) do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_max_transforms_per_tick
    end
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
      %NormalBlockData{material_id: material_id} ->
        %{
          macro_index: macro_index,
          material_id: material_id,
          temperature_celsius: temperature_celsius(storage, macro_index),
          tags: []
        }

      _other ->
        nil
    end
  end

  defp temperature_celsius(storage, macro_index) do
    raw = Storage.effective_attribute_at(storage, macro_index, @temperature_attribute)
    raw / MaterialCatalog.fixed32_scale()
  end
end
