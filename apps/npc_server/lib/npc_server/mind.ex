defmodule NpcServer.Mind do
  @moduledoc """
  全局系统功能：心智快照——控制链各层发问时唯一的上下文来源（总纲
  docs/10-active/cross-cutting/2026-11-12-npc-architecture-overview.md 的“共享心智”）。

  快照是发问那一刻从各 owner 现读拼出的只读视图，不另存：`snapshot/3` 返回有序的栏 `[{英文栏名, 英文正文}]`，
  `text/1` 把它转成给模型的英文 state。每一栏只有一个 owner，这里只读：

  | 栏 | 内容 | owner |
  |---|---|---|
  | Character | 人格卡的英文描述 | 注册参数（`profile.who`、`profile.persona`，`NpcServer.Persona`） |
  | Current situation | 位置、生命、附近的人、背包 | World / Scene，经 Body 的 Observation（派生缓存，不是世界真值） |
  | Recent activities | 最近做过的几件事及结果 | 选择器（`NpcServer.Selector` 的历史） |

  数值由代码算好写进正文（如与旁人的距离），模型不做算术。与模型的交互一律英文；角色名字原样写入。
  背包只有材料号与单位数：材料名在 World 的目录里，不在 Observation 里，这里不另查。
  以后的栏（情绪与关系、近期经历、记忆）加在 `snapshot/3` 的同一个列表里。
  """
  alias NpcServer.Persona

  @doc """
  一份快照：有序的栏 `[{栏名, 正文}]`。`profile` 含 `who` 与 `persona`；`observation` 是 Body 的 Observation；
  `history` 是已结束的活动（`NpcServer.Selector.history/1`，旧在前，每项含 `activity` 与
  `result: :completed | {:failed, 动作名, 原因文字}`）。
  """
  @spec snapshot(map(), map(), [map()]) :: [{String.t(), String.t()}]
  def snapshot(profile, observation, history) do
    [
      {"Character", Persona.describe(profile.who, profile.persona)},
      {"Current situation", situation(observation)},
      {"Recent activities", recent(history)}
    ]
  end

  @doc "快照的英文转写：每栏一行 `栏名: 正文`，按栏的次序。"
  @spec text([{String.t(), String.t()}]) :: String.t()
  def text(sections),
    do: Enum.map_join(sections, "\n", fn {title, body} -> title <> ": " <> body end)

  # 眼前的处境：只用 Observation 里现有的字段。
  defp situation(%{self: %{position: {x, y, z} = position} = self} = observation) do
    others = Enum.reject(observation.entities, &(&1.entity_id == self.entity_id))

    Enum.join(
      ["Standing at x=#{metres(x)}, z=#{metres(z)} (height #{metres(y)})."] ++
        life(self.body_state) ++ [nearby(others, position), inventory(observation.balances)],
      " "
    )
  end

  # 本会话还没收到身体状态（nil）时不写这一句。
  defp life(nil), do: []
  defp life(%{life: life}), do: ["Life #{round(life)} of 100."]

  defp nearby([], _origin), do: "Nobody else is nearby."

  defp nearby(others, origin) do
    "Nearby: " <>
      Enum.map_join(others, "; ", fn other ->
        "#{name(other.name)} (#{kind(other.kind)}, #{metres(distance(origin, other.position))} m away)"
      end) <> "."
  end

  defp name(""), do: "someone unnamed"
  defp name(name), do: name

  # Scene 的角色种类码：0 = 玩家，1 = NPC。
  defp kind(0), do: "player"
  defp kind(1), do: "NPC"

  # nil = 还没取过余额；空表 = 背包是空的。
  defp inventory(nil), do: "Inventory: not checked yet."
  defp inventory([]), do: "Inventory: empty."

  defp inventory(rows) do
    "Inventory: " <>
      Enum.map_join(rows, ", ", fn %{material: material, balance: balance} ->
        "material #{material}: #{balance} units"
      end) <> "."
  end

  defp recent([]), do: "None yet."

  defp recent(history) do
    "Oldest first. " <>
      Enum.map_join(history, " ", fn %{activity: activity, result: result} ->
        "#{activity}: #{outcome(result)}."
      end)
  end

  defp outcome(:completed), do: "completed"
  defp outcome({:failed, act, reason}), do: "failed (#{act}: #{reason})"

  defp distance({x, y, z}, {ox, oy, oz}),
    do: :math.sqrt((x - ox) ** 2 + (y - oy) ** 2 + (z - oz) ** 2)

  defp metres(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)
end
