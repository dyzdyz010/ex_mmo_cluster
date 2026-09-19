defmodule VoxelRegion.LiquidActivityTest do
  @moduledoc "Test-only: finite-volume threshold and active/full step equivalence; pure values, no World or database."
  use ExUnit.Case, async: true
  alias VoxelRegion.Liquid
  @capacity 2_097_152
  @threshold div(@capacity, 8)

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

  test "one cubic metre on a plane settles in bounded time without losing quanta" do
    bounds = {{-12, 0, -12}, {13, 1, 13}}
    {water, steps} = Enum.reduce_while(1..500, {%{{0,0,0} => @capacity}, 0}, fn n, {water, _} ->
      {changes, _} = Liquid.step_transfers(water, bounds, @capacity, @capacity, div(@capacity,16), fn _ -> true end, @threshold)
      next = Liquid.apply_changes(water, changes)
      assert Enum.sum(Map.values(next)) == @capacity
      if changes == %{}, do: {:halt, {next,n}}, else: {:cont, {next,n}}
    end)
    assert steps < 500
    assert map_size(water) <= 13
    assert Liquid.scoop(water, {0,0,0}, 0, @capacity).transferred_units > 0
  end

  test "active scheduling equals full synchronous gravity/side steps, then sleeps and wakes after a floor edit" do
    bounds = {{-4,-2,-4},{5,4,5}}
    initial = %{{0,3,0} => @capacity, {2,2,1} => div(@capacity,3)}
    for threshold <- [0,@threshold] do
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
