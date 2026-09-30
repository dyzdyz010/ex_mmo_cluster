defmodule SceneServer.Body.ReviveTest do
  @moduledoc """
  身体闭环 H2：伤病合成、复活统一状态与复活 debuff、施法相干度系数（烧伤疼痛 / 恍惚只降相干度，不进生命，用户 2026-09-27 定）。
  期望值均为手算：

  - 合成（用户 2026-09-26 定）：缺损 d = 1 − f，水平 = 1 − min(1, (Σ dᵖ)^(1/p))。
    p = 2：0.5 + 0.5 → 1 − √0.5 = 0.292893（生命 29）；0.3 + 0.3 → 1 − √0.98 = 0.010051（1）；单 0.5 → 0.5（50）；
    0.2 + 0.95 → 1 − √(0.64 + 0.0025) = 0.198439（20）。
    p = 3：1 − 0.25^(1/3) = 0.370039（37）；1 − 0.686^(1/3) = 0.118055（12）；50；1 − 0.512125^(1/3) = 0.199935（20）。
    p = 4：1 − 0.125^(1/4) = 0.405396（41）；1 − 0.4802^(1/4) = 0.167555（17）；50；1 − 0.40960625^(1/4) = 0.199997（20）。
  - 复活身体：营养 0、糖原 0、脂肪 11.16 kg × 9 kcal/g × 4186.8 J/kcal = 420 522 192 J；虚弱循环 × 0.85、神经 1（恍惚不进生命）
    → 1 − √(0.15² + 0) = 0.85（生命 85），去掉 debuff 生命 100 → 可恢复 15；相干度系数 1 × 1 × 0.45 = 0.45（相干度 4 × 0.45 = 1.8）。
  - 相干度系数 = 神经（核心体温带）× 疼痛（1 − 烧伤下压）× 恍惚（0.45）：一 / 二 / 三度压满（下压 0.25 / 0.151287 / 0.090906）
    → 0.75 / 0.848713 / 0.909094（相干度 3.0 / 3.39 / 3.64，现行目录 S ≤ 2 不走火）；恍惚 × 一度压满 0.3375（1.35）；
    一度计时 15 s → 1 − 0.25 × 0.5 = 0.875；核心 30 °C 神经 (30 − 28)/7 = 0.285714。
  - 烧伤生命（疼痛不进神经，只剩循环一个系统受压）：满深度 1 − 下压 → 75 / 85 / 91；从受伤起逐秒递推（递推式见 repair_test），
    谷底一度 82（第 30 秒）、二度 87（第 28–30 秒：下压 0.151287 × min(1, k/30) × (1 − h_k)，h_30 = 0.113 → 0.1342 → 87）、
    三度 91（下压 ≤ 0.0909 → 91）。
  - 濒死读合成值：核心 29.5 °C + 一度压满 + 虚弱：循环 (29.5 − 24)/8 × 0.75 × 0.85 = 0.438281，神经 (29.5 − 28)/7 = 0.214286，
    各自 ≥ 0.1（旧“取最弱”不会濒死），合成 1 − √(0.561719² + 0.785714²) = 1 − √0.932875 = 0.034146（生命 3）→ 10 秒后濒死。
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
        2.0 => [
          {[0.5, 0.5], 0.292893, 29},
          {[0.3, 0.3], 0.010051, 1},
          {[0.5, 1.0], 0.5, 50},
          {[0.2, 0.95], 0.198439, 20}
        ],
        3.0 => [
          {[0.5, 0.5], 0.370039, 37},
          {[0.3, 0.3], 0.118055, 12},
          {[0.5, 1.0], 0.5, 50},
          {[0.2, 0.95], 0.199935, 20}
        ],
        4.0 => [
          {[0.5, 0.5], 0.405396, 41},
          {[0.3, 0.3], 0.167555, 17},
          {[0.5, 1.0], 0.5, 50},
          {[0.2, 0.95], 0.199997, 20}
        ]
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

    test "濒死读合成水平（改前取最弱不会濒死）：核心 29.5 °C + 一度烧伤压满 + 虚弱 → 循环 0.438281、神经 0.214286，各自 ≥ 0.1，合成 0.034146 → 10 秒后濒死" do
      body = %{
        Body.new()
        | core_k: 29.5 + @c,
          burn_dose_s: 1.0,
          burn_age_s: @onset,
          weak_s: 500.0,
          daze_s: 500.0
      }

      %{circulation: circ, nervous: nerve} = Body.systems(body)
      assert_in_delta circ, 0.6875 * 0.75 * 0.85, 1.0e-12
      assert_in_delta nerve, 1.5 / 7, 1.0e-12
      assert circ >= 0.1 and nerve >= 0.1
      assert_in_delta Body.lethal_level(body), 0.034146, 1.0e-6
      assert Body.life(body) == 3
      nine = Enum.reduce(1..9, body, fn _, b -> Body.progress(b, 1.0) end)
      assert nine.status == :alive
      assert Body.progress(nine, 1.0).status == :dying
    end
  end

  describe "相干度系数（疼痛、恍惚只降相干度，不进生命）" do
    # 回归（改前失败）：body-h2 首版把疼痛与恍惚乘进神经，一度压满生命 65、复活生命 43。
    test "烧伤急性期满：相干度系数 0.75 / 0.848713 / 0.909094，神经仍 1.0，生命 75 / 85 / 91、可恢复 25 / 15 / 9" do
      for {dose, factor, life} <- [{1.0, 0.75, 75}, {3.0, 0.848713, 85}, {5.0, 0.909094, 91}] do
        body = %{Body.new() | burn_dose_s: dose, burn_age_s: @onset}
        assert_in_delta Body.coherence_factor(body), factor, 1.0e-6
        assert Body.systems(body).nervous == 1.0
        assert {dose, Body.life(body), Body.recoverable_life(body)} == {dose, life, 100 - life}
      end
    end

    test "烧伤生命谷底（含 30 s 急性期）：一 / 二 / 三度逐秒推进到愈合，最低生命 82 / 87 / 91" do
      for {dose, trough} <- [{1.0, 82}, {3.0, 87}, {5.0, 91}] do
        lives =
          %{Body.new() | burn_dose_s: dose}
          |> Stream.iterate(&tick!/1)
          |> Stream.take(800)
          |> Enum.map(&Body.life/1)

        assert {dose, Enum.min(lives)} == {dose, trough}
      end
    end

    test "疼痛随急性期先升后随愈合降：一度计时 15 s → 1 − 0.25 × 0.5 = 0.875；压满且进度 0.5 → 0.875" do
      assert_in_delta Body.coherence_factor(%{Body.new() | burn_dose_s: 1.0, burn_age_s: 15.0}),
                      0.875,
                      1.0e-12

      assert_in_delta Body.coherence_factor(%{
                        Body.new()
                        | burn_dose_s: 1.0,
                          burn_age_s: @onset,
                          burn_heal: 0.5
                      }),
                      0.875,
                      1.0e-12
    end

    test "恍惚与疼痛相乘：恍惚 0.45 × 一度压满 0.75 = 0.3375；恍惚不改生命（75）；核心 30 °C 神经 0.285714 也进系数" do
      body = %{Body.new() | burn_dose_s: 1.0, burn_age_s: @onset, daze_s: 10.0}
      assert_in_delta Body.coherence_factor(body), 0.3375, 1.0e-12
      assert Body.life(body) == 75
      assert_in_delta Body.coherence_factor(%{Body.new() | core_k: 30.0 + @c}), 2 / 7, 1.0e-12
      assert Body.coherence_factor(Body.new()) == 1.0
    end
  end

  describe "复活统一状态" do
    test "逐字段：营养 0、糖原 0、脂肪标准值 420 522 192 J、调定点体温、无伤口、伤病只剩饥饿 + 虚弱 + 恍惚，生命 85、可恢复 15、相干度系数 0.45" do
      b = Body.revive()
      assert {b.protein_g, b.reserve_j} == {0.0, 0.0}
      assert_in_delta b.fat_reserve_j, 420_522_192.0, 1.0e-3
      assert {b.core_k, b.skin_k, b.tissue_k} == {36.8 + @c, 34.0 + @c, 34.0 + @c}

      assert {b.burn_dose_s, b.frost_dose_k_s, b.burn_heal, b.frost_heal, b.burn_age_s} ==
               {0.0, 0.0, 0.0, 0.0, 0.0}

      assert {b.status, b.lethal_s, b.wetness} == {:alive, 0.0, 0.0}
      assert {b.weak_s, b.daze_s} == {120.0, 40.0}
      assert tags(b) == ["nervous.daze", "nutrition.hunger", "recovery.weakness"]
      %{circulation: circ, nervous: nerve} = Body.systems(b)
      assert {circ, nerve} == {0.85, 1.0}
      assert_in_delta Body.lethal_level(b), 0.85, 1.0e-12
      assert {Body.life(b), Body.recoverable_life(b)} == {85, 15}
      assert Body.coherence_factor(b) == 0.45
      r = Body.report(b, 1.0)
      assert {"recovery.weakness", 1, 0, 120.0} in r.injuries
      assert {"nervous.daze", 1, 0, 40.0} in r.injuries
      assert {"nutrition.hunger", 1, 0, 0.0} in r.injuries
    end

    test "虚弱 120 s、恍惚 40 s 各自按时间解除：第 39 秒恍惚仍在（系数 0.45）、第 40 秒解除（系数 1，生命仍 85）；第 119 秒虚弱仍在、第 120 秒解除（生命 100）" do
      at = fn n -> Enum.reduce(1..n, Body.revive(), fn _, b -> tick!(b) end) end
      b20 = at.(20)
      assert {"nervous.daze", 1, 50, 20.0} in Body.report(b20, 1.0).injuries
      assert {"recovery.weakness", 1, 16, 100.0} in Body.report(b20, 1.0).injuries
      b39 = at.(39)
      assert "nervous.daze" in tags(b39)
      assert Body.coherence_factor(b39) == 0.45
      b40 = tick!(b39)
      assert tags(b40) == ["nutrition.hunger", "recovery.weakness"]
      assert Body.coherence_factor(b40) == 1.0
      assert Body.life(b40) == 85
      b119 = Enum.reduce(41..119, b40, fn _, b -> tick!(b) end)
      assert "recovery.weakness" in tags(b119)
      b120 = tick!(b119)
      assert tags(b120) == ["nutrition.hunger"]
      assert {Body.life(b120), Body.recoverable_life(b120)} == {100, 0}
    end

    test "饥饿吃到 20 g 解除：蒲公英每株 1.08 g，18 株 19.44 g 仍饥饿，第 19 株 20.52 g 解除；虚弱、恍惚不受进食影响" do
      eat = fn b, n ->
        Enum.reduce(1..n, b, fn _, b -> b |> Repair.eat(1.08, 75_362.4) |> elem(0) end)
      end

      b18 = eat.(Body.revive(), 18)
      assert_in_delta b18.protein_g, 19.44, 1.0e-9
      assert "nutrition.hunger" in tags(b18)
      b19 = eat.(b18, 1)
      assert_in_delta b19.protein_g, 20.52, 1.0e-9
      assert tags(b19) == ["nervous.daze", "recovery.weakness"]
    end
  end
end
