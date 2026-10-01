defmodule VoxelRegion.ThermoelectricFurnaceSimTest do
  @moduledoc """
  只测试（:sim，默认排除）：R8-09 片 1——散体煤炉膛温差发电的布局模拟，为片 2 双端 `furnace_generator` 定布局。

  炉膛（z = 2 一行，地面 y = 0 石；x 相对炉膛 X = 3）：
      x:  0 冷铜 Bc | 1 热电石 TEb | 2 热铜 Bh | 3 炉膛（空，倒煤）| 4 热铜 Ah | 5 热电石 TEa | 6 冷铜 Ac
  炉膛前后 (3,1,1)(3,1,3) 石、底是地面石、顶 (3,2,2) 是 1 m 开口；煤从开口倒入（每次 0.25 m³），K 从正上方点燃。
  双壁串联回路：Ah→TEa→Ac→(6,1,1)→z = 0 铜链 (6..2,1,0)→合金桥 L2 (2,1,1)→Bh→TEb→Bc→(0,1,3)→z = 4 铜链 (0..4,1,4)
  →合金灯 L1 (4,1,3)→Ah（冷热跨接都经合金，k 25；铜链直连会把冷热短路）。
  单壁：Bh 换成石墙，回路 Ah→TEa→Ac→(6,1,3)→z = 4 铜链 (6..4,1,4)→L1→Ah。
  冰：作者供料一次（记账，带作者焓）后用正式建造放整格冰在冷铜顶上 (0,2,2)／(6,2,2)（冰不是可倾倒的流动材料）。

  目录 = b88329ab（发布 249f2442 + 玻璃；含散体字段与热电石 43：S 0.05、σ 2、k 15、耐热 1400 K），液体步长改手动投递；
  热环境 = 生产值（ε 0.9、h 10 W/m²K、视距 8，`fixtures/combustion/environment-radiation.json` 与 Voxim 资产同值）。
  每个变体一个新 World；每 0.5 s 一笔热提交；每笔核对显热账与佩尔捷分项（与 thermoelectric_world_test 同式）。
  运行：`mix test --no-start --only sim test/thermoelectric_furnace_sim_test.exs`。每个变体一行 `sim variant=…` 汇总。
  """
  use ExUnit.Case, async: false
  @moduletag :sim
  @moduletag timeout: :infinity
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @catalog "b88329ab0d3652c30f67d012fce04fd30afd7fd6dcc263e5066ba0b08f90284f"
  @cap 2_097_152
  @quarter div(@cap, 4)
  @stone 11
  @coal 15
  @ice 20
  @copper 24
  @alloy 40
  @te 43
  @ambient 293.15
  @box {{-2, -2, -2}, {2, 2, 2}}
  @bounds {{-3, 0, -1}, {10, 6, 6}}
  @limit_s 9000.0
  @roles %{coal: {3, 1, 2}, top: {3, 2, 2}, ah2: {4, 2, 2}, bh: {2, 1, 2}, ah: {4, 1, 2}, teb: {1, 1, 2}, tea: {5, 1, 2}, bc: {0, 1, 2}, ac: {6, 1, 2},
    l1: {4, 1, 3}, l2: {2, 1, 1}, wall: {3, 1, 3}, floor: {3, 0, 2}, ice_a: {6, 2, 2}, ice_b: {0, 2, 2}}

  # 变体：walls 1／2；coal 初装 0.25 m³ 份数；refuel {到点模拟秒, 份数}；ice 每块冷板顶上整格冰数（0／1）；lid 点燃后盖石。
  @variants [
    %{name: "double-1.0", walls: 2, coal: 4, refuel: nil, ice: 0, lid: false},
    %{name: "double-0.5", walls: 2, coal: 2, refuel: nil, ice: 0, lid: false},
    %{name: "single-1.0", walls: 1, coal: 4, refuel: nil, ice: 0, lid: false},
    %{name: "double-1.0-ice", walls: 2, coal: 4, refuel: nil, ice: 1, lid: false},
    %{name: "double-0.5+0.5", walls: 2, coal: 2, refuel: {600.0, 2}, ice: 0, lid: false},
    %{name: "double-1.0-lid", walls: 2, coal: 4, refuel: nil, ice: 0, lid: true},
    %{name: "deep-stone-2.0", walls: 2, coal: 8, refuel: nil, ice: 0, lid: false, depth: 2, upper: @stone},
    %{name: "deep-copper-2.0", walls: 2, coal: 8, refuel: nil, ice: 0, lid: false, depth: 2, upper: @copper},
    %{name: "deep-copper-1.0+1.0", walls: 2, coal: 4, refuel: {600.0, 4}, ice: 0, lid: false, depth: 2, upper: @copper},
    %{name: "deep-copper-1.0+1.0-ice", walls: 2, coal: 4, refuel: {600.0, 4}, ice: 1, lid: false, depth: 2, upper: @copper},
    %{name: "deep-copper-1.0+1.0-fins", walls: 2, coal: 4, refuel: {600.0, 4}, ice: 0, lid: false, depth: 2, upper: @copper,
      fins: true},
    %{name: "double-1.0-lid-fins", walls: 2, coal: 4, refuel: nil, ice: 0, lid: true, fins: true},
    %{name: "double-0.5+0.5-lid-fins", walls: 2, coal: 2, refuel: {600.0, 2}, ice: 0, lid: true, fins: true}
  ]

  for v <- @variants do
    @v v
    test "thermoelectric furnace #{v.name}" do
      simulate(@v)
    end
  end

  defp simulate(v) do
    root = Path.join(System.tmp_dir!(), "te_furnace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json"))) |> put_in(["liquid", "step_seconds"], 3600)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [@stone, @coal, @ice, @copper, @alloy, @te], liquid_bounds: @bounds]})
    actor = %{cid: 1001, gate: self(), identity: :furnace, refresh: &Actor.tool_context/2, eye: {3.5, 4.5, 2.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    c = %{w: w, actor: actor, materials: materials, v: v}

    v = Map.merge(%{depth: 1, upper: @stone, fins: false}, v)
    c = %{c | v: v}
    opening = {3, v.depth + 1, 2}
    {:ok, _} = World.apply_edits(w, layout(v.walls) ++ upper(v) ++ fins(v))
    coal_units = (v.coal + if(v.refuel, do: elem(v.refuel, 1), else: 0)) * @quarter + @cap
    supply = %{@coal => coal_units, @stone => @cap}
    supply = if v.ice > 0, do: Map.put(supply, @ice, v.ice * v.walls * @cap), else: supply
    {:ok, _} = World.material_supply(w, 1001, "te-furnace", supply)
    for {_, cell} <- Enum.take([a: {6, 2, 2}, b: {0, 2, 2}], v.walls), _ <- List.duplicate(1, v.ice),
      do: {:ok, _} = intent(c, 1, @ice, cell, 1)
    for _ <- 1..v.coal, do: ({:ok, _} = intent(c, 3, @coal, opening, 12); settle(w))
    q = World.simulation_snapshot(w, [1001], @box).liquid_quantities
    # K 命中的是最上面一格煤：其体积决定点燃热（散体体积 = 数量 / 容量）。
    top = Enum.max_by(for({{3, y, 2}, u} <- q, u > 0, do: {y, u}), &elem(&1, 0))
    cavity = elem(top, 1) / @cap
    IO.puts("sim #{v.name} charge cells=#{inspect(for {{3, y, 2}, u} <- Enum.sort(q), do: {y, u / @cap})}")
    clicks = ignite(c, 0)
    # K 每次把 heat_energy_j × 目标体积直接记入供热（工具 9 目录值；散体体积 = 数量 / 容量）。
    k = Enum.find(data["tools"], &(&1["tool_id"] == 9))
    c = Map.put(c, :ignition, clicks * k["heat_energy_j"] * cavity)
    if v.lid, do: {:ok, _} = intent(c, 1, @stone, opening, 1)
    s0 = observe(w)
    started = System.monotonic_time(:millisecond)
    r = loop(c, s0, %{peak: %{}, emf_peak: 0.0, power_peak: 0.0, i_peak: 0.0, first: nil, last_burning: 0.0,
      gen_above: nil, refueled: false, ice_gone: %{}, commits: 0, samples: []})
    wall = System.monotonic_time(:millisecond) - started
    s = r.state
    te = ledger(s, :circuit_thermoelectric_j)
    coal_m3 = coal_units / @cap - 1
    peak = Map.new(r.peak, fn {k, t} -> {k, round(t)} end)
    hp = for k <- [:tea, :teb, :ah, :bh], row = cell(s, @roles[k]), into: %{}, do: {k, row && Float.round(row.hp / row.max_hp, 3)}
    IO.puts("sim variant=#{v.name} walls=#{v.walls} coal_m3=#{coal_m3} ice_m3_per_plate=#{v.ice / 4} lid=#{v.lid} clicks=#{clicks} " <>
      "sim_s=#{s.thermal.elapsed_s} commits=#{r.commits} wall_ms=#{wall} emf_peak_v=#{Float.round(r.emf_peak, 2)} " <>
      "i_peak_a=#{Float.round(r.i_peak, 2)} p_peak_w=#{Float.round(r.power_peak, 1)} gen_s(P>10%peak)=#{gen_span(r)} " <>
      "burn_end_s=#{r.last_burning} te_mj=#{Float.round(te / 1.0e6, 3)} te_mj_per_m3_coal=#{Float.round(te / 1.0e6 / coal_m3, 3)} " <>
      "light_mj=#{Float.round(ledger(s, :circuit_light_j) / 1.0e6, 3)} combustion_mj=#{Float.round(ledger(s, :combustion_j) / 1.0e6, 1)} " <>
      "te_over_combustion=#{Float.round(te / max(1.0, ledger(s, :combustion_j)), 5)} discarded_fuel_mj=#{Float.round(ledger(s, :discarded_fuel_j) / 1.0e6, 1)} " <>
      "peak_k=#{inspect(peak)} hp=#{inspect(hp)} ice_gone_s=#{inspect(r.ice_gone)}")
    IO.puts("sim #{v.name} curve(t_s,emf_v,i_a,coal_k,ah_k,ac_k)=#{inspect(Enum.reverse(r.samples))}")
    # 耐热：热电石 1400 K、铜 1800 K 以内且完整；煤不过 2273 K 热毁（无弃置燃料）。
    assert Enum.max([0 | for(k <- [:tea, :teb], Map.has_key?(peak, k), do: peak[k])]) < materials[@te]["heat_resistance_kelvin"]
    assert Enum.max([0 | for(k <- [:ah, :bh, :ah2], Map.has_key?(peak, k), do: peak[k])]) < materials[@copper]["heat_resistance_kelvin"]
    assert Enum.all?(Map.values(hp), &(&1 == 1.0))
    assert ledger(s, :discarded_fuel_j) == 0.0
  end

  defp layout(walls) do
    ground = for x <- -2..8, z <- 0..4, do: {{x, 0, z}, @stone}
    common = [{{4, 1, 2}, @copper}, {{5, 1, 2}, @te}, {{6, 1, 2}, @copper}, {{3, 1, 1}, @stone}, {{3, 1, 3}, @stone},
      {{4, 1, 3}, @alloy}]
    if walls == 2 do
      ground ++ common ++ [{{0, 1, 2}, @copper}, {{1, 1, 2}, @te}, {{2, 1, 2}, @copper}, {{6, 1, 1}, @copper}, {{2, 1, 1}, @alloy},
        {{0, 1, 3}, @copper}] ++ for(x <- 2..6, do: {{x, 1, 0}, @copper}) ++ for(x <- 0..4, do: {{x, 1, 4}, @copper})
    else
      ground ++ common ++ [{{2, 1, 2}, @stone}, {{6, 1, 3}, @copper}] ++ for(x <- 4..6, do: {{x, 1, 4}, @copper})
    end
  end

  # 深炉膛（depth 2）：第二层炉膛 (3,2,2) 前后石墙，两侧上层墙为石或铜（铜与下层热铜同一电极，只多收热，不另接热电石）。
  defp upper(%{depth: 1}), do: []
  defp upper(v), do: [{{3, 2, 1}, @stone}, {{3, 2, 3}, @stone}, {{4, 2, 2}, v.upper}] ++
    if(v.walls == 2, do: [{{2, 2, 2}, v.upper}], else: [{{2, 2, 2}, @stone}])

  # 冷端散热片：冷铜外侧与上方各接铜格（同一电极的死端，不进回路），只加大冷端向环境散热的外露面。
  # 有冰的变体不加散热片（冰占冷铜顶上那格）。
  defp fins(%{fins: false}), do: []
  defp fins(v) do
    a = [{{7, 1, 2}, @copper}, {{8, 1, 2}, @copper}, {{7, 2, 2}, @copper}, {{6, 2, 2}, @copper}, {{7, 1, 3}, @copper}, {{7, 1, 1}, @copper}]
    b = [{{-1, 1, 2}, @copper}, {{-2, 1, 2}, @copper}, {{-1, 2, 2}, @copper}, {{0, 2, 2}, @copper}, {{-1, 1, 3}, @copper}, {{-1, 1, 1}, @copper}]
    if v.walls == 2, do: a ++ b, else: a
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)

  defp intent(c, action, material, coord, tool) do
    seq = next()
    World.production_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material,
        tool_id: tool, coord: coord})
  end

  defp tick(w), do: (send(w, :liquid_commit); World.seq(w))
  defp settle(w), do: (tick(w); if(World.liquid_activity(w).active_cells > 0, do: settle(w), else: :ok))

  # K：从开口正上方竖直向下命中炉膛里最上面的煤，点到燃烧为止。
  defp ignite(c, n) do
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 9,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, c.actor, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    case World.tool_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}), request) do
      {:ok, _} -> ignite(c, n + 1)
      {:error, :already_burning} -> n
    end
  end

  # 镐（工具 1）从正上方竖直向下敲开盖，直到命中的不再是盖格。
  defp pick(c, {x, y, z} = lid, n) do
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 1,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, c.actor, query)
    {tx, ty, tz} = target.micro
    if {div(tx, 8), div(ty, 8), div(tz, 8)} == {x, y, z} and target.material == @stone do
      seq = next()
      request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
        |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
      {:ok, _} = World.tool_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}), request)
      pick(c, lid, n + 1)
    else
      n
    end
  end

  defp sensible(c, s) do
    for {_, r} <- s.damage, r.granularity == 0, Map.has_key?(r, :temperature_kelvin), not Map.has_key?(r, :phase_energy_j),
      reduce: 0.0,
      do: (sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] *
        Map.get(s.liquid_units, VoxelRegion.Damage.macro(r), @cap) / @cap * (r.temperature_kelvin - @ambient))
  end

  defp phase_energy(s), do: Enum.sum([0.0 | for({_, r} <- s.damage, Map.has_key?(r, :phase_energy_j), do: r.phase_energy_j)]) +
    Enum.sum([0.0 | for({_, {e, _}} <- s.phase_inventory, do: e)])

  # 每笔提交核对：显热 + 相态焓 − 作者焓 = 供热 + 环境 + 重标 − 移除 − 转化；供热 = 燃烧 + 电路净热；吸热 − 放热 = 做功。
  defp check(c, s) do
    supplied = ledger(s, :supplied_j)
    scale = max(1.0, supplied)
    book = supplied + ledger(s, :environment_j) + ledger(s, :parameter_rebase_j) - ledger(s, :removed_j) - ledger(s, :transform_j)
    assert_in_delta sensible(c, s) + phase_energy(s) - ledger(s, :phase_authored_energy_j), book, 1.0e-6 * scale
    circuit = ledger(s, :circuit_supplied_j) - ledger(s, :circuit_charged_j) - ledger(s, :circuit_light_j)
    assert_in_delta supplied - ledger(s, :combustion_j) - c.ignition, circuit, 1.0e-6 * scale
    te = ledger(s, :circuit_thermoelectric_j)
    assert_in_delta ledger(s, :circuit_peltier_absorbed_j) - ledger(s, :circuit_peltier_released_j), te, 1.0e-6 * max(1.0, te)
  end

  defp loop(c, _prev, acc) do
    send(c.w, :thermal_commit)
    s = observe(c.w)
    check(c, s)
    t = s.thermal.elapsed_s
    temps = for {k, p} <- @roles, row = cell(s, p), Map.has_key?(row, :temperature_kelvin), into: %{}, do: {k, row.temperature_kelvin}
    tes = for k <- [:tea, :teb], row = cell(s, @roles[k]), row != nil, do: row
    emf = Enum.sum([0.0 | for(r <- tes, do: Map.get(r, :source_emf_v, 0.0))])
    i = Map.get(cell(s, @roles.tea) || %{}, :source_current_a, 0.0)
    power = emf * i
    burning = Enum.any?(Map.values(s.damage), &Map.get(&1, :burning, false))
    ice_gone = for {k, p} <- [ice_a: @roles.ice_a, ice_b: @roles.ice_b], c.v.ice > 0, not Map.has_key?(acc.ice_gone, k),
      not ice?(c, s, p), into: acc.ice_gone, do: {k, t}
    acc = %{acc | peak: Map.merge(acc.peak, temps, fn _, a, b -> max(a, b) end), emf_peak: max(acc.emf_peak, emf),
      i_peak: max(acc.i_peak, i), power_peak: max(acc.power_peak, power), commits: acc.commits + 1,
      first: acc.first || (if i > 0, do: t), last_burning: if(burning, do: t, else: acc.last_burning), ice_gone: ice_gone,
      gen_above: if(power > 0.1 * acc.power_peak and acc.power_peak > 0, do: t, else: acc.gen_above),
      samples: if(rem(acc.commits, 200) == 0,
        do: [{round(t), Float.round(emf, 2), Float.round(i, 2), round(Map.get(temps, :coal, 0.0)), round(Map.get(temps, :ah, 0.0)),
          round(Map.get(temps, :ac, 0.0))} | acc.samples], else: acc.samples)}
    acc =
      case c.v.refuel do
        {at, n} when not acc.refueled and t >= at ->
          # 有盖：先用镐挖开盖（正式工具），倒煤，再盖回。
          hits = if c.v.lid, do: pick(c, {3, c.v.depth + 1, 2}, 0), else: 0
          for _ <- 1..n, do: ({:ok, _} = intent(c, 3, @coal, {3, c.v.depth + 1, 2}, 12); settle(c.w))
          if c.v.lid, do: {:ok, _} = intent(c, 1, @stone, {3, c.v.depth + 1, 2}, 1)
          IO.puts("sim #{c.v.name} lid_hits=#{hits}")
          q = observe(c.w).liquid_units
          IO.puts("sim #{c.v.name} refuel at_s=#{t} burning=#{burning} emf=#{emf} cells=#{inspect(for {{3, y, 2}, u} <- Enum.sort(q), do: {y, u / @cap})}")
          %{acc | refueled: true}
        _ -> acc
      end
    done = (not burning and acc.power_peak > 0 and power < 0.05 * acc.power_peak) or t >= @limit_s or not s.thermal.active
    if done, do: Map.put(acc, :state, s), else: loop(c, s, acc)
  end

  defp ice?(c, _s, p), do: hd(World.material_snapshot(c.w, [], [p]).probe_occupancy).material == @ice

  defp gen_span(%{first: nil}), do: 0
  defp gen_span(r), do: (r.gen_above || r.first) - r.first
end
