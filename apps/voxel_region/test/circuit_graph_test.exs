defmodule VoxelRegion.CircuitGraphTest do
  @moduledoc "只测试：读取图owner回调的小确定输入；不启动World、数据库或新求解器。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{Circuit, Damage, Protection, ThermalGeometry}
  alias VoxelRegion.World.{Canonical, CircuitGraph, Thermal}

  defp target(x, material), do: %{micro: {x * 8, 0, 0}, granularity: 0, material: material,
    owner: {0, 0}, incarnation: 1}

  defp state do
    seed = target(63, 43)
    slot = {1, 0, {520, 4, 4}}
    empty = for x <- 60..66, y <- -2..2, z <- -2..2, into: %{}, do: {{0, {x, y, z}}, {0, 0}}
    %{seq: 1, resident: MapSet.new([{0, {0, 0, 0}}]),
      overlay: empty |> Map.put({0, {63, 0, 0}}, {43, 0}) |> Map.put({0, {64, 0, 0}}, {24, 0}),
      refined: %{}, epochs: %{}, macro_owners: %{}, liquid_units: %{}, attachments: %{slot => {7, 24}},
      protection: Protection.new(), damage: %{Damage.key(seed) => Map.put(seed, :temperature_kelvin, 310.0)},
      properties: %{materials: %{0 => %{}, 24 => %{"electrical_conductivity" => 10.0},
        43 => %{"electrical_conductivity" => 2.0, "seebeck_v_per_k" => 0.05}}},
      thermal: %{config: %{"ambient_kelvin" => 293.15}},
      thermal_work: %{electric: MapSet.new([Damage.key(seed)]), circuit: nil}}
    |> Canonical.index_attachments()
  end

  test "实体读取遇冷页先返回原图和真实XYZ需求，不把未知导体当空气" do
    s = state()
    graph = CircuitGraph.new(s.seq, [target(63, 43)])
    assert {:needs_pages, keys, waiting, same} = CircuitGraph.advance(s, graph)
    assert same == s
    assert {0, {1, 0, 0}} in keys
    assert MapSet.size(waiting.solids) == 0
    assert :queue.len(waiting.queue) == 1
    assert {0, {1, 0, 0}} in CircuitGraph.dependencies(waiting)
  end

  test "装页后同图发现冷实体另一侧附件，冻结实际slot和host" do
    s = state()
    graph = CircuitGraph.new(s.seq, [target(63, 43)])
    assert {:needs_pages, _, waiting, s} = CircuitGraph.advance(s, graph)
    assert {:ready, ready, _} = CircuitGraph.advance(%{s | resident: :all}, waiting)
    assert MapSet.member?(ready.solids, ThermalGeometry.key(target(64, 24)))
    assert ready.slots == %{{1, 0, {520, 4, 4}} => {7, 24}}
    assert Enum.any?(ready.hosts[{:point, {520, 4, 4}}], &(&1.micro == {512, 0, 0}))
    refute Enum.any?(ready.hosts[{:point, {521, 4, 4}}], &(&1.micro == {512, 0, 0}))
  end

  test "未求解准备图遇正常提交seq变化，旧实体和附件不进入新图" do
    s = state()
    assert {:needs_pages, _, pending} = Thermal.prepare_circuit(s)
    assert pending.thermal_work.circuit.seq == 1
    current = Canonical.index_attachments(%{pending | seq: 2, damage: %{}, attachments: %{}})
    assert {:ready, empty, _} = Thermal.prepare_circuit(current)
    assert empty.seq == 2
    assert empty.slots == %{}
    assert MapSet.size(empty.solids) == 0
  end

  test "消费完整图后退休大输入，只保留下一段实际读取依赖" do
    s = %{state() | resident: :all}
    assert {:ready, ready, _} = CircuitGraph.advance(s, CircuitGraph.new(s.seq, [target(63, 43)]))
    complete = CircuitGraph.completed(ready)
    assert complete.status == :complete
    assert CircuitGraph.dependencies(complete) == CircuitGraph.dependencies(ready)
    refute Map.has_key?(complete, :hosts)
    refute Map.has_key?(complete, :slots)
    refute Map.has_key?(complete, :contacts)
  end

  test "32与33槽的被动断开岛不改变可达闭路的拓扑、功率或能量方向" do
    catalog = Damage.load(Path.expand("fixtures/combustion/b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec.json", __DIR__))
    environment = %{"ambient_kelvin" => 293.15, "circuit_min_power_w" => 1.0}
    node = fn {x, y, z}, material -> %{micro: {x * 8, y * 8, z * 8}, granularity: 0,
      material: material, owner: {0, 0}, incarnation: 0} end
    [battery, b0, b1, b2, t0, load, t2] = cells = [node.({0, 0, 0}, 42),
      node.({0, -1, 0}, 24), node.({1, -1, 0}, 24), node.({2, -1, 0}, 24),
      node.({0, 1, 0}, 24), node.({1, 1, 0}, 40), node.({2, 1, 0}, 24)]
    damage = %{Damage.key(battery) => Map.put(battery, :stored_j, 1.0e6)}
    # 固定七实体与八线槽单串回路；远处无源岛只增加全量旧输入的map规模，不触碰回路。
    active = for y <- 0..7, into: %{}, do: {{1, 1, {20, y, 4}}, {y + 1, 24}}
    empty = for x <- -2..4, y <- -3..3, z <- -2..2, into: %{}, do: {{0, {x, y, z}}, {0, 0}}
    overlay = Enum.reduce(cells, empty, &Map.put(&2, {0, Damage.macro(&1)}, {&1.material, 0}))
    contacts = [{battery, b0, 1.0}, {b0, b1, 1.0}, {b1, b2, 1.0},
      {battery, t0, 1.0}, {t0, load, 1.0}, {load, t2, 1.0}]
    contact_set = fn entries -> MapSet.new(entries, fn {a, b, area} ->
      {Enum.sort([ThermalGeometry.key(a), ThermalGeometry.key(b)]), area}
    end) end
    # 与既有Circuit电池／合金例同一发布参数与1e-8电流相对界；其它断言保持精确或自身绝对界。
    cu = catalog.materials[24]["electrical_conductivity"]
    section = catalog.attachments["line_section_m2"]
    current = 24.0 / (0.05 + 0.25 + 4.0 / cu + 2.0 / (cu * section))

    for count <- [32, 33] do
      island = for n <- 1..(count - 8), into: %{}, do: {{1, 0, {800 + n, 800, 800}}, {100 + n, 24}}
      slots = Map.merge(active, island)
      assert map_size(slots) == count
      state = %{state() | seq: 1, resident: :all, overlay: overlay, damage: damage,
        attachments: slots, properties: catalog, thermal: %{config: environment}} |> Canonical.index_attachments()
      assert {:ready, graph, _} = CircuitGraph.advance(state, CircuitGraph.new(1, [battery]))
      assert graph.slots == active
      assert contact_set.(graph.contacts) == contact_set.(contacts)
      assert MapSet.size(graph.solids) == length(cells)
      input = Circuit.prepare(slots, damage, catalog, 0.5, environment)
      hosts = Map.new(Circuit.points(input), fn point ->
        {point, case point do {:point, {20, 0, 4}} -> [b2]; {:point, {20, 8, 4}} -> [t2]; _ -> [] end}
      end)
      reference = Circuit.plan(input, hosts, contacts)
      reachable = Circuit.plan(Circuit.prepare(graph.slots, damage, catalog, 0.5, environment), graph.hosts, graph.contacts)
      assert reachable.edges == 16
      assert reference.edges == reachable.edges + map_size(island)
      assert Map.keys(reachable.electric) == Map.keys(reference.electric)
      assert Map.keys(reachable.sources) == Map.keys(reference.sources)
      for plan <- [reference, reachable] do
        source = plan.sources[ThermalGeometry.key(battery)]
        assert source.current_a > 0.0 and plan.supplied_j > 0.0 and plan.light_j > 0.0
        assert plan.charged_j == 0.0 and plan.thermoelectric_j == 0.0
        assert source.emf_v == 24.0
        assert_in_delta source.current_a, current, current * 1.0e-8
        assert_in_delta source.stored_j, 1.0e6 - 24.0 * current * 0.5, 24.0 * current * 0.5 * 1.0e-8
        assert_in_delta plan.supplied_j, 24.0 * current * 0.5, 24.0 * current * 0.5 * 1.0e-8
        assert_in_delta plan.light_j, 0.2 * current * current * 0.25 * 0.5,
          0.2 * current * current * 0.25 * 0.5 * 3.0e-8
      end
      assert Map.keys(reachable.powers) |> Enum.sort() == Map.keys(reference.powers) |> Enum.sort()
      for {key, power} <- reference.powers, do: assert_in_delta(reachable.powers[key], power, abs(power) * 3.0e-8)
      physics = fn plan -> Map.take(plan, [:duration, :powers, :supplied_j, :charged_j, :light_j, :electric, :sources]) end
      IO.puts("CIRCUIT_MAP_COMPARE slots=#{count} retained=#{map_size(graph.slots)} physics_bit_identical=#{physics.(reference) === physics.(reachable)}")
    end
  end

  # 3×3×3天然铜立方（无附件）：实际构图每次电路段都重建，单个宏格实体的读取工作只应由其接触面与端点盒内候选槽决定。
  # 用调用进程归约数而非墙钟，结果不随机器负载漂移；阈值只属测试侧（逐顶点×关联槽枚举时约46–58万/实体，
  # 无附件仍逐个查约五千个候选锚点时约2.4万/实体，候选与区域实际附件求交后约1.1万/实体）。
  test "宏格实体构图按端点盒一次取候选槽与页，不按9³顶点×关联槽重复枚举，也不逐个查无附件的候选锚点" do
    cells = for x <- 0..2, y <- 0..2, z <- 0..2, do: {x, y, z}
    empty = for x <- -1..3, y <- -1..3, z <- -1..3, into: %{}, do: {{0, {x, y, z}}, {0, 0}}
    seed = %{micro: {0, 0, 0}, granularity: 0, material: 24, owner: {0, 0}, incarnation: 0}
    s = %{state() | resident: :all, attachments: %{}, damage: %{},
      overlay: Enum.reduce(cells, empty, &Map.put(&2, {0, &1}, {24, 0}))} |> Canonical.index_attachments()
    graph = CircuitGraph.new(s.seq, [seed])
    {:reductions, before} = Process.info(self(), :reductions)
    assert {:ready, ready, _} = CircuitGraph.advance(s, graph)
    {:reductions, after_build} = Process.info(self(), :reductions)
    assert MapSet.size(ready.solids) == 27
    assert div(after_build - before, 27) < 16_000
  end
end
