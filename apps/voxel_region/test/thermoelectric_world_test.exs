defmodule VoxelRegion.ThermoelectricWorldTest do
  @moduledoc """
  只测试：R8-09 片 1——热电石发电的世界级能量账（Voxim Docs/R8/plan.md §R8-09）。经真实 World 的作者编辑、
  Test-only 实验热源／作者供料、正式工具（倾倒、K 点燃）、热提交、日志与冷恢复。

  双热壁串联炉（z = 2 一行，地面 y = 0 石）：
      x:  0 冷铜 Bc | 1 热电石 TEb | 2 热铜 Bh | 3 炉膛 | 4 热铜 Ah | 5 热电石 TEa | 6 冷铜 Ac
  炉膛前后 (3,1,1)(3,1,3) 石。串联回路 Ah→TEa→Ac→(6,1,1)→z = 0 铜链 (6..2,1,0)→合金桥 L2 (2,1,1)→Bh→TEb→Bc→
  (0,1,3)→z = 4 铜链 (0..4,1,4)→合金灯 L1 (4,1,3)→Ah。冷热之间的两处跨接都经电阻合金（k 25），不用铜直连（铜链 4000 W/K
  会把冷热短路）。电阻：热电石四个半格 4 × 0.25 Ω + 两块合金四个半格 4 × 0.125 Ω + 32 个铜半格 0.5/σ_Cu。

  期望来自目录算术（r = d/(σA)、ε = S·ΔT_i）与账目恒等式，不取自内核输出：
  - 显热账：带温度记录的非相态节点 C·V·(T − Ta) = 供热 + 环境交换 + 重标 − 移除 − 转化吸热；
  - 供热分解：供热 = 实验热源放出 + 燃烧 + 电路净热（放电 − 充入 − 光），本装置无蓄能石，电路净热 = −光；
  - 佩尔捷分项：Δ吸热 − Δ放热 = Δ热电做功，Δ 从佩尔捷键引入世界时起算（新世界与实验入口重置的账从 0 起，基线全 0；
    片 1 之前已累计热电做功的世界升级后，基线 = 回放时的热电做功，佩尔捷键从 0 起，不补造历史值）；
    每笔 0.5 s 提交的做功增量 = Σ 行上电动势 × 电流 × 0.5；
  - 卡诺上限：热电做功 ≤ 热输入 × (1 − Ta/T峰)。
  """
  use ExUnit.Case, async: false
  @moduletag :thermoelectric
  @moduletag timeout: 600_000
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @catalog "b88329ab0d3652c30f67d012fce04fd30afd7fd6dcc263e5066ba0b08f90284f"
  @cap 2_097_152
  @stone 11
  @coal 15
  @ice 20
  @copper 24
  @alloy 40
  @te 43
  @ambient 293.15
  @box {{-2, -2, -2}, {2, 2, 2}}
  @bounds {{-3, 0, -1}, {10, 6, 6}}

  setup do
    root = Path.join(System.tmp_dir!(), "thermoelectric_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @catalog <> ".json"))) |> put_in(["liquid", "step_seconds"], 3600)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [@stone, @coal, @ice, @copper, @alloy, @te], liquid_bounds: @bounds]
    w = start_supervised!({World, opts}, id: :world)
    %{w: w, opts: opts, root: root, materials: Map.new(data["materials"], &{&1["material_id"], &1})}
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp temperature(s, coord), do: Map.get(cell(s, coord) || %{}, :temperature_kelvin, @ambient)
  defp sigma(c, m), do: c.materials[m]["electrical_conductivity"]

  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  # 双热壁串联炉的固定部分（炉膛格由各场景自己放）。
  @te_a {5, 1, 2}
  @te_b {1, 1, 2}
  defp generator(c, hearth) do
    ground = for x <- -2..8, z <- 0..4, do: {{x, 0, z}, @stone}
    row = [{{0, 1, 2}, @copper}, {{1, 1, 2}, @te}, {{2, 1, 2}, @copper}, {{4, 1, 2}, @copper}, {{5, 1, 2}, @te},
      {{6, 1, 2}, @copper}, {{3, 1, 1}, @stone}, {{3, 1, 3}, @stone}]
    front = [{{6, 1, 1}, @copper}, {{2, 1, 1}, @alloy}] ++ for(x <- 2..6, do: {{x, 1, 0}, @copper})
    back = [{{0, 1, 3}, @copper}, {{4, 1, 3}, @alloy}] ++ for(x <- 0..4, do: {{x, 1, 4}, @copper})
    {:ok, _} = World.apply_edits(c.w, ground ++ row ++ front ++ back ++ hearth)
  end

  # 回路电阻（目录算术）。
  defp loop_r(c), do: 4 * 0.5 / sigma(c, @te) + 4 * 0.5 / sigma(c, @alloy) + 32 * 0.5 / sigma(c, @copper)

  defp experiment(c, name, macro, power, energy, h \\ 10.0) do
    path = Path.join(c.root, "#{name}.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(macro), ambient_kelvin: @ambient,
      environment_w_per_m2_k: h, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8, power_w: power, energy_j: energy}))
    :ok = World.thermal_experiment(c.w, path)
  end

  # 非相态节点 C·V·(T − Ta)（散体 V = 数量 / 容量）。
  defp sensible(c, s) do
    for {_, r} <- s.damage, r.granularity in [0, 1], Map.has_key?(r, :temperature_kelvin), not Map.has_key?(r, :phase_energy_j),
      reduce: 0.0,
      do: (sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] * VoxelRegion.Damage.volume(r.granularity) *
        Map.get(s.liquid_units, VoxelRegion.Damage.macro(r), @cap) / @cap * (r.temperature_kelvin - @ambient))
  end

  # 相态焓：格上记录的焓（Phase.energy 的真值）加角色相态库存焓。
  defp phase_energy(s), do: Enum.sum([0.0 | for({_, r} <- s.damage, Map.has_key?(r, :phase_energy_j), do: r.phase_energy_j)]) +
    Enum.sum([0.0 | for({_, {e, _}} <- s.phase_inventory, do: e)])

  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)
  defp delivered(s, energy), do: energy - Enum.sum([0.0 | for({_, src} <- s.thermal.sources, do: src.remaining_j)])

  # 每次取样都要成立的账（tol 相对供热）。energy = 实验热源总能量；c.ignition = K 直接记入供热的点燃热（目录算术）。
  defp assert_ledgers(c, s, energy) do
    supplied = ledger(s, :supplied_j)
    scale = max(1.0, supplied)
    book = supplied + ledger(s, :environment_j) + ledger(s, :parameter_rebase_j) - ledger(s, :removed_j) - ledger(s, :transform_j)
    # 作者供给的相态材料带作者焓入账（phase_authored_energy_j），之后随热交换变化：显热 + 相态焓 − 作者焓 = 账。
    assert_in_delta sensible(c, s) + phase_energy(s) - ledger(s, :phase_authored_energy_j), book, 1.0e-6 * scale
    # 供热分解：电路净热 = 放电 − 充入 − 光。
    circuit = ledger(s, :circuit_supplied_j) - ledger(s, :circuit_charged_j) - ledger(s, :circuit_light_j)
    assert_in_delta supplied - delivered(s, energy) - ledger(s, :combustion_j) - Map.get(c, :ignition, 0.0), circuit,
      1.0e-6 * scale
    assert_peltier(s, Map.get(c, :peltier_base, {0.0, 0.0, 0.0}))
  end

  # 佩尔捷恒等式只对键引入之后的增量成立：base = 引入时的 {吸热, 放热, 热电做功}。
  defp assert_peltier(s, {absorbed0, released0, te0}) do
    dte = ledger(s, :circuit_thermoelectric_j) - te0
    assert_in_delta (ledger(s, :circuit_peltier_absorbed_j) - absorbed0) - (ledger(s, :circuit_peltier_released_j) - released0),
      dte, 1.0e-6 * max(1.0, abs(dte))
  end

  defp te_rows(s), do: for(p <- [@te_a, @te_b], do: cell(s, p))
  defp emf(s), do: Enum.sum(for r <- te_rows(s), do: Map.get(r || %{}, :source_emf_v, 0.0))
  defp current(s), do: Map.get(cell(s, @te_a) || %{}, :source_current_a, 0.0)
  defp peak(s), do: Enum.max([@ambient | for({_, r} <- s.damage, Map.has_key?(r, :temperature_kelvin), do: r.temperature_kelvin)])

  # 逐笔提交：账、单笔做功增量 = Σε·I·0.5、I = Σε/ΣR；返回 {末快照, 统计}。stop?(s, acc) 为真或达到 limit 笔停。
  defp run(c, s0, energy, stop?, limit, acc \\ nil) do
    acc = acc || %{peak: @ambient, te_peak: @ambient, emf_peak: 0.0, steps: 0, checked: 0, commits: 0}
    Enum.reduce_while(1..limit, {s0, acc}, fn _, {prev, acc} ->
      s = commit(c.w)
      assert_ledgers(c, s, energy)
      acc = %{acc | peak: max(acc.peak, peak(s)), te_peak: Enum.max([acc.te_peak | for(p <- [@te_a, @te_b], do: temperature(s, p))]),
        emf_peak: max(acc.emf_peak, emf(s)), commits: acc.commits + 1}
      # 只在两次取样之间恰好一笔 0.5 s 提交时核对单笔增量（后台 500 ms 定时提交可能插在中间）。
      acc =
        if abs(s.thermal.elapsed_s - prev.thermal.elapsed_s - 0.5) < 1.0e-9 and current(s) != 0.0 do
          i = emf(s) / loop_r(c)
          assert_in_delta current(s), i, abs(i) * 1.0e-8
          dte = ledger(s, :circuit_thermoelectric_j) - ledger(prev, :circuit_thermoelectric_j)
          assert_in_delta dte, emf(s) * current(s) * 0.5, abs(dte) * 1.0e-8 + 1.0e-9
          %{acc | checked: acc.checked + 1}
        else
          acc
        end
      if stop?.(s, acc), do: {:halt, {s, acc}}, else: {:cont, {s, acc}}
    end)
  end

  # 冻结 World（没有进行中的提交）后取原始状态；返回时进程仍挂起。
  defp frozen(w) do
    :sys.suspend(w)
    s = :sys.get_state(w)
    if s.thermal_run == nil, do: s, else: (:sys.resume(w); Process.sleep(2); frozen(w))
  end

  defp restart(c) do
    before = frozen(c.w)
    :ok = stop_supervised(:world)
    w = start_supervised!({World, c.opts}, id: :world)
    restored = frozen(w)
    :sys.resume(w)
    {%{c | w: w}, before, restored}
  end

  test "整格炉 + Test-only 有限热源：每笔账闭合、单笔做功 = Σε·I·Δt、卡诺上限、不越过耐热；热源耗尽后衰减；冷重启账逐项相同；生产环境下功率低于 1 W 断流、余温衰减后热调度休眠", c do
    # 炉膛 = 一格石（实验热源所在格），上盖一格石。
    generator(c, [{{3, 1, 2}, @stone}, {{3, 2, 2}, @stone}])
    power = 150_000.0
    energy = 7.5e7
    experiment(c, "hearth", {3, 1, 2}, power, energy)
    s0 = observe(c.w)
    started = System.monotonic_time(:millisecond)
    {hot, acc} = run(c, s0, energy, fn s, _ -> s.thermal.sources == %{} end, 4000)
    assert hot.thermal.sources == %{}
    wall = System.monotonic_time(:millisecond) - started
    assert acc.checked > 100
    te = ledger(hot, :circuit_thermoelectric_j)
    assert te > 0.0
    # 卡诺上限（热输入 = 实验热源放出；本场景无燃烧）。
    assert te <= delivered(hot, energy) * (1.0 - @ambient / acc.peak)
    # 耐热：热电石 1400 K、铜 1800 K 以内，热电石完整。
    assert acc.te_peak < c.materials[@te]["heat_resistance_kelvin"]
    for p <- [@te_a, @te_b], do: assert(cell(hot, p).hp == cell(hot, p).max_hp)
    IO.puts("TE_HEARTH sim_s=#{hot.thermal.elapsed_s} commits=#{acc.commits} wall_ms=#{wall} checked=#{acc.checked} " <>
      "te_j=#{te} absorbed_j=#{ledger(hot, :circuit_peltier_absorbed_j)} released_j=#{ledger(hot, :circuit_peltier_released_j)} " <>
      "light_j=#{ledger(hot, :circuit_light_j)} emf_peak=#{acc.emf_peak} peak_k=#{acc.peak} te_peak_k=#{acc.te_peak} " <>
      "Ah=#{temperature(hot, {4, 1, 2})} Ac=#{temperature(hot, {6, 1, 2})} hearth=#{temperature(hot, {3, 1, 2})}")

    # 热源耗尽后：电动势越过峰值后衰减（炉膛余热先流向热壁，峰值可能晚于耗尽）。
    {cooling, acc2} = run(c, hot, energy, fn s, a -> a.commits >= 200 and emf(s) < 0.8 * a.emf_peak end, 4000)
    assert emf(cooling) < 0.8 * acc2.emf_peak and current(cooling) > 0.0
    IO.puts("TE_HEARTH_COOL sim_s=#{cooling.thermal.elapsed_s} emf=#{emf(cooling)} emf_peak=#{acc2.emf_peak} current=#{current(cooling)}")
    # 生产环境（h = 10）下的衰减速度：再推进 400 笔，按指数 I ∝ e^(−t/τ) 估时间常数，据此给出两个独立的时间界：
    # 旧判据（求解器零阈值 1e-10 A）的断流时刻 τ·ln(I/1e-10)，与新判据（电源输出功率 P = I²·ΣR 低于环境资产
    # circuit_min_power_w）的断流时刻 (τ/2)·ln(P/P_min)。
    {tail, _} = run(c, cooling, energy, fn _, _ -> false end, 400)
    tau = (tail.thermal.elapsed_s - cooling.thermal.elapsed_s) / :math.log(current(cooling) / current(tail))
    min_w = Jason.decode!(File.read!(Keyword.fetch!(c.opts, :thermal_environment_path)))["circuit_min_power_w"]
    old_zero_s = tau * :math.log(current(tail) / 1.0e-10)
    cut_s = tau / 2 * :math.log(current(tail) * current(tail) * loop_r(c) / min_w)
    IO.puts("TE_HEARTH_TAU tau_s=#{tau} current=#{current(tail)} projected_s_to_1e-10A=#{old_zero_s} projected_s_to_#{min_w}W=#{cut_s}")

    # 冷重启：日志恢复出的属性行与热账逐项相同（挂起 World，取无进行中提交的原始状态）。
    {c, before, restored} = restart(c)
    assert restored.damage == before.damage
    assert Map.drop(restored.thermal, [:active]) == Map.drop(before.thermal, [:active])
    assert restored.thermal.circuit_peltier_absorbed_j == before.thermal.circuit_peltier_absorbed_j
    assert restored.thermal.circuit_peltier_released_j == before.thermal.circuit_peltier_released_j
    after_restart = observe(c.w)
    assert_ledgers(c, after_restart, energy)

    # 生产环境（实验文件 = 生产 h = 10 W/m²K、ε 0.9、容差 1 K；电路零功率阈值沿用环境资产 1 W）下继续推进，
    # 不换环境、不重置热账：电源输出功率 Σε·I 降到 1 W 以下的那一笔起回路断流（R8-05／R8-09 零功率判据），
    # 余温照常由热内核衰减到容差内，随后热调度自行休眠。旧判据（求解器 1e-10 A）在这里要上万模拟秒才断流。
    # 界：断流在模型时刻的 2 倍之内（按笔数 ceil(2·cut_s/0.5) 截止）；休眠早于旧判据的断流时刻（旧判据下电流未断不可能休眠）。
    {flowing, dead, acc3} = run_until_zero(c, after_restart, energy, ceil(2 * cut_s / 0.5))
    assert dead.thermal.elapsed_s - tail.thermal.elapsed_s <= 2 * cut_s
    assert current(dead) == 0.0
    assert Enum.all?(te_rows(dead), &(Map.get(&1, :source_current_a, 0.0) == 0.0))
    # 断流前最后一笔仍按 I = Σε/ΣR 导通且 Σε·I ≥ 1 W；断流这一笔开路 Σε²/ΣR < 1 W（单串回路，Σε 取两块热电石行上的电动势）。
    assert emf(flowing) * current(flowing) >= 1.0
    assert emf(dead) * emf(dead) / loop_r(c) < 1.0
    # 断流后电能不转换：热电做功、佩尔捷吸放热与光账此后不变，温度场照常演化（每笔账仍闭合）。
    {idle, acc4} = run(c, dead, energy, fn s, _ -> not s.thermal.active end,
      ceil((tail.thermal.elapsed_s + old_zero_s - dead.thermal.elapsed_s) / 0.5))
    refute idle.thermal.active
    assert idle.thermal.elapsed_s < tail.thermal.elapsed_s + old_zero_s
    for key <- [:circuit_thermoelectric_j, :circuit_peltier_absorbed_j, :circuit_peltier_released_j, :circuit_light_j],
      do: assert(ledger(idle, key) == ledger(dead, key))
    assert idle.thermal.environment_j < dead.thermal.environment_j
    # 热调度休眠：最后一笔降温提交之后，零功率网络按新温度至多再确认一次，此后真实定时器窗口里没有热事务。
    confirm = window(c.w, 1_200)
    rest = window(c.w, 2_000)
    IO.puts("TE_HEARTH_ZERO commits=#{acc3.commits} sim_s=#{dead.thermal.elapsed_s} emf=#{emf(dead)} flowing_w=#{emf(flowing) * current(flowing)} " <>
      "Ah=#{temperature(dead, {4, 1, 2})} Ac=#{temperature(dead, {6, 1, 2})} hearth=#{temperature(dead, {3, 1, 2})}")
    IO.puts("TE_HEARTH_SLEEP commits=#{acc4.commits} sim_s=#{idle.thermal.elapsed_s} confirm_txns=#{confirm.seq} rest_ticks=#{rest.ticks} " <>
      "rest_txns=#{rest.seq} hearth=#{temperature(idle, {3, 1, 2})} peak=#{peak(idle)}")
    assert confirm.seq <= 1
    assert rest.seq == 0 and rest.ticks <= 1
    assert physics(rest.before) == physics(rest.after)
  end

  # 逐笔推进（账、单笔做功同 run/6）直到两块热电石电流都为 0；返回 {断流前一笔, 断流笔, 统计}。
  defp run_until_zero(c, s0, energy, limit, acc \\ nil) do
    {s, acc} = run(c, s0, energy, fn _, _ -> true end, 1, acc)
    cond do
      current(s) == 0.0 -> {s0, s, acc}
      acc.commits >= limit -> flunk("#{acc.commits} 笔后电流仍为 #{current(s)} A（Σε #{emf(s)} V）")
      true -> run_until_zero(c, s, energy, limit, acc)
    end
  end

  # 固定观察窗口内数定时器节拍（进程接收事件）与世界序号变化（同 thermal_activity_world_test）。
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

  defp physics(s) do
    rows = s.damage |> Map.values() |> Enum.map(&Map.drop(&1, [:seq, :request_id])) |> Enum.sort()
    {rows, Map.drop(s.thermal, [:elapsed_s])}
  end

  # ---- 散体煤炉膛：正式倾倒（工具 12，每次 0.25 m³）→ K 点燃 → 燃烧中续料；限定窗口（各 300 笔 = 150 模拟秒）。

  defp intent(c, actor, action, material, coord, tool) do
    seq = next()
    World.production_intent(c.w, Map.merge(actor, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, material: material,
        tool_id: tool, coord: coord})
  end

  defp settle(w) do
    send(w, :liquid_commit)
    if World.liquid_activity(w).active_cells > 0, do: settle(w), else: :ok
  end

  # K：从开口正上方竖直向下命中炉膛里最上面的煤，点到燃烧为止；返回成功次数。
  defp ignite(c, actor, n \\ 0) do
    query = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 9,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, actor, query)
    seq = next()
    request = Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{action: 1, request_id: seq, client_intent_seq: seq})
    case World.tool_intent(c.w, Map.merge(actor, %{received_us: seq * 1_000_000, clock_node: node()}), request) do
      {:ok, _} -> ignite(c, actor, n + 1)
      {:error, :already_burning} -> n
    end
  end

  # 燃料账：初始化 = 燃烧 + 弃置 + 还原剂消耗 + 行上余量。
  defp assert_fuel_closes(s) do
    left = for {_, row} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(row, :remaining_fuel_j, 0.0))
    assert_in_delta ledger(s, :fuel_initialized_j),
      ledger(s, :combustion_j) + ledger(s, :discarded_fuel_j) + ledger(s, :transform_reductant_fuel_j) + left,
      1.0e-6 * max(1.0, ledger(s, :fuel_initialized_j))
  end

  test "散体煤炉：从 1 m 开口倒 2 × 0.25 m³ 煤、K 点燃发电；燃烧中再倒 2 × 0.25 m³ 续料，电动势回升、仍在发电；每笔账与燃料账闭合", c do
    generator(c, [])
    a = actor({3.5, 4.5, 2.5})
    # Test-only 作者供料一次（记账）；之后只经正式倾倒与 K 消费。
    {:ok, _} = World.material_supply(c.w, 1001, "te-furnace", %{@coal => 6 * div(@cap, 4)})
    for _ <- 1..2, do: ({:ok, _} = intent(c, a, 3, @coal, {3, 2, 2}, 12); settle(c.w))
    charged = observe(c.w)
    assert charged.liquid_units[{3, 1, 2}] == div(@cap, 2)
    clicks = ignite(c, a)
    assert clicks >= 1
    # K 每次把 heat_energy_j × 目标体积直接记入供热（工具 9 目录值；散体体积 = 0.5 m³）。
    k = 3_125_000.0
    c = Map.put(c, :ignition, clicks * k * 0.5)
    {lit, acc} = run(c, observe(c.w), 0.0, fn _, _ -> false end, 300)
    assert current(lit) > 0.0 and acc.checked > 100
    assert_fuel_closes(lit)
    before = emf(lit)
    te_before = ledger(lit, :circuit_thermoelectric_j)

    # 燃烧中续料：同一开口再倒 2 × 0.25 m³，带火散体合并（燃料随数量初始化入账）。
    for _ <- 1..2, do: ({:ok, _} = intent(c, a, 3, @coal, {3, 2, 2}, 12); settle(c.w))
    refueled = observe(c.w)
    assert refueled.liquid_units[{3, 1, 2}] == @cap
    assert cell(refueled, {3, 1, 2}).burning
    {late, acc2} = run(c, refueled, 0.0, fn _, _ -> false end, 300)
    assert acc2.checked > 100
    assert current(late) > 0.0
    assert emf(late) > before
    assert ledger(late, :circuit_thermoelectric_j) > te_before
    assert_fuel_closes(late)
    assert acc2.te_peak < c.materials[@te]["heat_resistance_kelvin"]
    # 卡诺上限：热输入 = 燃烧放热 + 点燃热。
    assert ledger(late, :circuit_thermoelectric_j) <= (ledger(late, :combustion_j) + c.ignition) * (1.0 - @ambient / max(acc.peak, acc2.peak))
    IO.puts("TE_LOOSE clicks=#{clicks} emf_at_refuel=#{before} emf_end=#{emf(late)} current_end=#{current(late)} " <>
      "te_j=#{ledger(late, :circuit_thermoelectric_j)} combustion_j=#{ledger(late, :combustion_j)} " <>
      "coal_k=#{temperature(late, {3, 1, 2})} Ah=#{temperature(late, {4, 1, 2})} Ac=#{temperature(late, {6, 1, 2})}")
  end

  # ---- 冰作冷端：同一整格炉在两个世界里并排推进，只差冷铜顶上的整格冰（作者供料一次、正式建造放下）。
  # 冰不是可倾倒的流动材料，只能整格放；整格冰潜热 334 MJ，本装置冷端只给每块冰约 2.7 kW，化完要 ~1.2e5 模拟秒，
  # “冰化完后输出下降”不在本用例窗口内（数字随 TE_ICE 打印）。

  defp twin(c) do
    root = Path.join(c.root, "twin")
    File.mkdir_p!(Path.join(root, "prefabs"))
    File.cp!(Path.join(c.root, "properties.json"), Path.join(root, "properties.json"))
    File.cp!(Path.join(c.root, "environment.json"), Path.join(root, "environment.json"))
    opts = Keyword.merge(c.opts, root: root, property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"), prefab_catalog_path: Path.join(root, "prefabs"))
    %{c | w: start_supervised!({World, opts}, id: :twin), root: root, opts: opts}
  end

  test "冰作冷端：整格冰的潜热按相态焓入账（显热 + 焓 − 作者焓 = 账）；冰保持 273.15 K、冷铜更冷、电动势高于无冰对照", c do
    hearth = [{{3, 1, 2}, @stone}, {{3, 2, 2}, @stone}]
    generator(c, hearth)
    other = twin(c)
    generator(other, hearth)
    energy = 7.5e7
    experiment(c, "hearth", {3, 1, 2}, 150_000.0, energy)
    experiment(other, "hearth", {3, 1, 2}, 150_000.0, energy)
    # 实验入口重置热账之后再供冰：作者焓记入新账。
    a = actor({3.5, 4.5, 2.5})
    {:ok, _} = World.material_supply(c.w, 1001, "te-ice", %{@ice => 2 * @cap})
    supplied = observe(c.w)
    # 作者焓（Phase.energy，固相供给温度取 min(Ta, 转变点)）：Ta = 293.15 K > 273.15 K，供给冰在转变点、焓 0。
    ice = c.materials[@ice]
    authored = 2 * ice["heat_capacity_per_macro"] * (min(@ambient, ice["phase_transition_kelvin"]) - ice["phase_transition_kelvin"])
    assert_in_delta ledger(supplied, :phase_authored_energy_j), authored, 1.0e-6
    for p <- [{6, 2, 2}, {0, 2, 2}], do: assert({:ok, _} = intent(c, a, 1, @ice, p, 1))
    placed = observe(c.w)
    e0 = for p <- [{6, 2, 2}, {0, 2, 2}], do: cell(placed, p).phase_energy_j
    {iced, acc} = run(c, placed, energy, fn _, _ -> false end, 600)
    {plain, _} = run(other, observe(other.w), energy, fn _, _ -> false end, 600)
    assert acc.checked > 100
    for {p, e} <- Enum.zip([{6, 2, 2}, {0, 2, 2}], e0) do
      row = cell(iced, p)
      # 仍是冰（焓未到潜热），温度钉在转变点；吸热只增加焓。
      assert row.material == @ice
      assert row.temperature_kelvin == ice["phase_transition_kelvin"]
      assert row.phase_energy_j > e and row.phase_energy_j < ice["latent_heat_per_macro_j"]
    end
    assert temperature(iced, {6, 1, 2}) < temperature(plain, {6, 1, 2})
    assert emf(iced) > emf(plain)
    absorbed = Enum.sum(for p <- [{6, 2, 2}, {0, 2, 2}], do: cell(iced, p).phase_energy_j) - Enum.sum(e0)
    IO.puts("TE_ICE sim_s=#{iced.thermal.elapsed_s} ice_absorbed_j=#{absorbed} ice_left_to_melt_j=#{2 * ice["latent_heat_per_macro_j"] - Enum.sum(e0) - absorbed} " <>
      "emf_ice=#{emf(iced)} emf_plain=#{emf(plain)} Ac_ice=#{temperature(iced, {6, 1, 2})} Ac_plain=#{temperature(plain, {6, 1, 2})}")
  end

  # ---- 旧检查点：增量 3 之前的服务端代码记录的日志（fixtures/energy_migration）。热电做功键在增量 3 才引入，所以这份日志里
  # 热电做功与佩尔捷键都缺、升级后一起从 0 起算（基线全 0）。真实的升级路径是下一个用例的 master 时代检查点。

  @oldest "0b2bb0b6e47e5fe52aa4393f9e8eaae7f68aac7cd42af01f8269df89a725f172"
  @published "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  test "增量 3 之前的旧日志（热电与佩尔捷键都缺）：回放后一起按 0 起算；迁移发布后整格煤炉（K 点燃）发电，吸热 − 放热 = 热电做功，重启后逐项相同", c do
    root = Path.join(c.root, "old")
    File.mkdir_p!(root)
    File.cp!(Path.expand("fixtures/energy_migration/overlay.log", __DIR__), Path.join(root, "overlay.log"))
    File.cp!(Path.join(@fixtures, @oldest <> ".json"), Path.join(root, "properties.json"))
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), Path.join(root, "environment.json"))
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: Path.join(root, "environment.json"),
      production_materials: [9, @stone, @coal, 23, @copper, @alloy, 41, 42, @te]]
    c = %{c | w: start_supervised!({World, opts}, id: :old), opts: opts}
    before = observe(c.w)
    for key <- [:circuit_peltier_absorbed_j, :circuit_peltier_released_j, :circuit_thermoelectric_j],
      do: refute(Map.has_key?(before.thermal, key))
    :ok = World.publish_parameters(c.w, Path.join(@fixtures, @published <> ".json"), before.property_digest)
    File.cp!(Path.join(@fixtures, @published <> ".json"), Path.join(root, "properties.json"))
    migrated = observe(c.w)
    refute Map.has_key?(migrated.thermal, :circuit_peltier_absorbed_j)
    removed = ledger(migrated, :circuit_removed_j)

    # 整格煤炉（z = 2，旧世界设备在 x ≤ 4）：煤 (10,3,2) 烧热铜 H (11,3,2)，热电石 (12,3,2)，冷铜 (13,3,2)；
    # 回路 H→T→C→合金 (13,2,2)→铜 (13,1,2)(12,1,2)(11,1,2)(11,2,2)→H；煤下垫石柱。
    ground = for x <- 8..15, z <- 0..4, do: {{x, 0, z}, @stone}
    cells = [{{10, 1, 2}, @stone}, {{10, 2, 2}, @stone}, {{10, 3, 2}, @coal}, {{11, 3, 2}, @copper}, {{12, 3, 2}, @te},
      {{13, 3, 2}, @copper}, {{13, 2, 2}, @alloy}, {{13, 1, 2}, @copper}, {{12, 1, 2}, @copper}, {{11, 1, 2}, @copper},
      {{11, 2, 2}, @copper}]
    {:ok, _} = World.apply_edits(c.w, ground ++ cells)
    {:ok, _} = World.material_supply(c.w, 1001, "te-old", %{@coal => @cap})
    clicks = ignite(c, actor({10.5, 4.5, 2.5}))
    assert clicks >= 1
    s = Enum.reduce_while(1..3000, nil, fn _, _ ->
      s = commit(c.w)
      if ledger(s, :circuit_thermoelectric_j) > 1.0e4, do: {:halt, s}, else: {:cont, s}
    end)
    te = ledger(s, :circuit_thermoelectric_j)
    assert te > 1.0e4
    assert_in_delta ledger(s, :circuit_peltier_absorbed_j) - ledger(s, :circuit_peltier_released_j), te, 1.0e-6 * te
    assert ledger(s, :circuit_peltier_released_j) > 0.0
    # 旧账键不被重置。
    assert ledger(s, :circuit_removed_j) == removed
    {_, frozen_before, restored} = restart_old(c, :old)
    assert Map.drop(restored.thermal, [:active]) == Map.drop(frozen_before.thermal, [:active])
    IO.puts("TE_OLD clicks=#{clicks} sim_s=#{s.thermal.elapsed_s} te_j=#{te} absorbed_j=#{ledger(s, :circuit_peltier_absorbed_j)} " <>
      "released_j=#{ledger(s, :circuit_peltier_released_j)} H=#{temperature(s, {11, 3, 2})} C=#{temperature(s, {13, 3, 2})}")
  end

  defp restart_old(c, id) do
    before = frozen(c.w)
    :ok = stop_supervised(id)
    w = start_supervised!({World, c.opts}, id: id)
    restored = frozen(w)
    :sys.resume(w)
    {%{c | w: w}, before, restored}
  end

  # ---- master 时代检查点（fixtures/thermoelectric_master，由 R8-09 片 1 之前的 master 7bfd0bba 经正式入口录制、压实成一帧检查点，
  # 录制器 record_7bfd0bba_helper.exs）：整格煤 K 点燃、单热壁热电石发电中，热账里热电做功已累计 te_old（world.json，旧代码写下），
  # 没有佩尔捷键。升级后佩尔捷键从 0 起算、热电做功接着累加：Δ吸热 − Δ放热 = Δ做功，而绝对值差恒为 −te_old（不补造历史值）。
  @master_fixture Path.expand("fixtures/thermoelectric_master", __DIR__)
  test "master 时代检查点（热电做功已累计、无佩尔捷键）：回放后原样保留不补造；续烧发电后 Δ吸热 − Δ放热 = Δ做功、绝对差恒为 −te_old；重启后逐项相同", c do
    meta = Jason.decode!(File.read!(Path.join(@master_fixture, "world.json")))
    assert meta["catalog"] == @catalog and meta["peltier_keys_present"] == false and meta["frames"] == 1
    root = Path.join(c.root, "master")
    File.mkdir_p!(Path.join(root, "prefabs"))
    File.cp!(Path.join(@master_fixture, "overlay.log"), Path.join(root, "overlay.log"))
    File.cp!(Path.join(@fixtures, @catalog <> ".json"), Path.join(root, "properties.json"))
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), Path.join(root, "environment.json"))
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: Path.join(root, "environment.json"),
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [@stone, @coal, @copper, @alloy, @te]]
    w = start_supervised!({World, opts}, id: :master)
    # 首个定时热提交在启动后 500 ms 才到期；回放态必须恰是录制末态（seq、时钟、热电做功逐位相同）。
    replayed = frozen(w)
    :sys.resume(w)
    c = %{c | w: w, opts: opts}
    te_old = meta["circuit_thermoelectric_j"]
    assert te_old > 1.0e4
    assert {replayed.seq, replayed.thermal.elapsed_s, replayed.thermal.circuit_thermoelectric_j} == {meta["seq"], meta["elapsed_s"], te_old}
    refute Map.has_key?(replayed.thermal, :circuit_peltier_absorbed_j)
    refute Map.has_key?(replayed.thermal, :circuit_peltier_released_j)
    assert cell(observe(w), {1, 3, 2}).burning
    base = {0.0, 0.0, te_old}

    s = Enum.reduce_while(1..3000, nil, fn _, _ ->
      s = commit(c.w)
      assert_peltier(s, base)
      # 不补造：吸热 − 放热 − 做功 = −te_old（绝对恒等式在升级世界上不成立，验收只核对增量）。
      assert_in_delta ledger(s, :circuit_peltier_absorbed_j) - ledger(s, :circuit_peltier_released_j) - ledger(s, :circuit_thermoelectric_j),
        -te_old, 1.0e-6 * ledger(s, :circuit_thermoelectric_j)
      if ledger(s, :circuit_thermoelectric_j) - te_old > 1.0e4, do: {:halt, s}, else: {:cont, s}
    end)
    dte = ledger(s, :circuit_thermoelectric_j) - te_old
    assert dte > 1.0e4
    assert ledger(s, :circuit_peltier_released_j) > 0.0
    {c, frozen_before, restored} = restart_old(c, :master)
    assert Map.drop(restored.thermal, [:active]) == Map.drop(frozen_before.thermal, [:active])
    assert_peltier(commit(c.w), base)
    IO.puts("TE_MASTER te_old_j=#{te_old} sim_s=#{s.thermal.elapsed_s} dte_j=#{dte} absorbed_j=#{ledger(s, :circuit_peltier_absorbed_j)} " <>
      "released_j=#{ledger(s, :circuit_peltier_released_j)} H=#{temperature(s, {2, 3, 2})} C=#{temperature(s, {4, 3, 2})}")
  end
end
