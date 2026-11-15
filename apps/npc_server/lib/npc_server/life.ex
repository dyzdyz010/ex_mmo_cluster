defmodule NpcServer.Life do
  @moduledoc """
  NPC 人生状态唯一 owner，跟随 Runtime 生命周期。canonical 心智、World 游标、待写经历与认识缓存
  原子保存在 NpcMemory 的 life/state 行；观察只派生衰减视图。World 读取与 Hindsight 使用独立 worker，
  慢记忆写入期间继续接纳权威事件。

  经历条目（`"pending"` 与片段里）是 `%{"id", "at_ms", "text", "tags", …}`：`"text"` 是不带时刻的原文，时刻只在 `"at_ms"`，
  `"tags"` 是字符串列表（`kind:event | activity | conversation | sight`、`actor:<cid>`、`place:<名>`，召回按人、按地点精确调取）。
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

  ## 日计划（实现设计 `docs/10-active/cross-cutting/2026-11-15-npc-day-plan-implementation.md` §1、§4）

  一份计划是“今天我打算做几件事”：意图（词表里的活动 + 次数 + 时限）与 `wants`（想做而词表写不出的事）。规则（检查、额度、
  触发判定、采用、记账、给 Mind 的数据）都在纯函数核心 `Life.DayPlan`，一次规划调用的流程在 `Life.DayPlan.Round`；本模块只做
  触发、起槽、落栏、记账与视图。只有**规划的形态**规划：profile 带写日记的接口（同反思，写作接口与人格卡共用）且有候选表
  （词表 = `profile.activities` 的名字与判据）；其余形态不触发、不记账，`mind/2` 与 `observe/1` 的 `plan` 为 nil。

  - **持久行 `"plan"`**（形状见 `DayPlan.new/0`）与其它键同一次保存，重启后还在；日计划之前存下的行在加载边界补成空的一份。
  - **触发只在每帧观察上查**（`maybe_plan/1`，便宜：不到点不写库、不打日志）：行已加载、规划的形态、规划槽空着、观察里有
    游戏钟（`world_time`；日号与日内分钟都取它）、不在防抖期内，且 `DayPlan.due/3` 给出 `:day`（本游戏日还没有采用过计划）
    或 `:event`（接纳经历时有 `kind:event`，在那次保存里 `DayPlan.note_event/1`）。到点后 `DayPlan.admit/2` 记一次调用并保存，
    保存成功才起槽；保存失败行不变，一秒之内不再试。当日 5 次额度用完：每个游戏日只记一笔 `skipped` 与一行日志。
  - **规划槽**（第四个 worker 槽 `plan`，与 `poll` / `job` / `reflect` 并列，可与反思槽同时在途）：快照在起槽那一刻取齐，
    worker 不回头问 Life。结果落栏是一次保存：写成且检查通过 → `DayPlan.adopt/6`；写作失败、检查不过、worker 崩溃 →
    `DayPlan.fail/5`（意图与 `wants` 不动，选择照常）。日号、分钟、时刻都用**起槽那一刻**的：调用期间越过日界时，计划按起槽时的
    日号落栏，下一帧观察因日号变了再触发 `:day`。
  - **活动记账**：`activity/2` 接纳活动经历的同一次保存里，完成的活动按此刻观察里的游戏钟 `DayPlan.record_activity/4`；
    失败的不计（`done` 只由代码按活动结果增）。
  - **视图**：`mind/2` 的 `plan` 是 `DayPlan.column/3` 对持久行与此刻游戏钟的结果；`observe/1` 的 `plan` 是
    `%{enabled, running, row: 持久行 "plan", column: 同 mind/2, error: 最近一次规划调用失败的原因（只在内存，起下一次时清空）}`。
  - 日志一律 `npc_plan cid=<cid> …`（`start` / `end` 在槽里，`landed` / `persist_failed` / `crashed` / `skipped` 在本模块）。

  已知的未设上限处与边界（只记事实）：
  - “当日额度用完只记一次 skipped”的标记只在内存：Life 在同一游戏日重启后，再到点会再记一次。
  - 规划槽在途时 Life 重启：调用已在那次保存里记过（`calls` 不退还），结果随进程丢掉，不记 `failed`；行里的意图沿用上一份。
  - 落栏那次保存失败：调用已记、这一次的计划或失败都没有落进行里（`last_at_ms` 也没记，最小间隔只从上一次落了栏的调用算），
    所以随后的帧可能立即再起一次（额度照扣，至多到当日 5 次）。
  - 每帧都调一次 Life 的时钟与 `DayPlan.due/3`（都是常数时间）。
  """
  use GenServer
  require Logger
  alias NpcServer.{Dialogue, Memory, Persona, Life.State, Life.Hindsight, Life.Sight}
  alias NpcServer.Life.{Appraisal, DayPlan, Reflection}
  alias NpcServer.Life.Reflection.{Round, Writer}
  @fragment_chars 3000
  # 起规划槽之前那次保存失败后，多久之内不再试（观察每秒 20 帧，不逐帧重试写库）：原创取值。
  @plan_retry_ms 1000
  @refresh_ms 600_000
  # 心智快照各路召回的单路上限（毫秒）：既是那一路 HTTP 请求的超时，也是并行时等那一路的墙钟上限。
  # 写入与认识刷新仍用适配器的长超时。
  @mind_recall_timeout_ms 10_000
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

  @doc "读取派生心智、持久游标、批写状态、缓存年龄和显式错误。"
  def observe(cid), do: call(cid, :observe)
  @doc "封存不足 3000 字的尾片段并后台批写；立即返回任务状态。"
  def flush(cid), do: call(cid, :flush)
  @doc "后台刷新四份认识；立即返回任务状态，决策不会调用此入口。"
  def refresh(cid), do: call(cid, :refresh)

  @doc """
  手动起一轮反思（CLI / 调试用，同 `flush/1` 的形状）：行没加载 → `{:error, :life_not_ready}`；没开反思 →
  `{:error, :reflection_disabled}`；槽在途 → `{:ok, %{status: :busy}}`；还没收到观察 → `{:error, :no_observation}`（不动触发状态、
  不计 `skipped`）；自上一轮以来没有新经历 → `{:ok, %{status: :empty}}`；否则这一刻起一轮（`Reflection.manual/2`，
  `causes: [:manual]`；同到点的一轮一样 `Reflection.started/2`、`rounds` 加一，与之同一次保存）→ `{:ok, %{status: :started}}`；
  那次保存失败 → `{:error, 原因}`，不起槽。
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
  （`Task.async_stream`，同时至多 #{@recall_concurrency} 路，每路最多等 #{@mind_recall_timeout_ms} 毫秒：选择是秒级决策），
  结果按 `NpcServer.Mind.merge_recalled/1` 合成一张清单。另给出还没写进 Hindsight 的经历。返回 `{:ok, 视图}`：

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

  读不到就是显式失败，不冒充“没有记忆”：`{:error, :life_not_running | :life_not_ready |
  {:life_models_unavailable, 原因} | 召回的失败原因 | :recall_timeout | World 路由或查询的失败原因}`。
  **任何一路**失败或超时，整次视图都失败（不拿其余几路凑一张残缺的清单）；失败的那一路的问句与原因记进 `observe/1` 的 `recall`。
  新 NPC 的空 bank 召回为空是正常结果。World 读不到时不写“在”或“不在”，整份视图失败（World 调用退出时发问 worker 随之退出，
  同样是显式失败）。
  """
  def mind(cid, queries) do
    with {:ok, snapshot, recalled} <- recollect(cid, queries, @mind_recall_timeout_ms),
         {:ok, buildings} <- standing(snapshot.mind["buildings"], snapshot.context) do
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
         plan: snapshot.plan
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
  # 返回 `%{routes: [每路的结果，按 queries 的次序], latency_ms: 墙钟}`。`timeout_ms` 是每路的上限（整数时也写进适配器的
  # 单次请求超时；`:infinity` 时只由适配器自己的超时约束）。任何一路失败或超时就停下（其余在途的路随流结束被关掉），
  # 整次失败。成败记回 owner 供 observe 查看。
  defp recollect(cid, queries, timeout_ms) do
    with {:ok, snapshot} <- call(cid, :context) do
      config =
        if timeout_ms == :infinity,
          do: snapshot.config,
          else: Map.put(snapshot.config, :timeout_ms, timeout_ms)

      started = System.monotonic_time(:millisecond)

      result =
        queries
        |> Task.async_stream(
          fn query -> {query, snapshot.adapter.recall(config, query, snapshot.now_ms)} end,
          max_concurrency: @recall_concurrency,
          timeout: timeout_ms,
          on_timeout: :kill_task,
          zip_input_on_exit: true
        )
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, {_query, {:ok, recalled}}}, {:ok, routes} ->
            {:cont, {:ok, [recalled.results | routes]}}

          {:ok, {query, {:error, reason}}}, _ ->
            {:halt, {:error, query, reason}}

          {:exit, {query, :timeout}}, _ ->
            {:halt, {:error, query, :recall_timeout}}
        end)

      latency_ms = System.monotonic_time(:millisecond) - started

      case result do
        {:ok, routes} ->
          GenServer.cast(
            name(cid),
            {:recall, %{status: :done, routes: length(routes), latency_ms: latency_ms}}
          )

          {:ok, snapshot, %{routes: Enum.reverse(routes), latency_ms: latency_ms}}

        {:error, query, reason} ->
          GenServer.cast(
            name(cid),
            {:recall, %{status: :failed, error: reason, query: query.query}}
          )

          {:error, reason}
      end
    end
  end

  @doc "接收 Body 当前场景身份和纯观察；不阻塞发送者。"
  def observation(pid, observation), do: GenServer.cast(pid, {:observation, observation})
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
  completed: 是否完成}`（`NpcServer.Selector.experience/2`）。与 World 事件、Speech 同样进未封存的尾部，攒够一个片段后写入 Hindsight。
  原文末尾加一句期间事实（见 moduledoc；没有开始信号或期间没有观察则不加）；tags 是 `kind:activity`、期间进过 6 米内的
  每个人 `actor:<cid>`、有地名时 `place:<地名>`。规划的形态在同一次保存里给日计划记账（完成的才记，见 moduledoc 的“日计划”）；
  不规划的形态只读 `text` 与 `place`。由 Runtime 在活动结束时调用一次；不改 World 游标、情绪或关系。
  """
  def activity(pid, %{text: _, place: _} = experience),
    do: GenServer.cast(pid, {:activity, experience})

  @doc "提交本次模型情绪评价；持久化完成才返回成功，调用方随后才执行动作。"
  def appraise(cid, through, entries), do: call(cid, {:appraise, through, entries})

  defp name(cid), do: {:global, {__MODULE__, node(), cid}}

  defp call(cid, request) do
    try do
      GenServer.call(name(cid), request)
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
       speech_pending: [],
       # 正在进行的活动的最近距离账：nil = 没有收到开始信号；`%{observed: 期间收到过观察, closest: Life.State.approach/2 的账}`。
       activity: nil,
       # “看到的”进行中的账（`Life.Sight.new/0`）：还没结束的相遇、还没合上的建造 / 拆除、每人频率上限。只在内存，重启即丢。
       sight: Sight.new(),
       # 写日记所需（不变的配置）：nil = 这个形态不反思；否则是写日记的函数、人格卡一行与反思库（见 `journaling/3`）。
       # 与持久行的 "reflection"（反思的状态）不是一回事。
       journaling: journaling(profile, config, context.cid),
       # 反思槽（worker，同 poll / job）：nil 或 `%{pid, ref, round, now_ms, taken, landed}`（见 `start_round/2`）。
       reflect: nil,
       # 最近一轮里最近一次失败的原因（只在内存，observe 用）：起下一轮时清空。
       reflect_error: nil,
       # 规划槽（worker，同 reflect）：nil 或 `%{pid, ref, kind, day, now_minute, now_ms}`（见 `start_plan/5`）。
       plan: nil,
       # 最近一次规划调用失败的原因（只在内存，observe 用）：起下一次时清空，采用成功时为 nil。
       plan_error: nil,
       # 起槽之前那次保存失败后，这一刻之前不再试（内存里的防抖，不落库）。
       plan_not_before_ms: nil,
       # 当日额度用完那次已经记过一笔 skipped 的游戏日（每个游戏日只记一次；内存里，Life 重启即忘）。
       plan_exhausted_day: nil
     }}
  end

  # 写日记所需：profile 有写日记的接口（`reflect`）才有。写日记的函数可经 `profile.write_journal` 注入
  # （同 Selector 经 `profile.request` 注入 Jev 发送函数的做法），缺省是 `Writer.write(profile.reflect, …)`。
  # 反思库的 config 是经历库的换一个 bank。日计划共用写日记的接口与人格卡，词表是候选表的名字与判据（`profile.activities`，
  # 次序不变；没有候选表的形态为 []，不规划）。
  defp journaling(%{reflect: endpoint} = profile, config, cid),
    do: %{
      write:
        Map.get(profile, :write_journal, fn system, user ->
          Writer.write(endpoint, system, user)
        end),
      character: Persona.describe(profile.who, profile.persona),
      archive: %{config | bank: "npc-reflect-#{cid}"},
      archive_name: "NPC #{cid} journal",
      activities:
        for(
          activity <- Map.get(profile, :activities, []),
          do: Map.take(activity, [:name, :criterion])
        )
    }

  defp journaling(_profile, _config, _cid), do: nil

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
        hindsight: s.status,
        recall: s.recall,
        decision: s.decision,
        unsaved_speech: length(s.speech_pending),
        unsaved_experiences: length(s.experience_pending),
        sight_capped: s.sight.capped,
        emotion_owner: if(s.appraise, do: :model, else: :construction_rules),
        reflection: observe_reflection(s),
        plan: observe_plan(s)
      }}, s}
  end

  def handle_call(:context, _, %{row: nil} = s), do: {:reply, {:error, :life_not_ready}, s}

  def handle_call(:context, _, s) do
    if s.row["cache"] do
      {:reply,
       {:ok,
        %{
          adapter: s.adapter,
          config: s.config,
          now_ms: s.now.(),
          mind: State.view(s.row["state"], s.now.()),
          cache: s.row["cache"],
          # 现查 World 用（`mind/2` 在调用者进程里查“我的建筑”此刻在不在）。
          context: s.context,
          recent: recent(s.row),
          thought: thought(s),
          plan: plan_column(s)
        }}, s}
    else
      {:reply, {:error, {:life_models_unavailable, s.job_error || s.error}}, s}
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
      round = Reflection.manual(s.row["reflection"]["trigger"], s.now.())

      case save(s, mark_round_started(s.row, round)) do
        {:ok, s} -> {:reply, {:ok, %{status: :started}}, start_round(s, round)}
        {:error, s} -> {:reply, {:error, s.error}, s}
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

  def handle_call(:refresh, _, s),
    do: {:reply, {:ok, %{status: :started}}, start_job(s, :refresh)}

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

  @impl true
  def handle_cast({:observation, o}, s) do
    context = %{s.context | scene_id: Map.get(o.self, :scene_id, s.context.scene_id)}
    {sight, seen, capped} = Sight.see(s.sight, o, s.now.())
    s = %{s | observation: o, context: context, activity: approach(s.activity, o), sight: sight}
    s = record_sight(s, seen, capped)

    s =
      if s.appraise and s.row != nil and s.row["state"]["affect"]["next_seq"] == 0 and
           not Enum.any?(s.experience_pending, fn {kind, _, _, _} -> kind == "situation" end) do
        enqueue_experience(s, "situation", %{self: o.self, entities: o.entities})
      else
        s
      end

    {:noreply, maybe_plan(s)}
  end

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

  # 活动只能在一次成功的选择之后结束，而选择要先读到本 owner 的视图，所以此时 row 必已加载。
  # 规划的形态在接纳这条经历的同一次保存里给日计划记账（`record_plan_activity/3`）。
  def handle_cast({:activity, %{text: text, place: place} = experience}, s) do
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

    s = %{s | activity: nil}
    {row, next} = accept(s, s.row, [episode])
    row = record_plan_activity(s, row, experience)

    case save(s, seal(row, false)) do
      {:ok, s} -> {:noreply, s |> automatic() |> follow_round(next)}
      {:error, s} -> {:noreply, s}
    end
  end

  def handle_cast({:speech, message}, s) do
    s = %{s | speech_pending: s.speech_pending ++ [message]}
    {:noreply, save_speech(s)}
  end

  @impl true
  def handle_info(:poll, %{poll: nil} = s) do
    memory = s.memory
    context = s.context
    row = s.row

    {:noreply,
     worker(s, :poll, fn ->
       with {:ok, loaded} <- if(row, do: {:ok, row}, else: Memory.life_load(memory, context.cid)),
            {:ok, route} <- context.router.route(context.scene_id),
            {:ok, events} <-
              VoxelRegion.World.interactions_since(
                route.world_ref,
                loaded && loaded["state"]["cursor"]
              ) do
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

        {:error, reason} ->
          error(s, reason)
      end

    Process.send_after(self(), :poll, s.poll_ms)
    {:noreply, s}
  end

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

          case save(s, row) do
            {:ok, s} -> automatic(%{s | status: result.status, job_error: nil})
            {:error, s} -> s
          end

        {:error, reason} ->
          job_error(s, reason)
      end

    {:noreply, s}
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

  # 规划槽交回的结果（`DayPlan.Round.write/1`）：清槽，落栏是一次保存——采用（`DayPlan.adopt/6`，日号与分钟用起槽那一刻的，
  # 所以调用期间越过日界时计划按起槽时的日号落栏，下一帧观察因日号变了再触发 `:day`）或记一笔失败 / 被拒（`DayPlan.fail/5`，
  # 意图不动）。时刻一律是起槽那一刻（`now_ms`），两次调用的最小间隔从它算。保存失败：行不变、错误经 `save/2` 可见。
  def handle_info({:result, :plan, outcome}, %{plan: slot} = s) do
    s = done(s, :plan)
    plan = s.row["plan"]

    {landed, plan_error} =
      case outcome.result do
        :ok ->
          {DayPlan.adopt(
             plan,
             slot.day,
             slot.now_minute,
             outcome.checked,
             slot.kind,
             slot.now_ms
           ), nil}

        {failure, reason} when failure in [:failed, :rejected] ->
          {DayPlan.fail(plan, slot.kind, failure, reason, slot.now_ms), reason}
      end

    case save(s, %{s.row | "plan" => landed}) do
      {:ok, s} ->
        Logger.info(
          "npc_plan cid=#{s.context.cid} event=landed kind=#{slot.kind} day=#{slot.day} " <>
            "result=#{landed["last"]["result"]} reason=#{inspect(plan_error)} " <>
            "intents=#{length(landed["intents"])} wants=#{length(landed["wants"])} " <>
            "elapsed_ms=#{outcome.elapsed_ms} usage=#{inspect(outcome.usage)}"
        )

        {:noreply, %{s | plan_error: plan_error}}

      {:error, s} ->
        Logger.warning(
          "npc_plan cid=#{s.context.cid} event=persist_failed kind=#{slot.kind} day=#{slot.day} " <>
            "result=#{landed["last"]["result"]} reason=#{inspect(s.error)}"
        )

        {:noreply, %{s | plan_error: s.error}}
    end
  end

  # 规划槽崩溃（写作函数退出、取材时抛错等）：清槽，当一次失败记（`DayPlan.fail/5`，原因带截断的退出原因）；Life 不受影响。
  def handle_info({:DOWN, ref, :process, _, reason}, %{plan: %{ref: ref} = slot} = s) do
    detail = reason |> inspect(limit: 10, printable_limit: 200) |> String.slice(0, 400)

    Logger.warning(
      "npc_plan cid=#{s.context.cid} event=crashed kind=#{slot.kind} day=#{slot.day} reason=#{detail}"
    )

    failure = {:plan_worker_crashed, detail}
    s = %{done(s, :plan) | plan_error: failure}

    plan = DayPlan.fail(s.row["plan"], slot.kind, :failed, failure, slot.now_ms)

    case save(s, %{s.row | "plan" => plan}) do
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
      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  def handle_info({:EXIT, owner, _}, %{owner: owner} = s) do
    for w <- [s.poll, s.job, s.reflect, s.plan], w != nil, do: Process.exit(w.pid, :shutdown)
    {:stop, :shutdown, s}
  end

  def handle_info({:EXIT, _, _}, s), do: {:noreply, s}

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
      "plan" => DayPlan.new()
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

  # 只有 owner 推进当前 canonical；在途 World 读取不能覆盖模型刚提交的情绪。
  # 加载边界：反思之前存下的行没有 "reflection"、日计划之前存下的行没有 "plan"，只在这里补成空的一份，别处一律直接读。
  defp accept_world(s, loaded, events) do
    row =
      s.row ||
        (loaded &&
           loaded
           |> Map.put_new("reflection", empty_reflection())
           |> Map.put_new("plan", DayPlan.new())) ||
        initial(s.context.cid, events, s.now.())

    if row["state"]["world_id"] != events.world_id do
      error(s, :life_world_identity_mismatch)
    else
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
  end

  defp advance_world(s, row, canonical, events) do
    {canonical, episodes} =
      State.advance(
        canonical,
        events.events,
        events.cursor,
        s.now.(),
        if(s.appraise, do: :model, else: :rules),
        names(s)
      )

    # 所见只取没有被写成“动我的建筑”经历的事件（同一件事不写两条）；分组账与到点检查在 `Life.Sight`。
    # 账无论保存成败都换成新的：写失败时这几条丢掉（与活动经历相同），重来的同一批事件按 seq 不再算一次。
    {sight, seen, capped} =
      Sight.witness(s.sight, Sight.unwritten(events.events, episodes), s.observation, s.now.())

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

    {candidate, next} = accept(s, %{row | "state" => canonical}, episodes ++ seen)

    case save(s, seal(candidate, false)) do
      {:ok, s} ->
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
  defp names(%{observation: o}), do: Map.new(o.entities, &{&1.entity_id, &1.name})

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
    save_experiences(%{s | experience_pending: s.experience_pending ++ [source]})
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
  #   起不了 → skipped 加一、触发状态不动（下一条经历进来还会到点），下一步 `{:skip, 一轮, :busy | :no_observation}`。
  # 这一批里有 `kind:event` 的经历时，同一份行里给日计划记下“有 event 在等着重排”（`DayPlan.note_event/1`；下一帧观察到点就起）。
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
      if Enum.any?(entries, &("kind:event" in &1["tags"])),
        do: DayPlan.note_event(row["plan"]),
        else: row["plan"]

    row = %{
      row
      | "pending" => row["pending"] ++ entries,
        "reflection" => reflection,
        "plan" => plan
    }

    cond do
      due == nil -> {row, nil}
      reason = cannot_start(s) -> {count_skipped(row), {:skip, due, reason}}
      true -> {mark_round_started(row, due), {:start, due}}
    end
  end

  # 到点却起不了一轮的原因；起得了为 nil。
  defp cannot_start(%{reflect: slot}) when slot != nil, do: :busy
  defp cannot_start(%{observation: nil}), do: :no_observation
  defp cannot_start(_s), do: nil

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

  defp follow_round(s, {:skip, round, reason}) do
    Logger.info(
      "npc_reflect cid=#{s.context.cid} event=skipped trigger_at_ms=#{round.at_ms} " <>
        "causes=#{Enum.join(round.causes, ",")} reason=#{reason}"
    )

    s
  end

  # 起反思槽的 worker（`mark_round_started/2` 那次保存已经成功）：快照在本进程里取齐，worker 不回头问 Life。当时的 "new" 整份交给这一轮，
  # 槽上记下取走了几条（taken，做完时从 "new" 头上删掉这几条）、这一轮的此刻（now_ms）与落栏了没有（landed：
  # nil 还没交回写作结果、true 已落栏、false 落栏那次保存失败）。起轮时清掉上一轮的失败原因。
  defp start_round(s, round) do
    new = s.row["reflection"]["new"]
    now_ms = s.now.()

    snapshot =
      Map.merge(s.journaling, %{
        cid: s.context.cid,
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
        {:ok, _} = Application.ensure_all_started(:inets)
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

  # 规划的形态：有写日记的接口，且有候选表（词表非空）。
  defp planning?(%{journaling: nil}), do: false
  defp planning?(%{journaling: %{activities: activities}}), do: activities != []

  # 每帧观察上的触发检查（观察每秒 20 帧，所以这里要便宜：不到点不写库、不打日志）。条件依次：行已加载、规划的形态、
  # 规划槽空着、观察里有游戏钟、不在保存失败后的防抖期内、`DayPlan.due/3` 给出 `:day` 或 `:event`。
  defp maybe_plan(%{row: nil} = s), do: s

  defp maybe_plan(s) do
    with true <- planning?(s),
         nil <- s.plan,
         %{world_time: %{day: day, minute_of_day: minute}} <- s.observation,
         now_ms = s.now.(),
         true <- s.plan_not_before_ms == nil or now_ms >= s.plan_not_before_ms,
         kind when kind != nil <- DayPlan.due(s.row["plan"], day, now_ms) do
      admit_plan(s, kind, day, minute, now_ms)
    else
      _ -> s
    end
  end

  # 到点：先记一次调用（`DayPlan.admit/2`）并保存，保存成功才起槽；保存失败行不变（错误经 `save/2` 可见），
  # 一秒之内不再试。当日额度用完：每个游戏日只记一笔 skipped 与一行日志（内存里记下这一日），跨日 `admit/2` 自然恢复。
  defp admit_plan(s, kind, day, minute, now_ms) do
    case DayPlan.admit(s.row["plan"], day) do
      {:ok, admitted} ->
        case save(s, %{s.row | "plan" => admitted}) do
          {:ok, s} -> start_plan(%{s | plan_not_before_ms: nil}, kind, day, minute, now_ms)
          {:error, s} -> %{s | plan_not_before_ms: now_ms + @plan_retry_ms}
        end

      {:error, :day_budget_exhausted} when s.plan_exhausted_day == day ->
        s

      {:error, :day_budget_exhausted} ->
        Logger.info(
          "npc_plan cid=#{s.context.cid} event=skipped kind=#{kind} day=#{day} reason=day_budget_exhausted"
        )

        s = %{s | plan_exhausted_day: day}

        case save(s, %{s.row | "plan" => DayPlan.skip(s.row["plan"])}) do
          {:ok, s} -> s
          {:error, s} -> s
        end
    end
  end

  # 起规划槽的 worker（记调用那次保存已经成功）：快照在本进程里取齐，worker 不回头问 Life（同 `start_round/2`）。
  # “今天已有的意图”各行只在计划是今天的时候有（`DayPlan.column/3`）；旧 wants 不论日号都交进去，由这一次规划留或撤。
  defp start_plan(s, kind, day, minute, now_ms) do
    plan = s.row["plan"]

    today =
      case DayPlan.column(plan, day, minute) do
        nil -> []
        %{intents: intents} -> Enum.map(intents, &NpcServer.Mind.plan_intent_line/1)
      end

    snapshot =
      Map.merge(s.journaling, %{
        cid: s.context.cid,
        kind: kind,
        day: day,
        now_minute: minute,
        now_ms: now_ms,
        observation: s.observation,
        recent: recent(s.row),
        buildings: s.row["state"]["buildings"],
        people: Enum.map(State.relationships(s.row["state"]), & &1.actor),
        names: names(s),
        latest: s.row["reflection"]["latest"],
        adapter: s.adapter,
        # 每路召回的上限同心智快照（召回是串行发的）。
        config: Map.put(s.config, :timeout_ms, @mind_recall_timeout_ms),
        context: s.context,
        today: today,
        wants: Enum.map(plan["wants"], & &1["want"])
      })

    s =
      worker(s, :plan, fn ->
        {:ok, _} = Application.ensure_all_started(:inets)
        {:ok, _} = Application.ensure_all_started(:ssl)
        DayPlan.Round.write(snapshot)
      end)

    %{
      s
      | plan: Map.merge(s.plan, %{kind: kind, day: day, now_minute: minute, now_ms: now_ms}),
        plan_error: nil
    }
  end

  # 日计划记账（在接纳活动经历的同一份行里）：规划的形态、活动完成（失败的不计）、本 owner 此刻的观察里有游戏钟时，
  # 按此刻的日号与分钟 `DayPlan.record_activity/4`；否则行不动。`experience` 是 `Selector.experience/2` 的结果：规划的形态
  # 要求它带 `activity` 与 `completed`（缺了直接崩，是产生者的错误）；不规划的形态不读这两个键。
  defp record_plan_activity(s, row, experience) do
    if planning?(s) do
      %{activity: activity, completed: completed} = experience

      case s.observation do
        %{world_time: %{day: day, minute_of_day: minute}} when completed ->
          update_in(row["plan"], &DayPlan.record_activity(&1, activity, day, minute))

        _ ->
          row
      end
    else
      row
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
        running: s.plan != nil,
        row: s.row && s.row["plan"],
        column: s.row && plan_column(s),
        error: s.plan_error
      }
    end
  end

  # 还没写进 Hindsight 的经历：已封存待写的片段，加未封存的尾部；正文不带时刻，“多久以前”由 Mind 按 at_ms 写。
  defp recent(row),
    do:
      for(
        episode <- sealed(row["fragments"]) ++ row["pending"],
        do: %{at_ms: episode["at_ms"], text: episode["text"]}
      )

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
    if row == s.row do
      {:ok, %{s | error: nil}}
    else
      case Memory.life_save(s.memory, s.context.cid, row) do
        :ok -> {:ok, %{s | row: row, error: nil}}
        {:error, reason} -> {:error, error(s, reason)}
      end
    end
  end

  defp publish(s), do: send(s.owner, {:life_state, s.row["state"], s.row["thanked_seq"]})
  defp automatic(%{job: job} = s) when job != nil, do: s
  defp automatic(%{job_error: reason} = s) when reason != nil, do: s

  defp automatic(s) do
    cond do
      s.row["fragments"] != [] ->
        start_job(s, :retain)

      s.row["cache"] == nil ->
        start_job(s, :models)

      s.row["dirty"] and
          (s.row["refresh_at_ms"] == nil or s.now.() - s.row["refresh_at_ms"] >= @refresh_ms) ->
        start_job(s, :refresh)

      true ->
        s
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
        {:ok, _} = Application.ensure_all_started(:inets)
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
    Logger.warning("npc_life_memory_error cid=#{s.context.cid} reason=#{inspect(reason)}")
    %{s | job_error: reason}
  end

  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :worker_failed
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
