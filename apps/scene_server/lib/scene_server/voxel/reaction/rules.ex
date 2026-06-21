defmodule SceneServer.Voxel.Reaction.Rules do
  @moduledoc """
  涌现反应规范规则表(功能完善 · 反应层 R1)。

  单一真相源,`Engine` 对它求值。骨架阶段只 seed 一条 demo 相变(冰熔化)立住回路;燃烧 / 相变补全 /
  电→世界 只是往这里加规则(+ 必要的 coded reaction kernel)。新增 kernel 行为无须改 Engine——数据化优先。
  """

  alias SceneServer.Voxel.Reaction.Actuators
  alias SceneServer.Voxel.Reaction.ChemicalReactions
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

  # 蒸汽 < 100℃(水沸点)冷凝回水,完成 ice↔water↔steam 可逆水循环。严格 < 与水沸 ≥100 错开防振荡。
  @steam_condenses Rule.new!(
                     id: :steam_condenses,
                     kind: :phase_transition,
                     from_material: :steam,
                     condition: {:temperature, :lt, {:celsius, 100.0}},
                     to_material: :water,
                     priority: 0
                   )

  # 化学扩展(2026-06-21)金属/岩石熔化族——与 ice↔water 同模板异材料,零 Engine 改动。
  # 同样 ≥melting / <freezing 严格不等式迟滞(1538℃/1200℃ 处不来回翻)。热源(电加热铁、燃烧、
  # 岩浆)经 ReactionKernel 守恒热扩散把邻格烤过阈即熔。
  @iron_melts Rule.new!(
                id: :iron_melts,
                kind: :phase_transition,
                from_material: :iron,
                condition: {:temperature, :gte, {:material_threshold, "melting_point"}},
                to_material: :molten_iron,
                priority: 0
              )

  @molten_iron_solidifies Rule.new!(
                            id: :molten_iron_solidifies,
                            kind: :phase_transition,
                            from_material: :molten_iron,
                            condition:
                              {:temperature, :lt, {:material_threshold, "freezing_point"}},
                            to_material: :iron,
                            priority: 0
                          )

  @stone_melts Rule.new!(
                 id: :stone_melts,
                 kind: :phase_transition,
                 from_material: :stone,
                 condition: {:temperature, :gte, {:material_threshold, "melting_point"}},
                 to_material: :lava,
                 priority: 0
               )

  @lava_solidifies Rule.new!(
                     id: :lava_solidifies,
                     kind: :phase_transition,
                     from_material: :lava,
                     condition: {:temperature, :lt, {:material_threshold, "freezing_point"}},
                     to_material: :stone,
                     priority: 0
                   )

  # S4 正交架构:燃烧从此处手写的三条规则(ignite/burn/burn_out)收敛为 `ChemicalReactions` 的一条
  # 声明式 `%ChemicalReaction{}` 规格(与氧化 铁→锈 同模板异参数),经 `ChemicalReactions.to_rules/0`
  # 展开成等价的 start/sustain/complete tag_reaction 规则并入 `all/0`。「燃烧=通用化学的一个实例」在数据
  # 结构上证死;新增化学反应 = 加一条 recipe,不改此表/不改 Engine。展开等价性由 chemical_reactions_test 守。

  # R9a 通电加热器规则已删(2026-06-16 正交架构 S1):加热不再是「电负载 + :powered → 凭空发热」的
  # 写死规则,而是「载流(闭环电流)× 材料 electric_resistance → I²R 焦耳热」的物理后果——由
  # CircuitCurrentKernel 直接注入 temperature 注热原语。高电阻 electric_load(发热元件)载流即热;
  # 零电阻 door(机械执行器)载流不热——同为 :powered 负载,发热与否由材料属性正交分流,无须设备规则。

  # S3 Part B(正交架构):门/机关从手写两条规则收敛为 `Actuators` 的一条声明式规格,经
  # `Actuators.to_rules/0` 展开成 activate/deactivate tag_reaction 规则并入 `all/0`。

  # 化学扩展(2026-06-21)多反应物 A + 相邻 B → C(tag_reaction + neighbor 门控)。经典演示:
  # 熔岩遇水淬成黑曜石玻璃、水侧被熔岩闪蒸成蒸汽。一个 tick 内对同一快照各自反应,下一 tick 不再相邻
  # (产物 obsidian/steam)。纯邻接门控(lava 定义上够热,不叠温度条件)。产物 obsidian 依赖**双反应物**
  # (lava 单独冷却只回凝 stone),证 A+B→C 组合。
  @lava_quench_to_obsidian Rule.new!(
                             id: :lava_quench_to_obsidian,
                             kind: :tag_reaction,
                             material: :lava,
                             require_neighbor_materials: [:water],
                             effects: [{:transform, :obsidian}]
                           )

  @water_flash_to_steam Rule.new!(
                          id: :water_flash_to_steam,
                          kind: :tag_reaction,
                          material: :water,
                          require_neighbor_materials: [:lava],
                          effects: [{:transform, :steam}]
                        )

  @multi_reactant [
    @lava_quench_to_obsidian,
    @water_flash_to_steam
  ]

  # 基础物理反应(相变);化学反应(燃烧/氧化)由 ChemicalReactions 展开、设备执行器由 Actuators 展开后并入。
  @base [
    @ice_melts,
    @water_freezes,
    @water_boils,
    @steam_condenses,
    @iron_melts,
    @molten_iron_solidifies,
    @stone_melts,
    @lava_solidifies
  ]

  @all @base ++ @multi_reactant ++ ChemicalReactions.to_rules() ++ Actuators.to_rules()

  @doc "全部反应规则(基础相变 + 化学展开 + 执行器展开)。"
  @spec all() :: [Rule.t()]
  def all, do: @all

  @doc "某 from 材料名(相变)适用的规则。"
  @spec for_material(atom()) :: [Rule.t()]
  def for_material(name) when is_atom(name) do
    Enum.filter(@all, &(&1.kind == :phase_transition and &1.from_material == name))
  end
end
