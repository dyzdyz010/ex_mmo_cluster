defmodule VoxelRegion.ThermalInvalidationTest do
  @moduledoc "只测试：派生视线失效的局部性与空编辑复用；手算相距 100 格、视距 8 的两处热域。"
  use ExUnit.Case, async: true
  alias VoxelRegion.ThermalWork

  defp sample do
    a={-20,3,-5}
    b={80,3,-5}
    ka={0,{-160,24,-40}}
    kb={0,{640,24,-40}}
    sights=%{a=>[{ka,:sky,6.0}],b=>[{kb,:sky,6.0}]}
    %{ThermalWork.new() | geometry: %{a=>[],b=>[]}, cells: MapSet.new([a,b]), sights: sights, exact: true}
  end

  test "空编辑保留已完整派生的域" do
    work=sample()
    assert ThermalWork.drop(work,[],8)==work
  end

  test "局部占用编辑保留超出视距的远处视线" do
    work=sample()
    edited=ThermalWork.drop(work,[{-19,3,-5}],8)
    assert edited.sights==%{{80,3,-5}=>[{{0,{640,24,-40}},:sky,6.0}]}
    assert edited.geometry==work.geometry
  end

  test "六轴视距端点失效，跨轴或视距之外保留，包括负坐标" do
    origin = {-20, 3, -5}
    points = for axis <- 0..2, sign <- [-1, 1], do: put_elem(origin, axis, elem(origin, axis) + sign * 8)
    outside = [{-29, 3, -5}, {-12, 4, -5}, {-20, 3, 4}]
    sights = Map.new([origin | points ++ outside], &{&1, []})
    work = %{ThermalWork.new() | sights: sights}
    assert ThermalWork.drop(work, [origin], 8).sights == Map.take(sights, outside)
  end

  test "热域收缩不让未变几何失效，休眠期间的编辑仍须重读" do
    a = {0, 0, 0}
    b = {30, 0, 0}
    ka = {0, {0, 0, 0}}
    kb = {0, {240, 0, 0}}
    work = %{ThermalWork.new() | hot: MapSet.new([a, b])}
    plan = ThermalWork.plan(work, %{}, %{}, %{})
    geometry = Map.new(plan.cells, &{&1, []}) |> Map.put(a, [{ka, %{contacts: []}}]) |> Map.put(b, [{kb, %{contacts: []}}])
    {work, true} = ThermalWork.refresh(work, plan, geometry, %{})
    work = %{work | hot: MapSet.new([a])}
    plan = ThermalWork.plan(work, %{}, %{}, %{})
    {cold, true} = ThermalWork.refresh(work, plan, plan.geometry, %{})
    refute MapSet.member?(cold.cells, b)
    refute Map.has_key?(cold.solid_nodes, kb)
    resumed = %{cold | hot: MapSet.new([a, b])}
    plan = ThermalWork.plan(resumed, %{}, %{}, %{})
    assert plan.missing == MapSet.new()
    {warm, true} = ThermalWork.refresh(resumed, plan, plan.geometry, %{})
    assert warm.solid_nodes == %{ka => %{contacts: []}, kb => %{contacts: []}}
    edited = ThermalWork.drop(cold, [b], 8)
    plan = ThermalWork.plan(%{edited | hot: resumed.hot}, %{}, %{}, %{})
    assert plan.missing == MapSet.new([b])
  end
end
