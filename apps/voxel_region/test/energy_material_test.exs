defmodule VoxelRegion.EnergyMaterialTest do
  @moduledoc """
  只测试：R8-04 增量 3（器件材料化第三步，Voxim Docs/R8/Design-decisions.md §10 D3–D5、D8）在 UE 发布的目录字节上核对。

  目录 `b1aca503…` = `DA_MaterialCoverageV1` 的发布字节：蓄能石 42（σ 20、每米 24 V、每宏格 10 MJ，荧光石 23 接触煤
  在 1073.15 K 转化）、热电石 43（σ 2、k 15、S 0.05 V/K，砂岩 9 接触煤在 1373.15 K 转化）、冰／水导热 ×10；
  撤下工具 2（加热器投料）、3／15／19（电源）、8（补能），`retired_tools` 3/15/19 → 铜 24，2、8 无设备。
  迁移起点是上一份发布 `0c67824f…`。热环境 = 生产 ε 0.9（`environment-radiation.json`）。

  场景地形只经作者编辑入口；热只经 Test-only 实验热源；蓄能石新放置为空，只经热电石发电充电；开关切换、挖掘走正式工具。
  期望来自目录算术（r = d/(σA)、E = 24 V/m × 边长、S·ΔT_i）与账目恒等式，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :energy_material
  alias VoxelRegion.{World, Damage, ParameterEvolution}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}
  alias MmoContracts.Voxel.Codec

  @digest "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @previous "0c67824f97992de46ea7306b3e7596b6b29eea3d51e4e2a226bf947b2cf21552"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @sandstone 9
  @stone 11
  @coal 15
  @glowstone 23
  @copper 24
  @alloy 40
  @switch 41
  @battery 42
  @te 43
  @macro 512 * 4096
  @materials [@sandstone, @stone, @coal, @glowstone, @copper, @alloy, @switch, @battery, @te]
  @box {{-2, -2, -2}, {2, 2, 2}}

  setup do
    root = Path.join(System.tmp_dir!(), "energy_material_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    %{root: root, data: data, materials: Map.new(data["materials"], &{&1["material_id"], &1}),
      tools: Map.new(data["tools"], &{&1["tool_id"], &1}), ambient: 293.15}
  end

  defp start(c, name, digest \\ @digest) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    unless File.exists?(catalog), do: File.cp!(Path.join(@fixtures, digest <> ".json"), catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, production_materials: @materials]}, id: name)
    {w, root}
  end

  defp restart(c, name) do
    :ok = stop_supervised(name)
    elem(start(c, name), 0)
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end
  defp stamp(a, seq), do: Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()})
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp commits(w, n), do: Enum.reduce(1..n, nil, fn _, _ -> commit(w) end)
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp temperature(s, c, coord), do: Map.get(cell(s, coord) || %{}, :temperature_kelvin, c.ambient)

  # 正式工具路径：先按眼睛到目标微格的射线查询命中身份，再以同一身份执行。
  defp use_tool(w, a, {x, y, z} = micro, tool, opts \\ []) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    q = Map.merge(q, Map.new(Keyword.get(opts, :target, [])))
    target = if q.granularity == 3, do: q, else: elem(World.tool_intent(w, a, q), 1)
    r = Map.merge(q, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    World.tool_intent(w, stamp(a, seq), %{r | action: Keyword.get(opts, :action, 1)})
  end

  # 眼睛在目标宏格正上方那格的中心：射线竖直向下命中目标顶面。
  defp toggle(w, {x, y, z}), do: use_tool(w, actor({x + 0.5, y + 1.5, z + 0.5}), {x * 8 + 4, y * 8 + 4, z * 8 + 4}, 7)

  test "夹具即 UE 发布字节：蓄能石、热电石、转化规则、冰水导热与退役工具按作者值发布；上一份发布可在线升级到它", c do
    path = Path.join(@fixtures, @digest <> ".json")
    assert Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) == @digest
    b = c.materials[@battery]
    assert {b["electrical_conductivity"], b["battery_volts_per_m"], b["battery_energy_per_macro_j"]} == {20, 24, 10_000_000}
    t = c.materials[@te]
    assert {t["electrical_conductivity"], t["seebeck_v_per_k"], t["thermal_conductivity"], t["heat_resistance_kelvin"]} == {2, 0.05, 15, 1400}
    # 几何：宏格蓄能石 0.5/(20×1)×2 = 0.05 Ω；20 块一串 = 480 V、1 Ω（原工具 19）。
    assert_in_delta 2 * 0.5 / b["electrical_conductivity"], 0.05, 1.0e-15
    g = c.materials[@glowstone]
    assert {g["transform_material_id"], g["transform_kelvin"], g["transform_reductant_material_id"], g["heat_resistance_kelvin"]} ==
             {@battery, 1073.15, @coal, 1600}
    s = c.materials[@sandstone]
    assert {s["transform_material_id"], s["transform_kelvin"], s["transform_reductant_material_id"]} == {@te, 1373.15, @coal}
    assert {c.materials[20]["thermal_conductivity"], c.materials[21]["thermal_conductivity"]} == {22, 6}
    assert Enum.all?([2, 3, 8, 15, 19], &(not Map.has_key?(c.tools, &1)))
    new = Damage.load(path)
    assert new.retired == %{2 => nil, 3 => 24, 4 => 41, 5 => 40, 6 => 40, 8 => nil, 15 => 24, 16 => 24, 19 => 24}
    old = Damage.load(Path.join(@fixtures, @previous <> ".json"))
    assert ParameterEvolution.compatible?(old, new)
    # 反例：安装类工具（电源）退役却不给迁移材料，不能在线发布。
    refute ParameterEvolution.compatible?(old, %{new | retired: Map.put(new.retired, 3, nil)})
  end

  test "荧光石接触煤越过 1073.15 K 变成蓄能石、砂岩越过 1373.15 K 变成热电石（整格、还原剂 0.25 × 煤燃料）", c do
    for {source, product, kelvin} <- [{@glowstone, @battery, 1073.15}, {@sandstone, @te, 1373.15}] do
      {w, _} = start(c, :"smelt_#{source}")
      {:ok, _} = World.apply_edits(w, [{{2, 0, 2}, @stone}, {{2, 1, 2}, source}, {{3, 1, 2}, @coal}])
      path = Path.join(c.root, "heat_#{source}.json")
      File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [2, 1, 2], ambient_kelvin: c.ambient,
        environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, power_w: 500_000.0, energy_j: 6.0e7}))
      :ok = World.thermal_experiment(w, path)
      s = Enum.reduce_while(1..4000, nil, fn _, _ ->
        s = commit(w)
        if match?(%{material: ^product}, cell(s, {2, 1, 2})), do: {:halt, s}, else: {:cont, s}
      end)
      row = cell(s, {2, 1, 2})
      assert row.material == product
      assert c.materials[source]["transform_kelvin"] == kelvin
      assert_in_delta s.thermal.transform_reductant_fuel_j, 0.25 * c.materials[@coal]["fuel_energy_per_macro_j"], 1.0e-3
      # 新蓄能石是空的：转化不产生储能。
      refute Map.has_key?(row, :stored_j)
      IO.puts("ENERGY_SMELT #{source}->#{product} temperature=#{row.temperature_kelvin} elapsed=#{s.thermal.elapsed_s}")
    end
  end

  # 发电—蓄能—灯（z = 2 平面，地面 y = 0 石）：
  #   y = 3：热铜 H (1,3)（实验热源）— 热电石 T (2,3) — 冷铜 C (3,3) — 开关 S2 (4,3)
  #   y = 2：铜 (1,2)；蓄能石 B (3,2)（正极朝上接 C）；电阻合金灯 L (4,2)（与 B 侧面相邻，不导电）
  #   y = 1：铜 (1,1) — 开关 S1 (2,1) — 铜 (3,1)（B 的负极）— 铜 (4,1)
  # 充电回路 H→T→C→B(+)→B(−)→(3,1)→S1→(1,1)→(1,2)→H；灯回路 B(+)→C→S2→L→(4,1)→(3,1)→B(−)。
  defp generator(c, name) do
    {w, root} = start(c, name)
    ground = for x <- -1..6, z <- 0..4, do: {{x, 0, z}, @stone}
    cells = [{{1, 3, 2}, @copper}, {{2, 3, 2}, @te}, {{3, 3, 2}, @copper}, {{4, 3, 2}, @switch},
      {{1, 2, 2}, @copper}, {{3, 2, 2}, @battery}, {{4, 2, 2}, @alloy},
      {{1, 1, 2}, @copper}, {{2, 1, 2}, @switch}, {{3, 1, 2}, @copper}, {{4, 1, 2}, @copper}]
    {:ok, _} = World.apply_edits(w, ground ++ cells)
    path = Path.join(root, "heat.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [1, 3, 2], ambient_kelvin: c.ambient,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8, power_w: 2.0e6, energy_j: 1.0e9}))
    :ok = World.thermal_experiment(w, path)
    {w, root}
  end

  # 热电石开路电动势：界面温度按 k/半格长加权（铜 4000/0.5、热电石 15/0.5）。
  defp open_emf(c, s) do
    th = temperature(s, c, {1, 3, 2}); tt = temperature(s, c, {2, 3, 2}); tc = temperature(s, c, {3, 3, 2})
    ti = fn cu -> (8000 * cu + 30 * tt) / 8030 end
    0.05 * (ti.(th) - ti.(tc))
  end

  defp battery_row(s), do: cell(s, {3, 2, 2})
  defp te_row(s), do: cell(s, {2, 3, 2})

  test "发电—蓄能—灯：热电石开路电动势 = S·ΔT_i；闭合 S1 充电（账：充入 = 储能）；断开 S1、闭合 S2 按 24 V/ΣR 点灯；复制、重启、挖掘", c do
    {w, _} = generator(c, :generator)
    # 开路：两个开关都断开，热电石只报开路电动势，电流 0，蓄能石没有行（新放置为空）。
    # 每次提交先按提交前的温度求解、再推进热：一次提交写下的电动势对应上一次提交结束时的温度。
    {previous, hot} = Enum.reduce_while(1..2000, {nil, observe(w)}, fn _, {_, s0} ->
      s = commit(w)
      if open_emf(c, s0) > 34.0, do: {:halt, {s0, s}}, else: {:cont, {s0, s}}
    end)
    te = te_row(hot)
    assert_in_delta te.source_emf_v, open_emf(c, previous), 1.0e-9
    assert te.source_current_a == 0.0
    assert Map.get(battery_row(hot) || %{}, :stored_j, 0.0) == 0.0
    IO.puts("ENERGY_OPEN emf=#{te.source_emf_v} hot=#{temperature(previous, c, {1, 3, 2})} te=#{temperature(previous, c, {2, 3, 2})} cold=#{temperature(previous, c, {3, 3, 2})} elapsed=#{hot.thermal.elapsed_s}")

    # 闭合 S1：热电石经 B 的正极灌入，B 充电（电流为负）。
    {:ok, _} = toggle(w, {2, 1, 2})
    charged = commits(w, 40)
    b = battery_row(charged)
    assert b.stored_j > 0 and b.source_current_a < 0 and b.source_emf_v == 24.0
    assert te_row(charged).source_current_a > 0
    # 账：充入储能 = 这块电池的储能；没有放电；热电做功 > 0。
    assert_in_delta charged.thermal.circuit_charged_j, b.stored_j, 1.0e-6
    assert Map.get(charged.thermal, :circuit_supplied_j, 0.0) == 0.0
    assert charged.thermal.circuit_thermoelectric_j > b.stored_j
    IO.puts("ENERGY_CHARGE stored_j=#{b.stored_j} current=#{b.source_current_a} te_emf=#{te_row(charged).source_emf_v} te_work_j=#{charged.thermal.circuit_thermoelectric_j}")

    # 断开 S1、闭合 S2：热电石回路悬空（0 A），B 经 C—S2—L—(4,1)—(3,1) 放电点灯。
    {:ok, _} = toggle(w, {2, 1, 2})
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(w, {{0, 0, 0}, {1, 1, 1}}, self(), ref, false)
    assert_receive {:canonical_snapshot, ^ref, _}
    {:ok, _} = toggle(w, {4, 3, 2})
    lit = commits(w, 2)
    sigma = fn m -> c.materials[m]["electrical_conductivity"] end
    # ΣR：B 两个半格 + L 两个半格 + 铜/开关半格（C 两个、S2 两个、(4,1) 两个、(3,1) 两个）。
    r = 2 * 0.5 / sigma.(@battery) + 2 * 0.5 / sigma.(@alloy) + 8 * 0.5 / sigma.(@copper)
    i = 24.0 / r
    b = battery_row(lit)
    assert_in_delta b.source_current_a, i, i * 1.0e-8
    assert te_row(lit).source_current_a == 0.0
    lamp = cell(lit, {4, 2, 2})
    assert_in_delta lamp.electric_w, i * i * 2 * 0.5 / sigma.(@alloy), i * i * 1.0e-6
    later = commit(w)
    dt = later.thermal.elapsed_s - lit.thermal.elapsed_s
    # 放电：储能按 E·I 减少，放电账同额；光 = 0.2 × 灯焦耳。
    assert_in_delta battery_row(lit).stored_j - battery_row(later).stored_j, 24.0 * i * dt, 24.0 * i * dt * 1.0e-6
    assert_in_delta later.thermal.circuit_supplied_j - lit.thermal.circuit_supplied_j, 24.0 * i * dt, 24.0 * i * dt * 1.0e-6
    assert_in_delta later.thermal.circuit_light_j - lit.thermal.circuit_light_j, 0.2 * lamp.electric_w * dt, 0.2 * lamp.electric_w * dt * 1.0e-6
    IO.puts("ENERGY_LAMP current=#{b.source_current_a} hand=#{i} lamp_w=#{lamp.electric_w} stored_j=#{battery_row(later).stored_j}")

    # 复制：订阅者收到带储能的蓄能石行，编码 flags 位 3 + 24 字节后缀（储能、电动势、电流）。
    row = Enum.find_value(Stream.repeatedly(fn ->
      receive do
        {:canonical_delta, %{transaction: %{property_states: rows}}} -> Enum.find(rows, &(&1.material == @battery and &1.granularity == 0))
      after 5_000 -> flunk("no battery row replicated")
      end
    end), & &1)
    {:ok, bytes} = Codec.encode({:voxel_property_state, row})
    bytes = IO.iodata_to_binary(bytes)
    assert Bitwise.band(:binary.at(bytes, 120), 8) == 8
    assert binary_part(bytes, byte_size(bytes) - 24, 24) ==
             <<row.stored_j::float-64, row.source_emf_v::float-64, row.source_current_a::float-64>>

    # 重启：储能与两个开关的开合从日志恢复，恢复后照常放电。
    before = observe(w)
    w = restart(c, :generator)
    restored = observe(w)
    assert battery_row(restored).stored_j == battery_row(before).stored_j
    assert Map.get(cell(restored, {4, 3, 2}), :closed) == true
    refute Map.get(cell(restored, {2, 1, 2}) || %{}, :closed, false)
    assert battery_row(commit(w)).source_current_a > 0.9 * i

    # 挖掉蓄能石：只返还蓄能石单位（储能不进库存），剩余储能记入移除账；灯熄灭。
    left = battery_row(observe(w)).stored_j
    removed0 = Map.get(observe(w).thermal, :circuit_removed_j, 0.0)
    a = actor({2.5, 2.5, 2.5})
    hits = ceil(c.materials[@battery]["max_hp_per_macro"] / (c.tools[1]["power"] - c.materials[@battery]["defense"]))
    for _ <- 1..hits, do: assert({:ok, _} = use_tool(w, a, {24, 20, 20}, 1))
    mined = observe(w)
    assert battery_row(mined) == nil
    assert mined.material_balances[{1001, @battery}] == @macro
    assert_in_delta mined.thermal.circuit_removed_j - removed0, left, left * 1.0e-3 + 1.0
    dark = commit(w)
    refute Map.has_key?(cell(dark, {4, 2, 2}), :electric_w)
  end

  # 旧世界夹具（fixtures/energy_migration，由增量 3 之前的服务端代码 aef461ef 经正式工具记录的 overlay 日志）：
  # 目录 0b2bb0b6（五种设备工具都在），地面上五块铜面分别装开关、灯、加热器、冷板与 24 V 电源（投料一次 6.25 MJ），
  # 铜宏格 (3,1,3) 上加热器投料一次（12.5 MJ、25 kW）。一次参数发布直接升到本增量的目录（增量 2 的映射也在 retired_tools 里）。
  @oldest "0b2bb0b6e47e5fe52aa4393f9e8eaae7f68aac7cd42af01f8269df89a725f172"
  test "迁移：旧世界日志回放后一次参数发布——五种设备都变成材料面、电源剩余电能记入移除账；加热器热源撤销、剩余热能记入弃置账；退役工具不再可用", c do
    fixture = Path.expand("fixtures/energy_migration", __DIR__)
    meta = Jason.decode!(File.read!(Path.join(fixture, "world.json")))
    assert meta["catalog"] == @oldest
    root = Path.join(c.root, "migrate")
    File.mkdir_p!(root)
    File.cp!(Path.join(fixture, "overlay.log"), Path.join(root, "overlay.log"))
    File.cp!(Path.join(@fixtures, @oldest <> ".json"), Path.join(root, "properties.json"))
    {w, _} = start(c, :migrate, @oldest)
    faces = Map.new(meta["faces"], fn {name, f} -> {String.to_atom(name), {f["id"], List.to_tuple(f["anchor"])}} end)
    before = observe(w)
    {source_id, _} = faces.source
    source = before.damage[{3, source_id}].circuit
    assert {source.tool_id, source.remaining_j} == {3, 6_250_000.0}
    assert before.damage[{3, elem(faces.switch, 0)}].circuit.closed == true
    heater = Enum.sum(for {_, s} <- before.thermal.sources, do: s.remaining_j)
    assert heater > 0 and heater <= 12_500_000.0
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(w, {{0, 0, 0}, {1, 1, 1}}, self(), ref, false)
    assert_receive {:canonical_snapshot, ^ref, _}
    assert :ok = World.publish_parameters(w, Path.join(@fixtures, @digest <> ".json"), before.property_digest)
    after_state = observe(w)
    assert after_state.seq == before.seq + 1
    # D8：开关 → 开关面（保持闭合）、灯／加热器 → 电阻合金面、冷板 → 铜面、电源 → 铜面；都不再带设备记录。
    expected = %{switch: {@switch, true}, lamp: {@alloy, nil}, heater: {@alloy, nil}, cold: {@copper, nil}, source: {@copper, nil}}
    slots = VoxelRegion.TestSupport.payload(w, 0, {0, 0, 0}).attachments
    for {name, {material, closed}} <- expected do
      {id, anchor} = faces[name]
      row = after_state.damage[{3, id}]
      assert {row.material, Map.get(row, :closed), Map.has_key?(row, :circuit)} == {material, closed, false}, "#{name}"
      assert slots[{0, 1, anchor}] == {id, material}, "#{name}"
    end
    assert_in_delta Map.get(after_state.thermal, :circuit_removed_j, 0.0) - Map.get(before.thermal, :circuit_removed_j, 0.0),
      source.remaining_j, 1.0e-6
    assert after_state.thermal.sources == %{}
    assert_in_delta after_state.thermal.discarded_source_j - Map.get(before.thermal, :discarded_source_j, 0.0), heater, 1.0e-6
    # 同一事务：订阅者收到迁移后的整件行。
    assert_receive {:canonical_delta, %{transaction_seq: seq, transaction: txn}}, 5_000
    assert seq == after_state.seq
    assert Enum.any?(txn.property_states, &(&1.granularity == 3 and &1.incarnation == source_id and &1.material == @copper))
    a = actor({1.5, 3.5, 2.5})
    {_, anchor} = faces.source
    on_face = [micro: anchor, granularity: 3, incarnation: source_id, owner: {source_id, 1}, material: @copper]
    for tool <- [2, 3, 4, 5, 6, 8, 15, 16, 19], do: assert({:error, :invalid_tool} = use_tool(w, a, anchor, tool, target: on_face))
    # 重启：新目录文件加日志恢复出同一状态。
    File.cp!(Path.join(@fixtures, @digest <> ".json"), Path.join(root, "properties.json"))
    w = restart(c, :migrate)
    restored = observe(w)
    assert restored.damage == after_state.damage
    assert Map.drop(restored.thermal, [:active]) == Map.drop(after_state.thermal, [:active])
  end

  test "旧目录仍可加载（迁移发布之前）：退役动作的工具只被拒绝，不当作伤害", c do
    {w, _} = start(c, :old, @previous)
    a = actor({1.5, 3.5, 2.5})
    {:ok, _} = World.apply_edits(w, [{{1, 1, 2}, @copper}])
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@coal => @macro})
    seq = World.seq(w)
    for tool <- [2, 3, 8, 15, 19], do: assert({:error, :retired_tool} = use_tool(w, a, {12, 12, 20}, tool))
    assert World.seq(w) == seq
  end
end
