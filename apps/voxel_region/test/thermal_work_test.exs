defmodule VoxelRegion.ThermalWorkTest do
  @moduledoc "只测试：热候选域与可丢弃接触图的复用、编辑失效和索引契约。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{Attachments, ThermalAttachments, ThermalRadiation, ThermalWork}

  test "热记录、有限源、电功率与燃烧种子覆盖完整三维附件足迹" do
    slot = {0, 0, {512, 0, 0}}
    target = Attachments.identity(slot, {1, 19}) |> Map.put(:granularity, 4)
    hot = %{target | material: 19} |> Map.put(:temperature_kelvin, 310.0)
    config = %{"ambient_kelvin" => 300.0, "tolerance_kelvin" => 0.1}
    footprint = MapSet.new(Attachments.macros([slot]))
    assert ThermalWork.hot(%{slot => hot}, config) == footprint

    burning = Map.put(target, :burning, true)
    assert ThermalWork.hot(%{slot => burning}, config) == footprint
    assert ThermalWork.hot(%{slot => %{hot | temperature_kelvin: 300.0}}, config) == MapSet.new()

    work = %{ThermalWork.new() | hot: MapSet.new([{-5, -6, -7}])}
    source = {1, 2, 3}
    electric = {1, 1, {-8, -8, -8}}

    plan =
      ThermalWork.plan(work, %{source => %{}}, %{ThermalAttachments.key(electric) => -1.0}, %{
        slot => burning
      })

    seeds =
      footprint
      |> MapSet.union(MapSet.new(Attachments.macros([electric])))
      |> MapSet.put(source)
      |> MapSet.put({-5, -6, -7})

    assert plan.seeds == seeds
    assert MapSet.member?(plan.cells, {1, 3, 3})
    assert MapSet.member?(plan.cells, {1, 2, 4})
    refute MapSet.member?(plan.cells, {2, 3, 4})
    assert plan.missing == plan.cells
  end

  test "空气扩域和收缩保留接触图，收缩丢弃离域几何" do
    work = warm()
    expanded = %{work | hot: MapSet.new([{0, 0, 0}, {0, 0, 2}])}
    plan = ThermalWork.plan(expanded, %{}, %{}, %{})
    geometry = Map.merge(plan.geometry, Map.new(plan.missing, &{&1, []}))
    {next, rebuild?} = ThermalWork.refresh(expanded, plan, geometry, %{})
    refute rebuild?
    assert next.ordered == work.ordered
    assert next.indexed_edges == work.indexed_edges
    assert next.builds == work.builds + MapSet.size(plan.missing)

    cooled = %{next | hot: work.hot}
    plan = ThermalWork.plan(cooled, %{}, %{}, %{})
    {next, false} = ThermalWork.refresh(cooled, plan, plan.geometry, %{})
    assert next.geometry == work.geometry
    assert next.ordered == work.ordered
  end

  test "同域无热容量宿主失效仍重建，合法空气无需重新读取" do
    work = warm()
    assert ThermalWork.plan(work, %{}, %{}, %{}).missing == MapSet.new()
    edited = %{work | geometry: Map.delete(work.geometry, {1, 0, 0})}
    plan = ThermalWork.plan(edited, %{}, %{}, %{})
    assert plan.missing == MapSet.new([{1, 0, 0}])
    geometry = Map.put(plan.geometry, {1, 0, 0}, [])
    {next, rebuild?} = ThermalWork.refresh(edited, plan, geometry, %{})
    assert rebuild?
    assert next.solid_nodes == work.solid_nodes
    assert next.thermal_slots == work.thermal_slots
  end

  test "扩域纳入新附件和实体时重建，离域附件不参与" do
    work = warm()
    near = {0, 0, {0, 0, 24}}
    far = {0, 0, {800, 800, 800}}
    attachments = %{near => {1, 19}, far => {2, 19}}

    work = %{
      work
      | attachment_cells: Enum.map(attachments, fn {s, v} -> {s, v, Attachments.macros([s])} end)
    }

    expanded = %{work | hot: MapSet.put(work.hot, {0, 0, 2})}
    plan = ThermalWork.plan(expanded, %{}, %{}, %{})
    geometry = Map.merge(plan.geometry, Map.new(plan.missing, &{&1, []}))
    {next, true} = ThermalWork.refresh(expanded, plan, geometry, attachments)
    assert next.thermal_slots == %{near => {1, 19}}

    key = {0, {0, 0, 24}}
    geometry = Map.put(geometry, {0, 0, 3}, [{key, %{contacts: []}}])
    {next, true} = ThermalWork.refresh(expanded, plan, geometry, attachments)
    assert Map.has_key?(next.solid_nodes, key)
  end

  test "接触索引跟随原节点顺序，每条接触只结算一次" do
    a = {0, {504, 0, 0}}
    b = {0, {512, 0, 0}}
    nodes = %{a => %{contacts: [{b, 2.0}]}, b => %{contacts: [{a, 2.0}]}}
    work = ThermalWork.index(ThermalWork.new(), nodes, :attachment_graph)
    assert work.ordered == Enum.to_list(nodes)
    assert work.edges == [{a, b, 2.0}]
    assert [{i, j, 2.0}] = work.indexed_edges
    assert elem(Enum.at(work.ordered, i), 0) == a
    assert elem(Enum.at(work.ordered, j), 0) == b
    assert work.attachment_graph == :attachment_graph
  end

  test "提交内种子只增：增量扩域与整域重算得到同一候选域、节点表和燃烧行" do
    key = fn cell -> {0, cell |> Tuple.to_list() |> Enum.map(&(&1 * 8)) |> List.to_tuple()} end
    geometry = fn cells -> Map.new(cells, &{&1, if(elem(&1, 1) == 0, do: [{key.(&1), %{contacts: []}}], else: [])}) end
    # 种子 {0,0,0} 的一条视线命中 {5,0,0}；视线表按 World 的 sight_domain 在计算该格视线的同一轮补入伙伴格。
    sights = %{{0, 0, 0} => [{key.({0, 0, 0}), {key.({5, 0, 0}), {5, 0, 0}}, 1.0}]}
    sight_domain = fn plan ->
      extra = MapSet.difference(ThermalRadiation.partners(sights, plan.fresh), plan.cells)
      %{plan | cells: MapSet.union(plan.cells, extra), missing: MapSet.union(plan.missing, extra),
        grown: plan.grown && MapSet.union(plan.grown, extra)}
    end

    work = %{warm() | sights: sights, seeds: nil}
    base = sight_domain.(ThermalWork.plan(work, %{}, %{}, %{}))
    {work, _} = ThermalWork.refresh(work, base, Map.merge(work.geometry, geometry.(base.missing)), %{})
    assert work.exact and MapSet.member?(work.cells, {5, 0, 0})
    grown = %{work | hot: MapSet.new([{0, 0, 0}, {1, 0, 0}, {3, 0, 0}])}

    incremental = sight_domain.(ThermalWork.plan(grown, %{}, %{}, %{}))
    full = sight_domain.(ThermalWork.plan(%{grown | exact: false}, %{}, %{}, %{}))
    assert incremental.grown != nil and full.grown == nil
    assert incremental.cells == full.cells
    assert incremental.missing == MapSet.difference(full.cells, MapSet.new(Map.keys(work.geometry)))

    all = Map.merge(work.geometry, geometry.(incremental.missing))
    {a, true} = ThermalWork.refresh(grown, incremental, all, %{})
    {b, true} = ThermalWork.refresh(%{grown | exact: false}, full, all, %{})
    assert Enum.to_list(a.solid_nodes) == Enum.to_list(b.solid_nodes)

    burning = %{micro: {8, 0, 0}, granularity: 0, burning: true}
    work = ThermalWork.burned(%{a | burning: %{}}, [{:a, burning}, {:b, burning}, {:a, %{burning | burning: false}}])
    assert work.burning == %{b: [{1, 0, 0}]}
  end

  defp warm do
    work = %{ThermalWork.new() | hot: MapSet.new([{0, 0, 0}])}
    plan = ThermalWork.plan(work, %{}, %{}, %{})
    key = {0, {0, 0, 0}}
    node = %{contacts: []}
    geometry = Map.new(plan.cells, &{&1, []}) |> Map.put({0, 0, 0}, [{key, node}])
    {work, true} = ThermalWork.refresh(work, plan, geometry, %{})
    ThermalWork.index(work, %{key => node}, nil)
  end
end
