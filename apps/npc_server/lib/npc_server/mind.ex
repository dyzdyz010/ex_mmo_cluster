defmodule NpcServer.Mind do
  @moduledoc """
  全局系统功能：心智快照——控制链各层发问时唯一的上下文来源（总纲
  docs/10-active/cross-cutting/2026-11-12-npc-architecture-overview.md 的“共享心智”）。

  快照是发问那一刻从各 owner 现读拼出的只读视图，不另存：`snapshot/4` 返回有序的栏 `[{英文栏名, 英文正文}]`，
  `text/1` 把它转成给模型的英文 state。每一栏只有一个 owner，这里只读；栏的次序就是下表的次序：

  | 栏 | 内容 | owner |
  |---|---|---|
  | Now | 游戏钟此刻的时段与钟点 | 游戏钟（`MmoContracts.WorldTime`，Runtime 每帧写进观察的 `world_time`） |
  | Character | 人格卡的英文描述 | 注册参数（`profile.who`、`profile.persona`，`NpcServer.Persona`） |
  | Feelings and relationships | 此刻仍活跃的情绪（对谁、什么情绪、多强）与对各角色的信任 | Life（`Life.mind/2` 的 `feelings`、`relationships`） |
  | What just happened | 还没写进 Hindsight 的近期经历，每条前面写多久以前 | Life（`Life.mind/2` 的 `recent`、`now_ms`） |
  | What I remember | 缓存的认识（mental models）与按处境分路召回、合并后的记忆 | Hindsight，经 Life 的适配器（`Life.mind/2` 的 `models`、`memories`） |
  | What I have come to think（可缺） | 最近一轮反思写成的“自己”一问的收尾一句，只有原文，句首不加任何标注 | Life 的持久行，规则在 `Life.Reflection.thought/1`（`Life.mind/2` 的 `thought`） |
  | Plans and promises（可缺） | 今天打算做的几件事（活动、次数、时限、做了几次、此刻的状态）与想做而现在做不到的事 | Life 的持久行 `"plan"`，规则在 `Life.DayPlan.column/3`（`Life.mind/2` 的 `plan`） |
  | Current situation | 位置、生命、附近的人、我的建筑在不在、背包里非零的材料 | World / Scene，经 Body 的 Observation（派生缓存，不是世界真值）；建筑在不在是发问时现查 World（`Life.mind/2` 的 `buildings`） |
  | Recent activities | 最近做过的几件事及结果 | 选择器（`NpcServer.Selector` 的历史） |

  **What I have come to think**（R4，内容规范 §10.11 末尾用户对第 1 条的答复；写法 R4b，用户 2026-11-14 定）：只有一条，
  正文就是那句收尾句的原文——不改写、不截断，句首不加“多久以前”、不加 `I thought: `。**撤下的规则**：Life 给出 nil 时整栏不出现——
  还没有过任何一轮、这个形态不反思、或最近一轮没写成“自己”（中止、失败、丢弃；不沿用上一轮的那条——只对留下了小结的一轮成立，
  一轮已起而没留下小结时仍是上一轮那句，边界见 `NpcServer.Life` moduledoc 的“已知”清单）。
  位置是 S1-X2 / S1-X3 离线测过的。R4 曾在句首加“多久以前”与 `I thought: ` 两段标注（原创取值）；离线对照显示两段都在削弱这句话，
  所以去掉：同一份 state 里句首从 `About 12 hours ago` 换成 `Just now`，打算的活动的概率从约 .09 升到约 .8，
  而实跑中含这一栏的 state 过半（100 份里 55 份）句首在 5 小时以上（`.demo/observe/npc-slice1-20261112/s1r6/why-results.md`）；
  三份无人的基准上只有句子比 `I thought: <句>` 高 .18–.45（同目录 `age-results.md`；只有句子也是 S1-X3 当初测过的形态）。
  **已知代价**：这一句在一轮之内不随时间淡下去（从落栏到下一轮约现实 10 分钟，游戏里约 4 小时；2026-11-15 前 ×72 时是约 12 小时），过时的打算只靠下一轮重写或撤下；
  这在闭环里是好是坏离线看不出，要再实跑。整条日记、小屋与人的各条不进这里。

  **Plans and promises**（日计划，决策稿 `docs/10-active/cross-cutting/2026-11-14-npc-day-plan-decision.md` D-3，实现设计
  `2026-11-15-npc-day-plan-implementation.md` §5）：位置在 `What I have come to think` 之后、`Current situation` 之前
  （计划是“想做什么”，处境是“现在有什么”，先让模型读到前者；位置本身没有离线对照过）。
  **可缺的理由**：Life 给 nil 时整栏不出现——这个形态不规划、持久行还没采用过计划、或今天没有意图而 `wants` 也空——
  此时 state 与没有这一栏时逐字节相同。正文多行（栏内换行同 `What I remember`），先今天的各条意图、一条一行，写法是
  `plan_intent_line/1`（`<活动>: <做了几次> of <几次> done, by HH:MM` / `… — finished` / `… — not finished by HH:MM`）；
  再是 `wants`，每条一行 `I would like to <want>, but I cannot do that yet`，`<want>` 取模型原文，不改写、不去标点。
  意图的状态由 `Life.DayPlan.column/3` 在读时推出；计划不是今天的则只剩 `wants` 行。
  **不点名该选什么**：不写 `you should` / `next` / `remember` 之类的话，只陈述数目、时限与做不到的事（用户 2026-11-13 定“靠内容涌现”）。
  与 `What I have come to think` **先并存**（决策稿 D-3：离线对照计划栏对选择的作用之后再定留哪个）；这一栏对选择的作用还没测过。

  数值由代码转成给模型读的写法，模型不做算术、不读原始数值：

  - 情绪强度（Life 衰减后的值，0.1 及以下 Life 不给出）：≥ 0.4 `strong`，≥ 0.2 `moderate`，其余 `faint`。
    规则模式一次事件 +0.6、半衰期 120 秒，所以一次破坏之后约 70 秒内是 strong，约 190 秒内是 moderate，约 310 秒后不再出现。
  - 信任（−1..1，不随时间恢复）：≤ −0.6 `Deeply distrusts`，≤ −0.2 `Distrusts`，≥ 0.2 `Trusts`，≥ 0.6 `Deeply trusts`，
    其间不写。规则模式一次破坏 −0.35、一次帮助 +0.25。
  - 角色的写法：还在观察里的写 `名字 (actor <cid>)`，不在的写 `actor <cid>, who is not nearby`。
    带上 cid 是因为近期经历与记忆的原文也按 `名字 (actor <cid>)` 写人（写经历时取不到名字就只有 `actor <cid>`），模型要靠 cid 把两处对上。
    名字的写法（空名写 `someone unnamed`）、“附近的人”（观察里除自己以外的每个人）与距离都用 `Life.State` 的
    `person_name/1`、`others/1`、`distance/2`：写经历与写快照是同一套。
    处境栏的 `Nearby` 也写 `<名字> (<kind>, actor <cid>, <距离> m away)`：不能只靠情绪栏那一句把名字与 cid 对上
    （2026-11-12 S1-E 离线实测：去掉 Distrusts 一句后模型认不出附近的人就是记忆里的那个 actor；见 docs/10-active/cross-cutting/tools/jev/s1e_design.py）。
  - 与旁人的距离由代码算好。

  ## 游戏时间的写法（原文出自离线测量 S1-K，`docs/10-active/cross-cutting/tools/jev/s1k_design.py` 的 `now_line` / `words_ago`）

  NPC 看的是游戏钟（游戏钟设计页 `docs/10-active/cross-cutting/2026-11-13-world-clock-design.md`：现实 60 分钟 = 一个昼夜日，倍率 ×24；2026-11-15 前是 ×72、现实 20 分钟一日），
  不是 UTC；存进 Hindsight 的经历正文仍是 `At <UTC> (UTC), …`（Life 写入侧），这里不解析它，只用条目另存的毫秒时刻。

  - **Now** 栏：`It is <时段>, <HH:MM>.`，钟点取观察里 `world_time.minute_of_day`。时段按钟点的小时：
    05–11 `morning`、12–16 `afternoon`、17–20 `evening`、其余 `night`。
  - **多久以前**：两个真实时刻（Unix 毫秒）各经 `MmoContracts.WorldTime.game_us/1` 换成游戏时间后相减，按游戏小时换词：
    不足 0.25 小时写 `Just now, `；不足 48 小时按 0.5 小时四舍五入写 `About <N> hours ago, `（`1 hour`、`0.5 hours`、`13.5 hours`）；
    48 小时及以上按天四舍五入写 `About <N> days ago, `。放在句首，后面接经历原文。
    召回的记忆有事件时刻（`at_ms`）时同样前缀，没有时不写；反思新栏那一句不加（见上）。

  ## 记忆一栏的召回

  `recall_queries/2` 按处境给出至多四路召回的描述（`NpcServer.Life.Hindsight.recall/3` 的入参），次序即优先级：

  | 路 | 问句 | 过滤 | `max_tokens` |
  |---|---|---|---|
  | R1 附近的人（至多 2 人，近者在前；每人一路） | `What has happened between me and <名字> (actor <cid>)? Did they help, harm, or promise me anything?` | `tags: ["actor:<cid>"]`、`any_strict` | 700 |
  | R2 我的建筑（Life 记得的最近放下的那座；没有就省这一路） | `What has happened at my building "<名>"?` | `tags: ["place:<名>"]`、`any_strict` | 700 |
  | R3 未了与感受 | `What am I looking forward to, worried about, or have promised to do?` | 无 | 600 |

  三路都 `prefer_observations: true`、不按 `types` 过滤（带 mission 后不少事实被抽成 `world` 类型）。问句、tags 与 token 上限
  照离线重测 S1-Q 的原文（`.demo/observe/npc-slice1-20261112/s1q/plan.md` 的 R 部分）。
  各路由 Life 并行召回，`merge_recalled/1` 合成记忆栏里的一张清单：路的优先级 R1（近者在前）> R2 > R3，
  **各路保持 Hindsight 返回的次序**（它自己的相关性排序），每路取前 4 条（`@recall_quota`）还没被更高优先级的路取走的，按 id 去重。
  不按时间排：S1-Q 在真实导出上看到“路内新的在前”截掉了拆屋事实与“守屋 77 次，没人来”，手写材料上“旧的在前”又截掉了最近的事实
  （`s1q/results.md`）。召回条目的正文从第一个 ` | When:` 起是抽取器附加的时间 / 涉及者后缀，渲染时去掉。

  人格只来自人格卡：Life 状态里的 `caution` / `sociability` 不进快照（并入人格卡要迁移持久状态并牵动 `Brain.Social`，待做）。
  记忆与认识只是“我记得”，不是世界真值，这一栏的开头写明。与模型的交互一律英文；角色名字原样写入。
  背包只有材料号与单位数：材料名在 World 的目录里，不在 Observation 里，这里不另查；余额为 0 的材料不写。
  我放下的有名字的建筑，每座一句，在背包之前：`My building "<名>" at (<ax>, <ay>, <az>) is standing.` 或 `… is gone.`
  （坐标是锚点所在宏格；`is gone.` 是离线对照实测过的原文，见 docs/10-active/cross-cutting/tools/jev/s1c_diag.py 的 `SIT_GONE`）。
  哪几座来自 Life 的记忆，在不在只认发问那一刻 World 的现查结果；没有这样的建筑就一句不写。“受损但还在”不写（没有便宜的逐格读法）。

  `person/2` 按选择器从此刻的观察与 Life 的信任里选一个人（候选活动“去找某人”，`NpcServer.Trees.npc/1`）；
  “不信任”的界限与快照里写 `Distrusts` 的界限是同一个值。
  """
  alias MmoContracts.WorldTime
  alias NpcServer.Persona
  alias NpcServer.Life.State

  # 信任不高于它即“不信任”：快照写 Distrusts 与 person(:distrusted, _) 选人共用。
  @distrusts -0.2

  # 合并召回时每路最多取几条。原创取值（没有外部依据），在 S1-Q 的真实导出上量过一次（三种处境都留住了拆屋事实、
  # 对 Corvin 的愤怒与“守屋 77 次，没人来”，见 `.demo/observe/npc-slice1-20261112/s1q/remerge-rank-order.json`），实跑后调。
  @recall_quota 4

  # 附近的人至多给几路召回（近者优先）。出处：内容规范 §4 的 R1“上限 2 个”。
  @recall_people 2

  # 各路共用的召回参数（S1-Q 的 R 部分）：偏好已巩固的认识，不按类型过滤。
  @recall_common %{prefer_observations: true}

  @open_concerns Map.merge(@recall_common, %{
                   query: "What am I looking forward to, worried about, or have promised to do?",
                   max_tokens: 600
                 })

  @hour_us 3_600_000_000
  @day_us 24 * @hour_us

  @doc """
  一份快照：有序的栏 `[{栏名, 正文}]`。`profile` 含 `who` 与 `persona`；`observation` 是 Body 的 Observation
  （Runtime 已写入游戏钟 `world_time`）；`history` 是已结束的活动（`NpcServer.Selector.history/1`，旧在前，每项含 `activity` 与
  `result: :completed | {:failed, 动作名, 原因文字}`）；`life` 是 `NpcServer.Life.mind/2` 的视图。
  """
  @spec snapshot(map(), map(), [map()], map()) :: [{String.t(), String.t()}]
  def snapshot(profile, observation, history, life) do
    [
      {"Now", clock(observation.world_time)},
      {"Character", Persona.describe(profile.who, profile.persona)},
      {"Feelings and relationships", feelings(life, observation.entities)},
      {"What just happened", happened(life.recent, life.now_ms)},
      {"What I remember", remembered(life)}
    ] ++
      thought(life) ++
      plans(life) ++
      [
        {"Current situation", situation(observation, life.buildings)},
        {"Recent activities", recent(history)}
      ]
  end

  # 日计划新栏：Life 给出 `plan`（`Life.DayPlan.column/3` 的结果）才有这一栏，nil 时整栏不出现（state 与没有这一栏时逐字节相同）。
  # 严格取键（同 `thought/1`）：手造 `life` 的测试只有三处，都补了 `plan: nil`，漏给的调用方会在这里立刻崩而不是悄悄少一栏。
  # 正文多行：先今天的各条意图一条一行（`plan_intent_line/1`），再 wants 各一行；不点名该选什么，不写任何指令性的话。
  defp plans(%{plan: nil}), do: []

  defp plans(%{plan: %{intents: intents, wants: wants}}) do
    lines =
      Enum.map(intents, &plan_intent_line/1) ++
        Enum.map(wants, &"I would like to #{&1["want"]}, but I cannot do that yet")

    [{"Plans and promises", Enum.join(lines, "\n")}]
  end

  # 反思新栏：Life 给出那一句才有这一栏，没有就整栏不出现（state 与没有这一栏时逐字节相同）。
  # 正文只有收尾句原文，不加“多久以前”与 `I thought: `（R4b，依据见 moduledoc）；那一句的 `at_ms` 这里不读。
  defp thought(%{thought: nil}), do: []
  defp thought(%{thought: %{closing: closing}}), do: [{"What I have come to think", closing}]

  @doc "快照的英文转写：每栏一行 `栏名: 正文`，按栏的次序（“What I remember”一栏的正文自己可以有多行）。"
  @spec text([{String.t(), String.t()}]) :: String.t()
  def text(sections),
    do: Enum.map_join(sections, "\n", fn {title, body} -> title <> ": " <> body end)

  @doc """
  这次选择要发的各路召回（见 moduledoc 的表），按优先级排好：`[描述]`，每个描述是
  `%{query:, tags:, tags_match:, prefer_observations:, max_tokens:}`（R3 没有 tags 两项），直接交给 `Life.mind/2`。
  `observation` 是此刻的观察（附近的人与距离）；`buildings` 是 Life 记得的“我放下的有名字的建筑”
  （`Life.State` 的 `"buildings"`，按放下的次序），取最后一座。
  """
  @spec recall_queries(map(), [map()]) :: [map()]
  def recall_queries(%{self: self} = observation, buildings) do
    people =
      observation
      |> State.others()
      |> Enum.sort_by(&{State.distance(self.position, &1.position), &1.entity_id})
      |> Enum.take(@recall_people)
      |> Enum.map(fn %{entity_id: cid, name: name} ->
        Map.merge(@recall_common, %{
          query:
            "What has happened between me and #{State.person(cid, %{cid => name})}? " <>
              "Did they help, harm, or promise me anything?",
          tags: ["actor:#{cid}"],
          tags_match: "any_strict",
          max_tokens: 700
        })
      end)

    building =
      case List.last(buildings) do
        nil ->
          []

        %{"name" => name} ->
          [
            Map.merge(@recall_common, %{
              query: ~s|What has happened at my building "#{name}"?|,
              tags: ["place:#{name}"],
              tags_match: "any_strict",
              max_tokens: 700
            })
          ]
      end

    people ++ building ++ [@open_concerns]
  end

  @doc """
  把各路召回的结果合成记忆栏的一张清单。`routes` 是各路返回的条目列表，按 `recall_queries/2` 的次序（即优先级）；
  每路保持 Hindsight 返回的次序，取前 #{@recall_quota} 条还没被更高优先级的路取走的（同一路里重复的 id 也只算一次）。
  条目是适配器规范化后的 `%{"id", "text", "type", "at_ms", "tags"}`，原样留在清单里。
  """
  @spec merge_recalled([[map()]]) :: [map()]
  def merge_recalled(routes) do
    {merged, _taken} =
      Enum.reduce(routes, {[], MapSet.new()}, fn results, {merged, taken} ->
        picked =
          results
          |> Enum.reject(&MapSet.member?(taken, &1["id"]))
          |> Enum.uniq_by(& &1["id"])
          |> Enum.take(@recall_quota)

        {merged ++ picked, Enum.into(picked, taken, & &1["id"])}
      end)

    merged
  end

  @doc """
  按选择器选一个人 → `{:ok, %{entity_id:, entity_epoch:}}`（与关注动词的目标同一身份形状）或 `{:error, 原因}`。
  `:distrusted`：观察里除自己以外、Life 信任 ≤ −0.2 的人中信任最低者；同值取近的（与处境栏同一距离），再同取 entity_id 小的。
  没有这样的人 → `:nobody_distrusted`；观察里还没有 Life 的规范状态（Runtime 还没收到）→ `:life_not_ready`。
  """
  @spec person(:distrusted, map()) ::
          {:ok, map()} | {:error, :nobody_distrusted | :life_not_ready}
  def person(:distrusted, %{life: %{state: state}, self: self} = observation) do
    trust = Map.new(State.relationships(state), &{&1.actor, &1.trust})

    candidates =
      for e <- State.others(observation),
          value = Map.get(trust, e.entity_id),
          value <= @distrusts,
          do: {{value, State.distance(self.position, e.position), e.entity_id}, e}

    case candidates do
      [] ->
        {:error, :nobody_distrusted}

      _ ->
        {_, e} = Enum.min_by(candidates, &elem(&1, 0))
        {:ok, %{entity_id: e.entity_id, entity_epoch: e.entity_epoch}}
    end
  end

  def person(:distrusted, _observation), do: {:error, :life_not_ready}

  @doc "一项活动的结局的英文写法（“最近做过的事”一栏与活动经历共用）。"
  @spec result(:completed | {:failed, String.t(), String.t()}) :: String.t()
  def result(:completed), do: "completed"
  def result({:failed, act, reason}), do: "failed (#{act}: #{reason})"

  @doc """
  反思用的“此刻”一块（`Right now:` 标题之后的三行，内容规范 §10.11、离线脚本 `s1x2_reflect.py` 的 `right_now_block`）：

      <Now 栏正文> It is day <world_time.day>.
      <Current situation 栏正文>
      My body: life <四舍五入> of 100, <no injuries or ailments | with <伤病的词>>.

  Now 栏与 Current situation 栏就是快照的同一套渲染（`clock/1`、`situation/2`）；`buildings` 是现查 World 的结果
  （`Life.standing/2`）。`observation.self.body_state` 必须已收到（不是 nil，调用方先判）。伤病标签按离线脚本的
  `INJURY_WORDS` / `MECHANICAL_INJURY` 写成词（标签集合取自 scene_server `body.ex` 的 `injuries/1`）；未知的标签直接崩，同脚本。
  """
  @spec right_now(map(), [map()]) :: [String.t()]
  def right_now(
        %{self: %{body_state: %{} = body}, world_time: world_time} = observation,
        buildings
      ),
      do: [
        clock(world_time) <> " It is day #{world_time.day}.",
        situation(observation, buildings),
        body_sentence(body)
      ]

  @doc "Now 栏的正文：`It is <时段>, <HH:MM>.`（S1-K 的 now_line，去掉栏名）；`world_time` 是观察里的游戏钟。"
  @spec clock(map()) :: String.t()
  def clock(%{minute_of_day: minute}) do
    hour = div(minute, 60)
    "It is #{period(hour)}, #{two_digits(hour)}:#{two_digits(rem(minute, 60))}."
  end

  @doc """
  今天的一条意图写成一行英文（`NpcServer.Life.DayPlan.column/3` 的一项，`by` 是日内分钟，写成两位的 `HH:MM`）：

      :open    <activity>: <done> of <times> done, by HH:MM
      :done    <activity>: <done> of <times> done — finished
      :missed  <activity>: <done> of <times> done — not finished by HH:MM

  规划的用户消息里 `What I meant to do today, as it stands:` 一块（`NpcServer.Life.DayPlan.Round`）用它；写法是原创取值，
  S1-R8 没有测过这一块。只陈述数目与时限，不点名该做什么。
  """
  @spec plan_intent_line(%{
          activity: String.t(),
          times: pos_integer(),
          done: non_neg_integer(),
          by: non_neg_integer(),
          status: :open | :done | :missed
        }) :: String.t()
  def plan_intent_line(%{activity: activity, times: times, done: done, by: by, status: status}) do
    count = "#{activity}: #{done} of #{times} done"

    case status do
      :open -> "#{count}, by #{hh_mm(by)}"
      :done -> "#{count} — finished"
      :missed -> "#{count} — not finished by #{hh_mm(by)}"
    end
  end

  defp hh_mm(minute), do: "#{two_digits(div(minute, 60))}:#{two_digits(rem(minute, 60))}"

  defp period(hour) when hour in 5..11, do: "morning"
  defp period(hour) when hour in 12..16, do: "afternoon"
  defp period(hour) when hour in 17..20, do: "evening"
  defp period(_hour), do: "night"

  defp two_digits(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # 句首的“多久以前”（S1-K 的 words_ago）：真实时刻换成游戏时间再相减，整数微秒运算，不经浮点。
  # 不足 0.25 游戏小时 → Just now；不足 48 小时 → 四舍五入到 0.5 小时；否则四舍五入到天。
  defp ago(at_ms, now_ms) do
    elapsed = WorldTime.game_us(now_ms * 1000) - WorldTime.game_us(at_ms * 1000)

    cond do
      4 * elapsed < @hour_us ->
        "Just now, "

      elapsed >= 48 * @hour_us ->
        "About #{count(div(2 * elapsed + @day_us, 2 * @day_us), "day")} ago, "

      true ->
        # 半小时数 = floor(小时 × 2 + 1/2)。
        halves = div(4 * elapsed + @hour_us, 2 * @hour_us)

        if rem(halves, 2) == 0,
          do: "About #{count(div(halves, 2), "hour")} ago, ",
          else: "About #{div(halves, 2)}.5 hours ago, "
    end
  end

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"

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
  defp trust(trust) when trust <= @distrusts, do: "Distrusts"
  defp trust(trust) when trust >= 0.6, do: "Deeply trusts"
  defp trust(trust) when trust >= 0.2, do: "Trusts"
  defp trust(_trust), do: nil

  defp actor(cid, entities) do
    case Enum.find(entities, &(&1.entity_id == cid)) do
      nil -> "actor #{cid}, who is not nearby"
      entity -> "#{State.person_name(entity.name)} (actor #{cid})"
    end
  end

  # 近期经历的原文由 Life 写成（不带时刻），这里在句首加多久以前。
  defp happened([], _now_ms), do: "Nothing new."

  defp happened(recent, now_ms),
    do: "Oldest first. " <> Enum.map_join(recent, " ", &recent_item(&1, now_ms))

  @doc """
  一条还没写进 Hindsight 的近期经历（`Life.mind/2` 的 `recent` 的一项 `%{at_ms:, text:}`）：句首写多久以前，后接原文。
  “What just happened”一栏与反思的“发生过的事”共用这一写法。
  """
  @spec recent_item(map(), integer()) :: String.t()
  def recent_item(%{at_ms: at_ms, text: text}, now_ms), do: ago(at_ms, now_ms) <> text

  defp remembered(%{models: [], memories: []}), do: "Nothing relevant."

  defp remembered(%{models: models, memories: memories, now_ms: now_ms}) do
    Enum.join(
      ["My own memories and beliefs; they may be out of date and are not current world facts."] ++
        for({id, text} <- models, do: "- Belief (#{id}): #{text}") ++
        for(memory <- memories, do: "- Recalled: #{recalled(memory, now_ms)}"),
      "\n"
    )
  end

  @doc """
  一条召回条目（适配器规范化的 `%{"text", "at_ms", …}`）的正文：去掉抽取器的 ` | When: … | Involving: …` 后缀；
  有事件时刻才在句首写多久以前。记忆栏与反思的“发生过的事”共用这一写法。
  """
  @spec recalled(map(), integer()) :: String.t()
  def recalled(%{"text" => text} = memory, now_ms) do
    [plain | _] = String.split(text, " | When:", parts: 2)

    case memory["at_ms"] do
      nil -> plain
      at_ms -> ago(at_ms, now_ms) <> plain
    end
  end

  @doc """
  Current situation 栏的正文：Observation 里现有的字段（位置、生命、附近的人、背包），加现查 World 得到的“我的建筑”
  在不在（`buildings` 是 `Life.standing/2` 的结果）。快照与反思的“此刻”共用这一写法。
  """
  @spec situation(map(), [map()]) :: String.t()
  def situation(%{self: %{position: {x, y, z} = position} = self} = observation, buildings) do
    others = State.others(observation)

    Enum.join(
      ["Standing at x=#{metres(x)}, z=#{metres(z)} (height #{metres(y)})."] ++
        life(self.body_state) ++
        [nearby(others, position)] ++
        Enum.map(buildings, &building/1) ++ [inventory(observation.balances)],
      " "
    )
  end

  defp building(%{name: name, anchor: {ax, ay, az}, standing: standing}),
    do:
      ~s|My building "#{name}" at (#{ax}, #{ay}, #{az}) is #{if standing, do: "standing", else: "gone"}.|

  # 本会话还没收到身体状态（nil）时不写这一句。
  defp life(nil), do: []
  defp life(%{life: life}), do: ["Life #{round(life)} of 100."]

  # 反思“此刻”的身体一句（离线脚本 `body_sentence` 逐字移植；原创写法，量是真实的；不写开尔文数、不写因果）。
  # 生命四舍五入用 Elixir 的 round/1（同上面 `life/1`）；离线脚本的 Python round 在恰好 .5 时取偶，两者只在这时不同。
  defp body_sentence(%{life: life, injuries: injuries}) do
    tail =
      case Enum.map(injuries, &injury_word(&1.tag)) do
        [] -> "no injuries or ailments"
        words -> "with " <> join_words(words)
      end

    "My body: life #{round(life)} of 100, #{tail}."
  end

  # 伤病标签 → 英文词（离线脚本 `INJURY_WORDS` / `MECHANICAL_INJURY`，标签集合取自 scene_server body.ex 的 injuries/1）。
  # 未知标签直接崩（同脚本）：新的伤病种类要先在这里写词。正则写在函数里（较新的 OTP 不能把编译好的正则存进模块属性）。
  defp injury_word("temperature.hypothermia"), do: "hypothermia"
  defp injury_word("temperature.hyperthermia"), do: "hyperthermia"
  defp injury_word("trauma.thermal.burn"), do: "a burn"
  defp injury_word("trauma.thermal.frostbite"), do: "frostbite"
  defp injury_word("nutrition.hunger"), do: "hunger"
  defp injury_word("recovery.weakness"), do: "weakness"
  defp injury_word("nervous.daze"), do: "a daze"

  defp injury_word(tag) do
    [_, part] = Regex.run(~r/^trauma\.mechanical\.(head|torso|legs)$/, tag)
    "an injury to the #{part}"
  end

  # 同脚本 `join_words`：一个词原样；多个词前面的用逗号连、最后一个用 and。
  defp join_words([word]), do: word

  defp join_words(words) do
    {init, [last]} = Enum.split(words, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp nearby([], _origin), do: "Nobody else is nearby."

  defp nearby(others, origin) do
    "Nearby: " <>
      Enum.map_join(others, "; ", fn other ->
        "#{State.person_name(other.name)} (#{kind(other.kind)}, actor #{other.entity_id}, #{metres(State.distance(origin, other.position))} m away)"
      end) <> "."
  end

  # Scene 的角色种类码：0 = 玩家，1 = NPC。
  defp kind(0), do: "player"
  defp kind(1), do: "NPC"

  # nil = 还没取过余额；只列余额非零的材料，全是零与空表一样写 empty。
  defp inventory(nil), do: "Inventory: not checked yet."

  defp inventory(rows) do
    case Enum.reject(rows, &(&1.balance == 0)) do
      [] ->
        "Inventory: empty."

      held ->
        "Inventory: " <>
          Enum.map_join(held, ", ", fn %{material: material, balance: balance} ->
            "material #{material}: #{balance} units"
          end) <> "."
    end
  end

  defp recent([]), do: "None yet."

  defp recent(history) do
    "Oldest first. " <>
      Enum.map_join(history, " ", fn %{activity: activity, result: result} ->
        "#{activity}: #{result(result)}."
      end)
  end

  defp metres(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)
end
