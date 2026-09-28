defmodule SceneServer.Body.MovementTest do
  @moduledoc """
  分类：Test-only。冻伤移动系数的纯推导与真实 Repair 接缝。
  手算：浅 / 深初始损失 0.15 / 0.35；修复 25% 时损失减半，系数 0.925 / 0.825；
  修复 50% 起损失归零。这里不验证 Player、网络或客户端移动。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Repair

  test "未到冻伤剂量阈值时不减速" do
    assert Body.movement_factor(Body.new()) == 1.0
    assert Body.movement_factor(%{Body.new() | frost_dose_k_s: 299.0}) == 1.0
  end

  test "浅冻伤按修复进度恢复移动，半愈合起保持全速" do
    for {heal, expected} <- [{0.0, 0.85}, {0.25, 0.925}, {0.5, 1.0}, {1.0, 1.0}] do
      body = %{Body.new() | frost_dose_k_s: 300.0, frost_heal: heal}
      assert_in_delta Body.movement_factor(body), expected, 1.0e-12
    end
  end

  test "深冻伤只用当前严重度，不与浅冻伤叠乘，半愈合起保持全速" do
    for {heal, expected} <- [{0.0, 0.65}, {0.25, 0.825}, {0.5, 1.0}, {1.0, 1.0}] do
      body = %{Body.new() | frost_dose_k_s: 600.0, frost_heal: heal}
      assert_in_delta Body.movement_factor(body), expected, 1.0e-12
    end
  end

  test "浅冻伤修复到全速后继续冻结成深冻伤，归零的修复进度重新减速" do
    # 组织块 −10 °C：一步过冷剂量约 9.45 K·s，使 599 跨过深冻伤阈值 600。
    body = %{Body.new() | frost_dose_k_s: 599.0, frost_heal: 0.5, tissue_k: 263.15}
    assert Body.movement_factor(body) == 1.0

    {next, _account} = Repair.tick(body, 1.0, %{q_j: 0.0, air_k: 293.15}, 1.0)

    assert Body.severity(next, :frostbite) == 2
    assert next.frost_heal == 0.0
    assert_in_delta Body.movement_factor(next), 0.65, 1.0e-12
  end

  test "缺蛋白或两种能量储备都空时，修复不推进也不恢复移动" do
    frozen = %{Body.new() | frost_dose_k_s: 600.0, frost_heal: 0.25}

    for body <- [
          %{frozen | protein_g: 0.0},
          %{frozen | reserve_j: 0.0, fat_reserve_j: 0.0}
        ] do
      {next, account} = Repair.heal(body, 60.0, 1.0)

      assert next.frost_heal == 0.25
      assert account.repair_protein_g == 0.0
      assert account.synth_j == 0.0
      assert_in_delta Body.movement_factor(next), 0.825, 1.0e-12
    end
  end

  test "烧伤、虚弱与恍惚不额外减速，复活新身体恢复全速" do
    other_injuries = %{Body.revive() | burn_dose_s: 5.0, burn_age_s: 30.0}
    assert Body.movement_factor(other_injuries) == 1.0
    assert_in_delta Body.movement_factor(%{other_injuries | frost_dose_k_s: 300.0}), 0.85, 1.0e-12
    assert Body.movement_factor(Body.revive()) == 1.0
  end
end
