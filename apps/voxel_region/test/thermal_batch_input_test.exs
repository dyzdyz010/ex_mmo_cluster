defmodule VoxelRegion.ThermalBatchInputTest do
  @moduledoc "只测试：当次权威摘要到热内核输入的有限预算与事件契约。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{Combustion, ThermalBatch}

  test "共同批次止于最早有限源或燃料端点，预算按实际批长计算" do
    {key, n, t, volume} = sample()
    burner = Map.merge(t, %{burning: true, remaining_fuel_j: 0.5, power_w: 10.0})
    sources = %{n.cell => %{remaining_j: 2.0, power_w: 20.0}}

    batch =
      ThermalBatch.prepare(
        [{key, n, burner, volume}],
        sources,
        %{key => -5.0},
        MapSet.new(),
        %{"ambient_kelvin" => 293.15},
        0.5
      )

    assert_in_delta batch.duration, 0.05, 1.0e-12
    assert [{input, {nil, nil, false}}] = batch.input
    assert elem(input, 7) == 25.0
    assert elem(input, 8) == 1.25
    assert elem(input, 9)
    assert [{_, _, ^burner, 293.15, -5.0, 10.0}] = batch.targets

    batch = ThermalBatch.prepare([{key, n, t, volume}], sources, %{}, MapSet.new(), %{"ambient_kelvin" => 293.15}, 0.5)
    assert batch.duration == 0.1
    assert elem(elem(hd(batch.input), 0), 8) == 2.0
  end

  test "有符号冷功率保持正的有限能量上限，读取当前 HP 温度而非缓存默认值" do
    {key, n, t, _} = sample()
    t = Map.merge(t, %{temperature_kelvin: 280.0, hp: 7.0})

    batch =
      ThermalBatch.prepare([{key, n, t, nil}], %{}, %{key => -12.0}, MapSet.new(), %{"ambient_kelvin" => 293.15}, 0.5)

    assert [{input, _}] = batch.input
    assert {elem(input, 0), elem(input, 1), elem(input, 2)} == {280.0, 7.0, 100.0}
    assert {elem(input, 7), elem(input, 8), elem(input, 9)} == {-12.0, 6.0, true}
    assert batch.duration == 0.5
  end

  test "耗尽、已燃和已损毁节点不再请求点燃；无燃料记录仍可首次点燃" do
    {key, n, t, _} = sample()
    refute Combustion.exhausted?(t)
    assert Combustion.exhausted?(%{remaining_fuel_j: 1.0e-9})
    refute Combustion.exhausted?(%{remaining_fuel_j: 2.0e-9})

    for {row, expected} <- [
          {t, 300.0},
          {Map.put(t, :remaining_fuel_j, 0.0), nil},
          {%{t | hp: 0.0}, nil},
          {Map.merge(t, %{burning: true, remaining_fuel_j: 5.0, power_w: 1.0}), nil}
        ] do
      batch = ThermalBatch.prepare([{key, n, row, nil}], %{}, %{}, MapSet.new(), %{"ambient_kelvin" => 293.15}, 0.5)
      assert [{_, {^expected, nil, false}}] = batch.input
    end
  end

  test "相变输入按真实体积和已存焓，不从温度重构覆盖潜热" do
    {key, n, t, _} = sample()
    t = Map.merge(t, %{material: 21, phase_energy_j: 12.0, temperature_kelvin: 273.15})

    material =
      Map.merge(n.material, %{
        "phase_transition_kelvin" => 273.15,
        "latent_heat_per_macro_j" => 1000.0
      })

    n = %{n | material: material, ignition: nil}
    batch = ThermalBatch.prepare([{key, n, t, 0.25}], %{}, %{}, MapSet.new([n.cell]), %{"ambient_kelvin" => 293.15}, 0.5)
    assert [{input, {nil, {12.0, 0.25, 273.15, 250.0, 100.0, true}, false}}] = batch.input
    assert elem(input, 9)
  end

  test "微格及附件不吃同宏格热源，保留共享 HP 标记与原顺序" do
    {key, n, t, _} = sample()
    fine = %{t | granularity: 1}
    attachment = %{t | granularity: 4}
    sources = %{n.cell => %{remaining_j: 100.0, power_w: 20.0}}

    batch =
      ThermalBatch.prepare(
        [{key, n, fine, nil}, {key, n, attachment, nil}],
        sources,
        %{},
        MapSet.new(),
        %{"ambient_kelvin" => 293.15},
        0.5
      )

    assert Enum.map(batch.targets, fn {_, _, row, _, _, _} -> row.granularity end) == [1, 4]

    assert Enum.all?(batch.input, fn {input, {_, nil, shared}} ->
             elem(input, 7) == 0.0 and not elem(input, 9) and shared
           end)
  end

  defp sample do
    cell = {63, 0, 0}
    key = {0, {504, 0, 0}}
    t = %{granularity: 0, material: 19, hp: 100.0, max_hp: 100.0}

    material = %{
      "thermal_conductivity" => 1.0,
      "heat_resistance_kelvin" => 1000.0,
      "heat_capacity_per_macro" => 100.0
    }

    n = %{
      cell: cell,
      cells: [cell],
      material: material,
      capacity: 100.0,
      exposed_faces: 6.0,
      ignition: 300.0
    }

    {key, n, t, nil}
  end
end
