defmodule SceneServer.Body.ColdValidationTest do
  @moduledoc """
  只测试：身体体温模型对照公开的人体冷暴露实测（期望值全部来自下列文献，不由本模型生成）。1 Hz 推进 `Body.Thermo.step/3`，
  World 一侧用解析替身（浸没：G = 体表 × 浸没比例 / 总热阻，每秒 q = G·(T_水 − T_皮)）。完整数据表与出处见 body/README.md。

  | 条件 | 实测 | 出处 |
  |---|---|---|
  | 冷海水浸泡，轻便衣物 + 木棉救生衣，静止，4.6–18.2 °C | 直肠降温率 C = 0.0785 − 0.0034·T_w °C/min；产热 H = 4.19 − 0.117·T_w kcal/min；存活（到 30 °C）t = 15 + 7.2/C min | Hayward, Eckerson & Collis 1975, Can J Physiol Pharmacol, doi:10.1139/y75-002 |
  | 浸没衣物总热阻（含水边界层） | 0.06 clo（裸）– 0.23 clo | Nunneley, Wissler & Allan 1985, Aviat Space Environ Med, PMID 4084171 |
  | 0–5 °C 冷水浸泡 | 核心 2–4 °C/h | Hawley et al. 2024, Wilderness Environ Med, doi:10.1177/10806032241272127 |
  | 8 °C 水浸泡后升温到 20 °C 诱发峰值寒战 | 峰值 4.9 ± 0.8 倍静息代谢 | Eyolfson et al. 2001, Eur J Appl Physiol, doi:10.1007/s004210000329 |
  | 0 °C 空气（22 °C 起约 15–18 min 降到 0 °C），0.63 clo，风 0.8–1.2 m/s，坐 | 直肠降 0.3 °C：103 ± 37 min（20–146）；降 0.8 °C：149 ± 32 min（89–173） | Wallace et al. 2023, Physiol Rep, doi:10.14814/phy2.15893 |
  | 寒战时核心可进入热平衡 | 线性外推降温率到致死温度只在失热超过寒战时成立；寒战能抵消失热时核心先降后稳，存活由寒战耐力决定 | Brooks, Survival in Cold Waters（Transport Canada）第 7 章 c 节 |
  | 冷水浸泡寒战耐力 | 61% / 69% 峰值寒战持续 105–388 min（均值 250 / 199 min），未见停止 | Tikuisis et al. 2002, Eur J Appl Physiol, doi:10.1007/s00421-002-0589-1 |
  | 中等寒战（约 3 倍静息）供能 | 肌糖原约占总产热 27% | Blondin et al. 2010, Eur J Appl Physiol, doi:10.1007/s00421-009-1210-7 |
  | 10 °C 液冷服 2 h 寒战，低糖原 vs 高糖原 | 总产热不受糖原储备影响（低糖原时脂肪蛋白补上） | Haman et al. 2004, J Appl Physiol, doi:10.1152/japplphysiol.00427.2003 |

  浸泡校验用头露出水面：浸没比例 0.93（Stolwijk 1971 头部占体表 7%），头部空气温度取水温、静止空气。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Thermo

  @c 273.15
  @clo 0.155
  @kcal_min 4186.8 / 60

  # 1 Hz 推进 seconds 秒，返回逐秒状态（含初态）与逐秒代谢。
  defp simulate(body, seconds, inputs) do
    {states, mets} =
      Enum.map_reduce(1..seconds, body, fn _, b ->
        {n, account} = Thermo.step(b, 1.0, inputs.(b))
        {{n, account.metabolic_j}, n}
      end)
      |> elem(0)
      |> Enum.unzip()

    {[body | states], mets}
  end

  defp immersion(water_c, total_r, immersed, seconds) do
    g = Body.params().area_m2 * immersed / total_r
    simulate(Body.new(), seconds, fn b -> %{q_j: g * (water_c + @c - b.skin_k), air_k: water_c + @c, immersed: immersed} end)
  end

  # 第一个核心低于 x °C 的时刻（分钟）；没有为 nil。
  defp minutes_below(states, x), do: Enum.find_index(states, &(&1.core_k < x + @c)) |> then(&(&1 && &1 / 60))
  # 15–60 分钟的平均核心降温率 °C/h（Hayward 的线性段在约 15 分钟的平台之后）。
  defp rate(states), do: (Enum.at(states, 900).core_k - Enum.at(states, 3600).core_k) / 0.75
  # 热平衡：最后 2 小时核心变化 < 0.05 K 且在 30 °C 以上。
  defp balanced?(states) do
    last = List.last(states).core_k
    abs(Enum.at(states, -7201).core_k - last) < 0.05 and last > 30.0 + @c
  end

  describe "冷水浸泡（Hayward 1975；衣物热阻范围 Nunneley 1985）" do
    test "5 / 10 / 15 °C：Hayward 实测降温率与存活时间落在 0.23 clo 与 0.06 clo（浸没衣物范围两端）的模型结果之间；产热不低于 Hayward、不超过峰值寒战" do
      for tw <- [5.0, 10.0, 15.0] do
        hayward_rate = (0.0785 - 0.0034 * tw) * 60
        hayward_survival = 15 + 7.2 / (0.0785 - 0.0034 * tw)
        hayward_met = (4.19 - 0.117 * tw) * @kcal_min

        [{thin_states, thin_met}, {thick_states, thick_met}] =
          for clo <- [0.06, 0.23], do: immersion(tw, clo * @clo, 0.93, 10 * 3600)

        {fast, slow} = {rate(thin_states), rate(thick_states)}
        {early, late} = {minutes_below(thin_states, 30.0), minutes_below(thick_states, 30.0)}
        [m_thin, m_thick] = for m <- [thin_met, thick_met], do: Enum.sum(Enum.take(m, 3600)) / 3600

        IO.puts("VALIDATE hayward Tw=#{tw} rate_C_per_h model[0.23clo..0.06clo]=#{Float.round(slow, 2)}..#{Float.round(fast, 2)} data=#{Float.round(hayward_rate, 2)} | " <>
                  "t30_min model=#{early && Float.round(early, 1)}..#{late && Float.round(late, 1)} data=#{Float.round(hayward_survival, 1)} | " <>
                  "met_W model=#{round(m_thick)}..#{round(m_thin)} data=#{round(hayward_met)} | t35_min=#{inspect(minutes_below(thick_states, 35.0))}..#{inspect(minutes_below(thin_states, 35.0))}")

        assert slow <= hayward_rate and hayward_rate <= fast
        # Hayward 的存活时间是把降温率线性外推到 30 °C；寒战能抵消失热时核心进入热平衡、线性外推不成立（Brooks 第 7 章 c 节）。
        # 所以快端（0.06 clo）要么不晚于 Hayward 到 30 °C，要么在 30 °C 以上进入热平衡（最后 2 小时核心变化 < 0.05 K）。
        assert (early != nil and early <= hayward_survival) or (early == nil and balanced?(thin_states))
        assert late == nil or hayward_survival <= late
        # 产热：不低于 Hayward（静止、救生衣），不超过峰值寒战 4.9 倍静息（Eyolfson 2001）
        for m <- [m_thin, m_thick], do: assert(m >= hayward_met and m <= 4.9 * 58.2 * Body.params().area_m2)
      end
    end

    test "游戏内浸没（World 浸没边：湿衣 0.03 + 水 1/100 m²·K/W，全身浸没）：0 °C 与 5 °C 水 15–60 min 降温率在 2 °C/h（Hawley 2024 下限）与 Hayward 之间" do
      for tw <- [0.0, 5.0] do
        {states, _} = immersion(tw, 0.03 + 1 / 100, 1.0, 4 * 3600)
        r = rate(states)
        hayward = (0.0785 - 0.0034 * tw) * 60

        IO.puts("VALIDATE game_immersion Tw=#{tw} rate_C_per_h=#{Float.round(r, 2)} range=2.0..#{Float.round(hayward, 2)} | " <>
                  "t35_min=#{Float.round(minutes_below(states, 35.0), 1)} t32_min=#{minutes_below(states, 32.0) && Float.round(minutes_below(states, 32.0), 1)} t28_min=#{minutes_below(states, 28.0) && Float.round(minutes_below(states, 28.0), 1)}")

        assert r >= 2.0 and r <= hayward
      end
    end

    test "峰值寒战：模型寒战上限 + 静息 = Eyolfson 2001 实测峰值 4.9 ± 0.8 倍静息之内" do
      p = Body.params()
      ratio = (p.metabolic_w_per_m2 + p.shiver_max_w_per_m2) / p.metabolic_w_per_m2
      assert ratio >= 4.9 - 0.8 and ratio <= 4.9 + 0.8
    end
  end

  describe "寒战供能（Blondin 2010、Haman 2004、Tikuisis 2002）" do
    # 峰值寒战 232.8 W/m² × 1.8877 m² = 439.45656 W。皮肤 33 °C 时 Tikuisis & Giesbrecht 需求只剩核心项 155.5·(37 − T_c)/√15，
    # 取 f × 232.8 W/m² 解出 T_c：f = 0.69 → 32.999188 °C，f = 0.61 → 33.463061 °C（都在体温调节满功能带 ≥ 32 °C 内）。
    test "61% / 69% 峰值寒战：固定核心 / 皮肤、只让储备随步推进，388 min（Tikuisis 2002 最长观测）内寒战不降；模型耐力远超观测上限" do
      p = Body.params()
      peak = p.shiver_max_w_per_m2 * p.area_m2

      for f <- [0.61, 0.69] do
        core = 37.0 - f * p.shiver_max_w_per_m2 * :math.sqrt(15.0) / 155.5
        held = %{Body.new() | core_k: core + @c, skin_k: 33.0 + @c}

        {last, shiver, glycogen} =
          Enum.reduce(1..(388 * 60), {held, 0.0, 0.0}, fn _, {b, s, g} ->
            {n, a} = Thermo.step(%{held | reserve_j: b.reserve_j, fat_reserve_j: b.fat_reserve_j}, 1.0, %{q_j: 0.0, air_k: 33.0 + @c})
            assert_in_delta a.shiver_j, f * peak, 1.0e-6
            {n, s + a.shiver_j, g + a.shiver_glycogen_j}
          end)

        # 账：Σ 寒战 = 糖原减少 + 脂肪减少；糖原份额 27%（Blondin 2010）
        assert_in_delta shiver, held.reserve_j - last.reserve_j + held.fat_reserve_j - last.fat_reserve_j, 1.0e-3
        assert_in_delta glycogen / shiver, 0.27, 1.0e-9

        glycogen_h = p.reserve_full_j / (0.27 * f * peak) / 3600
        total_h = (p.reserve_full_j + p.fat_full_j) / (f * peak) / 3600
        IO.puts("VALIDATE endurance f=#{f} shiver_W=#{Float.round(f * peak, 1)} glycogen_empty_h=#{Float.round(glycogen_h, 1)} both_empty_h=#{Float.round(total_h, 1)} (data 105..388 min, no cessation)")
        assert total_h * 60 >= 388
      end
    end

    test "10 °C 浸泡 2 h（0.23 clo）：糖原空与满储备总产热逐秒相同（Haman 2004）；糖原空时寒战全由脂肪付，满储备时糖原付 27%" do
      g = Body.params().area_m2 * 0.93 / (0.23 * @clo)
      inputs = fn b -> %{q_j: g * (10.0 + @c - b.skin_k), air_k: 10.0 + @c, immersed: 0.93} end

      sums = fn body ->
        Enum.reduce(1..7200, {body, 0.0, 0.0, 0.0}, fn _, {b, m, s, gl} ->
          {n, a} = Thermo.step(b, 1.0, inputs.(b))
          {n, m + a.metabolic_j, s + a.shiver_j, gl + a.shiver_glycogen_j}
        end)
      end

      {_, m_full, s_full, g_full} = sums.(Body.new())
      {_, m_low, s_low, g_low} = sums.(%{Body.new() | reserve_j: 0.0})

      assert m_low == m_full
      assert s_full > 0.0
      assert_in_delta g_full / s_full, 0.27, 1.0e-9
      assert g_low == 0.0 and s_low == s_full
    end
  end

  describe "冷空气（Wallace 2023）" do
    test "0 °C 空气、0.63 clo、1 m/s、22 °C 起 16.5 min 线性降到 0 °C：核心降 0.3 °C 的时刻落在实测 20–146 min 内" do
      ramp = 16.5 * 60

      {states, _} =
        Enum.map_reduce(1..(4 * 3600), Body.new(), fn t, b ->
          air = @c + max(22.0 * (1 - t / ramp), 0.0)
          {n, _} = Thermo.step(b, 1.0, %{q_j: 0.0, air_k: air, wind_mps: 1.0, clothing_m2_k_per_w: 0.63 * @clo})
          {n, n}
        end)
        |> then(fn {s, _} -> {[Body.new() | s], nil} end)

      start = Body.new().core_k
      drop = fn d -> Enum.find_index(states, &(&1.core_k <= start - d)) |> then(&(&1 && &1 / 60)) end
      at = fn m -> start - Enum.at(states, m * 60).core_k end

      IO.puts("VALIDATE wallace drop0.3_min=#{Float.round(drop.(0.3), 1)} (data 103±37, 20..146) drop0.8_min=#{inspect(drop.(0.8))} (data 149±32, 89..173) | " <>
                "drop@149=#{Float.round(at.(149), 2)} drop@173=#{Float.round(at.(173), 2)} skin@19=#{Float.round(Enum.at(states, 19 * 60).skin_k - @c, 1)} (data ~27)")

      assert drop.(0.3) >= 20 and drop.(0.3) <= 146
    end
  end
end
