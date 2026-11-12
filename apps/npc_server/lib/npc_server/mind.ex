defmodule NpcServer.Mind do
  @moduledoc """
  全局系统功能：心智快照——控制链各层发问时唯一的上下文来源（总纲
  docs/10-active/cross-cutting/2026-11-12-npc-architecture-overview.md 的“共享心智”）。

  快照是发问那一刻从各 owner 现读拼出的只读视图，不另存：`snapshot/4` 返回有序的栏 `[{英文栏名, 英文正文}]`，
  `text/1` 把它转成给模型的英文 state。每一栏只有一个 owner，这里只读；栏的次序就是下表的次序：

  | 栏 | 内容 | owner |
  |---|---|---|
  | Character | 人格卡的英文描述 | 注册参数（`profile.who`、`profile.persona`，`NpcServer.Persona`） |
  | Feelings and relationships | 此刻仍活跃的情绪（对谁、什么情绪、多强）与对各角色的信任 | Life（`Life.mind/2` 的 `feelings`、`relationships`） |
  | What just happened | 还没写进 Hindsight 的近期经历原文（权威事件、已结束的活动） | Life（`Life.mind/2` 的 `recent`） |
  | What I remember | 缓存的认识（mental models）与针对当前处境的一次召回 | Hindsight，经 Life 的适配器（`Life.mind/2` 的 `models`、`memories`） |
  | Current situation | 位置、生命、附近的人、我的建筑在不在、背包 | World / Scene，经 Body 的 Observation（派生缓存，不是世界真值）；建筑在不在是发问时现查 World（`Life.mind/2` 的 `buildings`） |
  | Recent activities | 最近做过的几件事及结果 | 选择器（`NpcServer.Selector` 的历史） |

  数值由代码转成给模型读的写法，模型不做算术、不读原始数值：

  - 情绪强度（Life 衰减后的值，0.1 及以下 Life 不给出）：≥ 0.4 `strong`，≥ 0.2 `moderate`，其余 `faint`。
    规则模式一次事件 +0.6、半衰期 120 秒，所以一次破坏之后约 70 秒内是 strong，约 190 秒内是 moderate，约 310 秒后不再出现。
  - 信任（−1..1，不随时间恢复）：≤ −0.6 `Deeply distrusts`，≤ −0.2 `Distrusts`，≥ 0.2 `Trusts`，≥ 0.6 `Deeply trusts`，
    其间不写。规则模式一次破坏 −0.35、一次帮助 +0.25。
  - 角色的写法：还在观察里的写 `名字 (actor <cid>)`，不在的写 `actor <cid>, who is not nearby`。
    带上 cid 是因为近期经历与记忆的原文只用 cid 指人（`Actor <cid> damaged …`），模型要靠它把两处对上。
  - 与旁人的距离由代码算好。

  人格只来自人格卡：Life 状态里的 `caution` / `sociability` 不进快照（并入人格卡要迁移持久状态并牵动 `Brain.Social`，待做）。
  记忆与认识只是“我记得”，不是世界真值，这一栏的开头写明。与模型的交互一律英文；角色名字原样写入。
  背包只有材料号与单位数：材料名在 World 的目录里，不在 Observation 里，这里不另查。
  我放下的有名字的建筑，每座一句，在背包之前：`My building "<名>" at (<ax>, <ay>, <az>) is standing.` 或 `… is gone.`
  （坐标是锚点所在宏格；`is gone.` 是离线对照实测过的原文，见 docs/10-active/cross-cutting/tools/jev/s1c_diag.py 的 `SIT_GONE`）。
  哪几座来自 Life 的记忆，在不在只认发问那一刻 World 的现查结果；没有这样的建筑就一句不写。“受损但还在”不写（没有便宜的逐格读法）。

  `recall_query/2` 由处境拼出那一次召回的问句（附近的人 + 各候选的判据），一次选择只召回一次。
  """
  alias NpcServer.Persona

  @doc """
  一份快照：有序的栏 `[{栏名, 正文}]`。`profile` 含 `who` 与 `persona`；`observation` 是 Body 的 Observation；
  `history` 是已结束的活动（`NpcServer.Selector.history/1`，旧在前，每项含 `activity` 与
  `result: :completed | {:failed, 动作名, 原因文字}`）；`life` 是 `NpcServer.Life.mind/2` 的视图。
  """
  @spec snapshot(map(), map(), [map()], map()) :: [{String.t(), String.t()}]
  def snapshot(profile, observation, history, life) do
    [
      {"Character", Persona.describe(profile.who, profile.persona)},
      {"Feelings and relationships", feelings(life, observation.entities)},
      {"What just happened", happened(life.recent)},
      {"What I remember", remembered(life)},
      {"Current situation", situation(observation, life.buildings)},
      {"Recent activities", recent(history)}
    ]
  end

  @doc "快照的英文转写：每栏一行 `栏名: 正文`，按栏的次序（“What I remember”一栏的正文自己可以有多行）。"
  @spec text([{String.t(), String.t()}]) :: String.t()
  def text(sections),
    do: Enum.map_join(sections, "\n", fn {title, body} -> title <> ": " <> body end)

  @doc """
  针对当前处境的那一次召回的问句：附近的人（名字与 cid）加各候选活动的判据（它们写着涉及的地点与对象）。
  记忆原文用 cid 指人，所以问句里带 cid。
  """
  @spec recall_query(map(), map()) :: String.t()
  def recall_query(profile, %{self: self, entities: entities}) do
    people =
      case Enum.reject(entities, &(&1.entity_id == self.entity_id)) do
        [] -> "Nobody is nearby."
        others -> "Nearby: " <> Enum.map_join(others, ", ", &actor(&1.entity_id, entities)) <> "."
      end

    "I am deciding what to do next. #{people} What I could do: " <>
      Enum.map_join(profile.activities, " ", & &1.criterion) <>
      " What do I remember about these people, places and tasks?"
  end

  @doc "一项活动的结局的英文写法（“最近做过的事”一栏与活动经历共用）。"
  @spec result(:completed | {:failed, String.t(), String.t()}) :: String.t()
  def result(:completed), do: "completed"
  def result({:failed, act, reason}), do: "failed (#{act}: #{reason})"

  # 情绪在前、关系在后；都没有时写一句，不留空栏。
  defp feelings(%{feelings: feelings, relationships: relationships}, entities) do
    sentences =
      for(
        %{emotion: emotion, actor: actor, intensity: intensity} <- feelings,
        do: "Feels #{strength(intensity)} #{emotion} toward #{actor(actor, entities)}."
      ) ++
        for(
          %{actor: actor, trust: trust} <- relationships,
          word = trust(trust),
          do: "#{word} #{actor(actor, entities)}."
        )

    if sentences == [], do: "Nothing notable.", else: Enum.join(sentences, " ")
  end

  defp strength(intensity) when intensity >= 0.4, do: "strong"
  defp strength(intensity) when intensity >= 0.2, do: "moderate"
  defp strength(_intensity), do: "faint"

  # 中间一段（接近中立）不写：返回 nil。
  defp trust(trust) when trust <= -0.6, do: "Deeply distrusts"
  defp trust(trust) when trust <= -0.2, do: "Distrusts"
  defp trust(trust) when trust >= 0.6, do: "Deeply trusts"
  defp trust(trust) when trust >= 0.2, do: "Trusts"
  defp trust(_trust), do: nil

  defp actor(cid, entities) do
    case Enum.find(entities, &(&1.entity_id == cid)) do
      nil -> "actor #{cid}, who is not nearby"
      entity -> "#{name(entity.name)} (actor #{cid})"
    end
  end

  # 近期经历的原文由 Life 写成，这里原样列出。
  defp happened([]), do: "Nothing new."
  defp happened(texts), do: "Oldest first. " <> Enum.join(texts, " ")

  defp remembered(%{models: [], memories: []}), do: "Nothing relevant."

  defp remembered(%{models: models, memories: memories}) do
    Enum.join(
      ["My own memories and beliefs; they may be out of date and are not current world facts."] ++
        for({id, text} <- models, do: "- Belief (#{id}): #{text}") ++
        for(memory <- memories, do: "- Recalled: #{memory["text"]}"),
      "\n"
    )
  end

  # 眼前的处境：Observation 里现有的字段，加 Life.mind 现查 World 得到的“我的建筑”在不在。
  defp situation(%{self: %{position: {x, y, z} = position} = self} = observation, buildings) do
    others = Enum.reject(observation.entities, &(&1.entity_id == self.entity_id))

    Enum.join(
      ["Standing at x=#{metres(x)}, z=#{metres(z)} (height #{metres(y)})."] ++
        life(self.body_state) ++
        [nearby(others, position)] ++
        Enum.map(buildings, &building/1) ++ [inventory(observation.balances)],
      " "
    )
  end

  defp building(%{name: name, anchor: {ax, ay, az}, standing: standing}),
    do: ~s|My building "#{name}" at (#{ax}, #{ay}, #{az}) is #{if standing, do: "standing", else: "gone"}.|

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
        "#{activity}: #{result(result)}."
      end)
  end

  defp distance({x, y, z}, {ox, oy, oz}),
    do: :math.sqrt((x - ox) ** 2 + (y - oy) ** 2 + (z - oz) ** 2)

  defp metres(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)
end
