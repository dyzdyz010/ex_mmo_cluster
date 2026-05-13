defmodule SceneServer.Voxel.Field.FieldLayerTest do
  # Phase 6 局部场最小目标:FieldLayer 单元测试。
  #
  # 覆盖:
  #   - new/0 产出全 0.0 的 4096-cell binary
  #   - get/2 在 index 0、1、4095 等关键位置正确读取
  #   - put/3 修改指定 index 不影响其它
  #   - active_cells/2 只在 AABB 内迭代并跳过 abs(value) <= epsilon
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.FieldLayer

  describe "new/0" do
    test "returns 4096 cells of 0.0" do
      layer = FieldLayer.new()
      assert byte_size(layer.data) == 4096 * 4

      Enum.each([0, 1, 16, 257, 4095], fn idx ->
        assert FieldLayer.get(layer, idx) == 0.0
      end)
    end

    test "cell_count/0 reports 4096" do
      assert FieldLayer.cell_count() == 4096
    end
  end

  describe "get/2" do
    test "reads endpoints of the binary" do
      layer = FieldLayer.new()
      assert FieldLayer.get(layer, 0) == 0.0
      assert FieldLayer.get(layer, 4095) == 0.0
    end
  end

  describe "put/3" do
    test "writes a single cell and leaves all others untouched" do
      layer =
        FieldLayer.new()
        |> FieldLayer.put(0, 1.5)
        |> FieldLayer.put(4095, -2.25)
        |> FieldLayer.put(2048, 100.0)

      assert FieldLayer.get(layer, 0) == 1.5
      assert FieldLayer.get(layer, 4095) == -2.25
      assert FieldLayer.get(layer, 2048) == 100.0

      # Spot-check that adjacent cells are still zero.
      assert FieldLayer.get(layer, 1) == 0.0
      assert FieldLayer.get(layer, 4094) == 0.0
      assert FieldLayer.get(layer, 2047) == 0.0
      assert FieldLayer.get(layer, 2049) == 0.0
    end

    test "accepts integer value (coerced to float)" do
      layer = FieldLayer.put(FieldLayer.new(), 10, 5)
      assert FieldLayer.get(layer, 10) == 5.0
    end

    test "successive puts overwrite previous value" do
      layer =
        FieldLayer.new()
        |> FieldLayer.put(123, 7.0)
        |> FieldLayer.put(123, -3.5)

      assert FieldLayer.get(layer, 123) == -3.5
    end
  end

  describe "active_cells/2,3" do
    test "returns only non-zero cells inside AABB" do
      layer =
        FieldLayer.new()
        # inside AABB
        |> FieldLayer.put(macro_index({1, 1, 1}), 5.0)
        |> FieldLayer.put(macro_index({2, 2, 2}), -8.0)
        # outside AABB
        |> FieldLayer.put(macro_index({5, 5, 5}), 999.0)

      aabb = {{0, 0, 0}, {3, 3, 3}}
      active = FieldLayer.active_cells(layer, aabb)

      indices = Enum.map(active, &elem(&1, 0))
      assert macro_index({1, 1, 1}) in indices
      assert macro_index({2, 2, 2}) in indices
      refute macro_index({5, 5, 5}) in indices
    end

    test "skips values within epsilon" do
      layer =
        FieldLayer.new()
        # below epsilon
        |> FieldLayer.put(macro_index({0, 0, 0}), 0.00005)
        # above epsilon
        |> FieldLayer.put(macro_index({1, 1, 1}), 0.5)

      aabb = {{0, 0, 0}, {2, 2, 2}}
      active = FieldLayer.active_cells(layer, aabb, 0.0001)

      indices = Enum.map(active, &elem(&1, 0))
      refute macro_index({0, 0, 0}) in indices
      assert macro_index({1, 1, 1}) in indices
    end

    test "empty layer yields empty active list" do
      layer = FieldLayer.new()
      assert FieldLayer.active_cells(layer, {{0, 0, 0}, {3, 3, 3}}) == []
    end
  end

  defp macro_index(coord), do: SceneServer.Voxel.Types.macro_index!(coord)
end
