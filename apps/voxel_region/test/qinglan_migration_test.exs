defmodule VoxelRegion.QinglanMigrationTest do
  @moduledoc """
  只测试：R8-09 片 3，青岚驿旧作品迁移契约（旧电源退役、温差发电接替）在 UE 发布的目录字节上核对。

  起点目录 `4b2c6abe…` = 青岚 0923 分发目录（`DA_MaterialCoverageV1` 发布字节，含工具 19 = 480 V 有限能源直流电源、工具 8 投煤补能，
  没有 retired_tools，也没有材料 40–43）。目标：`249f2442…`（2026-09-30 青岚实际发布的目录）与 `b88329ab…`（当前可玩目录），
  两者都以 `retired_tools` 3/15/16/19 → 铜 24 撤下电源。

  旧世界夹具 `fixtures/qinglan_migration`：当前服务端已拒绝 circuit.install／feed，所以由青岚 0923 版服务端源码 79dde382 经正式入口录制
  （作者铺地 → Test-only 记账供料 → 付费铜面 → 工具 19 安装 → 工具 8 投料两次），录制器 `record_79dde382_helper.exs` 同目录保存。
  迁移后发电的热只经 Test-only 实验热源；热电石等器件格经作者编辑放置；开关切换走正式工具 7。
  期望来自目录算术（2 × 6.25 MJ、4 × 4096 单位／次、S·ΔT_i、k/半格长）与账目恒等式，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :energy_material
  alias VoxelRegion.{World, Damage, ParameterEvolution}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @qinglan "4b2c6abeaec3818e2203a0b95e3ee03f1cf1aed6bf796c5f33ab41001eb641ed"
  @deployed "249f2442c082edaf95cb0610b60661d5539a72caa5ca0b4fd594632c84eb4839"
  @current "b88329ab0d3652c30f67d012fce04fd30afd7fd6dcc263e5066ba0b08f90284f"
  @catalogs Path.expand("fixtures/combustion", __DIR__)
  @fixture Path.expand("fixtures/qinglan_migration", __DIR__)
  @stone 11
  @coal 15
  @copper 24
  @alloy 40
  @switch 41
  @battery 42
  @te 43
  @units 4096
  @materials [@stone, @coal, @copper, @alloy, @switch, @battery, @te]
  @box {{-2, -2, -2}, {7, 4, 5}}

  setup do
    root = Path.join(System.tmp_dir!(), "qinglan_migration_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    meta = Jason.decode!(File.read!(Path.join(@fixture, "world.json")))
    %{root: root, meta: meta, ambient: 293.15}
  end

  defp catalog_path(digest), do: Path.join(@catalogs, digest <> ".json")
  defp rows(digest, key, id), do: Map.new(Jason.decode!(File.read!(catalog_path(digest)))[key], &{&1[id], &1})

  defp start(c, name) do
    root = Path.join(c.root, "#{name}")
    unless File.exists?(root) do
      File.mkdir_p!(root)
      File.cp!(Path.join(@fixture, "overlay.log"), Path.join(root, "overlay.log"))
      File.cp!(catalog_path(@qinglan), Path.join(root, "properties.json"))
    end
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@catalogs, "environment-radiation.json"), env)
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: env, production_materials: @materials]}, id: name)
    {w, root}
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
  defp hex(digest), do: Base.encode16(digest, case: :lower)

  # 正式工具入口：整件目标直接带身份；宏格目标先按眼睛射线查询命中身份，再以同一身份执行。
  defp use_tool(w, a, {x, y, z} = micro, tool, target \\ []) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    q = Map.merge(q, Map.new(target))
    hit = if q.granularity == 3, do: q, else: elem(World.tool_intent(w, a, q), 1)
    r = Map.merge(q, Map.take(hit, [:micro, :granularity, :incarnation, :owner, :material]))
    World.tool_intent(w, stamp(a, seq), %{r | action: 1})
  end

  defp on_source(c, material) do
    s = c.meta["source"]
    [micro: List.to_tuple(s["anchor"]), granularity: 3, incarnation: s["id"], owner: {s["id"], 1}, material: material]
  end

  test "目录：青岚 4b2c6abe 夹具即发布字节；可在线升级到 249f2442（已部署）与 b88329ab（当前），电源退役必须给出迁移材料" do
    assert hex(:crypto.hash(:sha256, File.read!(catalog_path(@qinglan)))) == @qinglan
    tools = rows(@qinglan, "tools", "tool_id")
    assert Map.take(tools[19], ~w(action circuit_kind circuit_voltage_v circuit_resistance_ohm)) ==
             %{"action" => "circuit.install", "circuit_kind" => 1, "circuit_voltage_v" => 480, "circuit_resistance_ohm" => 1}
    assert Map.take(tools[8], ~w(action fuel_material_id fuel_units circuit_energy_j)) ==
             %{"action" => "circuit.feed", "fuel_material_id" => @coal, "fuel_units" => 4, "circuit_energy_j" => 6_250_000}
    old = Damage.load(catalog_path(@qinglan))
    assert old.retired == %{}
    refute Enum.any?([@alloy, @switch, @battery, @te], &Map.has_key?(old.materials, &1))
    for digest <- [@deployed, @current] do
      new = Damage.load(catalog_path(digest))
      assert hex(:crypto.hash(:sha256, File.read!(catalog_path(digest)))) == digest
      assert Map.take(new.retired, [2, 3, 8, 15, 16, 19]) == %{2 => nil, 3 => @copper, 8 => nil, 15 => @copper, 16 => @copper, 19 => @copper}
      refute Enum.any?([2, 3, 8, 15, 16, 19], &Map.has_key?(new.tools, &1))
      assert new.materials[@te]["seebeck_v_per_k"] == 0.05
      assert ParameterEvolution.compatible?(old, new), digest
      # 反例：安装类工具 19 退役却不给迁移材料、或干脆不列入退役，都不能在线发布。
      refute ParameterEvolution.compatible?(old, %{new | retired: Map.put(new.retired, 19, nil)})
      refute ParameterEvolution.compatible?(old, %{new | retired: Map.delete(new.retired, 19)})
    end
    # 青岚此刻在 249f2442；下一次分发升到当前目录也须在线兼容。
    assert ParameterEvolution.compatible?(Damage.load(catalog_path(@deployed)), Damage.load(catalog_path(@current)))
  end

  # 一次参数发布前后的公共读数；返回迁移后的 World。
  defp migrate(c, name, target) do
    {w, root} = start(c, name)
    before = observe(w)
    src = c.meta["source"]
    feed = rows(@qinglan, "tools", "tool_id")[8]
    # 旧世界日志回放：工具 19 电源在用、投料两次（2 × 6.25 MJ），煤余额 = 3 次份额 − 2 次（每次 4 微格 × 4096 单位）。
    assert hex(before.property_digest) == @qinglan
    source = before.damage[{3, src["id"]}]
    assert {source.material, source.circuit.tool_id, source.circuit.kind} == {@copper, 19, 1}
    assert source.circuit.remaining_j == 2 * feed["circuit_energy_j"]
    assert before.material_balances[{1001, @coal}] == (3 - 2) * feed["fuel_units"] * @units

    # 迁移前（新服务端、旧目录）：投煤与安装只被拒绝，世界不动；电源没有闭合负载，提交热也不消耗储能。
    a = actor({5.5, 1.75, 0.5})
    for tool <- [8, 19, 3, 15], do: assert({:error, :retired_tool} = use_tool(w, a, List.to_tuple(src["anchor"]), tool, on_source(c, @copper)))
    idle = commits(w, 2)
    assert idle.damage[{3, src["id"]}].circuit.remaining_j == source.circuit.remaining_j
    assert idle.material_balances == before.material_balances

    assert :ok = World.publish_parameters(w, catalog_path(target), before.property_digest)
    after_state = observe(w)
    assert after_state.seq == idle.seq + 1
    assert hex(after_state.property_digest) == target
    # D8：电源面 → 铜面（铜→铜，HP 比 1），不再带设备记录；附件槽同时换成铜。
    row = after_state.damage[{3, src["id"]}]
    assert {row.material, Map.has_key?(row, :circuit), row.hp, row.max_hp} == {@copper, false, source.hp, source.max_hp}
    assert VoxelRegion.TestSupport.payload(w, 0, {0, 0, 0}).attachments[{0, 1, List.to_tuple(src["anchor"])}] == {src["id"], @copper}
    # 剩余电能不退还：记入移除账，煤与其他余额逐项不变；没有加热器热源可弃置。
    assert_in_delta Map.get(after_state.thermal, :circuit_removed_j, 0.0) - Map.get(idle.thermal, :circuit_removed_j, 0.0),
      2 * feed["circuit_energy_j"], 1.0e-6
    assert Map.get(after_state.thermal, :discarded_source_j, 0.0) == Map.get(idle.thermal, :discarded_source_j, 0.0)
    assert after_state.material_balances == idle.material_balances
    # 迁移后：退役工具已不在目录里，按无效工具拒绝；世界不动。
    for tool <- [8, 19, 3, 15], do: assert({:error, :invalid_tool} = use_tool(w, a, List.to_tuple(src["anchor"]), tool, on_source(c, @copper)))
    assert World.seq(w) == after_state.seq
    # 冷重启：新目录文件 + 日志恢复同一状态。
    File.cp!(catalog_path(target), Path.join(root, "properties.json"))
    :ok = stop_supervised(name)
    {w, _} = start(c, name)
    restored = observe(w)
    assert restored.damage == after_state.damage
    assert Map.drop(restored.thermal, [:active]) == Map.drop(after_state.thermal, [:active])
    {w, restored}
  end

  test "迁移到青岚已部署目录 249f2442：在用的工具 19 电源变铜面、剩余 12.5 MJ 记入移除账、旧工具被拒、冷重启一致", c do
    migrate(c, :deployed, @deployed)
  end

  # 迁移后同一世界（z = 2 平面，地面是夹具里的石，电源旧面在 (5,0,0) 顶面、不在回路里）：
  #   y = 3：热铜 H (1,3)（实验热源）— 热电石 T (2,3) — 冷铜 C (3,3)
  #   y = 2：铜 (1,2)；蓄能石 B (3,2)（正极朝上接 C）
  #   y = 1：铜 (1,1) — 开关 S1 (2,1) — 铜 (3,1)（B 的负极）
  # 充电回路 H→T→C→B(+)→B(−)→(3,1)→S1→(1,1)→(1,2)→H。
  test "迁移到当前目录 b88329ab 后，同一世界可用热电石发电：开路电动势 = S·ΔT_i，闭合开关给蓄能石充电（充入 = 储能）", c do
    {w, migrated} = migrate(c, :current, @current)
    removed = migrated.thermal.circuit_removed_j
    cells = [{{1, 3, 2}, @copper}, {{2, 3, 2}, @te}, {{3, 3, 2}, @copper},
      {{1, 2, 2}, @copper}, {{3, 2, 2}, @battery}, {{1, 1, 2}, @copper}, {{2, 1, 2}, @switch}, {{3, 1, 2}, @copper}]
    {:ok, _} = World.apply_edits(w, cells)
    # 开关作者放置为断开（无行 = 断开）；先确认它确实断开，回路悬空。
    refute Map.get(cell(observe(w), {2, 1, 2}) || %{}, :closed, false)
    path = Path.join(c.root, "heat.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [1, 3, 2], ambient_kelvin: c.ambient,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8, power_w: 2.0e6, energy_j: 1.0e9}))
    :ok = World.thermal_experiment(w, path)

    # 界面温度按 k/半格长加权（目录值：铜 4000、热电石 15，半格 0.5 m）；ε = S·(T_i,热 − T_i,冷)。
    m = rows(@current, "materials", "material_id")
    g_cu = m[@copper]["thermal_conductivity"] / 0.5
    g_te = m[@te]["thermal_conductivity"] / 0.5
    emf = fn s ->
      tt = temperature(s, c, {2, 3, 2})
      ti = fn cu -> (g_cu * cu + g_te * tt) / (g_cu + g_te) end
      m[@te]["seebeck_v_per_k"] * (ti.(temperature(s, c, {1, 3, 2})) - ti.(temperature(s, c, {3, 3, 2})))
    end
    # 每次提交先按提交前的温度求解、再推进热：一次提交写下的电动势对应上一次提交结束时的温度。
    {previous, hot} = Enum.reduce_while(1..2000, {nil, observe(w)}, fn _, {_, s0} ->
      s = commit(w)
      if emf.(s0) > 30.0, do: {:halt, {s0, s}}, else: {:cont, {s0, s}}
    end)
    te = cell(hot, {2, 3, 2})
    assert_in_delta te.source_emf_v, emf.(previous), 1.0e-9
    assert te.source_current_a == 0.0
    assert Map.get(cell(hot, {3, 2, 2}) || %{}, :stored_j, 0.0) == 0.0

    # 闭合 S1（正式工具 7，眼睛在开关正上方）：热电石经 B 正极灌入，B 充电。
    {:ok, _} = use_tool(w, actor({2.5, 2.5, 2.5}), {2 * 8 + 4, 8 + 4, 2 * 8 + 4}, 7)
    charged = commits(w, 40)
    b = cell(charged, {3, 2, 2})
    assert b.stored_j > 0 and b.source_current_a < 0 and b.source_emf_v == 24.0
    assert cell(charged, {2, 3, 2}).source_current_a > 0
    assert_in_delta charged.thermal.circuit_charged_j, b.stored_j, 1.0e-6
    assert charged.thermal.circuit_thermoelectric_j > b.stored_j
    # 旧电源面迁移后只是铜面：不在回路里、不带设备记录，发电不经过它。
    refute Map.has_key?(charged.damage[{3, c.meta["source"]["id"]}], :circuit)
    IO.puts("QINGLAN_MIGRATION removed_j=#{removed} emf=#{te.source_emf_v} stored_j=#{b.stored_j} te_work_j=#{charged.thermal.circuit_thermoelectric_j} elapsed=#{charged.thermal.elapsed_s}")
  end
end
