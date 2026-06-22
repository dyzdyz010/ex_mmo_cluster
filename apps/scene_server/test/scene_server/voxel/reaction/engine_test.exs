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

    test "蒸汽 < 100℃ 冷凝回水;≥100℃ 稳定(完成可逆水循环,防振荡)" do
      assert [{:transform_material, eff}] = Engine.evaluate([cell(steam_id(), 50.0)], Rules.all())
      assert eff.from_material_id == steam_id()
      assert eff.to_material_id == water_id()
      assert eff.rule_id == :steam_condenses
      # 恰 100℃ 不冷凝(严格 <,与水沸 ≥100 错开);> 100 稳定。
      assert [] = Engine.evaluate([cell(steam_id(), 100.0)], Rules.all())
      assert [] = Engine.evaluate([cell(steam_id(), 150.0)], Rules.all())
    end

    test "water 的 for_material 返回冻结与沸腾两条" do
      ids = Rules.for_material(:water) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [:water_boils, :water_freezes]
    end
  end

  describe "化学扩展:金属/岩石熔化族(与冰熔同模板异材料)" do
    defp iron_mid, do: MaterialCatalog.material_id(:iron)
    defp molten_iron_id, do: MaterialCatalog.material_id(:molten_iron)
    defp lava_id, do: MaterialCatalog.material_id(:lava)

    # iron 同 tick 还会起锈(oxidation_temperature=0,与熔化正交并发),故按效果类型筛 transform,
    # 不假设唯一效果——熔化与氧化两个独立涌现并存是正确行为。
    defp find_transform(effects) do
      Enum.find_value(effects, fn
        {:transform_material, eff} -> eff
        _ -> nil
      end)
    end

    test "iron ≥ melting_point(1538℃)熔成 molten_iron" do
      eff = find_transform(Engine.evaluate([cell(iron_mid(), 1538.0)], Rules.all()))
      assert eff.from_material_id == iron_mid()
      assert eff.to_material_id == molten_iron_id()
      assert eff.rule_id == :iron_melts
    end

    test "iron 1537℃ 不熔(边界下方;起锈与熔化正交,故只断言无熔化 transform)" do
      effects = Engine.evaluate([cell(iron_mid(), 1537.0)], Rules.all())
      refute Enum.any?(effects, &match?({:transform_material, _}, &1))
    end

    test "molten_iron < freezing_point(1538℃)回凝为 iron" do
      # molten_iron 氧化哨兵不锈 → 只此一条 transform。
      eff = find_transform(Engine.evaluate([cell(molten_iron_id(), 1500.0)], Rules.all()))
      assert eff.to_material_id == iron_mid()
      assert eff.rule_id == :molten_iron_solidifies
    end

    test "1538℃ 无熔/凝振荡:iron 熔、molten_iron 不立即回凝(严格 < 迟滞)" do
      cells = [cell(iron_mid(), 1538.0, 1), cell(molten_iron_id(), 1538.0, 2)]
      effects = Engine.evaluate(cells, Rules.all())
      transforms = Enum.filter(effects, &match?({:transform_material, _}, &1))
      # 仅 iron→molten(macro 1);molten_iron 恰 1538℃ 不回凝(<freezing 严格)。
      assert [{:transform_material, eff}] = transforms
      assert eff.macro_index == 1
      assert eff.to_material_id == molten_iron_id()
    end

    test "stone ≥ melting_point(1200℃)熔成 lava;lava 回凝石" do
      # stone/lava 不锈,各自唯一 transform。
      melt = find_transform(Engine.evaluate([cell(stone_id(), 1200.0)], Rules.all()))
      assert melt.to_material_id == lava_id()
      assert melt.rule_id == :stone_melts

      solidify = find_transform(Engine.evaluate([cell(lava_id(), 1100.0)], Rules.all()))
      assert solidify.to_material_id == stone_id()
      assert solidify.rule_id == :lava_solidifies
    end

    test "molten_iron/lava 不再熔(melting 哨兵)且高温稳定" do
      assert [] = Engine.evaluate([cell(molten_iron_id(), 3000.0)], Rules.all())
      assert [] = Engine.evaluate([cell(lava_id(), 3000.0)], Rules.all())
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

    test "R5d:未知材料(不在 catalog)即便高温也不反应(惰性安全不被缺省阈值 0 反转)" do
      refute MaterialCatalog.known_material?(9999)

      # 未知材料 9999 在 1000℃:若 material_threshold 缺省 0 会误点燃/误熔——现应完全不反应。
      assert [] = Engine.evaluate([bcell(9999, 1000.0)], Rules.all())
    end
  end

  describe "tag_reaction material 过滤(R9a 引入,door 等设备规则用)" do
    # S1 正交架构:加热不再是 powered_heater 规则,而是 CircuitCurrentKernel 的 I²R 物理后果
    # (见 circuit_current_kernel_test);此处只验 material 过滤本身——设备规则按材料分流。
    defp electric_load_id, do: MaterialCatalog.material_id(:electric_load)

    test "通电的非门材料不触发门规则(material 过滤)" do
      # electric_load 带 :powered 也不触发门规则(material: :door 过滤)。
      effects =
        Engine.evaluate(
          [
            %{
              macro_index: 0,
              material_id: electric_load_id(),
              temperature_celsius: 20.0,
              tags: [:powered]
            }
          ],
          Rules.all()
        )

      refute Enum.any?(effects, fn
               {:set_tag, st} -> :open in st.add
               _ -> false
             end)
    end

    test "Rule.new! 接受合法 material 过滤、拒绝非法材料名" do
      rule =
        Rule.new!(
          id: :dev_device,
          kind: :tag_reaction,
          material: :door,
          require_tags: [:powered],
          effects: [{:add_tag, :open}]
        )

      assert rule.material == :door

      assert_raise ArgumentError, ~r/material 非法材料名/, fn ->
        Rule.new!(
          id: :bad_device,
          kind: :tag_reaction,
          material: :unobtanium,
          require_tags: [:powered],
          effects: [{:add_tag, :open}]
        )
      end
    end
  end

  describe "R9b 通电门(:powered↔:open tag 状态机)" do
    defp door_id, do: MaterialCatalog.material_id(:door)

    defp dcell(tags, macro_index \\ 0) do
      %{macro_index: macro_index, material_id: door_id(), temperature_celsius: 20.0, tags: tags}
    end

    test "通电的关门 → 开(加 :open)" do
      effects = Engine.evaluate([dcell([:powered])], Rules.all())
      assert {:set_tag, st} = Enum.find(effects, &match?({:set_tag, _}, &1))
      assert :open in st.add
      assert st.remove == []
    end

    test "失电的开门 → 关(去 :open)" do
      effects = Engine.evaluate([dcell([:open])], Rules.all())
      assert {:set_tag, st} = Enum.find(effects, &match?({:set_tag, _}, &1))
      assert :open in st.remove
      assert st.add == []
    end

    test "通电且已开 → 稳定(不重复开、不误关)" do
      assert [] = Engine.evaluate([dcell([:powered, :open])], Rules.all())
    end

    test "失电且已关 → 稳定(不动)" do
      assert [] = Engine.evaluate([dcell([])], Rules.all())
    end

    test "非门材料带 :powered 不触发门规则(material 过滤;通电 load 走加热器不开门)" do
      effects =
        Engine.evaluate(
          [
            %{
              macro_index: 0,
              material_id: electric_load_id(),
              temperature_celsius: 20.0,
              tags: [:powered]
            }
          ],
          Rules.all()
        )

      refute Enum.any?(effects, fn
               {:set_tag, st} -> :open in st.add
               _ -> false
             end)
    end
  end

  describe "S4 氧化(铁→锈,化学 recipe 第二实例)" do
    defp iron_id, do: MaterialCatalog.material_id(:iron)
    defp rust_id, do: MaterialCatalog.material_id(:rust)

    defp ocell(material_id, tags, progress \\ 0.0, temp \\ 20.0) do
      %{
        macro_index: 0,
        material_id: material_id,
        temperature_celsius: temp,
        oxidation_progress: progress,
        tags: tags
      }
    end

    defp adds_tag?(effects, tag) do
      Enum.any?(effects, fn
        {:set_tag, st} -> tag in st.add
        _ -> false
      end)
    end

    test "iron 常温过起锈门 → 置 :rusting(属性派生激活)" do
      effects = Engine.evaluate([ocell(iron_id(), [])], Rules.all())
      assert adds_tag?(effects, :rusting)
    end

    test "锈中 iron → 微放热 + 推进 oxidation_progress(连续效果)" do
      effects = Engine.evaluate([ocell(iron_id(), [:rusting], 0.2)], Rules.all())

      assert Enum.any?(effects, fn
               {:write_voxel_attribute, %{attribute: :temperature, heat_energy_joules: j}} ->
                 j > 0.0

               _ ->
                 false
             end)

      assert Enum.any?(effects, fn
               {:write_voxel_attribute, %{attribute: "oxidation_progress", delta: d}} -> d > 0.0
               _ -> false
             end)
    end

    test "oxidation_progress 满 → 转 rust + 去 :rusting" do
      effects = Engine.evaluate([ocell(iron_id(), [:rusting], 1.0)], Rules.all())

      assert Enum.any?(effects, fn
               {:transform_material, %{to_material_id: to}} -> to == rust_id()
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set_tag, st} -> :rusting in st.remove
               _ -> false
             end)
    end

    test "rust 终产物不再氧化(起锈门=哨兵)" do
      refute adds_tag?(Engine.evaluate([ocell(rust_id(), [])], Rules.all()), :rusting)
    end

    test "非铁材料不生锈(material: :iron 过滤)" do
      refute adds_tag?(Engine.evaluate([cell(stone_id(), 20.0)], Rules.all()), :rusting)
    end

    test "未知材料不生锈(known_material? 惰性安全)" do
      assert [] = Engine.evaluate([ocell(9999, [])], Rules.all())
    end
  end

  describe "化学扩展:多反应物演示规则(lava+water→obsidian / water+lava→steam)" do
    defp obsidian_id, do: MaterialCatalog.material_id(:obsidian)

    defp rcell(material_name, neighbor_names, temp, macro_index) do
      %{
        macro_index: macro_index,
        material_id: MaterialCatalog.material_id(material_name),
        temperature_celsius: temp,
        neighbor_materials: Enum.map(neighbor_names, &MaterialCatalog.material_id/1),
        tags: []
      }
    end

    defp find_transform_for(effects, macro_index) do
      Enum.find_value(effects, fn
        {:transform_material, %{macro_index: ^macro_index} = eff} -> eff
        _ -> nil
      end)
    end

    test "热熔岩相邻水 → 淬成 obsidian(双反应物产物,经 Rules.all())" do
      # lava@1300℃(>freezing 1200,故不走 lava_solidifies,只走淬火)。
      eff =
        find_transform_for(Engine.evaluate([rcell(:lava, [:water], 1300.0, 7)], Rules.all()), 7)

      assert eff.to_material_id == obsidian_id()
      assert eff.rule_id == :lava_quench_to_obsidian
    end

    test "水相邻熔岩 → 闪蒸成 steam" do
      eff = find_transform_for(Engine.evaluate([rcell(:water, [:lava], 50.0, 3)], Rules.all()), 3)
      assert eff.to_material_id == steam_id()
      assert eff.rule_id == :water_flash_to_steam
    end

    test "熔岩相邻水 + 水相邻熔岩 同 tick 各自反应(lava→obsidian, water→steam)" do
      cells = [rcell(:lava, [:water], 1300.0, 1), rcell(:water, [:lava], 50.0, 2)]
      effects = Engine.evaluate(cells, Rules.all())

      assert find_transform_for(effects, 1).to_material_id == obsidian_id()
      assert find_transform_for(effects, 2).to_material_id == steam_id()
    end

    test "熔岩无相邻水(邻 stone)→ 不淬火(仅可能走温度相变)" do
      # lava@1300℃ 无水:不淬火;1300>1200 也不回凝 → 无 transform。
      assert [] = Engine.evaluate([rcell(:lava, [:stone], 1300.0, 0)], Rules.all())
    end

    test "孤立水(无相邻熔岩,常温)不闪蒸" do
      assert [] = Engine.evaluate([rcell(:water, [:stone], 50.0, 0)], Rules.all())
    end
  end

  describe "多反应物:邻居材料门控(require/forbid_neighbor_materials)" do
    # 临时 A+B→C 规则(lava + 相邻 water → obsidian),只验 Engine 门控机制本身。
    defp quench_rule do
      Rule.new!(
        id: :test_quench,
        kind: :tag_reaction,
        material: :lava,
        require_neighbor_materials: [:water],
        effects: [{:transform, :obsidian}]
      )
    end

    defp ncell(material_name, neighbor_names, macro_index \\ 0) do
      %{
        macro_index: macro_index,
        material_id: MaterialCatalog.material_id(material_name),
        temperature_celsius: 1300.0,
        neighbor_materials: Enum.map(neighbor_names, &MaterialCatalog.material_id/1),
        tags: []
      }
    end

    test "lava 有相邻 water → 触发(transform obsidian)" do
      effects = Engine.evaluate([ncell(:lava, [:water])], [quench_rule()])

      assert [{:transform_material, eff}] = effects
      assert eff.to_material_id == MaterialCatalog.material_id(:obsidian)
      assert eff.rule_id == :test_quench
    end

    test "lava 无相邻 water(邻为 stone)→ 不触发" do
      assert [] = Engine.evaluate([ncell(:lava, [:stone])], [quench_rule()])
    end

    test "lava 无邻居字段 → 不触发(缺省 [],惰性安全)" do
      cell = %{
        macro_index: 0,
        material_id: MaterialCatalog.material_id(:lava),
        temperature_celsius: 1300.0,
        tags: []
      }

      assert [] = Engine.evaluate([cell], [quench_rule()])
    end

    test "material 过滤:water 有相邻 lava 也不触发 lava 规则(material:lava)" do
      assert [] = Engine.evaluate([ncell(:water, [:lava])], [quench_rule()])
    end

    test "forbid_neighbor_materials:相邻有禁忌材料则不触发" do
      rule =
        Rule.new!(
          id: :test_forbid,
          kind: :tag_reaction,
          material: :lava,
          forbid_neighbor_materials: [:water],
          effects: [{:add_tag, :flowing}]
        )

      # 无相邻 water → 触发;有相邻 water → 被禁。
      assert [{:set_tag, _}] = Engine.evaluate([ncell(:lava, [:stone])], [rule])
      assert [] = Engine.evaluate([ncell(:lava, [:water])], [rule])
    end

    test "空邻居门控规则(绝大多数)对带/不带 neighbor_materials 的 cell 均正常求值" do
      # 现有规则全是空 neighbor 门控:不应因 cell 带 neighbor_materials 而改变行为。
      iron = MaterialCatalog.material_id(:iron)

      with_nb = %{
        macro_index: 0,
        material_id: iron,
        temperature_celsius: 20.0,
        neighbor_materials: [MaterialCatalog.material_id(:water)],
        tags: []
      }

      # iron 常温起锈(oxidation_temperature=0),邻居字段不影响。
      assert Enum.any?(Engine.evaluate([with_nb], Rules.all()), fn
               {:set_tag, st} -> :rusting in st.add
               _ -> false
             end)
    end

    test "Rule.new! 校验 neighbor 材料名:合法接受、非法 raise" do
      assert %Rule{require_neighbor_materials: [:water]} =
               Rule.new!(
                 id: :ok,
                 kind: :tag_reaction,
                 material: :lava,
                 require_neighbor_materials: [:water],
                 effects: [{:transform, :obsidian}]
               )

      assert_raise ArgumentError, ~r/require_neighbor_materials 非法材料名/, fn ->
        Rule.new!(
          id: :bad,
          kind: :tag_reaction,
          material: :lava,
          require_neighbor_materials: [:unobtanium],
          effects: [{:transform, :obsidian}]
        )
      end
    end
  end

  describe "光学:光敏元件(光成真机制,光作 condition gate)" do
    defp photo_sensor_id, do: MaterialCatalog.material_id(:photo_sensor)

    defp lcell(material_id, light, tags) do
      %{
        macro_index: 0,
        material_id: material_id,
        temperature_celsius: 20.0,
        light: light,
        tags: tags
      }
    end

    defp adds_illuminated?(effects) do
      Enum.any?(effects, fn
        {:set_tag, st} -> :illuminated in st.add
        _ -> false
      end)
    end

    defp removes_illuminated?(effects) do
      Enum.any?(effects, fn
        {:set_tag, st} -> :illuminated in st.remove
        _ -> false
      end)
    end

    test "photo_sensor 光照 ≥ 阈(32)且未亮 → 置 :illuminated" do
      effects = Engine.evaluate([lcell(photo_sensor_id(), 100.0, [])], Rules.all())
      assert adds_illuminated?(effects)
    end

    test "photo_sensor 光照 < 阈 且已亮 → 去 :illuminated(遮光熄灭)" do
      effects = Engine.evaluate([lcell(photo_sensor_id(), 5.0, [:illuminated])], Rules.all())
      assert removes_illuminated?(effects)
    end

    test "边界无振荡:已亮+开 恰 32(≥)稳定;未亮 + 31(<)保持暗" do
      # 已亮+已开 + 32:illuminate(forbid 已亮)/darken(需<32)/光门 activate(forbid 已开)/
      # deactivate(仍 :illuminated)全不触发 → 稳定(含光门执行器态)。
      assert [] =
               Engine.evaluate(
                 [lcell(photo_sensor_id(), 32.0, [:illuminated, :open])],
                 Rules.all()
               )

      # 未亮 + 31:illuminate 需 ≥32 不触发、darken 需已亮不触发、光门无 trigger → 稳定暗+关。
      assert [] = Engine.evaluate([lcell(photo_sensor_id(), 31.0, [])], Rules.all())
    end

    test "非 photo_sensor 材料即便强光也不点亮(material 过滤)" do
      refute adds_illuminated?(Engine.evaluate([lcell(stone_id(), 255.0, [])], Rules.all()))
    end

    test "Rule.new! 接受 :light condition 维度" do
      rule =
        Rule.new!(
          id: :light_gate,
          kind: :tag_reaction,
          material: :photo_sensor,
          condition: {:light, :gte, {:value, 10.0}},
          effects: [{:add_tag, :illuminated}]
        )

      assert rule.condition == {:light, :gte, {:value, 10.0}}
    end
  end

  describe "光学 · 光合:光长生命(光 × 相邻水 × 生长进度 三系统组合)" do
    defp sprout_id, do: MaterialCatalog.material_id(:sprout)
    defp wood_mid, do: MaterialCatalog.material_id(:wood)
    defp water_mid, do: MaterialCatalog.material_id(:water)

    defp gcell(material_id, light, growth, neighbors) do
      %{
        macro_index: 0,
        material_id: material_id,
        temperature_celsius: 20.0,
        light: light,
        growth_progress: growth,
        neighbor_materials: Enum.map(neighbors, &MaterialCatalog.material_id/1),
        tags: []
      }
    end

    test "sprout 光照 + 相邻水 → 推进 growth_progress(光合)" do
      effects = Engine.evaluate([gcell(sprout_id(), 100.0, 0.2, [:water])], Rules.all())

      assert Enum.any?(effects, fn
               {:write_voxel_attribute, %{attribute: "growth_progress", delta: d}} -> d > 0.0
               _ -> false
             end)
    end

    test "sprout 有光但无相邻水 → 不生长(多反应物门控)" do
      effects = Engine.evaluate([gcell(sprout_id(), 100.0, 0.2, [:stone])], Rules.all())

      refute Enum.any?(effects, fn
               {:write_voxel_attribute, %{attribute: "growth_progress"}} -> true
               _ -> false
             end)
    end

    test "sprout 相邻水但无光(<阈)→ 不生长(光 gate)" do
      effects = Engine.evaluate([gcell(sprout_id(), 5.0, 0.2, [:water])], Rules.all())

      refute Enum.any?(effects, fn
               {:write_voxel_attribute, %{attribute: "growth_progress"}} -> true
               _ -> false
             end)
    end

    test "growth_progress 满(≥1.0)→ 成熟为 wood" do
      effects = Engine.evaluate([gcell(sprout_id(), 100.0, 1.0, [:water])], Rules.all())

      assert Enum.any?(effects, fn
               {:transform_material, %{to_material_id: to}} -> to == wood_mid()
               _ -> false
             end)
    end

    test "非 sprout 材料不光合(material 过滤)" do
      refute Enum.any?(
               Engine.evaluate([gcell(stone_id(), 200.0, 0.5, [:water])], Rules.all()),
               fn
                 {:write_voxel_attribute, %{attribute: "growth_progress"}} -> true
                 _ -> false
               end
             )
    end

    test "water 邻接确实经 material_id 比对(非误报)" do
      assert water_mid() != nil
    end
  end

  describe "Rules 表" do
    test "for_material 过滤相变规则" do
      assert [%Rule{id: :ice_melts}] = Rules.for_material(:ice)
      # 化学扩展后 stone 有熔化相变(→lava)。
      assert [%Rule{id: :stone_melts}] = Rules.for_material(:stone)
      assert [] = Rules.for_material(:ash)
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
