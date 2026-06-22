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
      assert MaterialCatalog.default_attribute_value(
               iron,
               "oxidation_temperature",
               @inert_temperature_raw
             ) ==
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
        assert MaterialCatalog.default_attribute_value(
                 id,
                 "oxidation_temperature",
                 @inert_temperature_raw
               ) ==
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

  describe "化学扩展:熔化产物 + 多反应物产物(append-only id14/15/16)" do
    @inert_temperature_raw 327_680_000
    @absolute_zero_raw -17_904_824
    @fixed32_scale 65_536

    test "molten_iron(id14):液态产物,可回凝铁、惰性不锈、仍导电" do
      molten = MaterialCatalog.material_id(:molten_iron)
      assert molten == 14
      assert MaterialCatalog.known_material?(molten)
      # 已是液态:不再熔(melting 哨兵);降温 <1538℃ 回凝铁(freezing_point=1538)。
      assert MaterialCatalog.default_attribute_value(molten, "melting_point", 0) ==
               @inert_temperature_raw

      assert MaterialCatalog.default_attribute_value(molten, "freezing_point", 0) ==
               round(1_538.0 * @fixed32_scale)

      # 液态金属仍导电;惰性不锈(oxidation 哨兵)。
      assert MaterialCatalog.default_attribute_value(molten, "electric_conductivity", 0) > 0

      assert MaterialCatalog.default_attribute_value(molten, "oxidation_temperature", 0) ==
               @inert_temperature_raw
    end

    test "lava(id15):液态产物,可回凝石、不导电" do
      lava = MaterialCatalog.material_id(:lava)
      assert lava == 15
      assert MaterialCatalog.known_material?(lava)

      assert MaterialCatalog.default_attribute_value(lava, "melting_point", 0) ==
               @inert_temperature_raw

      # 降温 <1200℃ 回凝石(= stone melting_point,迟滞)。
      assert MaterialCatalog.default_attribute_value(lava, "freezing_point", 0) ==
               round(1_200.0 * @fixed32_scale)

      assert MaterialCatalog.default_attribute_value(lava, "electric_conductivity", 0) == 0
    end

    test "obsidian(id16):惰性终产物(不相变、不导电、良介质)" do
      obsidian = MaterialCatalog.material_id(:obsidian)
      assert obsidian == 16
      assert MaterialCatalog.known_material?(obsidian)

      # 终产物:melting 哨兵不可达 + freezing 绝对零(不回相变,同 ash/rust 范式)。
      assert MaterialCatalog.default_attribute_value(obsidian, "melting_point", 0) ==
               @inert_temperature_raw

      assert MaterialCatalog.default_attribute_value(obsidian, "freezing_point", 0) ==
               @absolute_zero_raw

      assert MaterialCatalog.default_attribute_value(obsidian, "electric_conductivity", 0) == 0
      assert MaterialCatalog.default_attribute_value(obsidian, "dielectric_strength", 0) > 0
    end

    test "名 ↔ id 双向一致(material_name 反查)" do
      for {name, id} <- [molten_iron: 14, lava: 15, obsidian: 16] do
        assert MaterialCatalog.material_id(name) == id
        assert MaterialCatalog.material_name(id) == name
      end
    end
  end

  describe "光学正交系统:发光源 + 光敏元件 + 不透明度(属性派生)" do
    @fixed32_scale 65_536

    test "ember 配 light_emission>0(余烬自发光,LightKernel 当光源)" do
      ember = MaterialCatalog.material_id(:ember)
      assert MaterialCatalog.default_attribute_value(ember, "light_emission", 0) > 0
    end

    test "非光源材料 light_emission 回退 0(惰性安全)" do
      for name <- [:stone, :iron, :water, :dirt] do
        id = MaterialCatalog.material_id(name)
        assert MaterialCatalog.default_attribute_value(id, "light_emission", 0) == 0
      end
    end

    test "photo_sensor(id17):append-only 光敏材料,惰性、不导电" do
      sensor = MaterialCatalog.material_id(:photo_sensor)
      assert sensor == 17
      assert MaterialCatalog.known_material?(sensor)
      assert MaterialCatalog.material_name(17) == :photo_sensor
      assert MaterialCatalog.default_attribute_value(sensor, "electric_conductivity", 0) == 0
      # 不发光(它是 sensor 不是 source)。
      assert MaterialCatalog.default_attribute_value(sensor, "light_emission", 0) == 0
    end

    test "obsidian 半透光(显式低 opacity);未配 opacity 材料回退不透明默认" do
      obsidian = MaterialCatalog.material_id(:obsidian)
      # 玻璃半透:opacity < 1.0(default 不透明)。
      assert MaterialCatalog.default_attribute_value(
               obsidian,
               "opacity",
               round(1.0 * @fixed32_scale)
             ) <
               round(1.0 * @fixed32_scale)

      # stone 未配 → 回退传入默认(不透明)。
      stone = MaterialCatalog.material_id(:stone)

      assert MaterialCatalog.default_attribute_value(
               stone,
               "opacity",
               round(1.0 * @fixed32_scale)
             ) ==
               round(1.0 * @fixed32_scale)
    end
  end
end
