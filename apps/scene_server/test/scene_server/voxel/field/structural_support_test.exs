defmodule SceneServer.Voxel.Field.StructuralSupportTest do
  @moduledoc """
  力学应力 · 纯结构支撑分析单测(chunk-local)。

  覆盖:坐地塔存活、悬空块失支撑、连地塔存活、浮岛失支撑、流体不承重、
  连地悬臂(v1 连通即支撑)。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.StructuralSupport

  @stone 2
  @iron 5
  @water 8

  # 整个 chunk 的 AABB(含地锚层 y=0)。
  @full_aabb {{0, 0, 0}, {15, 15, 15}}

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp idx(coord), do: Types.macro_index!(coord)

  defp new_storage, do: Storage.new(7, {0, 0, 0})

  test "坐地塔:从 y=0 起的实心结构列全部有支撑 → []" do
    storage =
      new_storage()
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({0, 1, 0}, @stone)
      |> put_solid({0, 2, 0}, @iron)

    assert StructuralSupport.unsupported_cells(storage, @full_aabb) == []
  end

  test "悬空块:无地锚的单块结构失支撑 → [自身]" do
    storage = put_solid(new_storage(), {3, 5, 3}, @iron)

    assert StructuralSupport.unsupported_cells(storage, @full_aabb) == [idx({3, 5, 3})]
  end

  test "连地高塔:逐层面相邻连到地锚 → 全部存活 []" do
    storage =
      Enum.reduce(0..6, new_storage(), fn y, acc ->
        put_solid(acc, {2, y, 2}, @stone)
      end)

    assert StructuralSupport.unsupported_cells(storage, @full_aabb) == []
  end

  test "浮岛:与地锚列断开的另一块结构失支撑,地锚列存活" do
    storage =
      new_storage()
      # 地锚列(x=0)
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({0, 1, 0}, @stone)
      # 远处悬空浮岛(x=6,与地锚列不面相邻)
      |> put_solid({6, 3, 6}, @iron)
      |> put_solid({6, 4, 6}, @iron)

    unsupported = StructuralSupport.unsupported_cells(storage, @full_aabb)

    assert Enum.sort(unsupported) == Enum.sort([idx({6, 3, 6}), idx({6, 4, 6})])
  end

  test "流体不承重:water 在 y=0、iron 在 y=1,iron 无结构地锚 → iron 失支撑" do
    storage =
      new_storage()
      |> put_solid({4, 0, 4}, @water)
      |> put_solid({4, 1, 4}, @iron)

    # water 非结构(structural=0)→ 既不是地锚也不传力;iron 唯一向下邻居是 water,失支撑。
    assert StructuralSupport.unsupported_cells(storage, @full_aabb) == [idx({4, 1, 4})]
  end

  test "连地悬臂:横臂经面相邻连回地锚 → v1 连通即支撑,全部存活" do
    storage =
      new_storage()
      # 立柱
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({0, 1, 0}, @stone)
      # 横臂(y=1 上向 +x 伸出)
      |> put_solid({1, 1, 0}, @stone)
      |> put_solid({2, 1, 0}, @iron)

    assert StructuralSupport.unsupported_cells(storage, @full_aabb) == []
  end

  test "AABB 之外的块不参与分析" do
    storage =
      new_storage()
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({10, 5, 10}, @iron)

    # 仅扫一个不含 (10,5,10) 的局部 AABB。
    local_aabb = {{0, 0, 0}, {3, 3, 3}}

    assert StructuralSupport.unsupported_cells(storage, local_aabb) == []
  end
end
