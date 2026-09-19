defmodule VoxelRegion.ThermalGeometryInputTest do
  @moduledoc "只测试：canonical 热几何只消费冻结采样值，不访问 World 或读取回调。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{ThermalGeometry, ThermalAttachments, Combustion, Phase}

  @material %{"heat_capacity_per_macro" => 1000.0, "thermal_conductivity" => 10.0}

  test "固体与非热宿主共面，空气采样与缺失采样不混同" do
    target = %{micro: {0, 0, 0}, granularity: 0, owner: {0, 0}, incarnation: 1, material: 19}
    faces = ThermalGeometry.faces({0, 0, 0}, %{})
    points = ThermalGeometry.points(faces)
    samples = Map.new(points, &{&1, nil})
      |> Map.put({0, 0, 0}, {target, 1.0})
      |> Map.put({8, 0, 0}, {%{target | micro: {8, 0, 0}, material: 11}, 1.0})
    [{_, node}] = ThermalGeometry.cell(faces, %{19 => @material, 11 => %{}}, samples)
    assert node.capacity == 1000.0
    assert node.exposed_faces == 5.0
    assert node.contacts == []
    assert_raise KeyError, fn -> ThermalGeometry.cell(faces, %{19 => @material, 11 => %{}}, Map.delete(samples, {-8, 0, 0})) end
  end

  test "附件只请求唯一宿主点；空摘要可直接计算且不读取任何世界" do
    slots = %{{0, 1, {0, 0, 0}} => {1, 19}, {1, 0, {0, 0, 0}} => {2, 19}}
    points = ThermalAttachments.points(slots, %{materials: %{19 => @material}})
    assert length(points) == MapSet.size(MapSet.new(points))
    assert MapSet.new(points) == MapSet.new(Enum.flat_map(Map.keys(slots), &VoxelRegion.Attachments.neighbors/1))
    assert ThermalAttachments.points(slots, %{materials: %{19 => %{}}}) == []
    assert {%{}, _} = ThermalAttachments.add(%{}, %{}, %{materials: %{}, attachments: %{}}, %{}, nil)
  end

  test "回收只按剩余燃料向下取整，未燃材料不要求燃料目录" do
    wood = %{"fuel_energy_per_macro_j" => 100.0}
    assert Combustion.recover_units(%{}, %{}, nil, 512) == 512
    assert Combustion.recover_units(%{remaining_fuel_j: 20.0}, wood, 0.5, 256) == 102
    assert Combustion.recover_units(%{remaining_fuel_j: 0.0}, wood, 0.5, 256) == 0
  end

  test "固体建造复用相变库存取出规则，损伤与负焓完整守恒" do
    {placed, remaining} = Phase.transfer({0.0, 0.0}, {-50.0, 75.0}, 100, 40, :pour)
    assert placed == {-20.0, 30.0}
    assert remaining == {-30.0, 45.0}
  end
end
