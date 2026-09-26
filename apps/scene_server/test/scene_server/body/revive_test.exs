defmodule SceneServer.Body.ReviveTest do
  @moduledoc """
  身体闭环 H2：伤病合成、复活统一状态与复活 debuff、烧伤疼痛 / 恍惚压神经（相干度倍率）。期望值均为手算：

  - 合成（用户 2026-09-26 定）：缺损 d = 1 − f，水平 = 1 − min(1, (Σ dᵖ)^(1/p))。
    p = 2：0.5 + 0.5 → 1 − √0.5 = 0.292893（生命 29）；0.3 + 0.3 → 1 − √0.98 = 0.010051（1）；单 0.5 → 0.5（50）；
    0.2 + 0.95 → 1 − √(0.64 + 0.0025) = 0.198439（20）。
    p = 3：1 − 0.25^(1/3) = 0.370039（37）；1 − 0.686^(1/3) = 0.118055（12）；50；1 − 0.512125^(1/3) = 0.199935（20）。
    p = 4：1 − 0.125^(1/4) = 0.405396（41）；1 − 0.4802^(1/4) = 0.167555（17）；50；1 − 0.40960625^(1/4) = 0.199997（20）。
  - 复活身体：营养 0、糖原 0、脂肪 11.16 kg × 9 kcal/g × 4186.8 J/kcal = 420 522 192 J；虚弱循环 × 0.85、恍惚神经 × 0.45
    → 1 − √(0.15² + 0.55²) = 1 − √0.325 = 0.429912（生命 43），去掉 debuff 生命 100 → 可恢复 57。
  - 烧伤急性期满：一度下压 0.25 同时压循环与神经（疼痛）→ 1 − √(2 × 0.25²) = 0.646447（65）；二度 0.151287 → 0.786047（79）；
    三度 0.090906 → 0.871439（87）。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Repair

  @c 273.15
  @air %{q_j: 0.0, air_k: 20.0 + @c}
  @onset 30.0

  defp tick!(body) do
    {next, a} = Repair.tick(body, 1.0, @air, 1.0)
    assert_in_delta a.stored_j, Body.heat_content_j(next) - Body.heat_content_j(body), 1.0e-6
    assert_in_delta body.protein_g - next.protein_g, a.repair_protein_g, 1.0e-12
    next
  end

  defp tags(body), do: body |> Body.injuries() |> Enum.map(& &1.tag) |> Enum.sort()

  describe "伤病合成" do
    test "手算表：p = 2 / 3 / 4 下 0.5 + 0.5、0.3 + 0.3、单 0.5、0.2 + 0.95" do
      table = %{
        2.0 => [{[0.5, 0.5], 0.292893, 29}, {[0.3, 0.3], 0.010051, 1}, {[0.5, 1.0], 0.5, 50}, {[0.2, 0.95], 0.198439, 20}],
        3.0 => [{[0.5, 0.5], 0.370039, 37}, {[0.3, 0.3], 0.118055, 12}, {[0.5, 1.0], 0.5, 50}, {[0.2, 0.95], 0.199935, 20}],
        4.0 => [{[0.5, 0.5], 0.405396, 41}, {[0.3, 0.3], 0.167555, 17}, {[0.5, 1.0], 0.5, 50}, {[0.2, 0.95], 0.199997, 20}]
      }

      for {p, rows} <- table, {levels, level, life} <- rows do
        got = Body.combined_level(levels, p)
        assert_in_delta got, level, 1.0e-6
        assert {p, levels, round(100 * got)} == {p, levels, life}
      end

      # p 很大时退化为取最弱（旧规则）
      assert_in_delta Body.combined_level([0.3, 0.7], 100.0), 0.3, 1.0e-9
      assert Body.params().lethal_norm_p == 2.0
    end

    test "核心 30 °C：循环 (30 − 24)/8 = 0.75、神经 (30 − 28)/7 = 0.285714 → 1 − √(0.0625 + 0.510204) = 0.243228，生命 24（旧取最弱 29）" do
      body = %{Body.new() | core_k: 30.0 + @c}
      assert_in_delta Body.lethal_level(body), 0.243228, 1.0e-6
      assert Body.life(body) == 24
    end

    test "濒死读合成水平（改前取最弱不会濒死）：核心 31 °C + 一度烧伤压满 + 虚弱 + 恍惚 → 循环 0.557813、神经 0.144643，各自 ≥ 0.1，合成 0.037105 → 10 秒后濒死" do
      body = %{Body.new() | core_k: 31.0 + @c, burn_dose_s: 1.0, burn_age_s: @onset, weak_s: 500.0, daze_s: 500.0}
      %{circulation: circ, nervous: nerve} = Body.systems(body)
      assert_in_delta circ, 0.875 * 0.75 * 0.85, 1.0e-12
      assert_in_delta nerve, 3 / 7 * 0.75 * 0.45, 1.0e-12
      assert circ >= 0.1 and nerve >= 0.1
      assert_in_delta Body.lethal_level(body), 0.037105, 1.0e-6
      assert Body.life(body) == 4
      nine = Enum.reduce(1..9, body, fn _, b -> Body.progress(b, 1.0) end)
      assert nine.status == :alive
      assert Body.progress(nine, 1.0).status == :dying
    end
  end

  describe "烧伤疼痛与恍惚压神经（相干度倍率）" do
    test "急性期满：一 / 二 / 三度下压同时压循环与神经 → 生命 65 / 79 / 87，神经 0.75 / 0.848713 / 0.909094；可恢复 35 / 21 / 13" do
      for {dose, nerve, life} <- [{1.0, 0.75, 65}, {3.0, 0.848713, 79}, {5.0, 0.909094, 87}] do
        body = %{Body.new() | burn_dose_s: dose, burn_age_s: @onset}
        assert_in_delta Body.systems(body).nervous, nerve, 1.0e-6
        assert_in_delta Body.systems(body).circulation, nerve, 1.0e-6
        assert {dose, Body.life(body), Body.recoverable_life(body)} == {dose, life, 100 - life}
      end
    end

    test "疼痛随急性期先升后随愈合降：一度计时 15 s → 神经 1 − 0.25 × 0.5 = 0.875；压满且进度 0.5 → 0.875" do
      assert_in_delta Body.systems(%{Body.new() | burn_dose_s: 1.0, burn_age_s: 15.0}).nervous, 0.875, 1.0e-12
      assert_in_delta Body.systems(%{Body.new() | burn_dose_s: 1.0, burn_age_s: @onset, burn_heal: 0.5}).nervous, 0.875, 1.0e-12
    end

    test "恍惚与疼痛相乘：恍惚 0.45 × 一度压满 0.75 = 0.3375" do
      body = %{Body.new() | burn_dose_s: 1.0, burn_age_s: @onset, daze_s: 10.0}
      assert_in_delta Body.systems(body).nervous, 0.3375, 1.0e-12
    end
  end

  describe "复活统一状态" do
    test "逐字段：营养 0、糖原 0、脂肪标准值 420 522 192 J、调定点体温、无伤口、伤病只剩饥饿 + 虚弱 + 恍惚，生命 43、可恢复 57" do
      b = Body.revive()
      assert {b.protein_g, b.reserve_j} == {0.0, 0.0}
      assert_in_delta b.fat_reserve_j, 420_522_192.0, 1.0e-3
      assert {b.core_k, b.skin_k, b.tissue_k} == {36.8 + @c, 34.0 + @c, 34.0 + @c}
      assert {b.burn_dose_s, b.frost_dose_k_s, b.burn_heal, b.frost_heal, b.burn_age_s} == {0.0, 0.0, 0.0, 0.0, 0.0}
      assert {b.status, b.lethal_s, b.wetness} == {:alive, 0.0, 0.0}
      assert {b.weak_s, b.daze_s} == {120.0, 40.0}
      assert tags(b) == ["nervous.daze", "nutrition.hunger", "recovery.weakness"]
      %{circulation: circ, nervous: nerve} = Body.systems(b)
      assert {circ, nerve} == {0.85, 0.45}
      assert_in_delta Body.lethal_level(b), 0.429912, 1.0e-6
      assert {Body.life(b), Body.recoverable_life(b)} == {43, 57}
      r = Body.report(b, 1.0)
      assert {"recovery.weakness", 1, 0, 120.0} in r.injuries
      assert {"nervous.daze", 1, 0, 40.0} in r.injuries
      assert {"nutrition.hunger", 1, 0, 0.0} in r.injuries
    end

    test "虚弱 120 s、恍惚 40 s 各自按时间解除：第 39 秒恍惚仍在、第 40 秒解除（生命 85）；第 119 秒虚弱仍在、第 120 秒解除（生命 100）" do
      at = fn n -> Enum.reduce(1..n, Body.revive(), fn _, b -> tick!(b) end) end
      b20 = at.(20)
      assert {"nervous.daze", 1, 50, 20.0} in Body.report(b20, 1.0).injuries
      assert {"recovery.weakness", 1, 16, 100.0} in Body.report(b20, 1.0).injuries
      b39 = at.(39)
      assert "nervous.daze" in tags(b39)
      b40 = tick!(b39)
      assert tags(b40) == ["nutrition.hunger", "recovery.weakness"]
      assert Body.life(b40) == 85
      b119 = Enum.reduce(41..119, b40, fn _, b -> tick!(b) end)
      assert "recovery.weakness" in tags(b119)
      b120 = tick!(b119)
      assert tags(b120) == ["nutrition.hunger"]
      assert {Body.life(b120), Body.recoverable_life(b120)} == {100, 0}
    end

    test "饥饿吃到 20 g 解除：蒲公英每株 1.08 g，18 株 19.44 g 仍饥饿，第 19 株 20.52 g 解除；虚弱、恍惚不受进食影响" do
      eat = fn b, n -> Enum.reduce(1..n, b, fn _, b -> b |> Repair.eat(1.08, 75_362.4) |> elem(0) end) end
      b18 = eat.(Body.revive(), 18)
      assert_in_delta b18.protein_g, 19.44, 1.0e-9
      assert "nutrition.hunger" in tags(b18)
      b19 = eat.(b18, 1)
      assert_in_delta b19.protein_g, 20.52, 1.0e-9
      assert tags(b19) == ["nervous.daze", "recovery.weakness"]
    end
  end
end
