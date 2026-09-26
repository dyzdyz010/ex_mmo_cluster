defmodule SceneServer.Body.RepairTest do
  @moduledoc """
  身体闭环 H1 修复账与进食单测。期望值均为手算（参数依据见 body/README.md“修复账”），K 由测试显式给出：

  - 伤口蛋白 = 0.03 m² × 深度 × 1000 kg/m³ × 30%：1 度 0.1 mm → 0.9 g，2 度 1 mm → 9 g，3 度 / 冻伤 2 mm → 18 g；
  - 合成能 12 kJ/g：1 度 0.9 g → 10 800 J，糖原付 27% = 2 916 J、脂肪付 7 884 J（储备满、20 °C 空气不寒战）；
  - 真实愈合 1 度 5 d = 432 000 s、3 度 90 d = 7 776 000 s、冻伤 42 d = 3 628 800 s；
    K = 3375 时 1 度每秒进度 3375/432000 = 1/128（二进制精确）→ 第 128 秒愈合；K = 1008 时 432000/1008 = 428.57 s → 第 429 秒；
  - 进食：蒲公英一株蛋白 1.08 g、能量 18 kcal = 75 362.4 J（USDA 生重，40 g × 2.7 g、45 kcal /100 g）；
    进了蛋白储备的蛋白按 Atwater 4 kcal/g = 16 747.2 J/g 从能量里扣出：1.08 g → 18 086.976 J，进能量储备 57 275.424 J。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.{Repair, Thermo}

  @c 273.15
  @k 3375
  @air %{q_j: 0.0, air_k: 20.0 + @c}
  @glycogen_full 7_650_000.0

  # 推进一步并核对完整账：储热变化 = stored_j = q + core_j + 代谢 − 散热；core_j = 合成放热 = 糖原付 + 脂肪付；
  # 糖原 / 脂肪减少 = 寒战付 + 合成付；蛋白减少 = 修复蛋白。
  defp tick!(body, k \\ @k, inputs \\ @air) do
    {next, a} = Repair.tick(body, 1.0, inputs, k, 1.0)
    assert_in_delta a.stored_j, Body.heat_content_j(next) - Body.heat_content_j(body), 1.0e-6
    assert_in_delta a.stored_j, a.q_j + a.core_j + a.metabolic_j - a.convection_j - a.sweat_j - a.drying_j, 1.0e-9
    assert a.core_j == a.synth_j
    assert_in_delta a.synth_j, a.synth_glycogen_j + a.synth_fat_j, 1.0e-9
    assert_in_delta body.reserve_j - next.reserve_j, a.shiver_glycogen_j + a.synth_glycogen_j, 1.0e-6
    assert_in_delta body.fat_reserve_j - next.fat_reserve_j, a.shiver_fat_j + a.synth_fat_j, 1.0e-6
    assert_in_delta body.protein_g - next.protein_g, a.repair_protein_g, 1.0e-12
    {next, a}
  end

  defp run(body, n, k \\ @k, inputs \\ @air),
    do: Enum.reduce(1..n, {body, 0.0, 0.0}, fn _, {b, p, s} ->
      {b, a} = tick!(b, k, inputs)
      {b, p + a.repair_protein_g, s + a.synth_j}
    end)

  defp severity(body, tag), do: Enum.find_value(Body.injuries(body), 0, &(&1.tag == tag && &1.severity))

  describe "伤口量" do
    test "伤口蛋白 1/2/3 度 0.9 / 9 / 18 g，冻伤 18 g；真实愈合 5 / 21 / 90 d、冻伤 42 d" do
      assert_in_delta Repair.wound_protein_g(:burn, 1), 0.9, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:burn, 2), 9.0, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:burn, 3), 18.0, 1.0e-12
      assert_in_delta Repair.wound_protein_g(:frostbite, 1), 18.0, 1.0e-12
      assert Repair.heal_real_s(:burn, 1) == 432_000.0
      assert Repair.heal_real_s(:burn, 3) == 7_776_000.0
      assert Repair.heal_real_s(:frostbite, 1) == 3_628_800.0
    end
  end

  describe "自然愈合" do
    # 回归（改前失败）：旧实现伤口剂量只增不减、`:permanent`，同样离火 128 s 后仍是一度烧伤。
    test "一度烧伤、K = 3375：第 127 秒进度 127/128，第 128 秒剂量与进度归零、伤病消失；共耗蛋白 0.9 g、合成能 10 800 J" do
      burnt = %{Body.new() | burn_dose_s: 1.0}
      assert [%{tag: "trauma.thermal.burn", severity: 1, progression: :heals, heal: +0.0}] = Body.injuries(burnt)

      {b127, protein, synth} = run(burnt, 127)
      assert severity(b127, "trauma.thermal.burn") == 1
      assert b127.burn_heal == 127 / 128

      {b128, a} = tick!(b127)
      assert Body.injuries(b128) == []
      assert b128.burn_dose_s == 0.0 and b128.burn_heal == 0.0
      assert_in_delta protein + a.repair_protein_g, 0.9, 1.0e-9
      assert_in_delta 100.0 - b128.protein_g, 0.9, 1.0e-9
      assert_in_delta synth + a.synth_j, 10_800.0, 1.0e-6
      # 20 °C 空气不寒战：储备的减少全部是合成能，按 27% / 73% 拆分
      assert_in_delta @glycogen_full - b128.reserve_j, 2_916.0, 1.0e-6
      assert_in_delta Body.params().fat_full_j - b128.fat_reserve_j, 7_884.0, 1.0e-6
      assert Body.life(b128) == 100
    end

    test "一度烧伤、K = 1008：432000/1008 = 428.57 s，第 428 秒仍在、第 429 秒愈合" do
      {b428, _, _} = run(%{Body.new() | burn_dose_s: 1.0}, 428, 1008)
      assert severity(b428, "trauma.thermal.burn") == 1
      {b429, _} = tick!(b428, 1008)
      assert severity(b429, "trauma.thermal.burn") == 0
    end

    test "三度烧伤首步：进度 = 3375/7776000 × 循环 0.7；蛋白 18 × 0.7 × 3375/7776000 = 0.00546875 g，合成 65.625 J" do
      {b, a} = tick!(%{Body.new() | burn_dose_s: 5.0})
      assert_in_delta b.burn_heal, 0.7 * 3375 / 7_776_000, 1.0e-15
      assert_in_delta a.repair_protein_g, 0.00546875, 1.0e-12
      assert_in_delta a.synth_j, 65.625, 1.0e-9
    end

    test "三度烧伤：循环上限 0.7 随进度线性恢复（进度 0.5 → 0.85，生命 85）" do
      assert Body.systems(%{Body.new() | burn_dose_s: 5.0}).circulation == 0.7
      half = %{Body.new() | burn_dose_s: 5.0, burn_heal: 0.5}
      assert_in_delta Body.systems(half).circulation, 0.85, 1.0e-12
      assert Body.life(half) == 85
    end

    test "冻伤不压循环（生命 100），K = 3375：3628800/3375 = 1075.2 s，第 1075 秒仍在、第 1076 秒愈合，耗蛋白 18 g" do
      frozen = %{Body.new() | frost_dose_k_s: 600.0}
      assert Body.life(frozen) == 100
      {b1075, protein, _} = run(frozen, 1075)
      assert severity(b1075, "trauma.thermal.frostbite") == 1
      {b1076, a} = tick!(b1075)
      assert severity(b1076, "trauma.thermal.frostbite") == 0 and b1076.frost_dose_k_s == 0.0
      assert_in_delta protein + a.repair_protein_g, 18.0, 1.0e-9
    end

    test "愈合中再烧到更深一度：进度归零，已付的蛋白不返还" do
      # 组织块 60 °C 每秒剂量 +1：第 1 步剂量 2.0 仍是一度（进度 0.5 + 1/128），第 2 步 3.0 进二度 → 进度 0
      healing = %{Body.new() | burn_dose_s: 1.0, burn_heal: 0.5, tissue_k: 60.0 + @c}
      {b1, _} = tick!(healing)
      assert severity(b1, "trauma.thermal.burn") == 1 and b1.burn_heal == 0.5 + 1 / 128
      {b2, _} = tick!(b1)
      assert severity(b2, "trauma.thermal.burn") == 2 and b2.burn_heal == 0.0
      assert b2.protein_g < 100.0
    end
  end

  describe "底物约束（付不起就停在原处，不欠账）" do
    test "营养为 0：一度烧伤 100 秒进度不动，不耗能量储备" do
      {b, protein, synth} = run(%{Body.new() | burn_dose_s: 1.0, protein_g: 0.0}, 100)
      assert b.burn_heal == 0.0 and severity(b, "trauma.thermal.burn") == 1
      assert protein == 0.0 and synth == 0.0
      assert b.reserve_j == @glycogen_full
    end

    test "蛋白只剩 0.45 g（一度伤口的一半）：一步最多走到进度 0.5，蛋白归零，此后不动" do
      body = %{Body.new() | burn_dose_s: 1.0, protein_g: 0.45}
      {b, a} = tick!(body, 432_000)
      assert_in_delta b.burn_heal, 0.5, 1.0e-12
      assert b.protein_g == 0.0
      assert_in_delta a.synth_j, 5_400.0, 1.0e-6
      {b2, _} = tick!(b, 432_000)
      assert b2.burn_heal == b.burn_heal
    end

    test "能量只剩脂肪 1080 J（一度伤口合成能的 1/10）：进度 0.1，蛋白 0.09 g，储备归零" do
      body = %{Body.new() | burn_dose_s: 1.0, reserve_j: 0.0, fat_reserve_j: 1_080.0}
      {b, a} = tick!(body, 432_000)
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

  test "report：伤病带愈合进度 ⌊heal × 100⌋，下行带蛋白质储备；进度或蛋白变化 0.1 g 即换比较键" do
    body = %{Body.new() | burn_dose_s: 3.0, burn_heal: 0.506, protein_g: 42.0}
    r = Body.report(body)
    assert r.injuries == [{"trauma.thermal.burn", 2, 50}]
    assert r.protein_g == 42.0
    refute Body.report(%{body | burn_heal: 0.51}).key == r.key
    refute Body.report(%{body | protein_g: 42.1}).key == r.key
    assert Body.report(%{body | protein_g: 42.01}).key == r.key
  end
end
