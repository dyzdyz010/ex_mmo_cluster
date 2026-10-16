defmodule VoxelRegion.LiquidActivityTest do
  @moduledoc "Test-only: finite-volume threshold and active/full step equivalence; pure values, no World or database."
  use ExUnit.Case, async: true
  alias VoxelRegion.Liquid
  @capacity 2_097_152
  @threshold div(@capacity, 8)

  # 只测试：在尚未进水的下游空格新增支撑；不代表允许玩家用实体替换已有水。
  test "one remaining quantum produces a one-quantum fall frame rather than a full-cell flag" do
    {changes, stages} = Liquid.step_transfers(%{{0,1,0} => 1}, {{0,0,0},{1,2,1}}, @capacity, @capacity, 0, fn _ -> true end)
    assert changes == %{{0,1,0} => 0, {0,0,0} => 1}
    assert Liquid.fall_transfers(stages) == [{{0,0,0},1}]
  end

  test "new downstream support stops a falling column without deleting its finite water" do
    bounds = {{0,0,0},{1,3,1}}
    water = %{{0,2,0} => 16}
    {changes, stages} = Liquid.step_transfers(water, bounds, 32, 8, 0, fn _ -> true end)
    assert Liquid.fall_transfers(stages) == [{{0,1,0},8}]
    water = Liquid.apply_changes(water, changes)
    refute Map.has_key?(water, {0,0,0})
    supported = fn {_,y,_} -> y > 0 end
    {changes, stages} = Liquid.step_transfers(water, bounds, 32, 8, 0, supported)
    assert Liquid.fall_transfers(stages) == [{{0,1,0},8}]
    water = Liquid.apply_changes(water, changes)
    assert water == %{{0,1,0} => 16}
    assert { %{}, stages } = Liquid.step_transfers(water, bounds, 32, 8, 0, supported)
    assert Liquid.fall_transfers(stages) == []
    assert MapSet.size(Liquid.next_active(stages)) == 0
  end

  test "fall display uses actual gravity destinations even when an intermediate cell has zero net change" do
    water = %{{0,2,0} => 16, {0,1,0} => 16}
    {changes, stages} = Liquid.step_transfers(water, {{0,0,0},{1,3,1}}, 32, 8, 0, fn _ -> true end)
    refute Map.has_key?(changes, {0,1,0})
    assert Liquid.fall_transfers(stages) == [{{0,0,0},8},{{0,1,0},8}]
    {_, sides} = Liquid.step_transfers(%{{0,0,0} => 16}, {{0,0,0},{2,1,1}},32,8,8,fn _ -> true end)
    assert Liquid.fall_transfers(sides) == []
  end

  test "side flow uses only excess head; gravity and old tiny quantities are preserved" do
    bounds = {{0, 0, 0}, {2, 2, 1}}
    water = %{{0, 0, 0} => @threshold}
    assert { %{}, _ } = Liquid.step_transfers(water, bounds, @capacity, @capacity, @capacity, fn _ -> true end, @threshold)
    water = %{{0, 0, 0} => @threshold + 80}
    {changes, _} = Liquid.step_transfers(water, bounds, @capacity, @capacity, @capacity, fn _ -> true end, @threshold)
    assert changes == %{{0, 0, 0} => @threshold + 70, {1, 0, 0} => 10}
    {changes, _} = Liquid.step_transfers(%{{0, 1, 0} => 7}, bounds, @capacity, @capacity, @capacity, fn _ -> true end, @threshold)
    assert changes == %{{0, 1, 0} => 0, {0, 0, 0} => 7}
  end

  # 逐步推进到内核不再产生变化（即 World 不再提交事务），每步核对守恒。
  defp settle(water, bounds, rule, limit) do
    Enum.reduce_while(1..limit, {water, 0}, fn n, {water, _} ->
      {changes, stages} = Liquid.step_transfers(water, bounds, @capacity, div(@capacity, 4), div(@capacity, 16), fn _ -> true end, rule)
      next = Liquid.apply_changes(water, changes)
      assert Enum.sum(Map.values(next)) == Enum.sum(Map.values(water))
      if changes == %{} do
        assert MapSet.size(Liquid.next_active(stages)) == 0
        {:halt, {next, n}}
      else
        {:cont, {next, n}}
      end
    end)
  end

  test "one cubic metre on a plane settles in bounded time without losing quanta" do
    bounds = {{-12, 0, -12}, {13, 1, 13}}
    {water, steps} = settle(%{{0,0,0} => @capacity}, bounds, {:wetting, @threshold}, 500)
    assert steps < 500
    # 润湿门槛：湿区内部摊平（相邻差 < 8），边缘不足门槛就停，覆盖至少 容量/(t+7) = 8 格、不铺成薄膜。
    assert map_size(water) >= 8 and map_size(water) <= 13
    assert Enum.max(Map.values(water)) - Enum.min(Map.values(water)) < 8 * 4
    assert Liquid.scoop(water, {0,0,0}, 0, @capacity).transferred_units > 0
  end

  # 1×1×5 槽一端灌满 1 m³（侧流上限 = 测试服 side_units_per_step = 容量/16）。
  # 手算：均值 容量/5 = 419430.4 > t，五格全湿；静止判据为相邻差 < 8，故各格落在 均值 ± 4×7 = [419402, 419459]。
  # 旧规则（液体沿用休止角阈值）静止时相邻差 ≈ t：约 [917504, 655360, 393216, 131072, 0] 的 0.375 m 斜面。
  test "a five-cell trough filled at one end levels in finite steps; the repose rule leaves a slope" do
    bounds = {{0, 0, 0}, {5, 1, 1}}
    trough = %{{0, 0, 0} => @capacity}
    {level, steps} = settle(trough, bounds, {:wetting, @threshold}, 2000)
    assert steps < 2000
    assert map_size(level) == 5
    assert Enum.all?(Map.values(level), &(&1 in 419_402..419_459))
    for x <- 0..3, do: assert(abs(level[{x, 0, 0}] - level[{x + 1, 0, 0}]) < 8)
    {slope, _} = settle(trough, bounds, @threshold, 2000)
    assert slope[{0, 0, 0}] - Map.get(slope, {3, 0, 0}, 0) > 2 * @threshold
    assert Map.get(slope, {4, 0, 0}, 0) == 0
    # 散体沿用休止角：整数阈值与 {:repose, t} 同义。
    assert settle(trough, bounds, {:repose, @threshold}, 2000) |> elem(0) == slope
  end

  test "active scheduling equals full synchronous gravity/side steps, then sleeps and wakes after a floor edit" do
    bounds = {{-4,-2,-4},{5,4,5}}
    initial = %{{0,3,0} => @capacity, {2,2,1} => div(@capacity,3)}
    for threshold <- [0,@threshold,{:wetting,@threshold}] do
      open = fn {_,y,_} -> y >= 0 end
      {settled, active} = Enum.reduce(1..300, {initial, Liquid.neighborhood(Map.keys(initial))}, fn _, {water,active} ->
        args = [water,bounds,@capacity,div(@capacity,4),div(@capacity,16),open,threshold]
        {full,_} = apply(Liquid,:step_transfers,args)
        {partial,stages} = apply(Liquid,:step_transfers,args ++ [active])
        assert partial == full
        {Liquid.apply_changes(water,partial),Liquid.next_active(stages)}
      end)
      if threshold > 0, do: assert(MapSet.size(active) == 0)
      opened = fn {x,y,z} -> y >= 0 or (x == 0 and z == 0) end
      active = MapSet.union(active,Liquid.neighborhood([{0,-1,0}]))
      {full,_} = Liquid.step_transfers(settled,bounds,@capacity,@capacity,@capacity,opened,threshold)
      {partial,_} = Liquid.step_transfers(settled,bounds,@capacity,@capacity,@capacity,opened,threshold,active)
      assert partial == full
      assert Map.get(partial,{0,-1,0},0) > 0
    end
  end
end
