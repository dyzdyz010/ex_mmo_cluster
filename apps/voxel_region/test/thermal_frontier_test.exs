defmodule VoxelRegion.ThermalFrontierTest do
  @moduledoc "只测试：提交内热域只扩张，冷却不能触发极小稳定步逐次回到 World。"
  use ExUnit.Case, async: true
  @moduletag :perf
  alias VoxelRegion.ThermalNative

  test "薄层在容差下冷却仍完成数值批次且热账闭合" do
    nodes = [{293.16001, 1.0, 1.0, 0.01, 1.0, 1000.0, 1.0, 0.0, 0.0, true}]
    {done, [{temperature, 1.0, 0.0}], 0.0, environment} =
      ThermalNative.advance(nodes, [], 293.15, 10.0, 0.01, 0.05, {[], []})
    assert_in_delta done, 0.05, 1.0e-12
    assert temperature >= 293.15
    assert temperature < 293.16
    assert_in_delta (temperature - 293.16001) * 0.01, environment, 1.0e-12
  end

  test "邻接冷域首次越阈值仍立即返回，不能等批末才扩张" do
    hot = {400.0, 1.0, 1.0, 0.01, 1.0, 1000.0, 0.0, 0.0, 0.0, true}
    cold = {293.15, 1.0, 1.0, 0.01, 1.0, 1000.0, 0.0, 0.0, 0.0, false}
    {done, [{a, _, _}, {b, _, _}], 0.0, 0.0} =
      ThermalNative.advance([hot, cold], [{0, 1, 10.0}], 293.15, 0.0, 0.01, 0.05, {[], []})
    assert done < 0.05
    assert b > 293.16
    assert_in_delta a + b, 693.15, 1.0e-10
  end
end
