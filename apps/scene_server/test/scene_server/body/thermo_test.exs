defmodule SceneServer.Body.ThermoTest do
  @moduledoc """
  身体 L1 体温模型单测：单步手算、能量账、伤病推导与湿衣。期望值均为手算（参数表见 body/README.md）：

  - 体表 1.8877 m²（Stolwijk 标准人）；静息代谢 58.2 × 1.8877 = 109.86414 W，按 Stolwijk 基础产热比例（合计 74.45 kcal/h）分配：
    核心 58.43 → 86.223797 W，躯干肌肉 5.00 → 7.3783842 W，躯干脂肪 2.13 → 3.1431916 W，皮肤 1.05 → 1.5494607 W；
  - 热容（kcal/K × 4186.8）：核心 14.84 → 62132.112，躯干肌肉 16.15 → 67616.82，躯干脂肪 4.25 → 17793.9，皮肤 3.35 → 14025.78 J/K；
  - 静止空气 1 clo 干热系数 1.8877/(0.155 + 1/7.8) = 6.6654866 W/K；
  - 寒战需求（Tikuisis & Giesbrecht 1999）[155.5·(37 − T_c) + 47·(33 − T_s) − 1.57·(33 − T_s)²]/√15 W/m²。
  寒冷暴露的实测对照（冷水浸泡、冷空气）在 `cold_validation_test.exs`。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Thermo

  @c 273.15
  @met 109.86414
  @inner [:trunk_muscle_k, :trunk_fat_k, :limb_core_k, :limb_muscle_k, :limb_fat_k]

  defp air(k), do: %{q_j: 0.0, air_k: k}

  # 推进一步并核对能量账：储热变化（各节点热容 × 温升之和）= q + 代谢 − 干热散失 − 出汗 − 湿衣蒸发；
  # 寒战热 = 糖原付 + 脂肪付，各等于该储备的减少量；组织块只随 tissue_j 变化。
  defp step!(body, inputs, dt \\ 1.0) do
    {next, account} = Thermo.step(body, dt, inputs)
    assert_in_delta account.stored_j, Body.heat_content_j(next) - Body.heat_content_j(body), 1.0e-6
    assert_in_delta account.shiver_glycogen_j, body.reserve_j - next.reserve_j, 1.0e-6
    assert_in_delta account.shiver_fat_j, body.fat_reserve_j - next.fat_reserve_j, 1.0e-6
    assert_in_delta account.shiver_j, account.shiver_glycogen_j + account.shiver_fat_j, 1.0e-9
    assert account.shiver_glycogen_j >= 0.0 and account.shiver_fat_j >= 0.0
    assert_in_delta Body.tissue_capacity_j_per_k() * (next.tissue_k - body.tissue_k), Map.get(inputs, :tissue_j, 0.0), 1.0e-9

    assert_in_delta account.stored_j,
                    account.q_j + account.metabolic_j - account.convection_j - account.sweat_j - account.drying_j,
                    1.0e-9

    {next, account}
  end

  defp run(body, inputs, steps),
    do: Enum.reduce(1..steps, body, fn _, b -> step!(b, inputs) |> elem(0) end)

  defp uniform(t_c), do: Enum.reduce([:core_k, :skin_k | @inner], Body.new(), &Map.put(&2, &1, t_c + @c))

  defp severity(body, tag) do
    case Enum.find(Body.injuries(body), &(&1.tag == tag)) do
      nil -> 0
      injury -> injury.severity
    end
  end

  describe "单步手算与能量账" do
    test "调定点身体的五个内层是该核心 / 皮肤温度下的稳态：一步后内层温度不变" do
      body = Body.new()
      assert body.core_k == 36.8 + @c and body.skin_k == 34.0 + @c
      {next, _} = step!(body, air(20.0 + @c))
      for f <- @inner, do: assert_in_delta(Map.fetch!(next, f), Map.fetch!(body, f), 1.0e-9)
      # 由外向内：皮肤 34 < 四肢脂肪 < 四肢肌肉 < 四肢核心、躯干脂肪 < 躯干肌肉 < 核心 36.8
      assert body.limb_fat_k < body.limb_muscle_k and body.limb_muscle_k < body.limb_core_k
      assert body.trunk_fat_k < body.trunk_muscle_k and body.trunk_muscle_k < body.core_k
      assert body.skin_k < body.limb_fat_k
    end

    test "全身均匀 37 °C（内部无温差、无导热与血流换热）、20 °C 空气、接触吸热 1000 J：各节点只按自己的产热与外部项变化" do
      {next, account} = step!(uniform(37.0), %{q_j: 1000.0, air_k: 20.0 + @c})
      # 干热 6.6654866 × 17 = 113.31327 W；出汗 170·0.2·e^(3/10.7)·2430/3600·1.8877 = 57.343008 W；无寒战（需求为负）
      assert_in_delta account.metabolic_j, @met, 1.0e-9
      assert_in_delta account.convection_j, 113.31327, 1.0e-4
      assert_in_delta account.sweat_j, 57.343008, 1.0e-5
      assert_in_delta next.core_k - (37.0 + @c), 86.223797 / 62_132.112, 1.0e-10
      assert_in_delta next.skin_k - (37.0 + @c), (1000 + 1.5494607 - 113.31327 - 57.343008) / 14_025.78, 1.0e-8
      assert_in_delta next.trunk_fat_k - (37.0 + @c), 3.1431916 / 17_793.9, 1.0e-10
    end

    test "层间导热与血流：躯干脂肪 35 °C、其余 37 °C 时它得 肌肉导热 + 皮肤导热 + 血流 = 63.05786 W" do
      body = %{uniform(37.0) | trunk_fat_k: 35.0 + @c}
      {next, _} = step!(body, air(37.0 + @c))
      # 肌肉→脂肪 4.75 × 1.163 × 2 = 11.0485；皮肤→脂肪 19.8 × 1.163 × 2 = 46.0548；血液 2.56 L/h × 1.163 × 2 = 5.95456
      assert_in_delta next.trunk_fat_k - body.trunk_fat_k, (63.05786 + 3.1431916) / 17_793.9, 1.0e-10
    end

    test "寒战：需求按核心与皮肤温度手算，进躯干肌肉 0.85/0.99，肌肉血流随寒战增加（每 kcal/h 1 L/h）" do
      body = %{uniform(36.0) | skin_k: 20.0 + @c, trunk_muscle_k: 35.0 + @c}
      {next, account} = step!(body, air(20.0 + @c))
      # 需求 (155.5 + 47·13 − 1.57·169)/√15 = 129.40154 W/m² → 244.27128 W（低于峰值 232.8 × 1.8877 = 439.45656 W）
      assert_in_delta account.shiver_j, 244.27128, 1.0e-4
      assert_in_delta account.metabolic_j, @met + 244.27128, 1.0e-4
      # 躯干肌肉：产热 7.3783842 + 寒战 244.27128 × 0.85/0.99 = 209.72787；血流 (6.00 + 209.72787/1.163) L/h × 1.163 × 1 K = 216.70587；
      # 核心导热 1.37 × 1.163 × 1 = 1.59331；脂肪导热 4.75 × 1.163 × 1 = 5.52425 → 合计 440.92968 W
      assert_in_delta next.trunk_muscle_k - body.trunk_muscle_k, 440.92968 / 67_616.82, 1.0e-9
    end

    test "寒战在峰值处封顶（232.8 W/m²），调定点身体不寒战" do
      colder = %{Body.new() | core_k: 33.0 + @c, skin_k: 18.0 + @c}
      # 需求 (155.5·4 + 47·15 − 1.57·225)/√15 = 251.42117 > 232.8 → 439.45656 W
      {_, account} = step!(colder, air(0.0 + @c))
      assert_in_delta account.shiver_j, 439.45656, 1.0e-6
      assert Thermo.shiver_demand_w_per_m2(Body.new()) == 0.0
      {_, account} = step!(Body.new(), air(20.0 + @c))
      assert account.shiver_j == 0.0
    end
  end

  describe "环境" do
    test "20 °C 空气（世界全局环境温度）下调定点身体 4 小时保持约 37 °C 稳态、不寒战" do
      body = run(Body.new(), air(20.0 + @c), 4 * 3600)
      later = run(body, air(20.0 + @c), 600)

      assert later.core_k - @c > 36.8 and later.core_k - @c < 37.0
      assert abs(later.core_k - body.core_k) < 0.005
      assert later.reserve_j == Body.params().reserve_full_j
      assert later.fat_reserve_j == Body.params().fat_full_j
      assert Body.injuries(later) == []
      assert Body.life(later) == 100
      assert later.status == :alive
    end

    test "0 °C 空气无接触：第一步干热按手算，之后皮肤与外层先降、寒战提高产热，核心随后才降" do
      {_, account} = step!(Body.new(), air(0.0 + @c))
      # 6.6654866 × 34 = 226.62655 W
      assert_in_delta account.convection_j, 226.62655, 1.0e-4

      ten = run(Body.new(), air(0.0 + @c), 600)
      assert ten.skin_k < 33.0 + @c
      assert ten.limb_fat_k < Body.new().limb_fat_k
      assert ten.core_k > 36.6 + @c
      {_, account} = step!(ten, air(0.0 + @c))
      assert account.shiver_j > 0.0
    end
  end

  # 风（气候区 wind_mps）：对流系数 h_c = max(3.1, 8.3·v^0.6)（Gagge / ASHRAE）。
  #   v = 5：h_c = 21.800181；干热系数 1.8877/(0.155 + 1/(21.800181 + 4.7)) = 9.7942471 W/K；v = 1：1.8877/(0.155 + 1/13) = 8.1393367 W/K。
  #   v = 0.1：8.3·0.1^0.6 = 2.0849 < 3.1 → 取下限 3.1，与静止空气相同。
  describe "风（气候区 wind_mps）" do
    test "风速 0、缺省、低于自然对流下限（0.1 m/s）：一步结果与不传风速逐位相同" do
      body = %{Body.new() | skin_k: 25.0 + @c, core_k: 36.2 + @c}
      still = Thermo.step(body, 1.0, air(-25.0 + @c))

      for v <- [0.0, 0, 0.1],
          do: assert(Thermo.step(body, 1.0, Map.put(air(-25.0 + @c), :wind_mps, v)) == still)
    end

    test "5 m/s、−25 °C：干热 9.7942471 × 59 = 577.86058 W；1 m/s、0 °C：8.1393367 × 34 = 276.73745 W" do
      {_, account} = step!(Body.new(), Map.put(air(-25.0 + @c), :wind_mps, 5.0))
      assert_in_delta account.convection_j, 577.86058, 1.0e-4
      {_, account} = step!(Body.new(), Map.put(air(0.0 + @c), :wind_mps, 1.0))
      assert_in_delta account.convection_j, 276.73745, 1.0e-4
    end

    test "干衣热阻可由输入给定（衣物系统接入前供校验场景用）：0.5 clo、0 °C 静止空气 1.8877 × 34/(0.0775 + 1/7.8)" do
      {_, account} = step!(Body.new(), Map.put(air(0.0 + @c), :clothing_m2_k_per_w, 0.0775))
      assert_in_delta account.convection_j, 1.8877 * 34 / (0.0775 + 1 / 7.8), 1.0e-9
    end
  end

  # 剂量读局部接触组织块温度：Scene 里它只随 World 回传的 tissue_j 变化，这里给定组织块温度、tissue_j = 0 即保持该温度。
  describe "烧伤与冻伤（组织块温度）" do
    defp held(tissue_c), do: %{Body.new() | tissue_k: tissue_c + @c}

    test "World 回传的 tissue_j 按组织块热容改变其温度，差额进皮肤：tissue_j = 2094 J → 组织块 +10 K" do
      body = Body.new()
      {next, account} = step!(body, %{q_j: 3000.0, tissue_j: 2094.0, air_k: 20.0 + @c})
      {plain, _} = step!(body, %{q_j: 906.0, air_k: 20.0 + @c})
      assert_in_delta next.tissue_k, 44.0 + @c, 1.0e-9
      # 皮肤只得 3000 − 2094 = 906 J：与直接给 906 J、不给组织块热的一步相同
      assert_in_delta next.skin_k, plain.skin_k, 1.0e-12
      assert account.tissue_j == 2094.0
    end

    test "组织块 60 °C 每秒累计 1 个剂量单位：1、3、5 秒依次出现 1、2、3 度，只增不减" do
      degrees =
        Enum.scan(1..5, held(60.0), fn _, b -> step!(b, air(20.0 + @c)) |> elem(0) end)
        |> Enum.map(&severity(&1, "trauma.thermal.burn"))

      assert degrees == [1, 1, 2, 2, 3]

      burnt = run(held(60.0), air(20.0 + @c), 5) |> then(&%{&1 | tissue_k: 34.0 + @c}) |> run(air(20.0 + @c), 60)

      # 只推进体温不走修复账：剂量不减、进度不动（愈合由 Body.Repair 推进，见 repair_test.exs）
      assert [%{tag: "trauma.thermal.burn", part: :contact, severity: 3, progression: :heals, heal: +0.0}] =
               Body.injuries(burnt)
    end

    test "组织块 44 °C 以下不累计烧伤；44 °C 需约 1.2 小时才一度" do
      assert run(held(43.9), air(20.0 + @c), 36_000).burn_dose_s == 0.0
      # 44 °C 剂量率 2^(−16/1.32) = 2.2446e-4 /s → 1 小时 0.808 < 1，1.5 小时 1.21 ≥ 1
      assert severity(run(held(44.0), air(20.0 + @c), 3600), "trauma.thermal.burn") == 0
      assert severity(run(held(44.0), air(20.0 + @c), 5400), "trauma.thermal.burn") == 1
    end

    test "组织块 −10 °C 每秒累计 9.45 K·s：31 秒 292.95 无冻伤、32 秒 302.4 浅冻伤；63 秒 595.35 仍浅、64 秒 604.8 深冻伤" do
      b31 = run(held(-10.0), air(20.0 + @c), 31)
      assert severity(b31, "trauma.thermal.frostbite") == 0
      {b32, _} = step!(b31, air(20.0 + @c))
      assert severity(b32, "trauma.thermal.frostbite") == 1
      b63 = run(held(-10.0), air(20.0 + @c), 63)
      assert severity(b63, "trauma.thermal.frostbite") == 1
      {b64, _} = step!(b63, air(20.0 + @c))
      assert severity(b64, "trauma.thermal.frostbite") == 2
    end

    test "组织块 −25 °C：冻伤剂量 24.45 K·s/s，24 秒 586.8 浅冻伤、25 秒 611.25 深冻伤" do
      cold = air(-25.0 + @c)
      b24 = run(%{Body.new() | tissue_k: -25.0 + @c}, cold, 24)
      assert_in_delta b24.frost_dose_k_s, 586.8, 1.0e-6
      assert severity(b24, "trauma.thermal.frostbite") == 1
      {b25, _} = step!(b24, cold)
      assert_in_delta b25.frost_dose_k_s, 611.25, 1.0e-6
      assert severity(b25, "trauma.thermal.frostbite") == 2
    end

    test "接触温度本身不进剂量：World 报 600 K 接触、但组织块只吸了 20.94 J（+0.1 K），不烧伤" do
      {b, _} = step!(Body.new(), %{q_j: 57.3, tissue_j: 20.94, air_k: 20.0 + @c})
      assert_in_delta b.tissue_k, 34.1 + @c, 1.0e-9
      assert b.burn_dose_s == 0.0
    end
  end

  describe "体温伤病、生命与濒死" do
    test "伤病与生命按核心温度阈值推导" do
      assert severity(%{Body.new() | core_k: 35.1 + @c}, "temperature.hypothermia") == 0
      assert severity(%{Body.new() | core_k: 34.9 + @c}, "temperature.hypothermia") == 1
      assert severity(%{Body.new() | core_k: 31.0 + @c}, "temperature.hypothermia") == 2
      assert severity(%{Body.new() | core_k: 40.5 + @c}, "temperature.hyperthermia") == 2

      # 30 °C：循环 (30−24)/8 = 0.75，神经 (30−28)/7 = 0.2857 → 合成（H2，p = 2）1 − √(0.25² + 0.7143²) = 0.2432 → 生命 24；
      # 体温调节 (30−28)/4 = 0.5
      at30 = %{Body.new() | core_k: 30.0 + @c}
      assert Body.life(at30) == 24
      assert_in_delta Body.systems(at30).thermoregulation, 0.5, 1.0e-9
    end

    test "持续失热使核心跌破 35 °C 的那一步出现体温过低" do
      chilled = %{uniform(35.05) | skin_k: 30.0 + @c, reserve_j: 0.0, fat_reserve_j: 0.0}
      loss = %{q_j: -1000.0, air_k: 20.0 + @c}

      crossed =
        Stream.iterate(chilled, fn b -> step!(b, loss) |> elem(0) end)
        |> Stream.take(20_000)
        |> Enum.find(fn b ->
          assert severity(b, "temperature.hypothermia") ==
                   if(b.core_k < 35.0 + @c, do: 1, else: 0)

          b.core_k < 35.0 + @c
        end)

      assert [%{tag: "temperature.hypothermia", part: :whole, severity: 1, progression: :tracks_core}] =
               Body.injuries(crossed)
    end

    test "核心 28 °C：神经功能 0 低于致命水平，10 秒后濒死，再 120 秒死亡" do
      body = %{uniform(28.0) | skin_k: 27.0 + @c}
      states = Enum.scan(1..130, body, fn _, b -> step!(b, air(20.0 + @c)) |> elem(0) end)

      assert Enum.map(Enum.take(states, 9), & &1.status) == List.duplicate(:alive, 9)
      assert Enum.at(states, 9).status == :dying
      assert Enum.at(states, 128).status == :dying
      assert Enum.at(states, 129).status == :dead
      assert Enum.all?(states, &(&1.core_k < 28.7 + @c))

      # 死亡为终态：即使回到调定点也不复活（复活由系统处理，§6.10）
      assert step!(%{List.last(states) | core_k: 36.8 + @c}, air(20.0 + @c))
             |> elem(0)
             |> Map.get(:status) ==
               :dead
    end

    test "濒死窗口内复温即被救回，计时清零" do
      dying = %{Body.new() | status: :dying, lethal_s: 50.0}
      {rescued, _} = step!(dying, air(20.0 + @c))
      assert rescued.status == :alive
      assert rescued.lethal_s == 0.0
    end

    test "回到 30 °C 温暖环境：体温过低逐步减轻至消失，烧伤不自愈只停止恶化" do
      body = %{uniform(34.0) | skin_k: 30.0 + @c, burn_dose_s: 3.0}
      states = Enum.scan(1..7200, body, fn _, b -> step!(b, air(30.0 + @c)) |> elem(0) end)

      hypo = Enum.map([body | states], &severity(&1, "temperature.hypothermia"))
      assert hd(hypo) == 1
      assert List.last(hypo) == 0
      assert hypo == Enum.sort(hypo, :desc)
      assert Enum.all?(states, &(severity(&1, "trauma.thermal.burn") == 2))
    end
  end

  # 寒战燃料：糖原 450 g × 17 kJ/g = 7.65 MJ；脂肪 11.16 kg × 9 kcal/g × 4186.8 J/kcal = 420 522 192 J（Stolwijk 标准人 74.4 kg 的 15%）。
  # 糖原付寒战热的 27%（Blondin 2010），不够时脂肪补足、总寒战不变（Haman 2004），脂肪不够时糖原补足，两者都空才无寒战。
  # 峰值寒战 232.8 × 1.8877 = 439.45656 W：糖原 0.27 × 439.45656 = 118.6532712 J，脂肪 320.8032888 J。
  describe "寒战储备（糖原 + 脂肪）" do
    @full 7_650_000.0
    @fat 420_522_192.0

    test "满储备：寒战 439.45656 W，糖原付 27% = 118.6532712 J、脂肪付 320.8032888 J，两储备各减同值" do
      colder = %{Body.new() | core_k: 33.0 + @c, skin_k: 18.0 + @c}
      assert colder.reserve_j == @full
      assert_in_delta colder.fat_reserve_j, @fat, 1.0e-3

      {next, account} = step!(colder, air(0.0 + @c))
      assert_in_delta account.shiver_j, 439.45656, 1.0e-6
      assert_in_delta account.metabolic_j, @met + 439.45656, 1.0e-6
      assert_in_delta account.shiver_glycogen_j, 118.6532712, 1.0e-6
      assert_in_delta account.shiver_fat_j, 320.8032888, 1.0e-6
      assert_in_delta next.reserve_j, @full - 118.6532712, 1.0e-6
      assert_in_delta next.fat_reserve_j, colder.fat_reserve_j - 320.8032888, 1.0e-6
    end

    test "糖原低或耗尽时总寒战不变（Haman 2004）：半糖原仍 439.45656 W；剩 50 J 时糖原付 50、脂肪付 389.45656；糖原空时脂肪全付" do
      colder = %{Body.new() | core_k: 33.0 + @c, skin_k: 18.0 + @c}

      {_, account} = step!(%{colder | reserve_j: @full / 2}, air(0.0 + @c))
      assert_in_delta account.shiver_j, 439.45656, 1.0e-6
      assert_in_delta account.shiver_glycogen_j, 118.6532712, 1.0e-6

      {low, account} = step!(%{colder | reserve_j: 50.0}, air(0.0 + @c))
      assert_in_delta account.shiver_glycogen_j, 50.0, 1.0e-9
      assert_in_delta account.shiver_fat_j, 389.45656, 1.0e-6
      assert low.reserve_j == 0.0

      {empty, account} = step!(%{colder | reserve_j: 0.0}, air(0.0 + @c))
      assert_in_delta account.shiver_j, 439.45656, 1.0e-6
      assert account.shiver_glycogen_j == 0.0
      assert_in_delta account.shiver_fat_j, 439.45656, 1.0e-6
      assert empty.reserve_j == 0.0
    end

    test "脂肪剩 100 J 时糖原补足 339.45656 J；两储备都空无寒战；两者合计剩 200 J 时寒战只有 200 J" do
      colder = %{Body.new() | core_k: 33.0 + @c, skin_k: 18.0 + @c}

      {lean, account} = step!(%{colder | fat_reserve_j: 100.0}, air(0.0 + @c))
      assert_in_delta account.shiver_j, 439.45656, 1.0e-6
      assert_in_delta account.shiver_fat_j, 100.0, 1.0e-9
      assert_in_delta account.shiver_glycogen_j, 339.45656, 1.0e-6
      assert_in_delta lean.fat_reserve_j, 0.0, 1.0e-9

      {none, account} = step!(%{colder | reserve_j: 0.0, fat_reserve_j: 0.0}, air(0.0 + @c))
      assert account.shiver_j == 0.0
      assert_in_delta account.metabolic_j, @met, 1.0e-9
      assert none.reserve_j == 0.0 and none.fat_reserve_j == 0.0

      {last, account} = step!(%{colder | reserve_j: 150.0, fat_reserve_j: 50.0}, air(0.0 + @c))
      assert_in_delta account.shiver_j, 200.0, 1.0e-9
      # 糖原 max(0.27 × 200, 200 − 50) = 150，脂肪 50：两者同时归零
      assert_in_delta account.shiver_glycogen_j, 150.0, 1.0e-9
      assert last.reserve_j == 0.0 and last.fat_reserve_j == 0.0
    end

    test "−25 °C、5 m/s：两储备都空时无寒战、核心 1 小时内跌破 35 °C；只糖原空时与满储备逐步相同（寒战改由脂肪付）" do
      windy = Map.put(air(-25.0 + @c), :wind_mps, 5.0)
      assert run(%{Body.new() | reserve_j: 0.0, fat_reserve_j: 0.0}, windy, 3600).core_k < 35.0 + @c

      full = run(Body.new(), windy, 3600)
      glycogen_empty = run(%{Body.new() | reserve_j: 0.0}, windy, 3600)
      assert full.core_k > 35.0 + @c
      assert glycogen_empty.core_k == full.core_k
      assert glycogen_empty.fat_reserve_j < full.fat_reserve_j
    end
  end

  # 湿衣：空气中非蒸发保温损失 16%（Bröde et al. 2008）；蒸发在衣面，衣面温度 T_面 解
  #   (T_皮 − T_面)/R_衣 = (T_面 − T_空)/R_空 + E(T_面)，E = 16.5·h_c·(p_s(T_面) − 0.5·p_s(T_空))·湿度（Lewis 关系、Magnus 式）。
  describe "湿衣" do
    defp magnus(k), do: 0.61094 * :math.exp(17.625 * (k - @c) / (k - @c + 243.04))

    test "干衣不蒸发；湿透衣物空气中热阻 0.155 × 0.84，衣面热平衡成立：经衣物导出的热 = 对流辐射 + 蒸发" do
      windy = Map.put(air(-25.0 + @c), :wind_mps, 5.0)
      {_, dry} = step!(Body.new(), windy)
      assert dry.drying_j == 0.0

      wet = %{Body.new() | wetness: 1.0}
      {next, account} = step!(wet, windy)
      h_c = 8.3 * :math.pow(5.0, 0.6)
      r_air = 1 / (h_c + 4.7)
      r_cloth = 0.155 * 0.84
      # 由对流辐射反推衣面温度，再核对两个独立关系：衣物导热平衡、Lewis 蒸发式
      t_s = -25.0 + @c + account.convection_j / 1.8877 * r_air
      assert_in_delta (wet.skin_k - t_s) / r_cloth * 1.8877, account.convection_j + account.drying_j, 1.0e-6
      assert_in_delta account.drying_j, 16.5 * h_c * (magnus(t_s) - 0.5 * magnus(-25.0 + @c)) * 1.8877, 1.0e-6
      # 衣面介于空气与皮肤之间；湿度按蒸发掉的水下降（1 kg、2430 J/g）
      assert t_s > -25.0 + @c and t_s < wet.skin_k
      assert_in_delta next.wetness, 1.0 - account.drying_j / 2.43e6, 1.0e-12
      # 衣面被蒸发冷却：比无蒸发的干热回路分压低
      assert t_s < -25.0 + @c + 59.0 * r_air / (r_cloth + r_air)
    end

    test "浸水：全身浸没时湿度按 20 s 时间常数趋于湿透（1 − e^(−n/20)），水下不蒸发；只浸一半湿到略低于 0.5" do
      water = %{q_j: 0.0, air_k: 20.0 + @c, immersed: 1.0}
      states = Enum.scan(1..20, Body.new(), fn _, b -> step!(b, water) |> elem(0) end)
      assert_in_delta hd(states).wetness, 0.048770575, 1.0e-9
      assert_in_delta List.last(states).wetness, 0.632120559, 1.0e-9
      half = run(Body.new(), %{water | immersed: 0.5}, 600)
      assert half.wetness < 0.5 and half.wetness > 0.49
    end

    test "湿透出水到 20 °C 静止空气：湿度只降，蒸发取走的热使皮肤比干衣时低" do
      wet = %{Body.new() | wetness: 1.0}
      out = Enum.scan(1..3600, wet, fn _, b -> step!(b, air(20.0 + @c)) |> elem(0) end)
      assert Enum.chunk_every([wet | out], 2, 1, :discard) |> Enum.all?(fn [a, b] -> b.wetness <= a.wetness end)
      assert List.last(out).wetness < 1.0
      assert List.last(out).skin_k < run(Body.new(), air(20.0 + @c), 3600).skin_k
    end
  end
end
