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

  # 蒸汽 < 100℃(水沸点)冷凝回水,完成 ice↔water↔steam 可逆水循环。严格 < 与水沸 ≥100 错开防振荡。
  @steam_condenses Rule.new!(
                     id: :steam_condenses,
                     kind: :phase_transition,
                     from_material: :steam,
                     condition: {:temperature, :lt, {:celsius, 100.0}},
                     to_material: :water,
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

  # R9a 通电加热器规则已删(2026-06-16 正交架构 S1):加热不再是「电负载 + :powered → 凭空发热」的
  # 写死规则,而是「载流(闭环电流)× 材料 electric_resistance → I²R 焦耳热」的物理后果——由
  # CircuitCurrentKernel 直接注入 temperature 注热原语。高电阻 electric_load(发热元件)载流即热;
  # 零电阻 door(机械执行器)载流不热——同为 :powered 负载,发热与否由材料属性正交分流,无须设备规则。

  # R9b 通电门/机关。通电(R7 circuit 置 :powered)的门"开"(加 :open → 碰撞视为可通行);失电的
  # 开门"关"(去 :open → 复阻挡)。开/关是 :powered↔:open 的 tag 状态机,复用 require/forbid
  # (forbid_tags 即"非 :powered")——无须 Engine 扩展。设备动作=结构/可通行性变化(非热),与
  # 加热器并列证设备行为多样性。涌现链:接通电路 → :powered → 门开(可穿行)/ 断电 → 门关。
  @door_open Rule.new!(
               id: :door_open,
               kind: :tag_reaction,
               material: :door,
               require_tags: [:powered],
               forbid_tags: [:open],
               effects: [{:add_tag, :open}]
             )

  @door_close Rule.new!(
                id: :door_close,
                kind: :tag_reaction,
                material: :door,
                require_tags: [:open],
                forbid_tags: [:powered],
                effects: [{:remove_tag, :open}]
              )

  @all [
    @ice_melts,
    @water_freezes,
    @water_boils,
    @steam_condenses,
    @ignite,
    @burn,
    @burn_out,
    @door_open,
    @door_close
  ]

  @doc "全部反应规则。"
  @spec all() :: [Rule.t()]
  def all, do: @all

  @doc "某 from 材料名(相变)适用的规则。"
  @spec for_material(atom()) :: [Rule.t()]
  def for_material(name) when is_atom(name) do
    Enum.filter(@all, &(&1.kind == :phase_transition and &1.from_material == name))
  end
end
