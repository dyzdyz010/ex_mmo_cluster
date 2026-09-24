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

  # 推进一步并核对能量账：储热变化 = 两节点热容 × 温升 = q + 代谢 − 干热散失 − 出汗。
  defp step!(body, inputs, dt \\ 1.0) do
    {next, account} = Thermo.step(body, dt, inputs)
    stored = @skin_c * (next.skin_k - body.skin_k) + @core_c * (next.core_k - body.core_k)
    assert_in_delta account.stored_j, stored, 1.0e-6

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
end
