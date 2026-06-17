defmodule SceneServer.Voxel.Reaction.ChemicalReactions do
  @moduledoc """
  化学反应规格表 + 规则展开(功能完善 · 正交架构 S4)。

  单一真相源:声明式 `ChemicalReaction` 规格列表。`to_rules/0` 把每条规格展开成三条既有
  `Reaction.Rule`(start / sustain / complete),并入 `Rules.all/0`;`Engine` 不变,只是多了一层更紧凑的
  声明(同 S3 `Actuators`)。

  **燃烧不再是 `Rules.ex` 里的特例三规则,而是这张表里的一条 recipe**——与氧化(铁→锈)同模板异参数。
  这把「燃烧=通用化学的一个实例」在数据结构上证死;新增任何化学反应 = 往 `@all` 加一条 `ChemicalReaction`
  (+ 若有新产物/属性,在 Material/Attribute catalog append),无须改 Engine 或写 coded kernel。

  燃烧 recipe 展开出的三条规则与历史手写 `ignite`/`burn`/`burn_out` **逐条行为等价**(仅 rule id 名变),
  由 `chemical_reactions_test` 断言。
  """

  alias SceneServer.Voxel.Reaction.ChemicalReaction
  alias SceneServer.Voxel.Reaction.Rule

  # 燃烧(旗舰涌现):定性档 game-feel(模型卡 :qualitative),非严格燃烧焓。释放 ~30MJ/tick(木
  # ΔT≈30K/tick),burn_progress 每 tick +0.025(~40 tick=4s 烧尽)。
  @combustion_joules_per_tick 30_000_000.0
  @burn_progress_per_tick 0.025

  # 氧化(铁→锈):缓慢、微放热。rate 取小值——慢氧化(~200 tick 锈成),且**护住 80-tick 焦耳热 e2e**
  # (iron 在热回路里 80 tick 仅累进 0.4 < 1.0,不会中途转 rust 断路)。放热极小(0.2MJ/tick,iron
  # ΔT≈0.06K/tick)远低于燃烧,仅作 chemistry→temperature→守恒热扩散 跨系统 truth 耦合的演示,不熔邻居。
  @oxidation_joules_per_tick 200_000.0
  @oxidation_progress_per_tick 0.005

  # 反应规格表(append-only)。燃烧 = 任意可燃材料(material: nil,ignition_temperature 哨兵属性派生)
  # → ash;氧化 = 具名反应物 iron(产物专属,同 phase_transition from_material)→ rust。
  @all [
    %ChemicalReaction{
      id: :combustion,
      material: nil,
      gate_attr: "ignition_temperature",
      active_tag: :burning,
      progress_attr: "burn_progress",
      rate: @burn_progress_per_tick,
      heat_per_tick: @combustion_joules_per_tick,
      product: :ash
    },
    %ChemicalReaction{
      id: :iron_oxidation,
      material: :iron,
      gate_attr: "oxidation_temperature",
      active_tag: :rusting,
      progress_attr: "oxidation_progress",
      rate: @oxidation_progress_per_tick,
      heat_per_tick: @oxidation_joules_per_tick,
      product: :rust
    }
  ]

  @doc "全部化学反应规格。"
  @spec all() :: [ChemicalReaction.t()]
  def all, do: @all

  @doc "全部化学反应展开成的反应规则(每规格三条:start / sustain / complete)。"
  @spec to_rules() :: [Rule.t()]
  def to_rules, do: Enum.flat_map(@all, &rules_for/1)

  @doc """
  把一条化学反应规格展开成三条 `tag_reaction` 规则:

    * `<id>_start`:material + 温度 ≥ gate_attr + forbid [active_tag] → add active_tag;
    * `<id>_sustain`:material + require [active_tag] → emit_heat heat_per_tick + advance progress_attr rate;
    * `<id>_complete`:material + require [active_tag] + progress ≥ 1.0 → transform product + remove active_tag。
  """
  @spec rules_for(ChemicalReaction.t()) :: [Rule.t()]
  def rules_for(%ChemicalReaction{} = reaction) do
    progress_field = String.to_existing_atom(reaction.progress_attr)

    [
      Rule.new!(
        id: :"#{reaction.id}_start",
        kind: :tag_reaction,
        material: reaction.material,
        forbid_tags: [reaction.active_tag],
        condition: {:temperature, :gte, {:material_threshold, reaction.gate_attr}},
        effects: [{:add_tag, reaction.active_tag}]
      ),
      Rule.new!(
        id: :"#{reaction.id}_sustain",
        kind: :tag_reaction,
        material: reaction.material,
        require_tags: [reaction.active_tag],
        effects: [
          {:emit_heat_joules, reaction.heat_per_tick},
          {:advance_attribute, reaction.progress_attr, reaction.rate}
        ]
      ),
      Rule.new!(
        id: :"#{reaction.id}_complete",
        kind: :tag_reaction,
        material: reaction.material,
        require_tags: [reaction.active_tag],
        condition: {progress_field, :gte, {:value, 1.0}},
        effects: [{:transform, reaction.product}, {:remove_tag, reaction.active_tag}]
      )
    ]
  end
end
