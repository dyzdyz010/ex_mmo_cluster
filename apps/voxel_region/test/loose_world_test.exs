defmodule VoxelRegion.LooseWorldTest do
  @moduledoc """
  只测试：R8-07 散体（倾倒／舀取的有限数量固体）经真实 World 意图、数量内核、热提交、几何事务与冷恢复。

  目录 = UE 发布 `b1aca503…` 字节，另给可倾倒材料加 `loose_threshold_units`（沙、煤 5/8 格，砾石、矿、产物 6/8 格），
  即 `test/fixtures/combustion/7b69b79f…`；本模块只把液体步长改成 3600 s，数量步只由测试手动投递。
  材料只经 material_supply（一次、记账）；地形只经作者编辑、作者 Prefab 与玩家建造；时间只经 :liquid_commit / :thermal_commit。
  期望来自目录算术与内核的静止判据（同层相邻差 d 在 (t, t+8) 内停），不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :loose
  alias VoxelRegion.{World, Damage, ParameterEvolution}
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @loose "7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e"
  @published "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @cap 2_097_152
  @quarter div(@cap, 4)
  @sand 5
  @stone 11
  @coal 15
  @ore 16
  @copper 24
  @water 21
  @ambient 293.15
  @box {{-1, -1, -1}, {10, 10, 10}}

  setup context do
    root = Path.join(System.tmp_dir!(), "loose_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @loose <> ".json")))
    # 只测试：手动投递数量步（正式节拍 0.1 s 不变）；转化场景另把热损伤阈值提到 1e5 K，只观察转化。
    data = put_in(data, ["liquid", "step_seconds"], 3600)
    data = if context[:no_heat_damage],
      do: Map.update!(data, "materials", &Enum.map(&1, fn m ->
        if m["material_id"] in [@coal, @ore, @copper], do: Map.put(m, "heat_resistance_kelvin", 1.0e5), else: m end)),
      else: data
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment.json"), env)
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [@sand, @stone, @coal, @ore, @copper, @water],
      liquid_bounds: context[:bounds] || {{0, 0, 0}, {8, 8, 8}}]
    w = start_supervised!({World, opts})
    actor = %{cid: 1001, gate: self(), identity: :loose, refresh: &Actor.tool_context/2,
      eye: context[:eye] || {4.5, 6.5, 4.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    {:ok, _} = World.material_supply(w, 1001, "loose-scenario",
      %{@sand => 8 * @cap, @stone => 16 * @cap, @coal => 4 * @cap, @ore => @cap, @water => @cap})
    %{w: w, opts: opts, actor: actor, root: root, catalog: catalog, data: data,
      materials: Map.new(data["materials"], &{&1["material_id"], &1})}
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp intent(c, action, material, coord, tool) do
    seq = next()
    World.production_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material,
        tool_id: tool, coord: coord})
  end

  defp pour(c, coord, material \\ @sand), do: intent(c, 3, material, coord, 12)
  defp scoop(c, coord, material), do: intent(c, 2, material, coord, 11)
  defp build(c, coord, material), do: intent(c, 1, material, coord, 1)
  defp eye(c, eye), do: :ok = GenServer.call(c.actor.player, {:eye, eye})

  defp tick(w), do: (send(w, :liquid_commit); World.seq(w))

  defp settle(w, left \\ 2000) do
    tick(w)
    cond do
      World.liquid_activity(w).active_cells == 0 -> :ok
      left == 0 -> flunk("loose cells did not come to rest")
      true -> settle(w, left - 1)
    end
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp quantities(w), do: observe(w).liquid_units
  defp balance(w, m), do: Enum.find(World.material_balances(w, 1001), &(&1.material == m)).balance
  defp material(w, cell), do: hd(World.material_snapshot(w, [], [cell]).probe_occupancy).material
  defp micro({x, y, z}), do: {x * 8, y * 8, z * 8}
  defp row(s, cell), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == micro(cell)))

  # 从正上方瞄准一个宏格：先查询权威命中身份，再以同一身份执行。
  defp tool(c, cell, tool_id) do
    {x, _, z} = cell
    eye(c, {x + 0.5, 6.5, z + 0.5})
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: tool_id,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, c.actor, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    World.tool_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}), request)
  end

  defp thermal(w, left \\ 4000, stop?) do
    send(w, :thermal_commit)
    s = observe(w)
    cond do
      stop?.(s) -> s
      left == 0 -> flunk("thermal condition not reached; elapsed #{s.thermal.elapsed_s}")
      true -> thermal(w, left - 1, stop?)
    end
  end

  defp heat(c, cell, power, energy) do
    path = Path.join(c.root, "thermal.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(cell),
      ambient_kelvin: @ambient, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0,
      view_range_cells: 8, power_w: power, energy_j: energy}))
    :ok = World.thermal_experiment(c.w, path)
  end

  defp define(c, name, macros, micro \\ []) do
    cells = fn xs -> for {{x, y, z}, m} <- Enum.sort(xs), into: <<>>,
      do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, m::16-little>> end
    bytes = <<"VXPD", 3::32-little, length(micro)::32-little, cells.(micro)::binary, 0::32-little,
      0::32-little, length(macros)::32-little, cells.(macros)::binary>>
    File.write!(Path.join([c.root, "prefabs", name <> ".vxpd"]), bytes)
    :ok = World.publish_prefabs(c.w, Path.join(c.root, "prefabs"))
    :crypto.hash(:sha256, bytes)
  end

  # 燃料账：初始化 = 燃烧 + 弃置 + 还原剂消耗 + 行上余量。
  defp assert_fuel_closes(s) do
    left = for {_, row} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(row, :remaining_fuel_j, 0.0))
    assert_in_delta Map.get(s.thermal, :fuel_initialized_j, 0.0),
      Map.get(s.thermal, :combustion_j, 0.0) + Map.get(s.thermal, :discarded_fuel_j, 0.0) +
        Map.get(s.thermal, :transform_reductant_fuel_j, 0.0) + left, 1.0e-3
  end

  # 显热账：全部带温度宏格 C·V·(T−Ta)（散体 V = q / 容量）= 供热 + 环境 − 移除 − 转化吸热。
  defp assert_energy_closes(c, s) do
    sensible = for {_, r} <- s.damage, r.granularity == 0, Map.has_key?(r, :temperature_kelvin), reduce: 0.0 do
      sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] *
        Map.get(s.liquid_units, Damage.macro(r), @cap) / @cap * (r.temperature_kelvin - @ambient)
    end
    ledger = s.thermal.supplied_j + s.thermal.environment_j - Map.get(s.thermal, :removed_j, 0.0) -
      Map.get(s.thermal, :transform_j, 0.0)
    assert_in_delta sensible, ledger, 1.0e-6 * max(1.0, s.thermal.supplied_j)
  end

  defp txn_with(w, from, pred), do: Enum.find(World.entries_after(w, from), &Enum.any?(Map.get(&1, :property_states, []), pred))

  test "catalog: loose threshold is validated, may be added or tuned online, never withdrawn" do
    old = Damage.load(Path.join(@fixtures, @published <> ".json"))
    loose = Damage.load(Path.join(@fixtures, @loose <> ".json"))
    assert Base.encode16(loose.digest, case: :lower) == @loose
    assert loose.materials[@sand]["loose_threshold_units"] == div(@cap * 5, 8)
    assert loose.materials[@ore]["loose_threshold_units"] == div(@cap * 6, 8)
    assert ParameterEvolution.compatible?(old, loose)
    refute ParameterEvolution.compatible?(loose, old)
    tuned = put_in(loose.materials[@sand]["loose_threshold_units"], @quarter)
    assert ParameterEvolution.compatible?(loose, tuned)

    root = Path.join(System.tmp_dir!(), "loose_catalog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    raw = Jason.decode!(File.read!(Path.join(@fixtures, @loose <> ".json")))
    for {id, t} <- [{@water, 0}, {4, 0}, {@sand, @cap + 1}, {@sand, -1}, {32, 0}] do
      bad = Map.update!(raw, "materials", &Enum.map(&1, fn m ->
        if m["material_id"] == id, do: Map.put(m, "loose_threshold_units", t), else: m end))
      path = Path.join(root, "bad.json")
      File.write!(path, Jason.encode!(bad))
      assert_raise MatchError, fn -> Damage.load(path) end
    end
  end

  @tag bounds: {{0, 0, 0}, {2, 1, 3}}
  @tag eye: {1.0, 2.5, 1.5}
  test "repose: a two-cell channel stops strictly above the material threshold and below it plus 8; water keeps its own", c do
    t = c.materials[@sand]["loose_threshold_units"]
    tw = c.data["liquid"]["side_threshold_units"]
    # 沙槽 z=0 与水槽 z=2 之间隔一排石墙，两种材料互不相邻。
    for cell <- [{0, 0, 1}, {1, 0, 1}], do: assert({:ok, _} = build(c, cell, @stone))
    for n <- 1..4 do
      assert {:ok, _} = pour(c, {0, 0, 0})
      assert {:ok, _} = pour(c, {0, 0, 2}, @water)
      settle(c.w)
      q = quantities(c.w)
      {a, b} = {Map.get(q, {0, 0, 0}, 0), Map.get(q, {1, 0, 0}, 0)}
      assert a + b == n * @quarter
      # 3/8 ≤ 5/8 格：未过阈值，不流动；超过后同层差停在 (t, t+8)。
      if n * @quarter <= t, do: assert(b == 0), else: assert(a - b > t and a - b < t + 8)
      {wa, wb} = {Map.get(q, {0, 0, 2}, 0), Map.get(q, {1, 0, 2}, 0)}
      assert wa + wb == n * @quarter
      assert wa - wb > tw and wa - wb < tw + 8
    end
    assert material(c.w, {1, 0, 0}) == @sand and material(c.w, {1, 0, 2}) == @water
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
  end

  @tag bounds: {{0, 0, 0}, {9, 5, 9}}
  test "a column poured at one cell spreads to the rest criterion, conserves quantity and survives a cold restart", c do
    for _ <- 1..12 do
      assert {:ok, _} = pour(c, {4, 3, 4})
      for _ <- 1..5, do: tick(c.w)
    end
    settle(c.w)
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
    q = quantities(c.w)
    t = c.materials[@sand]["loose_threshold_units"]
    assert Enum.sum(Map.values(q)) == 12 * @quarter
    assert balance(c.w, @sand) == 8 * @cap - 12 * @quarter
    assert Enum.all?(q, fn {cell, units} -> units > 0 and units <= @cap and material(c.w, cell) == @sand end)
    assert map_size(q) > 1
    # 静止判据：同层相邻差不超过 t+7；非底层的格下方已满。
    for {{x, y, z}, units} <- q, {dx, dz} <- [{1, 0}, {0, 1}], other = {x + dx, y, z + dz},
        elem(other, 0) < 9 and elem(other, 2) < 9 do
      assert abs(units - Map.get(q, other, 0)) <= t + 7
    end
    for {{x, y, z}, _} <- q, y > 0, do: assert(Map.get(q, {x, y - 1, z}) == @cap)
    payload = VoxelRegion.TestSupport.payload(c.w, 0, {0, 0, 0})
    assert payload.format_version == 12
    assert map_size(payload.liquid_units) == map_size(q)

    before = observe(c.w)
    stop_supervised!(World)
    w = start_supervised!({World, c.opts})
    assert quantities(w) == q
    assert observe(w).damage == before.damage
    settle(w)
    assert quantities(w) == q
  end

  test "sand poured through a macro prefab opening falls; removing the prefab re-settles the pile on top", c do
    slab = for x <- 0..2, z <- 0..2, {x, z} != {1, 1}, do: {{x, 0, z}, @stone}
    id = define(c, "slab", slab)
    {:ok, seq} = World.place_prefab(c.w, id, {8, 8, 8}, 0)
    assert material(c.w, {2, 1, 2}) == 0 and material(c.w, {1, 1, 1}) == @stone
    assert {:ok, _} = pour(c, {2, 1, 2})
    assert {:ok, _} = pour(c, {1, 2, 1})
    assert {:ok, _} = pour(c, {1, 2, 1})
    settle(c.w)
    assert quantities(c.w) == %{{2, 0, 2} => @quarter, {1, 2, 1} => 2 * @quarter}
    assert {:ok, _} = World.remove_prefab(c.w, {seq, 0})
    settle(c.w)
    # 板上的 0.5 m³ 落到地面；两堆对角不相邻，各自低于 5/8 格阈值，不再侧流。
    assert quantities(c.w) == %{{2, 0, 2} => @quarter, {1, 0, 1} => 2 * @quarter}
    assert material(c.w, {1, 2, 1}) == 0
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
  end

  test "refusals: refined cavity, water, outside bounds, another holder's region; loose cells are only scooped", c do
    id = define(c, "micro", [], [{{0, 0, 0}, @stone}])
    {:ok, _} = World.place_prefab(c.w, id, micro({5, 1, 5}), 0)
    assert {:error, :needs_macro_opening} = pour(c, {5, 1, 5})
    assert {:error, :needs_macro_opening} = pour(c, {5, 1, 5}, @water)
    assert {:ok, _} = pour(c, {6, 0, 6}, @water)
    settle(c.w)
    assert material(c.w, {6, 0, 6}) == @water
    assert {:error, :no_liquid_transfer} = pour(c, {6, 0, 6})
    assert {:error, :invalid_liquid_operation} = pour(c, {8, 0, 0})
    assert {:ok, _} = World.author_regions(c.w, [%{holder: {:character, 2002}, min: {0, 6}, max: {1, 7}}])
    assert {:error, :protected_region} = pour(c, {0, 0, 7})
    sand = balance(c.w, @sand)
    assert {:ok, _} = pour(c, {2, 0, 2})
    settle(c.w)
    assert {:error, :use_liquid_tool} = tool(c, {2, 0, 2}, 1)
    assert quantities(c.w)[{2, 0, 2}] == @quarter
    assert {:ok, _} = scoop(c, {2, 0, 2}, @sand)
    assert balance(c.w, @sand) == sand
    assert material(c.w, {2, 0, 2}) == 0 and not Map.has_key?(quantities(c.w), {2, 0, 2})
  end

  test "natural and built sand stay static; only poured sand flows", c do
    {:ok, _} = World.apply_edits(c.w, [{{3, 0, 3}, @sand}, {{3, 1, 3}, @sand}])
    assert {:ok, _} = build(c, {5, 3, 5}, @sand)
    assert {:ok, _} = pour(c, {6, 3, 6})
    {:ok, _} = World.apply_edits(c.w, [{{3, 0, 3}, 0}])
    assert World.liquid_activity(c.w).active_cells > 0
    settle(c.w)
    assert quantities(c.w) == %{{6, 0, 6} => @quarter}
    assert material(c.w, {3, 1, 3}) == @sand and material(c.w, {3, 0, 3}) == 0
    assert material(c.w, {5, 3, 5}) == @sand and material(c.w, {5, 2, 5}) == 0
    assert {:ok, _} = tool(c, {5, 3, 5}, 1)
  end

  test "0.25 m³ poured coal burns a quarter of the per-macro fuel and power; a built block keeps the full amount", c do
    fuel = c.materials[@coal]["fuel_energy_per_macro_j"]
    power = c.materials[@coal]["burn_power_per_macro_w"]
    assert {:ok, _} = pour(c, {2, 0, 2}, @coal)
    assert {:ok, _} = build(c, {5, 0, 5}, @coal)
    settle(c.w)
    from = World.seq(c.w)
    # 每次点燃 3.125 MJ/m³，比热 16380 J/(m³·K)：+190.8 K，第二次越过 673.15 K；与体积无关。
    for _ <- 1..2, cell <- [{2, 0, 2}, {5, 0, 5}], do: assert({:ok, _} = tool(c, cell, 9))
    lit = fn cell -> txn_with(c.w, from, &(&1.micro == micro(cell) and Map.get(&1, :burning, false))) end
    pile = Enum.find(lit.({2, 0, 2}).property_states, &(&1.micro == micro({2, 0, 2})))
    block = Enum.find(lit.({5, 0, 5}).property_states, &(&1.micro == micro({5, 0, 5})))
    assert pile.remaining_fuel_j == fuel / 4 and pile.power_w == power / 4
    assert pile.max_hp == c.materials[@coal]["max_hp_per_macro"] / 4
    assert block.remaining_fuel_j == fuel and block.power_w == power
  end

  @tag :no_heat_damage
  test "a 0.25 m³ ore pile on a full coal block transforms with a quarter of the heat and reductant and keeps its quantity", c do
    ore = c.materials[@ore]
    assert {:ok, _} = build(c, {2, 0, 2}, @coal)
    assert {:ok, _} = pour(c, {2, 1, 2}, @ore)
    settle(c.w)
    heat(c, {2, 1, 2}, 50_000.0, 2.0e7)
    from = World.seq(c.w)
    s = thermal(c.w, &(material_of(&1, {2, 1, 2}) == @copper))
    assert_in_delta s.thermal.transform_j, ore["transform_heat_per_macro_j"] / 4, 1.0e-6
    assert_in_delta s.thermal.transform_reductant_fuel_j,
      ore["transform_reductant_units_per_unit"] / 4 * c.materials[@coal]["fuel_energy_per_macro_j"], 1.0e-3
    assert s.thermal.transform_units == @quarter
    assert s.liquid_units[{2, 1, 2}] == @quarter
    product = Enum.find(txn_with(c.w, from, &(&1.material == @copper and &1.flags == 0)).property_states,
      &(&1.material == @copper))
    assert product.max_hp == c.materials[@copper]["max_hp_per_macro"] / 4
    assert_fuel_closes(s)
    assert_energy_closes(c, s)
    # 产物仍是散体：可以舀回 0.25 m³。
    copper = balance(c.w, @copper)
    assert {:ok, _} = scoop(c, {2, 1, 2}, @copper)
    assert balance(c.w, @copper) == copper + @quarter
  end

  @tag :no_heat_damage
  test "the same ore pile over a 3/4-full coal pit finds no contact and stays ore while hot", c do
    for cell <- [{4, 0, 5}, {6, 0, 5}, {5, 0, 4}, {5, 0, 6}], do: assert({:ok, _} = build(c, cell, @stone))
    for _ <- 1..3, do: assert({:ok, _} = pour(c, {5, 0, 5}, @coal))
    assert {:ok, _} = pour(c, {5, 1, 5}, @ore)
    settle(c.w)
    assert quantities(c.w) == %{{5, 0, 5} => 3 * @quarter, {5, 1, 5} => @quarter}
    heat(c, {5, 1, 5}, 50_000.0, 2.0e7)
    transform = c.materials[@ore]["transform_kelvin"]
    hot = thermal(c.w, &((r = row(&1, {5, 1, 5})) && r.temperature_kelvin >= transform))
    assert material_of(hot, {5, 1, 5}) == @ore
    s = Enum.reduce(1..10, hot, fn _, _ -> send(c.w, :thermal_commit); observe(c.w) end)
    assert material_of(s, {5, 1, 5}) == @ore and Map.get(s.thermal, :transform_j, 0.0) == 0.0
  end

  test "scooping burning coal returns floor(moved × remaining / full fuel) units and books the carried heat and fuel", c do
    for _ <- 1..2, do: assert({:ok, _} = pour(c, {2, 0, 2}, @coal))
    settle(c.w)
    for _ <- 1..2, do: assert({:ok, _} = tool(c, {2, 0, 2}, 9))
    burning = thermal(c.w, &(&1.thermal.combustion_j > 1.0e6))
    assert row(burning, {2, 0, 2}).burning
    units = balance(c.w, @coal)
    from = World.seq(c.w)
    assert {:ok, seq} = scoop(c, {2, 0, 2}, @coal)
    txn = Enum.find(World.entries_after(c.w, from), &(&1.seq == seq))
    prior = World.entries_after(c.w, 0) |> Enum.filter(&(&1.seq < seq and Map.has_key?(&1, :thermal))) |> List.last()
    after_row = Enum.find(txn.property_states, &(&1.micro == micro({2, 0, 2})))
    fuel = c.materials[@coal]["fuel_energy_per_macro_j"]
    # 舀走一半：剩余燃料按比例留一半，入库单位按舀取前剩余比例向下取整。
    remaining_before = after_row.remaining_fuel_j * 2
    assert balance(c.w, @coal) == units + floor(@quarter * remaining_before / (fuel / 2))
    assert balance(c.w, @coal) < units + @quarter
    assert after_row.burning and after_row.power_w == c.materials[@coal]["burn_power_per_macro_w"] / 4
    assert after_row.max_hp == c.materials[@coal]["max_hp_per_macro"] / 4
    assert_in_delta txn.thermal.discarded_fuel_j - Map.get(prior.thermal, :discarded_fuel_j, 0.0),
      after_row.remaining_fuel_j, 1.0e-3
    assert_in_delta txn.thermal.removed_j - Map.get(prior.thermal, :removed_j, 0.0),
      c.materials[@coal]["heat_capacity_per_macro"] / 4 * (after_row.temperature_kelvin - @ambient), 1.0e-3
    s = observe(c.w)
    assert s.liquid_units[{2, 0, 2}] == @quarter
    assert_fuel_closes(s)
    assert_energy_closes(c, s)
  end

  test "coal poured onto a burning pile carries the fire when it flows; power follows each cell's volume", c do
    for _ <- 1..2, do: assert({:ok, _} = pour(c, {2, 0, 2}, @coal))
    settle(c.w)
    for _ <- 1..2, do: assert({:ok, _} = tool(c, {2, 0, 2}, 9))
    assert row(observe(c.w), {2, 0, 2}).burning
    # 再倒 0.5 m³ 到燃烧格：满 1 m³ 超过 5/8 格阈值，向四邻侧流，流出的煤带着火与已烧比例。
    for _ <- 1..2, do: assert({:ok, _} = pour(c, {2, 0, 2}, @coal))
    settle(c.w)
    s = observe(c.w)
    assert Enum.sum(Map.values(s.liquid_units)) == @cap
    assert map_size(s.liquid_units) == 5
    power = c.materials[@coal]["burn_power_per_macro_w"]
    for {cell, q} <- s.liquid_units do
      r = row(s, cell)
      assert r.burning
      assert_in_delta r.power_w, power * q / @cap, 1.0e-6
      assert_in_delta r.max_hp, c.materials[@coal]["max_hp_per_macro"] * q / @cap, 1.0e-9
    end
    assert_fuel_closes(s)
    assert_energy_closes(c, s)
  end

  defp material_of(s, cell), do: (r = row(s, cell)) && r.material
end
