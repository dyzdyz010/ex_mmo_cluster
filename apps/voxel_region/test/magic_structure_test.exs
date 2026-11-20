defmodule VoxelRegion.MagicStructureTest do
  @moduledoc """
  只测试：结构对象的纯值步进 `Magic.Structure`（符号组合魔法 v2 切片 0c；决策稿测试矩阵第 4 条）。

  - 契约：设计 v2.7（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`）§4.3 运行期公式与拍内分段（R1）、
    §5.3 每拍步进与 §5.3.3 出账细则（R7②：活动未付足时场按 t_eff 缩短）、§5.4 读数丢失不消费读数（R5）、
    §5.5 终止类型（R4）、§5.8 整数 mJ 与确定性、§7.3 每拍计入的驱散剂量。
  - 夹具：结构组由冻结样本 `fixtures/magic/ir-v2-samples.json` 经真实 `Program.decode_ir/2` 解码（灯、火球、驱散脉冲、
    定时火种、过热保险火球）；持续扰乱场的 5 kW〈乱〉由驱散脉冲字节改写两个 dec 槽得到，同样经解码器接纳。
    报价是真实 `Cost.quote_structure/3` 的产出（施放处 293.15 K；报价本身的期望值由 `magic_cost_test.exs` 覆盖）。
  - 判定：期望值取设计附录 A.2–A.4 的手算数（灯寿命 132 s、x* 0.61 / 0.25、A.4 净欠账与毛剂量），容差写在各用例里；
    账目闭合与逐位一致是不变量。读数丢失的用例按 hash(id, tick) 逐个 id 搜索丢失的实例，不复制 hash 算法。
  - 不覆盖：热内核限流与真实净热（切片 1/5，这里净热是显式输入）、World 提交、多段与 P2 符号。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Structure}

  @digest "c6f60cdbcdcc287d71301ed415a0782d8968cc9c7376cb49aed7d2a0ab5e421b"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)
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
      field_bytes: field,
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

  # ---- A.4 驱散剂量（〈乱 100 kW，3 m〉〈蓄 60 kJ〉，τ = 0.595 s） ----

  # 脉冲两拍内给目标的总剂量，目标装载按出生值（A.4 口径）。
  defp pulse_dose(c, target, distance_m, feed_w) do
    p = pulse(c)

    Enum.reduce(1..3, {p, 0.0}, fn tick, {p, total} ->
      field =
        if p.status == :running, do: Structure.disruption_field(p, distance_m, tick, c.catalog)

      dose =
        if field,
          do: Structure.dose(target, field, %{env: 1, feed_w: feed_w}, c.catalog),
          else: 0.0

      p =
        if p.status == :running,
          do: elem(Structure.step(p, inputs(), tick, c.catalog), 0),
          else: p

      {p, total + dose}
    end)
    |> elem(1)
  end

  test "A.4 毛剂量（不扣偿还）：灯正中 1.407、1 m 0.617，火球 1 m 0.905，300 W 供能的灯正中 1.369", c do
    assert_in_delta pulse_dose(c, lamp(c), 0, 0), 1.407, 0.002
    assert_in_delta pulse_dose(c, lamp(c), 1, 0), 0.617, 0.002
    assert_in_delta pulse_dose(c, fireball(c), 1, 0), 0.905, 0.002
    assert_in_delta pulse_dose(c, lamp(c), 0, 300), 1.369, 0.002
  end

  # 同拍内脉冲与目标一起步进：World 先按拍首状态算全部场，再按 id 升序步进（脉冲不吃自己的场）。
  defp under_pulse(c, target, distance_m, ticks) do
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
          do: Structure.step(t, inputs(fields: fields), tick, c.catalog),
          else: {t, nil}

      {p, t, if(out, do: [out | outs], else: outs)}
    end)
  end

  test "A.4 结果：未供能的灯正中被驱散、1 m 处存活且净欠账 0.606；火球 1 m 处被驱散；脉冲约 0.6 s 后衰竭（按拍取整 1.0 s）", c do
    {p, lamp_center, outs} = under_pulse(c, lamp(c), 0, 4)
    assert lamp_center.status == {:terminated, :dispelled}
    Enum.each(outs, &assert_closed/1)
    assert p.status == {:terminated, :exhausted}
    assert p.last_tick == 2

    # v2.7 R1：第 2 拍场在 0.095 s 结束，其后 0.405 s 线内段偿还，1 m 处净欠账 0.606（毛剂量 0.617 见上一用例）。
    # A.4 按出生装载 x 0.221 计；逐拍步进时第 1 拍的越线泄漏约 4.9 kJ 使第 2 拍 x 降到 0.198，手算净欠账 0.6027，
    # 所以容差取 0.004。
    {_, lamp_1m, _} = under_pulse(c, lamp(c), 1, 2)
    assert lamp_1m.status == :running
    assert_in_delta lamp_1m.debt_micro / 1.0e6, 0.606, 0.004

    {_, fireball_1m, outs} = under_pulse(c, fireball(c), 1, 4)
    assert fireball_1m.status == {:terminated, :dispelled}
    Enum.each(outs, &assert_closed/1)
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

  # ---- 活动未付足时场按 t_eff 缩短（§5.3.3 v2.7 R7②） ----

  test "R7②：活动能未付足的那一拍，场的存续按 t_eff = 实付活动能 ÷ P_act 缩短；付足的拍为名义时长", c do
    # 5 kW 持续场：τ 按出生值约 60 s，但泄漏先付，运转储能在 τ 之前耗尽。最后一拍的拍首储能若不够“泄漏 + 2.5 kJ
    # 活动”，活动只付一部分；够付但付后低于 E_min 则整付后终止。〈蓄〉在 300.0–301.0 kJ 间按 100 J 逐个取（dec e = 2，
    # 偏移 29），找到第一个最后一拍未付足的实例。
    {tick, before, after_step, out} =
      Enum.find_value(3000..3010, fn m ->
        program = program!(patch(c.field_bytes, 29, <<2::4, m::12>>), c.catalog)
        quote = Cost.quote_structure(program, c.catalog, @site)
        p = Structure.new({3, 0}, hd(program.groups), quote, 0)

        Enum.reduce_while(1..200, p, fn tick, p ->
          {next, out} = Structure.step(p, inputs(), tick, c.catalog)

          cond do
            next.status == :running ->
              assert out.metrics.field_s == 0.5 and out.ledger.out.activity_mj == 2_500_000
              {:cont, next}

            out.ledger.out.activity_mj < 2_500_000 ->
              {:halt, {tick, p, next, out}}

            true ->
              {:halt, nil}
          end
        end)
      end)

    assert after_step.status == {:terminated, :exhausted}
    nominal = Structure.disruption_field(before, 1, tick, c.catalog)
    assert nominal.seconds == 0.5
    paid_mj = out.ledger.out.activity_mj
    assert out.metrics.field_s == paid_mj / 5000 / 1000 and out.metrics.field_s < 0.5

    # 发出者本拍已步进（且已终止）：World 取到的是 t_eff 的场，env 增量不变。
    case Structure.disruption_field(after_step, 1, tick, c.catalog) do
      nil -> assert paid_mj == 0
      shortened -> assert shortened == %{nominal | seconds: out.metrics.field_s}
    end
  end
end
