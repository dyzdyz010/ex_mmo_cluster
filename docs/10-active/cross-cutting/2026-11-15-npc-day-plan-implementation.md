# NPC 日计划层实现设计（第十五个统筹会话，2026-11-15）

上位：[决策稿](2026-11-14-npc-day-plan-decision.md)（含用户的四项决定）、离线测量 S1-R8（本地 `.demo/observe/npc-slice1-20261112/s1r8/`，判定见决策稿“进度”）。本稿只定**怎么拆实现**；每步实现后写进代码的 moduledoc / README 的是“现状”，本稿记决定与理由。

## 0. 前提（对着代码核过）

- **词表不是系统动作**：候选（`guard_hut`、`visit_plaza` 等）是各 NPC 登记参数 `profile.activities` 里的 `name` + `criterion`，系统只有三种候选形状——技能（build / gather / expand / travel）、`place`+`stay_ticks`（走到某处待一阵）、`person`+`stay_ticks`（走到某人身边待一阵）（`registry.ex` moduledoc）。`completed` 只表示“走到了并待够了 / 技能做完了”，系统不知道它在语义上算不算“守”。计划词表 = 该 NPC 的 `profile.activities`，计划不新增任何动作。
- **产生者**：活动一结束，Runtime（`runtime.ex` 的 `choose_activity`）经 `Selector.experience/2` 把经历交 Life（`Life.activity/2`）；`Selector.history` 的每项带 `activity` 与 `result: :completed | {:failed, …}`。“按 Outcome 计数”的计数事件就是这一条，现在交给 Life 的 `experience` 里没有活动名与结果，要加。
- **时钟**：`observation.world_time = %{day:, minute_of_day:, weekday:}`（Runtime 每帧写入）。日号 / 分钟取自它，不再用 `day_ms`。
- **持久行与槽**：Life 的 `"reflection"` 键与反思槽是现成先例（`life.ex`：`empty_reflection`、`accept_world` 里 `put_new` 补旧行、`worker/2` 起槽、`{:reflected, …}` 落栏、`DOWN` 处理）。规划槽与它同构，写作接口共用（`journaling.write`，即 `NPC_REFLECT_*`）。
- 旧 `NpcServer.DayPlan` + `LlmBudget` 未接线（无任何注册表入口启动它），中文提示词、现实 24 分钟分日，**整个删除**；“DayPlan 重写成更小的意图持有者”实现为 `NpcServer.Life.DayPlan`（纯函数核心，同 `Life.Reflection` 的写法）。

## 1. 持久行 `"plan"`（Life 是唯一 owner）

字符串键、能原样过 JSON：

```
"plan" => %{
  "day"          => nil | 日号      # 当前意图属于哪个游戏日
  "intents"      => [%{"id", "activity", "times", "by", "why", "done"}]
                    # by = 日内分钟（0..1439）；done = 已记下的完成次数。状态不存，读时由代码推：
                    #   done >= times → done；否则（日号已过 或 此刻分钟 > by）→ missed；否则 open
  "wants"        => [%{"want", "why"}]   # cannot_yet：想做而词表写不出的事，由下一次规划的 LLM 留或撤
  "calls"        => %{"day" => nil | 日号, "n" => 0}   # 本游戏日发出了写作请求的规划调用数（起调用时 admit 先记；
                                                    #   写作之前就失败的落栏时退回；worker 崩溃 / Life 重启照扣；跨日清零。T7）
  "event_waiting" => false         # 有一条 kind:event 经历进来、等着触发重排
  "last_at_ms"   => nil | 毫秒     # 上一次起调用的时钟（防连发的最小间隔用）
  "last"         => nil | %{"at_ms", "kind" => "day" | "event", "result" => "adopted" | "failed" | "rejected", "reason"}
  "counts"       => %{"planned" => 0, "replanned" => 0, "failed" => 0, "rejected" => 0, "skipped" => 0}
}
```

不变量（决策稿 §5）：`done` 只由代码按 Outcome 增；LLM 只在规划调用里新写意图与留 / 撤 `wants`；规划失败（写作失败、检查不过）不挡选择，行里沿用上一份。

## 2. 纯函数核心 `NpcServer.Life.DayPlan`

- `new/0`（空的一份，上面的形状）。
- `check(text, activity_names, now_minute)`：S1-R8 的检查 1–5 原样（`stop_reason` 在调用方）：至多去一对 ``` 围栏；一个 JSON 对象、只有 `intents` / `cannot_yet` 两个键；意图键恰为 `activity,times,by,why`，`activity` ∈ 词表（逐字）、`times` 整数 ≥ 1、`by` 为 `HH:MM` 且严格晚于此刻、不晚于 23:59、`why` 非空串；`cannot_yet` 条键恰为 `want,why` 非空串；两表总条数 ≤ 5。返回 `{:ok, %{intents:, wants:}}`（`by` 已换成分钟）或 `{:error, 原因}`。
- `admit(plan, day, now_ms)`：当日 `calls.n < 5`（决策稿：规划 + 重排共 5 次）返回 `{:ok, plan'}`，跨日清零；否则 `{:error, :day_budget_exhausted}`。放行时记一次调用，并**记 `last_at_ms = now_ms`、清 `event_waiting`**（起调用就记：规划在途时 Life 重启、落栏保存失败之后也至少隔最小间隔；这次调用的材料在起槽时取，已含那条 event。T5，独立评审后）。T7（2026-11-16，用户定）：额度只扣**发出了写作请求**的调用——`admit/3` 照旧起调用就记一次，`Round.write/1` 的结果多一个 `wrote`（写作函数被调用过为真，不论成败；写作接口连接被拒也算），Life 落栏时对 `wrote: false`（此刻一块失败、召回失败、`:no_materials`）调新纯函数 `refund(plan)` 把那一次退回（`calls.n` 减一，不判日号：槽在途时 Life 不查触发、不会有 `admit` / `skip` 改 `calls`，Life 重启丢槽不落栏，所以落栏时 `calls` 恒是起槽那次记下的、`n ≥ 1`；跨日落栏照常退回，下一帧 `admit` 再清零），失败照记 `counts.failed` / `last`，`last_at_ms` 不动；worker 崩溃与调用在途时 Life 重启不知道发没发出，按发出算、不退。依据：实跑 S1-R10 的 8 次规划调用里 4 次没问到模型（出生 `:no_materials` 1、Hindsight 召回 `:timeout` 2、连接被拒 1），照样各扣一次，第 506 天 5 次用完；按此定义，其中连接被拒那次仍扣。
- `due(plan, day, now_ms)`：此刻该不该起一次规划——`:day`（`plan["day"] != day`）或 `:event`（`plan["day"] == day` 且 `event_waiting`）或 nil；距 `last_at_ms` 不足 `@min_gap_ms`（3 分钟，原创取值，实跑后调）一律 nil。
- `adopt(plan, day, now_minute, checked, kind, at_ms)`（实现里多了 `now_minute`：判断旧意图是否已结束要用它）：采用一份检查合格的计划：同日重排保留已 `done` 与已 `missed` 的旧意图、换掉 open 的；跨日整份换；新意图 `id = "<day>:<序号>"`、`done = 0`；`wants` 整份换成新的；记 `last`、`last_at_ms`、计数；**不碰 `event_waiting`**（调用在途时新来的 event 要留给下一次重排）。条目总数上限 8（超出丢最旧的保留项；新意图至多 5 条，丢不到）。
- `fail(plan, kind, :failed | :rejected, reason, at_ms)`：写作失败 / 崩溃 / 检查不过：意图与 `wants` 不动，记 `last`、`last_at_ms`、计数；`:event` 失败把 `event_waiting` 恢复为真，`:day` 失败不恢复。`skip(plan)`：当日额度用完时 `counts.skipped + 1`。`status(plan, intent, {day, minute})`：`:done | :missed | :open`。
- `record_activity(plan, {kind, object}, day, minute)`（稿 A 批 0b 起按种类 + 对象，原为候选名）：一项活动 **completed**（失败不计）时调用：在种类相同、今天、`open`（`done < times` 且 `minute <= by`）的意图里，**先取点名的就是这个对象的**，没有再取没点名的（`object` 为 nil 或旧行无此键），各取 `by` 最早的一条 `done + 1`。点名优先是稿 A 批 0 评审修正：混在一起按时限取会让点名那条白白落空。计划不是今天的原样返回；`done` 不是 `{种类, 对象}` 直接 `FunctionClauseError`。
- `note_event(plan)`：`event_waiting = true`。
- `column(plan, day, minute)`：给 Mind 的数据：今天的各条 `%{activity, times, done, by, status}` 与 `wants`；没有意图也没有 `wants` 为 nil。

## 3. 提示词 `NpcServer.Life.DayPlan.Prompt`

系统提示词与用户消息**逐字照 S1-R8**（`s1r8/plan.md` 的“提示词”；测试用 S1-R8 存下的真实请求体当金标：同样的人格、候选、三块材料，产出的 system / user 与存档字节相同）。用户消息 = 三块材料（`Right now:` / `What happened:` / `What I thought before …`，即 `Reflection.user_message/2` 去掉“要想的那件事”与 `Used:` 要求的部分）+ `Plan the rest of today now.`。只在非空时再加两块（所以“当日第一次且没有旧 `wants`”与测过的逐字相同）：`What I meant to do today, as it stands:`（今天已有的意图与状态，一条一行）与 `Things I wanted to do but could not yet:`（旧 `wants`）。`Reflection.user_message/2` 里三块材料的拼法抽成公用函数（输出不变，现有测试与反思夹具守住）。

## 4. 规划槽（worker）与触发

- `NpcServer.Life.DayPlan.Round.write(snapshot)`：此刻一块（`Life.standing` + `Mind.right_now`）→ 材料（用“自己”一问的两次召回与“之前的想法”，与 S1-R8 取材同一路径；从 `Reflection.Round` 抽出公用的取材函数，不复制）→ 写一次（不重问）→ `DayPlan.check/3`。返回 `%{result: :ok | {:failed, 原因} | {:rejected, 原因}, checked: %{intents:, wants:} | nil, elapsed_ms:, usage:, wrote:}`（`wrote`：写作函数被调用过没有，T7）；每步一行 `npc_plan cid=… event=…` 日志，正文不进日志。
- Life：新槽 `plan`（与 `poll` / `job` / `reflect` 并列）；`EXIT` / `DOWN` 照反思槽的处理；落栏 `{:planned, outcome}` 是一次保存：成功 → `adopt/5`，失败 → `counts.failed`（或 `rejected`）、行里意图不动。**只有 profile 带写日记接口的 Life 规划**（同反思）。
- 触发（在 `{:observation, …}` 与接纳经历的路径里查 `due/3`，到点且槽空、有观察、`admit` 过才起）：`:day`（本游戏日还没有采纳过的计划）与 `:event`（`kind:event` 经历到来，经 `note_event`）。到点而当日额度用完：每个游戏日只记一笔 `counts.skipped` 与一行日志（槽在途、没有观察、身体状态还没到时不查、不计数——触发逐帧查，那样记会随帧数增长），不清触发条件；触发还要求观察里有身体状态（规划的“此刻”一块需要它）。其余触发（计划耗尽、被直呼等）记后期。T7（2026-11-16，用户定）：触发再加一条“这个 NPC 有过至少一条经历”——还没写进 Hindsight 的（`"pending"` / `"fragments"` 非空）或已写进的（持久行现成字段 `"retained"`，写成功的片段累计数，只增不减，大于 0 即写进过；重启后的老 NPC 靠它），没有就不起调用、不 `admit`、不记失败、不记 `skipped`（同身体状态那一条）；不新增持久字段。依据：S1-R10 出生那一次规划没有任何材料（`:no_materials`），白耗一次额度并锁住最小间隔。
- 活动记账：`Selector.experience/2` 的返回加 `activity`（名字）与 `completed`（布尔）；`Life.activity/2` 在接纳那条经历的**同一次保存**里 `record_activity`。

## 5. Mind 栏（`Plans and promises`）

Life 的 `mind/2` 视图加 `plan`（`column/3` 的结果）；`Mind.snapshot` 在 `What I have come to think` 之后、`Current situation` 之前加一栏，英文、代码渲染，**不点名该选什么**。形式：每条意图一行，`<activity>: <done> of <times> done, by HH:MM` / `… — finished` / `… — not finished by HH:MM`；`wants` 各一行 `I would like to <want>, but I cannot do that yet`。没有内容整栏不出现（state 与现在逐字节相同）。`What I have come to think` 先与它并存（决策稿 D-3）。

## 6. 拆任务（顺序做；同一个 worktree，不并行跑 mix）

1. **T1** 纯核心 `Life.DayPlan` + 单元测试（新文件）。
2. **T2** `Life.DayPlan.Prompt` + `Reflection.user_message` 抽公用函数 + 金标测试（把 S1-R8 的一份真实请求体复制进 `test/support/fixtures/day_plan/`）。
3. **T3** `Selector.experience` 加字段、`Life.activity/2` 记账、Life 的 `"plan"` 键（初值 / 补旧行）、规划槽、触发、`mind/2` 与 `observe/1` 的 `plan`、`Life.DayPlan.Round`（含取材函数从 `Reflection.Round` 抽出）。Life 测试。
4. **T4** `Mind` 栏、删除旧 `DayPlan` / `LlmBudget` / Runtime 里的挂接与它们的测试、README 与 moduledoc（含数据流图查出的三处不一致）。
5. 独立代码评审（不带结论）→ 解决 → npc_server 全套 → 本地提交（每步先测后提交，动了共享契约的提交跑全套）。
6. ③ 计划栏对选择的作用：离线对照；再闭环实跑（先写计划与期望、告知用量）。

## 7. 范围外（后期，不在搭层阶段做）

- 规划提示词措辞；“只是走过 / 看一眼”之类要不要登记一个短停留的 `place` 候选（登记内容，不是代码）；计划耗尽、被直呼触发的重排；`times` 作完成条件的校准；次数与容量的提示；`What I have come to think` 是否保留；计划进 Hindsight（`kind:plan`）；周意图。
