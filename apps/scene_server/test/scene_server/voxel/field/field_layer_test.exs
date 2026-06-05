defmodule SceneServer.Voxel.Field.FieldLayerTest do
  # Phase 6 局部场最小目标:FieldLayer 单元测试。
  #
  # 覆盖:
  #   - new/0 产出 baseline 0.0 的空稀疏层
  #   - new/1 可配置环境 baseline / 整数化 / 异常阈值
  #   - put/3 修改指定 index 不影响其它
  #   - active_cells/2 只返回 AABB 内偏离 baseline 的异常 cell
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.FieldLayer

  describe "new/0" do
    test "returns an empty sparse layer with baseline 0.0" do
      layer = FieldLayer.new()

      Enum.each([0, 1, 16, 257, 4095], fn idx ->
        assert FieldLayer.get(layer, idx) == 0.0
        assert FieldLayer.get_delta(layer, idx) == 0.0
      end)

      assert FieldLayer.active_cells(layer, {{0, 0, 0}, {15, 15, 15}}) == []
    end

    test "cell_count/0 reports 4096" do
      assert FieldLayer.cell_count() == 4096
    end
  end

  describe "new/1" do
    test "temperature-style layers keep baseline cells out of active cells" do
      idx = macro_index({1, 1, 1})

      layer =
        FieldLayer.new(baseline: 20, quantization: :integer, threshold: 1)
        |> FieldLayer.put(idx, 20.4)

      assert FieldLayer.get(layer, idx) == 20
      assert FieldLayer.get_delta(layer, idx) == 0
      assert FieldLayer.active_cells(layer, {{0, 0, 0}, {3, 3, 3}}) == []
    end

    test "temperature-style layers store integer deviations from baseline" do
      idx = macro_index({1, 1, 1})

      layer =
        FieldLayer.new(baseline: 20, quantization: :integer, threshold: 1)
        |> FieldLayer.put(idx, 42.6)

      assert FieldLayer.get(layer, idx) == 43
      assert FieldLayer.get_delta(layer, idx) == 23
      assert FieldLayer.active_cells(layer, {{0, 0, 0}, {3, 3, 3}}) == [{idx, 43}]
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

  describe "clear_in_aabb/2" do
    test "drops deltas inside the AABB and keeps those outside" do
      inside1 = macro_index({1, 1, 1})
      inside2 = macro_index({3, 3, 3})
      outside = macro_index({5, 5, 5})

      layer =
        FieldLayer.new()
        |> FieldLayer.put(inside1, 5.0)
        |> FieldLayer.put(inside2, -8.0)
        |> FieldLayer.put(outside, 999.0)

      cleared = FieldLayer.clear_in_aabb(layer, {{0, 0, 0}, {3, 3, 3}})

      assert FieldLayer.get(cleared, inside1) == 0.0
      assert FieldLayer.get(cleared, inside2) == 0.0
      assert FieldLayer.get(cleared, outside) == 999.0

      # Sparse semantics: cleared cells are *removed* from values, not stored as 0 deltas.
      refute Map.has_key?(cleared.values, inside1)
      refute Map.has_key?(cleared.values, inside2)
      assert Map.has_key?(cleared.values, outside)
    end

    test "full-chunk clear is equivalent to per-cell put(0.0) on a baseline-0 layer" do
      indices = [macro_index({0, 0, 0}), macro_index({2, 1, 0}), macro_index({7, 8, 9}), macro_index({15, 15, 15})]
      layer = Enum.reduce(indices, FieldLayer.new(), fn idx, acc -> FieldLayer.put(acc, idx, idx + 1.0) end)
      aabb = {{0, 0, 0}, {15, 15, 15}}

      via_api = FieldLayer.clear_in_aabb(layer, aabb)

      via_per_cell =
        for(x <- 0..15, y <- 0..15, z <- 0..15, do: macro_index({x, y, z}))
        |> Enum.reduce(layer, fn idx, acc -> FieldLayer.put(acc, idx, 0.0) end)

      assert via_api.values == via_per_cell.values
      assert via_api.values == %{}
    end

    test "sub-AABB clear matches per-cell put(0.0) over that sub-AABB" do
      indices = [macro_index({1, 1, 1}), macro_index({2, 2, 2}), macro_index({5, 5, 5}), macro_index({0, 3, 1})]
      layer = Enum.reduce(indices, FieldLayer.new(), fn idx, acc -> FieldLayer.put(acc, idx, 3.0) end)
      aabb = {{0, 0, 0}, {3, 3, 3}}

      via_api = FieldLayer.clear_in_aabb(layer, aabb)

      via_per_cell =
        for(x <- 0..3, y <- 0..3, z <- 0..3, do: macro_index({x, y, z}))
        |> Enum.reduce(layer, fn idx, acc -> FieldLayer.put(acc, idx, 0.0) end)

      assert via_api.values == via_per_cell.values
      # outside cell survives
      assert FieldLayer.get(via_api, macro_index({5, 5, 5})) == 3.0
    end

    test "resets cells back to baseline for a non-zero-baseline layer" do
      idx = macro_index({1, 1, 1})

      layer =
        FieldLayer.new(baseline: 20, quantization: :integer, threshold: 1)
        |> FieldLayer.put(idx, 42.0)

      cleared = FieldLayer.clear_in_aabb(layer, {{0, 0, 0}, {3, 3, 3}})

      assert FieldLayer.get(cleared, idx) == 20
      refute Map.has_key?(cleared.values, idx)
    end

    test "empty layer stays empty" do
      layer = FieldLayer.new()
      assert FieldLayer.clear_in_aabb(layer, {{0, 0, 0}, {15, 15, 15}}).values == %{}
    end

    test "on a non-zero-baseline layer, clear (reset to baseline) differs from per-cell put(0.0)" do
      # 固化设计意图:clear_in_aabb 是"重置回 baseline",不是"写绝对 0"。当前无 baseline≠0
      # 的活跃调用点,但此负向测试防止未来有人把它当作 put(0.0) 的同义词复用。
      idx = macro_index({1, 1, 1})
      base = FieldLayer.new(baseline: 20, quantization: :integer, threshold: 1) |> FieldLayer.put(idx, 42.0)
      aabb = {{0, 0, 0}, {3, 3, 3}}

      via_clear = FieldLayer.clear_in_aabb(base, aabb)

      via_put0 =
        for(x <- 0..3, y <- 0..3, z <- 0..3, do: macro_index({x, y, z}))
        |> Enum.reduce(base, fn i, acc -> FieldLayer.put(acc, i, 0.0) end)

      assert FieldLayer.get(via_clear, idx) == 20
      assert FieldLayer.get(via_put0, idx) == 0
      refute via_clear.values == via_put0.values
    end
  end

  defp macro_index(coord), do: SceneServer.Voxel.Types.macro_index!(coord)
end
