defmodule VoxelRegion.MagicStructureTest do
  @moduledoc """
  只测试：结构对象的纯值步进 `Magic.Structure`（符号组合魔法 v2 切片 0c；决策稿测试矩阵第 4 条）。

  - 契约：设计 v2.9（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`）§4.3 运行期公式与拍内分段（R1）、
    §5.3 每拍步进与 §5.3.3 出账细则（A1：干预活动按拍首 E_op 预付，场存续 t_eff 与处理顺序无关）、§5.4 读数丢失
    不消费读数（R5）、§5.5 终止类型（R4）、§5.8 整数 mJ 与确定性、§7.3 每拍计入的驱散剂量。
  - 夹具：结构组由冻结样本 `fixtures/magic/ir-v2-samples.json` 经真实 `Program.decode_ir/2` 解码（灯、火球、驱散脉冲、
    定时火种、过热保险火球）；持续扰乱场的 5 kW〈乱〉由驱散脉冲字节改写两个 dec 槽得到，同样经解码器接纳。
    报价是真实 `Cost.quote_structure/3` 的产出（施放处 293.15 K；报价本身的期望值由 `magic_cost_test.exs` 覆盖）。
  - 判定：期望值取设计附录 A.2–A.4 的数（灯寿命 132 s、x* 0.61 / 0.25、A.4 v2.9 逐拍净欠账与 t_eff），容差按文档
    给出的位数，写在各用例里；账目闭合与逐位一致是不变量。读数丢失的用例按 hash(id, tick) 逐个 id 搜索丢失的实例，
    不复制 hash 算法。干预场一律由发出者的拍首状态取（`disruption_field/4` 的契约）。
  - 线上状态量 `wire/1`（切片 4a，决策稿 `2026-11-26-p1-closure-slices4-8.md` §3.1、§3.3）：量化口径
    load = round(x·255)、coherence = round(clamp(C, 0, 1)·255)；期望取附录 A.3 的灯 x₀ = 0.221（56）、火球 2000 K、
    500 K 处 x* ≈ 0.25，以及“终止拍取终止判定那一刻的值”的契约。`respond/3` 的 outputs（metrics 为空）交给
    `wire/1` 显式失败（运行期断言，经 `apply/3` 调用以免编译期类型检查先行拒绝）。
  - 不覆盖：热内核限流与真实净热（切片 1/5，这里净热是显式输入）、World 提交、多段与 P2 符号；前摇打断剂量
    （施法者处，A.4 末行）的消费方在切片 1（Player，D7），这里只验证它所依赖的 t_eff 合计 0.593 s。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Structure}

  @digest "e337873b1daaafeb55397bd0ef8e01fda4572dd549d34cd6e268ec54ec638264"
  @path Application.app_dir(:voxel_region, "priv/magic/#{@digest}.json")
  @samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)
  @ambient_k 293.15
  # 〈附〉的形成距离取本地施法域内的 3 m；T15 的热环境取设计 A.7 的示意值。
  @site %{
    ambient_k: @ambient_k,
    formation_distance_m: 3.0,
    emissivity: 0.9,
    exchange_w_per_m2_k: 10.0
  }

  setup_all do
    catalog = Catalog.load(@path)

    bytes =
      Map.new(
        Jason.decode!(File.read!(@samples))["samples"],
        &{&1["id"], Base.decode16!(&1["program_hex"], case: :lower)}
      )

    # 持续扰乱场：驱散脉冲的〈乱〉activity_w 改为 5 kW（dec e=1 m=500 → 0x11F4，偏移 22），〈蓄〉改为 300 kJ
    # （dec e=2 m=3000 → 0x2BB8，偏移 29）。偏移按 §11.4.4 逐字节注释手数。
    field = bytes["dispel_pulse"] |> patch(22, <<0x11, 0xF4>>) |> patch(29, <<0x2B, 0xB8>>)

    programs =
      Map.new(
        bytes |> Map.drop(["draw_1mj", "draw_2mj"]) |> Map.put("sustained_field", field),
        fn {id, b} -> {id, program!(b, catalog)} end
      )

    %{
      catalog: catalog,
      programs: programs,
      groups: Map.new(programs, fn {id, %Program{groups: [group]}} -> {id, group} end),
      quotes:
        Map.new(programs, fn {id, program} ->
          {id, Cost.quote_structure(program, catalog, @site)}
        end)
    }
  end

  defp patch(bytes, at, part),
    do:
      binary_part(bytes, 0, at) <>
        part <> binary_part(bytes, at + byte_size(part), byte_size(bytes) - at - byte_size(part))

  defp program!(bytes, catalog) do
    {:ok, %Program{kind: :structure, groups: [_]} = program} = Program.decode_ir(bytes, catalog)
    program
  end

  # 由样本的结构组与真实报价出生（出生拍号默认 0）。
  defp born(c, name, id, born_tick \\ 0),
    do: Structure.new(id, c.groups[name], c.quotes[name], born_tick)

  defp lamp(c, id \\ 1), do: born(c, "lamp", {id, 0})
  defp fireball(c), do: born(c, "fireball", {2, 0})
  defp pulse(c, name \\ "dispel_pulse"), do: born(c, name, {3, 0})
  defp ember(c, id \\ {4, 0}), do: born(c, "timed_ember", id)

  defp inputs(overrides \\ []) do
    Map.merge(
      %{
        net_heat_j: 0,
        feed_w: 0,
        temperature_k: @ambient_k,
        cell_heat_capacity_j_per_k: 1200.0,
        embedded: false,
        neighbors: [],
        fields: [],
        release_doses: [],
        contact: false
      },
      Map.new(overrides)
    )
  end

  # 逐拍推进直到终止或到达 max_tick；`fun.(tick)` 给出该拍读数。返回 {终止拍或 nil, 最终结构, 每拍 outputs}。
  defp run(s, max_tick, c, fun) do
    Enum.reduce_while(1..max_tick, {nil, s, []}, fn tick, {nil, s, outs} ->
      {s, out} = Structure.step(s, fun.(tick), tick, c.catalog)
      acc = {if(s.status == :running, do: nil, else: tick), s, [out | outs]}
      if s.status == :running, do: {:cont, acc}, else: {:halt, acc}
    end)
    |> then(fn {t, s, outs} -> {t, s, Enum.reverse(outs)} end)
  end

  defp seconds(tick), do: tick * Structure.tick_ms() / 1000

  # 账目闭合：Σ 流入 = Σ 流出 + Δ储能，逐项为整数。
  defp assert_closed(%{ledger: l}) do
    values = Map.values(l.in) ++ Map.values(l.out) ++ [l.stored_before_mj, l.stored_after_mj]
    assert Enum.all?(values, &is_integer/1), inspect(l)

    assert Enum.sum(Map.values(l.in)) ==
             Enum.sum(Map.values(l.out)) + l.stored_after_mj - l.stored_before_mj,
           inspect(l)
  end

  # ---- 寿命与稳态线 ----

  test "灯：env = 1、无供能时逐拍出账至 E_op < E_min，断供衰竭，寿命约 132 s（A.3）", c do
    {tick, s, outs} = run(lamp(c), 400, c, fn _ -> inputs() end)

    assert s.status == {:terminated, :exhausted}
    assert_in_delta seconds(tick), 132.0, 1.32
    assert [{:terminated, :exhausted, %{released_mj: released}}] = List.last(outs).events
    assert released < 500_000
    Enum.each(outs, &assert_closed/1)
  end

  test "稳态线 x*：env = 1 为 0.61，env = 2 为 0.25（§4.3、§4.6）；步进按所在格温度推出 env", c do
    lamp = lamp(c)
    assert_in_delta Structure.steady_load(lamp, 1, 0, c.catalog), 0.612, 0.001
    assert_in_delta Structure.steady_load(lamp, 2, 0, c.catalog), 0.25, 0.001
    assert_in_delta Structure.steady_load(fireball(c), 1, 0, c.catalog), 0.612, 0.001

    # 500 K：env = 1 + a_T·(500 − 300)/100 = 2。
    {_, out} = Structure.step(lamp, inputs(temperature_k: 500), 1, c.catalog)
    assert_in_delta out.metrics.env, 2.0, 1.0e-9
    assert_in_delta out.metrics.steady_load, 0.25, 0.001
  end

  # ---- A.4 驱散剂量（〈乱 100 kW，3 m〉〈蓄 60 kJ〉，名义 τ = 0.595 s；v2.9 逐拍口径） ----

  test "A1：脉冲按拍首 E_op 预付活动，t_eff 第 1 拍 0.5 s、第 2 拍 0.0933 s，合计 0.593 s（名义 0.595 s）", c do
    p = pulse(c)
    assert Structure.disruption_field(p, 0, 1, c.catalog).seconds == 0.5

    # 第 1 拍：预付 100 kW × 0.5 s = 50 kJ；发出者自己扣的就是目标收到的那个 t_eff。
    {p, out} = Structure.step(p, inputs(), 1, c.catalog)
    assert out.metrics.field_s == 0.5 and out.ledger.out.activity_mj == 50_000_000
    assert_closed(out)

    # 第 2 拍：第 1 拍的泄漏约 0.17 kJ 使可预付的能量从 9.5 kJ 降为约 9.33 kJ（§5.3.3），短于名义 0.095 s。
    second = Structure.disruption_field(p, 0, 2, c.catalog).seconds
    assert_in_delta second, 0.0933, 0.00005
    assert_in_delta 0.5 + second, 0.593, 0.0005

    {p, out} = Structure.step(p, inputs(), 2, c.catalog)
    assert out.metrics.field_s == second
    assert out.ledger.out.activity_mj == round(second * 100_000 * 1000)
    assert_closed(out)
    # 预付到 E_min 为止，其后的泄漏使 E_op < E_min：第 2 拍断供衰竭。
    assert p.status == {:terminated, :exhausted}

    # 契约：场只能由拍首状态取；已步进的发出者没有匹配子句，World 无法按处理顺序取到不同的场。
    assert_raise FunctionClauseError, fn -> Structure.disruption_field(p, 0, 2, c.catalog) end
  end

  test "A1：同一拍内结构的处理顺序不同，结果逐位相同（两个脉冲互相作用，另有一盏灯）", c do
    # 两个脉冲相距 1 m、灯在二者之间各 0.5 m；每拍先由拍首状态取齐全部场，再按给定顺序步进。
    start = %{
      a: born(c, "dispel_pulse", {3, 0}),
      b: born(c, "dispel_pulse", {5, 0}),
      lamp: lamp(c)
    }

    distance = %{{:a, :b} => 1.0, {:b, :a} => 1.0, {:a, :lamp} => 0.5, {:b, :lamp} => 0.5}

    run = fn order ->
      Enum.reduce(1..3, start, fn tick, world ->
        fields =
          Map.new(Map.keys(world), fn target ->
            emitted =
              for {emitter, s} <- world, emitter != target, s.status == :running do
                Structure.disruption_field(s, distance[{emitter, target}], tick, c.catalog)
              end
              |> Enum.reject(&is_nil/1)

            {target, emitted}
          end)

        Enum.reduce(order, world, fn name, acc ->
          s = acc[name]

          if s.status == :running,
            do:
              Map.put(
                acc,
                name,
                elem(Structure.step(s, inputs(fields: fields[name]), tick, c.catalog), 0)
              ),
            else: acc
        end)
      end)
    end

    forward = run.([:a, :b, :lamp])
    assert run.([:lamp, :b, :a]) == forward
    assert forward.lamp.debt_micro > 0
  end

  # 同拍内脉冲与目标一起步进：World 先按拍首状态取场，再步进（脉冲不吃自己的场）；目标可带供能 `feed_w`。
  defp under_pulse(c, target, distance_m, ticks, feed_w \\ 0) do
    Enum.reduce(1..ticks, {pulse(c), target, []}, fn tick, {p, t, outs} ->
      fields =
        if p.status == :running,
          do: List.wrap(Structure.disruption_field(p, distance_m, tick, c.catalog)),
          else: []

      p =
        if p.status == :running,
          do: elem(Structure.step(p, inputs(), tick, c.catalog), 0),
          else: p

      {t, out} =
        if t.status == :running,
          do: Structure.step(t, inputs(fields: fields, feed_w: feed_w), tick, c.catalog),
          else: {t, nil}

      {p, t, if(out, do: [out | outs], else: outs)}
    end)
  end

  defp debt(s), do: s.debt_micro / 1.0e6

  test "A.4（v2.9 逐拍）：灯正中 1.182 第 1 拍驱散、1 m 处 0.601 存活；火球 1 m 0.76 驱散；供能 300 W / 3 kW 的灯正中 1.152 / 0.877",
       c do
    {p, lamp_center, outs} = under_pulse(c, lamp(c), 0, 4)
    assert {lamp_center.status, lamp_center.last_tick} == {{:terminated, :dispelled}, 1}
    assert_in_delta debt(lamp_center), 1.182, 0.0005
    Enum.each(outs, &assert_closed/1)
    assert {p.status, p.last_tick} == {{:terminated, :exhausted}, 2}

    # 脉冲在第 2 拍 0.0933 s 结束，之后的线内段偿还；脉冲结束时的净欠账。
    {_, lamp_1m, _} = under_pulse(c, lamp(c), 1, 2)
    assert lamp_1m.status == :running
    assert_in_delta debt(lamp_1m), 0.601, 0.0005

    {_, fireball_1m, outs} = under_pulse(c, fireball(c), 1, 4)
    assert {fireball_1m.status, fireball_1m.last_tick} == {{:terminated, :dispelled}, 1}
    assert_in_delta debt(fireball_1m), 0.76, 0.005
    Enum.each(outs, &assert_closed/1)

    # 短脉冲供能挡不住：两者都在第 1 拍终止。
    for {feed_w, expected} <- [{300, 1.152}, {3000, 0.877}] do
      {_, fed, _} = under_pulse(c, lamp(c), 0, 2, feed_w)
      assert {fed.status, fed.last_tick} == {{:terminated, :dispelled}, 1}
      assert_in_delta debt(fed), expected, 0.0005
    end
  end

  # ---- 持续扰乱场与供能（A.4 末段） ----

  test "5 kW 持续扰乱场、目标 1 m：未供能的灯欠账 +0.027 /s 直至被驱散，300 W 供能的灯欠账始终为 0", c do
    field_pulse = pulse(c, "sustained_field")
    assert field_pulse.activity.power_w == 5000

    {_, unfed, fed, field_ticks} =
      Enum.reduce(1..120, {field_pulse, lamp(c, 10), lamp(c, 11), 0}, fn tick,
                                                                         {p, unfed, fed, n} ->
        fields =
          if p.status == :running,
            do: List.wrap(Structure.disruption_field(p, 1, tick, c.catalog)),
            else: []

        p =
          if p.status == :running,
            do: elem(Structure.step(p, inputs(), tick, c.catalog), 0),
            else: p

        unfed =
          if unfed.status == :running do
            {unfed, out} = Structure.step(unfed, inputs(fields: fields), tick, c.catalog)
            # A.4：env = 3.22，D = 0.077，欠账增速 0.027 /s（首拍按出生装载）。
            if tick == 1, do: assert_in_delta(out.metrics.debt, 0.027 * 0.5, 3.0e-4)
            unfed
          else
            unfed
          end

        {fed, out} = Structure.step(fed, inputs(fields: fields, feed_w: 300), tick, c.catalog)
        assert_closed(out)
        if fields != [], do: assert(fed.debt_micro == 0)
        {p, unfed, fed, n + length(fields)}
      end)

    # 场持续约 54 s（300 kJ 减去自身维持），远长于未供能灯的终止时刻。
    assert seconds(field_ticks) > 40
    assert unfed.status == {:terminated, :dispelled}

    # A.4 的“约 26 s”= 0.7 / 0.027，按出生装载外推；逐拍装载下降使增速变慢，实算更晚但仍在场存续内。
    assert seconds(unfed.last_tick) >= 26 and unfed.last_tick < field_ticks
    assert fed.status == :running
  end

  # ---- 其余终止类型 ----

  test "过载崩解：700 K 格中 env = 3、x* = 0，灯越线累积欠账至 debt > 0.7（无干预）", c do
    {tick, s, outs} = run(lamp(c), 400, c, fn _ -> inputs(temperature_k: 700) end)
    assert s.status == {:terminated, :collapsed}

    # 首拍越线速度 D0·env·(1 + κx₀²) − r0 = 0.02 × 3 × 1.19545 − 0.05 = 0.02173 /s（手算）。
    assert_in_delta hd(outs).metrics.debt, 0.02173 * 0.5, 2.0e-5

    # 装载随出账下降、越线变慢，所以晚于按出生装载外推的 0.7 / 0.02173 ≈ 32 s，早于 env = 1 时的 132 s 衰竭。
    assert seconds(tick) > 32.2 and seconds(tick) < 132
    assert hd(outs).metrics.steady_load == 0.0
    Enum.each(outs, &assert_closed/1)
  end

  test "主动终止：火球〈遇〉触发〈散〉；热份额按端口温度释放，动能经动能出口沉积", c do
    fb = fireball(c)
    {fb, out} = Structure.step(fb, inputs(net_heat_j: -1234.5678, contact: true), 1, c.catalog)
    assert_closed(out)
    assert_in_delta out.ledger.heat_rounding_mj, 0.2, 1.0e-6
    assert [%{outcome: :met, responses: [release]}] = out.triggered

    {fb, out} = Structure.respond(fb, release, c.catalog)
    assert_closed(out)
    assert fb.status == {:terminated, :released}
    assert [{:terminated, :released, _}] = out.events

    # 出生热份额 426 700 000 mJ（T_ref 量化为 293.2 K，§11.4.7），减去本拍净热 1 234 568 mJ。
    assert {:release_thermal, 425_465_432, port_k} =
             List.keyfind(out.requests, :release_thermal, 0)

    assert_in_delta port_k, 293.2 + 425_465.432 / 250, 1.0e-6
    assert {:deposit_heat, 36_000, :kinetic} in out.requests
  end

  test "定时火种：〈时 30 s〉在第 60 拍到期才触发，此前不求值", c do
    {_, s, outs} = run(ember(c), 59, c, fn _ -> inputs() end)
    assert Enum.all?(outs, &(&1.triggered == []))
    {_, out} = Structure.step(s, inputs(), 60, c.catalog)
    assert [%{outcome: :met, responses: [%{id: "resp.release"}]}] = out.triggered
  end

  test "邻近终止释放剂量：10 kJ、1.5 m → Δdebt = D0·(1 + κx²)·a_X·k_rel·10·0.25，不计入 debt_int", c do
    lamp = lamp(c)
    x = 50_000 / 226_194.671

    {lamp, out} =
      Structure.step(
        lamp,
        inputs(release_doses: [%{energy_mj: 10_000_000, distance_m: 1.5}]),
        1,
        c.catalog
      )

    assert_in_delta out.metrics.debt, 0.02 * (1 + 4 * x * x) * 1.0 * 0.3 * 10 * 0.25, 2.0e-6
    assert lamp.debt_int_micro == 0
  end

  # ---- 账目与确定性 ----

  test "整数账闭合：供能被 Φ_cap 与容量截流、泄漏批量沉积、带小数净热的每一拍", c do
    {_, s, outs} = run(lamp(c), 40, c, fn _ -> inputs(feed_w: 100_000) end)
    assert s.status == :running
    assert Enum.any?(outs, &(&1.ledger.out.feed_rejected_mj > 0))
    assert Enum.any?(outs, &(&1.ledger.out.leak_heat_mj > 0))
    assert s.e_op_mj + abs(s.e_th_mj) <= s.e_cap_mj
    Enum.each(outs, &assert_closed/1)

    {_, _, outs} = run(fireball(c), 30, c, fn tick -> inputs(net_heat_j: -2_000.3 * tick) end)
    Enum.each(outs, &assert_closed/1)
  end

  # 火种在脉冲 1.5 m 处：越线后欠账 > 0，到期拍的读数可能按 hash(id, tick) 丢失。
  defp ember_scenario(c, id \\ {4, 0}, ticks \\ 61) do
    Enum.reduce(1..ticks, {pulse(c), ember(c, id), []}, fn tick, {p, e, outs} ->
      fields =
        if p.status == :running,
          do: List.wrap(Structure.disruption_field(p, 1.5, tick, c.catalog)),
          else: []

      p =
        if p.status == :running,
          do: elem(Structure.step(p, inputs(), tick, c.catalog), 0),
          else: p

      {e, out} =
        if e.status == :running,
          do: Structure.step(e, inputs(fields: fields), tick, c.catalog),
          else: {e, nil}

      {p, e, [out | outs]}
    end)
  end

  test "确定性：相同输入重复运行，结构与全部输出逐位一致（到期拍 debt > 0，读数丢失判定按 hash(id, tick) 参与）", c do
    {_, _ember, outs} = first = ember_scenario(c)
    assert ember_scenario(c) == first
    due = Enum.at(Enum.reverse(outs), 59)
    assert due.metrics.debt > 0
  end

  # ---- 读数丢失不消费读数（§5.4 v2.7 R5） ----

  # 从 `s` 起逐拍推进（读数由 `fun.(tick)` 给出），直到某拍有触发；返回 {触发拍, 该拍结构, 该拍 outputs}。
  defp until_triggered(s, ticks, c, fun) do
    Enum.reduce_while(ticks, s, fn tick, s ->
      assert s.status == :running
      {s, out} = Structure.step(s, fun.(tick), tick, c.catalog)
      if out.triggered == [], do: {:cont, s}, else: {:halt, {tick, s, out}}
    end)
  end

  test "R5：〈时〉到期拍读数丢失时到期保持待决，之后第一个未丢失的拍触发", c do
    # 到期拍（第 60 拍）欠账 > 0，读数按 hash(id, tick) 以 p = min(0.5, debt / 0.5) 丢失；逐个 id 找到期拍丢失的实例。
    lost =
      Enum.find_value(1..64, fn seq ->
        {_, ember, _} = ember_scenario(c, {seq, 0}, 59)
        {ember, out} = Structure.step(ember, inputs(), 60, c.catalog)
        if out.triggered == [] and out.metrics.debt > 0, do: ember
      end)

    assert %Structure{} = lost
    assert {tick, _, out} = until_triggered(lost, 61..80, c, fn _ -> inputs() end)
    assert tick > 60
    assert [%{outcome: :met, responses: [%{id: "resp.release"}]}] = out.triggered
  end

  test "R5：〈满〉的阈值跨越落在丢失拍时不更新上次量化值，之后第一个未丢失的拍触发", c do
    # 过热保险火球先独立运行 2 拍（相干 1，规则 1 首次求值为“未满足”并记下量化值）；脉冲在第 2 拍出生、第 3 拍起
    # 在 1.3 m 处作用：第 3 拍欠账约 0.55（相干跌破 0.5，跨越阈值），两拍合计约 0.65，不到终止线 0.7。
    lost =
      Enum.find_value(1..64, fn seq ->
        guarded = born(c, "guarded_fireball", {seq, 0})
        {guarded, _} = Structure.step(guarded, inputs(), 1, c.catalog)
        {guarded, _} = Structure.step(guarded, inputs(), 2, c.catalog)
        pulse = born(c, "dispel_pulse", {1_000, 0}, 2)
        field = Structure.disruption_field(pulse, 1.3, 3, c.catalog)
        {guarded, out} = Structure.step(guarded, inputs(fields: [field]), 3, c.catalog)
        if out.triggered == [] and out.metrics.coherence < 0.5, do: {guarded, pulse}
      end)

    assert {guarded, pulse} = lost
    {pulse, _} = Structure.step(pulse, inputs(), 3, c.catalog)

    fields = fn tick ->
      if pulse.status == :running and tick == 4,
        do: inputs(fields: [Structure.disruption_field(pulse, 1.3, 4, c.catalog)]),
        else: inputs()
    end

    assert {_tick, guarded, out} = until_triggered(guarded, 4..30, c, fields)
    assert guarded.status == :running
    assert [%{priority: 1, outcome: :met, responses: [%{id: "resp.release"}]}] = out.triggered
  end

  # ---- 线上状态量（切片 4a，决策稿 2026-11-26-p1-closure-slices4-8.md §3.1、§3.3） ----

  test "wire：灯出生记录 load = round(0.221 × 255) = 56、相干 255、温度 0（无〈热〉）、发光取标称 100 W、无状态位", c do
    lamp = lamp(c)

    assert Structure.wire({lamp, c.quotes["lamp"]}) == %{
             load: 56,
             coherence: 255,
             status: [],
             failed_segments: 0,
             temperature_k: 0.0,
             glow_w: 100.0
           }
  end

  test "wire：出生越线按报价 x₀ > x*——500 K 处施放的火球（x* ≈ 0.25，附录 A.3）置越线位，293 K 处不置", c do
    group = c.groups["fireball"]
    hot_quote = Cost.quote_structure(c.programs["fireball"], c.catalog, %{@site | ambient_k: 500.0})
    assert_in_delta hot_quote.x_star, 0.25, 0.01
    hot = Structure.new({2, 0}, group, hot_quote, 0)

    assert %{status: [:overline]} = Structure.wire({hot, hot_quote})
    assert %{status: [], temperature_k: t} = Structure.wire({fireball(c), c.quotes["fireball"]})
    # 〈热〉2000 K：T_port = T_ref + E_th0 / C_th（T_ref 按 0.1 K 量化）。
    assert_in_delta t, 2000.0, 1.0e-9
  end

  test "wire：步进后发光 = 本拍 light_mj ÷ 拍长，有供能时置供能中位，相干与装载取本拍 metrics", c do
    {s, out} = Structure.step(lamp(c), inputs(feed_w: 300), 1, c.catalog)
    wire = Structure.wire({s, out})

    assert wire.glow_w == out.ledger.out.light_mj / 500
    assert wire.glow_w == 100.0
    assert wire.status == [:feeding]
    assert wire.load == round(out.metrics.load * 255)
    assert wire.coherence == 255
  end

  test "wire：终止拍取终止判定那一刻的装载与端口温度，而不是清空后的 0 与 T_ref（2000 K 格中火球过载崩解）", c do
    {tick, s, outs} = run(fireball(c), 20, c, fn _ -> inputs(temperature_k: 2000.0) end)
    out = List.last(outs)
    assert s.status == {:terminated, :collapsed} and tick < 20
    assert s.e_op_mj == 0 and s.e_th_mj == 0
    assert_in_delta Structure.port_temperature(s), s.t_ref_k, 1.0e-9

    wire = Structure.wire({s, out})
    assert wire.load == round(out.metrics.load * 255) and wire.load > 0
    # 无净热输入，E_th 不变：终止前一刻的端口温度仍是出生时的 2000 K。
    assert_in_delta wire.temperature_k, 2000.0, 1.0e-9
    assert wire.coherence < round(0.3 * 255)
    assert :overline in wire.status
  end

  test "wire：respond/3 的 outputs 的 metrics 为空、没有本拍装载与相干，不匹配任何子句（记录取同拍 step/4 的结果）", c do
    {s, out} = Structure.step(fireball(c), inputs(contact: true), 1, c.catalog)
    [%{responses: [release]}] = out.triggered
    responded = Structure.respond(s, release, c.catalog)
    assert elem(responded, 1).metrics == %{}
    # 经 apply/3 调用：编译期类型检查已能静态看出这次调用不匹配（会产生编译警告），这里要证明的是运行期同样显式失败。
    assert_raise FunctionClauseError, fn -> apply(Structure, :wire, [responded]) end
  end
end
