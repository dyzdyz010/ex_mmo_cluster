defmodule SceneServer.Movement.Harm do
  @moduledoc """
  Global system：角色来源作用的唯一许可判断（Voxim `Docs/Combat-Action-Design.md` §1.1 规则层）。
  工具与投射物在候选筛选、扫掠和目标 owner 提交时都调这里；物理作用本身不在此计算。
  当前语义是显式战斗范围；分区合法性（`Docs/Factions.md` §5.4）接入时只改这里。
  """

  @doc "本场是否允许任何角色来源的作用；未配置战斗范围的正式世界不允许。"
  def open?(scope), do: scope != nil

  @doc "一次角色来源作用：来源与目标中心均在显式战斗范围内才允许。"
  def permitted?(nil, _, _), do: false

  def permitted?({low, high}, source, target),
    do:
      Enum.all?([source, target], fn p ->
        Enum.all?(0..2, &(elem(p, &1) >= elem(low, &1) and elem(p, &1) < elem(high, &1)))
      end)
end
