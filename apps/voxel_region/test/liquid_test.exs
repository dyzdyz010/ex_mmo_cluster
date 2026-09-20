defmodule VoxelRegion.LiquidTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.Liquid

  # Test-only：正式目录的 4096 量子/微格，8³ 微格/宏格；核只接受调用方给出的容量。
  @capacity 4096 * 8 * 8 * 8

  defp total(water), do: water |> Map.values() |> Enum.sum()

  test "建造排液按六面容量全量规划，封闭 XYZ 边界不足则不产生部分结果" do
    cell = {63, 1, 2}
    water = %{cell => 10, {63, 0, 2} => 7}
    bounds = {{63, 0, 2}, {65, 3, 3}}
    assert {:ok, changes, flows} = Liquid.displace(water, cell, 10, bounds, fn _ -> true end)
    assert changes == %{cell => 0, {63, 0, 2} => 10, {64, 1, 2} => 7}
    assert Enum.sum(Map.values(Liquid.apply_changes(water, changes))) == 17
    assert Enum.sum(Enum.map(flows, &elem(&1, 2))) == 10
    values = VoxelRegion.Phase.transport(%{cell => {70.0, 5.0}, {63,0,2} => {14.0, 7.0}}, water, flows)
    assert values[cell] == {0.0, 0.0}
    assert values[{63,0,2}] == {35.0, 8.5}
    assert values[{64,1,2}] == {49.0, 3.5}
    assert {:error, :occupied} = Liquid.displace(water, cell, 10, bounds, &(&1 == {63, 0, 2}))
    assert {:ok, %{^cell => 0, {63, 2, 2} => 10}, _} =
      Liquid.displace(%{cell => 10}, cell, 10, bounds, &(&1 == {63, 2, 2}))
  end
  defp advance(water, bounds, open?, gravity \\ @capacity, side \\ @capacity) do
    Liquid.apply_changes(water, Liquid.step(water, bounds, @capacity, gravity, side, open?))
  end

  test "同步重力一格一步，有限容量接收，不沿遍历顺序瞬间落到底" do
    bounds = {{0, 0, 0}, {1, 4, 1}}
    before = %{{0, 3, 0} => @capacity}
    first = advance(before, bounds, fn _ -> true end)
    assert first == %{{0, 2, 0} => @capacity}
    second = advance(first, bounds, fn _ -> true end)
    assert second == %{{0, 1, 0} => @capacity}
    partial = %{{0, 1, 0} => @capacity, {0, 0, 0} => @capacity - 37}
    assert advance(partial, bounds, fn _ -> true end) == %{{0, 1, 0} => @capacity - 37, {0, 0, 0} => @capacity}
    assert advance(before, bounds, fn _ -> true end, 19, 0) == %{{0, 3, 0} => @capacity - 19, {0, 2, 0} => 19}
  end

  test "重力优先，四向同步平衡保持对称和微小余量" do
    bounds = {{-3, 0, -3}, {4, 2, 4}}
    before = %{{0, 1, 0} => @capacity}
    after_step = advance(before, bounds, fn _ -> true end)
    assert Map.get(after_step, {0, 1, 0}, 0) == 0
    assert after_step[{0, 0, 0}] == div(@capacity, 2)
    for cell <- [{-1, 0, 0}, {1, 0, 0}, {0, 0, -1}, {0, 0, 1}],
      do: assert(after_step[cell] == div(@capacity, 8))
    assert total(after_step) == @capacity
    dust = %{{0, 0, 0} => 1}
    assert advance(dust, bounds, fn _ -> true end) == dust
  end

  test "实体容器保水，地板破损后泄漏但总量守恒" do
    bounds = {{-1, -2, -1}, {4, 3, 4}}
    basin = fn {x, y, z} -> x in 0..2 and z in 0..2 and y in 1..2 end
    closed = Enum.reduce(1..12, %{{1, 1, 1} => @capacity}, fn _, water -> advance(water, bounds, basin) end)
    assert Enum.all?(closed, fn {{_, y, _}, _} -> y == 1 end)
    assert total(closed) == @capacity
    broken = fn {_, y, _} = p -> basin.(p) or p == {1, 0, 1} or y < 0 end
    leaked = Enum.reduce(1..8, closed, fn _, water -> advance(water, bounds, broken) end)
    assert Enum.any?(leaked, fn {{_, y, _}, amount} -> y < 1 and amount > 0 end)
    assert total(leaked) == @capacity
    assert Map.get(closed, {1, 0, 1}, 0) == 0
  end

  test "跨正负区域边界使用相同 canonical 通量，水可接收而冰挡住" do
    for x <- [-1, 63] do
      bounds = {{x, 0, 0}, {x + 2, 1, 1}}
      before = %{{x, 0, 0} => @capacity}
      material = fn cell -> if cell == {x + 1, 0, 0}, do: 20, else: 21 end
      assert advance(before, bounds, fn cell -> material.(cell) in [0, 21] end) == before
      after_step = advance(before, bounds, fn _ -> true end)
      assert after_step[{x + 1, 0, 0}] == div(@capacity, 8)
      assert total(after_step) == @capacity
    end
  end

  test "盛倒与既有材料余额共用量子，部分容量与重复计算不复制物质" do
    bounds = {{0, 0, 0}, {2, 1, 1}}
    water = %{{0, 0, 0} => @capacity, {1, 0, 0} => @capacity - 13}
    scoop = Liquid.scoop(water, {0, 0, 0}, 0, 100)
    after_scoop = Liquid.apply_changes(water, scoop.changes)
    assert scoop.balance == 100 and scoop.transferred_units == 100
    assert total(after_scoop) + scoop.balance == total(water)
    pour = Liquid.pour(after_scoop, {1, 0, 0}, scoop.balance, 100, @capacity, bounds, fn _ -> true end)
    after_pour = Liquid.apply_changes(after_scoop, pour.changes)
    assert pour.balance == 87 and pour.transferred_units == 13
    assert total(after_pour) + pour.balance == total(water)
    assert Liquid.pour(after_pour, {1, 0, 0}, pour.balance, 100, @capacity, bounds, fn _ -> true end).transferred_units == 0
    assert Liquid.pour(after_pour, {0, 0, 0}, pour.balance, 100, @capacity, bounds, fn _ -> false end).transferred_units == 0
    assert Liquid.pour(after_pour, {-1, 0, 0}, pour.balance, 100, @capacity, bounds, fn _ -> raise "域外不可采样" end).transferred_units == 0
    all = Liquid.scoop(%{{0, 0, 0} => 7}, {0, 0, 0}, 0, 100)
    assert all.changes == %{{0, 0, 0} => 0}
    assert Liquid.apply_changes(%{{0, 0, 0} => 7}, all.changes) == %{}
  end

  test "多邻居通量不超容量不负量，输入顺序不影响结果且封闭边界不丢水" do
    bounds = {{-2, 0, -2}, {3, 3, 3}}
    pairs = for x <- -2..2, y <- 0..2, z <- -2..2,
      do: {{x, y, z}, rem(abs(x * 7919 + y * 104729 + z * 15485863), @capacity) + 1}
    water = Map.new(pairs)
    reversed = Map.new(Enum.reverse(pairs))
    open? = fn {x, y, z} -> x in -2..2 and y in 0..2 and z in -2..2 end
    assert Liquid.step(water, bounds, @capacity, @capacity, @capacity, open?) ==
      Liquid.step(reversed, bounds, @capacity, @capacity, @capacity, open?)
    Enum.reduce(1..40, water, fn _, current ->
      next = advance(current, bounds, open?)
      assert total(next) == total(water)
      assert Enum.all?(next, fn {cell, quantity} -> quantity > 0 and quantity <= @capacity and open?.(cell) end)
      next
    end)
  end
end
