defmodule NpcServer.Life do
  @moduledoc """
  NPC 人生状态唯一 owner，跟随 Runtime 生命周期。canonical 心智、World 游标、待写经历与认识缓存
  原子保存在 NpcMemory 的 life/state 行；观察只派生衰减视图。World 读取与 Hindsight 使用独立 worker，
  慢记忆写入期间继续接纳权威事件。

  经历条目（`"pending"` 与片段里）是 `%{"id", "at_ms", "text", "tags", …}`：`"text"` 是不带时刻的原文，时刻只在 `"at_ms"`，
  `"tags"` 是字符串列表（`kind:event | activity | conversation | sight | task`、`actor:<cid>`、`place:<名>`，召回按人、按地点精确调取）。
  交给 Hindsight 的正文是离线测过的 `At <UTC> (UTC), <原文>`，只由本模块的 `dated/1` 一处加前缀；
  心智快照拿到的是 `%{at_ms:, text:}`（不带前缀），由 `NpcServer.Mind` 按游戏时间写“多久以前”。
  短经历先按原文字数攒到约 3000 字封成片段 `%{"id", "at_ms", "episodes" => [经历条目]}`（片段只是运输批次）；
  retain 时每条经历单独成一份 Hindsight 文档（document_id = 经历 id，timestamp = 该条 `at_ms`，tags = 该条 tags），
  失败重发原片段里的同一批经历（文档 id 不变）。片段只有 `"text"` 的旧形状不做转换（用户 2026-11-13 定：开发数据清空重建）。

  记忆里的人一律写 `名字 (actor <cid>)`（`Life.State.person/2`，用户 2026-11-13 同意）：名字取自本 owner 此刻持有的观察
  （`observation.entities`），取不到写 `actor <cid>`；不建全局名字表。World 事件的经历见 `Life.State` 的标准描述表，说话的经历见
  `NpcServer.Dialogue.episode/3`。

  活动的期间事实：Runtime 选定新活动后调 `activity_started/1`，本 owner 从那一刻起每收到一帧观察就记下自己以外每个人
  到我的最小距离（`Life.State.approach/2`）；`activity/2` 接纳这项活动的经历时在原文末尾加一句期间事实（`Life.State.during/2`：
  谁进过 6 米内、结束时还在不在，或 `nobody came near`）。没有收到开始信号、或期间一帧观察都没有，就没有真值，不写这句。
  这份距离账只在进程内：Life 重启会丢掉正在进行的活动的账，那一条经历就不写期间事实（可接受，不持久化）。

  “看到的”（`Life.Sight`，内容规范 §9 的 A 相遇与 B 附近的建造 / 拆除）：每帧观察喂一次相遇账，每秒读到的 World 事件里
  不是我做的、没有被 `Life.State.advance/6` 写成“动我的建筑”经历的（按 seq 排除）喂一次分组账；两处都顺带做到点检查，
  不另开定时器。写出的条目（`kind:sight`）与其它经历一样进未封存的尾部、封存、保存；观察每秒 20 帧，没有条目时不保存。
  进行中的账在进程状态 `sight` 里，不落库：Life 重启即丢，不补写。上限挡下的打 `npc_sight_capped`，计数见 `observe/1` 的 `sight_capped`。

  World 事件只带被动那一格所属建筑的定义 id（`prefab`）；读取 worker 向 World 的发布元信息查出名字写进事件（`building`），
  经历原文由此说得出是哪座建筑、是整座没了还是毁掉一部分（标准描述表见 `Life.State`）。没有名字的定义与散格不点名。
  自己放下的有名字的建筑记进状态的 `"buildings"`（记忆）；`mind/2` 发问时逐座现查 World 此刻在不在，不用记忆冒充现状。
  已保存游标落后于同一 World 的保留窗时，接纳仍保留的权威操作，结束依赖连续事件的损坏与修复账。
  恢复批不产生所见。`observe/1` 的 `last_interaction_gap` 只读最近一次成功持久化的缺口范围，
  与心智、经历和恢复后的游标同次保存。保存失败时沿用上次游标，下一轮继续读。
  对话只接纳已发生的 Speech，以 conversation_id/turn 标识来源，不改 World 游标或心智数值；
  初次加载与存储失败期间保留未落盘输入，并以 unsaved_speech/error 显式呈现。
  CLI observe/flush/refresh/context 以永久 cid 定位本节点 owner；网络调用不会占用 Body 邮箱。
  统一形态（注册表 `"npc"`，规则模式）经三个入口用它：`mind/2` 是心智快照的只读视图（情绪与关系、还没写进 Hindsight 的
  经历、缓存认识与按处境并行的多路召回），`activity_started/1` 与 `activity/2` 标出一项活动的开始与结束（结束时接纳“做了什么、
  结果如何、期间谁来过”的活动经历）。统一形态不读状态里的
  `traits`（`caution` / `sociability`）：人格只来自人格卡，这两个值并入人格卡待做。

  ## 反思（内容规范 §10.11、§10.12 的 R3）

  只有 profile 带写日记接口（`reflect`，统一形态由 `NpcServer.Registry` 给出）的 Life 反思；没有的形态不计分、不记新经历、
  不起槽（形态差别，不是降级）。四个经历入口（World 事件、所见、活动、对话）经同一个私有函数接纳经历：进未封存的尾部，
  并逐条 `Reflection.record/2` 计分、把 `%{"at_ms", "tags"}` 记进“自上一轮开始以来的新经历”（`"new"`）。

  起一轮与消耗新经历：
  - **到点且起得了**（反思槽空着、已有观察）：在接纳经历的**同一次保存**里 `Reflection.started/2`（累计分清零、记下触发时刻）、
    `rounds` 加一，保存成功后起**单独的反思槽**（第三个 worker 槽 `reflect`，与读 World 的 `poll`、写 Hindsight 的 `job` 并列）。
    一批里多条都到点只起一轮：直接取最后一条给出的那一轮（时刻、累计分、原因；一批之内触发状态不清零，后一条的原因
    必然包含前一条的）。槽里的流程见 `Reflection.Round`。
  - **到点却起不了**（槽在途 `busy`、还没有观察 `no_observation`）：不调 `started/2`，触发状态留着（下一条经历进来还会到点），
    `skipped` 加一、一行日志。
  - **新经历在落栏时才消耗**：起槽时把当时的 `"new"` 整份交给这一轮、槽上记下取走了几条；这一轮**做完**（每一问写成或丢弃）
    才在落栏那次保存里删掉 `"new"` 的前这几条（一轮进行中新来的排在后面，留给下一轮）。这一轮**中止**（写作或召回失败、
    问之前就失败、某一问没有材料、worker 在落栏前崩溃）则 `"new"` 不动，已写成的照常落栏，下一轮把这些对象再问一遍
    （“之前的想法”里就是这次写成的）。检查不合格被丢弃不算中止。Life 在一轮进行中重启也不丢新经历（触发状态已清零，等下一次到点）。
  - **时刻**（两个含义见 `Reflection` 的 moduledoc）：`"latest"` 各条、`"round"` 的 `"at_ms"` 与存档文档的时刻都是**想的时刻**
    ——起槽那一刻 Life 的时钟（槽上的 `now_ms`，同离线的 t′，日记是那一刻想的）；触发状态的 `"last_at_ms"` 是**触发时刻**
    ——`record/2` 给出的一轮的 `at_ms`，即触发那条经历的时刻（5 分钟间隔从它算）。

  为什么这样分：
  - **持久行是权威**：`life/state` 行的 `"reflection"`（触发状态、新经历、各问最新一条、最近一轮小结、计数）与其它键
    同一次保存，重启后还在；Hindsight 的反思库（`npc-reflect-<cid>`）只是存档，产品不从它读回。
  - **单独的槽**：一轮要串行写 2–3 次（每次约 9 秒），不能占住封存与认识刷新；它的失败不进 `job_error`、不挡 `automatic/1`。
  - **落栏时刻**：一轮写完才一次落进持久行（不逐问落），存档在落栏之后做、不挡落栏；存档失败只记数，不重试、不动已落栏的日记。
    落栏那次保存失败：一行 `event=persist_failed`，这一轮写成的日记没有落栏（不重试，同其它经历保存失败）；随后回来的存档结果
    只打日志、不碰行（槽上记着这一轮落栏了没有，存档结局只写进本轮自己的小结）。

  `"round"`（最近一轮的小结）：`"at_ms"`、`"causes"`、`"asked"` / `"written"` / `"discarded"` / `"failed"`（问题的键；worker 在
  落栏前崩溃时都是空表）、`"archive"`——`"none"` 没有可存的、`"pending"` 已落栏而存档结果还没回来（Life 在此期间重启就停在
  这个值，表示结果未知）、`"ok"`、`"failed"`。

  `"counts"`（累计，随行持久）：`rounds` 起了槽的轮数；`written` / `reasked` / `discarded` / `failed` 按问题计（写成、重问、
  检查两次都不合格丢弃、写作或召回失败或没有材料）；`aborted` 中止的轮数（含落栏前 worker 崩溃）；`skipped` 到点但没起成的次数；
  `archive_failed` 存档失败的轮数（含存档阶段 worker 崩溃）。

  进选择的只有一句（R4，内容规范 §10.11 末尾用户对第 1 条的答复）：`mind/2` 的 `thought` 是 `Reflection.thought/1` 对持久行
  `"reflection"` 的结果——最近一轮写成了“自己”一问就是那条的收尾一句与时刻，否则 nil（不沿用上一轮的；边界见下面“已知”清单的最后一条）；`NpcServer.Mind`
  据此写 `What I have come to think` 栏，正文只有那句收尾句的原文（R4b：不加“多久以前”与 `I thought: `；时刻只给 observe 看）。
  本模块不另判这条规则；整条日记与小屋、人的各条不进选择的 state。

  手动入口 `reflect/1`；`observe/1` 的 `reflection` 给出槽在不在途、触发状态、新经历条数、各问最新一条、最近一轮、计数、
  `thought`（此刻新栏里的那一句，同 `mind/2`）与
  `error`——最近一轮里最近一次失败的原因（写作阶段、落栏、存档、崩溃都算；只在进程内），起下一轮时清空，别的时候不清。
  日志一律 `npc_reflect cid=<cid> …`。

  已知的未设上限处与对不上的计数（只记事实，现在不加代码）：
  - “之前的想法”里其它对象的条数（此刻记得的建筑、关系表里的人、“自己”各一条）没有上限——现在一个 NPC
    只有一座建筑、一个有关系的人，多个 NPC 实跑之前再定。
  - `"new"`：写日记接口持续失败时每一轮都中止、`"new"` 不消耗，它就一直增长。
  - `"latest"`：在持久行里只增不减；已不在建筑表与关系表里的对象那一条留着不删（只是不进“之前的想法”）。
  - `rounds` 在两条路径上与其它计数对不上：Life 在一轮进行中重启、落栏那次保存失败——两者 `rounds` 都已加一（起轮那次
    保存里），但没有这一轮的 `"round"` 小结，也不计 `aborted`。
  - 新栏“不沿用上一轮”只对留下了 `"round"` 小结的一轮成立：起轮那次保存只动触发状态与 `rounds`，不动 `"round"`，所以
    一轮已起而还没留下小结时，`thought` 仍是上一轮写成的那句，直到下一轮落栏。正常进行中的一轮如此（几次写作的时长）；
    以下三条路径会让它一直留到**下一轮**落栏：Life 在一轮进行中重启（槽随进程没了，加载回来的行里还是上一轮的小结）；
    落栏那次保存失败（行不变）；worker 在落栏前崩溃、记中止小结的那次保存也失败（`save_reflection/2` 失败时行不变）。
    要不要改成“起轮即撤下”是决定层面的事，现在不改。

  ## 每日回顾与任务（日计划实现设计 `docs/10-active/cross-cutting/2026-11-15-npc-day-plan-implementation.md` §1、§4；任务层决策稿
  `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4，T-1a）

  一份计划是“今天我打算做几件事”：意图（词表里的种类 + 可选对象 + 次数 + 时限）与 `wants`（想做而词表写不出的事）。任务层 T-1a 起
  日计划退化为**每日回顾**：同一次规划调用另开 / 弃**任务**（一件要几步才做成的事，持久行 `"tasks"`，跨日留着）。规则都在纯函数核心：
  意图那一半（额度、触发判定、采用、记账、给 Mind 的数据）在 `Life.DayPlan`，任务那一半（采用回顾、步骤记账与 K-3 分类、新信息、
  到期与停滞、给 Mind 的数据）在 `Life.Tasks`，整份回顾应答的唯一校验点是 `Life.Tasks.check/3`；一次规划调用的流程在
  `Life.DayPlan.Round`。本模块只做触发、起槽、落栏、记账与视图。只有**规划的形态**规划：profile 带写日记的接口（同反思，
  写作接口与人格卡共用）且有候选表；其余形态不触发、不记账，`mind/2` 与 `observe/1` 的 `plan` / `tasks` 为 nil 或空。
  任务的**推进**（K-3 判出偏差 / 新信息时问模型这个任务下一步，T-1b）与回顾共用同一个规划槽，流程在 `Life.Tasks.Round`，见下文“任务推进”。

  - **词表**（稿 A 批 0b）：种类取 `NpcServer.Offers.plan_kinds/1`（按生成器次序：不对人的登记项各一个静态种类，对人的登记项各一个可点名人的种类（种类名 = 登记名，
    任务层稿 §7 ①），配了说话加 `speak_to`，批 1 起再加不可点名对象的 `eat` 与 `craft`），
    起槽那一刻展开对象交进快照的 `vocabulary`：可点名人的种类（对人的登记项与说话同一套）能点名的人是关系里的人 ∪ 此刻观察里的他人
    ∪ 开着的任务里点名过的人（`Tasks.people/1`；任务层稿 K-0 评审第 8 条：回顾时点名过、推进时已不在观察里的人仍可点名），显示名用名字层
    `State.person/2`（`名字 (actor <cid>)`，观察里没有名字时 `actor <cid>`），对象 `%{"actor" => cid}`。

  - **持久行 `"plan"`、`"tasks"`**（形状见 `DayPlan.new/0`、`Tasks.new/0`）与其它键同一次保存，重启后还在；之前存下的行在加载边界
    补成空的一份。
  - **触发只在每帧观察上查**（`maybe_plan/1`，便宜：不到点不写库、不打日志）：行已加载、规划的形态、规划槽空着、这个 NPC
    有过至少一条经历（还没写进 Hindsight 的 `"pending"` / `"fragments"` 非空，或已写进的 `"retained"` 大于 0；刚出生、一条都没有时
    规划无事可依，S1-R10 出生那一次就是 `:no_materials`）、观察里有游戏钟（`world_time`；日号与日内分钟都取它）与身体状态
    （`self.body_state`，与规划“此刻”一块同一条件，没到就起只会白锁最小间隔）、不在防抖期内，且 `DayPlan.due/3` 给出 `:day`
    （本游戏日还没有采用过计划）或 `:event`（接纳经历时有 `kind:event`，在那次保存里 `DayPlan.note_event/1`）。经历、身体状态、
    游戏钟不满足时不起调用、不记失败、不记 `skipped`。到点后 `DayPlan.admit/3` 记一次调用、起调用的时刻（`last_at_ms`，最小间隔
    从它算）并清 event 标记（这次的材料已含那条 event），保存成功才起槽；保存失败行不变，一秒之内不再试。槽在途、没有观察时不查，
    不计数。当日 2 次额度用完：每个游戏日只记一笔 `skipped` 与一行日志（那次保存成功之后才记下这一日；失败则一秒之内不再试）。
  - **规划槽**（第四个 worker 槽 `plan`，与 `poll` / `job` / `reflect` 并列，可与反思槽同时在途）：快照在起槽那一刻取齐，
    worker 不回头问 Life。结果落栏是一次保存：写成且检查通过 → `DayPlan.adopt/6`；写作失败、检查不过、worker 崩溃 →
    `DayPlan.fail/5`（意图与 `wants` 不动，选择照常；`:event` 失败把 event 标记恢复，留到下次）。采用时同一次保存里 `Tasks.review/4`
    开 / 弃任务，开 / 弃各一句标准句经历（`kind:task`）进未封存的尾部。当日 2 次（1 次日界 + 1 次事件）。**当日额度只扣发出了写作请求的
    调用**（T7，用户 2026-11-16 定）：结果说写作没有发出（`wrote: false`——此刻一块失败、召回失败、没有材料）时在同一次保存里
    `DayPlan.refund/1` 退回这一次；写作函数被调用过的（写作接口连接被拒、超时、检查不过也算）照扣；worker 崩溃不知道发没发出，
    按发出算、不退（防额度被反复崩溃绕过）。退回不动 `last_at_ms`，最小间隔照算。调用在途时又来的 `kind:event`
    照常记标记，落栏不清它，过了最小间隔再重排。日号、分钟、时刻都用**起槽那一刻**的：调用期间越过日界时，计划按起槽时的
    日号落栏，下一帧观察因日号变了再触发 `:day`（过了最小间隔）。
  - **活动记账**：`activity/2` 接纳活动经历的同一次保存里，完成的活动（结构化结局为 `:completed`）按它的 `{种类, 对象}`
    与此刻观察里的游戏钟 `DayPlan.record_activity/4`；失败与被打断的不计（`done` 只由代码按活动结果增）。同一次保存里不论结局
    `Tasks.record_step/4`（只记开着的任务的当头步；K-3 分类：前移、待推进 `failed` / `steps_done`，打断只记 log）。
  - **新信息**（K-3）：接纳经历的那次保存里（`accept/3`），`kind:event` 经历的出手者（经历的 `"actor"` 字段）、对我说话的人
    （对话经历存的原消息叫的是我，与 Runtime 唤醒同一口径 `Dialogue.direct?/2`；旁听别人之间的话不算）落在某个任务的 `Tasks.people/1` 里 → `Tasks.note_news/3`（`event` / `heard`）。
    只读结构化字段，不解析文字。
  - **到期与停滞**：每帧观察上 `Tasks.tick/3`（游戏日与 Life 时钟；常数级）；有变化（到期关为 expired 并写经历、停滞待推进）才保存。
  - **任务推进**（任务层决策稿 K-4、K-9）：规划槽（`job: :advance`）与回顾共用，一次只一个在途；每帧上回顾到点先起回顾，回顾没有起
    （不到点、当日额度用完、花费到线）才查推进。条件同回顾（槽空、有经历、观察里有游戏钟与身体状态、不在防抖期内）加 `Tasks.due/2`
    （距上次推进 ≥ 3 分钟、取最早开的 `waiting` 任务，一次一个）→ 花费闸门 `:task` → `Tasks.admit/3`（每人每游戏日 12 次，T-3 的学习写作
    共用这一计数）记一次调用并保存，保存成功才起槽。快照与回顾同一套材料（`planning_snapshot/4`），另带这个任务与其它开着的任务；
    槽里存这个任务此刻的基准（`Tasks.basis/2`：待做步骤与完成步数）。
    落栏一次保存：合格 → `Tasks.adopt/6` 先比对基准——写作在途时当头步做成前移了（步骤或完成数变了）就不采用（`stale`：任务原样、
    `waiting` 与连续不合格数不动、额度不退，下一次到点再问），任务已到期关掉为 `gone`；否则采用（continue 换待做步骤、清 `waiting`；
    done / drop 关掉，标准句后接 `note` 进经历）。不合格 → `Tasks.reject/4`（`waiting` 留着，连续 3 次关为 stuck 并写经历）；
    写作失败、worker 崩溃 → `Tasks.fail/1`；写作没有发出 → 同一次保存 `Tasks.refund/1`（崩溃不退，同回顾）。`cannot` 只计数并进落栏日志
    （交学习属 T-3）。12 次用完不记、不打日志。
  - **写作的出向上限**：回顾与推进每次写作 `max_tokens` 4096（`Tasks.write_max_tokens/0`，经写作函数按次交给 `Reflection.Writer`）；
    反思的写作不带，取 Writer 的缺省。
  - **视图**：`mind/2` 的 `plan` 是 `DayPlan.column/3` 对持久行与此刻游戏钟的结果，`tasks` 是 `Tasks.column/1`；`observe/1` 的 `plan` 是
    `%{enabled, running: 回顾在途, row: 持久行 "plan", column: 同 mind/2, error: 最近一次规划调用失败的原因（只在内存，起下一次时清空）}`，
    `tasks` 是 `%{row: 持久行 "tasks", running: 推进在途, task: 在推进的任务 id, calls: 当日调用数 %{"day", "n"}, counts, error: 最近一次推进
    失败 / 被拒的原因（只在内存）}`（不规划的形态为 nil）。
  - 日志：回顾 `npc_plan cid=<cid> …`（`start` / `end` 在槽里，`landed` / `persist_failed` / `crashed` / `skipped` 在本模块；
    `end` 与 `landed` 带 `wrote=true|false`，写成时带开 / 弃任务数）；任务 `npc_task cid=<cid> event=step|news|opened|dropped|expired|done|stuck …`，
    推进 `npc_task … event=start|end task= why=`（槽里）与 `event=landed|persist_failed|crashed task=`（本模块；`landed` 带结局
    `result=adopted|stale|gone|rejected|failed`、决定、`cannot`、`wrote`、当日调用数、用量）。

  已知的未设上限处与边界（只记事实）：
  - “当日额度用完只记一次 skipped”的标记只在内存：Life 在同一游戏日重启后，再到点会再记一次。
  - 规划槽在途时 Life 重启：调用已在那次保存里记过（`calls` 与 `last_at_ms` 不退还——不知道写作发出了没有，同 worker 崩溃
    按发出算；重启后照样隔最小间隔才再调用），结果随进程丢掉，不记 `failed`；行里的意图沿用上一份。
  - 落栏那次保存失败：调用已记、这一次的计划或失败都没有落进行里（写作之前就失败的那次也没退回）；`last_at_ms` 在起调用时
    已记，最小间隔照算。
  - 上面两条路径都会丢掉触发那次 `:event` 的条件：起调用时已清掉 event 标记，而落栏（含 `:event` 失败时的恢复）没有发生，
    这条 event 不再触发重排（调用在途期间新来的 event 已在接纳它的那次保存里记下，不受影响）。
  - 写作之前的失败不占当日额度，只受 3 分钟最小间隔约束：游戏钟 ×24 下一个游戏日是现实约 60 分钟，所以每游戏日至多约 20 次
    这样的调用，每次 2 路 Hindsight 召回（Hindsight 停摆、或材料长期为空时就会这样）。这是用户 2026-11-16 定的额度规则
    （只扣发出了写作请求的调用）的直接结果，现在不另设上限。
  - 每帧都调一次 Life 的时钟与 `DayPlan.due/3`（都是常数时间）。

  ## 花费额度（决策稿 `docs/10-active/cross-cutting/2026-11-18-npc-spend-budget-decision.md` §4.2、§7）

  每天模型花费的 owner 是 `NpcServer.SpendBudget`；本模块只在**自己的后台触发处**读它的类型化结论
  （`profile.life.spend`，生产由 `NpcServer.Registry` 注入 `&NpcServer.SpendBudget.background/0`；不给时恒为 `:open`——只有测试与
  直接用代码起 Life 的地方不给）。停了（`{:paused, %{day: 北京日}}`）时：

  | 后台工作 | 到线后 |
  |---|---|
  | 认识刷新槽（`automatic/1` 的刷新分支） | 不起（`dirty` 留着，恢复后下一次触发照常刷新） |
  | CLI `refresh/1` / `reflect/1` | `{:error, {:budget_exhausted, 北京日}}` |
  | 到点的反思 | 按 `cannot_start` 跳过：`skipped` 加一、`npc_reflect … event=skipped reason=budget_exhausted` |
  | 日计划（每日回顾） | 在 `DayPlan.admit/3` 之前拒：不记调用、不扣当日额度，`event` 标记留着 |
  | 任务推进（`:task`） | 在 `Tasks.admit/3` 之前拒：不记调用、不扣当日额度，`waiting` 留着；已写好的步骤照常是候选（执行不调模型） |
  | retain、读认识（`:models`）、选择、说话、召回 | 照常（Q-3 (b)：经历不丢；交互不过闸门） |

  每种后台工作每个北京日只打一行 `npc_spend_refused cid= kind=refresh|reflect|plan|task day=`；`observe/1` 的 `spend_refused` 是
  `%{种类 => 最近一次被拒的北京日}`（只在内存）。恢复不广播：次日结论变回 `:open` 后，由各自的下一次自然触发（下一条经历、
  下一帧观察、下一次落栏）照常起。
  """
  use GenServer
  require Logger
  alias NpcServer.{Dialogue, Memory, Offers, Persona, Life.State, Life.Hindsight, Life.Sight}
  alias NpcServer.Life.{Appraisal, DayPlan, Reflection, Tasks}
  alias NpcServer.Life.Reflection.{Round, Writer}
  @fragment_chars 3000
  # 起规划槽之前那次保存失败后，多久之内不再试（观察每秒 20 帧，不逐帧重试写库）：原创取值。
  @plan_retry_ms 1000
  @refresh_ms 600_000
  # 记忆任务槽（写 Hindsight、刷认识、读认识）失败后的重试退避：起点 30 秒、每次翻倍、上限 5 分钟，
  # 再乘一个按 cid 稳定的 0.75–1.25 抖动。原来 `job_error` 一置上就再也不会自动起槽——一次 Hindsight 抖动
  # 会让这个 NPC 在本进程生命周期里永久停止写记忆，而且没有告警（见召回隔离决策稿 S11 的亚稳态与
  # AGENTS.md §2.1 第 2 条：活性必须由 owner 自己维护）。退避状态只在内存，Life 重启即从头算。
  @job_retry_ms 30_000
  @job_retry_max_ms 300_000
  # 待写片段的硬上限（见 `cap_fragments/1`）：写盘后报告实际淘汰的最旧片段。
  @max_fragments 8
  # 心智快照 "What just happened" 一栏最多列多少条经历（见 `recent/1`）。
  @max_recent 40
  # 心智快照各路召回的单路上限（毫秒）：既是那一路 HTTP 请求的超时，也是并行时等那一路的墙钟上限。
  # 写入与认识刷新仍用适配器的长超时。
  @mind_recall_timeout_ms 10_000
  @initial_mind_wait_ms 10_000
  # 同时在途的召回路数上限（内容规范 §4：请求并发 ≤ 3）；`Mind.recall_queries/2` 至多给四路。
  @recall_concurrency 3

  @doc "由 Runtime 建立关联 owner；context 包含 cid、scene_id 和路由模块。"
  def start_link(owner, context, profile) do
    case GenServer.start_link(__MODULE__, {owner, context, profile}, name: name(context.cid)) do
      {:error, {:already_started, previous}} ->
        # Body transient 重启可以先于旧 Runtime 的关联进程退出；只等其真实退出，不复用旧 owner。
        ref = Process.monitor(previous)

        receive do
          {:DOWN, ^ref, :process, ^previous, _} ->
            GenServer.start_link(__MODULE__, {owner, context, profile}, name: name(context.cid))
        after
          5000 ->
            Process.demonitor(ref, [:flush])
            {:error, :life_owner_busy}
        end

      result ->
        result
    end
  end

  @doc "读取派生心智、持久游标及最近缺口、批写状态、缓存年龄和显式错误。"
  def observe(cid), do: call(cid, :observe)
  @doc "封存不足 3000 字的尾片段并后台批写；立即返回任务状态。"
  def flush(cid), do: call(cid, :flush)

  @doc """
  后台刷新四份认识；立即返回任务状态，决策不会调用此入口。花费额度停了后台时 `{:error, {:budget_exhausted, 北京日}}`、不起槽。
  """
  def refresh(cid), do: call(cid, :refresh)

  @doc """
  手动起一轮反思（CLI / 调试用，同 `flush/1` 的形状）：行没加载 → `{:error, :life_not_ready}`；没开反思 →
  `{:error, :reflection_disabled}`；槽在途 → `{:ok, %{status: :busy}}`；还没收到观察 → `{:error, :no_observation}`（不动触发状态、
  不计 `skipped`）；自上一轮以来没有新经历 → `{:ok, %{status: :empty}}`；否则这一刻起一轮（`Reflection.manual/2`，
  `causes: [:manual]`；同到点的一轮一样 `Reflection.started/2`、`rounds` 加一，与之同一次保存）→ `{:ok, %{status: :started}}`；
  那次保存失败 → `{:error, 原因}`，不起槽。有新经历而花费额度停了后台 → `{:error, {:budget_exhausted, 北京日}}`，不起槽、不动行。
  """
  def reflect(cid), do: call(cid, :reflect)

  @doc """
  读取缓存认识并以问句 `query`（字符串）恰好召回一次（一路、不加过滤，单次请求用适配器的长超时）；
  由 CLI 或模型请求 worker 调用。
  """
  def context(cid, query) do
    with {:ok, snapshot, %{routes: [memories]} = recalled} <-
           recollect(cid, [%{query: query}], :infinity) do
      context = %{
        mind: Appraisal.mind(snapshot.mind),
        mental_models: snapshot.cache["models"],
        model_metadata: snapshot.cache["metadata"],
        model_cached_at_ms: snapshot.cache["at_ms"],
        memories: memories,
        recall_latency_ms: recalled.latency_ms,
        memory_retrieval: :hindsight_once,
        memory_truth: "Subjective memory; not current numeric world truth."
      }

      {:ok,
       if(snapshot.mind["affect"],
         do: Map.put(context, :emotion_context, Appraisal.context(snapshot.mind)),
         else: context
       )}
    end
  end

  @doc """
  心智快照（`NpcServer.Mind`）用的只读视图，由选择位置的发问 worker 调用；读的是规则模式的状态。
  `queries` 是这次的各路召回描述（`NpcServer.Mind.recall_queries/2`，按优先级排好）：各路在调用者进程里并行
  （`Task.async_stream`，同时至多 #{@recall_concurrency} 路），每路的截止时间是适配器交给 `NpcServer.Http` 的那一个总超时
  （#{@mind_recall_timeout_ms} 毫秒；取连接另有交互车道的上限；调用方不再另设 Task 超时，见 `recollect/3` 的注释），
  等每一路各自结束后按 `NpcServer.Mind.merge_recalled/1` 合成一张清单。另给出还没写进 Hindsight 的经历。返回 `{:ok, 视图}`：

      now_ms         读视图那一刻 Life 的时钟（Unix 毫秒），Mind 用它算“多久以前”
      feelings       此刻仍活跃的情绪 `[%{emotion:, actor:, intensity:}]`（`Life.State.feelings/2`）
      relationships  对各角色的信任 `[%{actor:, trust:}]`（`Life.State.relationships/1`）
      recent         还没写进 Hindsight 的经历 `[%{at_ms:, text:}]`（正文不带时刻；已封存待写的片段在前，未封存的尾部在后；各自旧在前）
      models         缓存的认识 `[{id, 正文}]`，按 `Life.Hindsight.model_ids/0` 的次序
      memories       各路召回合并后的清单（适配器规范化的 `%{"id", "text", "type", "at_ms", "tags"}`）
      recall_ms      各路并行召回的墙钟耗时
      buildings      我放下的有名字的建筑此刻在不在 `[%{name:, anchor: {x, y, z}, standing: boolean}]`，按放下的次序。
                     问哪几座来自 Life 的记忆（`Life.State` 的 `"buildings"`）；在不在只认这一刻现查 World 的结果
                     （`VoxelRegion.World.instance_cells/2`：有格 = 在，`:instance_not_found` = 不在）
      thought        反思新栏的那一句 `%{closing:, at_ms:}` 或 nil（`Life.Reflection.thought/1` 对持久行 `"reflection"` 的结果；
                     这个形态不反思时恒为 nil；与 observe 的 `thought` 同形，Mind 只用 `closing`）
      plan           日计划给选择的数据 `%{intents:, wants:}` 或 nil（`Life.DayPlan.column/3` 对持久行 `"plan"` 与本 owner 此刻
                     观察里的游戏钟的结果；不规划的形态、观察里还没有游戏钟、没有意图也没有 wants 时为 nil；与 observe 的 `plan.column` 同一份）
      tasks          开着的任务给选择的数据 `[%{goal:, next:, completed:}]`（`Life.Tasks.column/1` 对持久行 `"tasks"`；不规划的形态为 []）

  读不到就是显式失败，不冒充“没有记忆”：`{:error, :life_not_running | :life_not_ready |
  {:life_models_unavailable, 原因} | 召回的失败原因 | :recall_timeout | World 路由或查询的失败原因}`。
  上一项活动的经历与计划进度还未保存时返回 `{:error, :activity_pending}`。
  **任何一路**失败或超时，整次视图都失败（不拿其余几路凑一张残缺的清单）；失败的那一路的问句与原因记进 `observe/1` 的 `recall`。
  新 NPC 的空 bank 召回为空是正常结果。World 读不到时不写“在”或“不在”，整份视图失败（World 调用退出时发问 worker 随之退出，
  同样是显式失败）。
  """
  def mind(cid, queries) do
    with {:ok, snapshot, recalled} <- recollect(cid, queries, @mind_recall_timeout_ms),
         do: mind_view(snapshot, recalled)
  end

  @doc """
  读取选择所用的规范心智，首次加载可等待一次。调用方用同一份快照中的建筑记忆生成召回问句。
  """
  def selection_mind(cid, query_builder) when is_function(query_builder, 1) do
    with {:ok, snapshot} <-
           call_server(name(cid), :selection_context, @initial_mind_wait_ms + 1_000),
         queries = query_builder.(snapshot.mind["buildings"]),
         {:ok, _, recalled} <- recollect(cid, snapshot, queries, @mind_recall_timeout_ms),
         {:ok, view} <- mind_view(snapshot, recalled) do
      {:ok, view, queries}
    end
  end

  defp mind_view(snapshot, recalled) do
    with {:ok, buildings} <- standing(snapshot.mind["buildings"], snapshot.context) do
      {:ok,
       %{
         now_ms: snapshot.now_ms,
         feelings: State.feelings(snapshot.mind, snapshot.now_ms),
         relationships: State.relationships(snapshot.mind),
         recent: snapshot.recent,
         models:
           for(
             id <- Hindsight.model_ids(),
             text = snapshot.cache["models"][id],
             do: {id, text}
           ),
         memories: NpcServer.Mind.merge_recalled(recalled.routes),
         recall_ms: recalled.latency_ms,
         buildings: buildings,
         thought: snapshot.thought,
         plan: snapshot.plan,
         tasks: snapshot.tasks
       }}
    end
  end

  @doc """
  记得的每座“我的建筑”（`Life.State` 的 `"buildings"`）此刻在不在：在调用者进程里逐座现查 World
  （`VoxelRegion.World.instance_cells/2`：有格 = 在，`:instance_not_found` = 不在），`context` 是本 owner 的会话身份（路由用）。
  返回 `{:ok, [%{name:, anchor: {x, y, z}, standing: boolean}]}`（记得的次序）或路由 / 查询的失败原因；没有记得的建筑就不路由、不查。
  心智快照（`mind/2`）与反思的“此刻”（`Reflection.Round`）共用。
  """
  def standing([], _context), do: {:ok, []}

  def standing(remembered, context) do
    with {:ok, route} <- context.router.route(context.scene_id) do
      Enum.reduce_while(remembered, {:ok, []}, fn building, {:ok, acc} ->
        [birth, occurrence] = building["instance"]

        case VoxelRegion.World.instance_cells(route.world_ref, {birth, occurrence}) do
          {:ok, _cells} -> {:cont, {:ok, [view(building, true) | acc]}}
          {:error, :instance_not_found} -> {:cont, {:ok, [view(building, false) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, views} -> {:ok, Enum.reverse(views)}
        error -> error
      end
    end
  end

  defp view(building, standing),
    do: %{name: building["name"], anchor: List.to_tuple(building["anchor"]), standing: standing}

  # 读一次 owner 快照，再在调用者进程里把各路召回并行做完（同时至多 @recall_concurrency 路），
  # 返回 `%{routes: [每路的结果，按 queries 的次序], latency_ms: 墙钟}`。
  #
  # 每路的截止时间只有**一个** owner：适配器交给 `NpcServer.Http` 的总超时（`timeout_ms`，Finch `request_timeout`；
  # 取连接另由车道的 `pool_timeout` 管，见 `NpcServer.Http` moduledoc 的超时契约）。这里不给 `Task.async_stream`
  # 设第二个超时，也不在第一路失败时停下：等每一路自己结束（成功、失败或超时，超时时 Finch 关掉那条连接、
  # Hindsight 在阶段边界停下）再按现行的“全有全无”规则合成，失败记第一条失败的那一路。
  # 依据见召回隔离决策稿 D-3a（按 Finch 决策稿 §3 改写）与 S8/S10。
  defp recollect(cid, queries, timeout_ms) do
    with {:ok, snapshot} <- call(cid, :context),
         do: recollect(cid, snapshot, queries, timeout_ms)
  end

  defp recollect(cid, snapshot, queries, timeout_ms) do
    config =
      if timeout_ms == :infinity,
        do: snapshot.config,
        else: Map.put(snapshot.config, :timeout_ms, timeout_ms)

    started = System.monotonic_time(:millisecond)

    results =
      queries
      |> Task.async_stream(
        fn query -> {query, snapshot.adapter.recall(config, query, snapshot.now_ms)} end,
        max_concurrency: @recall_concurrency,
        timeout: :infinity,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, {_query, {:ok, recalled}}} -> {:ok, recalled.results}
        {:ok, {query, {:error, reason}}} -> {:error, query, reason}
        # 适配器自己以退出结束时（被外部 kill、`:timeout` 之类）：折成失败，不让未匹配的退出形状把调用方崩掉。
        {:exit, {query, :timeout}} -> {:error, query, :recall_timeout}
        {:exit, {query, reason}} -> {:error, query, {:recall_worker_failed, exit_kind(reason)}}
      end)

    latency_ms = System.monotonic_time(:millisecond) - started

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      nil ->
        routes = for {:ok, recalled} <- results, do: recalled

        GenServer.cast(
          name(cid),
          {:recall, %{status: :done, routes: length(routes), latency_ms: latency_ms}}
        )

        {:ok, snapshot, %{routes: routes, latency_ms: latency_ms}}

      {:error, query, reason} ->
        GenServer.cast(
          name(cid),
          {:recall, %{status: :failed, error: reason, query: query.query}}
        )

        {:error, reason}
    end
  end

  @doc "接收 Body 当前场景身份和观察。`observed_at_ms` 是 Body 生成观察时的墙钟；不阻塞发送者。"
  def observation(pid, observation), do: GenServer.cast(pid, {:observation, observation})

  @doc "按观察的消息顺序接收 Body 会话结束通知。"
  def observation_lost(pid), do: GenServer.cast(pid, :observation_lost)

  @doc "记录社交决策及实际权威终态，并持久确认已完成的感谢来源。"
  def decision(pid, data), do: GenServer.cast(pid, {:decision, data})

  @doc "接纳 Body 实际收到的权威 Speech；只保存主观经历，不推进 World 游标或修改心智。"
  def speech(pid, message), do: GenServer.cast(pid, {:speech, message})

  @doc "接纳真实 Runtime 的动作终态，供下一次情绪评价引用（只在模型评价情绪时使用；规则模式不建这条流水）。"
  def experience(pid, outcome), do: GenServer.cast(pid, {:experience, outcome})

  @doc """
  一项新活动开始了（由统一形态的 Runtime 在选定新活动后调用一次）：从这一刻起每帧观察都记进这项活动的最近距离账，
  直到 `activity/2` 结束它。再次调用即重新开始一份空账。不改持久状态。
  """
  def activity_started(pid), do: GenServer.cast(pid, :activity_started)

  @doc """
  接纳一项已结束的活动作为主观经历：`%{text: 做了什么、结果如何（一句英文）, place: 活动的地名 | nil, activity: 候选名,
  kind: 种类, object: 对象 | nil, outcome: :completed | {:failed, 动作名, 原因文字} | {:interrupted, 原因文字}}`
  （`NpcServer.Selector.experience/1`）。与 World 事件、Speech 同样进未封存的尾部，攒够一个片段后写入 Hindsight。
  原文末尾加一句期间事实（见 moduledoc；没有开始信号或期间没有观察则不加）；tags 是 `kind:activity`、期间进过 6 米内的
  每个人 `actor:<cid>`、有地名时 `place:<地名>`。规划的形态在同一次保存里给日计划记账（结局为 `:completed` 的才记，见 moduledoc
  的“日计划”）；不规划的形态只读 `text` 与 `place`。Life 不另存这份结局：活动的结局归 Selector 的历史（任务层决策稿
  2026-11-19-npc-long-task-loop-decision.md K-9）。由 Runtime 的选择 worker 在活动结束时调用一次。
  保存后返回 `:ok`；写失败时返回诊断错误，Life 保留原经历并在轮询时重试，期间心智不能供下一次选择。
  待保存的经历只驻留于本 Life 进程；已经保存的经历与计划进度随持久行恢复。
  """
  def activity(pid, %{text: _, place: _} = experience),
    do: call_server(pid, {:activity, experience})

  @doc "提交本次模型情绪评价；持久化完成才返回成功，调用方随后才执行动作。"
  def appraise(cid, through, entries), do: call(cid, {:appraise, through, entries})

  defp name(cid), do: {:global, {__MODULE__, node(), cid}}

  defp call(cid, request), do: call_server(name(cid), request)

  defp call_server(server, request, timeout \\ 5_000) do
    try do
      GenServer.call(server, request, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :life_not_running}
      :exit, _ -> {:error, :life_unavailable}
    end
  end

  @impl true
  def init({owner, context, profile}) do
    Process.flag(:trap_exit, true)
    options = profile.life

    config =
      Map.merge(options, %{
        bank: "npc-life-#{context.cid}",
        url: Map.get(options, :url) || System.fetch_env!("NPC_LIFE_HINDSIGHT_URL")
      })

    send(self(), :poll)

    {:ok,
     %{
       owner: owner,
       context: context,
       memory: Map.get(profile, :memory, DataService.NpcMemory),
       adapter: Map.get(options, :hindsight, Hindsight),
       config: config,
       now: Map.get(options, :clock, fn -> System.system_time(:millisecond) end),
       poll_ms: Map.get(options, :poll_ms, 1000),
       row: nil,
       selection_waiter: nil,
       poll: nil,
       job: nil,
       error: nil,
       observation: nil,
       appraise: Map.get(options, :appraise, false),
       experience_pending: [],
       decision: nil,
       recall: nil,
       status: nil,
       job_error: nil,
       # 记忆任务槽连续失败次数与"这一刻之前不再起槽"的退避截止（毫秒，内存里）：失败按指数退避重试，
       # `job_error` 只用于 observe 与告警，不再是"永不重试"的开关。
       job_failures: 0,
       job_retry_at_ms: nil,
       # 因为超过片段上限而丢掉的（片段数, 经历条数），只累计在内存里（Life 重启即清零）：`observe/1` 读。
       dropped_fragments: 0,
       dropped_episodes: 0,
       dropped_inputs: %{},
       speech_pending: [],
       # 正在进行的活动的最近距离账：nil = 没有收到开始信号；`%{observed: 期间收到过观察, closest: Life.State.approach/2 的账}`。
       activity: nil,
       activity_pending: nil,
       # “看到的”进行中的账（`Life.Sight.new/0`）：还没结束的相遇、还没合上的建造 / 拆除、每人频率上限。只在内存，重启即丢。
       sight: Sight.new(),
       # 写日记所需（不变的配置）：nil = 这个形态不反思；否则是写日记的函数、人格卡一行与反思库（见 `journaling/3`）。
       # 与持久行的 "reflection"（反思的状态）不是一回事。
       journaling: journaling(profile, config, context.cid),
       # 反思槽（worker，同 poll / job）：nil 或 `%{pid, ref, round, now_ms, taken, landed}`（见 `start_round/2`）。
       reflect: nil,
       # 最近一轮里最近一次失败的原因（只在内存，observe 用）：起下一轮时清空。
       reflect_error: nil,
       # 规划槽（worker，同 reflect；每日回顾与任务推进共用，一次只一个在途）：nil，或回顾
       # `%{pid, ref, job: :review, kind, day, now_minute, now_ms}`（见 `start_plan/5`）、推进
       # `%{pid, ref, job: :advance, task: 任务 id, basis: 起推进时的基准, day, now_ms}`（见 `start_advance/4`）。
       plan: nil,
       # 最近一次规划调用失败的原因（只在内存，observe 用）：起下一次时清空，采用成功时为 nil。
       plan_error: nil,
       # 最近一次推进失败 / 被拒的原因（只在内存，observe 的 `tasks.error`）：起下一次推进时清空，采用时为 nil。
       task_error: nil,
       # 起槽之前那次保存失败后，这一刻之前不再试（内存里的防抖，不落库）。
       plan_not_before_ms: nil,
       # 当日额度用完那次已经记过一笔 skipped 的游戏日（每个游戏日只记一次；内存里，Life 重启即忘）。
       plan_exhausted_day: nil,
       # 花费额度的结论（`NpcServer.SpendBudget.background/0` 的形状），只在后台触发处读，见 moduledoc“花费额度”。
       spend: Map.get(options, :spend, fn -> :open end),
       # 各种后台工作最近一次因额度被拒的北京日 `%{refresh | reflect | plan | task => Date}`（内存里；每种每天只打一行日志）。
       spend_refused: %{}
     }}
  end

  # 写日记所需：profile 有写日记的接口（`reflect`）才有。写日记的函数可经 `profile.write_journal` 注入
  # （同 Selector 经 `profile.request` 注入 Jev 发送函数的做法），缺省是 `Writer.write(profile.reflect, …)`。
  # 反思库的 config 是经历库的换一个 bank。日计划共用写日记的接口与人格卡，可计划的种类取 `Offers.plan_kinds/1`
  # （按生成器次序：登记项各一个静态种类，配了说话再加说话一类，批 1 起再加进食 `eat` 与合成 `craft`——所以 profile 带
  # `activities` 键就会规划，候选表为空也有这两类；profile 没有 `activities` 键的形态为 []，不规划）。
  # 种类的对象在起规划槽时展开（`vocabulary/1`）。
  defp journaling(%{reflect: _} = profile, config, cid),
    do: %{
      write: journal_writer(profile, cid),
      character: Persona.describe(profile.who, profile.persona),
      archive: %{config | bank: "npc-reflect-#{cid}"},
      archive_name: "NPC #{cid} journal",
      kinds: Offers.plan_kinds(profile)
    }

  defp journaling(_profile, _config, _cid), do: nil

  defp journal_writer(%{write_journal: write}, _cid),
    do: fn _operation, _limits, system, user -> write.(system, user) end

  # 反思与日计划没人在等：写作走出站的后台车道（`NpcServer.Http`），与说话的交互写作分开。
  # `limits` 是这一种写作按次的请求参数（只有每日回顾与任务推进带 `max_tokens`，任务层决策稿 K-9），并进 endpoint 交给 `Writer`。
  defp journal_writer(%{reflect: endpoint}, cid) do
    endpoint = Map.put(endpoint, :lane, :background)

    fn operation, limits, system, user ->
      Writer.write(Map.merge(endpoint, limits), system, user, %{cid: cid, operation: operation})
    end
  end

  defp write_for(%{write: write}, operation, limits \\ %{}),
    do: fn system, user -> write.(operation, limits, system, user) end

  @impl true
  def handle_call(:observe, _, s) do
    row = s.row
    cache = row && row["cache"]

    {:reply,
     {:ok,
      %{
        cid: s.context.cid,
        bank: s.config.bank,
        state: row && row["state"],
        last_interaction_gap: row && row["last_interaction_gap"],
        mind: row && State.view(row["state"], s.now.()),
        pending_episodes: if(row, do: length(row["pending"]), else: 0),
        pending_fragments: if(row, do: length(row["fragments"]), else: 0),
        retained: if(row, do: row["retained"], else: 0),
        cache: cache,
        thanked_seq: row && row["thanked_seq"],
        cache_age_ms: if(cache && cache["at_ms"], do: max(0, s.now.() - cache["at_ms"])),
        cache_dirty: row && row["dirty"],
        refresh_at_ms: row && row["refresh_at_ms"],
        job: s.job && s.job.kind,
        error: s.error || s.job_error,
        # 记忆任务槽的退避：连续失败次数与距下次自动重试的毫秒数（nil = 没在等）。
        job_failures: s.job_failures,
        job_retry_in_ms: if(s.job_retry_at_ms, do: max(0, s.job_retry_at_ms - s.now.())),
        # 因为超过片段上限而丢掉的经历（内存计数，Life 重启即清零）：见 `record_fragment_trim/2`。
        dropped_fragments: s.dropped_fragments,
        dropped_episodes: s.dropped_episodes,
        dropped_inputs: s.dropped_inputs,
        hindsight: s.status,
        recall: s.recall,
        decision: s.decision,
        activity_pending: s.activity_pending != nil,
        unsaved_speech: length(s.speech_pending),
        unsaved_experiences: length(s.experience_pending),
        sight_capped: s.sight.capped,
        emotion_owner: if(s.appraise, do: :model, else: :construction_rules),
        reflection: observe_reflection(s),
        plan: observe_plan(s),
        tasks: observe_tasks(s),
        spend_refused: s.spend_refused
      }}, s}
  end

  def handle_call(:context, _, s), do: {:reply, context_response(s), s}

  def handle_call(:selection_context, from, s) do
    case selection_response(s) do
      :loading when s.selection_waiter == nil ->
        token = make_ref()

        timer =
          Process.send_after(self(), {:selection_context_timeout, token}, @initial_mind_wait_ms)

        {:noreply, %{s | selection_waiter: %{from: from, token: token, timer: timer}}}

      :loading ->
        {:reply, {:error, :life_initializing}, s}

      answer ->
        {:reply, answer, s}
    end
  end

  def handle_call(:reflect, _, %{row: nil} = s), do: {:reply, {:error, :life_not_ready}, s}

  def handle_call(:reflect, _, %{journaling: nil} = s),
    do: {:reply, {:error, :reflection_disabled}, s}

  def handle_call(:reflect, _, %{reflect: slot} = s) when slot != nil,
    do: {:reply, {:ok, %{status: :busy}}, s}

  def handle_call(:reflect, _, %{observation: nil} = s),
    do: {:reply, {:error, :no_observation}, s}

  def handle_call(:reflect, _, s) do
    if s.row["reflection"]["new"] == [] do
      {:reply, {:ok, %{status: :empty}}, s}
    else
      case background(s, :reflect) do
        {:open, s} ->
          round = Reflection.manual(s.row["reflection"]["trigger"], s.now.())

          case save(s, mark_round_started(s.row, round)) do
            {:ok, s} -> {:reply, {:ok, %{status: :started}}, start_round(s, round)}
            {:error, s} -> {:reply, {:error, s.error}, s}
          end

        {refusal, s} ->
          {:reply, {:error, refusal}, s}
      end
    end
  end

  def handle_call(kind, _, %{row: nil} = s) when kind in [:flush, :refresh],
    do: {:reply, {:error, :life_not_ready}, s}

  def handle_call(kind, _, %{job: job} = s) when kind in [:flush, :refresh] and job != nil,
    do: {:reply, {:ok, %{status: :busy, job: job.kind}}, s}

  def handle_call(:flush, _, s) do
    case save(s, seal(s.row, true)) do
      {:ok, s} ->
        if s.row["fragments"] == [],
          do: {:reply, {:ok, %{status: :empty}}, s},
          else: {:reply, {:ok, %{status: :started}}, start_job(s, :retain)}

      {:error, s} ->
        {:reply, {:error, s.error}, s}
    end
  end

  def handle_call(:refresh, _, s) do
    case background(s, :refresh) do
      {:open, s} -> {:reply, {:ok, %{status: :started}}, start_job(s, :refresh)}
      {refusal, s} -> {:reply, {:error, refusal}, s}
    end
  end

  def handle_call({:appraise, _, _}, _, %{row: nil} = s),
    do: {:reply, {:error, :life_not_ready}, s}

  def handle_call({:appraise, through, entries}, _, s) do
    case Appraisal.apply(s.row["state"], through, entries, s.now.()) do
      {:ok, canonical} ->
        case save(s, %{s.row | "state" => canonical}) do
          {:ok, s} ->
            publish(s)

            Logger.info(
              "npc_emotion_appraised cid=#{s.context.cid} through=#{through} count=#{length(entries)}"
            )

            {:reply, :ok, s}

          {:error, s} ->
            {:reply, {:error, s.error}, s}
        end

      {:error, reason} ->
        Logger.warning("npc_emotion_rejected cid=#{s.context.cid} reason=#{reason}")
        {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:activity, _}, _, %{row: nil} = s),
    do: {:reply, {:error, :life_not_ready}, s}

  def handle_call({:activity, _}, _, %{activity_pending: pending} = s) when pending != nil,
    do: {:reply, {:error, :activity_pending}, s}

  def handle_call({:activity, experience}, _, s) do
    pending = prepare_activity(s, experience)

    case save_activity(%{s | activity: nil, activity_pending: pending}) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, s} -> {:reply, {:error, s.error}, s}
    end
  end

  @impl true
  def handle_cast({:observation, o}, s) do
    context = %{s.context | scene_id: Map.get(o.self, :scene_id, s.context.scene_id)}
    at_ms = Map.get(o, :observed_at_ms) || s.now.()
    {sight, seen, capped} = Sight.see(s.sight, o, at_ms)
    s = %{s | observation: o, context: context, activity: approach(s.activity, o), sight: sight}
    s = record_sight(s, seen, capped)

    s =
      if s.appraise and s.row != nil and s.row["state"]["affect"]["next_seq"] == 0 and
           not Enum.any?(s.experience_pending, fn {kind, _, _, _} -> kind == "situation" end) do
        enqueue_experience(s, "situation", %{self: o.self, entities: o.entities})
      else
        s
      end

    {:noreply, s |> tick_tasks() |> maybe_plan()}
  end

  def handle_cast(:observation_lost, s),
    do: {:noreply, %{s | sight: Sight.invalidate(s.sight)}}

  def handle_cast({:experience, outcome}, s) do
    position = s.observation && s.observation.self.position
    [projected] = NpcServer.Perception.project(outcome, [], position)
    {:noreply, enqueue_experience(s, "outcome", projected)}
  end

  def handle_cast({:decision, data}, s) do
    s = %{s | decision: data}

    if s.row != nil and Map.get(data, :thanks, 0) > s.row["thanked_seq"] do
      case save(s, Map.put(s.row, "thanked_seq", data.thanks)) do
        {:ok, s} ->
          publish(s)
          {:noreply, s}

        {:error, s} ->
          {:noreply, s}
      end
    else
      {:noreply, s}
    end
  end

  def handle_cast({:recall, data}, s), do: {:noreply, %{s | recall: data}}

  def handle_cast(:activity_started, s),
    do: {:noreply, %{s | activity: %{observed: false, closest: %{}}}}

  def handle_cast({:speech, message}, s) do
    {:noreply, s |> buffer_input(:speech_pending, message) |> save_speech()}
  end

  # 只在活动结束时冻结期间事实与记账时刻。重试只接纳同一条经历。
  defp prepare_activity(s, %{text: text, place: place} = experience) do
    at_ms = s.now.()

    # 期间事实：有开始信号且期间收到过观察才有真值；没有就不写这句、也没有 actor 标签。
    {text, people} =
      case s.activity do
        %{observed: true, closest: closest} ->
          {sentence, people} = State.during(closest, s.observation)
          {text <> " " <> sentence, people}

        _ ->
          {text, []}
      end

    episode = %{
      "id" => "activity:#{at_ms}",
      "at_ms" => at_ms,
      "text" => text,
      "tags" =>
        ["kind:activity"] ++
          Enum.map(people, &"actor:#{&1}") ++ if(place, do: ["place:#{place}"], else: [])
    }

    %{
      episode: episode,
      progress: activity_progress(s, experience),
      step: step_progress(s, experience, at_ms)
    }
  end

  defp save_activity(%{activity_pending: nil} = s), do: {:ok, s}

  defp save_activity(%{activity_pending: %{episode: episode, progress: progress, step: step}} = s) do
    {row, next} = accept(s, s.row, [episode])
    row = row |> record_plan_activity(progress) |> record_task_step(step)
    before = s.row["tasks"]

    case save(s, seal(row, false)) do
      {:ok, s} ->
        log_task_step(s, before, step)
        {:ok, %{s | activity_pending: nil} |> automatic() |> follow_round(next) |> land_plan()}

      {:error, s} ->
        {:error, s}
    end
  end

  @impl true
  def handle_info(:poll, %{poll: nil} = s) do
    {_, s} = save_activity(s)
    memory = s.memory
    context = s.context
    row = s.row

    {:noreply,
     worker(s, :poll, fn ->
       with {:ok, loaded} <- if(row, do: {:ok, row}, else: Memory.life_load(memory, context.cid)),
            {:ok, route} <- context.router.route(context.scene_id),
            {:ok, events} <- world_interactions(route.world_ref, loaded) do
         {:ok,
          %{row: loaded, events: Map.update!(events, :events, &buildings(route.world_ref, &1))}}
       end
     end)}
  end

  def handle_info(:poll, s), do: {:noreply, s}

  def handle_info({:result, :poll, result}, s) do
    s = done(s, :poll)

    s =
      case result do
        {:ok, %{row: loaded, events: events}} ->
          accept_world(s, loaded, events)

        {:error, :interaction_world_identity_mismatch} ->
          error(s, :life_world_identity_mismatch)

        {:error, reason} ->
          error(s, reason)
      end

    Process.send_after(self(), :poll, s.poll_ms)
    {:noreply, finish_selection_wait(s)}
  end

  def handle_info({:selection_context_timeout, token}, %{selection_waiter: %{token: token}} = s),
    do: {:noreply, reply_selection(s, {:error, :life_initialization_timeout})}

  def handle_info({:selection_context_timeout, _}, s), do: {:noreply, s}

  def handle_info({:result, :job, result}, s) do
    job = s.job
    s = done(s, :job)

    s =
      case result do
        {:ok, result} ->
          row =
            case job.kind do
              :retain ->
                %{
                  s.row
                  | "fragments" => Enum.reject(s.row["fragments"], &(&1["id"] in job.ids)),
                    "retained" => s.row["retained"] + length(job.ids),
                    "dirty" => true
                }

              _ ->
                %{
                  s.row
                  | "cache" => json(Map.put(result.models, :at_ms, s.now.())),
                    "dirty" => if(job.kind == :refresh, do: false, else: s.row["dirty"]),
                    "refresh_at_ms" =>
                      if(job.kind == :refresh, do: s.now.(), else: s.row["refresh_at_ms"])
                }
            end

          # 这一次任务成功了：连续失败清零（与"落库成功"无关——失败的是保存，不是这一次 retain / 刷新）。
          s = %{s | status: result.status, job_error: nil, job_failures: 0, job_retry_at_ms: nil}

          case save(s, row) do
            {:ok, s} -> automatic(s)
            {:error, s} -> s
          end

        {:error, reason} ->
          job_error(s, reason)
      end

    {:noreply, finish_selection_wait(s)}
  end

  # 反思槽交回的写作结果（槽还在途：接着存档）。落栏是一次保存：写成的各问进 "latest"、"round" 小结、各计数；
  # 这一轮做完（error 为 nil）才删掉 "new" 里起槽时取走的那几条，中止则 "new" 不动。槽上记下落栏了没有，存档结果据此处理。
  def handle_info({:reflected, outcome}, %{reflect: slot} = s) do
    complete = outcome.error == nil

    row =
      update_in(s.row, ["reflection"], fn reflection ->
        %{
          reflection
          | "new" =>
              if(complete, do: Enum.drop(reflection["new"], slot.taken), else: reflection["new"]),
            "latest" =>
              Enum.reduce(outcome.written, reflection["latest"], &Map.put(&2, &1.key, &1.entry)),
            "round" => round_summary(slot, outcome),
            "counts" =>
              count(reflection["counts"], %{
                "written" => length(outcome.written),
                "reasked" => outcome.reasked,
                "discarded" => length(outcome.discarded),
                "failed" => length(outcome.failed),
                "aborted" => if(complete, do: 0, else: 1)
              })
        }
      end)

    case save(s, row) do
      {:ok, s} ->
        {:noreply, %{s | reflect: %{slot | landed: true}, reflect_error: outcome.error}}

      # 没落栏：这一轮写成的日记不在持久行里（不重试，同其它经历保存失败）；"new" 与触发状态也就都没动。
      {:error, s} ->
        Logger.warning(
          "npc_reflect cid=#{s.context.cid} event=persist_failed at_ms=#{slot.now_ms} " <>
            "written=#{length(outcome.written)} reason=#{inspect(s.error)}"
        )

        {:noreply, %{s | reflect: %{slot | landed: false}, reflect_error: s.error}}
    end
  end

  # 反思槽结束（存档的结果）：清槽。落栏了才把存档结局写进本轮的小结（失败另记 archive_failed）；没落栏只打日志、不碰行。
  # 存档失败不重试，已落栏的日记不动。
  def handle_info({:result, :reflect, archived}, %{reflect: slot} = s) do
    s = done(s, :reflect)

    {archive, s} =
      case archived do
        :none -> {nil, s}
        {:ok, _} -> {"ok", s}
        {:error, reason} -> {"failed", %{s | reflect_error: reason}}
      end

    cond do
      archive == nil ->
        {:noreply, s}

      slot.landed ->
        {:noreply, archive_outcome(s, archive)}

      true ->
        Logger.warning(
          "npc_reflect cid=#{s.context.cid} event=archive_unrecorded at_ms=#{slot.now_ms} " <>
            "archive=#{archive} reason=not_persisted"
        )

        {:noreply, s}
    end
  end

  # 反思槽崩溃：落栏之前崩 → 这一轮中止（"round" 记这一轮、问到的键不知道就留空表，"new" 不动）；落栏之后（存档阶段）崩
  # → 存档失败；落栏没存成 → 不碰行。日志带原始退出原因（截断）。
  def handle_info({:DOWN, ref, :process, _, reason}, %{reflect: %{ref: ref} = slot} = s) do
    detail = reason |> inspect(limit: 10, printable_limit: 200) |> String.slice(0, 400)

    stage =
      case slot.landed do
        nil -> "writing"
        true -> "archiving"
        false -> "archiving_unpersisted"
      end

    Logger.warning(
      "npc_reflect cid=#{s.context.cid} event=crashed at_ms=#{slot.now_ms} stage=#{stage} reason=#{detail}"
    )

    s = %{done(s, :reflect) | reflect_error: {:reflect_worker_crashed, detail}}

    s =
      case slot.landed do
        nil ->
          save_reflection(s, fn reflection ->
            %{
              reflection
              | "round" =>
                  round_summary(slot, %{asked: [], written: [], discarded: [], failed: []}),
                "counts" => count(reflection["counts"], %{"aborted" => 1})
            }
          end)

        # 只有本轮有东西要存（"pending"）时，存档阶段的崩溃才算存档失败。
        true ->
          if s.row["reflection"]["round"]["archive"] == "pending",
            do: archive_outcome(s, "failed"),
            else: s

        false ->
          s
      end

    {:noreply, s}
  end

  # 已收到的规划结果留在原槽。若前一条活动还未写盘，先完成那条输入的经历与记账，再决定哪些旧意图应该保留。
  def handle_info({:result, :plan, outcome}, %{plan: slot} = s) do
    s = done(s, :plan)
    {:noreply, land_plan(%{s | plan: Map.put(slot, :outcome, outcome)})}
  end

  # 规划槽崩溃（写作函数退出、取材时抛错等）：清槽，当一次失败记（回顾 `DayPlan.fail/5`、推进 `Tasks.fail/1`，原因带截断的
  # 退出原因）；Life 不受影响。当日额度不退：不知道写作发出了没有，按发出算（否则反复崩溃就能绕过额度）。
  def handle_info({:DOWN, ref, :process, _, reason}, %{plan: %{ref: ref} = slot} = s) do
    detail = reason |> inspect(limit: 10, printable_limit: 200) |> String.slice(0, 400)
    failure = {:plan_worker_crashed, detail}
    s = done(s, :plan)

    {s, row} =
      case slot.job do
        :review ->
          Logger.warning(
            "npc_plan cid=#{s.context.cid} event=crashed kind=#{slot.kind} day=#{slot.day} reason=#{detail}"
          )

          plan = DayPlan.fail(s.row["plan"], slot.kind, :failed, failure, slot.now_ms)
          {%{s | plan_error: failure}, %{s.row | "plan" => plan}}

        :advance ->
          Logger.warning(
            "npc_task cid=#{s.context.cid} event=crashed task=#{slot.task} day=#{slot.day} reason=#{detail}"
          )

          {%{s | task_error: {:failed, failure}},
           %{s.row | "tasks" => Tasks.fail(s.row["tasks"])}}
      end

    case save(s, row) do
      {:ok, s} -> {:noreply, s}
      {:error, s} -> {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) do
    slot =
      cond do
        s.poll && s.poll.ref == ref -> :poll
        s.job && s.job.ref == ref -> :job
        true -> nil
      end

    if slot do
      s = done(s, slot)

      s =
        if slot == :poll,
          do: error(s, {:life_worker_failed, exit_kind(reason)}),
          else: job_error(s, {:life_worker_failed, exit_kind(reason)})

      if slot == :poll, do: Process.send_after(self(), :poll, s.poll_ms)
      {:noreply, finish_selection_wait(s)}
    else
      {:noreply, s}
    end
  end

  def handle_info({:EXIT, owner, _}, %{owner: owner} = s) do
    for w <- [s.poll, s.job, s.reflect, s.plan], w != nil, do: Process.exit(w.pid, :shutdown)
    {:stop, :shutdown, s}
  end

  def handle_info({:EXIT, _, _}, s), do: {:noreply, s}

  defp context_response(%{row: nil}), do: {:error, :life_not_ready}

  defp context_response(%{activity_pending: pending}) when pending != nil,
    do: {:error, :activity_pending}

  defp context_response(s) do
    if s.row["cache"] do
      now_ms = s.now.()

      {:ok,
       %{
         adapter: s.adapter,
         config: s.config,
         now_ms: now_ms,
         mind: State.view(s.row["state"], now_ms),
         cache: s.row["cache"],
         # 现查 World 用，查询由调用者进程执行。
         context: s.context,
         recent: recent(s.row),
         thought: thought(s),
         plan: plan_column(s),
         tasks: task_column(s)
       }}
    else
      {:error, {:life_models_unavailable, s.job_error || s.error}}
    end
  end

  defp selection_response(s) do
    case context_response(s) do
      {:error, :life_not_ready} when s.error == nil -> :loading
      {:error, :life_not_ready} -> {:error, {:life_not_ready, s.error}}
      {:error, {:life_models_unavailable, nil}} -> :loading
      answer -> answer
    end
  end

  defp finish_selection_wait(%{selection_waiter: %{}} = s) do
    case selection_response(s) do
      :loading -> s
      answer -> reply_selection(s, answer)
    end
  end

  defp finish_selection_wait(s), do: s

  defp reply_selection(%{selection_waiter: waiter} = s, answer) do
    Process.cancel_timer(waiter.timer)
    GenServer.reply(waiter.from, answer)
    %{s | selection_waiter: nil}
  end

  defp world_interactions(world, nil), do: VoxelRegion.World.interactions_since(world, nil)

  defp world_interactions(world, row) do
    state = row["state"]
    VoxelRegion.World.interactions_since(world, state["cursor"], state["world_id"])
  end

  # 事件里 `prefab` 是所属建筑的定义 id（散格与 2026-11-12 之前提交的事件没有）；名字的 owner 是 World 的发布元信息，
  # 这里读一次写进事件的 `building`。空名发布与作者目录里没发布过的定义没有名字。本批没有涉及建筑的事件就不读。
  defp buildings(world, events) do
    if Enum.any?(events, & &1[:prefab]) do
      names =
        for %{id: id, name: name} <- VoxelRegion.World.published_prefab_metadata(world),
            name != "",
            into: %{},
            do: {id, name}

      Enum.map(events, &Map.put(&1, :building, names[&1[:prefab]]))
    else
      events
    end
  end

  defp initial(cid, events, now),
    do: %{
      "state" => State.new(cid, events.world_id, events.cursor, now),
      "pending" => [],
      "fragments" => [],
      "cache" => nil,
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => nil,
      "thanked_seq" => 0,
      "reflection" => empty_reflection(),
      "plan" => DayPlan.new(),
      "tasks" => Tasks.new()
    }

  # 持久行的 "reflection"（形状见 moduledoc 的反思一节）：空的一份。字符串键，能原样过 JSON。
  defp empty_reflection,
    do: %{
      "trigger" => Reflection.new_trigger(),
      "new" => [],
      "latest" => %{},
      "round" => nil,
      "counts" =>
        Map.new(
          ~w(rounds written reasked discarded failed aborted skipped archive_failed),
          &{&1, 0}
        )
    }

  # 只有 owner 推进当前 canonical；在途 World 读取不能覆盖模型刚提交的情绪，持久行的身份与游标已由 World 验证。
  # 加载边界：反思之前存下的行没有 "reflection"、日计划之前存下的行没有 "plan"、任务层之前存下的行没有 "tasks"，
  # 只在这里补成空的一份，别处一律直接读。
  defp accept_world(s, loaded, events) do
    row =
      s.row ||
        (loaded &&
           loaded
           |> Map.put_new("reflection", empty_reflection())
           |> Map.put_new("plan", DayPlan.new())
           |> Map.put_new("tasks", Tasks.new())) ||
        initial(s.context.cid, events, s.now.())

    canonical = State.upgrade(row["state"])

    canonical =
      cond do
        s.appraise -> Appraisal.enable(canonical)
        Map.has_key?(canonical, "affect") -> {:error, :emotion_owner_mismatch}
        true -> canonical
      end

    case canonical do
      {:error, reason} -> error(s, reason)
      canonical -> advance_world(s, row, canonical, events)
    end
  end

  defp advance_world(s, row, canonical, events) do
    gap = Map.get(events, :gap)
    now_ms = s.now.()
    canonical = if gap, do: State.after_interaction_gap(canonical), else: canonical

    {canonical, episodes} =
      State.advance(
        canonical,
        events.events,
        events.cursor,
        now_ms,
        if(s.appraise, do: :model, else: :rules),
        names(s)
      )

    # 所见只取没有被写成“动我的建筑”经历的事件（同一件事不写两条）；分组账与到点检查在 `Life.Sight`。
    # 账无论保存成败都换成新的：写失败时这几条丢掉，重来的同一批事件按 seq 不再算一次。
    {sight, seen, capped} =
      if gap,
        do: Sight.due(s.sight, s.observation, now_ms),
        else:
          Sight.witness(s.sight, Sight.unwritten(events.events, episodes), s.observation, now_ms)

    log_capped(s, capped)
    s = %{s | sight: sight}

    canonical =
      if s.appraise do
        Enum.reduce(episodes, canonical, fn episode, state ->
          Appraisal.enqueue(
            state,
            "world",
            episode,
            [episode["actor"] | targets(s)],
            episode["at_ms"]
          )
        end)
      else
        canonical
      end

    row = %{row | "state" => canonical}

    row =
      if gap do
        Map.put(row, "last_interaction_gap", %{
          "from_cursor" => gap.from_cursor,
          "oldest_seq" => gap.oldest_seq,
          "resumed_cursor" => events.cursor
        })
      else
        row
      end

    {candidate, next} = accept(s, row, episodes ++ seen)

    case save(s, seal(candidate, false)) do
      {:ok, s} ->
        if gap do
          Logger.warning(
            "npc_life_interaction_gap cid=#{s.context.cid} world_id=#{events.world_id} " <>
              "from_cursor=#{gap.from_cursor} oldest_seq=#{gap.oldest_seq} resumed_cursor=#{events.cursor}"
          )
        end

        s = s |> follow_round(next) |> save_experiences() |> save_speech()
        publish(s)
        automatic(s)

      {:error, s} ->
        s
    end
  end

  # 观察处写出的所见条目进未封存的尾部（与活动经历同一条路）。观察每秒 20 帧，没有条目时不保存。
  # 写失败时这几条丢掉、错误经 `error` 可见（进行中的账已经合上，不逐帧重试写库）。首次加载之前没有行可写，丢掉并记一行。
  defp record_sight(s, entries, capped) do
    log_capped(s, capped)

    cond do
      entries == [] ->
        s

      s.row == nil ->
        Logger.warning(
          "npc_sight_dropped cid=#{s.context.cid} count=#{length(entries)} reason=life_not_ready"
        )

        s

      true ->
        {row, next} = accept(s, s.row, entries)

        case save(s, seal(row, false)) do
          {:ok, s} -> s |> automatic() |> follow_round(next)
          {:error, s} -> s
        end
    end
  end

  # 频率上限挡下的所见不写，但不静默：每条一行。
  defp log_capped(s, capped) do
    for %{actor: actor, kind: kind} <- capped do
      Logger.info("npc_sight_capped cid=#{s.context.cid} actor=#{actor} kind=#{kind}")
    end

    :ok
  end

  # 写经历时人名的来源：本 owner 此刻持有的观察里的 `%{cid => 名字}`（还没收到观察时为空，人一律写 `actor <cid>`）。
  defp names(%{observation: nil}), do: %{}
  defp names(%{observation: o}), do: State.names(o)

  # 活动进行中每帧观察更新最近距离账；没有开始信号（nil）时不记。
  defp approach(nil, _observation), do: nil

  defp approach(%{closest: closest}, observation),
    do: %{observed: true, closest: State.approach(closest, observation)}

  defp targets(%{observation: nil, context: context}), do: [context.cid]

  defp targets(s),
    do: Enum.uniq([s.context.cid | Enum.map(s.observation.entities, & &1.entity_id)])

  defp enqueue_experience(%{appraise: false} = s, _, _), do: s

  defp enqueue_experience(s, kind, data) do
    source = {kind, json(NpcServer.Context.plain(data)), targets(s), s.now.()}
    s |> buffer_input(:experience_pending, source) |> save_experiences()
  end

  # 未落盘输入保留最近的短期心智跨度。有存储错误时仍维持这个上限，丢弃有累计计数。
  defp buffer_input(s, key, input) do
    pending = Map.fetch!(s, key) ++ [input]

    if length(pending) > @max_recent do
      dropped = Map.update(s.dropped_inputs, key, 1, &(&1 + 1))

      Logger.warning(
        "npc_life_input_trimmed cid=#{s.context.cid} queue=#{key} total_dropped=#{dropped[key]}"
      )

      Map.put(%{s | dropped_inputs: dropped}, key, tl(pending))
    else
      Map.put(s, key, pending)
    end
  end

  defp save_experiences(%{row: nil} = s), do: s
  defp save_experiences(%{experience_pending: []} = s), do: s

  defp save_experiences(s) do
    canonical =
      Enum.reduce(s.experience_pending, s.row["state"], fn {kind, data, ids, at}, state ->
        Appraisal.enqueue(state, kind, data, ids, at)
      end)

    case save(s, %{s.row | "state" => canonical}) do
      {:ok, s} ->
        publish(s)
        %{s | experience_pending: []}

      {:error, s} ->
        s
    end
  end

  # 首次 World 身份尚未加载或写入失败时保留未落盘输入；既有轮询继续尝试，观察显式报告 unsaved_speech/error。
  defp save_speech(%{row: nil} = s), do: s
  defp save_speech(%{speech_pending: []} = s), do: s

  defp save_speech(s) do
    # Scene 已保证一次权威投递；存储失败不提交 row，不清空输入，原 outbox 重试无需第二套去重状态。
    episodes = Enum.map(s.speech_pending, &Dialogue.episode(&1, s.context.cid, names(s)))
    {row, next} = accept(s, s.row, episodes)

    canonical =
      if s.appraise do
        Enum.reduce(s.speech_pending, row["state"], fn message, state ->
          Appraisal.enqueue(
            state,
            "speech",
            json(message),
            Enum.uniq([message.speaker_id | targets(s)]),
            message.at_ms
          )
        end)
      else
        row["state"]
      end

    row = %{row | "state" => canonical}

    case save(s, seal(row, false)) do
      {:ok, s} ->
        publish(s)
        automatic(%{s | speech_pending: []}) |> follow_round(next)

      {:error, s} ->
        s
    end
  end

  # 接纳经历（四个入口共用）：追加到未封存的尾部；开着反思时逐条计分（`Reflection.record/2`）、把 `%{"at_ms", "tags"}`
  # 记进 "new"，并定下到点的一轮怎么办（一批里多条都到点只算一轮：直接取最后一条给出的那一轮——时刻、累计分与原因；
  # 一批之内触发状态不清零，后一条的原因必然包含前一条的）：
  #   起得了（槽空着、有观察）→ 同一份行里 `mark_round_started/2`（started/2、rounds 加一），下一步 `{:start, 一轮}`；
  #   起不了 → skipped 加一、触发状态不动（下一条经历进来还会到点），下一步
  #   `{:skip, 一轮, :busy | :no_observation | {:budget_exhausted, 北京日}}`。
  # 规划的形态在这一批里有 `kind:event` 的经历时，同一份行里给日计划记下“有 event 在等着重排”（`DayPlan.note_event/1`；
  # 下一帧观察到点就起）；不规划的形态不动 `"plan"`。同一份行里给任务记新信息（K-3，`task_news/3`）。
  # 返回 `{新的行, nil | 下一步}`。只改行，不保存：调用方保存成功之后才 `follow_round/2`（保存失败行没变，什么也不做）。
  defp accept(%{journaling: nil}, row, entries),
    do: {Map.update!(row, "pending", &(&1 ++ entries)), nil}

  defp accept(s, row, entries) do
    {reflection, due} =
      Enum.reduce(entries, {row["reflection"], nil}, fn entry, {reflection, due} ->
        {trigger, round} = Reflection.record(reflection["trigger"], entry)

        reflection = %{
          reflection
          | "trigger" => trigger,
            "new" => reflection["new"] ++ [Map.take(entry, ["at_ms", "tags"])]
        }

        # 后到点的那一轮的原因必然包含先到点的（触发条件不清零），直接取它。
        {reflection, round || due}
      end)

    plan =
      if Enum.any?(entries, &("kind:event" in &1["tags"])) and planning?(s),
        do: DayPlan.note_event(row["plan"]),
        else: row["plan"]

    tasks =
      if planning?(s),
        do: Enum.reduce(entries, row["tasks"], &task_news(s, &1, &2)),
        else: row["tasks"]

    row = %{
      row
      | "pending" => row["pending"] ++ entries,
        "reflection" => reflection,
        "plan" => plan,
        "tasks" => tasks
    }

    cond do
      due == nil -> {row, nil}
      reason = cannot_start(s) -> {count_skipped(row), {:skip, due, reason}}
      true -> {mark_round_started(row, due), {:start, due}}
    end
  end

  # 到点却起不了一轮的原因；起得了为 nil。花费额度停了后台是 `{:budget_exhausted, 北京日}`（拒绝的日志在 `follow_round/2`）。
  defp cannot_start(%{reflect: slot}) when slot != nil, do: :busy
  defp cannot_start(%{observation: nil}), do: :no_observation
  defp cannot_start(s), do: refusal(s)

  # 在行里记下起了一轮（只改行，不起 worker；保存成功后由 `start_round/2` 起槽）：触发状态 started/2（清零、记下这一轮的
  # 触发时刻）、rounds 加一。"new" 不动（落栏时才消耗）。
  defp mark_round_started(row, round),
    do:
      update_in(row, ["reflection"], fn reflection ->
        %{
          reflection
          | "trigger" => Reflection.started(reflection["trigger"], round.at_ms),
            "counts" => count(reflection["counts"], %{"rounds" => 1})
        }
      end)

  defp count_skipped(row),
    do: update_in(row, ["reflection", "counts"], &count(&1, %{"skipped" => 1}))

  # 接纳经历的那次保存成功之后：照 `accept/3` 定下的下一步起槽，或打跳过的日志（计数已在那次保存里）。
  defp follow_round(s, nil), do: s
  defp follow_round(s, {:start, round}), do: start_round(s, round)

  defp follow_round(s, {:skip, round, {:budget_exhausted, day}}) do
    log_skipped(s, round, :budget_exhausted)
    refused(s, :reflect, day)
  end

  defp follow_round(s, {:skip, round, reason}) do
    log_skipped(s, round, reason)
    s
  end

  defp log_skipped(s, round, reason),
    do:
      Logger.info(
        "npc_reflect cid=#{s.context.cid} event=skipped trigger_at_ms=#{round.at_ms} " <>
          "causes=#{Enum.join(round.causes, ",")} reason=#{reason}"
      )

  # 起反思槽的 worker（`mark_round_started/2` 那次保存已经成功）：快照在本进程里取齐，worker 不回头问 Life。当时的 "new" 整份交给这一轮，
  # 槽上记下取走了几条（taken，做完时从 "new" 头上删掉这几条）、这一轮的此刻（now_ms）与落栏了没有（landed：
  # nil 还没交回写作结果、true 已落栏、false 落栏那次保存失败）。起轮时清掉上一轮的失败原因。
  defp start_round(s, round) do
    new = s.row["reflection"]["new"]
    now_ms = s.now.()

    snapshot =
      Map.merge(s.journaling, %{
        cid: s.context.cid,
        write: write_for(s.journaling, :reflection),
        round: round,
        new: new,
        now_ms: now_ms,
        observation: s.observation,
        recent: recent(s.row),
        buildings: s.row["state"]["buildings"],
        people: Enum.map(State.relationships(s.row["state"]), & &1.actor),
        names: names(s),
        latest: s.row["reflection"]["latest"],
        adapter: s.adapter,
        # 每路召回的上限同心智快照（召回是一问一问串行发的）。
        config: Map.put(s.config, :timeout_ms, @mind_recall_timeout_ms),
        context: s.context
      })

    owner = self()

    s =
      worker(s, :reflect, fn ->
        {:ok, _} = Application.ensure_all_started(:ssl)
        outcome = Round.write(snapshot)

        # 先交回写作结果落栏，再存档（落栏不等存档）；存档的结果随槽结束交回。
        send(owner, {:reflected, outcome})
        Round.archive(snapshot, outcome)
      end)

    %{
      s
      | reflect:
          Map.merge(s.reflect, %{round: round, now_ms: now_ms, taken: length(new), landed: nil}),
        reflect_error: nil
    }
  end

  # 一轮的小结（进 "round"）：时刻是这一轮的此刻；`outcome` 是 `Round.write/1` 的结果（worker 落栏前崩溃时各键为空表）。
  # 写成了才有可存的（存档结果回来之前是 "pending"）。
  defp round_summary(slot, outcome) do
    written = Enum.map(outcome.written, & &1.key)

    %{
      "at_ms" => slot.now_ms,
      "causes" => Enum.map(slot.round.causes, &Atom.to_string/1),
      "asked" => outcome.asked,
      "written" => written,
      "discarded" => outcome.discarded,
      "failed" => outcome.failed,
      "archive" => if(written == [], do: "none", else: "pending")
    }
  end

  # 把存档结局写进本轮已落栏的小结（调用方保证本轮已落栏，"round" 就是本轮的）；失败另记 archive_failed。
  defp archive_outcome(s, archive) do
    save_reflection(s, fn reflection ->
      %{
        reflection
        | "round" => %{reflection["round"] | "archive" => archive},
          "counts" =>
            count(reflection["counts"], %{
              "archive_failed" => if(archive == "failed", do: 1, else: 0)
            })
      }
    end)
  end

  # 改持久行的 "reflection" 并保存；保存失败时错误经 `save/2` 可见（npc_life_error），行不变。
  defp save_reflection(s, fun) do
    case save(s, Map.update!(s.row, "reflection", fun)) do
      {:ok, s} -> s
      {:error, s} -> s
    end
  end

  defp count(counts, increments), do: Map.merge(counts, increments, fn _, a, b -> a + b end)

  defp observe_reflection(%{journaling: nil}), do: nil

  defp observe_reflection(s) do
    reflection = s.row && s.row["reflection"]

    %{
      enabled: true,
      running: s.reflect != nil,
      trigger: reflection && reflection["trigger"],
      new: if(reflection, do: length(reflection["new"]), else: 0),
      latest: reflection && reflection["latest"],
      round: reflection && reflection["round"],
      counts: reflection && reflection["counts"],
      thought: reflection && thought(s),
      error: s.reflect_error
    }
  end

  # 反思新栏此刻的那一句（心智快照与 observe 共用）：规则只在 `Reflection.thought/1`；不反思的形态没有。调用方保证行已加载。
  defp thought(%{journaling: nil}), do: nil
  defp thought(s), do: Reflection.thought(s.row["reflection"])

  # --- 日计划（规则在 `Life.DayPlan`，流程在 `Life.DayPlan.Round`；本节只做触发、起槽、记账与视图） ---

  # 规划的形态：有写日记的接口，且有可计划的种类（`Offers.plan_kinds/1` 非空：profile 带 `activities` 键即有进食与合成两类）。
  defp planning?(%{journaling: nil}), do: false
  defp planning?(%{journaling: %{kinds: kinds}}), do: kinds != []

  # 每帧观察上的触发检查（观察每秒 20 帧，所以这里要便宜：不到点不写库、不打日志）。条件依次：行已加载、规划的形态、
  # 规划槽空着、有过至少一条经历、观察里有游戏钟与身体状态、不在保存失败后的防抖期内、`DayPlan.due/3` 给出 `:day` 或 `:event`。
  # 身体状态与 `Reflection.Round.right_now/1` 同一条件：它为 nil 时此刻一块写不出，起了也只是白锁住最小间隔。
  # 经历同理（`experienced?/1`）：一条都没有时规划没有可依据的事（实跑 S1-R10 出生那一次就是 `:no_materials`）。
  defp maybe_plan(%{row: nil} = s), do: s
  defp maybe_plan(%{activity_pending: pending} = s) when pending != nil, do: s

  # 回顾与推进共用这一个槽：回顾到点先起回顾（它会开 / 弃任务，先推进一个即将被弃的任务是白花一次写作）；回顾没有起
  # （不到点、当日额度用完、花费到线）才查推进（任务层规划 §2.2）。
  defp maybe_plan(s) do
    with true <- planning?(s),
         nil <- s.plan,
         true <- experienced?(s.row),
         %{world_time: %{day: day, minute_of_day: minute}, self: %{body_state: body_state}}
         when body_state != nil <- s.observation,
         now_ms = s.now.(),
         true <- not_debounced?(s, now_ms) do
      s = maybe_review(s, day, minute, now_ms)
      if s.plan == nil and not_debounced?(s, now_ms), do: maybe_advance(s, day, now_ms), else: s
    else
      _ -> s
    end
  end

  defp not_debounced?(s, now_ms),
    do: s.plan_not_before_ms == nil or now_ms >= s.plan_not_before_ms

  defp maybe_review(s, day, minute, now_ms) do
    with kind when kind != nil <- DayPlan.due(s.row["plan"], day, now_ms),
         {:open, s} <- background(s, :plan) do
      admit_plan(s, kind, day, minute, now_ms)
    else
      # 花费额度停了后台：在 `DayPlan.admit/3` 之前拒，不记调用、不扣当日额度，event 标记留着。
      {{:budget_exhausted, _day}, refused} -> refused
      nil -> s
    end
  end

  # 到点：先记一次调用（`DayPlan.admit/3`：调用数、起调用的时刻、清 event 标记）并保存，保存成功才起槽；保存失败行不变
  # （错误经 `save/2` 可见），一秒之内不再试。当日额度用完：每个游戏日只记一笔 skipped 与一行日志——记 skipped 的那次保存
  # 成功之后才在内存里记下这一日；保存失败同样一秒之内不再试，不记这一日（下次再记）。跨日 `admit/3` 自然恢复。
  defp admit_plan(s, kind, day, minute, now_ms) do
    case DayPlan.admit(s.row["plan"], day, now_ms) do
      {:ok, admitted} ->
        case save(s, %{s.row | "plan" => admitted}) do
          {:ok, s} -> start_plan(%{s | plan_not_before_ms: nil}, kind, day, minute, now_ms)
          {:error, s} -> %{s | plan_not_before_ms: now_ms + @plan_retry_ms}
        end

      {:error, :day_budget_exhausted} when s.plan_exhausted_day == day ->
        s

      {:error, :day_budget_exhausted} ->
        case save(s, %{s.row | "plan" => DayPlan.skip(s.row["plan"])}) do
          {:ok, s} ->
            Logger.info(
              "npc_plan cid=#{s.context.cid} event=skipped kind=#{kind} day=#{day} reason=day_budget_exhausted"
            )

            %{s | plan_exhausted_day: day, plan_not_before_ms: nil}

          {:error, s} ->
            %{s | plan_not_before_ms: now_ms + @plan_retry_ms}
        end
    end
  end

  # 起规划槽的 worker（记调用那次保存已经成功）：快照在本进程里取齐，worker 不回头问 Life（同 `start_round/2`）。
  # “今天已有的意图”各行只在计划是今天的时候有（`DayPlan.column/3`）；旧 wants 不论日号都交进去，由这一次规划留或撤。
  defp start_plan(s, kind, day, minute, now_ms) do
    plan = s.row["plan"]
    names = names(s)

    today =
      case DayPlan.column(plan, day, minute) do
        nil -> []
        %{intents: intents} -> Enum.map(intents, &NpcServer.Mind.plan_intent_line(&1, names))
      end

    snapshot =
      s
      |> planning_snapshot(:day_plan, names, now_ms)
      |> Map.merge(%{
        kind: kind,
        day: day,
        now_minute: minute,
        today: today,
        wants: Enum.map(plan["wants"], & &1["want"]),
        open: s.row["tasks"]["open"],
        open_tasks: Tasks.Prompt.review_open_lines(s.row["tasks"]["open"], names),
        closed_tasks: Tasks.Prompt.review_closed_lines(s.row["tasks"]["closed"])
      })

    s =
      worker(s, :plan, fn ->
        {:ok, _} = Application.ensure_all_started(:ssl)
        DayPlan.Round.write(snapshot)
      end)

    %{
      s
      | plan:
          Map.merge(s.plan, %{
            job: :review,
            kind: kind,
            day: day,
            now_minute: minute,
            now_ms: now_ms
          }),
        plan_error: nil
    }
  end

  # 规划位置（每日回顾、任务推进）共用的快照部分：写作函数（按次 `max_tokens` 4096，任务层决策稿 K-9）、人格卡、词表与取材
  # 要的一切（同反思“自己”一问；`DayPlan.Round.ask/3` 读）。在本进程里取齐，worker 不回头问 Life。
  defp planning_snapshot(s, operation, names, now_ms) do
    Map.merge(s.journaling, %{
      cid: s.context.cid,
      write: write_for(s.journaling, operation, %{max_tokens: Tasks.write_max_tokens()}),
      vocabulary: vocabulary(s, names),
      now_ms: now_ms,
      observation: s.observation,
      recent: recent(s.row),
      buildings: s.row["state"]["buildings"],
      people: Enum.map(State.relationships(s.row["state"]), & &1.actor),
      names: names,
      latest: s.row["reflection"]["latest"],
      adapter: s.adapter,
      # 每路召回的上限同心智快照（召回是串行发的）。
      config: Map.put(s.config, :timeout_ms, @mind_recall_timeout_ms),
      context: s.context
    })
  end

  # --- 任务推进（规则在 `Life.Tasks`，流程在 `Life.Tasks.Round`；与回顾共用规划槽，回顾没有起时才查） ---

  # 推进到点（`Tasks.due/2`：过了最小间隔、有任务在等）→ 花费闸门（到线在记调用之前拒：不记调用，`waiting` 留着，
  # 已写好的步骤照常是候选）→ `Tasks.admit/3` 记一次调用并保存，保存成功才起槽；保存失败行不变，一秒之内不再试。
  # 当日 12 次用完不记、不打日志（`observe/1` 的 `tasks.calls` 看得到；稿件没写跳过的记账）。
  defp maybe_advance(s, day, now_ms) do
    with id when id != nil <- Tasks.due(s.row["tasks"], now_ms),
         {:open, s} <- background(s, :task),
         {:ok, admitted} <- Tasks.admit(s.row["tasks"], day, now_ms) do
      case save(s, %{s.row | "tasks" => admitted}) do
        {:ok, s} -> start_advance(%{s | plan_not_before_ms: nil}, id, day, now_ms)
        {:error, s} -> %{s | plan_not_before_ms: now_ms + @plan_retry_ms}
      end
    else
      {{:budget_exhausted, _day}, refused} -> refused
      _ -> s
    end
  end

  # 起推进槽的 worker（记调用那次保存已经成功）：快照取齐要推进的任务、其它开着的任务与回顾同一套材料（`planning_snapshot/4`）。
  defp start_advance(s, id, day, now_ms) do
    open = s.row["tasks"]["open"]
    task = Enum.find(open, &(&1["id"] == id))

    snapshot =
      s
      |> planning_snapshot(:task_advance, names(s), now_ms)
      |> Map.merge(%{day: day, task: task, others: Enum.reject(open, &(&1["id"] == id))})

    s =
      worker(s, :plan, fn ->
        {:ok, _} = Application.ensure_all_started(:ssl)
        Tasks.Round.write(snapshot)
      end)

    # 槽里存起推进这一刻的基准（`Tasks.basis/2`），落栏时 `Tasks.adopt/6` 比对：写作在途时步骤变了就不采用（stale）。
    slot = %{
      job: :advance,
      task: id,
      basis: Tasks.basis(s.row["tasks"], id),
      day: day,
      now_ms: now_ms
    }

    %{s | plan: Map.merge(s.plan, slot), task_error: nil}
  end

  # 推进落栏（一次保存，读最新的行）：合格 → `Tasks.adopt/6` 与槽里的基准比对（采用：continue 换步骤，done / drop 关掉并写经历；
  # 写作在途时步骤变了：stale，不采用；任务已关：gone）；不合格 → `Tasks.reject/4`（连续 3 次关为 stuck 并写经历）；
  # 写作失败 → `Tasks.fail/1`。写作没有发出（`wrote: false`）同一次保存里 `Tasks.refund/1`。`cannot` 只计数并进日志（交学习是 T-3）。
  # 经历经 `accept/3` 进未封存的尾部。
  defp land_advance(s, slot, outcome) do
    at_ms = s.now.()
    tasks = s.row["tasks"]

    {landed, tasks, episodes, error} =
      case outcome.result do
        :ok ->
          {landed, tasks, episodes} =
            Tasks.adopt(tasks, slot.task, slot.basis, outcome.checked, slot.day, at_ms)

          {landed, tasks, episodes, nil}

        {:rejected, reason} ->
          {tasks, episodes} = Tasks.reject(tasks, slot.task, slot.day, at_ms)
          {:rejected, tasks, episodes, {:rejected, reason}}

        {:failed, reason} ->
          {:failed, Tasks.fail(tasks), [], {:failed, reason}}
      end

    tasks = if outcome.wrote, do: tasks, else: Tasks.refund(tasks)
    {row, next} = accept(s, %{s.row | "tasks" => tasks}, episodes)

    case save(s, seal(row, false)) do
      {:ok, s} ->
        Logger.info(
          "npc_task cid=#{s.context.cid} event=landed task=#{slot.task} day=#{slot.day} " <>
            "#{advance_result(landed, outcome)} wrote=#{outcome.wrote} calls=#{tasks["calls"]["n"]} " <>
            "elapsed_ms=#{outcome.elapsed_ms} usage=#{inspect(outcome.usage)}"
        )

        log_task_episodes(s, episodes)
        %{s | task_error: error} |> automatic() |> follow_round(next)

      {:error, s} ->
        Logger.warning(
          "npc_task cid=#{s.context.cid} event=persist_failed task=#{slot.task} day=#{slot.day} " <>
            "reason=#{inspect(s.error)}"
        )

        %{s | task_error: s.error}
    end
  end

  # 落栏日志的结局：应答合格时 `result=` 是实际的落栏结局（`adopted` / `stale` 写作在途时步骤变了 / `gone` 任务已关），
  # 都带决定、步骤数与 `cannot` 原文（不存进任务，交学习属 T-3，这里是它唯一的去处；决策稿偏差 D-8）；不合格 / 失败带原因。
  defp advance_result(landed, %{result: :ok, checked: checked}),
    do:
      "result=#{landed} verdict=#{checked.task} steps=#{length(checked.steps)} cannot=#{inspect(checked.cannot)}"

  defp advance_result(landed, %{result: {_failure, reason}}),
    do: "result=#{landed} reason=#{inspect(reason)}"

  # 起槽这一刻的词表（稿 A 批 0b）：每个可计划的种类（`Offers.plan_kinds/1`）展开成 `%{kind, criterion, objects: %{显示名 => 对象}}`。
  # 对象是人的种类（说话、对人的登记项）能点名的人 = 关系里的人 ∪ 此刻观察里的他人 ∪ 开着的任务里点名过的人（`Tasks.people/1`，
  # 任务层稿 K-0 评审第 8 条）（关系在前、按 cid；观察里的在后、按观察次序；任务里的最后、按开的次序；去重），
  # 显示名用名字层 `State.person/2`（名字取自此刻观察，取不到写 `actor <cid>`），对象是 `%{"actor" => cid}`。
  # 显示名带 cid，所以不同的人不会撞名。没有对象的种类对象表为空。
  defp vocabulary(s, names) do
    people =
      Enum.uniq(
        Enum.map(State.relationships(s.row["state"]), & &1.actor) ++
          Enum.map(State.others(s.observation), & &1.entity_id) ++
          Enum.flat_map(s.row["tasks"]["open"], &Tasks.people/1)
      )

    for %{kind: kind, criterion: criterion, objects: objects} <- s.journaling.kinds do
      objects =
        case objects do
          :none -> %{}
          :people -> Map.new(people, &{State.person(&1, names), %{"actor" => &1}})
        end

      %{kind: kind, criterion: criterion, objects: objects}
    end
  end

  # 规划槽的结果按槽里的 `job` 分：回顾 / 推进。都等前一条活动经历写盘之后才落栏（落栏读最新的行）。
  defp land_plan(%{activity_pending: nil, plan: %{outcome: outcome} = slot} = s) do
    s = %{s | plan: nil}

    case slot.job do
      :review -> land_review(s, slot, outcome)
      :advance -> land_advance(s, slot, outcome)
    end
  end

  defp land_plan(s), do: s

  # 回顾落栏：使用起槽时的日期与分钟，同时读取最新已入账的计划。写作未发出的轮次在同次保存内退额度。
  # 采用时同一次保存里开 / 弃任务（`Tasks.review/4`，当头步与经历的时刻取落栏这一刻），开 / 弃的经历经 `accept/3` 进未封存的尾部。
  defp land_review(s, slot, outcome) do
    plan = s.row["plan"]

    {landed, plan_error, tasks, episodes} =
      case outcome.result do
        :ok ->
          {tasks, episodes} =
            Tasks.review(s.row["tasks"], outcome.checked.tasks, slot.day, s.now.())

          {DayPlan.adopt(
             plan,
             slot.day,
             slot.now_minute,
             outcome.checked,
             slot.kind,
             slot.now_ms
           ), nil, tasks, episodes}

        {failure, reason} when failure in [:failed, :rejected] ->
          {DayPlan.fail(plan, slot.kind, failure, reason, slot.now_ms), reason, s.row["tasks"],
           []}
      end

    landed = if outcome.wrote, do: landed, else: DayPlan.refund(landed)
    {row, next} = accept(s, %{s.row | "plan" => landed, "tasks" => tasks}, episodes)

    case save(s, seal(row, false)) do
      {:ok, s} ->
        Logger.info(
          "npc_plan cid=#{s.context.cid} event=landed kind=#{slot.kind} day=#{slot.day} " <>
            "result=#{landed["last"]["result"]} reason=#{inspect(plan_error)} wrote=#{outcome.wrote} " <>
            "intents=#{length(landed["intents"])} wants=#{length(landed["wants"])} " <>
            "tasks=#{length(tasks["open"])} elapsed_ms=#{outcome.elapsed_ms} usage=#{inspect(outcome.usage)}"
        )

        log_task_episodes(s, episodes)
        %{s | plan_error: plan_error} |> automatic() |> follow_round(next)

      {:error, s} ->
        Logger.warning(
          "npc_plan cid=#{s.context.cid} event=persist_failed kind=#{slot.kind} day=#{slot.day} " <>
            "result=#{landed["last"]["result"]} reason=#{inspect(s.error)}"
        )

        %{s | plan_error: s.error}
    end
  end

  # 完成的活动按 `{种类, 对象}` 记账（`DayPlan.record_activity/4`；种类、对象与结局由 `Selector.experience/1` 给出，
  # “完成”即结局为 `:completed`，失败与被打断都不记）。
  defp activity_progress(s, experience) do
    if planning?(s) do
      %{kind: kind, object: object, outcome: outcome} = experience

      case s.observation do
        %{world_time: %{day: day, minute_of_day: minute}} when outcome == :completed ->
          {{kind, object}, day, minute}

        _ ->
          nil
      end
    end
  end

  defp record_plan_activity(row, nil), do: row

  defp record_plan_activity(row, {done, day, minute}),
    do: update_in(row["plan"], &DayPlan.record_activity(&1, done, day, minute))

  # --- 任务（规则在 `Life.Tasks`；本节只做记账的接线、每帧的到期 / 停滞、新信息与视图） ---

  # 任务记账的参数：不论结局都记（K-3 按结局分类）；只有规划的形态。时刻是接纳这条活动经历的那一刻。
  defp step_progress(s, %{kind: kind, object: object, outcome: outcome}, at_ms) do
    if planning?(s), do: {{kind, object}, outcome, at_ms}
  end

  defp record_task_step(row, nil), do: row

  defp record_task_step(row, {done, outcome, at_ms}),
    do: update_in(row["tasks"], &Tasks.record_step(&1, done, outcome, at_ms))

  # 记账命中了哪个任务（保存成功之后）：一行 `npc_task … event=step`，带结局与此刻的 waiting；没命中不打。
  defp log_task_step(_s, _before, nil), do: :ok

  defp log_task_step(s, before, {{kind, _object}, outcome, _at_ms}) do
    case Enum.find(s.row["tasks"]["open"], &(&1 not in before["open"])) do
      nil ->
        :ok

      task ->
        Logger.info(
          "npc_task cid=#{s.context.cid} event=step task=#{task["id"]} kind=#{kind} " <>
            "outcome=#{inspect(outcome)} waiting=#{task["waiting"]}"
        )
    end
  end

  # K-3 的两行新信息：只读结构化字段——World 经历的出手者 `"actor"`、对话经历存的原消息里**对我说话**的人
  # （与 Runtime 唤醒同一口径 `Dialogue.direct?/2`：别人叫的是我；旁听别人之间的话、我自己说的都不算）。
  defp task_news(s, entry, tasks) do
    cond do
      "kind:event" in entry["tags"] ->
        news(s, tasks, entry["actor"], "event")

      speaker = addressed_by(entry, s.context.cid) ->
        news(s, tasks, speaker, "heard")

      true ->
        tasks
    end
  end

  # 对话经历存的原消息是过了 JSON 的字符串键（`Dialogue.episode/3`）；取回判定要的两个字段交给 `Dialogue.direct?/2`。
  defp addressed_by(%{"speech" => %{"speaker_id" => speaker, "target_id" => target}}, cid) do
    if Dialogue.direct?(%{speaker_id: speaker, target_id: target}, cid), do: speaker
  end

  defp addressed_by(_entry, _cid), do: nil

  defp news(s, tasks, cid, reason) do
    noted = Tasks.note_news(tasks, cid, reason)

    for task <- noted["open"], task not in tasks["open"] do
      Logger.info(
        "npc_task cid=#{s.context.cid} event=news task=#{task["id"]} reason=#{reason} actor=#{cid}"
      )
    end

    noted
  end

  # 每帧观察上的到期 / 停滞（`Tasks.tick/3`；便宜：至多 3 个任务）。没有变化不写库；有变化时经历经 `accept/3` 进尾部、保存。
  # 行没加载、不规划、活动经历在等写盘、观察里没有游戏钟时不查。保存失败行不变（错误经 `save/2` 可见），下一帧再算。
  defp tick_tasks(%{row: nil} = s), do: s
  defp tick_tasks(%{activity_pending: pending} = s) when pending != nil, do: s

  defp tick_tasks(%{observation: %{world_time: %{day: day}}} = s) do
    with true <- planning?(s),
         tasks = s.row["tasks"],
         {ticked, episodes} when ticked != tasks <- Tasks.tick(tasks, day, s.now.()) do
      {row, next} = accept(s, %{s.row | "tasks" => ticked}, episodes)

      case save(s, seal(row, false)) do
        {:ok, s} ->
          log_task_episodes(s, episodes)
          s |> automatic() |> follow_round(next)

        {:error, s} ->
          s
      end
    else
      _ -> s
    end
  end

  defp tick_tasks(s), do: s

  # 开 / 关任务的经历各一行日志（`npc_task … event=opened|dropped|expired task=`）。
  defp log_task_episodes(s, episodes) do
    for %{"id" => "task:" <> rest} <- episodes do
      [event | id] = rest |> String.split(":") |> Enum.reverse()
      id = id |> Enum.reverse() |> Enum.join(":")
      Logger.info("npc_task cid=#{s.context.cid} event=#{event} task=#{id}")
    end

    :ok
  end

  # 给选择的任务数据（心智快照与 observe 共用）：不规划的形态为 []。调用方保证行已加载。
  defp task_column(s), do: if(planning?(s), do: Tasks.column(s.row["tasks"]), else: [])

  # 任务的 observe：持久行全文，加推进在途（`running`、在推进的任务 id）、当日调用数与计数（取自持久行，CLI 不用翻行）、
  # 最近一次推进失败 / 被拒的原因（只在内存）。
  defp observe_tasks(s) do
    if planning?(s) do
      row = s.row && s.row["tasks"]
      advancing = match?(%{job: :advance}, s.plan)

      %{
        row: row,
        running: advancing,
        task: if(advancing, do: s.plan.task),
        calls: row && row["calls"],
        counts: row && row["counts"],
        error: s.task_error
      }
    end
  end

  # 给选择的日计划数据（心智快照与 observe 共用）：`DayPlan.column/3` 对持久行与此刻观察里的游戏钟。调用方保证行已加载。
  defp plan_column(s) do
    case {planning?(s), s.observation} do
      {true, %{world_time: %{day: day, minute_of_day: minute}}} ->
        DayPlan.column(s.row["plan"], day, minute)

      _ ->
        nil
    end
  end

  defp observe_plan(s) do
    if planning?(s) do
      %{
        enabled: true,
        # 规划槽回顾与推进共用：这里只说回顾（推进在途见 `tasks.running`）。
        running: match?(%{job: :review}, s.plan),
        waiting_for_activity: match?(%{job: :review, outcome: _}, s.plan),
        row: s.row && s.row["plan"],
        column: s.row && plan_column(s),
        error: s.plan_error
      }
    end
  end

  # 这个 NPC 有过至少一条经历（规划的触发条件之一）：还没写进 Hindsight 的（未封存的尾部、已封存待写的片段，即 `recent/1`
  # 的来源），或已写进 Hindsight 的——持久行的 `"retained"` 是写成功的片段累计数，片段至少含一条经历，只增不减，所以
  # 大于 0 即证明写进去过（重启后的老 NPC 未写的经历为空、靠它）。都是常数时间判断（逐帧调用）。
  defp experienced?(row),
    do: row["pending"] != [] or row["fragments"] != [] or row["retained"] > 0

  # 还没写进 Hindsight 的经历：已封存待写的片段，加未封存的尾部；正文不带时刻，“多久以前”由 Mind 按 at_ms 写。
  # 只给最近 #{@max_recent} 条：Hindsight 长时间不可用时待写片段会积压，这一栏不能跟着无限长。
  defp recent(row) do
    episodes = sealed(row["fragments"]) ++ row["pending"]

    for episode <- Enum.take(episodes, -@max_recent),
        do: %{at_ms: episode["at_ms"], text: episode["text"]}
  end

  defp seal(row, force) do
    {fragments, tail} = fragments(row["pending"], force, [])
    %{row | "pending" => tail, "fragments" => row["fragments"] ++ fragments}
  end

  defp fragments([], _, acc), do: {Enum.reverse(acc), []}

  defp fragments(episodes, force, acc) do
    {chunk, rest} = take_fragment(episodes, [], 0)

    if force or Enum.sum(Enum.map(chunk, &String.length(&1["text"]))) >= @fragment_chars do
      first = hd(chunk)
      last = List.last(chunk)
      id = first["id"] <> ":fragment:" <> last["id"]

      fragment = %{"id" => id, "at_ms" => first["at_ms"], "episodes" => chunk}

      fragments(rest, force, [fragment | acc])
    else
      {Enum.reverse(acc), episodes}
    end
  end

  defp take_fragment([], acc, _), do: {Enum.reverse(acc), []}
  defp take_fragment(rest, acc, size) when size >= @fragment_chars, do: {Enum.reverse(acc), rest}

  defp take_fragment([e | rest], acc, size),
    do: take_fragment(rest, [e | acc], size + String.length(e["text"]))

  defp save(s, row) do
    {row, dropped} = cap_fragments(row)

    if row == s.row do
      {:ok, %{s | error: nil}}
    else
      case Memory.life_save(s.memory, s.context.cid, row) do
        :ok -> {:ok, record_fragment_trim(%{s | row: row, error: nil}, dropped)}
        {:error, reason} -> {:error, error(s, reason)}
      end
    end
  end

  # 待写片段的硬上限在这里守：所有持久化都走 `save/2`，所以即使 Hindsight 长时间不可用、retain 一直失败，
  # 持久行也不会无限变大（行越大每次写越慢、越容易再失败，是正反馈）。丢的是最旧的、**还没写进 Hindsight 的
  # 经历**，所以必须吵：一行 warning 带 cid、丢掉的片段数与经历条数、此刻有没有在途的 retain（`in_flight`
  # 就是那一批的片段数——被丢的若在途，成功时仍按它与 `retained` 计数、失败时这批就永久没了），
  # 累计丢弃另进内存计数，由 `observe/1` 的 `dropped_fragments` / `dropped_episodes` 读出。
  defp cap_fragments(row) do
    case length(row["fragments"]) - @max_fragments do
      extra when extra > 0 ->
        {dropped, kept} = Enum.split(row["fragments"], extra)
        {%{row | "fragments" => kept}, dropped}

      _ ->
        {row, []}
    end
  end

  defp record_fragment_trim(s, []), do: s

  # 只有写盘成功才会真正淘汰片段。拒写后的重试不能重复累计丢弃。
  defp record_fragment_trim(s, dropped) do
    count = length(dropped)
    episodes = Enum.sum(Enum.map(dropped, &length(&1["episodes"])))
    in_flight = if s.job, do: length(Map.get(s.job, :ids, [])), else: 0
    dropped_fragments = s.dropped_fragments + count

    Logger.warning(
      "npc_memory_fragments_trimmed cid=#{s.context.cid} dropped=#{count} " <>
        "episodes=#{episodes} kept=#{length(s.row["fragments"])} in_flight=#{in_flight} " <>
        "total_dropped=#{dropped_fragments}"
    )

    %{s | dropped_fragments: dropped_fragments, dropped_episodes: s.dropped_episodes + episodes}
  end

  defp publish(s), do: send(s.owner, {:life_state, s.row["state"], s.row["thanked_seq"]})
  defp automatic(%{job: job} = s) when job != nil, do: s

  # 上一次失败后的退避还没到点：不起槽。到点之后照常按下面的条件重试——失败只推迟这次尝试，不再永久关闭。
  defp automatic(s) do
    if s.job_retry_at_ms != nil and s.now.() < s.job_retry_at_ms do
      s
    else
      cond do
        s.row["fragments"] != [] ->
          start_job(s, :retain)

        s.row["cache"] == nil ->
          start_job(s, :models)

        s.row["dirty"] and
            (s.row["refresh_at_ms"] == nil or s.now.() - s.row["refresh_at_ms"] >= @refresh_ms) ->
          case background(s, :refresh) do
            {:open, s} -> start_job(s, :refresh)
            {_refusal, s} -> s
          end

        true ->
          s
      end
    end
  end

  # --- 花费额度（见 moduledoc“花费额度”）：只在后台触发处读结论，不拦 retain、读认识、选择、说话与召回 ---

  # 此刻花费额度停没停后台：nil 或 `{:budget_exhausted, 北京日}`。
  defp refusal(s) do
    case s.spend.() do
      :open -> nil
      {:paused, %{day: day}} -> {:budget_exhausted, day}
    end
  end

  # 某种后台工作此刻能不能起：`{:open, s}`，或 `{{:budget_exhausted, day}, s}`（已记下这次拒绝）。
  defp background(s, kind) do
    case refusal(s) do
      nil -> {:open, s}
      {:budget_exhausted, day} = refusal -> {refusal, refused(s, kind, day)}
    end
  end

  # 记下一次拒绝：每种后台工作每个北京日只打一行 `npc_spend_refused`（触发在每帧观察、每次落栏上都会查，不逐次打）。
  defp refused(s, kind, day) do
    case Map.fetch(s.spend_refused, kind) do
      {:ok, ^day} ->
        s

      _ ->
        Logger.info("npc_spend_refused cid=#{s.context.cid} kind=#{kind} day=#{day}")
        %{s | spend_refused: Map.put(s.spend_refused, kind, day)}
    end
  end

  defp start_job(s, kind) do
    adapter = s.adapter
    config = s.config
    fragments = s.row["fragments"]

    # 每条经历一份 Hindsight 文档：id、时刻、tags 取自经历条目，正文加时刻前缀。
    documents =
      for episode <- sealed(fragments),
          do: episode |> Map.take(["id", "at_ms", "tags"]) |> Map.put("text", dated(episode))

    s =
      worker(s, :job, fn ->
        {:ok, _} = Application.ensure_all_started(:ssl)

        with {:ok, _} <- adapter.ensure(config, "NPC #{s.context.cid}"),
             {:ok, result} <-
               (case kind do
                  :retain -> adapter.retain(config, documents)
                  :refresh -> adapter.refresh(config)
                  :models -> adapter.models(config)
                end),
             {:ok, status} <- adapter.status(config) do
          {:ok, %{models: result, status: Map.put(status, :last_operation, result)}}
        end
      end)

    %{
      s
      | job_error: nil,
        job_retry_at_ms: nil,
        job: Map.merge(s.job, %{kind: kind, ids: Enum.map(fragments, & &1["id"])}),
        row: if(kind == :refresh, do: Map.put(s.row, "refresh_at_ms", s.now.()), else: s.row)
    }
  end

  # 已封存片段里的经历条目，按片段与片段内的次序（旧在前）。
  defp sealed(fragments), do: Enum.flat_map(fragments, & &1["episodes"])

  @doc """
  交给 Hindsight 的正文：`At <UTC> (UTC), <原文>`，UTC 取条目的 `"at_ms"`（ISO 8601 毫秒），原文是条目的 `"text"`。
  离线测过的就是这个写法；前缀只在这里加（经历条目与反思的存档文档都经它），条目的 `"text"` 不带时刻。
  """
  def dated(%{"at_ms" => at_ms, "text" => text}),
    do:
      "At #{at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()} (UTC), " <> text

  defp worker(s, slot, fun) do
    owner = self()

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(owner, {:result, slot, fun.()}) end, [:link, :monitor])

    Map.put(s, slot, %{pid: pid, ref: ref})
  end

  defp done(s, slot) do
    Process.demonitor(Map.fetch!(s, slot).ref, [:flush])
    Map.put(s, slot, nil)
  end

  defp error(s, reason) do
    Logger.warning("npc_life_error cid=#{s.context.cid} reason=#{inspect(reason)}")
    %{s | error: reason}
  end

  defp job_error(s, reason) do
    failures = s.job_failures + 1
    retry_at_ms = s.now.() + job_backoff_ms(failures, s.context.cid)

    Logger.warning(
      "npc_life_memory_error cid=#{s.context.cid} failures=#{failures} " <>
        "retry_in_ms=#{retry_at_ms - s.now.()} reason=#{inspect(reason)}"
    )

    %{s | job_error: reason, job_failures: failures, job_retry_at_ms: retry_at_ms}
  end

  # 退避时长：30 秒起、每次翻倍、上限 5 分钟，再乘按 cid 稳定算出的 0.75–1.25 抖动，最后**再夹一次上限**
  # （抖动乘在上限之后会到 375 秒，与"上限 5 分钟"的说法不符）。
  # 抖动按 cid 而不是随机数：同一个 NPC 每次算出来一样（可复现、可测），不同 NPC 之间错开
  # ——多 NPC 实跑时不会所有 NPC 在同一刻重试（决策稿 D-3c 要的 jitter，只是不引入随机源）。
  defp job_backoff_ms(failures, cid) do
    doublings = min(max(failures, 1) - 1, 10)
    base = min(@job_retry_ms * Integer.pow(2, doublings), @job_retry_max_ms)
    permille = 75 + :erlang.phash2({:job_backoff, cid}, 51)
    min(div(base * permille, 100), @job_retry_max_ms)
  end

  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :worker_failed
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
