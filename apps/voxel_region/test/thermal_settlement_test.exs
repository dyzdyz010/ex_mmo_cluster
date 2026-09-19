defmodule VoxelRegion.ThermalSettlementTest do
  @moduledoc "只测试：热结果结算不依赖数据库、World 或部件注册。"
  use ExUnit.Case, async: true
  alias VoxelRegion.ThermalSettlement

  test "已完成时长只消耗对应有限源，真实 HP 损伤扣除采回基准" do
    cell = {1, 2, 3}

    row = %{
      granularity: 0,
      micro: {8, 16, 24},
      incarnation: 1,
      owner: {0, 0},
      material: 11,
      hp: 10.0,
      max_hp: 10.0,
      pick_baseline_hp: 8.0,
      temperature_kelvin: 300.0
    }

    source = %{remaining_j: 100.0, power_w: 10.0}
    config = %{"ambient_kelvin" => 300.0, "tolerance_kelvin" => 0.01}

    {[{_, changed}], sources, hot, losses, burned} =
      ThermalSettlement.apply(
        [{cell, [cell], row, 300.0, 0.0, 0.0}],
        [{301.0, 7.0, 0.0}],
        %{cell => source},
        config,
        2.0
      )

    assert sources[cell].remaining_j == 80.0
    assert changed.pick_baseline_hp == 5.0
    assert changed.hp == 7.0
    assert hot == [cell]
    assert losses == %{}
    assert burned == 0.0
  end
end
