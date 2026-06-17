defmodule SceneServer.Voxel.Reaction.ChemicalReactionsTest do
  # 功能完善 · 正交架构 S4:化学反应规格 → 规则展开。证「燃烧=通用化学的一个实例」(燃烧 recipe 展开
  # 与历史手写 ignite/burn/burn_out 逐条等价)+「加化学反应=加数据」(氧化 recipe 同模板异参数)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Reaction.{ChemicalReaction, ChemicalReactions, Rule, Rules}

  describe "规格表" do
    test "all 含燃烧 + 铁氧化两条规格" do
      ids = Enum.map(ChemicalReactions.all(), & &1.id)
      assert :combustion in ids
      assert :iron_oxidation in ids
    end

    test "to_rules 每规格展开三条 tag_reaction(start/sustain/complete)" do
      rules = ChemicalReactions.to_rules()
      assert length(rules) == length(ChemicalReactions.all()) * 3
      assert Enum.all?(rules, &match?(%Rule{kind: :tag_reaction}, &1))
    end
  end

  describe "燃烧 = 通用化学的一个实例(展开与历史 ignite/burn/burn_out 逐条等价)" do
    setup do
      combustion = Enum.find(ChemicalReactions.all(), &(&1.id == :combustion))
      [start, sustain, complete] = ChemicalReactions.rules_for(combustion)
      %{start: start, sustain: sustain, complete: complete}
    end

    test "start 等价 ignite", %{start: start} do
      assert %Rule{
               kind: :tag_reaction,
               material: nil,
               forbid_tags: [:burning],
               condition: {:temperature, :gte, {:material_threshold, "ignition_temperature"}},
               effects: [{:add_tag, :burning}]
             } = start
    end

    test "sustain 等价 burn(放热 30MJ + 推进 burn_progress 0.025)", %{sustain: sustain} do
      assert %Rule{
               kind: :tag_reaction,
               material: nil,
               require_tags: [:burning],
               condition: nil,
               effects: [
                 {:emit_heat_joules, 30_000_000.0},
                 {:advance_attribute, "burn_progress", 0.025}
               ]
             } = sustain
    end

    test "complete 等价 burn_out(进度满 → ash + 去 burning)", %{complete: complete} do
      assert %Rule{
               kind: :tag_reaction,
               material: nil,
               require_tags: [:burning],
               condition: {:burn_progress, :gte, {:value, 1.0}},
               effects: [{:transform, :ash}, {:remove_tag, :burning}]
             } = complete
    end
  end

  describe "氧化(铁→锈)= 同模板异参数的第二实例" do
    setup do
      oxidation = Enum.find(ChemicalReactions.all(), &(&1.id == :iron_oxidation))
      [start, sustain, complete] = ChemicalReactions.rules_for(oxidation)
      %{start: start, sustain: sustain, complete: complete}
    end

    test "start:iron 过起锈温度门 + 未锈 → 置 :rusting", %{start: start} do
      assert %Rule{
               kind: :tag_reaction,
               material: :iron,
               forbid_tags: [:rusting],
               condition: {:temperature, :gte, {:material_threshold, "oxidation_temperature"}},
               effects: [{:add_tag, :rusting}]
             } = start
    end

    test "sustain:锈中 → 微放热 + 推进 oxidation_progress", %{sustain: sustain} do
      assert %Rule{
               material: :iron,
               require_tags: [:rusting],
               effects: [
                 {:emit_heat_joules, heat},
                 {:advance_attribute, "oxidation_progress", rate}
               ]
             } = sustain

      # 微放热远低于燃烧 30MJ;慢氧化(rate 小)护住 80-tick 焦耳热 e2e。
      assert heat > 0.0 and heat < 1_000_000.0
      assert rate > 0.0 and rate <= 0.01
    end

    test "complete:oxidation_progress 满 → 转 rust + 去 :rusting", %{complete: complete} do
      assert %Rule{
               material: :iron,
               require_tags: [:rusting],
               condition: {:oxidation_progress, :gte, {:value, 1.0}},
               effects: [{:transform, :rust}, {:remove_tag, :rusting}]
             } = complete
    end
  end

  describe "并入 Rules.all" do
    test "Rules.all 含化学展开的全部规则" do
      all_ids = Rules.all() |> Enum.map(& &1.id) |> MapSet.new()

      for rule <- ChemicalReactions.to_rules() do
        assert MapSet.member?(all_ids, rule.id), "Rules.all 应含化学规则 #{inspect(rule.id)}"
      end
    end

    test "rules_for 对任意规格生成对称三规则(可扩展性:加一条 recipe=新反应)" do
      # 一条假想第三反应(用既有材料 wood + tag burning 作占位,只验展开机制 material/tag 无关)。
      spec = %ChemicalReaction{
        id: :demo_reaction,
        material: :wood,
        gate_attr: "ignition_temperature",
        active_tag: :burning,
        progress_attr: "burn_progress",
        rate: 0.01,
        heat_per_tick: 1.0,
        product: :ash
      }

      assert [s, m, c] = ChemicalReactions.rules_for(spec)
      assert s.id == :demo_reaction_start
      assert m.id == :demo_reaction_sustain
      assert c.id == :demo_reaction_complete
      assert Enum.all?([s, m, c], &(&1.material == :wood))
    end
  end
end
