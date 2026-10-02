defmodule VoxelRegion.FurnaceGeneratorWorldTest do
  @moduledoc """
  只测试（World 集成，Voxim Docs/Testing.md §2.2）：R8-09 实体燃料炉膛发电与 R8-10 温敏陶瓷的长时演化，按生产参数逐提交推进。
  Voxim 双端 `furnace_generator` 只证明玩家入口、权威结果与双端复制；燃尽、衰减、续料对照、充电、断流、休眠、完全静止后由开关事务唤醒（R8-05）与温控的时间演化
  由本文件证明，真实客户端不在墙钟上空等（Testing.md §2.3“短”）。

  参数：目录 = 当前可玩发布 `b4d8bf35…`（含温敏陶瓷 45），只把液体步长改成 3600 s（散体由测试投递 :liquid_commit 落定）；
  热环境 = `environment-radiation.json`（h 10 W/m²K、ε 0.9、容差 1 K、零功率阈值 circuit_min_power_w 1 W，与 Voxim
  `Content/Voxel/Properties/thermal-environment.json` 生产值相同）。没有强对流或其它加速夹具。
  前提：装置几何经作者编辑入口 apply_edits（夹具）；煤／石是 Test-only material_supply 一次记账；之后只经正式工具
  （倾倒 12、K 点燃 9、建造 1、镐 1）。温敏场景的热来自 Test-only 实验热源（有限能量、生产环境值、在原热账上累加）。
  时间只经 :thermal_commit（每笔 0.5 模拟秒）。不注入温度、燃料、电流、储能。

  炉（片 1 推荐布局 `double-1.0-lid-fins`，z = 2 一行，地面 y = 0 石；见 thermoelectric_furnace_sim_test）：
      x: -2,-1 散热片 | 0 冷铜 Bc | 1 热电石 TEb | 2 热铜 Bh | 3 炉膛（倒煤，顶 (3,2,2) 开口盖石）| 4 热铜 Ah | 5 热电石 TEa | 6 冷铜 Ac | 7,8 散热片
  前段 Ac→(6,1,1)→铜 (6..2,1,0)→合金 L2 (2,1,1)→Bh→TEb→Bc。后段二选一：
  - 灯：Bc→(0,1,3)→铜 (0..4,1,4)→合金灯 L1 (4,1,3)→Ah；
  - 充电：Bc→(0,1,3)→(0,1,4)→P (1,1,4)→铜柱 (1,1..4,5)→(2,4,5)→(3,4,5)→蓄能石 (3,3,5) 叠在 (3,2,5) 上（正极 +Y，电流自上而下灌入）
    →(3,1,5)→Q (3,1,4)→(4,1,4)→L1→Ah（与双端片 2 的 S_bat 支路同拓扑，开关换成铜）。

  期望来自目录算术与手算，不取自内核输出：
  - r = d/(σA)：热电石半格 0.5/2 Ω、合金 0.5/4 Ω、蓄能石 0.5/20 Ω、温敏 0.5/10 Ω、铜 0.5/5.8e7 Ω。
    灯回路 ΣR = 4 × 0.25 + 4 × 0.125 = 1.5 Ω，充电回路再加 4 × 0.025 = 1.6 Ω；铜半格全部加起来 < 6e-7 Ω（相对 < 4e-7，
    散热片与铜链的并联支路只改这一项），所以炉子的电流按 1e-6 相对 + 1e-6 A 绝对（求解器电流精度，见 @i_abs）核对。
    温敏回路无并联，铜按 10 个半格精确计入，1e-8 相对。
  - I = Σε/ΣR（灯）；I = (Σε − 2 × 24 V)/ΣR（两块串联蓄能石充电，每块 24 V/m × 1 m）；单笔做功增量 = Σε·I·0.5 s。
  - 零功率判据（R8-05／R8-09 D1）：网络电源输出功率（灯 Σε²/ΣR；充电 Σε·I）不低于 1 W 才导通，否则本笔 0 A；
    判据边界 ±1 % 内不断言。断流后电账（做功、佩尔捷、光）不再变化。
  - 燃料：煤 8e8 J/m³ × 倾倒体积；K 每次 3.125 MJ × 命中散体体积记入供热。
  - 账（每笔）：显热 + 相态焓 − 作者焓 = 供热 + 环境 + 重标 − 移除 − 转化；供热 = 燃烧 + K + 实验热源放出 + 电路净热
    （放电 − 充入 − 光）；吸热 − 放热 = 热电做功（新世界从 0 起）；燃料初始化 = 燃烧 + 弃置 + 还原剂 + 行上余量。

  每个用例打印 `FURNACE_* sim_s=… commits=… wall_ms=…`（模拟时长、提交笔数、墙钟）。
  """
  use ExUnit.Case, async: false
  @moduletag :thermoelectric
  @moduletag timeout: 900_000
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @catalog "b4d8bf35d98ca527df900e049878795ffc6428f51a71f7a14ca2b0a55158607f"
  @cap 2_097_152
  @quarter div(@cap, 4)
  @stone 11
  @coal 15
  @copper 24
  @alloy 40
  @battery 42
  @te 43
  @thermistor 45
  @switch 41
  @materials [@stone, @coal, @copper, @alloy, @battery, @te, @thermistor, @switch]
  @ambient 293.15
  @min_w 1.0
  # 求解器的绝对电流误差：铜边电导 0.5/5.8e7 Ω 的倒数 ~1.2e8 S 乘以 ~50 V 电位的双精度舍入 ~1e-14 V，约 1e-6 A
  # （circuit_test 在 46 A 时 1e-8 相对，同量级）；小电流时它主导，所有电流比对另加这一绝对项（判据经用户 2026-10-02 确认）。
  @i_abs 1.0e-6
  @coal_j_per_m3 8.0e8
  @k_heat_j 3_125_000.0
  @box {{-2, -2, -2}, {2, 2, 2}}
  @bounds {{-3, 0, -1}, {10, 6, 7}}
  @hearth {3, 1, 2}
  @opening {3, 2, 2}
  @te_a {5, 1, 2}
  @te_b {1, 1, 2}
  @b_top {3, 3, 5}
  @b_bot {3, 2, 5}

  setup do
    root = Path.join(System.tmp_dir!(), "furnace_world_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json"))) |> put_in(["liquid", "step_seconds"], 3600)
    env = Jason.decode!(File.read!(Path.join(@fixtures, "environment-radiation.json")))
    # 生产热环境（前提，不是被测量）：h 10、ε 0.9、容差 1 K、零功率阈值 1 W。
    assert Map.take(env, ~w(environment_w_per_m2_k emissivity tolerance_kelvin circuit_min_power_w ambient_kelvin)) ==
             %{"environment_w_per_m2_k" => 10, "emissivity" => 0.9, "tolerance_kelvin" => 1, "circuit_min_power_w" => @min_w,
               "ambient_kelvin" => @ambient}
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    tools = Map.new(data["tools"], &{&1["tool_id"], &1})
    # 手算用的目录值。
    assert materials[@coal]["fuel_energy_per_macro_j"] == @coal_j_per_m3
    assert tools[9]["heat_energy_j"] == @k_heat_j
    assert {materials[@te]["electrical_conductivity"], materials[@alloy]["electrical_conductivity"],
            materials[@battery]["electrical_conductivity"], materials[@thermistor]["electrical_conductivity"],
            materials[@battery]["battery_volts_per_m"], materials[@thermistor]["electrical_cutoff_kelvin"]} == {2, 4, 20, 10, 24, 373.15}
    %{root: root, data: data, env: env, materials: materials}
  end

  # ---- 世界与正式入口

  defp world(c, id) do
    root = Path.join(c.root, "#{id}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    File.write!(Path.join(root, "properties.json"), Jason.encode!(c.data))
    File.write!(Path.join(root, "environment.json"), Jason.encode!(c.env))
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: Path.join(root, "environment.json"),
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: @materials, liquid_bounds: @bounds]
    w = start_supervised!({World, opts}, id: id)
    a = %{cid: 1001, gate: self(), identity: {id, make_ref()}, refresh: &Actor.tool_context/2, eye: {3.5, 4.5, 2.5}, tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}, id: {id, :actor}))
    %{w: w, id: id, opts: opts, root: root, actor: a, ignition: 0.0, experiment: 0.0, materials: c.materials}
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp stamp(f, seq), do: Map.merge(f.actor, %{received_us: seq * 1_000_000, clock_node: node()})

  defp intent(f, action, material, coord, tool) do
    seq = next()
    World.production_intent(f.w, stamp(f, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action,
      material: material, tool_id: tool, coord: coord})
  end

  # 正式工具：从眼睛竖直向下的射线先查询命中身份，再以同一身份执行。
  defp tool_down(f, tool) do
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: tool,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(f.w, f.actor, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    {target, World.tool_intent(f.w, stamp(f, seq), request)}
  end

  # K：从开口正上方向下命中炉膛里的煤，点到燃烧为止；返回被接受的次数。
  defp ignite(f, n) do
    case tool_down(f, 9) do
      {_, {:ok, _}} -> ignite(f, n + 1)
      {_, {:error, :already_burning}} -> n
    end
  end

  # 镐从正上方敲开盖石，直到命中的不再是盖格。
  defp pick_lid(f, n \\ 0) do
    {x, y, z} = @opening
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 1,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(f.w, f.actor, query)
    {tx, ty, tz} = target.micro
    if {div(tx, 8), div(ty, 8), div(tz, 8)} == {x, y, z} and target.material == @stone do
      {_, {:ok, _}} = tool_down(f, 1)
      pick_lid(f, n + 1)
    else
      n
    end
  end

  # 等热调度休眠（无待到期节拍、无进行中的提交）；只读同步，不改状态。
  defp rested(w, left \\ 300) do
    s = :sys.get_state(w)
    cond do
      s.thermal_timer == nil and s.thermal_run == nil -> :ok
      left == 0 -> flunk("thermal scheduler did not rest")
      true -> (Process.sleep(10); rested(w, left - 1))
    end
  end

  defp settle(w, left \\ 2000) do
    send(w, :liquid_commit)
    cond do
      World.liquid_activity(w).active_cells == 0 -> :ok
      left == 0 -> flunk("loose cells did not come to rest")
      true -> settle(w, left - 1)
    end
  end

  defp pour(f, quarters), do: for(_ <- 1..quarters, do: ({:ok, _} = intent(f, 3, @coal, @opening, 12); settle(f.w)))

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp row(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp temperature(s, p), do: Map.get(row(s, p) || %{}, :temperature_kelvin, @ambient)
  defp field(s, p, key), do: Map.get(row(s, p) || %{}, key, 0.0)
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)
  defp occupant(f, p), do: hd(World.material_snapshot(f.w, [], [p]).probe_occupancy).material
  defp emf(s), do: field(s, @te_a, :source_emf_v) + field(s, @te_b, :source_emf_v)
  defp current(s), do: field(s, @te_a, :source_current_a)
  defp burning?(s), do: Enum.any?(Map.values(s.damage), &Map.get(&1, :burning, false))
  defp peak(s), do: Enum.max([@ambient | for({_, r} <- s.damage, Map.has_key?(r, :temperature_kelvin), do: r.temperature_kelvin)])
  defp wall_ms(t0), do: System.monotonic_time(:millisecond) - t0

  # ---- 装置（几何 = 作者编辑夹具）

  defp frame do
    ground = for x <- -2..8, z <- 0..5, do: {{x, 0, z}, @stone}
    row = [{{0, 1, 2}, @copper}, {@te_b, @te}, {{2, 1, 2}, @copper}, {{4, 1, 2}, @copper}, {@te_a, @te}, {{6, 1, 2}, @copper},
      {{3, 1, 1}, @stone}, {{3, 1, 3}, @stone}]
    front = [{{6, 1, 1}, @copper}, {{2, 1, 1}, @alloy}] ++ for(x <- 2..6, do: {{x, 1, 0}, @copper})
    fins = for {x, y, z} <- [{7, 1, 2}, {8, 1, 2}, {7, 2, 2}, {6, 2, 2}, {7, 1, 3}, {7, 1, 1},
                             {-1, 1, 2}, {-2, 1, 2}, {-1, 2, 2}, {0, 2, 2}, {-1, 1, 3}, {-1, 1, 1}], do: {{x, y, z}, @copper}
    ground ++ row ++ front ++ fins
  end

  defp lamp_chain, do: [{{0, 1, 3}, @copper}, {{4, 1, 3}, @alloy}] ++ for(x <- 0..4, do: {{x, 1, 4}, @copper})

  defp charge_chain do
    [{{0, 1, 3}, @copper}, {{4, 1, 3}, @alloy}, {{0, 1, 4}, @copper}, {{1, 1, 4}, @copper}, {{3, 1, 4}, @copper}, {{4, 1, 4}, @copper},
     {{2, 4, 5}, @copper}, {{3, 4, 5}, @copper}, {@b_top, @battery}, {@b_bot, @battery}, {{3, 1, 5}, @copper}] ++
      for(y <- 1..4, do: {{1, y, 5}, @copper})
  end

  defp sigma(f, m), do: f.materials[m]["electrical_conductivity"]
  defp r_lamp(f), do: 4 * 0.5 / sigma(f, @te) + 4 * 0.5 / sigma(f, @alloy)
  defp r_charge(f), do: r_lamp(f) + 4 * 0.5 / sigma(f, @battery)

  # 搭炉、记账供料、倒 quarters × 0.25 m³ 煤、K 点燃、盖石。
  defp furnace(c, id, chain, quarters) do
    f = world(c, id)
    {:ok, _} = World.apply_edits(f.w, frame() ++ chain)
    # 一次记账供料：倒煤 + 一格煤给 K 付煤 + 两格盖石。
    {:ok, _} = World.material_supply(f.w, 1001, "furnace-#{id}", %{@coal => quarters * @quarter + @cap, @stone => 2 * @cap})
    pour(f, quarters)
    assert observe(f.w).liquid_units[@hearth] == quarters * @quarter
    # 点燃与盖石要落在同一模拟时刻（孪生世界按点燃后时刻逐项可比）：先等搭建／倾倒事务唤醒的电路确认拍休眠
    # （点燃前全场是环境温度，这几拍只推进时钟），K 的唤醒拍 500 ms 后才到。
    rested(f.w)
    t0 = observe(f.w).thermal.elapsed_s
    clicks = ignite(f, 0)
    assert clicks >= 1
    # K 每次把 heat_energy_j × 命中散体体积直接记入供热。
    f = %{f | ignition: clicks * @k_heat_j * quarters / 4}
    {:ok, _} = intent(f, 1, @stone, @opening, 1)
    s = observe(f.w)
    assert occupant(f, @opening) == @stone
    assert s.thermal.elapsed_s == t0
    # 燃料：K 点燃整堆散体 = 倒入体积 × 8e8 J/m³。
    assert_in_delta ledger(s, :fuel_initialized_j), quarters / 4 * @coal_j_per_m3, 1.0e-3
    {Map.put(f, :t0, t0), s, clicks}
  end

  # ---- 账（每笔）

  # 非相态节点 C·V·(T − Ta)（散体 V = 数量 / 容量）。
  defp sensible(f, s) do
    for {_, r} <- s.damage, r.granularity in [0, 1], Map.has_key?(r, :temperature_kelvin), not Map.has_key?(r, :phase_energy_j),
      reduce: 0.0,
      do: (sum -> sum + f.materials[r.material]["heat_capacity_per_macro"] * VoxelRegion.Damage.volume(r.granularity) *
        Map.get(s.liquid_units, VoxelRegion.Damage.macro(r), @cap) / @cap * (r.temperature_kelvin - @ambient))
  end

  defp phase_energy(s), do: Enum.sum([0.0 | for({_, r} <- s.damage, Map.has_key?(r, :phase_energy_j), do: r.phase_energy_j)]) +
    Enum.sum([0.0 | for({_, {e, _}} <- s.phase_inventory, do: e)])

  defp assert_ledgers(f, s) do
    supplied = ledger(s, :supplied_j)
    scale = max(1.0, supplied)
    book = supplied + ledger(s, :environment_j) + ledger(s, :parameter_rebase_j) - ledger(s, :removed_j) - ledger(s, :transform_j)
    assert_in_delta sensible(f, s) + phase_energy(s) - ledger(s, :phase_authored_energy_j), book, 1.0e-6 * scale
    circuit = ledger(s, :circuit_supplied_j) - ledger(s, :circuit_charged_j) - ledger(s, :circuit_light_j)
    delivered = f.experiment - Enum.sum([0.0 | for({_, src} <- Map.get(s.thermal, :sources, %{}), do: src.remaining_j)])
    assert_in_delta supplied - delivered - ledger(s, :combustion_j) - f.ignition, circuit, 1.0e-6 * scale
    te = ledger(s, :circuit_thermoelectric_j)
    assert_in_delta ledger(s, :circuit_peltier_absorbed_j) - ledger(s, :circuit_peltier_released_j), te, 1.0e-6 * max(1.0, te)
    left = for {_, r} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(r, :remaining_fuel_j, 0.0))
    fuel = ledger(s, :fuel_initialized_j)
    assert_in_delta fuel, ledger(s, :combustion_j) + ledger(s, :discarded_fuel_j) + ledger(s, :transform_reductant_fuel_j) + left,
      1.0e-6 * max(1.0, fuel)
  end

  # 逐笔推进：每笔核对账；fun.(prev, s, single?, acc) 返回 {:cont | :halt, acc}，single? = 两次取样之间恰好一笔 0.5 s
  # （后台 500 ms 定时提交偶尔插在中间，那一对不做逐笔断言）。limit 笔仍未 halt 即失败。
  defp run(f, s0, acc, limit, fun) do
    Enum.reduce_while(1..limit, {s0, acc}, fn n, {prev, acc} ->
      s = commit(f.w)
      assert_ledgers(f, s)
      single = abs(s.thermal.elapsed_s - prev.thermal.elapsed_s - 0.5) < 1.0e-9
      case fun.(prev, s, single, acc) do
        {:halt, acc} -> {:halt, {s, acc}}
        {:cont, _} when n == limit -> flunk("#{f.id}: #{limit} commits without reaching the stop condition (sim #{s.thermal.elapsed_s} s)")
        {:cont, acc} -> {:cont, {s, acc}}
      end
    end)
  end

  # 灯回路：功率 Σε²/ΣR ≥ 1 W 时 I = Σε/ΣR、两块热电石同一电流、单笔做功 = Σε·I·0.5；< 1 W 时 0 A。
  defp assert_lamp(f, prev, s) do
    e = emf(s)
    i = current(s)
    r = r_lamp(f)
    cond do
      e * e / r >= 1.01 * @min_w ->
        assert_in_delta i, e / r, e / r * 1.0e-6 + @i_abs
        assert_in_delta field(s, @te_b, :source_current_a), i, @i_abs
        dte = ledger(s, :circuit_thermoelectric_j) - ledger(prev, :circuit_thermoelectric_j)
        assert_in_delta dte, e * i * 0.5, abs(dte) * 1.0e-8 + e * @i_abs * 0.5
      e * e / r <= 0.99 * @min_w ->
        assert i == 0.0
      true -> :ok
    end
  end

  # ---- 1. 整炉长时演化：点燃 → 峰值 → 燃尽 → 断流 → 休眠

  test "双热壁炉 1 m³ 煤盖石：K 点燃后峰值 Σε ≥ 48 V；燃尽后电源功率跌破 1 W 那一笔起 0 A、电账冻结；余温衰减到容差内热调度休眠、此后无热提交；逐笔账闭合", c do
    {f, s0, clicks} = furnace(c, :lamp, lamp_chain(), 4)
    t0 = System.monotonic_time(:millisecond)
    acc0 = %{emf_peak: 0.0, peak: @ambient, te_peak: @ambient, lit: nil, burn_end: nil, cut: nil, commits: 0}
    {idle, acc} = run(f, s0, acc0, 80_000, fn prev, s, single, acc ->
      if single, do: assert_lamp(f, prev, s)
      t = s.thermal.elapsed_s
      acc = %{acc | emf_peak: max(acc.emf_peak, emf(s)), peak: max(acc.peak, peak(s)), commits: acc.commits + 1,
        te_peak: Enum.max([acc.te_peak, temperature(s, @te_a), temperature(s, @te_b)]),
        lit: acc.lit || (if current(s) > 0.0, do: t), burn_end: if(burning?(s), do: nil, else: acc.burn_end || t)}
      acc =
        cond do
          acc.cut != nil ->
            # 断流之后不再导通，电能不再转换。
            assert current(s) == 0.0
            {_, cut} = acc.cut
            for key <- [:circuit_thermoelectric_j, :circuit_peltier_absorbed_j, :circuit_peltier_released_j, :circuit_light_j],
              do: assert(ledger(s, key) == ledger(cut, key))
            acc
          acc.lit != nil and current(s) == 0.0 -> %{acc | cut: {prev, s}}
          true -> acc
        end
      if s.thermal.active, do: {:cont, acc}, else: {:halt, acc}
    end)
    wall = wall_ms(t0)
    {flowing, dead} = acc.cut
    r = r_lamp(f)

    # 峰值：两块热壁串联 ≥ 48 V（R8-09 默认决定 2）。
    assert acc.emf_peak >= 48.0
    # 燃尽：1 m³ 煤 = 8e8 J 全部烧完，无弃置；断流发生在燃尽之后。
    assert acc.burn_end != nil and not burning?(idle)
    assert_in_delta ledger(idle, :combustion_j), @coal_j_per_m3, 1.0e-3
    assert ledger(idle, :discarded_fuel_j) == 0.0
    assert dead.thermal.elapsed_s > acc.burn_end
    # 断流笔：前一笔仍导通且 Σε·I ≥ 1 W；这一笔开路 Σε²/ΣR < 1 W。
    assert current(flowing) > 0.0 and emf(flowing) * current(flowing) >= @min_w
    assert current(dead) == 0.0 and field(dead, @te_b, :source_current_a) == 0.0
    assert emf(dead) * emf(dead) / r < @min_w
    # 断流后温度场照常衰减（环境散热继续累计），直到休眠。
    assert ledger(idle, :environment_j) < ledger(dead, :environment_j)
    refute idle.thermal.active
    # 卡诺上限：热输入 = 燃烧 + K。耐热：热电石 < 1400 K 且完整。
    te = ledger(idle, :circuit_thermoelectric_j)
    assert te > 0.0
    assert te <= (ledger(idle, :combustion_j) + f.ignition) * (1.0 - @ambient / acc.peak)
    assert acc.te_peak < c.materials[@te]["heat_resistance_kelvin"]
    for p <- [@te_a, @te_b], do: assert(row(idle, p).hp == row(idle, p).max_hp)
    # 热调度休眠（R8-05：零功率、无其他事务且未改写任何记录的提交才算静止）：热推进停下后，电路按停下时的温度
    # 至多再写一次读数（热电石开路电动势；本笔求解用的是上一笔推进前的温度），再一笔什么都不改写的确认即停——
    # 这两笔不改温度、不改任何热／电账；此后真实定时器窗口里没有热事务（“至多 2 笔”判据经用户 2026-10-02 确认）。
    confirm = window(f.w, 1_200)
    rest = window(f.w, 2_000)
    assert confirm.seq <= 2
    assert physics(confirm.before, [:source_emf_v]) == physics(confirm.after, [:source_emf_v])
    assert rest.seq == 0 and rest.ticks <= 1
    assert physics(rest.before) == physics(rest.after)
    IO.puts("FURNACE_LAMP sim_s=#{idle.thermal.elapsed_s} ignite_s=#{f.t0} commits=#{acc.commits} wall_ms=#{wall} clicks=#{clicks} " <>
      "emf_peak_v=#{acc.emf_peak} lit_s=#{acc.lit} burn_end_s=#{acc.burn_end} cut_s=#{dead.thermal.elapsed_s} " <>
      "cut_flowing_w=#{emf(flowing) * current(flowing)} cut_open_w=#{emf(dead) * emf(dead) / r} sleep_s=#{idle.thermal.elapsed_s} " <>
      "te_j=#{te} absorbed_j=#{ledger(idle, :circuit_peltier_absorbed_j)} released_j=#{ledger(idle, :circuit_peltier_released_j)} " <>
      "light_j=#{ledger(idle, :circuit_light_j)} combustion_j=#{ledger(idle, :combustion_j)} peak_k=#{acc.peak} te_peak_k=#{acc.te_peak} " <>
      "confirm_txns=#{confirm.seq} rest_ticks=#{rest.ticks} rest_txns=#{rest.seq}")
  end

  # 固定观察窗口内数定时器节拍与世界序号变化（同 thermal_activity_world_test）。
  defp window(w, ms) do
    flush_trace()
    s0 = observe(w)
    :erlang.trace(w, true, [:receive])
    Process.sleep(ms)
    :erlang.trace(w, false, [:receive])
    s1 = observe(w)
    %{ticks: flush_trace(), seq: s1.seq - s0.seq, before: s0, after: s1}
  end

  defp flush_trace(n \\ 0) do
    receive do
      {:trace, _, :receive, :thermal_tick} -> flush_trace(n + 1)
      {:trace, _, :receive, _} -> flush_trace(n)
    after 0 -> n
    end
  end

  defp physics(s, readouts \\ []) do
    rows = s.damage |> Map.values() |> Enum.map(&Map.drop(&1, [:seq, :request_id] ++ readouts)) |> Enum.sort()
    {rows, Map.drop(s.thermal, [:elapsed_s])}
  end

  # ---- 2. 续料孪生对照

  @refuel_s 600.0
  @refuel_window_s 900.0
  test "续料孪生：两座 0.5 m³ 煤炉同样点燃盖石、600 s 时同样开盖再盖回，只有一座倒入 0.5 m³；续料后 Σε 高于对照同刻值，Δ燃料初始化 = 0.5 m³ × 8e8 J", c do
    {fa, sa, clicks_a} = furnace(c, :refuel, lamp_chain(), 2)
    {fb, sb, clicks_b} = furnace(c, :control, lamp_chain(), 2)
    assert clicks_a == clicks_b
    t0 = System.monotonic_time(:millisecond)
    until = fn f, s, t ->
      run(f, s, [], 10_000, fn prev, s, single, hist ->
        if single, do: assert_lamp(f, prev, s)
        # 时刻按点燃后计（两座世界点燃前的电路确认拍数可能不同，只推进时钟）。
        hist = [{s.thermal.elapsed_s - f.t0, emf(s), ledger(s, :fuel_initialized_j)} | hist]
        if s.thermal.elapsed_s >= t, do: {:halt, hist}, else: {:cont, hist}
      end)
    end
    {sa, ha} = until.(fa, sa, fa.t0 + @refuel_s)
    {sb, hb} = until.(fb, sb, fb.t0 + @refuel_s)
    # 孪生前提：同一时刻开盖，电动势与燃料逐项相同（只差续料一个动作）。
    assert sa.thermal.elapsed_s == fa.t0 + @refuel_s and sb.thermal.elapsed_s == fb.t0 + @refuel_s
    {ea, eb} = {emf(sa), emf(sb)}
    assert ea > 0.0
    assert_in_delta ea, eb, ea * 1.0e-12
    assert ledger(sa, :fuel_initialized_j) == ledger(sb, :fuel_initialized_j)
    assert burning?(sa) and burning?(sb)

    # 同样开盖、盖回；只有 A 倒煤。
    hits_a = pick_lid(fa)
    hits_b = pick_lid(fb)
    assert hits_a >= 1 and hits_a == hits_b
    pour(fa, 2)
    for f <- [fa, fb], do: {:ok, _} = intent(f, 1, @stone, @opening, 1)
    ra = observe(fa.w)
    rb = observe(fb.w)
    # 开盖、倒煤、盖回这一批动作期间，500 ms 墙钟定时拍可能各自插进一两笔热提交（两座世界不一定相同）；
    # 孪生前提已在动作前逐项核对，之后只按点燃后的同一时刻比较。
    batch = {ra.thermal.elapsed_s - fa.t0 - @refuel_s, rb.thermal.elapsed_s - fb.t0 - @refuel_s}
    assert ra.liquid_units[@hearth] == @cap and rb.liquid_units[@hearth] == div(@cap, 2)
    assert burning?(ra)
    {ea2, ha2} = until.(fa, ra, fa.t0 + @refuel_s + @refuel_window_s)
    {eb2, hb2} = until.(fb, rb, fb.t0 + @refuel_s + @refuel_window_s)
    wall = wall_ms(t0)

    # Δ燃料初始化 = 0.5 m³ × 8e8 J（带火散体合并时按并入数量初始化燃料）；对照仍是点燃时的 0.5 m³。
    assert_in_delta ledger(eb2, :fuel_initialized_j), 0.5 * @coal_j_per_m3, 1.0e-3
    assert_in_delta ledger(ea2, :fuel_initialized_j) - ledger(eb2, :fuel_initialized_j), 0.5 * @coal_j_per_m3, 1.0e-3
    # 续料后同刻比较：后半窗口（续料 + 300 s 起，起点经用户 2026-10-02 确认）每个共同时刻 Σε(续料) > Σε(对照)。
    eb_at = Map.new(hb2, fn {t, e, _} -> {t, e} end)
    pairs = for {t, e, _} <- ha2, t >= @refuel_s + 300.0, Map.has_key?(eb_at, t), do: {t, e, eb_at[t]}
    assert length(pairs) > 500
    for {t, e, e0} <- pairs, do: assert(e > e0, "t=#{t} refuel #{e} V <= control #{e0} V")
    {t_end, e_end, e0_end} = Enum.max_by(pairs, &elem(&1, 0))
    early = for {t, e, _} <- ha2, t < @refuel_s + 300.0, Map.has_key?(eb_at, t), do: {t, e - eb_at[t]}
    IO.puts("FURNACE_REFUEL sim_s=#{ea2.thermal.elapsed_s} ignite_s=#{fa.t0}/#{fb.t0} commits=#{length(ha) + length(hb) + length(ha2) + length(hb2)} wall_ms=#{wall} " <>
      "lid_hits=#{hits_a} refuel_batch_commit_s=#{inspect(batch)} emf_at_refuel=#{ea} emf_end_refuel=#{e_end} emf_end_control=#{e0_end} t_end=#{t_end} " <>
      "fuel_refuel_j=#{ledger(ea2, :fuel_initialized_j)} fuel_control_j=#{ledger(eb2, :fuel_initialized_j)} " <>
      "min_diff_first_300s=#{inspect(Enum.min_by(early, &elem(&1, 1), fn -> nil end))} pairs=#{length(pairs)}")
  end

  # ---- 3. 充电支路

  test "充电支路：两块串联蓄能石（正极 +Y）接在炉子外电路；Σε 越过 48 V 且 Σε·I ≥ 1 W 时 I = (Σε − 48)/ΣR，两块逐笔各充 24·I·0.5 J；Σε 回落到 48 V 止；充入 > 0、逐笔账闭合", c do
    {f, s0, _} = furnace(c, :charge, charge_chain(), 4)
    t0 = System.monotonic_time(:millisecond)
    r = r_charge(f)
    stored = fn s, p -> field(s, p, :stored_j) end
    {last, acc} = run(f, s0, %{charging: 0, emf_peak: 0.0, i_peak: 0.0, commits: 0}, 20_000, fn prev, s, single, acc ->
      e = emf(s)
      i = current(s)
      hand = (e - 48.0) / r
      acc = %{acc | emf_peak: max(acc.emf_peak, e), i_peak: max(acc.i_peak, i), commits: acc.commits + 1}
      # 充入 = 两块储能之和；不放电。
      assert_in_delta ledger(s, :circuit_charged_j), stored.(s, @b_top) + stored.(s, @b_bot), 1.0e-6 * max(1.0, ledger(s, :circuit_charged_j))
      # 串联同一电流：两块储能逐笔相等（差只来自求解器绝对电流误差 @i_abs）。
      assert_in_delta stored.(s, @b_top), stored.(s, @b_bot), 1.0e-6 * stored.(s, @b_top) + 1.0e-6
      assert ledger(s, :circuit_supplied_j) == 0.0
      empty = stored.(prev, @b_top) == 0.0
      acc =
        cond do
          not single -> acc
          hand > 0.0 and e * hand >= 1.01 * @min_w ->
            tol = hand * 1.0e-6 + @i_abs
            assert_in_delta i, hand, tol
            for p <- [@b_top, @b_bot] do
              ib = -field(s, p, :source_current_a)
              assert_in_delta ib, hand, tol
              assert field(s, p, :source_emf_v) == 24.0
              # 每块充入 = 24 V × 本块电流 × 0.5 s（储能按自己这条边的电流记）。
              assert_in_delta stored.(s, p) - stored.(prev, p), 24.0 * ib * 0.5, 24.0 * ib * 0.5 * 1.0e-9
            end
            dte = ledger(s, :circuit_thermoelectric_j) - ledger(prev, :circuit_thermoelectric_j)
            assert_in_delta dte, e * i * 0.5, abs(dte) * 1.0e-8 + e * @i_abs * 0.5
            %{acc | charging: acc.charging + 1}
          hand > 0.0 and e * hand <= 0.99 * @min_w ->
            assert i == 0.0 and stored.(s, @b_top) == stored.(prev, @b_top)
            acc
          empty and hand <= 0.0 ->
            # 空蓄能石不放电，Σε 未过 48 V 时严格 0 A。
            assert i == 0.0
            acc
          true -> acc
        end
      if acc.charging > 0 and hand <= 0.0, do: {:halt, acc}, else: {:cont, acc}
    end)
    wall = wall_ms(t0)
    each = stored.(last, @b_top)
    assert acc.charging > 100
    assert each > 0.0
    assert_in_delta ledger(last, :circuit_charged_j), 2 * each, 1.0e-6 * each
    IO.puts("FURNACE_CHARGE sim_s=#{last.thermal.elapsed_s} commits=#{acc.commits} wall_ms=#{wall} charging_commits=#{acc.charging} " <>
      "emf_peak_v=#{acc.emf_peak} i_peak_a=#{acc.i_peak} stored_each_j=#{each} charged_j=#{ledger(last, :circuit_charged_j)} " <>
      "te_j=#{ledger(last, :circuit_thermoelectric_j)} r_ohm=#{r}")
  end

  # ---- 5. 完全静止后由开关事务唤醒（R8-05）

  # 充电支路（用例 3）把 (2,4,5) 换成开关 S_c；另接一条蓄能石放电支路（z = 6，开关 S_d 断开）：
  #   蓄能石顶 (3,4,5) → (3,4,6) → S_d (4,4,6) → (5,4,6) → 合金灯 L3 (5,3,6) → (5,2,6) → (5,1,6) → (4,1,6) → (3,1,6) → (3,1,5) 蓄能石底。
  # S_c 断开后炉子一侧只挂在 (3,1,5) 上、不成回路；放电回路只含两块蓄能石、L3、S_d 与 8 格铜。
  @s_charge {2, 4, 5}
  @s_discharge {4, 4, 6}
  defp wake_chain do
    (charge_chain() -- [{{2, 4, 5}, @copper}]) ++ [{@s_charge, @switch}] ++
      [{{3, 4, 6}, @copper}, {@s_discharge, @switch}, {{5, 4, 6}, @copper}, {{5, 3, 6}, @alloy}, {{5, 2, 6}, @copper},
       {{5, 1, 6}, @copper}, {{4, 1, 6}, @copper}, {{3, 1, 6}, @copper}] ++ for(x <- -2..8, do: {{x, 0, 6}, @stone})
  end

  # 正式工具 G（7）：从目标正上方的眼睛竖直向下，先查询命中身份再以同一身份切换（同 thermal_activity_world_test）。
  defp toggle(f, {x, y, z}) do
    a = %{cid: 1001, gate: self(), identity: {f.id, make_ref()}, refresh: &Actor.tool_context/2, eye: {x + 0.5, y + 1.5, z + 0.5},
      tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 7,
      direction: {0.0, -1.0, 0.0}, micro: {x * 8 + 4, y * 8 + 4, z * 8 + 4}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(f.w, a, query)
    assert {target.material, VoxelRegion.Damage.macro(target)} == {@switch, {x, y, z}}
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    {:ok, _} = World.tool_intent(f.w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), request)
    observe(f.w)
  end

  # 下一笔带蓄能石行的事务（真实定时器推进，测试不投递提交）。
  defp await_battery(f) do
    receive do
      {:canonical_delta, %{transaction_seq: seq, transaction: %{property_states: rows}}} ->
        case Enum.filter(rows, &(&1.material == @battery and &1.granularity == 0)) do
          [] -> await_battery(f)
          batteries -> {seq, batteries}
        end
    after 3_000 -> flunk("#{f.id}: no battery row within 3 s")
    end
  end

  test "完全静止后由开关唤醒：炉经 S_c 充两块蓄能石后断开，燃尽冷却到休眠、定时器窗口 0 笔；闭合 S_d 的下一笔热事务 I = 48 V／ΣR，每块放 24·I·0.5 J", c do
    {f, s0, _} = furnace(c, :wake, wake_chain(), 4)
    t0 = System.monotonic_time(:millisecond)
    assert row(toggle(f, @s_charge), @s_charge).closed
    stored = fn s, p -> field(s, p, :stored_j) end

    # 充电：Σε 越过 48 V 后经 S_c 充两块蓄能石；回落到 48 V 以下时断开 S_c（玩家动作，事务），之后储能不再变化。
    {charged, n1} = run(f, s0, 0, 20_000, fn _prev, s, _single, n ->
      if stored.(s, @b_top) > 0.0 and emf(s) < 48.0, do: {:halt, n + 1}, else: {:cont, n + 1}
    end)
    open = toggle(f, @s_charge)
    refute row(open, @s_charge).closed
    held = {stored.(open, @b_top), stored.(open, @b_bot)}
    assert elem(held, 0) > 0.0 and elem(held, 0) == stored.(charged, @b_top)

    # 燃尽、断流、冷却，直到热调度不再活跃；储能逐笔不变（两块都只挂在断开的支路上）。
    {idle, n2} = run(f, open, 0, 80_000, fn _prev, s, _single, n ->
      assert {stored.(s, @b_top), stored.(s, @b_bot)} == held
      if s.thermal.active, do: {:cont, n + 1}, else: {:halt, n + 1}
    end)
    refute burning?(idle)
    # 完全静止（R8-05；尾提交至多 2 笔且不改温度与任何账、之后 0 笔，判据经用户 2026-10-02 确认）：
    # 此后真实定时器窗口里没有热事务，世界里只剩两块有储能的蓄能石（电路种子）与两个断开的开关。
    confirm = window(f.w, 1_200)
    rest = window(f.w, 2_000)
    assert confirm.seq <= 2
    assert physics(confirm.before, [:source_emf_v]) == physics(confirm.after, [:source_emf_v])
    assert rest.seq == 0 and rest.ticks <= 1
    assert physics(rest.before) == physics(rest.after)
    still = rest.after

    # 唤醒：闭合 S_d（正式工具，一笔事务）。不投递提交，等真实定时器推进的第一笔热事务。
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(f.w, {{0, 0, 0}, {1, 1, 1}}, self(), ref, false)
    assert_receive {:canonical_snapshot, ^ref, _}
    closed = toggle(f, @s_discharge)
    assert row(closed, @s_discharge).closed
    assert closed.seq == still.seq + 1
    {seq, batteries} = await_battery(f)
    # ΣR：两块蓄能石各两个半格（0.5/20）、L3 两个半格（0.5/4）、S_d 两个半格与 8 格铜各两个半格（0.5/5.8e7）。
    r = 4 * 0.5 / sigma(f, @battery) + 2 * 0.5 / sigma(f, @alloy) + 18 * 0.5 / sigma(f, @copper)
    i = 48.0 / r
    # 开关事务的下一笔就是热事务，两块蓄能石都在这笔里按 I = 48 V／ΣR 放电，各放 24 V × I × 0.5 s。
    assert seq == closed.seq + 1
    assert Enum.sort(Enum.map(batteries, &VoxelRegion.Damage.macro/1)) == Enum.sort([@b_top, @b_bot])
    for b <- batteries do
      assert_in_delta b.source_current_a, i, i * 1.0e-8 + @i_abs
      assert b.source_emf_v == 24.0
      before = stored.(still, VoxelRegion.Damage.macro(b))
      assert_in_delta before - b.stored_j, 24.0 * i * 0.5, 24.0 * i * 0.5 * 1.0e-8
    end
    {before_top, _} = held
    IO.puts("FURNACE_WAKE sim_s=#{still.thermal.elapsed_s} commits=#{n1 + n2} wall_ms=#{wall_ms(t0)} stored_each_j=#{before_top} " <>
      "confirm_txns=#{confirm.seq} rest_ticks=#{rest.ticks} rest_txns=#{rest.seq} switch_seq=#{closed.seq} thermal_seq=#{seq} " <>
      "current_a=#{hd(batteries).source_current_a} hand_a=#{i} r_ohm=#{r}")
  end

  # ---- 4. 温敏陶瓷 45 温控开关

  # z = 2 平面（同 thermal_switch_test，温敏导体换成目录里的 45）：
  #   y = 3：热铜 H (1,3)（实验热源）— 热电石 T (2,3) — 冷铜 C (3,3)
  #   y = 2：铜 (1,2)；电阻合金灯 L (3,2)
  #   y = 1：铜 (1,1) — 温敏陶瓷 R (2,1) — 铜 (3,1)
  @t_cell {2, 3, 2}
  @r_cell {2, 1, 2}
  @lamp {3, 2, 2}
  test "温敏陶瓷 45：低于 373.15 K 时 I = ε/ΣR；R 越过 373.15 K 的下一笔 0 A、灯熄、电动势仍在；冷却到截止以下的下一笔恢复 ε/ΣR；冷重启账逐项相同", c do
    f = world(c, :thermistor)
    ground = for x <- -1..5, z <- 0..4, do: {{x, 0, z}, @stone}
    cells = [{{1, 3, 2}, @copper}, {@t_cell, @te}, {{3, 3, 2}, @copper}, {{1, 2, 2}, @copper}, {@lamp, @alloy},
      {{1, 1, 2}, @copper}, {@r_cell, @thermistor}, {{3, 1, 2}, @copper}]
    {:ok, _} = World.apply_edits(f.w, ground ++ cells)
    energy = 1.0e8
    path = Path.join(f.root, "heat.json")
    File.write!(path, Jason.encode!(Map.merge(Map.take(c.env, ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin emissivity view_range_cells)),
      %{classification: "Test-only", source_macro: [1, 3, 2], power_w: 5.0e5, energy_j: energy})))
    :ok = World.thermal_experiment(f.w, path)
    f = %{f | experiment: energy}
    cutoff = c.materials[@thermistor]["electrical_cutoff_kelvin"]
    # ΣR：T、L、R 各两个半格，铜半格 10 个（H、C、(3,1)、(1,1)、(1,2) 各两个），无并联。
    r = 2 * 0.5 / sigma(f, @te) + 2 * 0.5 / sigma(f, @alloy) + 2 * 0.5 / sigma(f, @thermistor) + 10 * 0.5 / sigma(f, @copper)
    i_of = fn s -> field(s, @t_cell, :source_current_a) end
    e_of = fn s -> field(s, @t_cell, :source_emf_v) end
    t0 = System.monotonic_time(:millisecond)
    acc0 = %{lit: nil, cut: nil, reset: nil, after: 0, commits: 0, r_peak: @ambient}
    {last, acc} = run(f, observe(f.w), acc0, 40_000, fn prev, s, single, acc ->
      acc = %{acc | commits: acc.commits + 1, r_peak: max(acc.r_peak, temperature(s, @r_cell))}
      if single do
        tr = temperature(prev, @r_cell)
        e = e_of.(s)
        i = i_of.(s)
        # 一笔提交先按提交前的温度求解：R 此刻温度 = 上一笔结束时的温度。
        cond do
          tr >= cutoff ->
            assert i == 0.0
            refute Map.has_key?(row(s, @lamp), :electric_w)
          e * e / r >= 1.01 * @min_w -> assert_in_delta i, e / r, e / r * 1.0e-8
          e * e / r <= 0.99 * @min_w -> assert i == 0.0
          true -> :ok
        end
        t = s.thermal.elapsed_s
        cond do
          acc.lit == nil -> {:cont, %{acc | lit: if(i > 0.0, do: t)}}
          acc.cut == nil and tr >= cutoff ->
            # 越过截止的下一笔断开；它前一笔仍导通。
            assert i_of.(prev) > 0.0
            {:cont, %{acc | cut: {t, tr, e}}}
          acc.cut != nil and acc.reset == nil and i > 0.0 ->
            assert tr < cutoff
            {:cont, %{acc | reset: {t, tr, e, i}}}
          acc.reset != nil and acc.after >= 20 -> {:halt, acc}
          acc.reset != nil -> {:cont, %{acc | after: acc.after + 1}}
          true -> {:cont, acc}
        end
      else
        {:cont, acc}
      end
    end)
    wall = wall_ms(t0)
    {cut_s, cut_k, cut_emf} = acc.cut
    {reset_s, reset_k, reset_emf, reset_i} = acc.reset
    assert acc.lit < cut_s and cut_s < reset_s
    # 断开时开路电动势仍在（断的是 R，不是电源）。
    assert cut_emf > 1.0
    assert_in_delta reset_i, reset_emf / r, reset_i * 1.0e-8
    # 冷重启：日志恢复出的属性行与热账逐项相同；恢复后下一笔照常按 ε/ΣR 导通。
    {f, before, restored} = restart(f)
    assert restored.damage == before.damage
    assert Map.drop(restored.thermal, [:active]) == Map.drop(before.thermal, [:active])
    after_restart = commit(f.w)
    assert_ledgers(f, after_restart)
    assert_in_delta i_of.(after_restart), e_of.(after_restart) / r, i_of.(after_restart) * 1.0e-8
    assert i_of.(after_restart) > 0.0
    IO.puts("FURNACE_THERMISTOR sim_s=#{last.thermal.elapsed_s} commits=#{acc.commits} wall_ms=#{wall} lit_s=#{acc.lit} " <>
      "cut_s=#{cut_s} r_k_at_cut=#{cut_k} open_emf_at_cut=#{cut_emf} reset_s=#{reset_s} r_k_at_reset=#{reset_k} " <>
      "reset_i=#{reset_i} hand_i=#{reset_emf / r} r_peak_k=#{acc.r_peak} r_ohm=#{r}")
  end

  # 冻结 World（没有进行中的提交）后取原始状态；返回时进程仍挂起。
  defp frozen(w) do
    :sys.suspend(w)
    s = :sys.get_state(w)
    if s.thermal_run == nil, do: s, else: (:sys.resume(w); Process.sleep(2); frozen(w))
  end

  defp restart(f) do
    before = frozen(f.w)
    :ok = stop_supervised(f.id)
    w = start_supervised!({World, f.opts}, id: f.id)
    restored = frozen(w)
    :sys.resume(w)
    {%{f | w: w}, before, restored}
  end
end
