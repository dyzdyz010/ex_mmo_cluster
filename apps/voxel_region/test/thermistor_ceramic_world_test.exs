defmodule VoxelRegion.ThermistorCeramicWorldTest do
  @moduledoc """
  只测试：R8-10 温敏陶瓷 45（Voxim Docs/R8/plan.md §R8-10；方案 = 大理石 14 接触煤 15 于 1373.15 K 烧成）。

  目录 = `test/fixtures/combustion/b4d8bf35…`：在 `b88329ab…` 字节上按 UE 发布器的字段顺序与 `%.17g` 数字格式追加
  Thermistor Ceramic 45 行（σ 10 S/m、截止 373.15 K、C 25000 J/(m³K)、k 25、耐热 1600 K、密度 5700、散体 6/8 格；
  HP／防御／伤害响应同大理石），并给大理石加散体 6/8 格与转化字段（→ 45、1373.15 K、1 MJ/m³、还原剂煤 0.25）。
  最终以客户端编辑器发布字节为准（合并时核对替换）；本模块只把液体步长改成 3600 s，数量步只由测试手动投递。

  材料只经 material_supply（一次、记账）；地形只经玩家倾倒／建造；热只经 Test-only 热源实验（ε 0、h 10，单次）；
  时间只经 :liquid_commit / :thermal_commit。温控回路是纯函数求解（Circuit.prepare/plan），输入按纯函数直接构造，
  目录行取自同一夹具。期望来自目录算术与手算（r = d/(σA)、体积、反应热、热容之比）与账目恒等式，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :transform
  alias VoxelRegion.{World, Damage, ParameterEvolution, Circuit}
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @catalog "b4d8bf35d98ca527df900e049878795ffc6428f51a71f7a14ca2b0a55158607f"
  @previous "b88329ab0d3652c30f67d012fce04fd30afd7fd6dcc263e5066ba0b08f90284f"
  @qinglan "249f2442c082edaf95cb0610b60661d5539a72caa5ca0b4fd594632c84eb4839"
  @cap 2_097_152
  @quarter div(@cap, 4)
  @stone 11
  @marble 14
  @coal 15
  @copper 24
  @alloy 40
  @battery 42
  @thermistor 45
  @ambient 293.15
  @x 1373.15
  @heat 1.0e6
  @ratio 0.25
  @c_marble 23_430
  @c_thermistor 25_000
  @coal_fuel 8.0e8
  @cutoff 373.15
  @box {{-1, -1, -1}, {10, 10, 10}}

  setup do
    root = Path.join(System.tmp_dir!(), "thermistor_#{System.pid()}_#{System.unique_integer([:positive])}")
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
      production_materials: [@stone, @marble, @coal, @thermistor], liquid_bounds: {{0, 0, 0}, {8, 8, 8}}]
    %{opts: opts, root: root, materials: Map.new(data["materials"], &{&1["material_id"], &1})}
  end

  defp start(c) do
    w = start_supervised!({World, c.opts})
    actor = %{cid: 1001, gate: self(), identity: :thermistor, refresh: &Actor.tool_context/2,
      eye: {4.5, 6.5, 4.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    {:ok, _} = World.material_supply(w, 1001, "thermistor-scenario", %{@marble => 4 * @cap, @coal => 4 * @cap})
    Map.merge(c, %{w: w, actor: actor})
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp intent(c, action, material, coord, tool) do
    seq = next()
    World.production_intent(c.w, Map.merge(c.actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material,
        tool_id: tool, coord: coord})
  end

  defp pour(c, coord), do: intent(c, 3, @marble, coord, 12)
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

  defp heat(c, cell, power, energy) do
    path = Path.join(c.root, "thermal.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(cell),
      ambient_kelvin: @ambient, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0,
      view_range_cells: 8, power_w: power, energy_j: energy}))
    :ok = World.thermal_experiment(c.w, path)
  end

  defp thermal(w, stop?, left \\ 8000) do
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
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)

  defp product_txn(w, from), do: Enum.find(World.entries_after(w, from),
    &Enum.any?(Map.get(&1, :property_states, []), fn t -> t.material == @thermistor and t.flags == 0 end))

  # 转化前最后一笔提交里的大理石温度 T（转化在同一次热回调里紧随其后）。
  defp marble_before(w, txn, cell) do
    [previous] = World.entries_after(w, txn.seq - 2) |> Enum.take(1)
    Enum.find(previous.property_states, &(&1.material == @marble and &1.micro == micro(cell))).temperature_kelvin
  end

  # 显热账：全部带温度宏格 C·V·(T−Ta)（散体 V = q / 容量）= 供热 + 环境 − 移除 − 转化吸热。
  defp assert_energy_closes(c, s) do
    sensible = for {_, r} <- s.damage, r.granularity == 0, Map.has_key?(r, :temperature_kelvin), reduce: 0.0 do
      sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] *
        Map.get(s.liquid_units, Damage.macro(r), @cap) / @cap * (r.temperature_kelvin - @ambient)
    end
    book = ledger(s, :supplied_j) + ledger(s, :environment_j) - ledger(s, :removed_j) - ledger(s, :transform_j)
    assert_in_delta sensible, book, 1.0e-6 * max(1.0, ledger(s, :supplied_j))
  end

  # 燃料账：初始化 = 燃烧 + 弃置 + 还原剂消耗 + 行上余量。
  defp assert_fuel_closes(s) do
    left = for {_, r} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(r, :remaining_fuel_j, 0.0))
    assert_in_delta ledger(s, :fuel_initialized_j),
      ledger(s, :combustion_j) + ledger(s, :discarded_fuel_j) + ledger(s, :transform_reductant_fuel_j) + left, 1.0e-3
  end

  test "目录：45 行与大理石转化按方案取值；其余字节与 b88329ab 相同；b88329ab 与青岚 249f2442 都可在线升级" do
    new = Damage.load(Path.join(@fixtures, @catalog <> ".json"))
    assert Base.encode16(new.digest, case: :lower) == @catalog
    marble = new.materials[@marble]
    assert new.materials[@thermistor] == Map.merge(Map.take(marble, ~w(tags max_hp_per_macro defense responses)), %{
      "material_id" => 45, "display_name" => "Thermistor Ceramic", "loose_threshold_units" => div(@cap * 6, 8),
      "density_kg_m3" => 5700, "heat_capacity_per_macro" => @c_thermistor, "thermal_conductivity" => 25,
      "heat_resistance_kelvin" => 1600, "electrical_conductivity" => 10, "electrical_cutoff_kelvin" => @cutoff})
    assert Map.take(marble, ~w(loose_threshold_units transform_material_id transform_kelvin transform_heat_per_macro_j
      transform_reductant_material_id transform_reductant_units_per_unit)) ==
      %{"loose_threshold_units" => div(@cap * 6, 8), "transform_material_id" => @thermistor, "transform_kelvin" => @x,
        "transform_heat_per_macro_j" => @heat, "transform_reductant_material_id" => @coal,
        "transform_reductant_units_per_unit" => @ratio}

    # 只多这两处：其余材料行、工具、附件、液体、标签逐项与上一份目录相同。
    old_raw = Jason.decode!(File.read!(Path.join(@fixtures, @previous <> ".json")))
    new_raw = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json")))
    assert Map.drop(new_raw, ["materials"]) == Map.drop(old_raw, ["materials"])
    strip = fn rows -> Enum.reject(rows, &(&1["material_id"] in [@marble, @thermistor])) end
    assert strip.(new_raw["materials"]) == strip.(old_raw["materials"])
    old_marble = Enum.find(old_raw["materials"], &(&1["material_id"] == @marble))
    assert Map.drop(marble, ~w(loose_threshold_units) ++ Enum.filter(Map.keys(marble), &String.starts_with?(&1, "transform_"))) ==
      old_marble

    # 新增行与散体／转化字段都在可在线调整范围内：两份在用目录都可在线升级到它，反向不行（45 行不能撤下）。
    for digest <- [@previous, @qinglan] do
      old = Damage.load(Path.join(@fixtures, digest <> ".json"))
      assert ParameterEvolution.compatible?(old, new)
      refute ParameterEvolution.compatible?(new, old)
    end
  end

  test "0.25 m³ 大理石堆挨着整格煤越过 1373.15 K：同体积换成温敏陶瓷一次，煤扣 50 MJ、反应热 250 kJ；不可逆；冷恢复；舀回", c do
    c = start(c)
    assert {:ok, _} = pour(c, {2, 0, 2})
    settle(c.w)
    assert {:ok, _} = build(c, {3, 0, 2}, @coal)
    assert observe(c.w).liquid_units == %{{2, 0, 2} => @quarter}
    # 热源 8 MJ：0.25 m³ 产物全部吸收也只到 Ta + (8 MJ − 0.25 MJ)/(25000 × 0.25) = 1533.15 K < 耐热 1600 K；
    # 大理石到 X 需 23430 × 0.25 × 1080 = 6.33 MJ。
    heat(c, {2, 0, 2}, 200_000.0, 8.0e6)
    from = World.seq(c.w)
    s = thermal(c.w, &(material_of(&1, {2, 0, 2}) == @thermistor))

    # 有限投入：0.25 m³ 大理石 = 524 288 量子换成等量温敏陶瓷；反应热 1 MJ/m³ × 0.25 m³ = 250 kJ；
    # 还原剂 0.25 × 0.25 m³ × 800 MJ/m³ = 50 MJ，从未点燃的整格煤首次建立 800 MJ 余量后扣除。
    assert s.thermal.transform_units == @quarter
    assert s.liquid_units[{2, 0, 2}] == @quarter
    assert_in_delta s.thermal.transform_j, 250_000.0, 1.0e-9
    assert_in_delta s.thermal.transform_reductant_fuel_j, 5.0e7, 1.0e-3
    assert_in_delta s.thermal.fuel_initialized_j, @coal_fuel, 1.0e-3
    assert_in_delta row(s, {3, 0, 2}).remaining_fuel_j, @coal_fuel - 5.0e7, 1.0e-3
    # 场景前提：煤没被引燃（煤只作还原剂）。
    assert ledger(s, :combustion_j) == 0.0 and not Map.get(row(s, {3, 0, 2}), :burning, false)
    assert_energy_closes(c, s)
    assert_fuel_closes(s)

    # 焓口径：产物温度 = Ta + (C大理石(T−Ta) − H)/C温敏，体积约去；T 是转化前一笔提交里的大理石温度。
    # T = X 时为 293.15 + (23430 × 1080 − 1e6)/25000 = 1265.326 K；T ≥ X，所以产物不低于它。
    txn = product_txn(c.w, from)
    t = marble_before(c.w, txn, {2, 0, 2})
    assert t >= @x
    product = Enum.find(txn.property_states, &(&1.material == @thermistor))
    assert Enum.any?(txn.property_states, &(&1.material == @marble and &1.flags == 1))
    assert_in_delta product.temperature_kelvin, @ambient + (@c_marble * (t - @ambient) - @heat) / @c_thermistor, 1.0e-9
    assert product.temperature_kelvin >= 1265.326 - 1.0e-9
    # 完整度：未受损的 0.25 m³ 大理石 → 产物 HP 满（最大 HP 按体积 100 × 0.25）。
    assert product.max_hp == 25.0 and product.hp == product.max_hp

    # 不可逆：热源耗尽后冷却到静止仍是温敏陶瓷，只转化一次，账仍闭合。
    settled = thermal(c.w, &(not &1.thermal.active), 20_000)
    assert material_of(settled, {2, 0, 2}) == @thermistor
    assert row(settled, {2, 0, 2}).temperature_kelvin < @x
    assert settled.thermal.transform_units == @quarter
    assert_in_delta settled.thermal.transform_reductant_fuel_j, 5.0e7, 1.0e-3
    assert ledger(settled, :combustion_j) == 0.0
    assert_energy_closes(c, settled)
    assert_fuel_closes(settled)
    IO.puts("THERMISTOR_TRANSFORM marble_k=#{t} product_k=#{product.temperature_kelvin} converted_s=#{s.thermal.elapsed_s} " <>
      "coal_k_at_convert=#{Map.get(row(s, {3, 0, 2}), :temperature_kelvin)} settled_s=#{settled.thermal.elapsed_s} " <>
      "product_k_settled=#{row(settled, {2, 0, 2}).temperature_kelvin} coal_k_settled=#{Map.get(row(settled, {3, 0, 2}), :temperature_kelvin)}")

    # 冷恢复：同一根目录重启 World，属性行、热账与数量逐项相同。
    stop_supervised!(World)
    w = start_supervised!({World, c.opts})
    restored = observe(w)
    assert restored.damage == settled.damage
    assert restored.thermal == settled.thermal
    assert restored.liquid_units == settled.liquid_units
    assert hd(World.material_snapshot(w, [], [{2, 0, 2}]).probe_occupancy).material == @thermistor

    # 产物仍是散体数量（45 可倾倒）：舀回 0.25 m³ 温敏陶瓷，格清空。
    c = %{c | w: w}
    assert balance(w, @thermistor) == 0
    assert {:ok, _} = scoop(c, {2, 0, 2}, @thermistor)
    assert balance(w, @thermistor) == @quarter
    assert observe(w).liquid_units == %{}
  end

  test "没挨着煤的大理石堆越过 1373.15 K 仍是大理石（还原剂必须面接触）", c do
    c = start(c)
    assert {:ok, _} = pour(c, {2, 0, 2})
    settle(c.w)
    heat(c, {2, 0, 2}, 200_000.0, 8.0e6)
    hot = thermal(c.w, &(Map.get(row(&1, {2, 0, 2}) || %{}, :temperature_kelvin, @ambient) >= @x + 20))
    assert material_of(hot, {2, 0, 2}) == @marble
    refute Map.has_key?(hot.thermal, :transform_units)
    assert ledger(hot, :fuel_initialized_j) == 0.0
  end

  describe "温控回路（纯函数求解，目录行取自夹具）" do
    # z = 0 竖直平面：
    #   (0,2) 铜 ── (1,2) 温敏 45 ── (2,2) 合金 40 ── (3,2) 铜
    #   (0,1) 蓄能石 42（正极 +Y，24 V）                  (3,1) 铜
    #   (0,0) 铜 ── (1,0) 铜 ── (2,0) 铜 ───────────────── (3,0) 铜
    # 十条接触边、二十个半格：蓄能石 2 × 0.5/20、温敏 2 × 0.5/10、合金 2 × 0.5/4，铜 7 格 14 个半格 0.5/5.8e7。
    # ΣR = 0.05 + 0.1 + 0.25 + 7/5.8e7 = 0.40000012069 Ω；I = 24/ΣR = 59.99998190 A。
    # （设计稿写的 0.40000013793 Ω / 59.99997931 A 按 8 格铜算，回路里只有 7 格；两者相对差 4.3e-8 > 容差 1e-8。）
    # 容差 1e-8 相对：铜—铜半格与合金半格相差 ~1e7，消元相对误差 ≈ κ·ε ≈ 3e-9（同 circuit_test）。
    @rel 1.0e-8
    @env %{"ambient_kelvin" => 293.15, "circuit_min_power_w" => 1.0}
    @i 59.99998189655719

    defp macro({x, y, z}, material),
      do: %{micro: {x * 8, y * 8, z * 8}, granularity: 0, material: material, owner: {0, 0}, incarnation: 1}

    defp cells do
      [macro({0, 0, 0}, @copper), macro({0, 1, 0}, @battery), macro({0, 2, 0}, @copper), macro({1, 2, 0}, @thermistor),
       macro({2, 2, 0}, @alloy), macro({3, 2, 0}, @copper), macro({3, 1, 0}, @copper), macro({3, 0, 0}, @copper),
       macro({2, 0, 0}, @copper), macro({1, 0, 0}, @copper)]
    end

    defp contacts(cells) do
      for {a, i} <- Enum.with_index(cells), {b, j} <- Enum.with_index(cells), i < j, adjacent?(a, b), do: {a, b, 1.0}
    end

    defp adjacent?(a, b) do
      d = Enum.zip(Tuple.to_list(a.micro), Tuple.to_list(b.micro)) |> Enum.map(fn {p, q} -> abs(p - q) end)
      Enum.sort(d) == [0, 0, 8]
    end

    # World 的接触摘要只收此刻导电的导体（solid_contacts 按 sigma）；用同一产品函数筛格后按相邻关系成边。
    defp solve(catalog, damage) do
      live = Enum.filter(cells(), &(Circuit.solid_contacts([{&1, 64}], catalog, damage, @env) != %{}))
      Circuit.plan(Circuit.prepare(%{}, damage, catalog, 0.5, @env), %{}, contacts(live))
    end

    defp key(t), do: VoxelRegion.ThermalGeometry.key(t)
    defp state(t, fields), do: {Damage.key(t), Map.merge(t, fields)}

    test "低于截止 I = 24/ΣR；达到截止（373.15 K、900 K）下一次求解严格 0 A、储能不降、电动势仍 24 V；冷却回到截止以下恢复同一电流" do
      catalog = Damage.load(Path.join(@fixtures, @catalog <> ".json"))
      [_, b, _, r, alloy | _] = cells()
      at = fn kelvin -> Map.new([state(b, %{stored_j: 1.0e6}), state(r, %{temperature_kelvin: kelvin})]) end
      # 手算数字与目录算术一致（σ 取自夹具行）。
      sigma = &catalog.materials[&1]["electrical_conductivity"]
      r_sum = 2 * 0.5 / sigma.(@battery) + 2 * 0.5 / sigma.(@thermistor) + 2 * 0.5 / sigma.(@alloy) + 14 * 0.5 / sigma.(@copper)
      assert_in_delta r_sum, 0.40000012068965517, 1.0e-15
      assert_in_delta 24.0 / r_sum, @i, 1.0e-9

      for kelvin <- [@ambient, 373.14] do
        plan = solve(catalog, at.(kelvin))
        source = plan.sources[key(b)]
        assert_in_delta source.current_a, @i, @i * @rel
        assert source.emf_v == 24.0
        # 放电 ε·I·Δt = 1439.9996 W × 0.5 s；储能按同一速率下降。
        assert_in_delta plan.supplied_j, 24.0 * @i * 0.5, 24.0 * @i * 0.5 * @rel
        assert_in_delta source.stored_j, 1.0e6 - 24.0 * @i * 0.5, 24.0 * @i * 0.5 * @rel
        # 合金 I² × 0.25 Ω = 899.9995 W，其中 0.2 成为光（179.9999 W）；温敏格自身 I² × 0.1 Ω = 359.9998 W。
        assert_in_delta plan.light_j, 0.2 * @i * @i * 0.25 * 0.5, 0.2 * @i * @i * 0.25 * 0.5 * 3 * @rel
        assert_in_delta plan.powers[key(r)], @i * @i * 0.1, @i * @i * 0.1 * @rel
        assert Map.has_key?(plan.powers, key(alloy))
      end

      for kelvin <- [@cutoff, 900.0] do
        plan = solve(catalog, at.(kelvin))
        source = plan.sources[key(b)]
        assert source.current_a == 0.0
        assert source.emf_v == 24.0
        assert source.stored_j == 1.0e6
        assert plan.supplied_j == 0.0 and plan.light_j == 0.0 and plan.powers == %{}
      end

      # 冷却：同一回路回到截止以下（蓄能石电动势恒定），电流恢复为同一个 24/ΣR。
      cooled = solve(catalog, at.(373.0))
      assert_in_delta cooled.sources[key(b)].current_a, @i, @i * @rel
    end
  end
end
