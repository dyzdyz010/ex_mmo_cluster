defmodule VoxelRegion.ThermalWorkTest do
  @moduledoc "只测试：热候选域与可丢弃接触图的复用和编辑失效；内核节点表与拓扑见 ThermalDomainTest。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{Attachments, ThermalAttachments, ThermalDomain, ThermalRadiation, ThermalWork}

  test "热记录、有限源、电功率与燃烧种子覆盖完整三维附件足迹" do
    slot = {0, 0, {512, 0, 0}}
    target = Attachments.identity(slot, {1, 19}) |> Map.put(:granularity, 4)
    hot = %{target | material: 19} |> Map.put(:temperature_kelvin, 310.0)
    config = %{"ambient_kelvin" => 300.0, "tolerance_kelvin" => 0.1}
    footprint = MapSet.new(Attachments.macros([slot]))
    assert ThermalWork.footprints(ThermalWork.hot_rows(%{slot => hot}, config)) == footprint

    burning = Map.put(target, :burning, true)
    assert ThermalWork.footprints(ThermalWork.hot_rows(%{slot => burning}, config)) == footprint
    assert ThermalWork.footprints(ThermalWork.hot_rows(%{slot => %{hot | temperature_kelvin: 300.0}}, config)) == MapSet.new()

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

  # R8-05：提交末只重判上次的热行与此后改写过的行；期望按判据手算（环境 300 K、容差 0.1 K）。
  test "热行增量重判：冷却移出、改写升温与新行加入、删除移出，未改写的行沿用上次判定" do
    config = %{"ambient_kelvin" => 300.0, "tolerance_kelvin" => 0.1}
    row = fn x, fields -> Map.merge(%{micro: {x * 8, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 11}, fields) end
    key = &VoxelRegion.Damage.key/1
    a = row.(0, %{temperature_kelvin: 310.0})
    b = row.(1, %{temperature_kelvin: 300.05})
    c = row.(2, %{burning: true})
    rows = ThermalWork.hot_rows(Map.new([a, b, c], &{key.(&1), &1}), config)
    assert rows == %{key.(a) => [{0, 0, 0}], key.(c) => [{2, 0, 0}]}

    # a 在提交内冷却到容差内（本次提交改写），b 被事务加热、d 由事务新建为低温行，c 被删除。
    d = row.(3, %{temperature_kelvin: 290.0})
    damage = Map.new([%{a | temperature_kelvin: 300.0}, %{b | temperature_kelvin: 305.0}, d], &{key.(&1), &1})
    next = ThermalWork.rehot(rows, [key.(a), key.(b), key.(d)], damage, config)
    assert next == %{key.(b) => [{1, 0, 0}], key.(d) => [{3, 0, 0}]}
    assert ThermalWork.footprints(next) == MapSet.new([{1, 0, 0}, {3, 0, 0}])
    # 删除行的事务不带该行：上次的热行不在改写集合里也按当前记录重判（c 被删除，a、b 未变）。
    assert ThermalWork.rehot(rows, [], Map.new([a, b], &{key.(&1), &1}), config) == %{key.(a) => [{0, 0, 0}]}
  end

  # R8-05：事务改写的行增量维护燃烧行、结算待判键与电路候选；期望按判据手算（42 蓄能石、43 热电石、11 石）。
  test "事务改写的行：点燃加入、熄灭移出燃烧行；待判键累计；蓄能石／热电石与带电观察字段的行进入电路候选，删除行使用处过滤" do
    catalog = %{materials: %{11 => %{}, 42 => %{"battery_volts_per_m" => 24}, 43 => %{"seebeck_v_per_k" => 0.05}}}
    row = fn x, m, fields -> Map.merge(%{micro: {x * 8, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: m}, fields) end
    key = &VoxelRegion.Damage.key/1
    stone = row.(0, 11, %{burning: true})
    lamp = row.(1, 11, %{electric_w: 3.0})
    battery = row.(2, 42, %{})
    te = row.(3, 43, %{temperature_kelvin: 310.0})
    work = %{ThermalWork.new() | burning: %{}, pending: MapSet.new(), electric: MapSet.new()}
    work = ThermalWork.touched(work, [stone, lamp, battery, te], catalog)
    assert work.burning == %{key.(stone) => [{0, 0, 0}]}
    assert work.pending == MapSet.new(Enum.map([stone, lamp, battery, te], key))
    assert work.electric == MapSet.new(Enum.map([lamp, battery, te], key))
    # 熄灭移出；未派生（nil）的集合保持待全量派生。
    work = ThermalWork.touched(%{work | pending: nil}, [%{stone | burning: false}], catalog)
    assert work.burning == %{} and work.pending == nil
    # 删除行不经事务：燃烧行与候选按当前记录过滤（石被删除，灯去掉了观察字段）。
    damage = Map.new([%{lamp | electric_w: nil} |> Map.delete(:electric_w), battery, te], &{key.(&1), &1})
    assert ThermalWork.live_burning(%{key.(stone) => [{0, 0, 0}]}, damage) == %{}
    assert ThermalWork.electric(Map.keys(damage) ++ [key.(stone)], damage, catalog) == MapSet.new([key.(battery), key.(te)])
  end

  # 成本（默认排除，`--only benchmark`）：Demo 实测约 2.7 万条属性记录；小装置只有少数热行与改写行。
  @tag :benchmark
  test "热行判定成本：全量扫描与增量重判" do
    config = %{"ambient_kelvin" => 293.15, "tolerance_kelvin" => 1.0}
    rows = for i <- 0..26_999, do: %{micro: {rem(i, 300) * 8, div(i, 90_000) * 8, div(i, 300) * 8}, granularity: 0,
      incarnation: 0, owner: {0, 0}, material: 11, hp: 50.0, temperature_kelvin: 293.4}
    damage = Map.new(rows, &{VoxelRegion.Damage.key(&1), &1})
    lamp = rows |> Enum.take(12) |> Enum.map(&%{&1 | temperature_kelvin: 400.0})
    damage = Map.merge(damage, Map.new(lamp, &{VoxelRegion.Damage.key(&1), &1}))
    keys = Enum.map(lamp, &VoxelRegion.Damage.key/1)
    hot = ThermalWork.hot_rows(damage, config)
    time = fn f -> Enum.min(for _ <- 1..20, do: elem(:timer.tc(f), 0)) end
    full = time.(fn -> ThermalWork.hot_rows(damage, config) end)
    incremental = time.(fn -> ThermalWork.rehot(hot, keys, damage, config) end)
    assert ThermalWork.rehot(hot, keys, damage, config) == hot
    IO.puts("THERMAL_HOT_COST rows=#{map_size(damage)} hot=#{map_size(hot)} touched=#{length(keys)} full_us=#{full} incremental_us=#{incremental}")
  end

  test "空气扩域和收缩保留接触图，收缩丢弃离域几何" do
    work = warm()
    expanded = %{work | hot: MapSet.new([{0, 0, 0}, {0, 0, 2}])}
    plan = ThermalWork.plan(expanded, %{}, %{}, %{})
    geometry = Map.merge(plan.geometry, Map.new(plan.missing, &{&1, []}))
    {next, rebuild?} = ThermalWork.refresh(expanded, plan, geometry, %{})
    refute rebuild?
    assert next.ordered == work.ordered
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
    domain = ThermalDomain.sync(work.domain, %{key => node}, :full, [], :tag, nil,
      &{Map.merge(%{cell: {0, 0, 0}, cells: [{0, 0, 0}], damage_key: :row}, &1), false},
      fn _ -> {{1.0, 1.0, 1000.0, 6.0, 293.15, nil, false, true, nil}, {293.15, 1.0, 1.0, nil, 0.0, false, nil, nil}} end)
    {domain, ordered} = ThermalDomain.index(domain, 0.0)
    %{work | domain: domain, ordered: ordered}
  end

  test "热键足迹覆盖负坐标微格以及所有附件方向" do
    assert ThermalWork.key_cells({1, {-1, -9, 8}}) == [{-1, -2, 1}]
    for kind <- 0..1, axis <- 0..2 do
      slot = {kind, axis, {-8, -8, -8}}
      assert ThermalWork.key_cells(ThermalAttachments.key(slot)) == Attachments.macros([slot])
    end
  end
end
