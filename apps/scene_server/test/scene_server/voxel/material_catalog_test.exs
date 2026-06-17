defmodule SceneServer.Voxel.MaterialCatalogTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MaterialCatalog

  test "power block material is append-only and electrically active" do
    material_id = MaterialCatalog.power_source_material_id()

    assert material_id == 6
    assert MaterialCatalog.power_source_material?(material_id)
    assert MaterialCatalog.default_attribute_value(material_id, "electric_conductivity", 0) > 0

    assert MaterialCatalog.default_attribute_value(material_id, "dielectric_strength", 65_536) ==
             0
  end

  test "power block declares bounded default supply policy" do
    assert MaterialCatalog.power_source_defaults() == %{
             output_mode: :dc,
             voltage: 120.0,
             current_limit_amps: 20.0,
             energy_budget_joules: 20_000.0
           }
  end

  test "load block material is append-only and electrically conductive" do
    material_id = MaterialCatalog.electric_load_material_id()

    assert material_id == 7
    assert MaterialCatalog.electric_load_material?(material_id)
    assert MaterialCatalog.default_attribute_value(material_id, "electric_conductivity", 0) > 0
  end

  describe "S4 化学/氧化:iron 起锈门 + rust 终产物(属性派生,无白名单)" do
    @inert_temperature_raw 327_680_000

    test "iron 配可达起锈温度门(常温即氧化),非哨兵" do
      iron = MaterialCatalog.material_id(:iron)
      # 0℃ raw=0:常温 20℃ ≥ 0℃ → 起锈;远低于惰性哨兵 5000℃。
      assert MaterialCatalog.default_attribute_value(iron, "oxidation_temperature", @inert_temperature_raw) ==
               0
    end

    test "rust 是 append-only 终产物:不导电(锈断路)、起锈门=哨兵(不再氧化)" do
      rust = MaterialCatalog.material_id(:rust)
      assert rust == 12
      assert MaterialCatalog.known_material?(rust)
      # 锈不导电 → 涉 iron 电路生锈即自然断路(化学×电磁涌现)。
      assert MaterialCatalog.default_attribute_value(rust, "electric_conductivity", 0) == 0
      # 终产物惰性:起锈门=哨兵不可达 → 不再氧化(同 ash ignition inert)。
      assert MaterialCatalog.default_attribute_value(rust, "oxidation_temperature", 0) ==
               @inert_temperature_raw
    end

    test "非铁材料未配起锈门(回退哨兵)——氧化 recipe 靠 material:iron 过滤,不评估它们" do
      for name <- [:stone, :wood, :water, :ash] do
        id = MaterialCatalog.material_id(name)
        # 未配 oxidation_temperature → 回退传入哨兵;氧化规则带 material:iron 过滤故根本不评估它们。
        assert MaterialCatalog.default_attribute_value(id, "oxidation_temperature", @inert_temperature_raw) ==
                 @inert_temperature_raw
      end
    end
  end

  describe "M5 形态轨:ember 热源材料(表面元件火炬借其属性向量)" do
    test "ember append-only(id13)且 heat_output>0(稳定热源)" do
      ember = MaterialCatalog.material_id(:ember)
      assert ember == 13
      assert MaterialCatalog.known_material?(ember)
      assert MaterialCatalog.default_attribute_value(ember, "heat_output", 0) > 0
      # 惰性:不导电、不可燃(ignition 哨兵)。
      assert MaterialCatalog.default_attribute_value(ember, "electric_conductivity", 0) == 0
    end

    test "非热源材料 heat_output 回退 0(惰性安全)" do
      for name <- [:stone, :iron, :rust, :water] do
        id = MaterialCatalog.material_id(name)
        assert MaterialCatalog.default_attribute_value(id, "heat_output", 0) == 0
      end
    end
  end
end
