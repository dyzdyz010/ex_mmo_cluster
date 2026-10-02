defmodule VoxelRegion.ThermalActivityWorldTest do
  @moduledoc """
  只测试：R8-05 热活跃调度（Voxim Docs/R8/Design-decisions.md §8 决策 1 热遗留、Docs/R8/plan.md §R8-05）。

  装置与 `energy_material_test` 的发电—蓄能—灯相同（Voxim `energy_loop` 的服务端对应物）：实验热源加热热电石，
  闭合 S1 充电，断开 S1。随后用 Test-only 实验入口换一份强对流环境（h = 2000 W/m²K，只为把降温压到几千个模拟秒；
  热源余能 1 J）让装置冷却到容差内：此后世界里只剩“有储能的蓄能石、带温度记录的热电石、两个断开的开关”。

  - 空闲：真实定时器窗口内不再推进热提交、不写事务（旧实现每 500 ms 仍解一次电路并写一笔空热事务）；
    物理真值（属性行、账目，除模拟时钟与序号）在窗口前后逐项相等。
  - 唤醒：正式工具闭合 S2 这一事件在下一个节拍重新推进，第一笔热事务的电流 = 24 V / ΣR（目录算术），之后持续推进。
  - 再休眠：断开 S2 后灯熄、降温结束后至多一笔不改写真值的确认提交（零功率网络按降温后的温度再解一次）即停；
    冷却（被动导热）进行中即使电功率为 0 也持续推进。
  - 热行增量维护（`ThermalWork.rehot/4`）、燃烧行与电路候选（`ThermalWork.touched/3`）在各阶段之间与全量扫描当前记录相同。
  期望来自目录算术与账目恒等式；成本数字随输出打印（`THERMAL_ACTIVITY …`），用于与改动前比较。
  """
  use ExUnit.Case, async: false
  @moduletag :thermal_activity
  alias VoxelRegion.{Circuit, ThermalWork, World}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @digest "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @stone 11
  @copper 24
  @alloy 40
  @switch 41
  @battery 42
  @te 43
  @materials [9, @stone, 15, 23, @copper, @alloy, @switch, @battery, @te]
  @box {{-2, -2, -2}, {2, 2, 2}}
  @ambient 293.15

  setup do
    root = Path.join(System.tmp_dir!(), "thermal_activity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    %{root: root, materials: Map.new(data["materials"], &{&1["material_id"], &1})}
  end

  defp start(c) do
    catalog = Path.join(c.root, "properties.json")
    File.cp!(Path.join(@fixtures, @digest <> ".json"), catalog)
    env = Path.join(c.root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    start_supervised!({World, [source: Source, log: Log, root: c.root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, production_materials: @materials]})
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp temperature(s, coord), do: Map.get(cell(s, coord) || %{}, :temperature_kelvin, @ambient)

  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  # 正式工具路径：先按眼睛到目标微格的射线查询命中身份，再以同一身份执行（G 切换开关）。
  defp toggle(w, {x, y, z}) do
    a = actor({x + 0.5, y + 1.5, z + 0.5})
    micro = {x * 8 + 4, y * 8 + 4, z * 8 + 4}
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 7,
      direction: {0.0, -1.0, 0.0}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    target = elem(World.tool_intent(w, a, q), 1)
    r = Map.merge(q, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    {:ok, _} = World.tool_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), %{r | action: 1})
  end

  # 发电—蓄能—灯（z = 2 平面，地面 y = 0 石；同 energy_material_test）：
  #   y = 3：热铜 H (1,3)（实验热源）— 热电石 T (2,3) — 冷铜 C (3,3) — 开关 S2 (4,3)
  #   y = 2：铜 (1,2)；蓄能石 B (3,2)（正极朝上接 C）；电阻合金灯 L (4,2)
  #   y = 1：铜 (1,1) — 开关 S1 (2,1) — 铜 (3,1)（B 的负极）— 铜 (4,1)
  defp generator(c, w) do
    ground = for x <- -1..6, z <- 0..4, do: {{x, 0, z}, @stone}
    cells = [{{1, 3, 2}, @copper}, {{2, 3, 2}, @te}, {{3, 3, 2}, @copper}, {{4, 3, 2}, @switch},
      {{1, 2, 2}, @copper}, {{3, 2, 2}, @battery}, {{4, 2, 2}, @alloy},
      {{1, 1, 2}, @copper}, {{2, 1, 2}, @switch}, {{3, 1, 2}, @copper}, {{4, 1, 2}, @copper}]
    {:ok, _} = World.apply_edits(w, ground ++ cells)
    experiment(c, w, "heat", 10.0, 2.0e6, 1.0e9)
  end

  defp experiment(c, w, name, h, power, energy) do
    path = Path.join(c.root, "#{name}.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [1, 3, 2], ambient_kelvin: @ambient,
      environment_w_per_m2_k: h, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8, power_w: power, energy_j: energy}))
    :ok = World.thermal_experiment(w, path)
  end

  defp open_emf(s) do
    ti = fn cu -> (8000 * cu + 30 * temperature(s, {2, 3, 2})) / 8030 end
    0.05 * (ti.(temperature(s, {1, 3, 2})) - ti.(temperature(s, {3, 3, 2})))
  end

  # 物理真值指纹：属性行（去掉事务号与请求号）与热账（去掉模拟时钟）。
  defp physics(s) do
    rows = s.damage |> Map.values() |> Enum.map(&Map.drop(&1, [:seq, :request_id])) |> Enum.sort()
    {rows, Map.drop(s.thermal, [:elapsed_s])}
  end

  # 在固定观察窗口内数定时器节拍（进程接收事件）与世界序号、归约数的变化。
  defp window(w, ms) do
    flush_trace()
    s0 = observe(w)
    {:reductions, r0} = Process.info(w, :reductions)
    :erlang.trace(w, true, [:receive])
    Process.sleep(ms)
    :erlang.trace(w, false, [:receive])
    {:reductions, r1} = Process.info(w, :reductions)
    s1 = observe(w)
    ticks = flush_trace()
    %{ticks: ticks, seq: s1.seq - s0.seq, reductions: r1 - r0, before: s0, after: s1}
  end

  defp flush_trace(n \\ 0) do
    receive do
      {:trace, _, :receive, :thermal_tick} -> flush_trace(n + 1)
      {:trace, _, :receive, _} -> flush_trace(n)
    after 0 -> n
    end
  end

  # 热行增量维护的不变量（R8-05）：两次提交之间，上次热行与此后改写过的行按当前记录重判，等于全量扫描。
  defp hot_invariant(w) do
    s = :sys.get_state(w)

    if s.thermal_run do
      hot_invariant(w)
    else
      work = s.thermal_work
      assert ThermalWork.rehot(work.hot_rows, work.touched, s.damage, s.thermal.config) ==
               ThermalWork.hot_rows(s.damage, s.thermal.config)
      # 燃烧行（已派生时）与电路候选同理：按当前记录过滤后等于全量扫描，种子与带电观察字段的行都在候选里。
      if work.burning,
        do: assert(ThermalWork.live_burning(work.burning, s.damage) ==
          for({k, r} <- s.damage, Map.get(r, :burning, false), into: %{}, do: {k, ThermalWork.cells(r)}))
      assert MapSet.new(Circuit.seeds(s.damage, s.properties, work.electric)) == MapSet.new(Circuit.seeds(s.damage, s.properties))
      for {k, r} <- s.damage, Map.has_key?(r, :electric_w) or Map.has_key?(r, :source_emf_v),
        do: assert(MapSet.member?(work.electric, k))
    end
  end

  # 直接投递提交的往返时间（µs，含一次只读快照同步）。
  defp commit_cost(w, n) do
    {us, _} = :timer.tc(fn -> for _ <- 1..n, do: commit(w) end)
    div(us, n)
  end

  defp battery_rows(rows), do: Enum.find(rows, &(&1.material == @battery and &1.granularity == 0))

  # 等到下一笔带蓄能石行的热事务（真实定时器推进，不直接投递提交）。
  defp await_battery(pred) do
    receive do
      {:canonical_delta, %{transaction: %{property_states: rows}}} ->
        case battery_rows(rows) do
          nil -> await_battery(pred)
          row -> if pred.(row), do: row, else: await_battery(pred)
        end
    after 3_000 -> flunk("no battery row within 3 s")
    end
  end

  test "空闲装置真正休眠、事件唤醒后按目录算术推进、断电降温后再休眠；冷却中电功率为 0 仍推进", c do
    w = start(c)
    generator(c, w)
    Enum.reduce_while(1..2000, observe(w), fn _, s0 -> if open_emf(s0) > 34.0, do: {:halt, s0}, else: {:cont, commit(w)} end)
    hot_invariant(w)
    toggle(w, {2, 1, 2})
    Enum.each(1..40, fn _ -> commit(w) end)
    toggle(w, {2, 1, 2})
    hot_invariant(w)
    charged = observe(w)
    stored = cell(charged, {3, 2, 2}).stored_j
    assert stored > 0

    # 换强对流环境冷却；冷却进行中（热格仍在，电路断开 = 电功率 0）真实定时器照常推进。
    experiment(c, w, "cool", 2000.0, 1.0, 1.0)
    assert observe(w).thermal.active
    cooling = window(w, 1_200)
    assert cooling.ticks >= 2 and cooling.seq >= 2
    {commits, idle} = Enum.reduce_while(1..20_000, {0, observe(w)}, fn n, {_, s} ->
      if s.thermal.active, do: {:cont, {n, commit(w)}}, else: {:halt, {n, s}}
    end)
    refute idle.thermal.active
    hot_invariant(w)
    assert cell(idle, {3, 2, 2}).stored_j == stored
    IO.puts("THERMAL_ACTIVITY cooled commits=#{commits} lid=#{temperature(idle, {1, 3, 2})} te=#{temperature(idle, {2, 3, 2})}")
    # 空闲（有储能、有热电石记录、开关全断、全部在容差内）：直接投递的提交成本与真实定时器窗口。
    idle_us = commit_cost(w, 20)
    quiet = window(w, 3_000)
    IO.puts("THERMAL_ACTIVITY idle commit_us=#{idle_us} window_ms=3000 ticks=#{quiet.ticks} txns=#{quiet.seq} reductions=#{quiet.reductions} physics=#{:erlang.phash2(physics(quiet.after))}")
    assert physics(quiet.before) == physics(quiet.after)

    # 事件唤醒：闭合 S2（正式工具，一笔事务）。不直接投递提交，等真实定时器推进的第一笔热事务。
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(w, {{0, 0, 0}, {1, 1, 1}}, self(), ref, false)
    assert_receive {:canonical_snapshot, ^ref, _}
    toggle(w, {4, 3, 2})
    lit = await_battery(&(&1.source_current_a > 0))
    sigma = fn m -> c.materials[m]["electrical_conductivity"] end
    r = 2 * 0.5 / sigma.(@battery) + 2 * 0.5 / sigma.(@alloy) + 8 * 0.5 / sigma.(@copper)
    i = 24.0 / r
    assert_in_delta lit.source_current_a, i, i * 1.0e-8
    IO.puts("THERMAL_ACTIVITY wake current=#{lit.source_current_a} hand=#{i} stored_j=#{lit.stored_j}")
    powered = window(w, 1_000)
    lit_us = commit_cost(w, 5)
    IO.puts("THERMAL_ACTIVITY lit commit_us=#{lit_us} window_ms=1000 ticks=#{powered.ticks} txns=#{powered.seq} reductions=#{powered.reductions}")
    assert powered.ticks >= 2 and powered.seq >= 2
    hot_invariant(w)
    s = observe(w)
    left = cell(s, {3, 2, 2}).stored_j
    assert left > 0
    assert_in_delta Map.get(s.thermal, :circuit_supplied_j, 0.0), stored - left, 1.0e-6 * stored

    # 断开 S2：灯熄（电流 0），灯的焦耳热降温结束后停止推进。
    toggle(w, {4, 3, 2})
    await_battery(&(&1.source_current_a == 0.0))
    Enum.reduce_while(1..20_000, observe(w), fn _, s -> if s.thermal.active, do: {:cont, commit(w)}, else: {:halt, s} end)
    dark = observe(w)
    refute Map.has_key?(cell(dark, {4, 2, 2}), :electric_w)
    # 最后一笔降温提交改写了记录：零功率网络按新温度由真实定时器再解一次，这笔确认提交不改写任何真值，之后停止。
    confirm = window(w, 1_000)
    IO.puts("THERMAL_ACTIVITY confirm window_ms=1000 ticks=#{confirm.ticks} txns=#{confirm.seq}")
    assert confirm.seq <= 1
    assert physics(confirm.before) == physics(confirm.after)
    rest = window(w, 2_000)
    IO.puts("THERMAL_ACTIVITY rest window_ms=2000 ticks=#{rest.ticks} txns=#{rest.seq} reductions=#{rest.reductions}")
    assert physics(rest.before) == physics(rest.after)
    hot_invariant(w)

    # 休眠判据：空闲窗口与再休眠窗口里没有热事务，至多一个收尾节拍（上一笔提交之后排定的那一拍）。
    assert {quiet.seq, rest.seq} == {0, 0}
    assert quiet.ticks <= 1 and rest.ticks <= 1
  end
end
