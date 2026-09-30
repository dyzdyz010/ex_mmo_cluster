defmodule VoxelRegion.SandGlassWorldTest do
  @moduledoc """
  只测试：R8-08 单向热转化首例 Sand 5 → Glass 44（无还原剂，只靠温度）经真实 World 意图、热提交、几何事务与冷恢复。

  目录 = `test/fixtures/combustion/b88329ab…`：在 UE 发布 `249f2442…` 字节上按 UE 发布器的字段顺序与数字格式追加
  Glass 44 行（C 21000 J/(m³K)、k 10、耐热 1600 K、散体 6/8 格），并给 Sand 加转化字段（1373.15 K、1 MJ/m³，无还原剂）、
  耐热 1000 → 1600 K；编辑器发布该资产须得到同一摘要（待编辑器）。本模块只把液体步长改成 3600 s，数量步只由测试手动投递。
  材料只经 material_supply（一次、记账）；地形只经玩家倾倒／建造；热只经 Test-only 热源实验；时间只经 :liquid_commit / :thermal_commit。
  期望来自目录算术（体积、反应热、热容之比）与账目恒等式，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :transform
  alias VoxelRegion.{World, Damage, ParameterEvolution}
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @catalog "b88329ab0d3652c30f67d012fce04fd30afd7fd6dcc263e5066ba0b08f90284f"
  @published "249f2442c082edaf95cb0610b60661d5539a72caa5ca0b4fd594632c84eb4839"
  @cap 2_097_152
  @quarter div(@cap, 4)
  @sand 5
  @stone 11
  @glass 44
  @ambient 293.15
  @x 1373.15
  @heat 1.0e6
  @c_sand 18_333
  @c_glass 21_000
  @box {{-1, -1, -1}, {10, 10, 10}}

  setup do
    root = Path.join(System.tmp_dir!(), "glass_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json")))
    data = put_in(data, ["liquid", "step_seconds"], 3600)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment.json"), env)
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [@sand, @stone, @glass], liquid_bounds: {{0, 0, 0}, {8, 8, 8}}]
    w = start_supervised!({World, opts})
    actor = %{cid: 1001, gate: self(), identity: :glass, refresh: &Actor.tool_context/2,
      eye: {4.5, 6.5, 4.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    {:ok, _} = World.material_supply(w, 1001, "glass-scenario", %{@sand => 4 * @cap, @stone => 4 * @cap})
    %{w: w, opts: opts, actor: actor, root: root, materials: Map.new(data["materials"], &{&1["material_id"], &1})}
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp intent(c, action, material, coord, tool) do
    seq = next()
    World.production_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material,
        tool_id: tool, coord: coord})
  end

  defp pour(c, coord), do: intent(c, 3, @sand, coord, 12)
  defp scoop(c, coord, material), do: intent(c, 2, material, coord, 11)
  defp build(c, coord, material), do: intent(c, 1, material, coord, 1)

  defp settle(w, left \\ 2000) do
    send(w, :liquid_commit)
    cond do
      World.liquid_activity(w).active_cells == 0 -> :ok
      left == 0 -> flunk("loose cells did not come to rest")
      true -> settle(w, left - 1)
    end
  end

  # 从正上方瞄准一个宏格：先查询权威命中身份，再以同一身份执行。
  defp tool(c, cell, tool_id) do
    {x, _, z} = cell
    :ok = GenServer.call(c.actor.player, {:eye, {x + 0.5, 6.5, z + 0.5}})
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: tool_id,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, c.actor, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    World.tool_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}), request)
  end

  defp heat(c, cell, power, energy) do
    path = Path.join(c.root, "thermal.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(cell),
      ambient_kelvin: @ambient, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0,
      view_range_cells: 8, power_w: power, energy_j: energy}))
    :ok = World.thermal_experiment(c.w, path)
  end

  defp thermal(w, stop?, left \\ 6000) do
    send(w, :thermal_commit)
    s = observe(w)
    cond do
      stop?.(s) -> s
      left == 0 -> flunk("thermal condition not reached; elapsed #{s.thermal.elapsed_s}")
      true -> thermal(w, stop?, left - 1)
    end
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp micro({x, y, z}), do: {x * 8, y * 8, z * 8}
  defp row(s, cell), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == micro(cell)))
  defp material_of(s, cell), do: (r = row(s, cell)) && r.material
  defp balance(w, m), do: Enum.find(World.material_balances(w, 1001), &(&1.material == m)).balance
  defp glass_txn(w, from), do: Enum.find(World.entries_after(w, from),
    &Enum.any?(Map.get(&1, :property_states, []), fn t -> t.material == @glass and t.flags == 0 end))

  # 转化前最后一笔提交里的沙温 T（转化在同一次热回调里紧随其后）。
  defp sand_before(w, txn, cell) do
    [previous] = World.entries_after(w, txn.seq - 2) |> Enum.take(1)
    Enum.find(previous.property_states, &(&1.material == @sand and &1.micro == micro(cell))).temperature_kelvin
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

  test "catalog: sand melts to glass without a reductant; the reductant pair stays grouped; old worlds upgrade online", c do
    old = Damage.load(Path.join(@fixtures, @published <> ".json"))
    new = Damage.load(Path.join(@fixtures, @catalog <> ".json"))
    assert Base.encode16(new.digest, case: :lower) == @catalog
    assert Map.take(new.materials[@sand], ~w(transform_material_id transform_kelvin transform_heat_per_macro_j heat_resistance_kelvin)) ==
      %{"transform_material_id" => @glass, "transform_kelvin" => @x, "transform_heat_per_macro_j" => @heat,
        "heat_resistance_kelvin" => 1600}
    refute Enum.any?(Map.keys(new.materials[@glass]), &String.starts_with?(&1, "transform_"))
    assert ParameterEvolution.compatible?(old, new)
    refute ParameterEvolution.compatible?(new, old)

    raw = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json")))
    path = Path.join(c.root, "bad.json")
    bad = fn fields ->
      File.write!(path, Jason.encode!(Map.update!(raw, "materials", &Enum.map(&1, fn m ->
        if m["material_id"] == @sand, do: fields.(m), else: m end))))
      path
    end
    # 还原剂只写一半：缺比例 / 缺还原剂；缺反应热；还原剂不可燃。
    assert_raise MatchError, fn -> Damage.load(bad.(&Map.put(&1, "transform_reductant_material_id", 15))) end
    assert_raise KeyError, fn -> Damage.load(bad.(&Map.put(&1, "transform_reductant_units_per_unit", 0.25))) end
    assert_raise MatchError, fn -> Damage.load(bad.(&Map.delete(&1, "transform_heat_per_macro_j"))) end
    assert_raise MatchError, fn -> Damage.load(bad.(&Map.merge(&1, %{"transform_reductant_material_id" => @stone,
      "transform_reductant_units_per_unit" => 0.25}))) end
  end

  test "a 0.25 m³ poured sand pile melts once into 0.25 m³ glass: heat, quantity, integrity, no fuel; irreversible; cold restart; scooped back", c do
    assert {:ok, _} = pour(c, {2, 0, 2})
    settle(c.w)
    assert observe(c.w).liquid_units == %{{2, 0, 2} => @quarter}
    # 热源总能量按绝热上限定：0.25 m³ 全部吸收也只到 Ta + (7 MJ − 0.25 MJ)/(21000 × 0.25) = 1579 K < 耐热 1600 K。
    heat(c, {2, 0, 2}, 200_000.0, 7.0e6)
    from = World.seq(c.w)
    s = thermal(c.w, &(material_of(&1, {2, 0, 2}) == @glass))

    # 有限投入：0.25 m³ 沙 = 524 288 量子换成等量玻璃；反应热 1 MJ/m³ × 0.25 m³；不找、不扣还原剂燃料。
    assert s.thermal.transform_units == @quarter
    assert s.liquid_units[{2, 0, 2}] == @quarter
    assert_in_delta s.thermal.transform_j, @heat / 4, 1.0e-9
    assert Map.get(s.thermal, :transform_reductant_fuel_j, 0.0) == 0.0
    assert Map.get(s.thermal, :fuel_initialized_j, 0.0) == 0.0
    assert_energy_closes(c, s)

    # 焓口径：玻璃温度 = Ta + (C沙(T−Ta) − H)/C玻璃，体积约去；T 是转化前一笔提交里的沙温。
    txn = glass_txn(c.w, from)
    t = sand_before(c.w, txn, {2, 0, 2})
    assert t >= @x
    glass = Enum.find(txn.property_states, &(&1.material == @glass))
    assert Enum.any?(txn.property_states, &(&1.material == @sand and &1.flags == 1))
    assert_in_delta glass.temperature_kelvin, @ambient + (@c_sand * (t - @ambient) - @heat) / @c_glass, 1.0e-9
    # 完整度：未受损的 0.25 m³ 沙 → 玻璃 HP 满（最大 HP 按体积 100 × 0.25）。
    assert glass.max_hp == 25.0 and glass.hp == glass.max_hp

    # 不可逆：热源耗尽后冷却到静止仍是玻璃，只转化一次，账仍闭合。
    settled = thermal(c.w, &(not &1.thermal.active), 20_000)
    assert material_of(settled, {2, 0, 2}) == @glass
    assert row(settled, {2, 0, 2}).temperature_kelvin < @x
    assert settled.thermal.transform_units == @quarter
    assert_energy_closes(c, settled)

    # 冷恢复：同一根目录重启 World，属性行、热账与数量逐项相同。
    stop_supervised!(World)
    w = start_supervised!({World, c.opts})
    restored = observe(w)
    assert restored.damage == settled.damage
    assert restored.thermal == settled.thermal
    assert restored.liquid_units == settled.liquid_units
    assert hd(World.material_snapshot(w, [], [{2, 0, 2}]).probe_occupancy).material == @glass

    # 产物仍是散体数量：舀回 0.25 m³ 玻璃，格清空。
    c = %{c | w: w}
    assert balance(w, @glass) == 0
    assert {:ok, _} = scoop(c, {2, 0, 2}, @glass)
    assert balance(w, @glass) == @quarter
    assert observe(w).liquid_units == %{}
  end

  test "a damaged built sand block melts into a full glass block with the same HP fraction and no quantity record", c do
    assert {:ok, _} = build(c, {5, 0, 5}, @sand)
    assert {:ok, _} = tool(c, {5, 0, 5}, 1)
    hit = row(observe(c.w), {5, 0, 5})
    assert hit.material == @sand and hit.hp > 0 and hit.hp < hit.max_hp
    # 绝热上限 Ta + (27 MJ − 1 MJ)/21000 = 1531 K < 1600 K；到 X 至少需 18333 × 1080 = 19.8 MJ。
    heat(c, {5, 0, 5}, 400_000.0, 2.7e7)
    s = thermal(c.w, &(material_of(&1, {5, 0, 5}) == @glass))
    glass = row(s, {5, 0, 5})
    assert glass.max_hp == c.materials[@glass]["max_hp_per_macro"]
    assert_in_delta glass.hp / glass.max_hp, hit.hp / hit.max_hp, 1.0e-12
    assert s.thermal.transform_units == @cap
    assert_in_delta s.thermal.transform_j, @heat, 1.0e-9
    assert s.liquid_units == %{}
    assert_energy_closes(c, s)
  end
end
