defmodule VoxelRegion.MagicCostTest do
  @moduledoc """
  只测试：结构报价 `Magic.Cost.quote_structure/3` 与分阶段失败 `staged_failure/3`（符号组合魔法 v2 切片 0b；
  决策稿测试矩阵第 3 条）。

  - 契约：设计 v2.7（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`）§4.2 逐步计价与 `life_s`、
    §3.3 数值检查 T5/T6/T13/T14/T15、§3.6 与 §5.5 分阶段失败、§11.4.7 整数公式与 b_floor。
  - 夹具：程序一律由冻结样本 `fixtures/magic/ir-v2-samples.json` 经真实 `Program.decode_ir/2` 解码；反例由样本
    改写槽字节得到（偏移按设计 §11.4.4 逐字节注释手数），同样经解码器接纳，都是玩家能写出的程序。
  - 施放处读数：环境 293.15 K（附录 A.1）；T15 的热环境取设计 A.7 的示意值 ε = 0.9、h = 10 W/(m²·K)，
    World 的实值由切片 1 接线时传入。
  - 判定：期望值取设计（v2.8）正文与附录 A 的数字（A.3、A.7、A.8、A.10），容差按文档给出的位数；不复制产品公式。
  - 不覆盖：多组程序（P2）、〈链〉供能、`detect_w` 与 `entries`（设计未给定义，见决策稿进度日志）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Structure}

  @digest "c6f60cdbcdcc287d71301ed415a0782d8968cc9c7376cb49aed7d2a0ab5e421b"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)
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

  test "7 个 P1 预设：造价、前摇与构造顺序对拍 A.10（v2.8 姿态），单元数对拍 A.3，全部通过数值检查", c do
    # {造价 kJ, 前摇 s, S, 构造顺序}；火球、过热保险火球、定时火种取 v2.8 G1 重算值。
    expected = %{
      "lamp" => {53.6, 0.91, 2, ~w(anchor.hand form.semblance cpl.glow energy.load)},
      "fireball" =>
        {462.7, 1.36, 4,
         ~w(anchor.hand form.semblance cpl.thermal energy.load act.throw cond.contact resp.release)},
      "guarded_fireball" =>
        {472.1, 1.60, 5,
         ~w(anchor.hand form.semblance cpl.thermal energy.load act.throw cond.contact resp.release cond.load resp.release)},
      "hot_throw" =>
        {1894.5, 2.43, 3, ~w(anchor.hand form.semblance cpl.thermal energy.load act.throw)},
      "scorch" => {421.8, 1.15, 2, ~w(anchor.surface form.semblance cpl.thermal energy.load)},
      "timed_ember" =>
        {206.9, 1.37, 2, ~w(anchor.surface form.semblance energy.load cond.timer resp.release)},
      "dispel_pulse" => {64.0, 0.84, 2, ~w(anchor.surface form.semblance int.disrupt energy.load)}
    }

    # 造价容差 0.1 kJ（A.10 的位数）。例外：炽热投掷与灼点在 A.10 的“零路径”列就比按 §4.2 逐步计价的结果高
    # 0.19 / 0.13 kJ（其余 5 组零路径逐位一致），差异不来自姿态路径；已报 worldbook 待核，这两组暂按 0.25 kJ 判。
    tolerance_kj = %{"hot_throw" => 0.25, "scorch" => 0.25}

    for id <- @presets do
      {kj, windup_s, units, order} = expected[id]
      q = quote!(c, c.bytes[id])

      assert_in_delta q.total_mj / 1.0e6,
                      kj,
                      Map.get(tolerance_kj, id, 0.1),
                      "#{id} 造价 #{q.total_mj / 1.0e6} kJ"

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

    # Ω_eff 1.5：第 3 步〈辉〉使 S·P = 2 > 1.5，付到第 3 步为止（余额充足）。
    assert Cost.staged_failure(q, q.total_mj, 1.5) == {3, glow.spent_mj}
    # 余额只差 1 mJ：在最后一步耗尽，付到耗尽为止。
    assert Cost.staged_failure(q, q.total_mj - 1, 16) == {4, q.total_mj - 1}
    assert load.spent_mj == q.total_mj and glow.spent_mj < load.spent_mj
    # 余额在第 3 步就不够。
    assert Cost.staged_failure(q, glow.spent_mj - 1, 16) == {3, glow.spent_mj - 1}
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

  test "life_s：无热耦合结构与逐拍模拟相差 ≤ 0.5%；有热耦合者为偏短 16–25% 的保守下界（A.8）", c do
    # {A.8 求积值 s, 是否带热耦合}
    for {id, documented} <- [{"lamp", 131.7}, {"timed_ember", 572.3}] do
      life = quote!(c, c.bytes[id]).life_s
      assert_in_delta life / documented, 1.0, 0.005, "#{id} life_s #{life}"
      simulated = simulated_life_s(c, id)
      assert abs(life / simulated - 1) <= 0.005, "#{id}: 求积 #{life} s，逐拍 #{simulated} s"
    end

    for {id, documented} <- [{"fireball", 20.5}, {"scorch", 24.9}, {"hot_throw", 57.5}] do
      life = quote!(c, c.bytes[id]).life_s
      assert_in_delta life / documented, 1.0, 0.01, "#{id} life_s #{life}"
      ratio = life / simulated_life_s(c, id)
      assert ratio >= 0.74 and ratio <= 0.85, "#{id}: 求积 / 逐拍 = #{ratio}"
    end

    # 驱散脉冲：求积值即真实存续 τ = (E₀ − E_min) / P_act = 0.595 s。
    assert_in_delta quote!(c, c.bytes["dispel_pulse"]).life_s, 0.595, 0.003
  end
end
