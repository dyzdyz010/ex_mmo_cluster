defmodule VoxelRegion.PhaseSettlementTest do
  @moduledoc "只测试：相变结算的有限供能、广延量守恒和材料身份边界。"
  use ExUnit.Case, async: true
  alias VoxelRegion.Phase

  defp materials do
    Map.new([{20, 21, 10.0, 80.0}, {21, 20, 20.0, 40.0}], fn {id, peer, heat, hp} ->
      {id,
       %{
         "phase_peer_material_id" => peer,
         "phase_transition_kelvin" => 273.0,
         "latent_heat_per_macro_j" => 100.0,
         "heat_capacity_per_macro" => heat,
         "max_hp_per_macro" => hp
       }}
    end)
    |> Map.put(0, %{})
  end

  test "舀取和混合库存倒回守恒焓和损伤，不用环境温度重置库存" do
    cell = {120.0, 60.0}
    inventory = {-20.0, 10.0}
    {next_cell, next_inventory} = Phase.transfer(cell, inventory, 100, 25, :scoop)
    assert next_cell == {90.0, 45.0}
    assert next_inventory == {10.0, 25.0}
    # 库存混合后倒回全部，原格加原库存的焓/完整度仍守恒。
    {final_cell, empty} = Phase.transfer(next_cell, next_inventory, 50, 50, :pour)
    assert final_cell == {100.0, 70.0}
    assert empty == {0.0, 0.0}
  end

  test "工具加热精确抵达潜热终点，多付能量只进未用账，冷却同样守恒" do
    heat = %{"action" => "phase.heat", "heat_energy_j" => 100.0}
    hot = Phase.tool_energy(-13.1, 0.25, materials()[20], heat)
    assert hot.energy == 25.0
    assert_in_delta hot.supplied_j, 38.1, 1.0e-12
    assert_in_delta hot.paid_j, hot.supplied_j + hot.unused_j, 1.0e-12
    assert Phase.material(20, hot.energy, 0.25, materials()) == 21

    cool =
      Phase.tool_energy(hot.energy, 0.25, materials()[21], %{
        "action" => "phase.cool",
        "cooling_energy_j" => 10.0
      })

    assert cool == %{energy: 15.0, supplied_j: -10.0, paid_j: 10.0, unused_j: 0.0}
    assert Phase.material(21, cool.energy, 0.25, materials()) == 21
  end

  test "部分格重新凝固按携带完整度恢复 HP，不修复损伤或改变身份字段" do
    row = %{material: 20, hp: 80.0, max_hp: 80.0, incarnation: 7, seq: 9}
    restored = Phase.restore(row, {-5.0, 10.0}, 25, 100, materials())
    assert restored.max_hp == 20.0
    assert restored.hp == 8.0
    assert restored.phase_energy_j == -5.0
    assert restored.temperature_kelvin == 271.0
    assert restored.incarnation == 7 and restored.seq == 9
  end

  test "只给新作者格初始化环境焓，运输值优先，清空不求零体积温度" do
    context = %{materials: materials(), capacity: 100, ambient: 283.0, material: 21}

    current = %{
      authored: {0, {0.0, 0.0}},
      moved: {0, {0.0, 0.0}},
      frozen: {21, {0.0, 10.0}},
      empty: {21, {3.0, 2.0}}
    }

    {edits, values} =
      Phase.settle(
        %{authored: 25, moved: 25, frozen: 25, empty: 0},
        current,
        %{moved: {12.0, 8.0}},
        context
      )

    assert Map.new(edits) == %{authored: 21, moved: 21, frozen: 20, empty: 0}
    assert values.authored == {75.0, 25.0}
    assert values.moved == {12.0, 8.0}
    assert values.frozen == {0.0, 10.0}
  end

  test "净数量不变的中间格仍提交两阶段搬运的焓与完整度" do
    values = %{a: {100.0, 100.0}, b: {0.0, 50.0}}
    water = %{a: 100, b: 100}
    stages = [{water, [{:a, :b, 25}]}, {%{a: 75, b: 125}, [{:b, :c, 25}]}]
    {changes, transported} = Phase.transport_stages(values, water, %{a: 75, c: 25}, stages)
    assert changes == %{a: 75, b: 100, c: 25}
    assert transported == %{a: {75.0, 75.0}, b: {20.0, 60.0}, c: {5.0, 15.0}}
    assert Enum.sum(for {_, {e, _}} <- transported, do: e) == 100.0
    assert Enum.sum(for {_, {_, i}} <- transported, do: i) == 150.0
  end
end
