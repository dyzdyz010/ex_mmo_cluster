defmodule SceneServer.Voxel.Reaction.ChemicalReaction do
  @moduledoc """
  通用化学反应规格(功能完善 · 正交架构 S4)。

  把「燃烧」「氧化」这类「起反应 → 持续放热推进 → 完成转产物」的反应从**每反应手写三条规则**收敛成
  **一条声明式数据**(完全仿 S3 `Actuator`/`Actuators`)。一条规格描述一个反应的状态机:

      %ChemicalReaction{
        id: :combustion,                   # 规则 id 前缀
        material: nil,                     # 反应物过滤:nil=任意过门材料;atom=仅该反应物(具名反应,
                                           #   同 phase_transition from_material 范式,非系统激活白名单)
        gate_attr: "ignition_temperature", # 起反应温度门(material_threshold;惰性=哨兵不可达)
        active_tag: :burning,              # 反应中 latch
        progress_attr: "burn_progress",    # 动态进度属性(add_delta,满 1.0 完成)
        rate: 0.025,                       # 每 tick 进度增量
        heat_per_tick: 30_000_000.0,       # 每 tick 放热焦耳(经 truth 耦合到热系统)
        product: :ash                      # 完成产物
      }

  语义(`ChemicalReactions.rules_for/1` 展开成三条既有 `Reaction.Rule`,`Engine` 不变):

    * start:`material` + 温度 ≥ `gate_attr` + 未激活 → 置 `active_tag`;
    * sustain:`material` + 已激活 → `emit_heat_joules heat_per_tick` + `advance_attribute progress_attr rate`;
    * complete:`material` + 已激活 + `progress_attr` ≥ 1.0 → `transform product` + 去 `active_tag`。

  燃烧与氧化只是**同模板异参数**的两条数据 → 结构上证「燃烧=化学的一个实例」+「加化学反应=加数据」。
  """

  @enforce_keys [:id, :gate_attr, :active_tag, :progress_attr, :rate, :heat_per_tick, :product]
  defstruct [
    :id,
    :material,
    :gate_attr,
    :active_tag,
    :progress_attr,
    :rate,
    :heat_per_tick,
    :product
  ]

  @type t :: %__MODULE__{
          id: atom(),
          material: atom() | nil,
          gate_attr: String.t(),
          active_tag: atom(),
          progress_attr: String.t(),
          rate: float(),
          heat_per_tick: float(),
          product: atom()
        }
end
