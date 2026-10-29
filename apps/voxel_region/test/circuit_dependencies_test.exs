defmodule VoxelRegion.CircuitDependenciesTest do
  @moduledoc "只测试：电路依赖发现复用的规范顶点、邻槽与接触资格；纯值输入，不启动World或数据库。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{Attachments, Circuit, ThermalGeometry}

  @environment %{"ambient_kelvin" => 293.15, "circuit_min_power_w" => 1.0}

  defp catalog do
    %{materials: %{
      24 => %{"electrical_conductivity" => 4.0, "thermal_conductivity" => 1.0},
      88 => %{"electrical_conductivity" => 20.0, "thermal_conductivity" => 1.0,
        "battery_volts_per_m" => 24.0, "battery_energy_per_macro_j" => 1.0e7}},
      attachments: %{"line_section_m2" => 0.125, "face_thickness_m" => 0.25}}
  end

  defp target(point, granularity, material),
    do: %{micro: point, granularity: granularity, material: material, owner: {0, 0}, incarnation: 0}

  test "六种规范槽顶点保持原线端点与面四角次序" do
    point = {-1, 2, -3}
    assert Attachments.vertices({1, 0, point}) == [point, {0, 2, -3}]
    assert Attachments.vertices({1, 1, point}) == [point, {-1, 3, -3}]
    assert Attachments.vertices({1, 2, point}) == [point, {-1, 2, -2}]
    assert Attachments.vertices({0, 0, point}) == [point, {-1, 3, -3}, {-1, 2, -2}, {-1, 3, -2}]
    assert Attachments.vertices({0, 1, point}) == [point, {0, 2, -3}, {-1, 2, -2}, {0, 2, -2}]
    assert Attachments.vertices({0, 2, point}) == [point, {0, 2, -3}, {-1, 3, -3}, {0, 3, -3}]
  end

  test "顶点准确关联六线十二面，负XYZ及页边界反查互逆" do
    expected = [
      {1, 0, {-1, 0, 0}}, {1, 0, {0, 0, 0}},
      {1, 1, {0, -1, 0}}, {1, 1, {0, 0, 0}},
      {1, 2, {0, 0, -1}}, {1, 2, {0, 0, 0}},
      {0, 0, {0, -1, -1}}, {0, 0, {0, -1, 0}}, {0, 0, {0, 0, -1}}, {0, 0, {0, 0, 0}},
      {0, 1, {-1, 0, -1}}, {0, 1, {-1, 0, 0}}, {0, 1, {0, 0, -1}}, {0, 1, {0, 0, 0}},
      {0, 2, {-1, -1, 0}}, {0, 2, {-1, 0, 0}}, {0, 2, {0, -1, 0}}, {0, 2, {0, 0, 0}}
    ]
    assert MapSet.new(Attachments.incident_slots({0, 0, 0})) == MapSet.new(expected)

    for point <- [{-513, 511, -1}, {-512, 512, 0}, {511, -1, 512}, {512, 0, -512}] do
      slots = Attachments.incident_slots(point)
      assert length(slots) == 18
      assert MapSet.size(MapSet.new(slots)) == 18
      for slot <- slots do
        assert point in Attachments.vertices(slot)
        for vertex <- Attachments.vertices(slot), do: assert(slot in Attachments.incident_slots(vertex))
      end
    end
  end

  test "prepare复用顶点后保留原面边前插与端点顺序" do
    point = {-1, 2, -3}
    line = Circuit.prepare(%{{1, 2, point} => {7, 24}}, %{}, catalog(), 0.5, @environment)
    assert Enum.map(line.edges, &{&1.a, &1.b, &1.r}) == [{{:point, point}, {:point, {-1, 2, -2}}, 0.25}]
    assert Circuit.points(line) == [{:point, point}, {:point, {-1, 2, -2}}]

    face = Circuit.prepare(%{{0, 0, point} => {8, 24}}, %{}, catalog(), 0.5, @environment)
    assert Enum.map(face.edges, &{&1.a, &1.b, &1.r}) == [
      {{:point, {-1, 2, -2}}, {:point, {-1, 3, -2}}, 2.0},
      {{:point, {-1, 3, -3}}, {:point, {-1, 3, -2}}, 2.0},
      {{:point, point}, {:point, {-1, 2, -2}}, 2.0},
      {{:point, point}, {:point, {-1, 3, -3}}, 2.0}
    ]
    assert Circuit.points(face) == [{:point, {-1, 2, -2}}, {:point, {-1, 3, -2}},
      {:point, {-1, 3, -3}}, {:point, point}]
  end

  test "无域与有域端点分开，显式nil持有者仍保留原三元身份" do
    point = {-512, 8, 0}
    assert Circuit.point(point) == {:point, point}
    assert Circuit.point(point, nil) == {:point, point, nil}
    assert Circuit.point(point, {:holder, :wild}) == {:point, point, {:holder, :wild}}
    input = Circuit.prepare(%{{1, 0, point} => {9, 24}}, %{}, catalog(), 0.5, @environment, fn _ -> nil end)
    assert Circuit.points(input) == [{:point, point, nil}, {:point, {-511, 8, 0}, nil}]
  end

  test "电池材料由目录决定，只准正负Y实体接触且不接附件宿主" do
    battery = target({0, 0, 0}, 0, 88)
    for {point, allowed} <- [{{0, 8, 0}, true}, {{0, -8, 0}, true}, {{8, 0, 0}, false},
        {{-8, 0, 0}, false}, {{0, 0, 8}, false}, {{0, 0, -8}, false}] do
      copper = target(point, 0, 24)
      assert Circuit.contact_allowed?(battery, copper, catalog()) == allowed
      assert Circuit.contact_allowed?(copper, battery, catalog()) == allowed
      assert Circuit.contact_allowed?(%{battery | material: 24}, copper, catalog())
    end
    assert Circuit.contact_allowed?(battery, target({0, 8, 0}, 1, 24), catalog())
    assert Circuit.contact_allowed?(battery, target({0, -1, 0}, 1, 24), catalog())
    refute Circuit.contact_allowed?(battery, target({8, 0, 0}, 1, 24), catalog())
    copper = target({0, 8, 0}, 0, 24)
    assert Circuit.conductors([battery, copper], catalog(), %{}, @environment) == [copper]
  end

  test "plan使用同一接触资格，电池侧边不进求解而Y边仍保留" do
    battery = target({0, 0, 0}, 0, 88)
    input = Circuit.prepare(%{}, %{}, catalog(), 0.5, @environment)
    side = Circuit.plan(input, %{}, [{battery, target({8, 0, 0}, 0, 24), 1.0}])
    assert side.edges == 0
    assert side.sources == %{}
    assert side.powers == %{}
    vertical = Circuit.plan(input, %{}, [{battery, target({0, 8, 0}, 0, 24), 1.0}])
    assert vertical.edges == 1
    assert vertical.sources[ThermalGeometry.key(battery)].stored_j == 0.0
    assert vertical.supplied_j == 0.0
  end
end
