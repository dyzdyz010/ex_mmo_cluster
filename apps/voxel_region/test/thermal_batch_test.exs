defmodule VoxelRegion.ThermalBatchTest do
  @moduledoc "只测试：整批等价于旧 50ms 分段，事件保留 World 的结算边界。"
  use ExUnit.Case, async: true
  alias VoxelRegion.ThermalNative

  test "半秒批与旧十次分段的每节点温度 HP 余能及总热账相等" do
    nodes = [
      {400.0, 100.0, 100.0, 1.0, 1.0, 310.0, 1.0, 20.0, 4.0, true},
      {300.0, 80.0, 100.0, 2.0, 1.0, 310.0, 1.0, -5.0, 2.0, true}
    ]
    contacts = [{0, 1, 0.2}]
    {done, result, supplied, environment} =
      ThermalNative.advance(nodes, contacts, 293.15, 15.0, 0.01, 0.5)

    # 旧入口每次都只收到 50ms，稳定步不能用整批时长重新均分。
    {reference, old_supplied, old_environment} =
      Enum.reduce(1..10, {nodes, 0.0, 0.0}, fn _, {input, q, air} ->
        {step, output, dq, da} =
          ThermalNative.advance(input, contacts, 293.15, 15.0, 0.01, 0.05)
        assert_in_delta step, 0.05, 1.0e-12
        input = Enum.zip_with(input, output, fn n, {t, hp, remaining} ->
          n |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, remaining)
        end)
        {input, q + dq, air + da}
      end)

    assert_in_delta done, 0.5, 1.0e-12
    for {n, {t, hp, remaining}} <- Enum.zip(reference, result) do
      for {a, b} <- [{elem(n, 0), t}, {elem(n, 1), hp}, {elem(n, 8), remaining}] do
        assert_in_delta a, b, max(abs(a), 1.0) * 1.0e-12
      end
    end
    assert_in_delta supplied, old_supplied, max(abs(old_supplied), 1.0) * 1.0e-12
    assert_in_delta environment, old_environment, abs(old_environment) * 1.0e-12
  end

  test "点燃 相变 共享HP损伤和归零事件在原段末交还 World" do
    node = {400.0, 100.0, 100.0, 1000.0, 1.0, 310.0, 0.0, 0.0, 0.0, true}
    for control <- [{399.0, nil, false}, {nil, {400.0, true}, false}, {nil, nil, true}] do
      {done, result, _, _} = ThermalNative.advance([{node, control}], [], 293.15, 0.0, 0.01, 0.5)
      {old_done, old_result, _, _} = ThermalNative.advance([node], [], 293.15, 0.0, 0.01, 0.05)
      assert done == old_done
      assert result == old_result
    end
    dying = put_elem(node, 1, 0.001)
    assert {0.05, [{400.0, 0.0, 0.0}], 0.0, 0.0} =
      ThermalNative.advance([{dying, {nil, nil, false}}], [], 293.15, 0.0, 0.01, 0.5)
  end

  test "未到点燃或损伤阈值的共享节点不打断批次" do
    node = {300.0, 100.0, 100.0, 1000.0, 1.0, 310.0, 0.0, 0.0, 0.0, true}
    {done, _, _, _} = ThermalNative.advance([{node, {400.0, {273.15, true}, true}}], [], 293.15, 0.0, 0.01, 0.5)
    assert_in_delta done, 0.5, 1.0e-12
  end

  test "液体降温或固体升温跨入潜热区时在当前段交还" do
    for {temperature, power, transition, liquid} <-
          [{300.0, -100.0, 299.0, true}, {300.0, 100.0, 301.0, false}] do
      node = {temperature, 100.0, 100.0, 1.0, 1.0, 1000.0, 0.0, power, 50.0, true}
      {done, rows, _, _} = ThermalNative.advance(
        [{node, {nil, {transition, liquid}, false}}], [], 293.15, 0.0, 0.01, 0.5)
      {_, expected, _, _} = ThermalNative.advance([node], [], 293.15, 0.0, 0.01, 0.05)
      assert done == 0.05
      assert rows == expected
    end
  end
end
