defmodule VoxelRegion.MagicCostTest do
  @moduledoc """
  只测试：结构报价 `Magic.Cost.quote_structure/3` 与分阶段失败 `staged_failure/3`（符号组合魔法 v2 切片 0b；
  决策稿测试矩阵第 3 条）。

  - 契约：设计 v2.10（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`）§4.2 逐步计价、`life_s`、
    `detect_w` 与 `entries`（A5；E2 按 `reading_source`）、§4.5 从零定义（Q21(a)；E3 计入步）、施法者动作报价（E4、
    附录 A.12）、§3.3 数值检查 T5/T6/T13/T14/T15、§3.6 与 §5.5 分阶段失败、§11.4.7 整数公式与 b_floor。
  - 夹具：程序一律由冻结样本 `fixtures/magic/ir-v2-samples.json` 经真实 `Program.decode_ir/2` 解码；反例由样本
    改写槽字节得到（偏移按设计 §11.4.4 逐字节注释手数），同样经解码器接纳，都是玩家能写出的程序。
  - 施放处读数：环境 293.15 K（附录 A.1）；T15 的热环境取设计 A.7 的示意值 ε = 0.9、h = 10 W/(m²·K)，
    World 的实值由切片 1 接线时传入。
  - 判定：期望值取设计（v2.9）正文与附录 A 的数字（A.2、A.3、A.7、A.8、A.10、§4.5 的例子），容差按文档给出的位数；
    不复制产品公式。
  - 不覆盖：多组程序（P2）、〈链〉供能、`entries_charge`（P1 目录没有〈纳〉〈印〉，恒为 0）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Structure}

  @digest "e337873b1daaafeb55397bd0ef8e01fda4572dd549d34cd6e268ec54ec638264"
  @path Application.app_dir(:voxel_region, "priv/magic/#{@digest}.json")
  @samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)
  @ambient_k 293.15
  @site %{
    ambient_k: @ambient_k,
    formation_distance_m: 3.0,
    emissivity: 0.9,
    exchange_w_per_m2_k: 10.0
  }
  @presets ~w(lamp fireball guarded_fireball hot_throw scorch timed_ember dispel_pulse)

  setup_all do
    bytes =
      Map.new(
        Jason.decode!(File.read!(@samples))["samples"],
        &{&1["id"], Base.decode16!(&1["program_hex"], case: :lower)}
      )

    %{catalog: Catalog.load(@path), bytes: bytes}
  end

  defp program!(bytes, catalog) do
    {:ok, %Program{kind: :structure} = program} = Program.decode_ir(bytes, catalog)
    program
  end

  defp quote!(c, bytes, site \\ []),
    do:
      Cost.quote_structure(program!(bytes, c.catalog), c.catalog, Map.merge(@site, Map.new(site)))

  defp patch(bytes, at, part),
    do:
      binary_part(bytes, 0, at) <>
        part <> binary_part(bytes, at + byte_size(part), byte_size(bytes) - at - byte_size(part))

  defp checks(quote), do: Enum.map(quote.rejects, & &1.check)

  # ---- 造价与前摇（附录 A.10，v2.3 姿态） ----

  test "7 个 P1 预设：造价、前摇与构造顺序对拍 A.10（v2.9），单元数对拍 A.3，全部通过数值检查", c do
    # {造价 kJ, 前摇 s, S, 构造顺序}；火球、过热保险火球、定时火种取 v2.8 G1 重算值，炽热投掷、灼点取 v2.9 D1 改正值。
    # 7 个预设都只写一类性质，不触发 §4.5 的从零定义附加量（Q21(a)），所以造价与 v2.8 相同。
    expected = %{
      "lamp" => {53.6, 0.91, 2, ~w(anchor.hand form.semblance cpl.glow energy.load)},
      "fireball" =>
        {462.7, 1.36, 4,
         ~w(anchor.hand form.semblance cpl.thermal energy.load act.throw cond.contact resp.release)},
      "guarded_fireball" =>
        {472.1, 1.60, 5,
         ~w(anchor.hand form.semblance cpl.thermal energy.load act.throw cond.contact resp.release cond.load resp.release)},
      "hot_throw" =>
        {1894.27, 2.43, 3, ~w(anchor.hand form.semblance cpl.thermal energy.load act.throw)},
      "scorch" => {421.66, 1.15, 2, ~w(anchor.surface form.semblance cpl.thermal energy.load)},
      "timed_ember" =>
        {206.9, 1.37, 2, ~w(anchor.surface form.semblance energy.load cond.timer resp.release)},
      "dispel_pulse" => {64.0, 0.84, 2, ~w(anchor.surface form.semblance int.disrupt energy.load)}
    }

    # 造价容差 0.1 kJ（A.10 的位数；v2.9 D1 改正后 7 组全部适用）。
    for id <- @presets do
      {kj, windup_s, units, order} = expected[id]
      q = quote!(c, c.bytes[id])

      assert_in_delta q.total_mj / 1.0e6, kj, 0.1, "#{id} 造价 #{q.total_mj / 1.0e6} kJ"

      assert_in_delta q.windup_s, windup_s, 0.01, "#{id} 前摇 #{q.windup_s} s"
      assert q.units == units and q.precision == 1, id
      assert Enum.map(q.steps, & &1.symbol) == order, id

      assert q.total_mj == q.physical_mj + q.loss_mj and List.last(q.steps).spent_mj == q.total_mj,
             id

      assert q.rejects == [], "#{id}: #{inspect(q.rejects)}"
    end
  end

  test "火球的整数量按 §11.4.7：T_ref 量化到 0.1 K，热份额、动能、物理能量为精确整数（A.2）", c do
    q = quote!(c, c.bytes["fireball"])

    # T_ref_dk = round(2931.5) = 2932；E_th0 = 500 g × 500 × (20000 − 2932) / 10；动能 = 500 × 12000² / 2e6。
    assert q.t_ref_k == 293.2
    assert q.e_th0_mj == 426_700_000 and q.kinetic_mj == 36_000 and q.c_th_j_per_k == 250.0
    assert q.physical_mj == 20_000_000 + 426_700_000 + 36_000
    # A.2：E_cap 1.047 MJ、x₀ 0.427、x* 0.612、E_min 1 kJ。
    assert_in_delta q.e_cap_mj / 1.0e9, 1.047, 0.001
    assert_in_delta q.x0, 0.427, 0.001
    assert_in_delta q.x_star, 0.612, 0.001
    assert q.e_min_mj == 1_000_000
  end

  test "A5：detect_w = 泄漏热份额 × (出生 P_run + P_rep，env = 1) + 发光；entries_spoof 按 reading_source 计外部读数种类（v2.10 E2）",
       c do
    # A.2：灯 0.5 × (178 + 113) + 100 W；火球 0.5 × (690 + 241) W，无发光。手算各项取整到 1 W，容差按此。
    lamp = quote!(c, c.bytes["lamp"])
    fireball = quote!(c, c.bytes["fireball"])
    assert_in_delta lamp.detect_w, 0.5 * (178 + 113) + 100, 1.0
    assert_in_delta fireball.detect_w, 0.5 * (690 + 241), 1.0
    # 口径固定为 env = 1：施法处更热不改变 detect_w（只改变 p_maint_w）。
    hot = quote!(c, c.bytes["lamp"], ambient_k: 500.0)
    assert hot.detect_w == lamp.detect_w and hot.p_maint_w > lamp.p_maint_w

    # 目录 reading_source：〈遇〉external；〈时〉〈满〉self，不计；过热保险火球〈遇〉+〈满〉仍为 1。P1 charge 恒为 0（E1）。
    for {id, spoof} <- [{"fireball", 1}, {"timed_ember", 0}, {"guarded_fireball", 1}, {"lamp", 0}] do
      assert Map.take(quote!(c, c.bytes[id]), [:entries_charge, :entries_spoof]) ==
               %{entries_charge: 0, entries_spoof: spoof},
             id
    end

    # 判据只看 reading_source，不从签名推断：同一目录只把〈遇〉改标 self（签名不变），火球即为 0；
    # 把〈满〉改标 external，过热保险火球〈遇〉+〈满〉为 2。
    relabel = fn id, source ->
      Jason.decode!(File.read!(@path))
      |> update_in(["symbols"], fn symbols ->
        Enum.map(symbols, &if(&1["id"] == id, do: %{&1 | "reading_source" => source}, else: &1))
      end)
      |> Jason.encode!()
      |> Catalog.decode()
    end

    for {id, source, preset, spoof} <- [
          {"cond.contact", "self", "fireball", 0},
          {"cond.load", "external", "guarded_fireball", 2}
        ] do
      catalog = relabel.(id, source)
      q = Cost.quote_structure(program!(c.bytes[preset], catalog), catalog, @site)
      assert q.entries_spoof == spoof, "#{id} → #{source}"
    end
  end

  test "Q21(a) 从零定义：灼点加〈辉〉写入两类性质，单元 +0.5、精度 +0.25、Q = 0.7；S·P 4.38、x* 0.32（§4.5）", c do
    # 灼点质段（偏移 19 n_qual，20–24〈热〉）后插入〈辉 100 W〉（下标 0x0010，dec(0, 100)），按规范顺序排在〈热〉之后。
    scorch = c.bytes["scorch"]

    glowing =
      binary_part(scorch, 0, 19) <>
        <<2>> <>
        binary_part(scorch, 20, 5) <> <<0x0010::16, 0x0064::16>> <> binary_part(scorch, 25, 7)

    plain = quote!(c, scorch)
    q = quote!(c, glowing)

    # 〈辉〉自身 1 单元，加从零定义第 2 类的 0.5；精度 +0.25；修复基值 r0·Q 由 0.05 /s 变为 0.05 × 0.7。
    assert q.units - plain.units == 1.5 and q.precision - plain.precision == 0.25
    assert_in_delta q.r_base_per_s / plain.r_base_per_s, 0.7, 1.0e-12

    # §4.5 的例子〈形〉〈热〉〈辉〉〈蓄〉：S·P 由 3 变为 4.38（= 3.5 × 1.25，文档取两位），x* 由 0.61 降到 0.32。
    assert q.units * q.precision == 4.375
    assert_in_delta q.x_star, 0.32, 0.005

    # 附加量在引入第 2 类的那一步进入构造（附 → 形 → 热 → 辉 → 蓄）。
    assert Enum.map(q.steps, & &1.complexity) == [0, 1, 2, 4.375, 4.375]

    # v2.10 E3：Ω 中断按含附加量的逐步 S·P 判定。Ω_eff = 4.375 恰好建成；略低于它即在第 4 步〈辉〉中断，只扣第 1–4 步。
    # Ω_eff = 3 也在第 4 步中断：若附加量不计入〈辉〉这一步（或推到最后一步），第 4 步只有 3 × 1 = 3，不会在此中断。
    [_, _, _, glow, _] = q.steps
    assert Cost.staged_failure(q, q.total_mj, 4.375) == nil
    assert Cost.staged_failure(q, q.total_mj, 4.37) == {4, glow.spent_mj, :omega}
    assert Cost.staged_failure(q, q.total_mj, 3.0) == {4, glow.spent_mj, :omega}
    assert glow.spent_mj < q.total_mj
  end

  test "施法者动作〈取〉：报价对拍附录 A.12——物理能量 0，loss = total = 调整损耗 + 出手前置，S·P = 1（v2.10 E4）", c do
    # A.12：静息 (150, −120, −120 | 30, 120, 120)° 到〈取〉(155, −90, −95 | 25, 90, 95)°，d = 0.97176 rad；S·P = 1、
    # 不计物理能量 → b = b0 = 1000 W；调整损耗 2·d·√(η·b) = 260.75 J，出手前置 b × 0.3 s = 300 J，合计 560.75 J；
    # 前摇 d·√(η/b) + 0（注能）+ 0.3 = 0.1304 + 0.3 = 0.4304 s。容差取 A.12 的位数。
    for id <- ~w(draw_1mj draw_2mj) do
      {:ok, %Program{kind: :caster_action} = draw} = Program.decode_ir(c.bytes[id], c.catalog)
      q = Cost.quote_structure(draw, c.catalog, @site)

      # rejects 只可能含 T6；施放处的能源目标在 3 m（域内），所以为空。T6 边界见下一条用例。
      assert {q.units * q.precision, q.physical_mj, q.rejects} == {1, 0, []}

      assert [
               %{
                 symbol: "energy.draw",
                 part_index: 0,
                 complexity: 1,
                 inject_s: inject_s,
                 adjust_s: adjust_s
               }
             ] =
               q.steps

      assert inject_s == 0
      assert_in_delta adjust_s / :math.sqrt(18 / 1000), 0.97176, 0.00001
      assert_in_delta adjust_s, 0.1304, 0.0001
      assert_in_delta q.windup_s, 0.4304, 0.0001
      # 报价不单列出手前置；按 A.12 的分解 260.75 + 300 比较合计。
      assert_in_delta q.total_mj / 1000, 260.75 + 300.0, 0.01
      assert q.total_mj == q.loss_mj and hd(q.steps).spent_mj == q.total_mj

      # fail_step 照常：余额不足以付构造费、或 Ω_eff < 1 时都在第 1 步中断。
      assert Cost.staged_failure(q, q.total_mj, 16) == nil
      assert Cost.staged_failure(q, q.total_mj - 1, 16) == {1, q.total_mj - 1, :energy}
      assert Cost.staged_failure(q, q.total_mj, 0.9) == {1, q.total_mj, :omega}
    end
  end

  test "Q-1 取能 T6（v2.10 E4）：能源目标距离 6.0 m 通过、6.01 m 被拒；只判 domain，造价与前摇不随距离变", c do
    # 目录 limits.local_domain_m = 6；〈取〉声明 numeric_checks: ["domain"]。形成距离 = 施法者眼点到目标宏格中心，
    # 由 World 算好放进 site。若取能子句仍忽略 site，6.01 m 一侧会错误地得到空表。
    for id <- ~w(draw_1mj draw_2mj) do
      {:ok, %Program{kind: :caster_action} = draw} = Program.decode_ir(c.bytes[id], c.catalog)
      quote_at = &Cost.quote_structure(draw, c.catalog, %{@site | formation_distance_m: &1})

      inside = quote_at.(6.0)
      outside = quote_at.(6.01)
      assert inside.rejects == [], id

      assert outside.rejects == [
               %{check: :domain, detail: %{distance_m: 6.01, local_domain_m: 6}}
             ],
             id

      assert Map.delete(outside, :rejects) == Map.delete(inside, :rejects), id
    end
  end

  test "b_floor：第一步只有形成锚（0 单元、无体积与能量），维护功率取 b0，调整时长有限（§11.4.7）", c do
    for id <- @presets do
      [first | _] = quote!(c, c.bytes[id]).steps
      assert first.complexity == 0 and first.inject_s == 0.0
      assert is_float(first.adjust_s) and first.adjust_s > 0
    end

    # 〈握〉距静息 1.07 rad（§2.6）：T_adj = 1.07 × √(η / b0) = 1.07 × √(18 / 1000)。
    assert_in_delta hd(quote!(c, c.bytes["lamp"]).steps).adjust_s, 1.07 * :math.sqrt(0.018), 0.001
  end

  # ---- 数值检查（§3.3） ----

  test "T5 capacity：火球同热量装进 0.15 m 球，装载超过储能硬上限（§4.6：x₀ 1.98，拒绝）", c do
    # 火球偏移 10 是〈形〉size1_mm：250 → 150。
    q = quote!(c, patch(c.bytes["fireball"], 10, <<150::16>>))
    assert [%{check: :capacity, detail: %{load_mj: load, e_cap_mj: cap}}] = q.rejects
    assert_in_delta load / cap, 1.98, 0.01
  end

  test "T6 domain：〈附〉的形成位置须在本地施法域 6 m 内；〈握〉不声明该检查", c do
    assert quote!(c, c.bytes["scorch"], formation_distance_m: 6.0).rejects == []
    q = quote!(c, c.bytes["scorch"], formation_distance_m: 6.5)
    assert q.rejects == [%{check: :domain, detail: %{distance_m: 6.5, local_domain_m: 6}}]
    assert quote!(c, c.bytes["fireball"], formation_distance_m: 6.5).rejects == []
  end

  test "T13 first_tick 边界两侧：所需最小 E₀_op 恰为 E₀ 时通过，多 1 mJ 即拒绝", c do
    # 灯的〈蓄〉改为 720 J（偏移 26，dec e = 0、m = 720）。所需最小值随环境温度（env）连续上升，二分找到它越过
    # 720 000 mJ 的地方：两侧相差远小于 1 mJ，于是一侧恰好等于 E₀、另一侧多 1 mJ。
    lamp = patch(c.bytes["lamp"], 26, <<0::4, 720::12>>)
    required = fn k -> quote!(c, lamp, ambient_k: k).first_tick_min_mj end
    assert required.(300.0) < 720_000 and required.(590.0) > 720_000

    {pass_k, fail_k} =
      Enum.reduce(1..80, {300.0, 590.0}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if required.(mid) <= 720_000, do: {mid, hi}, else: {lo, mid}
      end)

    passing = quote!(c, lamp, ambient_k: pass_k)
    failing = quote!(c, lamp, ambient_k: fail_k)
    assert passing.first_tick_min_mj == 720_000 and passing.rejects == []
    assert failing.first_tick_min_mj == 720_001

    assert failing.rejects == [
             %{check: :first_tick, detail: %{e_op_mj: 720_000, required_mj: 720_001}}
           ]
  end

  test "T14 ambient_floor：〈热〉T0 低于施法处环境温度即拒绝（P1 不开放制冷）", c do
    q = quote!(c, c.bytes["scorch"], ambient_k: 1600.0)
    assert %{check: :ambient_floor, detail: %{t0_dk: 15_000, t_ref_dk: 16_000}} in q.rejects
    # E_phys 的热份额项为 max(0, ·)，不因冷端口变小（§4.2 第 3 条）。
    assert q.e_th0_mj < 0 and q.physical_mj == 15_000_000
  end

  test "T15 thermal_step：10 g、2500 K 的 0.05 m 热球稳定步长约 13.8 ms，拒绝；P1 热预设全部通过（A.7）", c do
    # 火球改写：size1 250 → 50 mm（偏移 10），mass 500 → 10 g（偏移 16，dec e = 0），t0 20000 → 25000 dK（偏移 21）。
    small =
      c.bytes["fireball"]
      |> patch(10, <<50::16>>)
      |> patch(16, <<0::4, 10::12>>)
      |> patch(21, <<25_000::16>>)

    q = quote!(c, small)

    assert [%{step_ms: step_ms, c_th_j_per_k: 5.0, g_max_w_per_k: g}] =
             for(%{check: :thermal_step, detail: d} <- q.rejects, do: d)

    assert_in_delta step_ms, 13.8, 0.1
    assert_in_delta g, 163.0, 1.0

    for id <- ~w(fireball hot_throw scorch),
        do: refute(:thermal_step in checks(quote!(c, c.bytes[id])))
  end

  # ---- 分阶段失败（§3.6、§5.5） ----

  test "fail_step：Ω_eff 在第 k 步被 S·P 超过，或余额在第 k 步耗尽，只结算第 1..k 步", c do
    q = quote!(c, c.bytes["lamp"])
    # 构造顺序〈握〉〈形〉〈辉〉〈蓄〉，累计 S·P = 0、1、2、2。
    assert Enum.map(q.steps, & &1.complexity) == [0, 1, 2, 2]
    [_, _, glow, load] = q.steps

    assert Cost.staged_failure(q, q.total_mj, 16) == nil
    assert Cost.staged_failure(q, q.total_mj, 2) == nil

    # Ω_eff 1.5：第 3 步〈辉〉使 S·P = 2 > 1.5，付到第 3 步为止（余额充足），原因 :omega（决策稿 P6）。
    assert Cost.staged_failure(q, q.total_mj, 1.5) == {3, glow.spent_mj, :omega}
    # 余额只差 1 mJ：在最后一步耗尽，付到耗尽为止。
    assert Cost.staged_failure(q, q.total_mj - 1, 16) == {4, q.total_mj - 1, :energy}
    assert load.spent_mj == q.total_mj and glow.spent_mj < load.spent_mj

    # 余额在第 3 步就不够，原因 :energy。同一步两者都不满足时记 :omega（分辨先于能量，沿用 v1 次序）。
    assert Cost.staged_failure(q, glow.spent_mj - 1, 1.5) == {3, glow.spent_mj - 1, :omega}
    assert Cost.staged_failure(q, glow.spent_mj - 1, 16) == {3, glow.spent_mj - 1, :energy}
  end

  test "E_phys ≥ 0：全部预设 × 环境温度（含高于 T0 的冷端口情形）× 形成距离，物理能量非负且按 §11.4.7 组成", c do
    for id <- @presets, ambient <- [250.0, @ambient_k, 1600.0, 2600.0], distance <- [0.0, 7.0] do
      q = quote!(c, c.bytes[id], ambient_k: ambient, formation_distance_m: distance)
      %{groups: [group]} = program!(c.bytes[id], c.catalog)
      energy = Enum.find(group.energy, &(&1.id == "energy.load")).params["energy_mj"]
      assert q.physical_mj >= 0 and q.loss_mj >= 0 and q.total_mj >= q.physical_mj
      assert q.physical_mj == energy + max(0, q.e_th0_mj) + q.kinetic_mj, "#{id} @ #{ambient} K"
    end
  end

  # ---- life_s（§4.2 能量切片求积，附录 A.8） ----

  # Structure 逐拍模拟：env = 1、无供能；带热耦合者按 A.3 的近似让热份额流出 min(Φ_cap, 0.9σA(T⁴ − T_amb⁴))。
  defp simulated_life_s(c, id) do
    q = quote!(c, c.bytes[id])
    %{groups: [group]} = program!(c.bytes[id], c.catalog)
    area = q.phi_cap_w / c.catalog.runtime.throughput_density_w_per_m2
    s = Structure.new({1, 0}, group, q, 0)

    Enum.reduce_while(1..4000, s, fn tick, s ->
      outflow_j =
        case Structure.port_temperature(s) do
          nil ->
            0.0

          t ->
            min(
              min(q.phi_cap_w, 0.9 * 5.670374419e-8 * area * (t ** 4 - @ambient_k ** 4)) * 0.5,
              s.e_th_mj / 1000
            )
        end

      inputs = %{
        net_heat_j: -max(outflow_j, 0.0),
        feed_w: 0,
        temperature_k: @ambient_k,
        cell_heat_capacity_j_per_k: 1200.0,
        embedded: false,
        neighbors: [],
        fields: [],
        release_doses: [],
        contact: false
      }

      {s, _} = Structure.step(s, inputs, tick, c.catalog)
      if s.status == :running, do: {:cont, s}, else: {:halt, tick * Structure.tick_ms() / 1000}
    end)
  end

  test "life_s：无热耦合结构与逐拍模拟相差 ≤ 0.5%；带热耦合者偏短约 15–30%，以 Structure 逐拍为准（§4.2、A.8，v2.9 D2）", c do
    # {A.8 求积值 s, 是否带热耦合}
    for {id, documented} <- [{"lamp", 131.7}, {"timed_ember", 572.3}] do
      life = quote!(c, c.bytes[id]).life_s
      assert_in_delta life / documented, 1.0, 0.005, "#{id} life_s #{life}"
      simulated = simulated_life_s(c, id)
      assert abs(life / simulated - 1) <= 0.005, "#{id}: 求积 #{life} s，逐拍 #{simulated} s"
    end

    # 契约只有一条：热端口高于环境时求积值 ≤ 真实寿命；偏短幅度取决于热份额的流出速度，文档写作“约 15–30%”
    # （服务端 0b 实测火球 −17.9%、灼点 −20.9%、炽热投掷 −25.3%），所以比值判在 [0.70, 0.85]。
    for {id, documented} <- [{"fireball", 20.5}, {"scorch", 24.9}, {"hot_throw", 57.5}] do
      life = quote!(c, c.bytes[id]).life_s
      assert_in_delta life / documented, 1.0, 0.01, "#{id} life_s #{life}"
      ratio = life / simulated_life_s(c, id)
      assert ratio >= 0.70 and ratio <= 0.85, "#{id}: 求积 / 逐拍 = #{ratio}"
    end

    # 驱散脉冲：求积值即真实存续 τ = (E₀ − E_min) / P_act = 0.595 s。
    assert_in_delta quote!(c, c.bytes["dispel_pulse"]).life_s, 0.595, 0.003
  end
end
