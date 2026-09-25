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

  @tissue_c 209.4

  defp air(k), do: %{q_j: 0.0, air_k: k}

  # 推进一步并核对能量账：储热变化 = 三节点热容 × 温升 = q + 代谢 − 干热散失 − 出汗 − 湿衣蒸发；寒战热 = 储备减少量；
  # 组织块只随 tissue_j 变化。
  defp step!(body, inputs, dt \\ 1.0) do
    {next, account} = Thermo.step(body, dt, inputs)
    stored = @skin_c * (next.skin_k - body.skin_k) + @core_c * (next.core_k - body.core_k) +
      @tissue_c * (next.tissue_k - body.tissue_k)
    assert_in_delta account.stored_j, stored, 1.0e-6
    assert_in_delta account.shiver_j, body.reserve_j - next.reserve_j, 1.0e-6
    assert_in_delta @tissue_c * (next.tissue_k - body.tissue_k), Map.get(inputs, :tissue_j, 0.0), 1.0e-9

    assert_in_delta account.stored_j,
                    account.q_j + account.metabolic_j - account.convection_j - account.sweat_j - account.drying_j,
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
        step!(Body.new(), %{q_j: 1000.0, air_k: 20.0 + @c})

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

  # 剂量读局部接触组织块温度：Scene 里它只随 World 回传的 tissue_j 变化，这里给定组织块温度、tissue_j = 0 即保持该温度。
  describe "烧伤与冻伤（组织块温度）" do
    defp held(tissue_c), do: %{Body.new() | tissue_k: tissue_c + @c}

    test "World 回传的 tissue_j 按组织块热容改变其温度，差额进皮肤：tissue_j = 2094 J → 组织块 +10 K" do
      {next, account} = step!(Body.new(), %{q_j: 3000.0, tissue_j: 2094.0, air_k: 20.0 + @c})
      assert_in_delta next.tissue_k, 44.0 + @c, 1.0e-9
      # 皮肤得 3000 − 2094 = 906 J，其余同“调定点、20 °C 空气”一步：+(906 + 63.538776 − 88.981438)/24430
      assert_in_delta next.skin_k, 34.0 + @c + 880.557338 / 24_430, 1.0e-7
      assert account.tissue_j == 2094.0
    end

    test "组织块 60 °C 每秒累计 1 个剂量单位：1、3、5 秒依次出现 1、2、3 度，只增不减" do
      degrees =
        Enum.scan(1..5, held(60.0), fn _, b -> step!(b, air(20.0 + @c)) |> elem(0) end)
        |> Enum.map(&severity(&1, "trauma.thermal.burn"))

      assert degrees == [1, 1, 2, 2, 3]

      burnt = run(held(60.0), air(20.0 + @c), 5) |> then(&%{&1 | tissue_k: 34.0 + @c}) |> run(air(20.0 + @c), 60)

      assert [%{tag: "trauma.thermal.burn", part: :contact, severity: 3, progression: :permanent}] =
               Body.injuries(burnt)
    end

    test "组织块 44 °C 以下不累计烧伤；44 °C 需约 1.2 小时才一度" do
      assert run(held(43.9), air(20.0 + @c), 36_000).burn_dose_s == 0.0
      # 44 °C 剂量率 2^(−16/1.32) = 2.2446e-4 /s → 1 小时 0.808 < 1，1.5 小时 1.21 ≥ 1
      assert severity(run(held(44.0), air(20.0 + @c), 3600), "trauma.thermal.burn") == 0
      assert severity(run(held(44.0), air(20.0 + @c), 5400), "trauma.thermal.burn") == 1
    end

    test "组织块 −10 °C 每秒累计 9.45 K·s：63 秒 595.35 未冻伤，64 秒 604.8 冻伤" do
      b63 = run(held(-10.0), air(20.0 + @c), 63)
      assert severity(b63, "trauma.thermal.frostbite") == 0
      {b64, _} = step!(b63, air(20.0 + @c))
      assert severity(b64, "trauma.thermal.frostbite") == 1
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

    test "组织块 −25 °C（如手按冰已冷透）：冻伤剂量 24.45 K·s/s，24 秒 586.8 未冻伤、25 秒 611.25 冻伤" do
      cold = air(-25.0 + @c)
      b24 = run(%{Body.new() | tissue_k: -25.0 + @c}, cold, 24)
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

  # 湿衣（Body 参数表的依据见 body/README.md）。−25 °C、5 m/s：h_c = 21.800181，空气热阻 1/(21.800181 + 4.7) = 0.03773559；
  #   湿透衣物热阻 0.03（BodyContact 湿衣热阻）→ 干热 1.8 × 59 / 0.06773559 = 1567.8611 W（干衣 551.01395 W 的 2.85 倍）；
  #   衣面温度 248.15 + 59 × 0.03773559/0.06773559 = 281.01898 K（7.869 °C），Magnus 饱和水汽压 1.0618333 kPa，
  #   空气 0.5 × 0.0809761 kPa → 蒸发 16.5 × 21.800181 × (1.0618333 − 0.0404880) × 1.8 = 661.28565 W，
  #   含水 1 kg、潜热 2430 J/g → 湿度每秒降 661.28565 / 2 430 000 = 2.72134e-4。
  describe "湿衣" do
    test "干衣逐位不变：湿度 0 时干热与不引入湿衣前相同，不蒸发" do
      {_, account} = step!(Body.new(), Map.put(air(-25.0 + @c), :wind_mps, 5.0))
      assert_in_delta account.convection_j, 551.01395, 1.0e-4
      assert account.drying_j == 0.0
    end

    test "湿透一步（−25 °C、5 m/s）：干热 1567.8611 W、蒸发 661.28565 W 由皮肤付，湿度降 2.72134e-4" do
      wet = %{Body.new() | wetness: 1.0}
      {next, account} = step!(wet, Map.put(air(-25.0 + @c), :wind_mps, 5.0))
      assert_in_delta account.convection_j, 1567.8611, 1.0e-3
      assert_in_delta account.drying_j, 661.28565, 1.0e-3
      assert_in_delta next.wetness, 1.0 - 2.72134e-4, 1.0e-8
    end

    test "浸水：全身浸没时湿度按 20 s 时间常数趋于湿透（1 − e^(−n/20)），水下不蒸发；只浸一半湿到略低于 0.5" do
      water = %{q_j: 0.0, air_k: 20.0 + @c, immersed: 1.0}
      states = Enum.scan(1..20, Body.new(), fn _, b -> step!(b, water) |> elem(0) end)
      assert_in_delta hd(states).wetness, 0.048770575, 1.0e-9
      assert_in_delta List.last(states).wetness, 0.632120559, 1.0e-9
      # 半身浸没：浸水拉向 0.5，露出的一半同时蒸发（20 °C 约 1e-4 /s 量级），平衡点略低于 0.5。
      half = run(Body.new(), %{water | immersed: 0.5}, 600)
      assert half.wetness < 0.5 and half.wetness > 0.49
    end

    # 失温时长（数字由逐秒推进得出，打印供报告；断言只卡相对关系）：同一 −25 °C、5 m/s、1 clo、满储备，
    # 干衣 8.7 h（见“风”一节），湿透衣物明显更早。组织块无接触时由 World 经内部边拉向皮肤：这里用两节点里组织块一侧的
    # 解析松弛（皮肤段内视为常数）扮演 World，tissue_j = C_t·(T_皮 − T_组织)·(1 − e^(−G_i/C_t))，G_i = 0.03·K_cs。
    test "−25 °C、5 m/s 湿透衣物：核心 < 35 °C 早于干衣（干衣 6 小时内不失温）；湿度随蒸发下降；皮肤冻到冰点以下时组织块随之冻伤" do
      windy = Map.put(air(-25.0 + @c), :wind_mps, 5.0)
      relax = fn b ->
        g = Body.params().contact_tissue_m2 * Thermo.core_to_skin_w_per_m2_k(b)
        Map.put(windy, :tissue_j, @tissue_c * (b.skin_k - b.tissue_k) * (1 - :math.exp(-g / @tissue_c)))
      end
      crossing = fn start ->
        Enum.reduce_while(1..(6 * 3600), {start, nil}, fn t, {b, frost} ->
          {b, _} = step!(b, relax.(b))
          frost = frost || (severity(b, "trauma.thermal.frostbite") == 1 && t)
          if b.core_k < 35.0 + @c, do: {:halt, {t, b, frost}}, else: {:cont, {b, frost}}
        end)
      end

      assert {%Body{}, _} = crossing.(Body.new())
      {t, b, frost} = crossing.(%{Body.new() | wetness: 1.0})
      IO.puts("WET_HYPOTHERMIA minutes=#{Float.round(t / 60, 1)} frostbite_min=#{frost && Float.round(frost / 60, 1)} wetness=#{b.wetness} skin_c=#{b.skin_k - @c} reserve_j=#{b.reserve_j}")
      assert b.wetness < 1.0
      assert frost && frost < t
    end

    test "0 °C 水中 10 分钟（浸没 G 45 W/K 接皮肤）后出水到 20 °C 静止空气：出水时湿透，之后湿度只降、皮肤回升" do
      water = fn b -> %{q_j: 45.0 * (@c - b.skin_k), air_k: 20.0 + @c, immersed: 1.0} end
      soaked = Enum.reduce(1..600, Body.new(), fn _, b -> step!(b, water.(b)) |> elem(0) end)
      assert soaked.wetness > 0.999
      out = Enum.scan(1..(3 * 3600), soaked, fn _, b -> step!(b, air(20.0 + @c)) |> elem(0) end)
      at = fn s -> Enum.at(out, s - 1) end
      assert Enum.chunk_every(out, 2, 1, :discard) |> Enum.all?(fn [a, b] -> b.wetness <= a.wetness end)
      assert at.(3 * 3600).skin_k > soaked.skin_k
      IO.puts("WET_WATER after_10min skin_c=#{soaked.skin_k - @c} core_c=#{soaked.core_k - @c} | out 30min skin_c=#{at.(1800).skin_k - @c} wet=#{at.(1800).wetness} | 1h skin_c=#{at.(3600).skin_k - @c} wet=#{at.(3600).wetness} | 3h skin_c=#{at.(10_800).skin_k - @c} wet=#{at.(10_800).wetness} core_c=#{at.(10_800).core_k - @c}")
    end
  end
end
