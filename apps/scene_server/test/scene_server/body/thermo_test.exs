defmodule SceneServer.Body.ThermoTest do
  @moduledoc """
  身体 L1 体温模型单测。期望值均为手算：

  - 热容：皮肤 0.1×70×3490 = 24430 J/K，核心 0.9×70×3490 = 219870 J/K；
  - 静息代谢 58.2×1.8 = 104.76 W；
  - 干热交换系数 1.8 / (0.155 + 1/(3.1+4.7)) = 1.8 / 0.28320513 = 6.3558170 W/K；
  - 调定点皮肤血流 6.3 L/(m²·h) 时核心-皮肤导热 (5.28 + 1.163×6.3)×1.8 = 22.69242 W/K。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Thermo

  @c 273.15
  @skin_c 24_430.0
  @core_c 219_870.0

  defp air(k), do: %{q_j: 0.0, max_contact_k: k, air_k: k}

  # 推进一步并核对能量账：储热变化 = 两节点热容 × 温升 = q + 代谢 − 干热散失 − 出汗；寒战热 = 储备减少量。
  defp step!(body, inputs, dt \\ 1.0) do
    {next, account} = Thermo.step(body, dt, inputs)
    stored = @skin_c * (next.skin_k - body.skin_k) + @core_c * (next.core_k - body.core_k)
    assert_in_delta account.stored_j, stored, 1.0e-6
    assert_in_delta account.shiver_j, body.reserve_j - next.reserve_j, 1.0e-6

    assert_in_delta account.stored_j,
                    account.q_j + account.metabolic_j - account.convection_j - account.sweat_j,
                    1.0e-9

    {next, account}
  end

  defp run(body, inputs, steps),
    do: Enum.reduce(1..steps, body, fn _, b -> step!(b, inputs) |> elem(0) end)

  defp severity(body, tag) do
    case Enum.find(Body.injuries(body), &(&1.tag == tag)) do
      nil -> 0
      injury -> injury.severity
    end
  end

  describe "能量账与单步手算" do
    test "调定点身体、20 °C 空气、接触吸热 1000 J 的一步" do
      {next, account} =
        step!(Body.new(), %{q_j: 1000.0, max_contact_k: 30.0 + @c, air_k: 20.0 + @c})

      # 核心→皮肤 22.69242×2.8 = 63.538776 W；干热 6.3558170×14 = 88.981438 W
      assert_in_delta account.metabolic_j, 104.76, 1.0e-9
      assert_in_delta account.convection_j, 88.981438, 1.0e-5
      assert account.sweat_j == 0.0
      assert_in_delta account.stored_j, 1000 + 104.76 - 88.981438, 1.0e-5
      # 核心 +(104.76 − 63.538776)/219870；皮肤 +(1000 + 63.538776 − 88.981438)/24430
      assert_in_delta next.core_k, 36.8 + @c + 41.221224 / 219_870, 1.0e-9
      assert_in_delta next.skin_k, 34.0 + @c + 974.557338 / 24_430, 1.0e-7
    end

    test "寒战产热按 19.4×冷皮肤×冷核心 计入代谢，并在 5 met 峰值处封顶" do
      cold = %{Body.new() | core_k: 36.0 + @c, skin_k: 30.0 + @c}
      {_, account} = step!(cold, air(0.0 + @c))
      # 19.4 × 4 × 0.8 × 1.8 = 111.744 W
      assert_in_delta account.metabolic_j, 104.76 + 111.744, 1.0e-9

      colder = %{Body.new() | core_k: 34.0 + @c, skin_k: 20.0 + @c}
      {_, account} = step!(colder, air(0.0 + @c))
      # 19.4 × 14 × 2.8 = 760.48 W/m² > 232.8 峰值 → 232.8 × 1.8 = 419.04 W
      assert_in_delta account.metabolic_j, 104.76 + 419.04, 1.0e-9
    end
  end

  describe "环境" do
    test "20 °C 空气（世界全局环境温度）下调定点身体 4 小时保持约 37 °C 稳态" do
      body = run(Body.new(), air(20.0 + @c), 4 * 3600)
      later = run(body, air(20.0 + @c), 600)

      assert later.core_k - @c > 36.8 and later.core_k - @c < 37.0
      assert abs(later.core_k - body.core_k) < 0.005
      assert Body.injuries(later) == []
      assert Body.life(later) == 100
      assert later.status == :alive
    end

    test "0 °C 空气无接触：皮肤先降、核心随后按手算速率下降，寒战提高产热" do
      {first, _} = step!(Body.new(), air(0.0 + @c))
      # 皮肤 (63.538776 − 6.3558170×34)/24430 = −152.559003/24430 K/s
      assert_in_delta first.skin_k - (34.0 + @c), -152.559003 / 24_430, 1.0e-9

      # 皮肤已降到 26 °C、核心仍在调定点：血流 6.3/(1+0.5×8) = 1.26，
      # 核心→皮肤 (5.28 + 1.163×1.26)×1.8×10.8 = 131.130187 W > 代谢 104.76 W，寒战 0（核心未低于调定点）
      cooled = %{Body.new() | skin_k: 26.0 + @c}
      {next, account} = step!(cooled, air(0.0 + @c))
      assert_in_delta next.core_k - cooled.core_k, (104.76 - 131.130187) / 219_870, 1.0e-10
      assert_in_delta account.metabolic_j, 104.76, 1.0e-9

      hour = run(Body.new(), air(0.0 + @c), 3600)
      assert hour.core_k < 36.8 + @c
      {_, account} = step!(hour, air(0.0 + @c))
      assert account.metabolic_j > 104.76
    end
  end

  describe "烧伤与冻伤" do
    test "60 °C 接触每秒累计 1 个剂量单位：1、3、5 秒依次出现 1、2、3 度，只增不减" do
      hot = %{q_j: 0.0, max_contact_k: 60.0 + @c, air_k: 20.0 + @c}

      degrees =
        Enum.scan(1..5, Body.new(), fn _, b -> step!(b, hot) |> elem(0) end)
        |> Enum.map(&severity(&1, "trauma.thermal.burn"))

      assert degrees == [1, 1, 2, 2, 3]

      burnt = run(Body.new(), hot, 5) |> run(air(20.0 + @c), 60)

      assert [%{tag: "trauma.thermal.burn", part: :contact, severity: 3, progression: :permanent}] =
               Body.injuries(burnt)
    end

    test "600 K 宏格接触 1 秒即三度烧伤，持续接触后保持三度" do
      fire = %{q_j: 5000.0, max_contact_k: 600.0, air_k: 20.0 + @c}
      {one, _} = step!(Body.new(), fire)
      assert severity(one, "trauma.thermal.burn") == 3
      assert severity(run(one, fire, 5), "trauma.thermal.burn") == 3
    end

    test "44 °C 以下接触不累计烧伤；44 °C 需约 1.2 小时才一度" do
      warm = run(Body.new(), %{q_j: 0.0, max_contact_k: 43.9 + @c, air_k: 20.0 + @c}, 36_000)
      assert warm.burn_dose_s == 0.0

      # 44 °C 剂量率 2^(−16/1.32) = 2.2446e-4 /s → 1 小时 0.808 < 1，1.5 小时 1.21 ≥ 1
      at44 = %{q_j: 0.0, max_contact_k: 44.0 + @c, air_k: 20.0 + @c}
      assert severity(run(Body.new(), at44, 3600), "trauma.thermal.burn") == 0
      assert severity(run(Body.new(), at44, 5400), "trauma.thermal.burn") == 1
    end

    test "−10 °C 接触每秒累计 9.45 K·s：63 秒 595.35 未冻伤，64 秒 604.8 冻伤" do
      ice = %{q_j: 0.0, max_contact_k: -10.0 + @c, air_k: 20.0 + @c}
      b63 = run(Body.new(), ice, 63)
      assert severity(b63, "trauma.thermal.frostbite") == 0
      {b64, _} = step!(b63, ice)
      assert severity(b64, "trauma.thermal.frostbite") == 1
    end
  end

  describe "体温伤病、生命与濒死" do
    test "伤病与生命按核心温度阈值推导" do
      assert severity(%{Body.new() | core_k: 35.1 + @c}, "temperature.hypothermia") == 0
      assert severity(%{Body.new() | core_k: 34.9 + @c}, "temperature.hypothermia") == 1
      assert severity(%{Body.new() | core_k: 31.0 + @c}, "temperature.hypothermia") == 2
      assert severity(%{Body.new() | core_k: 40.5 + @c}, "temperature.hyperthermia") == 2

      # 30 °C：循环 (30−24)/8 = 0.75，神经 (30−28)/7 = 0.2857 → 生命 29；体温调节 (30−28)/4 = 0.5
      at30 = %{Body.new() | core_k: 30.0 + @c}
      assert Body.life(at30) == 29
      assert_in_delta Body.systems(at30).thermoregulation, 0.5, 1.0e-9
    end

    test "持续失热使核心跌破 35 °C 的那一步出现体温过低" do
      chilled = %{Body.new() | core_k: 35.05 + @c, skin_k: 30.0 + @c}
      loss = %{q_j: -1000.0, max_contact_k: 20.0 + @c, air_k: 20.0 + @c}

      crossed =
        Stream.iterate(chilled, fn b -> step!(b, loss) |> elem(0) end)
        |> Stream.take(20_000)
        |> Enum.find(fn b ->
          assert severity(b, "temperature.hypothermia") ==
                   if(b.core_k < 35.0 + @c, do: 1, else: 0)

          b.core_k < 35.0 + @c
        end)

      assert [
               %{
                 tag: "temperature.hypothermia",
                 part: :whole,
                 severity: 1,
                 progression: :tracks_core
               }
             ] =
               Body.injuries(crossed)
    end

    test "核心 28 °C：神经功能 0 低于致命水平，10 秒后濒死，再 120 秒死亡" do
      body = %{Body.new() | core_k: 28.0 + @c, skin_k: 27.0 + @c}
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
      body = %{Body.new() | core_k: 34.0 + @c, skin_k: 30.0 + @c, burn_dose_s: 3.0}
      states = Enum.scan(1..3600, body, fn _, b -> step!(b, air(30.0 + @c)) |> elem(0) end)

      hypo = Enum.map([body | states], &severity(&1, "temperature.hypothermia"))
      assert hd(hypo) == 1
      assert List.last(hypo) == 0
      assert hypo == Enum.sort(hypo, :desc)
      assert Enum.all?(states, &(severity(&1, "trauma.thermal.burn") == 2))
    end
  end

  describe "寒战储备（糖原 450 g × 17 kJ/g = 7.65 MJ）" do
    @full 7_650_000.0

    test "寒战热全部取自储备：满储备 5 met 封顶 419.04 W、储备减同值；半储备上限减半 209.52 W；空储备无寒战" do
      colder = %{Body.new() | core_k: 34.0 + @c, skin_k: 20.0 + @c}
      assert colder.reserve_j == @full

      {full, account} = step!(colder, air(0.0 + @c))
      # 需求 19.4 × 14 × 2.8 = 760.48 W/m² > 上限 232.8 → 232.8 × 1.8 = 419.04 W
      assert_in_delta account.shiver_j, 419.04, 1.0e-9
      assert_in_delta account.metabolic_j, 104.76 + 419.04, 1.0e-9
      assert_in_delta full.reserve_j, @full - 419.04, 1.0e-6

      # 半储备：上限 232.8 × 0.5 = 116.4 W/m² → 209.52 W
      {_, account} = step!(%{colder | reserve_j: @full / 2}, air(0.0 + @c))
      assert_in_delta account.shiver_j, 209.52, 1.0e-9

      {empty, account} = step!(%{colder | reserve_j: 0.0}, air(0.0 + @c))
      assert account.shiver_j == 0.0
      assert_in_delta account.metabolic_j, 104.76, 1.0e-9
      assert empty.reserve_j == 0.0
    end

    test "不寒战就不耗储备：20 °C 空气 4 小时后储备仍为满值（储备不随时间自然下降）" do
      assert run(Body.new(), air(20.0 + @c), 4 * 3600).reserve_j == @full
    end

    # 手算不动点（静止空气、1 clo、体温调节水平 1）：给皮肤温度 Ts（°C），
    #   干热散失 L = 6.3558170·(Ts − Ta)，寒战 S = L − 104.76，
    #   核心-皮肤 G = (5.28 + 1.163·6.3/(1 + 0.5·(34 − Ts)))·1.8，Tc = Ts + L/G，
    #   寒战需求 19.4·1.8·(34 − Ts)·(36.8 − Tc) 必须等于 S —— 二分求 Ts，得稳态寒战功率 P*。
    # 储备按 P* 线性下降，直到上限 419.04·R/R_full 低于 P*（拐点 R* = R_full·P*/419.04），之后寒战跟不上、核心下降。
    defp steady_shiver(ta, dry \\ 6.3558170) do
      f = fn ts ->
        l = dry * (ts - ta)
        g = (5.28 + 1.163 * 6.3 / (1 + 0.5 * (34 - ts))) * 1.8
        tc = ts + l / g
        {19.4 * 1.8 * (34 - ts) * (36.8 - tc) - (l - 104.76), l - 104.76, tc}
      end

      {ts, _} =
        Enum.reduce(1..60, {0.0, 30.0}, fn _, {lo, hi} ->
          mid = (lo + hi) / 2
          if elem(f.(mid), 0) > 0, do: {mid, hi}, else: {lo, mid}
        end)

      {_, p, tc} = f.(ts)
      {ts, tc, p}
    end

    test "−25 °C 静止空气、1 clo：储备按手算稳态寒战功率下降，越过拐点后才失温；每步寒战热 = 储备减少" do
      {ts, tc, p} = steady_shiver(-25.0)
      # 手算：Ts ≈ 13.62 °C、Tc ≈ 36.60 °C、P* ≈ 140.7 W；拐点 R* = 7.65 MJ × 140.7/419.04 ≈ 2.57 MJ
      assert_in_delta ts, 13.62, 0.01
      assert_in_delta tc, 36.60, 0.01
      assert_in_delta p, 140.7, 0.1
      knee = @full * p / 419.04

      cold = air(-25.0 + @c)
      states = Enum.scan(1..(24 * 3600), Body.new(), fn _, b -> step!(b, cold) |> elem(0) end)
      at = fn s -> Enum.at(states, s - 1) end

      assert_in_delta (at.(7200).reserve_j - at.(28_800).reserve_j) / 21_600, p, p * 0.01
      assert Enum.all?(states, &(&1.reserve_j < 1.05 * knee or &1.core_k >= 36.5 + @c))

      hypo = Enum.find_index(states, &(&1.core_k < 35.0 + @c))
      assert hypo != nil
      assert at.(hypo + 1).reserve_j < knee
    end

    test "裸接触 −25 °C（如手按冰，不经鞋底）：冻伤剂量 24.45 K·s/s，24 秒 586.8 未冻伤、25 秒 611.25 冻伤" do
      cold = air(-25.0 + @c)
      b24 = run(Body.new(), cold, 24)
      assert_in_delta b24.frost_dose_k_s, 586.8, 1.0e-6
      assert severity(b24, "trauma.thermal.frostbite") == 0
      {b25, _} = step!(b24, cold)
      assert_in_delta b25.frost_dose_k_s, 611.25, 1.0e-6
      assert severity(b25, "trauma.thermal.frostbite") == 1
    end
  end

  # 风（气候区 wind_mps）：对流系数 h_c = max(3.1, 8.3·v^0.6)（Gagge / ASHRAE）。
  #   v = 5：5^0.6 = 2.6265278 → h_c = 21.800181；干热系数 1.8/(0.155 + 1/(21.800181 + 4.7)) = 9.3392195 W/K，
  #   是静止空气 6.3558170 的 1.4694 倍。v = 1：h_c = 8.3 → 1.8/(0.155 + 1/13) = 7.7611940 W/K。
  #   v = 0.1：8.3·0.1^0.6 = 2.0849 < 3.1 → 取下限 3.1，与静止空气相同。
  describe "风（气候区 wind_mps）" do
    test "风速 0、缺省、低于自然对流下限（0.1 m/s）：一步结果与不传风速逐位相同" do
      body = %{Body.new() | skin_k: 25.0 + @c, core_k: 36.2 + @c}
      still = Thermo.step(body, 1.0, air(-25.0 + @c))

      for v <- [0.0, 0, 0.1],
          do: assert(Thermo.step(body, 1.0, Map.put(air(-25.0 + @c), :wind_mps, v)) == still)
    end

    test "5 m/s、−25 °C 空气、调定点身体一步：干热散失 9.3392195 × 59 = 551.01395 W；1 m/s、0 °C：7.7611940 × 34 = 263.88060 W" do
      {_, account} = step!(Body.new(), Map.put(air(-25.0 + @c), :wind_mps, 5.0))
      assert_in_delta account.convection_j, 551.01395, 1.0e-4
      {_, account} = step!(Body.new(), Map.put(air(0.0 + @c), :wind_mps, 1.0))
      assert_in_delta account.convection_j, 263.88060, 1.0e-4
    end

    # 同静止空气那条的手算不动点，只把干热系数换成 5 m/s 的 9.3392195：Ts ≈ 7.49 °C、Tc ≈ 36.59 °C、P* ≈ 198.7 W；
    # 拐点 R* = 7.65 MJ × 198.7/419.04 ≈ 3.63 MJ，按 P* 耗到拐点约 5.6 h——失温不可能早于此（静止空气拐点约 10 h）。
    test "−25 °C、5 m/s、1 clo：稳态寒战 P* ≈ 198.7 W（手算）、储备按 P* 线性下降，拐点前核心不低于 36.5 °C，越过拐点后失温" do
      {ts, tc, p} = steady_shiver(-25.0, 9.3392195)
      assert_in_delta ts, 7.49, 0.01
      assert_in_delta tc, 36.59, 0.01
      assert_in_delta p, 198.7, 0.1
      knee = @full * p / 419.04

      windy = Map.put(air(-25.0 + @c), :wind_mps, 5.0)
      states = Enum.scan(1..(12 * 3600), Body.new(), fn _, b -> step!(b, windy) |> elem(0) end)
      at = fn s -> Enum.at(states, s - 1) end

      assert_in_delta (at.(7200).reserve_j - at.(18_000).reserve_j) / 10_800, p, p * 0.01
      assert Enum.all?(states, &(&1.reserve_j < 1.05 * knee or &1.core_k >= 36.5 + @c))

      hypo = Enum.find_index(states, &(&1.core_k < 35.0 + @c))
      assert hypo != nil and hypo + 1 > 5.6 * 3600
      assert at.(hypo + 1).reserve_j < knee
    end
  end

  # 鞋底（冬靴 R_鞋 0.15 m²·K/W，VoxelRegion.BodyContact）：脚底组织温度 = 核心 ↔ 地面经 1/K_cs 与 R_鞋 的稳态分压，
  #   T_脚 = T_地 + (T_核 − T_地)·R_鞋/(1/K_cs + R_鞋)，K_cs = 5.28 + 1.163·皮肤血流。
  #   调定点身体：血流 6.3 → K_cs = 12.6069；站 −25 °C 冰：T_脚 = 248.15 + 61.8·0.15/(0.0793216 + 0.15) = 288.57357 K（15.4 °C）。
  #   皮肤 20 °C（冷皮肤 14 K）：血流 6.3/8 → K_cs = 6.1958625；−40 °C 冰 T_脚 = 270.14445 K → 冻伤剂量率 272.6 − 270.14445 = 2.45555；
  #   −25 °C 冰 T_脚 = 277.91897 K，不累计。血流最低时 K_cs → 5.28：−25 °C 冰上只有核心 < 30.32 °C 才可能冻脚。
  describe "鞋底隔热" do
    defp on_ice(k), do: %{q_j: 0.0, max_contact_k: nil, sole_k: k, air_k: k}

    test "调定点身体站 −25 °C 冰一步：T_脚 = 288.574 K，不累计冻伤；同温裸接触则累计 24.45 K·s" do
      {shod, _} = step!(Body.new(), on_ice(-25.0 + @c))
      assert shod.frost_dose_k_s == 0.0
      {bare, _} = step!(Body.new(), air(-25.0 + @c))
      assert_in_delta bare.frost_dose_k_s, 24.45, 1.0e-9
    end

    test "皮肤 20 °C 的身体：−40 °C 冰剂量率 2.45555 K·s/s，−25 °C 冰为 0；裸接触与鞋底同时存在取较高温度" do
      cold = %{Body.new() | skin_k: 20.0 + @c}
      {b, _} = step!(cold, on_ice(-40.0 + @c))
      assert_in_delta b.frost_dose_k_s, 272.6 - 270.14445, 1.0e-4
      {b, _} = step!(cold, on_ice(-25.0 + @c))
      assert b.frost_dose_k_s == 0.0
      # 鞋底在 −40 °C 冰上（T_脚 270.14 K）+ 裸接触 0 °C 水：剂量温度取 273.15 K，高于冻伤阈值 272.6 K
      {b, _} = step!(cold, %{on_ice(-40.0 + @c) | max_contact_k: 273.15})
      assert b.frost_dose_k_s == 0.0
    end

    test "−25 °C、5 m/s 站区温冰（Scene 无鞋底接触时 sole_k = 区温）1 小时：不冻伤；对照裸接触 25 秒冻伤" do
      windy = Map.put(on_ice(-25.0 + @c), :wind_mps, 5.0)
      hour = run(Body.new(), windy, 3600)
      assert hour.frost_dose_k_s == 0.0
      assert hour.core_k > 36.5 + @c
      assert severity(run(Body.new(), Map.put(air(-25.0 + @c), :wind_mps, 5.0), 25), "trauma.thermal.frostbite") == 1
    end
  end
end
