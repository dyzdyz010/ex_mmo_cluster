defmodule SceneServer.Body.RepairTest do
  @moduledoc """
  身体闭环 H1 修复账与进食单测。期望值均为手算（参数依据见 body/README.md“修复账”）：

  - 伤口蛋白 = 0.03 m² × 深度 × 1000 kg/m³ × 30%：1 度 0.1 mm → 0.9 g，2 度 / 浅冻伤 1 mm → 9 g，3 度 / 深冻伤 2 mm → 18 g；
  - 合成能 12 kJ/g：1 度 0.9 g → 10 800 J，糖原付 27% = 2 916 J、脂肪付 7 884 J（储备满、20 °C 空气不寒战）；
  - 游戏内愈合时长 T = clamp(30 s × 天数^0.7, 30, 1800)（Magic.md §12），按 e^(0.7 ln d) 手算：
    5 d：ln 5 = 1.6094379 → e^1.1266065 = 3.0851693 → 92.5551 s；21 d：e^2.1311657 = 8.4246818 → 252.7405 s；
    90 d：e^3.1498668 = 23.332956 → 699.9887 s；7 d：e^1.3621371 = 3.9045288 → 117.1359 s；42 d：e^2.6163687 = 13.685936 → 410.5781 s；
  - 慢性深度 = 0.25 × √(92.5551 / T)（基数用户 2026-09-26 定）：1 度 0.25、2 度 0.25 × √0.366206 = 0.25 × 0.605150 = 0.151287、
    3 度 0.25 × √0.132224 = 0.25 × 0.363626 = 0.090906；浅冻伤 0.25 × √(92.5551/117.1359) = 0.222226、深冻伤 0.118698
    （冻伤本增量不压系统，深度只供单调性断言）；未愈合循环上限 0.75 / 0.848713 / 0.909094 → 生命 75 / 85 / 91；
  - 烧伤循环上限 c + (1 − c)·h（c = 1 − 深度），离散一步 h' = h + (c + (1 − c)h)/T，闭式 h_n = (c/(1 − c))((1 + (1 − c)/T)^n − 1)，
    h_n ≥ 1 ⇔ n ≥ ln(1/c) / ln(1 + (1 − c)/T)：1 度 ln(4/3)/ln(1 + 0.25/92.5551) = 0.287682/0.0026975 = 106.65 → 第 107 步，
    2 度 ln(1/0.848713)/ln(1 + 0.151287/252.7405) = 0.164034/0.00059841 = 274.12 → 第 275 步；
  - 进食：蒲公英一株蛋白 1.08 g、能量 18 kcal = 75 362.4 J（USDA 生重，40 g × 2.7 g、45 kcal /100 g）；
    进了蛋白储备的蛋白按 Atwater 4 kcal/g = 16 747.2 J/g 从能量里扣出：1.08 g → 18 086.976 J，进能量储备 57 275.424 J。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.{Repair, Thermo}

  @c 273.15
  @air %{q_j: 0.0, air_k: 20.0 + @c}
  @glycogen_full 7_650_000.0

  # 推进一步并核对完整账：储热变化 = stored_j = q + core_j + 代谢 − 散热；core_j = 合成放热 = 糖原付 + 脂肪付；
  # 糖原 / 脂肪减少 = 寒战付 + 合成付；蛋白减少 = 修复蛋白。`m` 是速率倍数（魔法“调”留口，Player 恒 1）。
  defp tick!(body, m \\ 1.0, inputs \\ @air) do
    {next, a} = Repair.tick(body, 1.0, inputs, m)
    assert_in_delta a.stored_j, Body.heat_content_j(next) - Body.heat_content_j(body), 1.0e-6
    assert_in_delta a.stored_j, a.q_j + a.core_j + a.metabolic_j - a.convection_j - a.sweat_j - a.drying_j, 1.0e-9
    assert a.core_j == a.synth_j
    assert_in_delta a.synth_j, a.synth_glycogen_j + a.synth_fat_j, 1.0e-9
    assert_in_delta body.reserve_j - next.reserve_j, a.shiver_glycogen_j + a.synth_glycogen_j, 1.0e-6
    assert_in_delta body.fat_reserve_j - next.fat_reserve_j, a.shiver_fat_j + a.synth_fat_j, 1.0e-6
    assert_in_delta body.protein_g - next.protein_g, a.repair_protein_g, 1.0e-12
    {next, a}
  end

  defp run(body, n),
    do: Enum.reduce(1..n, {body, 0.0, 0.0}, fn _, {b, p, s} ->
      {b, a} = tick!(b)
      {b, p + a.repair_protein_g, s + a.synth_j}
    end)

  defp severity(body, tag), do: Enum.find_value(Body.injuries(body), 0, &(&1.tag == tag && &1.severity))

  # 按时长升序（92.6 < 117.1 < 252.7 < 410.6 < 700.0 s）
  @wounds [{:burn, 1}, {:frostbite, 1}, {:burn, 2}, {:frostbite, 2}, {:burn, 3}]

  describe "伤口量、时长与慢性深度" do
    test "伤口蛋白：烧伤 1/2/3 度 0.9 / 9 / 18 g，浅 / 深冻伤 9 / 18 g" do
      assert_in_delta Repair.wound_protein_g(:burn, 1), 0.9, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:burn, 2), 9.0, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:burn, 3), 18.0, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:frostbite, 1), 9.0, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:frostbite, 2), 18.0, 1.0e-12
    end

    # 回归（改前失败）：旧实现游戏内时长 = 真实时长 ÷ 统一压缩系数 K，没有 heal_s。
    test "游戏内愈合时长 clamp(30 s × 天数^0.7, 30, 1800)：1 度 92.56 s、2 度 252.74 s、3 度 699.99 s、浅冻伤 117.14 s、深冻伤 410.58 s" do
      for {{kind, severity}, t} <- [{{:burn, 1}, 92.5551}, {{:burn, 2}, 252.7405}, {{:burn, 3}, 699.9887},
                                    {{:frostbite, 1}, 117.1359}, {{:frostbite, 2}, 410.5781}] do
        assert_in_delta Body.heal_s(kind, severity), t, 1.0e-3
      end
    end

    test "时长被夹住：1 d 恰为 30 s；0.5 d（30 × 0.5^0.7 = 18.47 s）夹到 30 s；365 d（30 × 62.17 = 1865 s）夹到 1800 s" do
      assert Body.heal_s(1) == 30.0
      assert Body.heal_s(0.5) == 30.0
      assert Body.heal_s(365) == 1800.0
      # 夹界之内不受影响：2 d = 30 × 2^0.7 = 30 × 1.6245048 = 48.735 s
      assert_in_delta Body.heal_s(2), 48.735, 1.0e-3
    end

    test "慢性深度 0.25 × √(T_1度 / T)：随时长单调下降，深度 × 时长（总量）单调上升" do
      assert Body.chronic_depth(:burn, 1) == 0.25
      assert_in_delta Body.chronic_depth(:burn, 2), 0.151287, 1.0e-6
      assert_in_delta Body.chronic_depth(:burn, 3), 0.090906, 1.0e-6
      assert_in_delta Body.chronic_depth(:frostbite, 1), 0.222226, 1.0e-6
      assert_in_delta Body.chronic_depth(:frostbite, 2), 0.118698, 1.0e-6

      durations = for {k, s} <- @wounds, do: Body.heal_s(k, s)
      depths = for {k, s} <- @wounds, do: Body.chronic_depth(k, s)
      totals = Enum.zip_with(depths, durations, &(&1 * &2))
      assert durations == Enum.sort(durations)
      assert depths |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a > b end)
      assert totals |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)
      # 总量手算：1 度 0.25 × 92.5551 = 23.1388，3 度 0.090906 × 699.9887 = 63.633
      assert_in_delta hd(totals), 23.1388, 1.0e-3
      assert_in_delta List.last(totals), 63.633, 1.0e-2
    end

    test "烧伤循环上限 1 − 深度 × (1 − 进度)：未愈合 1/2/3 度生命 75 / 85 / 91；3 度进度 0.5 → 1 − 0.090906 × 0.5 = 0.954547（生命 95）；冻伤不压循环" do
      assert_in_delta Body.systems(%{Body.new() | burn_dose_s: 1.0}).circulation, 0.75, 1.0e-12
      assert Body.life(%{Body.new() | burn_dose_s: 1.0}) == 75
      assert Body.life(%{Body.new() | burn_dose_s: 3.0}) == 85
      assert Body.life(%{Body.new() | burn_dose_s: 5.0}) == 91
      half = %{Body.new() | burn_dose_s: 5.0, burn_heal: 0.5}
      assert_in_delta Body.systems(half).circulation, 0.954547, 1.0e-6
      assert Body.life(half) == 95
      assert Body.life(%{Body.new() | frost_dose_k_s: 600.0}) == 100
    end
  end

  describe "自然愈合" do
    # 回归（改前失败）：旧实现伤口剂量只增不减、`:permanent`；K 实现下一度烧伤不压循环、需传 K。
    test "一度烧伤：首步进度 0.75/92.5551 = 0.0081033；第 106 步 h = 3((1 + 0.25/92.5551)^106 − 1) = 0.992998 仍在，第 107 步剂量与进度归零；共耗蛋白 0.9 g、合成能 10 800 J" do
      burnt = %{Body.new() | burn_dose_s: 1.0}
      assert [%{tag: "trauma.thermal.burn", part: :contact, severity: 1, progression: :heals, heal: +0.0}] = Body.injuries(burnt)

      {b1, _} = tick!(burnt)
      assert_in_delta b1.burn_heal, 0.0081033, 1.0e-7

      {b106, protein, synth} = run(burnt, 106)
      assert severity(b106, "trauma.thermal.burn") == 1
      assert_in_delta b106.burn_heal, 0.992998, 1.0e-6

      {b107, a} = tick!(b106)
      assert Body.injuries(b107) == []
      assert b107.burn_dose_s == 0.0 and b107.burn_heal == 0.0
      assert_in_delta protein + a.repair_protein_g, 0.9, 1.0e-9
      assert_in_delta 100.0 - b107.protein_g, 0.9, 1.0e-9
      assert_in_delta synth + a.synth_j, 10_800.0, 1.0e-6
      # 20 °C 空气不寒战：储备的减少全部是合成能，按 27% / 73% 拆分
      assert_in_delta @glycogen_full - b107.reserve_j, 2_916.0, 1.0e-6
      assert_in_delta Body.params().fat_full_j - b107.fat_reserve_j, 7_884.0, 1.0e-6
      assert Body.life(b107) == 100
    end

    test "二度烧伤：第 274 步仍在、第 275 步愈合，共耗蛋白 9 g" do
      {b274, protein, _} = run(%{Body.new() | burn_dose_s: 3.0}, 274)
      assert severity(b274, "trauma.thermal.burn") == 2
      {b275, a} = tick!(b274)
      assert severity(b275, "trauma.thermal.burn") == 0
      assert_in_delta protein + a.repair_protein_g, 9.0, 1.0e-9
    end

    test "三度烧伤首步：进度 = 循环 0.909094 / 699.9887 = 0.00129873；蛋白 × 18 = 0.0233771 g，合成 280.525 J" do
      {b, a} = tick!(%{Body.new() | burn_dose_s: 5.0})
      assert_in_delta b.burn_heal, 0.00129873, 1.0e-8
      assert_in_delta a.repair_protein_g, 0.0233771, 1.0e-7
      assert_in_delta a.synth_j, 280.525, 1.0e-3
    end

    test "浅冻伤（300 K·s，部位脚、不压循环）：117/117.1359 = 0.99884 第 117 步仍在，第 118 步愈合，耗蛋白 9 g" do
      frozen = %{Body.new() | frost_dose_k_s: 300.0}
      assert [%{tag: "trauma.thermal.frostbite", part: :feet, severity: 1, progression: :heals}] = Body.injuries(frozen)
      {b117, protein, _} = run(frozen, 117)
      assert severity(b117, "trauma.thermal.frostbite") == 1
      assert_in_delta b117.frost_heal, 0.998840, 1.0e-6
      {b118, a} = tick!(b117)
      assert severity(b118, "trauma.thermal.frostbite") == 0 and b118.frost_dose_k_s == 0.0
      assert_in_delta protein + a.repair_protein_g, 9.0, 1.0e-9
    end

    test "深冻伤（600 K·s）：410/410.5781 第 410 步仍在，第 411 步愈合，耗蛋白 18 g" do
      frozen = %{Body.new() | frost_dose_k_s: 600.0}
      assert severity(frozen, "trauma.thermal.frostbite") == 2
      {b410, protein, _} = run(frozen, 410)
      assert severity(b410, "trauma.thermal.frostbite") == 2
      {b411, a} = tick!(b410)
      assert severity(b411, "trauma.thermal.frostbite") == 0 and b411.frost_dose_k_s == 0.0
      assert_in_delta protein + a.repair_protein_g, 18.0, 1.0e-9
    end

    test "愈合中再烧到更深一度：进度归零，已付的蛋白不返还" do
      # 组织块 60 °C 每秒剂量 +1：第 1 步剂量 2.0 仍是一度（进度 0.5 + (0.75 + 0.25 × 0.5)/92.5551 = 0.5094538），第 2 步 3.0 进二度 → 进度 0
      healing = %{Body.new() | burn_dose_s: 1.0, burn_heal: 0.5, tissue_k: 60.0 + @c}
      {b1, _} = tick!(healing)
      assert severity(b1, "trauma.thermal.burn") == 1
      assert_in_delta b1.burn_heal, 0.5094538, 1.0e-7
      {b2, _} = tick!(b1)
      assert severity(b2, "trauma.thermal.burn") == 2 and b2.burn_heal == 0.0
      assert b2.protein_g < 100.0
    end

    test "浅冻伤愈合中冻成深冻伤：进度归零" do
      # 组织块 −10 °C 每秒过冷剂量约 9.45 K·s：599 → 约 608 ≥ 600
      healing = %{Body.new() | frost_dose_k_s: 599.0, frost_heal: 0.5, tissue_k: -10.0 + @c}
      {b, _} = tick!(healing)
      assert severity(b, "trauma.thermal.frostbite") == 2 and b.frost_heal == 0.0
    end
  end

  describe "底物约束（付不起就停在原处，不欠账；速率倍数 M = 1000 使速率不是瓶颈）" do
    test "营养为 0：一度烧伤 100 秒进度不动，不耗能量储备" do
      {b, protein, synth} = run(%{Body.new() | burn_dose_s: 1.0, protein_g: 0.0}, 100)
      assert b.burn_heal == 0.0 and severity(b, "trauma.thermal.burn") == 1
      assert protein == 0.0 and synth == 0.0
      assert b.reserve_j == @glycogen_full
    end

    test "蛋白只剩 0.45 g（一度伤口的一半）：一步最多走到进度 0.5，蛋白归零，此后不动" do
      body = %{Body.new() | burn_dose_s: 1.0, protein_g: 0.45}
      {b, a} = tick!(body, 1000.0)
      assert_in_delta b.burn_heal, 0.5, 1.0e-12
      assert b.protein_g == 0.0
      assert_in_delta a.synth_j, 5_400.0, 1.0e-6
      {b2, _} = tick!(b, 1000.0)
      assert b2.burn_heal == b.burn_heal
    end

    test "能量只剩脂肪 1080 J（一度伤口合成能的 1/10）：进度 0.1，蛋白 0.09 g，储备归零" do
      body = %{Body.new() | burn_dose_s: 1.0, reserve_j: 0.0, fat_reserve_j: 1_080.0}
      {b, a} = tick!(body, 1000.0)
      assert_in_delta b.burn_heal, 0.1, 1.0e-12
      assert_in_delta a.repair_protein_g, 0.09, 1.0e-12
      assert b.reserve_j == 0.0 and b.fat_reserve_j == 0.0
    end
  end

  describe "进食与饥饿" do
    @dandelion {1.08, 75_362.4}

    test "储备 50 g 吃一株蒲公英：蛋白 +1.08 g；能量储备 +57 275.424 J（糖原满，全进脂肪）；进 = 出" do
      {p, e} = @dandelion
      body = %{Body.new() | protein_g: 50.0}
      {b, a} = Repair.eat(body, p, e)
      assert_in_delta b.protein_g, 51.08, 1.0e-12
      assert_in_delta a.food_energy_j, 57_275.424, 1.0e-6
      assert b.reserve_j == @glycogen_full
      assert_in_delta b.fat_reserve_j - body.fat_reserve_j, 57_275.424, 1.0e-6
      assert_in_delta a.food_energy_j + a.food_protein_g * 16_747.2, e, 1.0e-6
    end

    test "糖原差 10 000 J：先补糖原到满，余下 47 275.424 J 进脂肪" do
      {p, e} = @dandelion
      body = %{Body.new() | protein_g: 50.0, reserve_j: @glycogen_full - 10_000.0}
      {b, a} = Repair.eat(body, p, e)
      assert b.reserve_j == @glycogen_full
      assert a.food_glycogen_j == 10_000.0
      assert_in_delta a.food_fat_j, 47_275.424, 1.0e-6
    end

    test "储备满时照吃：蛋白不超上限，超出的蛋白被氧化，整株能量 75 362.4 J 进储备；99.5 g 时只收 0.5 g" do
      {p, e} = @dandelion
      {full, a} = Repair.eat(Body.new(), p, e)
      assert full.protein_g == 100.0 and a.food_protein_g == 0.0
      assert_in_delta a.food_energy_j, e, 1.0e-9
      {near, a} = Repair.eat(%{Body.new() | protein_g: 99.5}, p, e)
      assert near.protein_g == 100.0
      assert_in_delta a.food_energy_j, e - 0.5 * 16_747.2, 1.0e-6
    end

    test "饥饿：营养 < 20 g（上限 20%）出现 nutrition.hunger，20 g 不出现；19 g 吃一株蒲公英到 20.08 g 即消失" do
      assert severity(%{Body.new() | protein_g: 20.0}, "nutrition.hunger") == 0
      hungry = %{Body.new() | protein_g: 19.99}
      assert [%{tag: "nutrition.hunger", part: :whole, severity: 1, progression: :tracks_protein}] = Body.injuries(hungry)
      assert Body.life(hungry) == 100
      {p, e} = @dandelion
      {fed, _} = Repair.eat(%{Body.new() | protein_g: 19.0}, p, e)
      assert_in_delta fed.protein_g, 20.08, 1.0e-12
      assert severity(fed, "nutrition.hunger") == 0
    end
  end

  test "Thermo 的 core_j：均匀 37 °C、20 °C 空气、core_j 1000 J 只进核心：核心温升 (86.223797 + 1000)/62132.112" do
    body = Enum.reduce([:core_k, :skin_k, :trunk_muscle_k, :trunk_fat_k, :limb_core_k, :limb_muscle_k, :limb_fat_k],
      Body.new(), &Map.put(&2, &1, 37.0 + @c))
    {plain, _} = Thermo.step(body, 1.0, @air)
    {next, a} = Thermo.step(body, 1.0, Map.put(@air, :core_j, 1000.0))
    assert_in_delta next.core_k - (37.0 + @c), (86.223797 + 1000) / 62_132.112, 1.0e-10
    assert next.skin_k == plain.skin_k and next.trunk_muscle_k == plain.trunk_muscle_k
    assert_in_delta a.stored_j, Body.heat_content_j(next) - Body.heat_content_j(body), 1.0e-6
  end

  test "report：伤病带愈合进度 ⌊heal × 100⌋ 与剩余秒数，下行带蛋白质储备；进度、剩余整秒或蛋白变化 0.1 g 即换比较键" do
    # 二度、进度 0.504：上限 1 − 0.151287 × 0.496 = 0.924962，剩余 0.496 × 252.7405 / 0.924962 = 135.5292 s
    body = %{Body.new() | burn_dose_s: 3.0, burn_heal: 0.504, protein_g: 42.0}
    r = Body.report(body, 1.0)
    assert [{"trauma.thermal.burn", 2, 50, left}] = r.injuries
    assert_in_delta left, 135.5292, 1.0e-3
    assert r.protein_g == 42.0
    refute Body.report(%{body | burn_heal: 0.51}, 1.0).key == r.key
    refute Body.report(%{body | protein_g: 42.1}, 1.0).key == r.key
    assert Body.report(%{body | protein_g: 42.01}, 1.0).key == r.key
    # 进度 0.508 仍是 50 %，但剩余 0.492 × 252.7405 / 0.925567 = 134.35 s → 整秒 134 ≠ 136，换键
    refute Body.report(%{body | burn_heal: 0.508}, 1.0).key == r.key
  end

  # 生命条可恢复段与剩余愈合时间（Hello 30）。期望手算，见 moduledoc 的时长与慢性深度；循环带 24/32/40/43 °C、神经带 28/35/39/42 °C（body.ex）。
  describe "可恢复生命与剩余愈合时间" do
    test "一度烧伤受伤瞬间：生命 75、可恢复 25（全愈后 100）；剩余 = 92.5551 / 0.75 = 123.407 s；二度上限 0.848713 → 生命 85、可恢复 15" do
      burnt = %{Body.new() | burn_dose_s: 1.0}
      r = Body.report(burnt, 1.0)
      assert {r.life, r.recoverable} == {75, 25}
      assert [{"trauma.thermal.burn", 1, 0, left}] = r.injuries
      assert_in_delta left, 123.407, 1.0e-3
      second = %{burnt | burn_dose_s: 3.0}
      assert {Body.life(second), Body.recoverable_life(second)} == {85, 15}
    end

    test "三度烧伤：受伤瞬间生命 91、可恢复 9、剩余 699.9887 / 0.909094 = 769.99 s；进度 0.5 → 生命 95、可恢复 5、剩余 0.5 × 699.9887 / 0.954547 = 366.66 s" do
      r = Body.report(%{Body.new() | burn_dose_s: 5.0}, 1.0)
      assert {r.life, r.recoverable} == {91, 9}
      assert [{_, 3, 0, left}] = r.injuries
      assert_in_delta left, 769.99, 1.0e-2
      r = Body.report(%{Body.new() | burn_dose_s: 5.0, burn_heal: 0.5}, 1.0)
      assert {r.life, r.recoverable} == {95, 5}
      assert [{_, 3, 50, left}] = r.injuries
      assert_in_delta left, 366.66, 1.0e-2
    end

    test "急性损失不算可恢复：核心 32.9 °C 神经 (32.9 − 28)/7 = 0.70 低于一度上限 0.75（循环带 32 °C 起满值）→ 生命 70、可恢复 0；核心 33.6 °C 神经 0.80 → 生命 75、可恢复 5" do
      burnt = %{Body.new() | burn_dose_s: 1.0}
      assert Body.life(%{burnt | core_k: 32.9 + @c}) == 70
      assert Body.recoverable_life(%{burnt | core_k: 32.9 + @c}) == 0
      assert Body.life(%{burnt | core_k: 33.6 + @c}) == 75
      assert Body.recoverable_life(%{burnt | core_k: 33.6 + @c}) == 5
      # 无伤口时同一体温：生命 80，可恢复 0
      assert Body.recoverable_life(%{Body.new() | core_k: 33.6 + @c}) == 0
    end

    test "冻伤不压系统：浅冻伤生命 100、可恢复 0，剩余 = 时长 117.1359 s（循环满值）；体温伤病与饥饿不愈合，剩余 0" do
      r = Body.report(%{Body.new() | frost_dose_k_s: 300.0, core_k: 34.5 + @c, protein_g: 10.0}, 1.0)
      assert {r.life, r.recoverable} == {93, 0}
      assert [{"temperature.hypothermia", 1, 0, +0.0}, {"trauma.thermal.frostbite", 1, 0, left}, {"nutrition.hunger", 1, 0, +0.0}] =
               r.injuries
      assert_in_delta left, 117.1359, 1.0e-3
    end

    test "营养为 0 → 剩余 −1（愈合停止：需要营养）；循环归零（核心 23 °C 低于循环冷侧 24 °C）→ −2" do
      assert Body.remaining_s(%{Body.new() | burn_dose_s: 1.0, protein_g: 0.0}, :burn, 1.0) == -1.0
      assert Body.remaining_s(%{Body.new() | burn_dose_s: 1.0, core_k: 23.0 + @c}, :burn, 1.0) == -2.0
    end

    test "一度烧伤逐秒：剩余单调下降、每步降幅 ≥ 1 s（循环回升只会更快），愈合前一步（第 106 步，进度 0.992998）剩余 0.007002 × 92.5551 / 0.998249 = 0.649 s，第 107 步愈合" do
      steps =
        Enum.scan(1..106, {%{Body.new() | burn_dose_s: 1.0}, nil}, fn _, {b, _} -> tick!(b) end)
        |> Enum.map(fn {b, _} -> {b, Body.remaining_s(b, :burn, 1.0), Body.recoverable_life(b)} end)

      lefts = [Body.remaining_s(%{Body.new() | burn_dose_s: 1.0}, :burn, 1.0) | Enum.map(steps, &elem(&1, 1))]
      assert lefts |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a - b >= 1.0 - 1.0e-9 end)
      {b106, left106, _} = List.last(steps)
      assert_in_delta left106, 0.649, 1.0e-3
      # 可恢复段随愈合缩短：从 25 单调不增，第 106 步上限 0.998249 → 生命 100、可恢复 0
      recoverable = [25 | Enum.map(steps, &elem(&1, 2))]
      assert recoverable |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a >= b end)
      assert List.last(recoverable) == 0
      {b107, _} = tick!(b106)
      assert Body.injuries(b107) == [] and Body.recoverable_life(b107) == 0
    end
  end
end
