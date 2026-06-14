defmodule SceneServer.Voxel.Reaction.Rules do
  @moduledoc """
  涌现反应规范规则表(功能完善 · 反应层 R1)。

  单一真相源,`Engine` 对它求值。骨架阶段只 seed 一条 demo 相变(冰熔化)立住回路;燃烧 / 相变补全 /
  电→世界 只是往这里加规则(+ 必要的 coded reaction kernel)。新增 kernel 行为无须改 Engine——数据化优先。
  """

  alias SceneServer.Voxel.Reaction.Rule

  # R1 demo:冰 + 温度 ≥ 自身 melting_point(0℃)→ 水。回路 PoC。
  @ice_melts Rule.new!(
               id: :ice_melts,
               kind: :phase_transition,
               from_material: :ice,
               condition: {:temperature, :gte, {:material_threshold, "melting_point"}},
               to_material: :water,
               priority: 0
             )

  # R4 温度相变族补全。**0℃/100℃ 振荡防护**:用严格不等式做 hysteresis——
  # 冰熔 ≥0、水冻 <0(0℃ 时冰熔、水不冻 → 不来回翻);水沸 ≥100、蒸汽(暂无 condense)。
  @water_freezes Rule.new!(
                   id: :water_freezes,
                   kind: :phase_transition,
                   from_material: :water,
                   condition: {:temperature, :lt, {:material_threshold, "freezing_point"}},
                   to_material: :ice,
                   priority: 0
                 )

  @water_boils Rule.new!(
                 id: :water_boils,
                 kind: :phase_transition,
                 from_material: :water,
                 condition: {:temperature, :gte, {:material_threshold, "boiling_point"}},
                 to_material: :steam,
                 priority: 0
               )

  # R5 燃烧(旗舰涌现 · 反馈回路)。常量为定性档 game-feel(模型卡 :qualitative),非严格燃烧焓。
  # 燃烧释放 ~30MJ/tick(木 ΔT≈30K/tick),burn_progress 每 tick +0.025(~40 tick=4s 烧尽)。
  @combustion_joules_per_tick 30_000_000.0
  @burn_progress_per_tick 0.025

  # ignite:任意材料(inert ignition=5000℃ 不可达 → 天然只点燃可燃物),温度≥ignition 且未燃 → 加 :burning。
  @ignite Rule.new!(
            id: :ignite,
            kind: :tag_reaction,
            forbid_tags: [:burning],
            condition: {:temperature, :gte, {:material_threshold, "ignition_temperature"}},
            effects: [{:add_tag, :burning}]
          )

  # burn:燃烧中每 tick 注燃烧焦耳(自维持高温 + 经热扩散点燃邻居)+ 推进 burn_progress。**连续效果**。
  @burn Rule.new!(
          id: :burn,
          kind: :tag_reaction,
          require_tags: [:burning],
          condition: nil,
          effects: [
            {:emit_heat_joules, @combustion_joules_per_tick},
            {:advance_attribute, "burn_progress", @burn_progress_per_tick}
          ]
        )

  # burn_out:燃烧进度满 → 变 ash(ignition inert 不复燃)+ 去 :burning。
  @burn_out Rule.new!(
              id: :burn_out,
              kind: :tag_reaction,
              require_tags: [:burning],
              condition: {:burn_progress, :gte, {:value, 1.0}},
              effects: [{:transform, :ash}, {:remove_tag, :burning}]
            )

  @all [@ice_melts, @water_freezes, @water_boils, @ignite, @burn, @burn_out]

  @doc "全部反应规则。"
  @spec all() :: [Rule.t()]
  def all, do: @all

  @doc "某 from 材料名(相变)适用的规则。"
  @spec for_material(atom()) :: [Rule.t()]
  def for_material(name) when is_atom(name) do
    Enum.filter(@all, &(&1.kind == :phase_transition and &1.from_material == name))
  end
end
