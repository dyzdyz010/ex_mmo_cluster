defmodule SceneServer.Voxel.Reaction.Actuators do
  @moduledoc """
  执行器规格表 + 规则展开(功能完善 · 正交架构 S3 Part B)。

  单一真相源:声明式 `Actuator` 规格列表。`to_rules/0` 把每条规格展开成两条既有
  `Reaction.Rule`(activate / deactivate),并入 `Rules.all/0`。门(及未来 piston/gate/elevator)
  从"每设备手写两条规则"收敛成"每设备一条数据";`Engine` 不变,只是多了一层更紧凑的声明。

  新设备 = 往 `@all` 加一条 `Actuator`(若引入新物理态,再在 `TagPhysics` 等绑定表 append 其 tag)。
  """

  alias SceneServer.Voxel.Reaction.{Actuator, Rule}

  # 执行器规格表(append-only)。门:导电门(:load,S2 属性派生)通电(R7 置 :powered)→ 置 :open
  # (TagPhysics 绑定 :open → 可通行);失电 → 去 :open(复阻挡)。
  @all [
    %Actuator{material: :door, trigger_tag: :powered, active_tag: :open}
  ]

  @doc "全部执行器规格。"
  @spec all() :: [Actuator.t()]
  def all, do: @all

  @doc "全部执行器展开成的反应规则(每规格两条:activate / deactivate)。"
  @spec to_rules() :: [Rule.t()]
  def to_rules, do: Enum.flat_map(@all, &rules_for/1)

  @doc """
  把一条执行器规格展开成两条 `tag_reaction` 规则:

    * activate:material + require [trigger] + forbid [active] → add active
    * deactivate:material + require [active] + forbid [trigger] → remove active

  (require/forbid 互锁形成 trigger↔active 状态机,稳定态不再产生效果。)
  """
  @spec rules_for(Actuator.t()) :: [Rule.t()]
  def rules_for(%Actuator{material: material, trigger_tag: trigger, active_tag: active}) do
    [
      Rule.new!(
        id: :"#{material}_#{active}_activate",
        kind: :tag_reaction,
        material: material,
        require_tags: [trigger],
        forbid_tags: [active],
        effects: [{:add_tag, active}]
      ),
      Rule.new!(
        id: :"#{material}_#{active}_deactivate",
        kind: :tag_reaction,
        material: material,
        require_tags: [active],
        forbid_tags: [trigger],
        effects: [{:remove_tag, active}]
      )
    ]
  end
end
