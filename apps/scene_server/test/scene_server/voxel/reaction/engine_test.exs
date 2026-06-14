defmodule SceneServer.Voxel.Reaction.EngineTest do
  # 功能完善 · 反应层 R1:纯规则引擎(数据化阈值相变,行为无关)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Reaction.{Engine, Rule, Rules}

  defp ice_id, do: MaterialCatalog.material_id(:ice)
  defp water_id, do: MaterialCatalog.material_id(:water)
  defp stone_id, do: MaterialCatalog.material_id(:stone)

  defp cell(material_id, temp, macro_index \\ 0) do
    %{macro_index: macro_index, material_id: material_id, temperature_celsius: temp, tags: []}
  end

  describe "Rule.new!/1 校验" do
    test "合法相变规则构造成功" do
      rule =
        Rule.new!(
          id: :demo,
          kind: :phase_transition,
          from_material: :ice,
          condition: {:temperature, :gte, {:material_threshold, "melting_point"}},
          to_material: :water
        )

      assert rule.kind == :phase_transition
      assert rule.from_material == :ice
    end

    test "拒绝非法材料名" do
      assert_raise ArgumentError, ~r/from_material 非法材料名/, fn ->
        Rule.new!(
          id: :bad,
          kind: :phase_transition,
          from_material: :unobtanium,
          condition: {:temperature, :gte, {:celsius, 0}},
          to_material: :water
        )
      end
    end

    test "拒绝非法条件" do
      assert_raise ArgumentError, ~r/非法 condition/, fn ->
        Rule.new!(
          id: :bad,
          kind: :phase_transition,
          from_material: :ice,
          condition: {:pressure, :gt, {:celsius, 0}},
          to_material: :water
        )
      end
    end

    test "拒绝非法算子" do
      assert_raise ArgumentError, fn ->
        Rule.new!(
          id: :bad,
          kind: :phase_transition,
          from_material: :ice,
          condition: {:temperature, :approx, {:celsius, 0}},
          to_material: :water
        )
      end
    end
  end

  describe "Engine.evaluate/2 相变" do
    test "冰在 ≥ melting_point(0℃)熔化为水" do
      effects = Engine.evaluate([cell(ice_id(), 5.0)], Rules.all())

      assert [{:transform_material, eff}] = effects
      assert eff.from_material_id == ice_id()
      assert eff.to_material_id == water_id()
      assert eff.rule_id == :ice_melts
      assert eff.macro_index == 0
    end

    test "冰在 melting_point 边界(恰 0℃,gte)熔化" do
      assert [{:transform_material, _}] = Engine.evaluate([cell(ice_id(), 0.0)], Rules.all())
    end

    test "冰低于 melting_point(-1℃)不熔化" do
      assert [] = Engine.evaluate([cell(ice_id(), -1.0)], Rules.all())
    end

    test "非冰材料(石)不被冰规则触发" do
      assert [] = Engine.evaluate([cell(stone_id(), 500.0)], Rules.all())
    end

    test "水不再被冰熔化规则触发(转变后稳定,不抖动)" do
      assert [] = Engine.evaluate([cell(water_id(), 50.0)], Rules.all())
    end

    test "多 cell 各自独立求值,保输入序" do
      cells = [cell(ice_id(), 10.0, 1), cell(stone_id(), 10.0, 2), cell(ice_id(), -5.0, 3)]
      effects = Engine.evaluate(cells, Rules.all())

      assert [{:transform_material, eff}] = effects
      assert eff.macro_index == 1
    end
  end

  describe "Engine 阈值解析" do
    test "字面摄氏度阈值" do
      rule =
        Rule.new!(
          id: :hot,
          kind: :phase_transition,
          from_material: :stone,
          condition: {:temperature, :gte, {:celsius, 1200.0}},
          to_material: :iron
        )

      assert [] = Engine.evaluate([cell(stone_id(), 1199.0)], [rule])
      assert [{:transform_material, _}] = Engine.evaluate([cell(stone_id(), 1200.0)], [rule])
    end

    test "material_threshold 按 cell 的 from 材料解析(冰 melting=0)" do
      # 同一规则、不同温度边界,验证阈值来自 MaterialCatalog 冰的 melting_point=0。
      assert [] = Engine.evaluate([cell(ice_id(), -0.01)], Rules.all())
      assert [{:transform_material, _}] = Engine.evaluate([cell(ice_id(), 0.01)], Rules.all())
    end

    test "lte 算子(冷却向)" do
      rule =
        Rule.new!(
          id: :freeze,
          kind: :phase_transition,
          from_material: :water,
          condition: {:temperature, :lte, {:material_threshold, "freezing_point"}},
          to_material: :ice
        )

      assert [{:transform_material, eff}] = Engine.evaluate([cell(water_id(), -1.0)], [rule])
      assert eff.to_material_id == ice_id()
      assert [] = Engine.evaluate([cell(water_id(), 1.0)], [rule])
    end
  end

  describe "Rules 表" do
    test "for_material 过滤相变规则" do
      assert [%Rule{id: :ice_melts}] = Rules.for_material(:ice)
      assert [] = Rules.for_material(:stone)
    end

    test "每条规则材料名均合法(数据完整性)" do
      for rule <- Rules.all() do
        assert MaterialCatalog.material_id(rule.from_material)
        assert MaterialCatalog.material_id(rule.to_material)
      end
    end
  end
end
