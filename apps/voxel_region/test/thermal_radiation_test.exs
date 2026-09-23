defmodule VoxelRegion.ThermalRadiationTest do
  @moduledoc "只测试：灰体辐射内核项与视线合成；期望来自斯特藩-玻尔兹曼手算，不复用被测算法。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{ThermalNative, ThermalRadiation}

  # 手算：底面绝热、5 个暴露面的燃烧格，P = hA(T−Ta) + εσA(T⁴−Ta⁴)。
  # h=10、A=5、ε=0.9、P=600 kW、Ta=293.15 K：T=1214.85 K 时
  # 线性项 50×921.70 = 46 085 W，辐射项 0.9×5.670374e-8×5×(2.178164e12−7.385e9) = 553 915 W，合计 600 000 W。
  # 无辐射时同一格的线性平衡为 293.15 + 600000/50 = 12 293 K。
  test "孤立燃烧格的辐射平衡温度等于斯特藩-玻尔兹曼手算值，环境账等于供能减储热" do
    capacity = 16_380.0
    node = {293.15, 100.0, 100.0, capacity, 2.0, 1.0e6, 5.0, 600_000.0, 1.0e12, true}
    {done, [{t, _, _}], supplied, environment} =
      ThermalNative.advance([node], [], 293.15, 10.0, 1.0, 300.0, {[], [{0, 0.9 * 5.0}]})
    assert done == 300.0
    assert_in_delta t, 1214.85, 0.01
    assert_in_delta supplied, 600_000.0 * 300.0, 1.0e-3
    assert_in_delta supplied + environment, capacity * (t - 293.15), 1.0e-3
  end

  # 手算：ε=0.8 的两块 1 m² 平行板，q = σA(T₁⁴−T₂⁴)/(2/ε−1) = 5.670374419e-8×(1e12−8.1e9)/1.5 = 37 496.3 W，
  # 0.05 s 内 1 874.81 J；热容 1e9 J/K 使温度几乎不变，显式一步即解析值。
  test "两块互见平行板按灰体平行板公式交换，交换反对称且不计入环境" do
    ordered = [{:a, %{}}, {:b, %{}}]
    sights = %{{0, 0, 0} => [{:a, {:b, {3, 0, 0}}, 1.0}], {3, 0, 0} => [{:b, {:a, {0, 0, 0}}, 1.0}]}
    assert {[{0, 1, w}, {1, 0, w}], []} = ThermalRadiation.terms(ordered, sights, 0.8)
    plate = fn t -> {t, 100.0, 100.0, 1.0e9, 1.0, 1.0e6, 1.0, 0.0, 0.0, true} end
    {0.05, [{a, _, _}, {b, _, _}], 0.0, 0.0} =
      ThermalNative.advance([plate.(1000.0), plate.(300.0)], [], 293.15, 0.0, 1.0, 0.05,
        ThermalRadiation.terms(ordered, sights, 0.8))
    assert_in_delta (1000.0 - a) * 1.0e9, 1874.81, 0.01
    assert_in_delta (b - 300.0) * 1.0e9, 1874.81, 0.01
  end

  test "视线伙伴不在本次节点集内按域边界绝热；未命中面按 ε×面积对天空" do
    ordered = [{:a, %{}}]
    sights = %{{0, 0, 0} => [{:a, {:far, {5, 0, 0}}, 1.0}, {:a, :sky, 2.0}]}
    assert {[], [{0, sky}]} = ThermalRadiation.terms(ordered, sights, 0.9)
    assert_in_delta sky, 1.8, 1.0e-15
  end

  test "原生边界拒绝越界辐射索引和负面积" do
    node = {293.15, 100.0, 100.0, 1.0, 1.0, 1.0e6, 1.0, 0.0, 0.0, true}
    assert_raise ArgumentError, fn -> ThermalNative.advance([node], [], 293.15, 0.0, 1.0, 0.05, {[{0, 1, 1.0}], []}) end
    assert_raise ArgumentError, fn -> ThermalNative.advance([node], [], 293.15, 0.0, 1.0, 0.05, {[], [{0, -1.0}]}) end
  end
end
