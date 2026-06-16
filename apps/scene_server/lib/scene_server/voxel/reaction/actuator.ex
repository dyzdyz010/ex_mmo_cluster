defmodule SceneServer.Voxel.Reaction.Actuator do
  @moduledoc """
  通用机械执行器规格(功能完善 · 正交架构 S3 Part B)。

  把"通电门/活塞/闸门"这类设备从**每设备手写一对 tag_reaction 规则**收敛成**一条声明式数据**。
  一个执行器 = 一个材料 + 一个触发 tag + 一个激活 tag 的状态机:

      %Actuator{material: :door, trigger_tag: :powered, active_tag: :open}

  语义:材料 == `material` 的 cell——**有 `trigger_tag` 且未激活 → 置 `active_tag`;已激活但
  `trigger_tag` 消失 → 去 `active_tag`**(trigger↔active 状态机,带 hysteresis 不来回翻)。

  执行器只声明"受激 → 哪个状态 tag",**不声明该 tag 的物理后果**——后果(可通行/透光/位移)由
  `TagPhysics` 等正交绑定表决定。新设备 = 加一条 `Actuator` 规格(+ 若有新物理态,在 TagPhysics
  等表 append 该 tag),无须新规则或碰撞代码。

  `Actuators.rules_for/1` 把一条规格展开成两条既有 `Reaction.Rule`,`Engine` 不变。
  """

  @enforce_keys [:material, :trigger_tag, :active_tag]
  defstruct [:material, :trigger_tag, :active_tag]

  @type t :: %__MODULE__{
          material: atom(),
          trigger_tag: atom(),
          active_tag: atom()
        }
end
