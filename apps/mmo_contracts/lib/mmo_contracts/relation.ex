defmodule MmoContracts.Relation do
  @moduledoc """
  全局系统功能：观察者眼里目标的敌我关系与来源（Voxim Docs/Factions.md §3）。

  纯函数。输入两份角色档案（登录时由 `DataService.Orgs.profile/1` 组装，随实体值传播），输出关系与来源文字。
  档案：`%{name, guild: %{id, name} | nil, nation: %{id, name} | nil, standings: [standing]}`，
  standing = `%{from: :guild | :nation, to: org_id, relation: :friendly | :neutral | :hostile, locked: boolean, source: String.t()}`，
  是本角色所属公会 / 国家对其他组织的立场。

  五关，前一关命中即停：硬规则（自己、同公会、同国）→ 锁定立场 → 普通立场（从具体到宽泛）→
  反向（只取对方的敌对）→ 中立。P1 只有组织层立场；个人立场与"任何人"层以后加。

  关系只回答敌我颜色，不回答合法性或作用权限（Combat-Action-Design §5.1）。
  """

  @codes %{neutral: 0, self: 1, own: 2, friendly: 3, hostile: 4}
  @labels %{friendly: "友好", neutral: "中立", hostile: "敌对"}

  @doc "没有任何组织与名字的档案。"
  def blank, do: %{name: nil, guild: nil, nation: nil, standings: []}

  @doc "线上 relation 字节。"
  def code(relation), do: Map.fetch!(@codes, relation)

  @doc "`{关系, 来源}`；`observer_id` / `target_id` 是实体 ID（cid）。"
  def resolve(observer_id, observer, target_id, target) do
    cond do
      observer_id == target_id -> {:self, "自己"}
      same?(observer.guild, target.guild) -> {:own, "同属" <> observer.guild.name}
      same?(observer.nation, target.nation) -> {:own, "同属" <> observer.nation.name}
      true -> standing(observer, target)
    end
  end

  defp same?(nil, _), do: false
  defp same?(a, b), do: b != nil and a.id == b.id

  defp standing(observer, target) do
    forward = lookup(observer, target)

    with nil <- Enum.find(forward, & &1.locked),
         nil <- List.first(forward),
         nil <- Enum.find(lookup(target, observer), &(&1.relation == :hostile)) do
      {:neutral, "没有任何立场"}
    else
      %{relation: relation} = hit -> {relation, describe(hit)}
    end
  end

  # 按"我方从具体到宽泛 × 对方从具体到宽泛"的顺序列出命中的立场。
  defp lookup(from, to) do
    for level <- [:guild, :nation],
        org = Map.fetch!(from, level),
        org != nil,
        target <- [to.guild, to.nation],
        target != nil,
        s <- from.standings,
        s.from == level and s.to == target.id,
        do: %{relation: s.relation, locked: s.locked, source: s.source, from: org.name, to: target.name}
  end

  defp describe(hit) do
    detail = if hit.locked, do: hit.source <> "，锁定", else: hit.source
    "#{hit.from} 对 #{hit.to}：#{@labels[hit.relation]}（#{detail}）"
  end
end
