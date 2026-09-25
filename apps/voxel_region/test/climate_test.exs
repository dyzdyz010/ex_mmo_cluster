defmodule VoxelRegion.ClimateTest do
  @moduledoc """
  只测试：气候查询唯一入口 `VoxelRegion.Climate`（首个提供者 = 热环境资产的静态气候区）。
  期望手算：闭矩形边界、列表在前者优先、区外 / 无字段返回全局环境温度与风速 0（原值原样返回，不做类型转换）。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.Climate

  @zones [%{"min" => [-10, 0], "max" => [-1, 20], "ambient_kelvin" => 248.15, "wind_mps" => 5.0},
          %{"min" => [-5, 5], "max" => [5, 5], "ambient_kelvin" => 263.15}]
  defp zoned, do: %{"ambient_kelvin" => 293.15, "climate_zones" => @zones}

  test "按格 x/z 闭矩形取空气温度与风速，全高；重叠处列表在前者优先；区内缺省风速 0" do
    assert Climate.at(zoned(), {-10, 0, 0}) == %{air_k: 248.15, wind_mps: 5.0}
    assert Climate.at(zoned(), {-1, -500, 20}) == %{air_k: 248.15, wind_mps: 5.0}
    assert Climate.at(zoned(), {-3, 7, 5}) == %{air_k: 248.15, wind_mps: 5.0}
    assert Climate.at(zoned(), {0, 7, 5}) == %{air_k: 263.15, wind_mps: 0}
    assert Climate.at(zoned(), {5, 7, 5}) == %{air_k: 263.15, wind_mps: 0}
    assert Climate.air_k(zoned(), {-3, 7, 5}) == 248.15
    assert Climate.region(zoned(), {-3, 0, 5}) == 0
    assert Climate.region(zoned(), {0, 0, 5}) == 1
  end

  test "区外与无气候区：返回全局 ambient_kelvin 原值（整数仍是整数）与风速 0，分区为 nil" do
    for cell <- [{0, 7, 6}, {-11, 0, 0}, {-1, 0, 21}],
        do: assert(Climate.at(zoned(), cell) == %{air_k: 293.15, wind_mps: 0})

    for config <- [%{"ambient_kelvin" => 293.15}, %{"ambient_kelvin" => 293.15, "climate_zones" => []}] do
      assert Climate.at(config, {-3, 0, 5}) == %{air_k: 293.15, wind_mps: 0}
      assert Climate.region(config, {-3, 0, 5}) == nil
      refute Climate.zoned?(config)
    end

    assert Climate.air_k(%{"ambient_kelvin" => 293}, {0, 0, 0}) === 293
  end

  test "字段校验：整数闭矩形 min ≤ max、正区温、可选非负风速；缺省合法" do
    assert Climate.valid?(%{})
    assert Climate.valid?(zoned())
    zone = %{"min" => [0, 0], "max" => [1, 0], "ambient_kelvin" => 250}
    assert Climate.valid?(%{"climate_zones" => [Map.put(zone, "wind_mps", 0)]})
    refute Climate.valid?(%{"climate_zones" => [Map.put(zone, "wind_mps", -1.0)]})
    refute Climate.valid?(%{"climate_zones" => [Map.put(zone, "wind_mps", "5")]})
    refute Climate.valid?(%{"climate_zones" => [%{zone | "min" => [2, 0]}]})
    refute Climate.valid?(%{"climate_zones" => [%{zone | "min" => [0.5, 0]}]})
    refute Climate.valid?(%{"climate_zones" => [%{zone | "ambient_kelvin" => 0}]})
    refute Climate.valid?(%{"climate_zones" => %{}})
  end
end
