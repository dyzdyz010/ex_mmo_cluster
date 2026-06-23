defmodule SceneServer.Voxel.Field.Kernels.StructuralStressKernelTest do
  @moduledoc """
  力学应力 kernel 单测:失支撑 → :collapse_block 效果;坐地 → :done;安全阀封顶。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ModelCard}
  alias SceneServer.Voxel.Field.Kernels.StructuralStressKernel

  @stone 2
  @iron 5

  @full_aabb {{0, 0, 0}, {15, 15, 15}}

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp idx(coord), do: Types.macro_index!(coord)

  defp region(aabb \\ @full_aabb) do
    FieldRegion.new(%{
      region_id: 901,
      chunk_coord: {0, 0, 0},
      aabb: aabb,
      kernels: [%{id: :structural_stress, module: StructuralStressKernel}]
    })
  end

  defp tick(storage, region, opts \\ %{}) do
    context = KernelContext.new(region, 7, storage, dt_ms: 100)
    StructuralStressKernel.tick(region, context, opts)
  end

  defp collapse_indices(effects) do
    effects
    |> Enum.map(fn {:collapse_block, %{macro_index: idx}} -> idx end)
    |> Enum.sort()
  end

  test "自描述:kernel_id / 无 field 层 / 模型卡有效" do
    assert StructuralStressKernel.kernel_id() == :structural_stress
    assert StructuralStressKernel.required_layers(%{}) == []

    card = StructuralStressKernel.model_card()
    assert %ModelCard{} = card
    assert card.kernel_id == :structural_stress
    assert card.safety_valve.type == :max_effects_per_tick
  end

  test "坐地结构:全部有支撑 → :done,无效果" do
    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({0, 1, 0}, @stone)
      |> put_solid({0, 2, 0}, @iron)

    assert {:done, _region, []} = tick(storage, region())
  end

  test "悬空块:失支撑 → :cont + 一条 :collapse_block 效果(带 source)" do
    storage = put_solid(Storage.new(7, {0, 0, 0}), {3, 5, 3}, @iron)

    assert {:cont, _region, effects} = tick(storage, region())

    assert [{:collapse_block, attrs}] = effects
    assert attrs.macro_index == idx({3, 5, 3})
    assert attrs.source == :structural_collapse
  end

  test "浮岛 + 地锚列:仅浮岛 cell 发坍塌,地锚列不发" do
    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({0, 1, 0}, @stone)
      |> put_solid({6, 3, 6}, @iron)
      |> put_solid({6, 4, 6}, @iron)

    assert {:cont, _region, effects} = tick(storage, region())
    assert collapse_indices(effects) == Enum.sort([idx({6, 3, 6}), idx({6, 4, 6})])
  end

  test "安全阀:max_effects_per_tick 封顶单 tick 坍塌数" do
    # 5 个互不相邻的悬空块,全失支撑。
    floating = [{2, 5, 2}, {4, 5, 4}, {6, 5, 6}, {8, 5, 8}, {10, 5, 10}]

    storage =
      Enum.reduce(floating, Storage.new(7, {0, 0, 0}), fn coord, acc ->
        put_solid(acc, coord, @iron)
      end)

    assert {:cont, _region, effects} = tick(storage, region(), %{max_effects_per_tick: 2})
    assert length(effects) == 2
  end

  test "无 storage:安全 :done" do
    assert {:done, _region, []} = tick(nil, region())
  end
end
