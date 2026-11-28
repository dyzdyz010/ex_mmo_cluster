defmodule MmoContracts.Harm do
  @moduledoc """
  Global system：角色来源作用的唯一许可判断（Voxim `Docs/Combat-Action-Design.md` §1.1 规则层）。

  工具与投射物在候选筛选、扫掠和目标 owner 提交时都调这里；魔法干预（驱散脉冲作用于他人结构与他人前摇，
  设计 TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` §14.0 Q7）由 World 在热提交点调这里。
  物理作用本身不在此计算。当前语义是显式战斗范围；分区合法性（`Docs/Factions.md` §5.4）接入时只改这里。

  ## 为什么在 mmo_contracts

  原在 `SceneServer.Movement.Harm`。魔法 v2 切片 6 起 `VoxelRegion.World` 也要判（落地稿
  `docs/10-active/magic/2026-11-19-glyph-v2-server-landing.md` D6、决策稿 `2026-11-26-p1-closure-slices4-8.md` Q6-3）；
  依赖方向是 scene_server → voxel_region，World 不能调用 scene_server（AGENTS 铁律 6）。战斗范围因此作为共享契约
  放在三个 app 都依赖的纯模块里：Scene 配置给出范围值，施法快照把它带进 World，判定规则只有这一份。
  """

  @typedoc "显式战斗范围：`{下界, 上界)` 半开三维盒（m）；`nil` 表示本场不允许任何角色来源的作用。"
  @type scope :: {{number(), number(), number()}, {number(), number(), number()}} | nil

  @doc "本场是否允许任何角色来源的作用；未配置战斗范围的正式世界不允许。"
  @spec open?(scope()) :: boolean()
  def open?(scope), do: scope != nil

  @doc "一次角色来源作用：来源与目标中心均在显式战斗范围内才允许。"
  @spec permitted?(scope(), {number(), number(), number()}, {number(), number(), number()}) ::
          boolean()
  def permitted?(nil, _, _), do: false

  def permitted?({low, high}, source, target),
    do:
      Enum.all?([source, target], fn p ->
        Enum.all?(0..2, &(elem(p, &1) >= elem(low, &1) and elem(p, &1) < elem(high, &1)))
      end)
end
