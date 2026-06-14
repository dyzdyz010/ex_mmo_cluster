defmodule SceneServer.Voxel.Reaction.EngineTest do
  # 功能完善 · 反应层 R1:纯规则引擎(数据化阈值相变,行为无关)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Reaction.{Engine, Rule, Rules}

  defp ice_id, do: MaterialCatalog.material_id(:ice)
  defp water_id, do: MaterialCatalog.material_id(:water)
  defp stone_id, do: MaterialCatalog.material_id(:stone)
  defp steam_id, do: MaterialCatalog.material_id(:steam)

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

  describe "R4 温度相变族(freeze/boil + 0℃/100℃ 振荡防护)" do
    test "水低于 freezing_point(<0℃)冻成冰" do
      assert [{:transform_material, eff}] = Engine.evaluate([cell(water_id(), -1.0)], Rules.all())
      assert eff.from_material_id == water_id()
      assert eff.to_material_id == ice_id()
      assert eff.rule_id == :water_freezes
    end

    test "水恰 0℃ 不冻(严格 <,与冰熔 ≥0 错开防振荡)" do
      assert [] = Engine.evaluate([cell(water_id(), 0.0)], Rules.all())
    end

    test "水 ≥ boiling_point(100℃)沸成蒸汽" do
      assert [{:transform_material, eff}] =
               Engine.evaluate([cell(water_id(), 100.0)], Rules.all())

      assert eff.to_material_id == steam_id()
      assert eff.rule_id == :water_boils
    end

    test "水 99℃ 不沸" do
      assert [] = Engine.evaluate([cell(water_id(), 99.0)], Rules.all())
    end

    test "0℃ 无振荡:冰熔成水、水不回冻(同 tick 各自一次,稳定)" do
      cells = [cell(ice_id(), 0.0, 1), cell(water_id(), 0.0, 2)]
      effects = Engine.evaluate(cells, Rules.all())
      # 只有冰→水(macro 1);水(macro 2)在 0℃ 不动 → 不来回翻。
      assert [{:transform_material, eff}] = effects
      assert eff.macro_index == 1
      assert eff.to_material_id == water_id()
    end

    test "蒸汽稳定(暂无 condense 规则,不被任何规则触发)" do
      assert [] = Engine.evaluate([cell(steam_id(), 50.0)], Rules.all())
      assert [] = Engine.evaluate([cell(steam_id(), 150.0)], Rules.all())
    end

    test "water 的 for_material 返回冻结与沸腾两条" do
      ids = Rules.for_material(:water) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [:water_boils, :water_freezes]
    end
  end

  describe "R5a 燃烧(tag_reaction + 多效果物化)" do
    defp wood_id, do: MaterialCatalog.material_id(:wood)
    defp ash_id, do: MaterialCatalog.material_id(:ash)

    defp bcell(material_id, temp, opts \\ []) do
      %{
        macro_index: Keyword.get(opts, :macro_index, 0),
        material_id: material_id,
        temperature_celsius: temp,
        burn_progress: Keyword.get(opts, :burn_progress, 0.0),
        tags: Keyword.get(opts, :tags, [])
      }
    end

    test "ignite:木 ≥ ignition_temperature(300℃)且未燃 → 加 :burning" do
      effects = Engine.evaluate([bcell(wood_id(), 350.0)], Rules.all())
      assert {:set_tag, st} = Enum.find(effects, &match?({:set_tag, _}, &1))
      assert :burning in st.add
      assert st.remove == []
    end

    test "ignite:木 < ignition(200℃)不点燃" do
      assert [] = Engine.evaluate([bcell(wood_id(), 200.0)], Rules.all())
    end

    test "ignite:已 :burning 不重复点燃(forbid_tags)" do
      effects = Engine.evaluate([bcell(wood_id(), 350.0, tags: [:burning])], Rules.all())
      # 不应再产 add :burning(ignite forbid);但 burn 会产热+进度。
      refute Enum.any?(effects, fn
               {:set_tag, st} -> :burning in st.add
               _ -> false
             end)
    end

    test "ignite:惰性材料(石,ignition=5000℃ 不可达,且 1000<melting 1200 不熔)不点燃" do
      assert [] = Engine.evaluate([bcell(stone_id(), 1000.0)], Rules.all())
    end

    test "burn:燃烧中 → 注燃烧焦耳 + 推进 burn_progress(连续效果)" do
      effects =
        Engine.evaluate(
          [bcell(wood_id(), 500.0, tags: [:burning], burn_progress: 0.3)],
          Rules.all()
        )

      heat =
        Enum.find(effects, &match?({:write_voxel_attribute, %{heat_energy_joules: _}}, &1))

      assert {:write_voxel_attribute, %{attribute: :temperature, heat_energy_joules: j}} = heat
      assert j > 0

      advance =
        Enum.find(effects, fn
          {:write_voxel_attribute, %{attribute: "burn_progress", delta: _}} -> true
          _ -> false
        end)

      assert {:write_voxel_attribute, %{attribute: "burn_progress", delta: d}} = advance
      assert d > 0
    end

    test "burn_out:燃烧进度满 → 变 ash + 去 :burning" do
      effects =
        Engine.evaluate(
          [bcell(wood_id(), 500.0, tags: [:burning], burn_progress: 1.0)],
          Rules.all()
        )

      assert {:transform_material, t} =
               Enum.find(effects, &match?({:transform_material, _}, &1))

      assert t.to_material_id == ash_id()

      assert {:set_tag, st} = Enum.find(effects, &match?({:set_tag, _}, &1))
      assert :burning in st.remove
    end

    test "burn_out 未满(progress 0.5):只 burn 不 burn_out" do
      effects =
        Engine.evaluate(
          [bcell(wood_id(), 500.0, tags: [:burning], burn_progress: 0.5)],
          Rules.all()
        )

      refute Enum.any?(effects, &match?({:transform_material, _}, &1))
      assert Enum.any?(effects, &match?({:write_voxel_attribute, %{heat_energy_joules: _}}, &1))
    end

    test "ash 不复燃(ignition inert),不被任何规则触发" do
      assert [] = Engine.evaluate([bcell(ash_id(), 1000.0)], Rules.all())
    end
  end

  describe "Rules 表" do
    test "for_material 过滤相变规则" do
      assert [%Rule{id: :ice_melts}] = Rules.for_material(:ice)
      assert [] = Rules.for_material(:stone)
    end

    test "每条规则材料/效果引用均合法(数据完整性)" do
      for rule <- Rules.all() do
        case rule.kind do
          :phase_transition ->
            assert MaterialCatalog.material_id(rule.from_material)
            assert MaterialCatalog.material_id(rule.to_material)

          :tag_reaction ->
            # tag_reaction 无 from/to;校验 transform 效果的材料名合法。
            for {:transform, mat} <- Enum.filter(rule.effects, &match?({:transform, _}, &1)) do
              assert MaterialCatalog.material_id(mat)
            end
        end
      end
    end
  end
end
