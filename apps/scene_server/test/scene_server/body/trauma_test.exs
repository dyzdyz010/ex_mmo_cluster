defmodule SceneServer.Body.TraumaTest do
  use ExUnit.Case, async: true
  alias SceneServer.Body

  # Test-only：纯值小例，参数是明确夹具，不是第二份正式目录。
  @impact %{depth: 0.2, protein_g: 2.0, heal_s: 100.0}

  test "部位外伤进入既有生命合成，重复受伤只叠实际缺损" do
    body = Body.trauma(Body.new(), :torso, @impact)
    assert Body.life(body) == 80
    assert Body.recoverable_life(body) == 20
    assert Enum.any?(Body.injuries(body), &(&1.tag == "trauma.mechanical.torso" and &1.part == :torso))
    assert Body.life(Body.trauma(body, :torso, @impact)) == 64
    assert Body.life(Body.new()) == 100
  end

  test "机械和热在同一循环功能相乘，不额外扣 HP" do
    body = %{Body.new() | burn_dose_s: 1.0, burn_age_s: Body.burn_onset_s()}
    assert Body.life(body) == 75
    assert Body.life(Body.trauma(body, :torso, @impact)) == 60
  end

  test "外伤修复消耗组织蛋白与既有合成能，没有营养就停止" do
    body = Body.trauma(Body.new(), :legs, @impact)
    {healed, account} = Body.Repair.heal(body, 10.0, 1.0)
    # 初始循环 0.8，十秒进度 0.08，2 g × 0.08 = 0.16 g。
    assert_in_delta account.repair_protein_g, 0.16, 1.0e-9
    assert_in_delta account.synth_j, 1920.0, 1.0e-9
    assert_in_delta body.protein_g - healed.protein_g, 0.16, 1.0e-9
    assert Body.life(healed) == 82
    {stopped, stopped_account} = Body.Repair.heal(%{body | protein_g: 0.0}, 10.0, 1.0)
    assert stopped.traumas == body.traumas
    assert stopped_account.repair_protein_g == 0.0
  end
end
