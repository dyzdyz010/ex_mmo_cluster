# NPC 线统筹与交接（2026-11-11 起）

分类：工程交接文档，不是设计正文。设计与结论分别见
[`2026-11-10-npc-utility-selector.md`](2026-11-10-npc-utility-selector.md)（活动选择器、日计划、升级）与
[`2026-11-11-npc-jev-decision-research.md`](2026-11-11-npc-jev-decision-research.md)（Jev 决策调研、人格卡）。
本页只记：谁在做、做到哪、证据在哪、下一步是什么。接手的会话先读本页，再读上面两篇。

## 接手入口（2026-11-12，会话 voxim-ef 结束时写）

**总纲是 [`2026-11-12-npc-architecture-overview.md`](2026-11-12-npc-architecture-overview.md)**：一条控制链（规划 LLM → 选择 Jev → 执行行为树）、
一块共享心智快照（Life + Hindsight）、一个回路。用户 2026-11-12 明确要求不再按组件各自为战，要“分层但统一的一个 NPC 大模块，
不同模块在不同延迟和时间尺度上起作用”。本页下方的“评审后的路线 R1–R7”是按组件拆的旧表，**以总纲的薄片顺序为准**。

**2026-11-12 用户已逐项确认总纲**（整体概念与薄片顺序、人格单一来源、情绪评价的归属、薄片一不说话、`Utility` 的时钟打分不保留、
voxim-9c 的代码按原样提交）。决定的正文在总纲“已确认的决定”一节。voxim-9c 的代码已提交为基线 `4960146e`
（单测通过、未实跑、日计划不启用）。现在做的是**薄片一**，任务表见下文“薄片一的任务”。

接手的会话：读总纲 → 读本页“薄片一的任务”与“进度记录” → 接着推进表里第一个未完成的任务。统筹会话只拆任务、收结果、验证、提交。

### 交接（2026-11-14，第十一个统筹会话 → 第十二个，因上下文接近 300k）——接手先读这一节，再按需读紧接着的“第十一个统筹会话的进展”；任务书 `.demo/observe/npc-slice1-20261112/handoff-12-brief.md`

**一句话**：反思模块 R1、R2、R3 都已编译、测试并本地提交；R3 经过两轮独立评审（复审无阻断项）并做了收尾修补。**R3 是已实现、已测试、已评审，未实跑、未验收。** R4（新栏）仍等用户定新栏放什么。工作区干净，分支未推送。

**提交**（本会话）：`7780f116` R1、`84829049` R2、`c6b610c1` R3、`9d40ee6c` R3 收尾（崩溃路径的两条用例、文档）；其余是文档提交。最后一次测试：`npc_life_test.exs` 21 passed（连跑两次）、reflection 13、round 4（日志 `s1y/r3-polish/`）；其余文件在 R3 修正那一轮全部通过（`s1y/r3-fix/`）。

**用户那边的状态**：用户 2026-11-14 在对话里问了“R4 新栏是什么东西”，统筹会话用中文解释了新栏是什么、三种放法与离线读数、建议（只放“自己”一问的收尾那句打算并标上多久以前想的）；**用户还没有答复选哪一种**。§10.11“要用户定的”第 2 条（“当面问 Corvin”没有对应活动）同样没有答复。
用户要求**用中文交流**（2026-11-14 原话“说中文”）。用户还问过整体路线：薄片一三条验收已通过；现在是薄片二的前半段（内容与召回，反思是其中一块）；LLM 规划与说话没开始。

**下一步（按此顺序）**
1. **R3 的短实跑（NPC-only，不算验收；不依赖用户对 R4 的答复，先做这一件）**：真实服务端里起一个 NPC，让反思在产品里真的跑几轮——看触发、写日记（真实网关）、落栏、存档、`Life.observe` 的 `reflection`、`npc_reflect` 日志；期望运行前写下。做法同 S1-T（配方见本页“证据与复跑”与 `s1t/`）。
   新增要配的环境变量：`NPC_REFLECT_URL`（magpie 网关的 `/v1/messages`）、`NPC_REFLECT_KEY`、`NPC_REFLECT_MODEL`（S1-X2 用的 `claude/claude-sonnet-5-5`；网关地址与 key 的来源见 `s1g/services-20261113-magpie.txt` 与 `s1x3/gateway/report.md`，值不写进任何文件）。
   **这一步还有一个用处：R4 的测试数据必须是产品产生的**——R4 要用的“持久行里的反思”（`"latest"` 的收尾一句与时刻）应从这次实跑导出，不手写。导出 Life 的持久行与 `observe`、每次给 Jev 的 state、反思库的文档。
   专门看 R3 留下的两件：拆屋那一轮若写作失败，小屋的反思推迟多久；无事时是否每 20 次活动空转一轮（§10.11）。起长时间节点前先告知 voxim-d4；实跑不与编译并行；Jev、Hindsight、网关请求并发不超过 3；用量与各会话共用额度，遇到额度或认证类错误不重试。
2. **R4 新栏**：等用户答复 §10.11“要用户定的”第 1 条。答复若出现在对话里（也可能由第十一个会话 ex-mmo-cluster-npc-b5 转来），把原话记进内容规范 §10.11 与本页再做；**没有答复不要按建议自行实现**。做完第 1 步仍没有答复，就向用户再问一次（中文，把三种放法与建议说清）。
3. R5：npc_server 全套测试（Life 持久行与 state 文本都是共享契约）；README 的 Life 一节加反思；**把 `NPC_REFLECT_*` 三个变量写进部署清单 / runbook 涉及的文档**（现在只在 Registry 的 moduledoc 里）。
4. R6：真实服务端闭环实跑（期望运行前写下，§10.11“验收”一条列了至少要看的几件，加上本页“R3 留给后面的已知事项”前两条）。这一步才谈得上验收。
5. 其后：`Current situation` 与经历原文里原始单位与坐标的写法（独立任务，要单独离线测量）；S1-T 暴露的七件事。仍然不做的各项同前几份交接。

**环境（交接时）**：本线没有在跑的节点、tmux 会话、mix 进程。本线容器只有 `npc-s1g-hindsight-20261113`（`127.0.0.1:18933`，在跑）；临时测试库容器 `npc-s1y-pg-20261114` 与它的匿名卷已按名字删除，容器 / 卷数回到 37 / 19。
跑需要 PostgreSQL 的测试要自己再起一个本线命名的临时库（做法见下面“环境”一条与 `s1y/r3-fix/run.sh`；**测试库每次运行换新库名**）。Hindsight 里本线的 bank 与上一份交接相同（探针库已删）。
生产已切到 `20261112-qinglan`（ex master `29531ea4`，协议 44，不含本分支，生产 NPC `enabled=0`）；本分支推送前要对着新的 master rebase、核对 CI 并向用户确认。

### 交接（2026-11-15，第十四个统筹会话 → 第十五个，因上下文接近 250k）——接手先读这一节；第十四个会话的明细在下面“第十四个统筹会话的进展”；任务书 `.demo/observe/npc-slice1-20261112/handoff-15-brief.md`

**一句话**：S1-R7 实跑、独立重算、判定都已完成，用户定反思 R1–R4b **已验收**。之后的三轮离线对照（S1-R7b / R7c / R7d）把薄片一的行为问题归到一处结构缺口：**“打算”没有持有者和完成状态**。用户已认可这一判断（“不是结构的问题就后期再优化”）。日计划层的决策稿写完了，用户四项都定了（`2026-11-14-npc-day-plan-decision.md`“用户的决定”），**还没开工**。

**交接时的现场**：工作区干净，分支未推送（master..HEAD 约 130 个提交；master 已前移到 `29531ea4`）。没有在跑的节点、tmux、转发、补料进程，容器 / 卷 37 / 19，本线容器只有常驻的 `npc-s1g-hindsight-20261113`。Hindsight 本线 bank 都不删（新增 `npc-life-1689289494529`、`npc-reflect-1689289494529`）。

**工作纪律（用户 2026-11-15 同意；起因：第十四个会话在一句收尾句的措辞上连做三轮离线对照，没有回头查是不是缺了一层，最后由用户叫停）**
1. 离线测量只为一个结构决定服务：开跑前写明读数会让哪个决定往哪边走；回答不了这个问题的测量不跑。
2. 行为调优（写法、取值、“某场景选不选某项”）放到各层都接上之后；搭层阶段一律记为后期。
3. 同一个问题连着两轮离线读数都没导向结构决定，就停下来报用户，不开第三轮。

**下一步（按此顺序）**
1. **日计划层**（决策稿 §4–§7 与“用户的决定”）：
   ① 先按决策稿 §6 第 1 步写规划提示词与检查的离线测量计划（输入用 R7 的真实材料，经反思取材料的同一路径；期望先写、开跑前告知用量）。这一轮只回答“规划 LLM 能不能用我们的词表写出合规意图、`cannot_yet` 占多少”，不调措辞。
   ② 拆实现：Life 持久行 `"plan"` 键（照 `"reflection"` 先例：初值、加载 `put_new` 补旧行）；按 Outcome 计数、标 `done` / `missed`（只由代码改）；`cannot_yet`；分日用 WorldTime；额度（规划 + 重排每游戏日共 5 次）计数进持久行；规划用独立 worker 槽；Mind 渲染 `Plans and promises` 栏（英文，不点名该选什么）；`DayPlan` / `LlmBudget` 重写或删除。每步先测后本地提交，动了共享契约就跑 npc_server 全套，重要实现派不带结论的独立评审。
   ③ 计划栏对选择的作用做一轮离线对照（真实 state + 规划 LLM 写出的计划栏），再闭环实跑。`What I have come to think` 先与计划栏并存。
2. **“对某人说话”**（日计划之后）：先查证已有做法（AGENTS.md §2.2 第 8 条），再写决策稿报用户。边界已定：技能一级、组合归规划 LLM、Jev 只在封闭候选里选（内容规范 §10.11）。
3. 顺手修三处文档与代码的不一致（数据流图子会话查出的，见“第十四个统筹会话的进展”末条）。
4. 后期优化（不在搭层阶段做）：收尾句写法、背包原始数字进日记、采石 / 采石灰石分票、Corvin 删减测量的继续（嫌疑是 `What just happened` 那条与之后那轮的收尾句）、观察脚本新版还没在真实节点上跑过（下次实跑顺带验）、A5 第 ③ 段队列抽样下次实跑顺带补。
5. 推送前：对着 master `29531ea4` rebase、核对 CI、向用户确认。部署前补三组 NPC 环境变量（须先问用户）。

**用户这一个会话里定的事**：S1-R7 记已验收（A5 缺项注明为执行遗漏）；S1-R7b 之后选“先离线重测新收尾规则”；S1-R7c 之后选“先放下，做排队的其他项”（收尾规则维持现状）；S1-R7d 之后选“先写决策稿”；“不是结构的问题就后期再优化”；日计划决策稿四项都选建议项；上面三条工作纪律；“你自己开新会话”。

### 整体审查与方向重置（2026-11-16，用户要求“跳出细节、优先验证结构和概念，取值后面再调”）——之后的工作以本节为准

**按总纲薄片的进度**：薄片一已验收；薄片二前半（内容与召回、反思 R1–R4b）已验收；薄片二后半的**日计划结构已通**（S1-R10 P1–P7：规划 → 计划栏 → 选择 → 完成记账 → 重排 → 跨日，真实服务端闭环）；**说话**、薄片三的**步骤边界打断**、薄片四的**多 NPC** 未开始；游戏钟服务端 ×24 已改，客户端资产待用户重跑。
**S1-R10 的结构结论只有三条**：① 日计划层链路通；② 基础设施问题：Hindsight 召回被同一 httpc 连接上的同步写入堵住，选择 / 规划 / 反思三路同时受影响（E1 证实，修法小）；③ 概念问题：计划只是 state 里的一栏，实跑拉动很弱（open 意图活动 17.5%、守屋 76%）——**用户定：先保持一栏，记为后期**。
**用户定的先后**：修召回（T8）→ 说话 → 打断 → 多 NPC。日计划不单独补验收实跑，并进说话那一层的闭环实跑一起看链路。
**工作方式（替换此前偏细的做法）**：
1. 每一层只验“链路接上没有、概念成不成立”，期望写成少量是非题；取值门槛（耗时、占比、兑现率、措辞）一律不进验收，等各层接上之后统一调。
2. 小的结构修复直接“先测后改 → 独立评审 → 提交”，不另写决策稿、不另做实验；新层（说话、打断）照旧先写短决策稿，但只定结构与边界。
3. 统筹会话不再为单个现象开多轮调查；同一现象若不改变结构决定，记后期。
4. 本节之前已记“后期”的条目（时限太短、守屋偏多、完成后重写同一意图、`cannot_yet` 为空、过时限才完成不计数、措辞类）照旧后期，不再测。

### P0 结构修复与选择层换模型（2026-11-17，用户要求“把这个模块拉回正确轨道”）——四项与它们的状态以本节为准

独立评审（架构 / LLM 集成 / 测试三份只读审查）的结论是：单 NPC 的设计纪律与可解释性已经很好，但从 1 个到 MMO 的三道门槛一道都还没过——基础设施缺陷只写了稿、集成层长期没上 CI、表达层被静态配置钉死。据此定 P0 四项，**都已实现**（提交 `0c64e154` 与本次）：

1. **集成**：分支 rebase 到 master `29531ea4`（144 提交）；master 的 CI 占位修复随 rebase 回来，全套 `mix test --no-start` **586 通过 / 18 排除**（rebase 前同一份代码在本分支 6 失败）。本机 WSL 缺 OTP 29 且无 sudo，改为自建与 CI 同款工具链（OTP 29.1.2 + Elixir 1.20.5 + Rust；脚本在 `.demo/dev-env/`，不进仓库）+ 专用测试库容器 `npc-dev-pg-20261117`（55480）。
2. **召回隔离 T8**（决策稿 D-1 + D-3a）：见 [`2026-11-16-npc-hindsight-recall-isolation-decision.md`](2026-11-16-npc-hindsight-recall-isolation-decision.md) 的“进度”一节。T-1 用例改前红（召回排在慢 retain 后面、250 ms 超时）/改后绿（另一条连接、亚秒返回）。
3. **记忆闭环活性**：`job_error` 原来是单向闩锁——一次 Hindsight 抖动就让该 NPC 在本进程生命周期里永久停写记忆且无告警。改为有界指数退避（30 s 起、翻倍、5 min 上限、按 cid 稳定的 0.75–1.25 抖动），`observe` 增 `job_failures` / `job_retry_in_ms`；待写片段上限 8（丢最旧并记 `npc_memory_fragments_trimmed`），心智快照 “What just happened” 只列最近 40 条 —— 行不会在 Hindsight 长期不可用时无界变大。
4. **崩溃域**：`BodySupervisor` 显式 60 次 / 10 s；`claim` 超时不再打死 Body（折成失败走已有 1 秒重试）；世界调用超时且 Player 还活着时回 `{:error, :world_timeout}` 给 Brain，而不是让 Body 退出。
5. **选择层 LLM**：`NpcServer.Jev` 增加 OpenAI 兼容入口（`endpoint.api: :openai`），由 `NPC_JEV_API=openai` + `NPC_JEV_URL/_KEY/_MODEL/_EFFORT` 选；本机 deepseek（`deepseek-flash`，显示名 "DeepSeek V4.1 Flash"，缺省强度 `medium`）就走这条。**只有选择位置用它**，中断与 harm 仍只支持 `:answers`。适配器形状已有单测（请求体、system 契约、宽容 JSON 解析、置信度夹取、`Selector` 的 `unknown_activity`）。
   **未验**：真实 deepseek 端点一次都没打过（本机没有可用的平台 API key；DSH 账号的设备凭证不能当 API key 用）——键进 `D:\hemifuture\ex_mmo_cluster\.env`（gitignored）后补一次 live 冒烟。**另外**：DSH 自带的 deepseek 模型目录把 reasoning 档位只映射 `high` / `max`，`medium` 是否会被告知/忽略要那次冒烟才知。
6. **本次顺带发现的既有问题（未改，等定）**：
   - **第一次选择常常先于 Life 的缓存就绪**：树在 claim 后的第一帧就发 `choose_activity`，而 Life 的 `models` 槽还要一次 HTTP
     往返；输掉竞态时这次选择以 `{:mind_unavailable, {:life_models_unavailable, nil}}` 失败，树等 10 秒再问。
     本地单跑 `npc_registry_test.exs` 能稳定复现（全套一起跑时负载让 Life 抢先，因此 CI 上是绿的）。
     两种修法都涉及产品口径：① 选择侧把"Life 还没就绪"当成"稍等"而不是"失败"；② Life 就绪前树不发问。
   - 同一处的次生问题：`Body.observe` 的 `select.activities` 因此可能出现 `trigger: "retry"` 而不是 `"start"`，
     `npc_registry_test` 的既有断言默认第一次就成功，属实现细节被写死（本次没有改它）。
7. **独立评审（2026-11-17，只看 `53daf995..HEAD` 的 diff）的结论与处理**：
   - **阻断项 1（已改）**：`{:error, :world_timeout}` 原来谁都不重试——`Brain.Tree.transient/0` 不含它（那是驱动
     `act retry:` 原样重发的集合，超时的写意图**可能已提交**，不能放进去），而文档却写"交给 Brain 的重试策略"。
     处理：`Trees.settler` 的工地整体重来（重算缺额、不重发旧命令）把它算作瞬态；`Trees.npc` 让这次活动失败、下一轮
     照常发问；`Body.session_call/4` 与 README 的措辞改成与实现一致（新增 §“崩溃域”那一节的理由也写在这里）。
   - **阻断项 2（已改）**：`claim_session/2` 的 catch 原来收所有退出，与注释相反。收窄成只折"可重试的退出"
     （`:timeout` / `:noproc` / `:shutdown`，含 `{原因, {GenServer, :call, …}}` 形状），其它照旧上抛。
     同时补了这条崩溃域的用例：新增 `npc_body_crash_domain_test`（claim 超时 → 记 `npc_claim_failed`、1 秒后重试、
     就位后照常工作；Body 是 `restart: :temporary`，所以"活着"是真钉住的），`npc_application_test` 另从监督树状态
     直接断言 `BodySupervisor` 的 60 / 10 s。
   - **应改项（已改）**：`Player.running?/1` 的 erpc 错误原来会逃出 `catch` 打死执行进程（现在包成"判不出活"）；
     退避在抖动之后**再夹一次** 5 分钟上限（原来最长 375 s，与注释不符）；任务成功即清零连续失败（不再受落库失败
     影响）；片段上限的告警加 `in_flight` 与累计丢弃，`observe` 增 `dropped_fragments` / `dropped_episodes`；
     `npc_claim_failed` 的 `inspect` 截断（7×24 下每次一行、原来可能很长）；`NPC_JEV_API` 写了认不出的值改为明确拒绝
     （原来静默退回 TypeSafe）；`:openai` 入口的 `max_tokens` 缺省 2048（带思考档位的模型会先花思考预算，512 会把正文
     挤空）、选定 openai 时打一行 `npc_jev_endpoint`。
   - **评审建议但本次不改**：召回 profile 与后台召回共用（见召回隔离决策稿“进度”的收口条，D-1b 升为硬前置）；
     选择链路没有应用级 watchdog；`npc_registry_test` 的首问竞态（见上条）；D-3a 用例没有钉住"Task 不再设超时"
     （只能靠 10 s 以上的慢路，代价太大）。
   - **改前红已验**：① 召回隔离——把 `recall/3` 的 profile 换回 nil，T-1 立刻红（召回排在慢 retain 后面、250 ms 超时）；
     ② claim 超时——把 `claim_session/2` 的 catch 换回"一律上抛"，`npc_body_crash_domain_test` 立刻红（Body 消失、
     没有第二次 claim）。两者都在这次会话里实跑过红→绿。
   - **CI 现状（这次 PR 的实测）**：`Test npc_server` 连续四次 **pass**（8m54s / 9m58s / 10m19s / 9m16s）、
     `Format` 与 `Compile` pass、其余 app pass。两个既有 flake 各归位：
     ① `Test voxel_region` 的 `MagicSemblanceWorldTest`「冷重启…」在 CI 上两次红、单跑该文件绿、本机跑整套时
     红的是另一个用例（`WorldInteractionsTest` 的 DB 连接池耗尽）；且该作业在 master 历史上（2026-11-08…11-13
     的 8 次里 7 次红）本来就是红的。本分支对 `apps/voxel_region` 只动过 `interactions.ex` 的 `capture/5` 与
     `settle/2`（NPC 事件描述与 `instance_removed`），**是否为诱因未证明**，留给 voxel 线查；它最后一次
     run 自己通过了（13m0s），所以这是 flake 而不是本分支的破坏。
     ② `npc_body_world_test` 的「cancelling a skill preserves an already committed World transaction」在 CI 上
     把 `{:DOWN, …, :shutdown}` 翻成 `:noproc`（技能 worker 在测试设 monitor 之前就已经退出）。已按语义收口：
     两种原因都接受（都表示"报终态时它已不在跑"），取消本身的语义仍由 `:cancelled` 与已提交事务断言。
     ③ `npc_hindsight_test` 的「operation deadline bounds an in-flight poll request」在 CI 上偶发：`Task.yield(task, 100)`
     返回 nil。替身原来 200 ms 答、窗口 100 ms，负载一高就顶掉；改成替身 1 s 答、窗口 900 ms，仍是"截止 10 ms
     远早于服务端回答"，但不再赌调度延迟。
   - **最终一次 run 全绿**：`44165163094` 的 13 个 job 全部 pass（`npc_server` 9m25s、`voxel_region` 15m9s、
     `CI result` 绿）。此前 `44157294404` 也全绿过一次。PR 仍在 draft（是否合并由用户定）。
   - **数到的 flake 与处理**：6 次 `npc_server` 作业里 4 次绿、2 次红，两次红分别是上面 ② 与 ③ 两个**既有**
     用例的时序假设（都与本次改动无关），两个都已按语义收口——这是"20k 行测试第一次真正上 CI"必然要付的账。
8. **deepseek 接入的当前状态（2026-11-17，第三轮）**：
   - 代码/配置/测试都完成：`NpcServer.Jev` 的 `:openai` 入口、`Registry` 的 `NPC_JEV_*` 选择、单测（请求形状、
     宽容解析、置信度夹取、截断与拒绝形状、`Selector.ask` 的 `unknown_activity`）、端到端用例（`NPC_JEV_API=openai`
     + 真实 Body + 真实 HTTP 替身，走到东边哨位）。
   - **口径已按 DeepSeek 官方文档校准**：端点 `POST https://api.deepseek.com/chat/completions`；模型 id
     `deepseek-flash`（显示名 "DeepSeek-V4.1-Flash"）；`max_tokens` 是"思考 + 正文"的总量（思考模式缺省 64K），
     我们用 8192 并在 `finish_reason: "length"` 时报 `{:truncated, "length"}`；**思考强度的官方映射是
     `medium → high`，而默认档位就是 high**——所以用户要的 `medium` 合法但等于不指定，要更少思考得写 `low`
     （依据：DeepSeek《思考模式》的 effort 映射表与 Chat Completions 参考）。
   - **live 冒烟本身已验证**：`.demo/dev-env/jev_stub.exs`（最小 chat completions 端点）+ `run-live-smoke.sh`
     跑通了一次，打印 `model=deepseek-flash effort=medium picked=build_hut finish_reason="stop" has_reasoning=true usage=…`。
     所以剩下的只是"真实端点"这一件事，不是"冒烟脚本能不能跑"。
   - **阻塞**：本机没有可用的 DeepSeek 平台 API key（`ex_mmo_cluster\.env` 里那个 `sk-` 是 magpie 路由 key，
     打 api.deepseek.com 是 401；DSH 的账号设备凭证同样 401）。补法：把 `NPC_JEV_API=openai`、`NPC_JEV_URL`、
     `NPC_JEV_MODEL=deepseek-flash`、`NPC_JEV_EFFORT=medium`、`NPC_JEV_KEY` 五行写进 `ex_mmo_cluster\.env`，
     然后 `cd apps/npc_server && mix test --only live_jev_openai test/npc_server/npc_jev_test.exs`。
9. 下一步（未做，顺序即优先级）：上面那次 live 冒烟（缺 key）→ 说话层（先做“候选生成缝：操作 × 眼下可行对象”，说话是第一个实例；**不要**再加一条手写 activity）→ 打断 → 多 NPC 之前的规模治理（World 抽样共享、全链 jitter、成本记账、召回分档）。

### 运行时复核与后续验收（2026-11-17）

用户确认按复核结论继续。基线是 `9fd0055b`。单 NPC 的人格、经历和工作已经能连成闭环。S1-R10 跨日实跑的 121 份选择输入都带上了正确的计划栏，采纳的 11 项意图完成 8 项。无人时与未完成意图相符的活动占 17.5%，首次采用后无人时守屋占 76.1%。这些读数描述当次场景；断线恢复和漏采仍按原判保留。旧 `life` 的双端聊天证据见[对话验收](2026-10-11-npc-dialogue.md)，统一 `npc` 的主动发言要从本轮候选、权威提交到双端显示重新对账。

先用最小回归钉住三条已定位的故障：

- **所见时效。** 会话失去观察后，旧帧的坐标仍能让新施工变成 NPC 的亲历。沿用 Sight 的观察中断边界，建造与拆除的所见要有对该时段有效的位置。测试推进受控时钟，覆盖旧位置附近的施工与恢复观察后的新施工。按 ROS [tf2 的时刻查询](https://github.com/ros2/geometry2/blob/rolling/tf2/src/cache.cpp)区分事件时间和位置证据的时间；这里沿用既有短时观察窗，保留近邻估计。
- **交互游标恢复。** 已登记居民的游标落在 World 的 512 条保留窗口之外后，Life 持续重读旧游标。显式记录缺口并恢复可读取的后缀，保留同一世界的已存经历，交互源身份不一致或无效游标仍诊断为错误。参照 Kafka [消费游标重定位](https://kafka.apache.org/35/javadoc/org/apache/kafka/clients/consumer/KafkaConsumer.html)的 earliest 政策，World 的严格读取继续覆盖其他消费者。测试从真实 World 事务产生历史，检查缺口后冷启动、恢复后的持久游标与后续新事件。
- **活动提交。** Life 第一次写盘报错时遗失整条活动经历和日计划记账。失败期间只保留这一项完成输入，沿现有选择与持久化边界继续提交。经历与计划变化同写一行，确认后才能用该心智开启下一轮选择。参考 Azure [事件消费的顺序和幂等性](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing)；复用现有单 owner 和行级保存，恢复测试让真实存储的首次提交返回一次诊断性错误，再查经历条数、原时刻和计划进度。

下一段玩家场景聚焦**主动对眼前的人说话**。让玩家经真实操作拆屋、离开、回来，核对本轮可行候选、选择的目标、台词、权威发言的范围和双端显示，同时读回对应经历与计划。完成后按既定次序验证步骤边界打断，再让 3–5 张人格卡共同运行。多人采样前处理交互与后台召回共用连接资源的问题，记录本机 UDP 基线、并发、总时长与清理。短场景以产品动作和结构化结果判定，话术、守屋偏多及计划拉动力留到各层接通后再调。

#### 主动开口的决策与最小场景

- 统一 `npc` 登记说话技能。每轮从身体的当前观察里按角色身份稳定排序，向选择器提供“说话 × 附近有位置的角色”。现有候选照常参与。生成项用 `speak_to:<角色 ID>` 作为名字，遇同名登记项时避让。只在有附近对象时与 Scene 当前能听到新话题的同场成员取交集，冷却中省去这类选项。Jev 只返回已列出的选项，执行携带当轮冻结的目标及角色代次。参照 Epic [Smart Objects 的运行时空间查询与交互执行边界](https://dev.epicgames.com/documentation/en-us/unreal-engine/smart-objects-in-unreal-engine---overview)，这里对象是 Scene 在场角色，Scene 保有最后裁决。
- `speak` 先走近当轮选中的目标，用规划与反思所用的写作服务读同一份心智快照、写一句定向台词，最后经现有 `say` 提交。Scene 在接纳当刻核对目标的 ID、代次和范围，按现行可靠 Speech 广播；NPC 从权威回声保存自己的发言。CLI 查 `Body.observe` 的选择、目标及终态，Scene/Gate 的结构化日志与客户端 `Voxim.Dialogue.Status` 对账。当前写作只负责这一句，计划栏继续使用已登记活动。
- 最小集成先让真实 World、Scene、Body 运行，按现有测试形状替换模型接口。验证合法在场对象才进入本轮，选择后只向同一代次发言，失效与拒绝可从终态判定，真实发言可读回。UE 验收使用两位真实登录的玩家与一个居民，先核对 Ready、站位与版本，再让居民发起第一句。按计划核对目标、旁听者、消息身份和 HUD；拆屋与跨日恢复使用单独有完整前提的场景。

实现与测试进度。三条记忆故障的改前、改后证据保存在本地 `.demo/dev-env/logs/`。World 操作历史测试 6 项通过（`test-voxel_region-20261118T023106Z.log`），Scene 对话与在场资格 12 项通过（`test-scene_server-20261118T021827Z.log`）。NPC 全套首轮 600/607 通过，定位到旧回调夹具、启动时 AOI 到达顺序和缺代次的观察；修正后按失败清单重跑 7 项全通过（`test-20261118T023329Z.log`）。提交 `362fef94` 用 WSL 新库完整复跑，607 项通过、19 项排除（`test-20261118T025049Z.log`）。主动开口的服务端集成覆盖附近候选、权威发言、旁听、冷却及持久回声；双 UE 场景独立取证。

双 UE 短场景用提交 `362fef94` 构建的 WSL 原生 release、Hello 44、私有 PostgreSQL 和本机模型替身。首轮发现地图将 `LogVoxim` 压低，旧回放门漏读了已成功的登录。第二轮两端到达站位后发现驱动未把 Scene 的状态结构投影成 JSON。用当前 release 的真实结构和此前日志完成离线回归后，`short-03` 实际注册统一 NPC 临溪。玩家没有先发话，NPC 在两人同时可选时主动对 A 说话。A、旁听 B 与 NPC 自己收到同一会话 `3431057279571177255` 的第 1 句，两张 HUD 截图已逐张查看。PostgreSQL 读回带同一会话与目标的经历；首份日计划为空意图，已经落盘。

原始场景总判定为红，原因是发言之后反思写作调用遇到模型替身未实现的自省请求，返回 422（`release.log` 的 `npc_reflect`）。保留 `failed.json`，`player-chain-review.json` 独立对账主动发言证据，`visual-review.json` 记录双图核对。拆屋后基于经历开口、真实模型的台词质量及跨日恢复是另有前提的场景。运行脚本与证据在 `.demo/observe/npc-active-speech-20261117/`，实际场景在其 `runs/short-03/`。该轮 Windows UDP 为 83 → 92 → 87，4266 记录号未变，客户端、release 与私有库均已回收。

#### 步骤边界暂停

首例用正在采多格石料的居民。收到玩家经 Scene 发出的定向来话时，Runtime 等本次已经放行的 Body 步骤返回权威终态，暂缓下一步。Jev 在共享心智和这条来话下选继续或回复，回复沿原会话发出。回复结束后，原 Gather worker 从同一次调用的下一步继续，保留原采集进度。现有立即取消和结算继续服务它原有的场景。参照 [Epic 的事件驱动观察](https://dev.epicgames.com/documentation/en-us/unreal-engine/behavior-tree-in-unreal-engine---overview)、[BehaviorTree.CPP 的步间让出控制](https://behaviortree.dev/docs/nodes-library/SequenceNode/) 与 [Erlang 的信号顺序](https://www.erlang.org/doc/system/ref_man_processes.html#delivery-of-signals)。一处 Runtime 步骤入口串行决定何时发下一步，Body 和 World 继续裁决各步的结果。

可观测证据串起 Scene 的来话 `conversation_id/turn`、技能调用号、已结算步号、回复终态及恢复后的下一步号。真实 World 与 Scene 组件下的 `gather_reply` 改前未发起回复选择，改后使用原会话回复、继续同一次 Gather；`gather_step_matching` 覆盖在途号不匹配时保留正确待结算项。证据分别见 `.demo/dev-env/logs/test-20261118T040605Z.log`、`041002Z`、`041204Z`。

同提交 `729bb6b8` 的 `step-02` 双 Voxim 短场景原判通过。A 以正常游戏锁定与对话框向采石居民提问，A 与旁听 B 收到会话 `750626626442707426` 的第 2 句。原 Gather 调用 6 在步 16 后等待第 17 步，回复经 Scene 接纳后继续第 17 步。World 采集事务 8 在回复前，15、22、29 在回复后，原活动累计四格材料，PostgreSQL 读回回复经历。实机来话恰在两步之间，在途的错号情况由上述 Runtime 回归验证。首轮 `step-01` 的 B 精确放置被 `find_spawn` 拒绝，修正驱动走同版已实测的正常步行路线。双图已逐张核对，UDP 89 → 93 → 87，4266 记录号未变，独占资源均回收。命令与本地证据见 `.demo/observe/npc-gather-reply-20261117/README.md`。

**首个实现的契约。** 统一居民的顶层 `gather` 将它本来逐个等待的原子步骤交给 Runtime 准入。Runtime 在同一邮箱登记 Scene 已投递的玩家直呼，且只接纳当前调用和当前步号的 Body 终态。已有一步结束之后，Gather 下一次投步时暂缓准入。只有一条待处理来话；未开始新一步前不会累积后续来话。旁听、其他 NPC 的发言和自身回声仍进入原有记忆路径。Jev 复用活动选择的心智和封闭候选，再用现有写作端点撰写短回复。Runtime 在 Scene 权威发言返回后才放行下一步，Gather 保留原 worker、初始余额与活动号。端点失败、超时、选择继续、会话拒绝发言分别记录可诊断结果；失败的回复不会自动重发。已执行的原子动作继续由 Body 结算；取消和会话丢失清理本轮回复。使用步骤的请求与终态相关联，Erlang 的发送顺序只对同一发送者与接收者成立，因此不依赖 Scene、Body 和模型 worker 三者之间的消息顺序。

- `Body.observe` 的 `skill_boundary` 投影当前步号、最近结算步号、暂扣步号和来话身份。结构化 `npc_skill_boundary` 日志串起等待结算、暂停、回复、恢复的同一调用，继续使用 Scene 的权威消息编号和 World 的事务编号。
- 最小回归经真实 Registry、Scene/Player、World、Body、Gather 与 Life，独占测试数据和两块由作者入口安装的石料，HTTP 服务用回环替身。真实玩家角色走正常 claim、Ready 与 Scene.say，在第一格余额到账之后发起直呼。用受控模型回执验证下一步暂停、原会话只回复一次、第二格到账、原调用结束。用同步的 Runtime 入出事件验证只推进匹配的步骤；此测试不启动 QUIC 和 Voxim。
- Linux 命令 `cd apps/npc_server && mix test --no-start test/npc_server/npc_registry_test.exs`。真实客户端场景另用正式 release，按同一命令号、会话身份、角色和事务对账。记录 commit、运行器、日志及退出码。

#### 统一 NPC 的首问与未落盘输入

- 首问由发问 worker 等 Life 初次可读的一份持久心智，召回查询与快照从同一行构造。冷启动最多等一次有截止的应答；World、存储或模型初次读取失败显式结束等待。用受控认识读取卡在首次观察之前，断言启动中没有拒绝，并在释放后触发原选择。CLI 继续能直接观察当前加载错误。参照 [OTP GenServer 的延迟回复](https://www.erlang.org/doc/system/gen_server_concepts.html)。
- 发言与情绪评价两路未落盘输入各保留最近 40 条，按收到次序处理。长时间落库失败时记录淘汰量与最近一次错误；恢复后仍按原顺序落下保留的输入。40 与当前短期心智最多给出的经历条数一致，给每条路径一个固定内存预算。范围是 Life 收到并尚未保存的输入。思路参考 [Akka 有界邮箱的显式溢出](https://doc.akka.io/api/akka-core/2.10.15/akka/dispatch/NonBlockingBoundedMailbox.html)。用存储替身拒写一段有界输入，再恢复并核对保留下来的权威消息与评价来源。

#### 拆屋返场的因果场景与候选资格

`causal-stub-02` 用真双端目击 NPC 先从零余额采料建屋，再经 A 的真实准星与 V 拆除同一实例。World txn 42 的 actor 为该玩家，Life 写入同一篇经历。A 同一会话出入听距，离场回合仅 B 可选，返场回合含 A/B，受控选择才允许追问 A。两端确实收到同一追问。场景原判红于取证器只查 PostgreSQL 待归档数据，而发言已封片并成功归档。修正后同时核对精确 bank、文档和成功读回及 PG 水位，旧失败和未放行的视觉证据均保留。

`causal-real-01` 在同样权限和动作链中使用一次实际 Jev。请求含强烈愤怒和对本轮 A 的不信任，认得的小屋已毁，A、B 都进入候选。Jev 选 `guard_hut`（0.45），定向问 A 为 0.28，问 B 为 0.03，写作未调用。样本保留为真实行为未达标。驱动离线纠正把合法不同选项误报成 422 的做法。

真实请求同时给出了“小屋已毁”和“站在这间小屋旁守护”。地点型登记可用非空发布名 `requires_building` 表明这一活动需要建筑仍在。选择方使用本轮 `Life.mind` 已取得的自有建筑权威读回，只有至少一座同名建筑 `standing=true` 时这项地点活动参加即时选择。保留登记次序和旧活动、过去经历、长期计划的原词表；若本轮最终候选全空，显式返回 `:no_feasible_activity`。Garen 场景的守屋增加条件，并有单独的在地块等待活动。参照 [Epic Smart Objects 的当前活动资格查询](https://dev.epicgames.com/documentation/en-us/unreal-engine/smart-objects-in-unreal-engine---overview)，这里由现有 World/Life 读取完成条件判断。测试从正常放置与拆除产生状态，验证有屋可选、拆后移除以及空集合。

`causal-writer-01` 保留真实双端拆除与返场、受控选择、只调用一次真实 Claude 写作。两端 HUD 确认可读，发言已确认归档。语义原判保留失败：台词认对本轮拆除者，却声称亲眼目击，发言结尾也没有追问动机。生产写作契约允许按已记录事实说事，亲眼所见须有显式观察证据，涉及具体事件但动机未知时用角色口吻询问。这与 [Anthropic 的依据源材料和保留不确定性](https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/reduce-hallucinations) 一致，在本项目区分 World 裁决与 Sight 亲历。回归验证实际 HTTP 写作请求包含约束且沿用冻结心智；真实模型遵循新指令的效果仍须另一个模型样本。

上述原始场景、清理与使用真版本记录的反例在 `.demo/observe/npc-causal-speech-20261117/`。驱动修复了无客户端前置漏装 RPC wrapper、把瞄准点当最终停点、漏收已归档发言、把合法选择误报成 HTTP 失败。改前记录按原样保留，改后使用真实日志和包括身份错配、仍在听距、归档缺凭证等离线反例验证；最终 `causal-writer-01` 的严格运行判定绿、语义复核红。实际台词、语义复核和截图分别在该轮日志、`semantic-review.json` 和 `a/hud.png`、`b/hud.png`，本轮总计一次真选择和一次真写作。

建筑资格与写作约束共四项定向用例改前全红、改后全绿，分别见 `.demo/dev-env/logs/test-20261118T050222Z.log` 和 `test-20261118T050449Z.log`。新旧场景判定与驱动测试共 16 项离线通过。

2026-11-18 UTC 用 `28db99dd` 扩大复验。`recheck_models.py` 从 `causal-real-01` 和 `causal-writer-01` 取两份真实返场快照，保留同一份心智，按本轮登记将确定失效的守屋项换成 `watch_plot`，写作使用当前 `Speak` 的提示词。两份真实 Jev 回执均选择了 `watch_plot`，两条真实 Claude 台词都准确追问了拆屋原因，也保留了目击证据边界。两份样本的请求、原始回执和语义判定见 `.demo/observe/npc-causal-speech-20261117/model-recheck-real-20261118/`。

`causal-real-02` 用同版服务端和 Hello 44 双客户端实跑。双端确认 World txn 42 移除同一小屋，Life 经历保留同一事务与拆除者。A 同一会话从 NPC 的 17.165 m 外返回到 5.307 m。离场时只保留旁听 B，返场时 A/B 都可选，旧守屋项已消失。一次真实 Jev 返回 `watch_plot` 权重 0.46，追问 A 权重 0.37。实跑按 `desired_choice_not_met` 结束，该轮未触发 Writer，原失败记录和离线复算在 `runs/causal-real-02/{failed,selection-recheck}.json`。UDP 86 → 91 → 90，4266 记录号未变，双 UE、release 和私有库均已回收。

`causal-writer-03` 在独占的新双端会话中用受控选择发起同一类追问，随后调用一次真实 Writer，保留生产请求的 `max_tokens`。台词准确询问为什么拆自己的小屋，并以记录的拆除事实为依据。A、B、NPC 自己收到同一权威发言 `695208712436984313:1`，Hindsight 回读同一记忆，两张 HUD 已逐张核对。正式日志记录 3736 输入和 182 输出 token，同供应商回执对账通过。该轮 UDP 87 → 94 → 85，4266 记录号未变，所有本轮资源已回收。前一份 `causal-writer-02` 在固定端口暂占时于准备阶段停止，验证端口可绑定后换新目录补跑。证据见 `runs/causal-writer-03/{verdict,speech-memory-proof,visual-review,semantic-review,cleanup}.json`。合计真实 Jev 3 次、真实 Writer 3 次，写作语义与独立双端写作场景通过，自主选择追问的行为仍未达标。

#### 对话通道异步化（2026-11-18，取代上面“步骤边界暂停”的做法）

用户 2026-11-18 定：聊天与当前活动异步，“边聊边干，除非聊的时候决定停下”；停不停由 Jev 在封闭候选里先定，写作模型只写台词。
决策稿 [`2026-11-18-npc-dialogue-lane-decision.md`](2026-11-18-npc-dialogue-lane-decision.md)。已实现：Runtime 的对话回合与技能正交，
候选为 `keep_working_and_answer` / `keep_working_silently` / 本轮可行活动（含来话者的 `speak_to:`，带同一会话号）；
选活动项即预选 + 当前活动记 `interrupted` + `Tree.halt/1`，树从根重来时由预选应答。`step_owner` 步骤准入线整条删除。
全套 623 / 19 排除，T1 改前红、改后绿（日志见决策稿 §8）。双端实机复验并入薄片四之后的场景。

同日用户定模型统一用 DeepSeek（`deepseek-flash` = DeepSeek-V4.1-Flash-1017）：主检出 `.env` 已写 `NPC_JEV_*` 与 `NPC_REFLECT_*`
（同一端点、同一把 key）；Hindsight 容器以同镜像、同卷重建为 `npc-s1g-hindsight-20261118`（`openai` provider → DeepSeek），旧容器只停未删。
写作位置已加 `NPC_REFLECT_API=openai` 入口（Writer 按 `api` 分形状，发送与用量仍走 `ModelUsage.request/4`）。两条真实冒烟各一次请求通过：
选择 2.2 s、205 入 / 99 出；写作一篇日记 10 s、3931 入 / 1042 出（思考 836），均 `finish_reason=stop`（`.demo/dev-env/logs/test-20261118T120413Z-live-deepseek.log`）。
chat 形状单元用例的夹具取自这次真实回执；改前红 `test-20261118T120600Z-writer-openai-red.log`，改后绿 `test-20261118T121000Z-writer-openai-green.log`。薄片四（四张人格卡、真实模型）计划与驱动在本地 `.demo/observe/npc-slice4-20261118/`，用量已由用户确认。

#### 薄片四首轮：四张人格卡、真实 DeepSeek（`slice4-01`，2026-11-18）

release `ea49bd38`（`/home/dyz/npc-slice4-20261118/voxim_server`），四人同一份四项去处候选表，选择与写作走真实 DeepSeek `deepseek-flash`（effort medium = high），
真实 Hindsight。运行前计划与期望在本地 `.demo/observe/npc-slice4-20261118/plan.md`，产物在其 `runs/slice4-01/`。总判定按运行前规则为**不通过**：

- **Q1 链路 成立**：四人各 4–8 次成功选择，全部有权威 travel 与 Life 活动经历。
- **Q2 差别 成立**：同一处境、同一候选表，四张卡的首选各不相同（4 种）；整窗分布也随卡偏移（独处卡 6/8 选 `sit_quietly_apart`，外向卡 5/8 选 `wait_at_the_walkway`）。
- **Q3 用量 不成立（按规则）**：47 次请求，2 次未配对，都是停服前 1.5 s / 7 s 才发出、停服时仍在途的选择，不是记账遗漏；其余全部配对。
- **Q4 隔离 判定器量错**：它把 7 次 `npc_select_failed reason=:timeout` 当成召回超时。实际 `mind_unavailable` / `recall_timeout` 为 0，两人 `retained > 0`，召回隔离未见失败。原判保留，驱动待修。
- **Q5 说话候选 成立**：10 次发问的候选含 `speak_to:`，被选中 3 次，3 次 `speak` done。
- **结构发现：选择延迟**。产品侧 36 次选择里 7 次 10 s 超时、1 次上游 504。代理计时（只含上游）中位 4.3 s、p90 8.1 s、最大 13.7 s，思考 64–1218 token；
  上游超过 10 s 的只有 2 次，其余超时来自测试代理“对外在途 ≤ 3”的排队（代理计时不含排队，下轮要分开记）。总纲按 Jev 估的选择延迟是约 0.6 s，
  DeepSeek 默认开思考（官方：缺省 high；`thinking: {"type": "disabled"}` 可关）使它与 10 s 的选择超时同量级。另有 2 次上游 504（URLError，一次选择、一次反思）。
- 资源：UDP 94 → 97 → 92，Tcpip 4266 记录号未变，release 0.42 s 停，私有库已删，代理无残留连接。
- **用户 2026-11-18 定：选择位置关思考**（写作位置不变）。产品新增可选 `NPC_JEV_THINKING`（`disabled` 发 `"thinking": {"type": "disabled"}`、不发 effort；
  认不出的值登记即拒绝），主检出 `.env` 已写 `disabled`。真实冒烟 3 次：无思考内容，输出 35–49 token，冷连接约 2 s
  （`.demo/dev-env/logs/test-20261118T123934Z-live-jev-nothinking.log`）。下一轮薄片四在新 release 上复跑，驱动同时修 Q4 判定与代理排队计时。
- 驱动修正（Test-only）：Q4 只数 `mind_unavailable.*recall`，选择超时另记；代理分记排队 `wait_ms`，对外在途上限 3 → 8；停服前排空在途模型请求（≤ 30 s）。
  新判定器离线复判 slice4-01：Q4 成立（召回失败 0），原判文件不改（复判存 `runs/slice4-01/recheck-q4-fixed.json`）。

#### 薄片四第二轮：选择关思考（`slice4-02`，2026-11-18，release `6c1bde6d`）

- Q1、Q2、Q5 成立（四人各 5–9 次选择；首选仍四人各不相同；独处卡 8/9 `sit_quietly_apart`、外向卡 7/9 `wait_at_the_walkway`；`speak_to` 被选 3 次）。
- 关思考有效：上游选择中位 2.8 s、p90 5.0 s、最长 7.8 s，输出 42–68 token，代理排队 0。Jev 36 次合计 3.9 万入 / 0.19 万出。
- **结构发现：选择请求排在同一主机的慢请求后面**。产品仍有 5 次选择 10 s 超时，而上游没有一次超过 8 s；产品发起 38 次、代理只收到 36 次。
  5 次超时的时刻都落在同一主机有慢请求在途的时段（三路日计划写作 04:47:56–04:48:08、反思写作 04:48:21–04:48:33、Hindsight 同步写入 5–14 s）。
  模型请求全走 httpc 缺省 profile：测试里选择、写作、Hindsight 都经同一代理端口，生产上选择与写作同在 `api.deepseek.com`，选择请求排进已占用的
  keep-alive 会话、超时时从队列取消而从未发出——与 E1 证实的机制相同（召回隔离 D-1 只把召回移出了缺省 profile）。修法：选择请求独立 profile（同 D-1b）。
- Q3 不成立：1 次未配对，是排空判到 0 之后、停服之前那半秒里新发的选择（驱动竞态）。Q4 不成立：窗口内四人都还没有完成过 retain（前提未达，提前结束过早），
  召回失败 0。资源：UDP 85 → 88 → 88，4266 未变，release 0.59 s 停，私有库已删。

#### 三 NPC 同场与交互／后台召回

D-1b 将交互与后台取材分为两个连接池，启动失败只回收此次创建的池。回环 keep-alive 改前的 250ms 超时以及启动冲突误停已有池都已红绿，4 个相关文件共 38 项绿，见 `.demo/dev-env/logs/test-20261118T040844Z.log`。

提交 `729bb6b8` 的原生 `multi-02` 在同一 Scene 的 5209ms 功能窗口逐个核对砚池、南栖、峪望的选择、权威移动和 PostgreSQL 经历。暖后台连接暂挂时，南栖在释放后台前已发出这轮接续的 Jev 请求。整轮 67 个回环请求、零替身错误、0 UE 与 0 真实模型，UDP 88 → 88 → 80，4266 记录号未变，原生服务、端口和私有库均回收。首轮 `multi-01` 的结束顺序导致替身在 NPC 尚在线时等待持久连接，另有 refresh 路由表缺项；修复真实 refresh 契约、先停 release 再关替身及清理后全 trace 判定。保留首轮总失败和功能窗口原判，`multi-02` 总判及原始证据复判均通过。命令和证据见 `.demo/observe/npc-multi-20261118/README.md`。这个功能窗口记录三人路径与隔离现象。

最后把建筑资格和写作约束纳入 NPC 全套。WSL `mix test --no-start --seed 0` 在新测试库运行完成，616 项通过、19 项排除，见 `.demo/dev-env/logs/test-20261118T050509Z.log`。阶段验证在上面记录的 release 指纹与模型替身范围内。真实模型验证的两份语义原始结果仍按其实际判定。

#### 多人运行的模型用量

本轮先补统一居民的活动选择、采集步间回复选择，以及反思、日计划和主动／回复写作的直接模型用量。`causal-real-01` 的一次选择返回 1976 输入和 102 输出 token；`causal-writer-01` 的写作返回 2 普通输入、3884 缓存写入和 111 输出 token。前者在运行时没有用量记录，后者照旧的技能字段只会看到 2 个输入。三人同场记录还没有 World 轮询成本与队列读数，后续用该场景的真实入口量出重复读取再决定共享边界。

- Jev 选择与 Writer 在共享的模型请求记录处登记开始、结束和上下文。`npc_model_request` 后跟 JSON，可按角色 `cid`、`operation`、`api` 与请求／应答模型归类。一次应用侧请求在同一节点启动期间用 `request_id` 配对，网络应答在业务解析前记用量。HTTP 失败或缺少有效回执时 `usage=null`。结束窗口未配对的请求用量仍未知。事件字段限于请求元数据和计量。日计划槽日志把 Messages 原始输入数标为 `uncached_input_tokens`。
- 按 OpenTelemetry 的 GenAI 请求与 token 用量惯例记录调用与供应商计量，复用 release 日志出口。TypeSafe System One 的输入／输出取同名计数。Chat Completions 的提示与生成计数已含分项，缓存命中单列。Claude Messages 的总输入按普通、缓存读取和缓存写入三项相加。记录供应商返回的 token 数，货币金额需用实际路由账单核对。 [OpenTelemetry](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-metrics.md) · [TypeSafe System One](https://docs.typesafe.ai/api/system-one) · [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/) · [Claude Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- 先在现有 Writer 回环测试里截断真实响应夹具，验证业务拒绝仍记录缓存用量，再查无用量、超时与取消。Registry 测试经正常登记、真实 Life/Body/Scene/World 和独占 PostgreSQL 触发选择、步间回复与后台写作，模型与 Hindsight 使用现有回环替身。核对请求配对、角色和用途、用量及原有权威结果。WSL 从 `apps/npc_server` 运行 `mix test --no-start` 的直接相关文件，日志写本地 `.demo/dev-env/logs/`；本次用量变更由回环 HTTP 和正式服务端入口验证。
- 正式 release 日志验证复用三 NPC 同场短场景。每轮独占 World 与 PostgreSQL，0 UE、1 个本轮 QUIC listener、回环 HTTP 上限 24 个连接和 320 个请求。先核对 Windows 与 WSL UDP 基线，轮内复采，收尾按 release、替身、数据库的顺序清理。登记后窗口上限 45 秒。判定器按三名居民的登记身份对账 TypeSafe 替身的每个选择与 Writer 回执，区分缺用量和供应商明确报告的零。其余模型用量边界由上述定向测试验证。

Writer 改前因缺模型事件失败，见 `.demo/dev-env/logs/test-20261118T060731Z.log`。主动发话、步间回复、OpenAI 选择、Life 后台写作和 Speak 缓存总输入共五项改前红、改后绿，见 `test-20261118T061108Z.log` 与 `test-20261118T061321Z.log`。日计划槽日志旧字段的反例在 `test-20261118T061749Z.log`。WSL 上 `mix test --no-start --seed 0` 选择 `npc_{jev,selector,registry,speak,reflection_writer,reflection_round,life,life_day_plan_integration,life_day_plan_round,dialogue_life}_test.exs` 共 135 项通过、4 项排除，见 `test-20261118T062136Z.log`。

`multi-usage01` 的正式原生 release 同场场景通过，三名居民的 6 次选择和 3 次规划均与回环替身的调用流水一一配对。6 次选择缺少用量，3 次规划明确报告零，收尾时 0 个未配对请求。生产源码摘要与关键 BEAM 指纹在 `server-build.json`。UDP 84 → 90 → 88，Tcpip 4266 记录号未变，原生服务、端口及私有库已回收。命令为 `python -B .demo/observe/npc-multi-20261118/run.py live --run multi-usage01 --release /home/dyz/npc-model-usage-20261118/voxim_server`。在对应 `runs/multi-usage01/` 读 `verdict.json`、`model-usage.json` 和 `release.log`。本轮关注三人路径及用量对账，真实模型行为仍待复验。

### 第十五个统筹会话的进展（2026-11-15 起）——上面第十四 → 第十五交接里“下一步”各项的状态以这里为准

- **日计划层第 1 步（S1-R8，离线，探索性，不是验收）已跑完、已判定**：计划 `.demo/observe/npc-slice1-20261112/s1r8/plan.md`（发问前写）、判定 `results.md`、脚本 `docs/10-active/cross-cutting/tools/jev/s1r8_plan.py`、执行任务书 `exec-brief.md`。R7 的 6 份真实反思材料 × 3 次 = 18 次规划调用（用量实测合计约 12 万 token，开跑前估约 8 万，偏低）。P1、P2、P4、P5 成立；P3 里占比与 A 类成立、**B 类 27% > 15% 落空**（R2 一份材料三次采样都写了“回来路过小屋看一眼”进 `cannot_yet`，读法有争议）。读法：D-1 的意图形状 `{activity, times, by, why}` + `cannot_yet` 站住，进拆实现；`cannot_yet` 里 64% 是“对某人说话”，印证它是下一层。B 类按发问前规则报用户，统筹会话建议记为词表内容问题、后期处理。
- **日计划层实现 T1–T5 已完成并本地提交**（实现设计 `2026-11-15-npc-day-plan-implementation.md`；任务书与日志在本地 `.demo/observe/npc-slice1-20261112/s1r8/impl/`）：`1f2755ed` 纯核心 `Life.DayPlan`、`57fe73c0` 提示词模块 `Life.DayPlan.Prompt`（逐字照 S1-R8，金标测试）、`eb0d034e` Life 接线（持久行 `"plan"`、规划槽、触发、活动记账）、`c8327089` Mind `Plans and promises` 栏 + 删旧 `DayPlan` / `LlmBudget` + README 与三处文档不一致、`5dbf68ef` 独立评审后的修复（规划在途时到来的 event 不再被落栏清掉；起调用就记 `last_at_ms` 并清 `event_waiting`；身体状态没到不触发；不规划的形态不动 plan 行；删一条测不可达分支的用例并补失败路径测试）。评审问题与处理见提交说明；全套 npc_server 575 通过。**只做了离线测量与单测 / 集成测试，没有闭环实跑，不算验收。**
- **S1-R9（计划栏对选择的作用）没有开跑，Jev 请求 0 个**：计划 `s1r9/plan.md` 写错了前提（“基准 state 与规划材料同一时刻”；游戏钟 ×72，两者差游戏 1–6 小时，`by` 多已过），执行子会话在生成栏文本时发现（17 / 23 个样本 `check/3` 报 `by_not_after_now`）。更正在读到任何 Jev 读数之前，期望未动；记录 `s1r9/by-window.md`。
- **新发现（结构问题）：规划模型按游戏钟写的时限在 ×72 下现实里只有几十秒**（S1-R8 的 52 条意图：17 条 ≤ 62 秒、6 条 ≤ 31 秒、中位 125 秒；选择器一轮约 31 秒，估计值）。**用户 2026-11-15 经对话框定：把游戏钟调慢（倍率 ×24，一个昼夜日 = 现实 60 分钟），规划仍按游戏钟写；并授权一并改 Voxim 仓。** 服务端已改（`1431fab1`：`MmoContracts.WorldTime` `rate` 72 → 24、测试手算重写、`Mind.ago` / `Sight.duration` 本来就读 `WorldTime`，文字与测试期望同步；mmo_contracts 192、npc_server 575 通过）。**客户端未生效**：Voxim 的 `HourOfDay` 读 `Params.DayClockMultiplier`，生产值 72 存在 `DA_WeatherClimate.uasset` 与 `DA_WeatherClimate_TestOnly.uasset`（二进制资产），改 `Docs/Weather/tools/weather_assets.py` 里的常量只在经 UE 编辑器重跑该脚本后才写入资产；该步要开编辑器，**待用户定**。Voxim 仓已有未提交的静态改动（脚本常量、`VoxelWeatherTests.cpp` 对账用例手算 ×24、`Docs/Weather.md`、`Docs/Playtest/DayNight.md`），**未提交**；在资产重写之前客户端昼夜仍是 ×72（NPC 说的时辰与屏幕天空对不上，只影响观感）。
- **因倍率变了，S1-R9 不再按原样做**：S1-R7 导出的 state 是 ×72 下产生的（钟点、“多久以前”），不再代表新产品；按方法论（不生造数据）改为：先在 ×24 下做一次带计划栏的**闭环实跑**，再用实跑导出的真实 state 做计划栏的离线对照（`real` 由去掉栏得到，`PD` 由产品状态机推进得到）。每游戏日 5 次规划现在是每现实小时 5 次。已有持久数据的日号会因倍率变化而不连续（开发数据可清空重建，用户 2026-11-13 定）。
- 下一步：闭环实跑的计划与期望（先写、告知用量，用户同意后跑）；Voxim DA 资产重写待用户定；“对某人说话”决策稿随后。
- **用户 2026-11-15 定**：照计划跑 S1-R10；出生空调用先照原样跑、记录；Voxim DA 资产由用户自己开编辑器重跑（之后统筹会话核对资产并提交 Voxim 的静态改动）。
- **S1-R10（日计划层闭环实跑，×24）已跑完、已独立重算、已判定**（本地 `.demo/observe/npc-slice1-20261112/s1r10/`：`plan.md` 运行前定稿、`results.md` 判定、`recalc-report.md` 独立重算；数据流图更新为 `../npc-dataflow-20261115.html`）。登记 2026-11-16 01:00Z，跨一次日界，两次拆屋，一次断开写作接口；清理后 37 / 19，UDP 不因本线增长，额度 0 命中。
  甲组 P1–P7 成立（出生空调用、链路、计划栏逐字 121 / 121、记账、finished / missed 翻转、事件重排、跨日），**P8、P10、P11 落空 → 日计划层未验收**：P8、P10 是转发恢复后约 10 分钟 Hindsight 经历库召回 9–10 秒、撞 10 秒超时，规划两次、反思一轮起不成（同 P12 的老问题 `npc_select_failed`）；P11 是执行遗漏（第 ⑤ 段队列只抽 1 次）。
  结构问题：**额度按起调用计，没问到模型的失败也扣**（8 次调用 4 次未到模型；第 506 天 5 次用完）。乙组：完成率 72.7%，open 意图的拉动弱（17.5%），守屋 76%，对质时限采用后 33 秒就到，`cannot_yet` 全空，完成后重写同一意图——都记后期。**用户 2026-11-16 定（四项都选建议项）**：额度只扣真的发出写作请求的调用（取材失败不扣、隔 3 分钟再试）；有至少一条经历才触发规划；召回超时单独查根因（先调查、查证、再决策稿，不在日计划层加补丁）；本次记未验收，改完额度、召回超时有结论后再闭环实跑补验收。
- 下一步：额度计法与出生触发的实现（任务书 `s1r10/impl/t7-brief.md`，先测后改、独立评审、全套、提交）；召回超时的只读调查（`s1r10/recall-brief.md`）并行。
- **T7 已实现、评审、提交（`fdff7fb4`）**：额度只扣发出了写作请求的调用（`Round.write/1` 返回 `wrote`，写作前失败落栏时 `DayPlan.refund/1`；连接被拒、worker 崩溃、在途重启照扣）；有经历（`pending` / `fragments` 非空或 `retained > 0`）才触发规划。独立评审无正确性 / 契约问题，收尾改了设计稿两处与 `refund` 的不可达分支。日计划三个测试文件 82 / 82；全套 579 / 580（唯一失败 `npc_emotion_movement_test` 缺 `NPC_LLM_URL`，与本改动无关，评审核过）。
- **召回超时调查已回报**（本地 `s1r10/recall-report.md`）：25 次超时里 13 次是**我方** httpc 缺省 profile 的连接内队头阻塞——召回排在同一条 keep-alive 连接上 11–49 秒的同步 retain 后面，retain 结束后 5–7 ms 才到 Hindsight（与 bank 无关）；另 12 次是 01:57–02:02 Hindsight 重排每候选耗时涨 6–8 倍，谁占的 CPU 无证据。“写库时召回被拖慢”的旧读法作废。报告列了 8 个修复方向（主方向：召回独立 httpc profile、retain 改异步），业界做法一节部分凭记忆，写决策稿前要逐条核对原文。
- **用户 2026-11-16 定**：跑实验 E1（本地假服务对比缺省 / 独立 profile，计划 `s1r10/recall/e1-plan.md` 运行前定稿）；下一次闭环实跑附带 CPU 采样，含全部容器的 `docker stats --no-stream`（只读）、WSL 按进程 top、Windows 总 CPU，每 5 秒。
- 下一步：E1 读数 → 召回修复决策稿（核对一手来源）报用户 → 实现 → 补验收的闭环实跑（带 CPU 采样）。
- **E1 已跑、已判定**（本地 `s1r10/recall/e1-results.md`；OTP 29.1.2，节点同一套）：缺省 profile 下快请求排进 `/slow` 那条正忙的 keep-alive 连接（`queue_length=2`），10,001 ms `{error,timeout}`，且**从未发出**（期望里“慢请求结束后照发”一句落空：调用方超时时 httpc 把它从队列取消）；独立 profile 7.7 ms 返回 200。报告 §5.1 的机制被实验支持。召回修复决策稿已交子会话起草（`2026-11-16-npc-hindsight-recall-isolation-decision.md`，一手来源逐条核对）。
- **召回修复决策稿已写（`75e6d7c1`），用户 2026-11-16 四项都选建议项**：召回独立 httpc profile（参数缺省，应用起停）；retain 保持同步；选择每路只由 httpc 计时（去掉 Task kill）；重试暂不加退避。甲类 13 次由 D-1 消除；乙类 12 次（Hindsight 重排变慢）只能靠下次实跑的 CPU 采样查。下一步：实现 T8（任务书 `s1r10/impl/t8-brief.md`）→ 评审 → 提交 → 日计划层补验收 + 召回修复 + CPU 采样合并为一次闭环实跑（先写计划、告知用量）。

### 交接（2026-11-14，第十三个统筹会话 → 第十四个，因上下文超过 250k）——接手先读这一节，再按需读紧接着的“第十三个统筹会话的进展”；任务书 `.demo/observe/npc-slice1-20261112/handoff-14-brief.md`

**一句话**：R6 闭环实跑做完并判定了（链路与新栏规则按设计工作；召回超时一条未通过，没有记验收；新栏几乎推不动选择）；两轮离线对照查到主因是新栏句首的两段标注；用户选了“只留句子”，R4b 已实现、已全套测试、已独立评审、已本地提交（`2e251462`）；**下一次闭环实跑 S1-R7 的计划、期望与脚本都已备好，还没起节点**。

**交接时的现场**：工作区干净，分支未推送。没有在跑的节点、tmux、转发、补料进程；容器 / 卷 37 / 19；本线容器只有常驻的 `npc-s1g-hindsight-20261113`。Hindsight 里本线的真实 bank 都不删：`npc-life-` / `npc-reflect-` 各配 cid `114244456449`（S1-Z）、`129524305921`（R6 作废的那次）、`115410472961`（R6）。

**下一步（按此顺序）**
1. **起 S1-R7**：计划与期望 `.demo/observe/npc-slice1-20261112/s1r7/plan.md`（运行前已定稿，不改）；脚本 54 个在 `s1r7/scripts/` 与 WSL `~/npc-s1-run/*-s1r7.*`（由 `*-s1r6.*` 改名，只做过静态检查；端口 PG 55468、auth HTTP 27631、转发 3427，起前再查空闲）。
   逐步调用清单照 R6 的（本页“第十三个统筹会话的进展”里没有抄，见 R6 执行子会话的任务书要点：`s1r6/plan.md` 时间线 + 脚本文件头；①–④ 各步的脚本名把 `s1r6` 换成 `s1r7`）。WSL 的构建产物要先对着 HEAD（`2e251462` 改了 `mind.ex`）编译一次。
   **R6 的教训**：起节点前告诉用户用量（用户选“只留句子”时已被告知要再跑一次，约 70 分钟、约 8 轮、至多约 22 次写作）；每轮 `event=end` 后查 429；执行子会话因 429 中断时产品也在 429，**统筹会话要立即自己停节点**；执行子会话的中间通知只是进度，不要转述成读数；`waitgap` 已修（日志行首退格符）。
   跑完派只读子会话**从原始导出独立重算**再写 `s1r7/results.md`（R6 的重算任务书可照搬：七节；“某份 state 的时刻”取日志里那次选择的发问时刻）。
2. **等用户表态的一件**（已在对话里提出，用户没有回答；不表态就照原规则）：S1-R7 验收组的 A6（选择的召回超时 ≤ 3 次且都在存档窗口里）R6 没通过、产品也没为它改，预计仍落空；统筹会话提议它落空而其余六条成立时记作“反思模块已验收，召回超时单列为未解决问题”。
3. 其后：R6 留下的没查的——Corvin 到场 B 不对质的原因、收尾句的写法（并列几件事的弱）、采集被采石 / 采石灰石分票、`asked-…121846.519Z` 在重建完成后仍写小屋 `is gone`、`states/index.tsv` 漏记与错位（观察脚本）；召回超时（并入 S1-T 的“写库拖慢召回”）；空转的计分；S1-O、S1-U 的离线测量；“按处境带出对应的想法”；“对某人说话”（先查证已有做法、写决策稿）；S1-T 暴露的七件事。部署前补三组 NPC 环境变量（须先问用户）。

**用户这一个会话里定的事**：R6“备够是否停下”按现状跑作基线；补测 L4 落空后照现状跑 R6；**Voxim 那条线已结束，不再通知或等待 Voxim 会话**（原话“那边已经彻底结束了，你既不需要问也不需要等”）；新栏写法“只留句子”。

### 第十四个统筹会话的进展（2026-11-14T16:30Z 起）——上面第十三 → 第十四交接里“下一步”各项的状态以这里为准

- 接手时工作区干净、无残留进程、容器 / 卷 37 / 19。WSL 对着 HEAD `e092bf51`（产品代码同 `2e251462`）`mix compile` 成功（`s1r7/compile-head.log`）。
- **S1-R7 已跑完、已判定、已收尾**（节点 `npcs1r7` 16:38:02Z–17:37:39Z；Garen cid 1689289494529，Corvin 1906495721474；执行子会话任务书 `s1r7/exec-brief.md`、回报 `s1r7/seg12-report.md`、`seg34-report.md`；只读独立重算任务书 `recalc-brief.md`、回报 `recalc-report.md`；判定 `s1r7/results.md`）。七轮反思：六轮 16 问全部一次写成、存档 ok，第 6 轮故障注入下中止、撤栏、第 7 轮回来；全程无额度错误。清理后容器 / 卷 37 / 19，无残留进程；新 bank `npc-life-1689289494529`（103 份）、`npc-reflect-1689289494529`（16 份）不删。
  **甲组（验收）**：A1、A2、A3、A4、A6、A7 六条成立（**A6 召回超时这次通过**：1 次且在存档窗口里；R6 里为它准备的“单列未解决”提议用不上）；A5 读到的各项全成立，但**第 ③ 段没抽队列样本**（统筹会话给 ③④ 段的消息漏了这一步，执行遗漏，不是产品读数落空）。按运行前规则统筹会话不单方面记“已验收”，提交用户定；**用户 2026-11-14 经对话框定：记“已验收”，A5 缺项注明为执行遗漏**（未选“未验收、补跑”）。**反思模块（R1–R4b）的链路与新栏规则由此记为已验收**；以后任何一次实跑第 ③ 段顺带补抽队列样本，不单独安排。
  **乙组（行为读数）**：5 成立（B3、B4、B6、B8、B9）、2 落空（B1、B2）、2 部分（B5、B7）。要点：去掉标注后新栏那句对“去广场”“守屋”推得动（说去广场的三轮里广场 16 / 34，R6 全程 5 次；说守屋 13 / 13），对“采集”推不动（5 / 27）；守屋仍 72%（R6 87%）；不会淡下去的代价看见了（第 2 轮一轮内去广场 11 次），第 5 轮日记自己改口“广场一直没人”；第 4 轮把背包原始数字写进收尾句并进了新栏；Corvin 再来对质 2 / 6（原因仍没查）；备够后打算是采集时采集 25%。
- **S1-R7b（离线对照，探索性，不是验收）已跑完、已判定**：计划 `s1r7/why-plan.md`（发问前定稿），回报 `s1r7/why-report.md`，判定 `s1r7/why-results.md`，脚本 `tools/jev/s1r7b_why.py`；R7 的 8 份真实 state × 23 个变体，92 个 Jev 请求全部回答。3 成立（Y3 正对照、Y6 决绝句子、Y7 句子 vs state）、5 落空（Y1 6 / 8、Y2 后半、Y4 分票、Y5 删并列、Y8）。
  读法（按发问前写的分支）：**采集推不动的原因在句子写法，不在 state**——同一份 state 里，X3 那句“明说不再守、不去广场，去采石”能翻成采石（.74 / .83），删掉并列尾巴只把采集抬了 .13 / .25（不够 .50），两候选分票不是主因。方向：写作提示词的收尾规则改成“只说接下来做的一件、明说不再做什么”，要先用真实写作重测，**报用户定**。
  计划外：Corvin 在场两份 state 离线与实跑不一致（MVb 实跑守屋 .23，离线 4 / 4 对质；守屋 / 广场 / 对质三者接近），“对质 2 / 6”里可能有相当一部分是单次抽样波动；MVb 去掉新栏后对质 .39 → .55。执行偏差：第一次派出的子会话因 429 中断后，统筹会话另起了一个而不是 SendMessage 续做（原子会话没有产出，无影响）。
- **S1-R7c（新收尾规则的离线重测，探索性）已跑完、已判定**：用户 2026-11-14 经对话框选“先离线重测新收尾规则”。计划 `s1r7/rewrite-plan.md`，判定 `s1r7/rewrite-results.md`，脚本 `tools/jev/s1r7c_rewrite.py`；用 R7 转发器存下的 6 份真实“自己”写作请求，系统提示词只换收尾那一句（P2：只说接下来的一件、要放下的明说不做），与原样重发（P0）各写 3 次（36 次写作），盲标后换进 R7b 的 8 份 state 问 Jev（192 次）。
  2 成立（Z1 合格、Z5 广场 / 守屋不变差）、4 落空（Z2 只说一件 9 / 18 不到 14；Z3 采集兑现 P2 .615；Z4 总兑现 P2 = P0 = .708；Z6 P0 复现原句类别 4 / 6 轮）。按发问前的分支：**新规则不进产品**。新规则还把打算本身推向采集（P2 采集 8 / 18，P0 3 / 18），计划写明这要报用户。**用户 2026-11-14 经对话框定：先放下，做排队的其他项**（未选“只读核对‘打算已做到’”“换一种收尾写法再离线测”）；收尾规则维持现状，“打算已做到还挂着”这条线索记下未核。
  计划外：M1f 里句子已过时（R1 写作开始时小屋刚被拆，M1f 时已重建），P2 采集不兑现 5 处里 3 处在 M1f；R7 实跑“说采集时只有 5 / 27 采集”可能有相当一部分是“打算已做到”（第 7 轮采了一次石灰石后回到守屋），未逐轮核。
- README 反思一节“当前状态”已更新为 R1–R4b 已验收并列出已知行为问题（`d2282f6f`）。观察脚本 `index.tsv` 漏记 / 错位的修复已派子会话（原因：0.5 秒取样里两次选择挨着时，新的 asked 先盖掉了未记账的那份）。
- **S1-R7d（Corvin 再来为什么不对质，离线，探索性）已跑完、已判定**：计划 `s1r7/corvin-plan.md`，判定 `s1r7/corvin-results.md`，脚本 `tools/jev/s1r7d_corvin.py`；R6、R7 里 Corvin 在场的 12 份真实 state，126 个 Jev 请求。
  先做的只读核对：`Recent activities`（只留 5 件）里没有对质的 3 份实跑都对质，有的 9 份都没有。离线：D1（C− 对质 6 / 6 ×3）、D2（C+ 8 / 9 不对质）、D4（复现实跑 10 / 12）成立；**D3 落空**——只从 `Recent activities` 删掉那一项，对质只升 +.04 – +.14，top1 对质 2 / 9。读法：**不对质不是单次抽样波动，也主要不是 5 件窗口**；嫌疑转到 `What just happened` 里那条对质（C+ 都有、C− 都没有）与之后那一轮写的收尾句；“B 项期望定得不对”的更正不成立。
- **用户 2026-11-14 的方向**（对话里原话）：“你已经在这个问题上停留太久了，继续吧，如果不是结构的问题就后期再优化”；并要一张 HTML 数据流图（派子会话画，产物 `.demo/observe/npc-slice1-20261112/npc-dataflow-20261114.html`）。
  统筹会话据此分：**收尾句写法、背包原始数字、两个采集候选分票、Corvin 删减的继续测量 → 后期优化，不再做**；**“打算没有完成状态、做过的事只靠几段文字间接表达” → 结构问题**，正是 `2026-11-13-npc-planning-reflection-borrowing.md` §6 排好的下一层“日计划”（意图 / 时段持有者 + Plans and promises 栏），按那里的顺序推进：先查证已有做法（已派调研子会话），再写决策稿报用户。观察脚本已修（`s1r7/watch-fix-report.md`，未在真实节点上跑过新版）。
- **日计划层决策稿** `docs/10-active/cross-cutting/2026-11-14-npc-day-plan-decision.md`（`3ed03d5c`；依据 GA、F.E.A.R.、HTN、Utility、Voyager、SayCan 一手来源）。**用户 2026-11-14 四项都选建议项**：“做完”代码判为主、LLM 兜底（`done` / `missed` / `cannot_yet`）；持有者 Life 持久行 `"plan"`、`DayPlan` 重写；规划 + 重排每 NPC 每游戏日共 5 次；先日计划、“对某人说话”随后。未实现；下一步按决策稿 §6：先写规划提示词与检查的离线测量计划。
- **数据流图**已画好：`.demo/observe/npc-slice1-20261112/npc-dataflow-20261114.html`（自包含 SVG，26 条箭头逐条对代码核过；state 八栏的 owner 与来源；“一圈”的时序；已知问题 a–e 标在图上）。子会话报的文档与代码不一致（未改，待顺手修）：README“统一形态”mermaid 与 `runtime.ex` moduledoc 写“一次召回”，代码是按处境分路、最多 4 路；README“反思”mermaid 写材料是“未封存经历”，代码是所有还没写进 Hindsight 的（已封存待写 + 未封存）；README“统一形态”mermaid 只画了 World 事件一个经历入口。
  **下一步候选（都要先写计划与期望、告知额度）**：采集为什么推不动（收尾句并列 + 两候选分票；分票次数需要逐候选分数，要在 state 导出旁加 Jev 响应落盘）；日记 / 收尾句里的原始数字（S1-U 改写法）；Corvin 到场不对质的原因；R6 遗留的其余各项见页首交接“下一步”第 3 条。

### 第十三个统筹会话的进展（2026-11-14 起，会话 ex-mmo-cluster-npc-48）——下面第十二 → 第十三交接里“下一步”各项的状态以这里为准

- 接手时：R4 已本地提交、工作区干净，“下一步”第 1 项跳过。已通知 `voxim-d6`（仍没有确认它是不是 voxim-d4 的接替者）。
- **新栏标注写法的补测 S1-R6a：已跑、已判定（探索性离线，不算验收）。** 计划与 6 条期望发问前写定 `.demo/observe/npc-slice1-20261112/s1r6/label-plan.md`，判定 `s1r6/label-results.md`，脚本 `docs/10-active/cross-cutting/tools/jev/s1r6a_label.py`。
  输入是 S1-X3 的 5 份真实基准 state 与同一句收尾句，只换新栏的写法（不带标注 / 真实间隔 / `Just now` / `About 12 hours ago`）；88 个 Jev 请求、0 失败。**2 条成立、4 条落空**：
  “多久以前”的数值起很大作用——同一句打算标 `Just now` 时比不带标注更强（无人时采石 .77–.91；Corvin 在场对质 .748，仍是首选），标 `About 12 hours ago` 时弱到与守屋相当（对质 .933）。
  按现在的节奏（两轮隔现实 5–10 分钟 = 游戏 6–12 小时），同一句话的作用在两轮之间从很强滑到约一半。
- **用户 2026-11-14 经对话框定的两件**：① R6 里“备够之后是否停下”按现状跑作基线（不先改写法）；② S1-R6a 的 L4 落空之后照现状跑 R6（不改新栏写法，“刚落栏”与“快到下一轮”两段分开判定；改不改等 R6 读数）。
- **R6 之前的第二次只读侦察**：`s1r6/scout2-report.md`。要点：采石样本单盒装不大（料堆只能高出地面 1 层、站位要在小屋射程内、地是坡），R6 改为实跑中按需 GM 补料；Corvin 只到场不拆屋用现成的 `bystander`；
  每一问的材料由转发进程只落请求 / 响应的 body（header 不落盘）；`final-s1z.sh` 数新栏数的是服务端日志、永远是 0，要改成数导出的 state；Tobin 没成为一问是因为不在关系表里（只有拆、伤、修过 Garen 的东西才进表）。
- **R6 的计划与期望已在运行前写定**：`s1r6/plan.md`（甲组七条是验收看的链路与新栏规则，乙组八条是闭环里的行为读数、报用户定；四段时间线约 70 分钟；看门狗 110 分钟）。没有 `s1r6/results.md` 就是还没跑完。
- **R6 的实跑脚本已备好并单独验证**（54 个：43 个由 `*-s1z.*` 改名、11 个新写；本仓 `s1r6/scripts/` 与 WSL `~/npc-s1-run/*-s1r6.*`）：转发进程加了只落 body 的捕获（假服务上验证过跨包、chunked、一条连接多请求、中断；header 与 key 不落盘），补料循环、读队列长度、等落栏间隔、Corvin / Tobin 到场、故障段自动起回转发。
  端口：PG `127.0.0.1:55468`（容器 `npc-s1r6-pg-20261114`）、auth HTTP 27631、转发 3427 → 3425；节点 `npcs1r6`、tmux `npc-s1r6`。查证：GM 补料以 `:operator` 提交、不带 interaction，按代码不会被 Life 写成经历（实跑里仍按 R14 实测）。
  **起节点前对计划的一处修订**（写在 `plan.md` 第 3 条）：补料去掉“采集中不补”的条件（连着选采集时没有补料窗口，石堆会被采空）；期望未动。
- **Voxim 统筹会话换名**：`voxim-d6` 做完一次公网冒烟（期间 NPC 线照约定暂停）后已不在列表里，列表里新出现 `voxim-ba`；起节点的通知已发给它并注明若不是接替者可忽略（没有确认）。
- **与 Voxim 统筹会话的约定到此作废**（用户 2026-11-14 原话：“那边已经彻底结束了，你既不需要问也不需要等”；统筹会话的理解：“那边”指 Voxim 客户端与发版那条线）：起节点、占端口、编译、跑测试之前不再通知或等待 Voxim 会话，也不必再找它的接替者；下一份任务书里“与 Voxim 统筹会话的约定”一节与“接手后第一件事”里的通知要删掉。全局 CLAUDE.md 的 UDP / 远程连接保护照旧。
- **R6 第一次尝试作废（额度用尽，不判任何期望）**：节点 07:58:43Z 起，第 1 轮三问写成并落栏（08:00:39）；08:09 起本机网关 5 小时额度用尽，第 2–10 轮都以 429 中止，执行子会话同时 429 中断，看门狗 09:48Z 停节点。统筹会话 12:14Z 清理（转发、tmux、`npc-s1r6-pg-20261114` 与匿名卷；容器 / 卷 37 / 19），证据移到 `s1r6/attempt1/`，经过记在 `s1r6/plan.md` 末节。
  新增两个 bank 不删：`npc-life-129524305921`、`npc-reflect-129524305921`。顺带看到：落栏后第一份 state 的新栏句首已是 `About 1 hour ago`（`Just now` 在产品里基本不会出现）。**教训：子会话因 429 中断时，产品的写日记也在 429，统筹会话要立即自己停节点。** 额度恢复后照同一份计划重跑（下一条）。
- **R6 第二次尝试已跑完、已判定、已收尾**（12:16:50Z–13:23:45Z，Garen cid 115410472961；判定 `s1r6/results.md`，读数由一个只读子会话从原始导出独立重算过）。八轮反思（七轮正常、第 7 轮故障注入下中止），18 问全部一次写成，全程无额度错误。
  **甲组（验收）七条没有全部成立，不记“已验收”**：链路、新栏的出现 / 撤下、每一问材料导出、健康都按设计工作（R9、R13、R14 成立；R1 只有一次写作 20.2 秒超出期望的 20 秒；R2、R16 按文件名时刻的字面口径各差一小项，出在观察脚本时间戳滞后）；**R11 未通过**——选择的召回超时 4 次（期望 ≤ 3），其中 1 次不在任何存档窗口里。
  **乙组（行为读数）八条：2 成立、3 落空、3 部分**。最要紧的：**新栏那一句在真实闭环里几乎推不动选择**——四轮“去采石”的打算只有第 3 轮兑现了三次选择（第 1 轮落栏起连续 36 次守屋），“去广场”的打算几乎没兑现，全程守屋 108 / 124；离线补测里同样形态的一句能把选择翻成采石，差别的原因没有查。
  其余：备够之后一次都没再采（51 / 51，与期望相反）；Corvin 再来时对质只有 1 / 6（第 5 轮新栏写的是“他离得近时我不动手”）；“当面问 Corvin”的承诺第 3 轮起不再出现，没有累积；空转照旧；补料没有产生经历；`Just now` 一次没出现（落栏后第一份 state 已是 0.5–1.5 小时）。
  执行偏差：`waitgap-s1r6.sh` 第一次用出错白等 15 分钟（已修），Corvin 到场 A 推迟到第 4 轮之后；轮数多一轮。清理后容器 / 卷 37 / 19，无节点、tmux、转发、补料进程。新增两个 bank 不删：`npc-life-115410472961`（107 份）、`npc-reflect-115410472961`（18 份）。
  **要用户定 / 下一步**：见 `results.md` 末节六条——先离线查清“新栏为什么推不动选择”（用这次的 124 份真实 state 与 18 篇日记换写法 / 换位置 / 去掉年龄），再谈改；R11 并入“写库拖慢召回”；计分（空转）仍未定。
- **“新栏为什么推不动选择”的离线对照 S1-R6b：已跑、已判定（探索性，不算验收）**。计划与 9 条期望发问前写定 `s1r6/why-plan.md`，判定 `s1r6/why-results.md`，脚本 `docs/10-active/cross-cutting/tools/jev/s1r6b_why.py`；输入是 R6 的 8 份真实 state 与真实收尾句，只做交换 / 删减；112 个 Jev 请求、0 失败。5 条成立、4 条落空。
  读到的：① 离线 8 / 8 复现实跑的选择；② **最大的一项是句首的“多久以前”**——同一份 state、同一句，`About 12 hours ago` 时采集合计 .085（与没有新栏一样），改成 `Just now` 是 .792；实跑里 100 份含新栏的 state 只有 17 份 ≤ 2 小时、55 份 ≥ 5 小时，新栏大部分时间等于不存在；
  ③ 其次是收尾句的写法（并列几件事的弱，明说“不再守”的强）与采集被采石 / 采石灰石两个候选分票；④ state 本身不是主因；⑤ **Corvin 到场 B 不对质与新栏无关**（去掉新栏照样守屋；`results.md` 里那句已更正，原因没查）。
- **年龄的剂量与“不写年龄”的离线对照 S1-R6c：已跑、已判定（探索性，不算验收）**。计划 `s1r6/age-plan.md`，判定 `s1r6/age-results.md`，脚本 `docs/10-active/cross-cutting/tools/jev/s1r6c_age.py`；三份“已旧”的 R6 真实 state 加一份 Corvin 在场的，只换新栏句首；88 个 Jev 请求、0 失败；4 条成立、2 条落空。
  读到的：`Just now` 时打算的活动 .81（三份一样），2 小时 .23–.56，5 小时 .14–.46，10 小时以上 .04–.38；产品里 `Just now` 不会出现。**`I thought:` 这个标注本身也在削弱**：只有句子（S1-X3 测过的 `selfplan` 形态）.63–.85，`I thought: <句>` .18–.67。Corvin 在场时三种写法首选都仍是对质（.67–.86）。
  **要用户定**：新栏写法改不改（只有句子 / 只去掉年龄 / 不改）；改了要重做 R4 的测试与评审、再实跑一次闭环。没解决的另两项：收尾句的写法、采集被两个候选分票；Corvin 到场 B 不对质的原因没查。
- **用户 2026-11-14 经对话框定：新栏写法改成“只留句子”**（三个选项：只留句子 / 只去掉年龄 / 先不改；用户选第一个）。新栏正文只放最近一轮写成的“自己”一问的收尾一句，不加“多久以前”、不加 `I thought:`；出现与撤下的规则不变。已告知的代价：一轮之内这句话的作用不会淡下去，过时的打算只靠下一轮重写或撤下，好坏要再实跑一次闭环看。
  这一改动代号 **R4b**：改 `Mind` 的渲染、测试、moduledoc 与 README → npc_server 全套 → 不带结论的独立评审 → 本地提交 → 照 `s1r6/plan.md` 的做法再跑一次闭环（新写一份计划与期望，代号 S1-R7，脚本复用 `*-s1r6.*`）。没有 `s1y/r4b-report.md` 就是实现还没回来。
  **R4b 已实现、已测试（npc_server 全套 493 passed、0 failed）、已独立评审（无阻断；一条应改已修：测试里的“此刻”恢复成晚于想的时刻）、已本地提交 `2e251462`；未实跑、未验收。** 回报与评审要点 `s1y/r4b-report.md`，日志 `s1y/r4b/`。产品代码只改了 `mind.ex` 新栏的渲染一处。
  **S1-R7 的计划与期望已在运行前写定** `s1r7/plan.md`（甲组七条验收、乙组十条行为读数）；脚本 54 个已备好（`s1r7/scripts/`，静态检查过）。没有 `s1r7/results.md` 就是还没跑完。
- **（以下是起跑时写的，已过时）R6 已起跑**（第 ①、② 段由一个执行子会话在做；③、④ 段让同一个子会话续做）。**若本会话中断**：先看 WSL 里 `tmux ls` 与 beam 是否还在，看门狗在起节点后 110 分钟无条件停节点；清理只删 `npc-s1r6-pg-20261114` 与它的匿名卷、停本线的转发与补料进程（`fwd-stop-s1r6.sh`、`restock-stop-s1r6.sh`），容器 / 卷应回到 37 / 19。

### 交接（2026-11-14，第十二个统筹会话 → 第十三个，因上下文超过 300k）——接手先读这一节，再按需读紧接着的“第十二个统筹会话的进展”；任务书 `.demo/observe/npc-slice1-20261112/handoff-13-brief.md`。下面第十一 → 第十二的交接已执行到第 3 项中途，状态以这里为准

**一句话**：反思 R3 做了真实服务端短实跑 S1-Z（五轮，整条链走通；已实跑，不算验收）；用户对新栏选了 A，R4 已实现、已独立评审（无阻断项）、评审的两条应改已修；R5 的全套测试第一次有 9 条失败（都不是 R4 引起的，其中 8 条是 R3 留下的测试夹具问题），第二轮修补的结果见下面“交接时的现场”。R6（闭环实跑）还没开始，侦察已做。

**交接时的现场**：**R4 已本地提交，npc_server 全套全绿**（`mix test --no-start`：493 passed、18 excluded、0 failed，日志 `s1y/r4/fix2-full.log`；提交号见 `git log`，共三个：对话测试夹具的修补、R4 本体、文档）。工作区干净，分支未推送。临时库容器 `npc-r4-pg-20261114` 与它的匿名卷已删，容器 / 卷 37 / 19，WSL 里没有 beam。
**R4 现在是：已实现、已测试（含全套）、已独立评审、已本地提交；未实跑、未验收。** “你要做”第 1 条已完成，从第 2 条 R6 开始。
跑全套要给占位的 `NPC_LLM_URL` / `NPC_LLM_KEY` / `NPC_LLM_MODEL`（`NpcEmotionMovementTest` 的 `:dry` 用例解析 `"life"` 形态时要读，不发请求；写法见 `s1y/r4/run2.sh`）。

**用户这一个会话里定的事（原话都在内容规范 §10.11 末尾与 §8 末条）**
- 候选活动不再逐个情形手写（“全部同意”）：操作粒度停在技能一级，组合与开放参数归规划位置的 LLM；“对某人说话”排在 R6 之后、作为薄片二说话部分的第一件；不单独设计“问”这项活动。
- 新栏选“A”：只放最近一轮写成的“自己”一问的收尾一句、标上多久以前想的；最近一轮没写成“自己”就撤下；“按处境带出对应的想法”放到 R6 之后离线测。
- 重复的原始记忆与精炼后的记忆要分开：是提法，未定稿；现状读数与没解决的五件在 §8 末条与 `s1o/scout-report.md`。
- 用中文交流；上下文长了就在可暂停的点自己开新会话移交（2026-11-14 原话见任务书页首）。

**下一步（按此顺序）**
1. **R4 收尾到本地提交**（见“交接时的现场”；已提交就跳过）。
2. **R6 闭环实跑**：先写计划与期望（运行前定稿，放 `.demo/observe/npc-slice1-20261112/s1r6/plan.md`），蓝本是 S1-Z 的计划与 43 个脚本。写之前读 `s1r6/scout-report.md`。计划里必须处理的：
   - **采石样本装大**（S1-Z 的 12 格三次就采空；是夹具参数，不改产品）；拆屋不退料给 Garen，每被拆一次要重新采一座的料。
   - **“备够之后是否停下”**：state 里没有“备够”的文字，只有原始 units。统筹会话向用户说过倾向——R6 按现有写法跑，把“读原始数字时备够了停不停”如实记作改写法之前的基线；**用户没有表态**，写计划时再向用户确认一句。
   - **每一问发给写日记接口的材料要导出**：现在没有任何记录、离线无法完整重建；做法（例如实跑脚本经 rpc 读、或经 `profile.write_journal` 入口做只读捕获）写计划时定，不改产品行为。
   - 期望至少看：内容规范 §10.11“验收”一条的六件（说了去采石之后是否去了、备够之后是否停下、广场是否回来、Corvin 再来时是否仍对质、“说了做不到”的承诺是否累积、无事时是否空转）；新栏在 state 里的出现与撤下（中止的一轮之后整栏消失到下一轮落栏，**选择会不会回摆**）；存档期间选择的召回超时（S1-Z 五轮 1 次）；反思库的巩固用量；`final-s1z.sh` 里新栏计数的期望要从 0 改成非 0。
   - **带 `I thought:` 与“多久以前”标注的写法没有离线读数**：R6 之前或其第一段里补一轮小测（用产品渲染出的真实 state；旧离线脚本 `tools/jev/s1x2_reflect.py`、`s1c2_counterfactual.py` 按固定栏名切 state，会把新栏并进 `What I remember`，用它们之前先改）。
   - 起节点前告知 Voxim 统筹会话；网关用量开跑前告诉用户。
3. 其后：S1-O、S1-U 各写离线测量的计划与期望（要点在“第十二个统筹会话的进展”里“下一步（接手者）”一条）；“按处境带出对应的想法”离线测；“对某人说话”（先查证已有做法、写决策稿）；S1-T 暴露的七件事。部署前把三组 NPC 环境变量补进 `deploy/.env` 与 `.env.example`（须先向用户确认）。

**环境（交接时）**：本线没有在跑的节点、tmux 会话、转发进程。本线容器只有 `npc-s1g-hindsight-20261113`（`127.0.0.1:18933`，在跑）；容器 / 卷 37 / 19（临时库容器的状态见“交接时的现场”）。Hindsight 里本线新增两个真实 bank **不删**：`npc-life-114244456449`、`npc-reflect-114244456449`。WSL `~/npc-s1-run/` 里留着 `*-s1z.*` 脚本与 `server-s1z.log`。
**voxim-d4 已不在会话列表里**；列表里有 `voxim-d6`，已把通知发给它并注明若不是接替者可忽略，也已问用户它是不是接替者，**用户还没有回答**。生产仍是 `20261112-qinglan`（master `29531ea4`，不含本分支，NPC `enabled=0`）。

### 第十二个统筹会话的进展（2026-11-14T02:10Z 起，会话 ex-mmo-cluster-npc-7f）——上面交接里“下一步”各项的状态以这里为准

- **第 1 项 R3 的短实跑（代号 S1-Z）：计划与 14 条期望已在运行前写定**，`.demo/observe/npc-slice1-20261112/s1z/plan.md`（2026-11-14T02:40Z）。三段：① 起节点到小屋建成；② Corvin 拆屋 → 第 1 轮，Tobin 来说一句话 → 第 2 轮，再等一轮“新经历全是无人例行活动”的反思（看空转）；
  ③ 停掉写日记的出口后 Corvin 第二次拆屋（那一轮中止），恢复后量小屋的反思推迟多久，全量导出、停节点、清理。每轮落栏后导出 Life 持久行全文到 `s1z/export/rows/`（R4 的夹具从这里取）。
  - 写日记全程经本线的一个纯 TCP 转发进程（WSL，`127.0.0.1:3426 → 3425`，`s1z/scripts/fwd-s1z.py`）到 magpie 网关；第 ③ 段停掉它，产品遇到的是真实的“接口连不上”。这是对外部依赖的故障注入，不改产品、不往产品里塞数据。
  - `NPC_REFLECT_KEY` 在 source 环境脚本时从 Hindsight 容器的环境变量现读进进程环境（`env-s1z.sh`），值不落文件；`NPC_REFLECT_MODEL=claude/claude-sonnet-5-5`。
  - 脚本 43 个（35 个由 `*-s1t.*` 复制改名、9 个新写）在 WSL `~/npc-s1-run/*-s1z.*` 与 `s1z/scripts/`，由准备子会话做好并单独验证了转发（通时 200、停后连接被拒）；统筹会话抽查了 `env`、`start`、`fwd`、`reflwait`、`final`。
  - 起节点前已告知 voxim-d4（节点 `npcs1z`、tmux `npc-s1z`、27630、PG `npc-s1z-pg-20261114` 在 `127.0.0.1:55466`）。起前读数：容器 / 卷 37 / 19，UDP 端点 83。
  - **S1-Z 已实跑完、已判定、已收尾（已实跑，不算验收）**：判定与链路表 `s1z/results.md`；子会话回报 `s1z/seg12-report.md`、`s1z/seg3-report.md`。节点 02:38:14Z 起、约 03:11Z 停；Garen cid 114244456449。
    **14 条期望：11 条成立，Z8“无事时空转会发生”成立，Z9、Z11 各有一小项落空。** 五轮反思：三轮正常（拆屋事件立即触发、累计分被 5 分钟间隔压住后触发、20 次无人活动触发）、一轮在出口连不上时中止、一轮恢复后；10 次写作全部一次写成（7.1–13.3 秒、各 4 句），10 份存档各抽出 3–5 条事实，两库分开。
    落空的两小项：Z9 期望“日志有 `event=round_failed`”，实际问题一级的失败记在 `event=question … result=failed` 与 `event=end … error=` 里（期望里把日志名写错了，其余各项成立）；Z11 心智就绪之后有 1 次 `npc_select_failed`（`recall_timeout`，落在第 5 轮存档期间——与 S1-T“写库时召回被拖慢”同一类，这次的写入者是反思的存档）。
  - **R3 留下的两件的读数**：① 拆屋那一轮写作失败后，小屋的反思推迟 **6 分 19 秒**（这次重建与 Corvin 到场给分快；安静时约 10 分钟），期间行里小屋那条仍是拆屋之前写的；② 无事时**确实空转**：20 次无人活动起一轮，两问、约 18 秒、2 份存档加一次巩固，结论与上一轮相同。两件都留到 R4 接上、R6 闭环之后再定改不改（不在此时改分值）。
  - **看到的、要带进后面的**：日记说“不守了、去采石”之后仍守了 20 次，第 3、5 轮的日记自己写出了这一点（日记还不进 state，R4 要接的就是这一环）；每篇日记都照抄原始数量与坐标；五篇里四篇承诺“Corvin 来了就当面问”；Tobin 来过并说了话却没有成为一问（原因没查）；
    反思库 60 条记忆里 15 条把“我”写成 `the narrator`，Hindsight 对反思库排了 4 次巩固（额外用量）；连不上的原因在日志里地址被打成字符编码表。
  - **R4 的夹具来源**：`s1z/export/rows/` 七个时点的 Life 持久行全文（built、round1、round2、round3、round4-aborted、round5、final）与同时刻的 `Life.observe`；67 份 state 在 `s1z/states/`。进仓库的夹具要复制到 `apps/npc_server/test/support/fixtures/`。
  - **环境（S1-Z 之后）**：没有节点、tmux、转发进程；`npc-s1z-pg-20261114` 与它的匿名卷已按名字删除，容器 / 卷 37 / 19，UDP 81；已告知 voxim-d4 节点已停。新增两个真实 bank **不删**：`npc-life-114244456449`（63 份文档）、`npc-reflect-114244456449`（10 份文档）。WSL `~/npc-s1-run/` 里留着 `*-s1z.*` 脚本与 `server-s1z.log`。
- **第 3 项 R5 里不依赖 R4 的文档部分：已做**（子会话只改 Markdown，统筹会话逐行看过 diff）：`apps/npc_server/lib/npc_server/README.md` 的 Life 一章加“反思”一节（是什么、为什么、流程图、与持久行 / 存档库 / 失败 / 手动入口 / observe / 日志的关系、三个环境变量、当前状态；细节链接到 moduledoc），
  并改掉两处已不准确的“NPC 自己不调用任何 LLM”；`apps/npc_server/README.md` 的链接说明；`deploy/README.md`“NPC 常驻应用”补一段：`"npc"` 登记要的三组环境变量（Jev、Hindsight、`NPC_REFLECT_*`）与现状。
  **没有改的**：`deploy/.env.example` 与 `deploy/docker-compose.yml` 里本来就没有任何 NPC 变量（生产 NPC `enabled=0`），这次没有动非文档文件；启用 `"npc"` 登记之前要把这三组变量补进 `.env` 与 `.env.example`（属部署，须先向用户确认）。R5 剩下的：R4 之后的全套测试、README 的“七栏”随 R4 改。
- **第 2 项 R4：2026-11-14 用对话框把三种放法与建议再问了用户一次，用户没有选，表示想先澄清**；还没有答复，R4 不动。
  用户随后问了两件（原话记在内容规范）：① “这个新栏是做什么的？单独放反思吗？反思不能和原始记忆一同参与召回吗？”——统筹会话解释了分开的四个原因，并给了三个方向（A 新栏先只放一句、按处境取想法放到 R6 之后离线测；B 不要新栏、直接做反思参与召回；C 新栏加按处境从持久行取对应那条），**用户还没有选**。
  ② 重复的原始记忆与精炼后的记忆要分开（内容规范 §8 末条）：统筹会话对着 S1-Z、S1-T 的导出数过——这一层已由 Hindsight 的巩固加 `prefer_observations` 做着，原始重复句基本不进选择的召回（S1-Z 51 份里 1 份、S1-T 98 份里 5 份）；没解决的是归纳那一条本身的质量（冗长、时间标注、重叠、空窗、过时），并入“S1-T 暴露的七件事”另开任务。
- **第 2 项 R4：用户已答复，原话“A”**（2026-11-14；三个方向与落细的规则记在内容规范 §10.11 末尾）：新栏只放最近一轮写成的“自己”一问的收尾一句，代码标上多久以前想的；最近一轮没写成“自己”就整栏撤下；`Selector` 的问法不改；按处境带出对应的想法放到 R6 之后离线测。
  任务书 `.demo/observe/npc-slice1-20261112/s1y/r4-brief.md`（没有 `s1y/r4-report.md` 就是实现还没回来）。带“多久以前”标注的写法没有离线读数，R6 之前要补一轮小测。
  - **R4 首版已回来（已实现、已测试；未评审、未提交、未实跑）**：回报代存 `s1y/r4-report.md`，日志 `s1y/r4/`。子会话中途因 5 小时额度用尽（429）中断过一次，没有重试刷请求；额度恢复后由同一子会话带原上下文续做。
    新函数 `NpcServer.Life.Reflection.thought/1`（规则只在这一处）；`Life.mind/2` 与 `observe` 的 `reflection` 带 `thought`；`Mind` 在 `What I remember` 与 `Current situation` 之间按需加栏，正文 `<多久以前>I thought: <收尾句原文>`；`Selector` 问法未改。
    测试（WSL）：先红 `red-reflection-mind.log`（31/33，两条新用例失败）；绿：reflection 14、mind 19、selector 18、round 4、life 21（第一次 20/21：一条对 observe 的 `reflection` 整份比对的既有断言要加 `thought: nil`，已改，如实记：这是对既有断言期望的一处改动）。
    夹具 5 份在 `apps/npc_server/test/support/fixtures/reflection/s1z/`，取自 S1-Z 导出的持久行，只留 `"latest"` 与 `"round"`；统筹会话用脚本对着 `s1z/export/rows/` 逐值比过，相同。统筹会话核对了各日志的结果行、产品代码的 diff、临时库容器与卷已删（37 / 19）、WSL 里无 beam。
    `--warnings-as-errors` 编译失败是本线之外旧文件的既有警告，本线文件无警告；`npc_mind_test.exs`、`npc_selector_test.exs` 在 HEAD 上就不合 `mix format`（没有顺手重排）。
  - **R4 独立评审已做**（Fable 5.2，只读，没有给它实现者的回报与统筹会话的看法）：原文代存 `s1y/r4-review.md`。**没有阻断项；应改 2 条、记录 9 条。**
    应改 ①：核心判断（“自己”在不在这一轮写成的各问里）没有用例能证伪——把它改成“写成了任何一问”全部用例仍绿；真实导出里没有“写成了别的、没写成自己”的时点，要在 Life 层补一条（小屋写成、下一问超时）。应改 ②：三份文档把“不沿用上一轮”写成无条件，实际有三条路径会沿用（Life 在一轮进行中重启；落栏保存失败；落栏前崩溃且记中止小结的保存也失败）——新一轮已起却没留下小结时，栏里仍是上一轮那句。
    **统筹会话的处理**：① 接受，补用例并做反证；② 接受为**只改文档、不改行为**（三条都是少见的失败路径，后果是多留一轮旧的打算；“起轮即撤下”会让每一轮写作的二三十秒里栏都空着，没有读数支持，不改）。修补与 npc_server 全套测试（R5）已派给一个子会话（Opus 5.5 medium），没有回报就是还没做完。
  - **R4 评审修补已回来（未提交）**：回报代存 `s1y/r4-fix-report.md`，日志 `s1y/r4/fix-*.log`。新用例 `npc_life_test.exs`“写成了小屋、下一问写日记失败……新栏没有那一句”；反证做了（把判断改成 `written != []` 后新用例红，日志 `mutation-written-nonempty.log`；红的方式是 `thought/1` 在 `latest["self"]` 上匹配失败使 Life 崩溃，不是断言失败），改回后绿，统筹会话核对那一行已改回。
    文档改准了“不沿用上一轮”的边界（三条路径对着代码都属实）。测试：life 22（连跑两次）、reflection 14、mind 19。
  - **第 3 项 R5 全套测试：第一次跑出 484/493，9 条失败，都不是 R4 引起的，但其中 8 条是 R3 留下的**（如实记：R3 提交时只跑了改到的测试文件，没跑全套；上一次全套是 `c30a1a85` 时的 457 全过，`s1t/t34-full.log`）。
    ① `NpcDialogueLifeTest` 8 条：这份测试手工拼 Life 的 GenServer 状态直接喂 `handle_cast` / `handle_info`，没有 R3 新加的 `journaling` / `reflect` / `reflect_error` 三个字段，落进开着反思的 `accept/3` 而崩。产品里状态只由 `Life.init/1` 构造，三个字段总在，**不是产品缺陷，是测试夹具没跟上**；修法是在那份手拼的状态里补上三个字段（不反思的形态）。
    ② `NpcEmotionMovementTest` 1 条：运行环境里没有 `NPC_LLM_URL`（以前的全套运行里有）。
    修补与重跑全套已派给子会话（日志 `s1y/r4/fix2-*.log`）。**已回来，全套全绿：493 passed、18 excluded（`fix2-full.log`）**；统筹会话核对了结果行、测试文件的 diff（只加三个字段与一行注释）、容器 / 卷 37 / 19、WSL 里无 beam。
    ① 的修法照上：`npc_dialogue_life_test.exs` 的 `state/0` 补 `journaling: nil, reflect: nil, reflect_error: nil`（如实记：这份手拼的状态相对 `Life.init/1` 还缺 `adapter`、`config`、`decision`、`recall`、`status` 五个字段，这些用例的路径不读它们，没有补）。
    ② 以前的全套运行给的是占位值（`s1f/impl-report.md` 记的 `http://127.0.0.1:9/responses`、dummy），这次照做（`s1y/r4/run2.sh`）；`:dry` 用例用注入的替身，不发请求。产品代码没有为此改动。
    **R4 随后本地提交**（三个提交：对话测试夹具的修补；R4 本体——代码、测试、夹具、README；文档）。
  - **voxim-d4 已不在会话列表里**（2026-11-14 约 06:50Z 发消息时不可达）；列表里有 `voxim-d6`（Voxim 的会话，起了约 2 小时），已把“NPC 线在跑测试、约定照旧”的通知发给它并说明若不是接替者可忽略。之后起长时间节点之前先 ListAgents 确认 Voxim 统筹会话的名字。
  - **R6 之前的只读侦察已做**（回报 `.demo/observe/npc-slice1-20261112/s1r6/scout-report.md`）：采石样本只有 12 格石头、一次按整格采 4 格，S1-Z 里三次就采空（第四次 `gather: exhausted`）——**R6 要把样本装大**，否则“说了去采石之后是否去了”看不出来；“备够”在 state 里没有文字，只有原始 units 的背包数与判据里的造价，也没有可行性过滤；拆屋不退料给 Garen；每一问发给写日记接口的材料现在没有任何记录、离线无法完整重建（R6 要导出就得在实跑里经 `profile.write_journal` 之类的入口做只读捕获，做法写计划时定）；观察脚本不按栏名解析，只有 `final-s1z.sh` 里新栏计数的期望要改。
    评审“记录”里要带进后面的：撤下期间选择会不会回摆（R6 的期望里专门看）；离线脚本 `tools/jev/s1x2_reflect.py`、`s1c2_counterfactual.py` 按固定栏名切 state，新栏会被静默并进 `What I remember`——**用它们做补测之前要先改**；收尾句里的原始数量现在经新栏直达 Jev（属 S1-U）；`round.ex` 里还有一份字面量 `"self"`（R3 既有）。
- **第 5 项的两件已做只读侦察（R4 等用户期间做的；没有改任何代码、没有发网络请求；只是读数，测量计划与期望还没写、还没跑）**：
  - **S1-O 归纳的质量**（回报 `.demo/observe/npc-slice1-20261112/s1o/scout-report.md`）：① 冗长的一个可能来源在产品自己写的 mission——`retain_mission` 写“Keep counts and times”、`observations_mission` 写“say how many times it happened”，归纳于是每次列一个时刻（S1-Z 最长 875 字列了 46 个时刻）；② “多久以前”偏早是我们自己的取法：召回行取 `occurred_start`（出处里最早那次，`hindsight.ex:265`），归纳的 `occurred_end` 是最晚那次；
    ③ 写库到巩固完成的空窗中位约 36 秒，原始守屋句只在这个窗口里进召回；④ **过时的那句“the building no longer exists”在重建之后的每一份 state 里都在**（S1-Z 51 份、S1-T 98 行），在库里一直是 `valid`、从没被失效——这句话的现在时断言是 Life 写事件原文时自己带的（`life/state.ex` 的事件原文）；
    ⑤ 同时出现 ≥ 2 条带次数的守屋归纳的 state：S1-Z 18 份、S1-T 55 份；⑥ Hindsight 有按 scope 限条数、按 scope 设 mission、手动巩固、删除并重建归纳、查一条归纳历次变化的接口，缺省值都没改过。离线重测可行：`npc-life-114244456449` 还在，原文可逐份 GET `original_text`。
  - **S1-U 原始单位、坐标与内部编号**（回报 `.demo/observe/npc-slice1-20261112/s1u/scout-report.md`）：一份 state 平均有 ≥ 5 位整数 19.8 个、坐标 8.2 个、`material N` 12.1 处、world id 3.3 处、事务号 4.2 处；最多的是认识文档那一栏（Hindsight 从经历原文转写来的），所以**改在经历原文的出处才管用**。1 宏格 = 2,097,152 units，小屋要石头约 3.18 格、石灰石约 0.49 格。
    背包数量由 `Mind.inventory/1` 一处渲染（state 与反思共用）；造价、采集量与建造坐标不在产品代码里，是登记参数里人写的判据；建筑坐标有三处来源且数值不同（锚点 510、被打的格 512、判据）。state 里没有“还差多少”的句子，模型自己做减法。内容规范 §2 早已写“数量用玩家可读单位、材料写名字”，总纲写“编号与坐标只留在代码这一层”，代码没照做。约 38 处测试断言与 `fixtures/reflection/` 的夹具含这些原始数字。
  - **下一步（接手者）**：两件各写一份离线测量的计划与期望（输入用 S1-Z / S1-T 的真实导出，改写法属于“对真实导出换写法”，符合方法论），开跑前告知用户（要用网关额度）；S1-O 至少看：mission 改写后归纳的字数与是否还保住次数与“没发生什么”、时间标注改取最晚那次后的读法、事件原文不带现在时断言后过时句还在不在；S1-U 至少看：换成名字与“格”、去掉坐标 / world / 事务号之后三种处境的选择是否稳定、日记还抄不抄数字。两件都会动 state 文本与经历原文（共享契约），实现要排在 R4 之后或与 R4 合并排期，由统筹会话定。
- **用户 2026-11-14 定下的一个方向（候选活动的来源；原话与确认记在内容规范 §10.11 末尾）**：候选不再逐个情形手写，由“角色会做的操作 × 眼下可行的对象”生成；“对某人说话”是一项操作，走近与开启对话交给执行层，台词由 LLM 写；操作粒度停在技能一级；组合与开放参数归规划位置的 LLM，Jev 只在封闭候选里选。
  用户原话“全部同意”确认了两点：这两个边界；“对某人说话”排在 R6 之后、作为薄片二说话部分的第一件。§10.11“要用户定的”第 2 条因此有了答复（不单独设计“问”的活动）；**第 1 条（新栏放什么）仍没有答复**。

### 第十一个统筹会话的进展（2026-11-14 起，会话 ex-mmo-cluster-npc-b5）——下面第十 → 第十一交接里“下一步”各项的状态以这里为准

- **第 1 项 编译并测 R1、R2：已做，已本地提交。** 另派 Opus 5.5 短子会话在 WSL 里跑：`npc_reflection_test.exs` 11 passed、`npc_reflection_writer_test.exs` 4 passed、`npc_hindsight_test.exs` 20 passed、`npc_jev_test.exs` 6 passed（2 个联网用例照例排除）。
  **产品代码与测试代码一行都没有改**（第一次编译就过，本线文件没有编译警告）；只有 `mix format` 动了两处空白。两份回报里“没编译所以没确认的”各条都确认了（`~S"""` 去缩进与真实系统提示词相同、头名小写与 `content-type` 的断言、两个 async 文件共用替身、`capture_log` 抓到带 bank 的那一行）。
  统筹会话核对：四份最终日志的结果行；夹具与来源逐字节相同（`gateway-response.json`、`s1x2-moments.json`、`system-prompt.txt`，其余文件的修改时间早于本会话）。提交 `7780f116`（R1）、`84829049`（R2）。日志 `.demo/observe/npc-slice1-20261112/s1y/compile/`。
- **第 2 项 空的反思库抽不抽得出事实（S1-Y0）：已量，四条期望全部成立。** 计划与期望运行前写定（`s1y/empty-bank/plan.md`），判定 `s1y/empty-bank/results.md`。走产品自己的代码路径（`Reflection.questions/4` → `archive/3` → `Hindsight.ensure_bank/2` → `retain/2`），
  输入是 S1-X2 的两条真实日记：`retain/2` 成功，两份文档各抽出 3、4 条事实，15.1 秒；建成的库没有认识文档、没有抽取 / 巩固 mission。**结论：R3 的存档直接用 `ensure_bank/2` + `retain/2`，不改 `retain`。**
  只记录的两件：空库缺省抽取下有几条事实把“我”写成 `the narrator`（启用反思库的召回之前要先看）；每次存档后 Hindsight 会自己排一次巩固，是额外的网关用量（R6 要算进成本）。探针库 `npc-reflect-probe-20261114` 已按名字删除，其余 15 个 bank 未动。
- **第 3 项 R3 接进 Life：已做、已评审、已本地提交 `c6b610c1`（明细在本节后面几条）。下面这几条是首版任务书里定的，其中“起槽即清空新经历”“跳过照清触发状态”两条已被评审后的决定取代。** 任务书 `.demo/observe/npc-slice1-20261112/s1y/r3-brief.md`（统筹会话读过 `life.ex`、`mind.ex`、`registry.ex` 与离线脚本之后写的；设计决定都在它的 §3）。统筹会话定的、§10.12 没写细的几件：
  - 持久行加 `"reflection"`：触发状态、自上一轮以来的新经历（只留 `at_ms` 与 `tags`）、各问最新一条（日记、收尾一句、时刻）、最近一轮的小结、计数。**新经历要单独记在行里**——已封存并写进 Hindsight 的经历会从行里删掉，不单独记就定不了“问哪几件事”。
  - 四个经历入口共用一个“接纳经历”的私有函数（追加到未封存尾部 + 计分），不在四处各写一遍。
  - 起槽时在 Life 进程里把快照取齐交给 worker；起槽即清空“新经历”，这一轮写成与否都不还回去（同离线测过的“两轮之间的经历”）。槽在途时又到点、或还没有观察：这一轮跳过，计数加日志。
  - 写日记的出口失败（HTTP、超时、`stop_reason`）：这一问记失败，**这一轮到此为止**，不再发后面的请求（额度或认证类错误不连着重试）；检查不合格才原样重问一次。
  - **落栏不等存档**：写作结果先一次写进持久行，再存档；存档失败只计数与记日志，不重试、不影响已落栏的日记（权威在持久行）。已知代价：存档失败的那几条在反思库里就是缺的（这个库现在没有读者）。
  - 写日记的 endpoint：注册表 `"npc"` 形态从运行环境 `NPC_REFLECT_URL` / `NPC_REFLECT_KEY` / `NPC_REFLECT_MODEL` 取（必须，同 Jev 的做法）；反思库名 `npc-reflect-<cid>`。没有 `reflect` 的形态（模型模式）不反思。
  - 手动入口 `Life.reflect/1`；`Life.observe/1` 加 `reflection`；日志 `npc_reflect cid=… key=value`。R3 不碰 state 的七栏（R4 等用户答复）。
  - 对两份回报里子会话自己定的取舍的核对：R1 第 1 条 `event_waiting` 正是 §10.11“条件保留”所需，第 2 条 `causes` 只是多报信息，都与 §10.11 一致；文档 id 的形状与 §10.11 一致。没有发现不一致。
- **R3 首版已回来（已实现、已测试、未提交）**：回报代存 `s1y/r3-report.md`（文件清单、各测试文件的结果、子会话自己定的 11 条取舍、它指出的问题）。统筹会话核对了各日志的结果行与既有测试文件的 diff。
  既有测试的改动：`npc_registry_test.exs` 与 `npc_selector_test.exs` 加了三个 `NPC_REFLECT_*` 环境变量；`npc_registry_test.exs` 里 npc profile 的全等断言多了 `reflect` 一项（profile 加键的必然结果，如实记：这是对既有断言期望的一处改动），另加一条“缺 `NPC_REFLECT_URL` 登记不了”。
- **R3 独立评审已做**（Fable 5.2，只读；没有给它实现者的回报与统筹会话的看法，任务书里的设计决定也在评审范围内）：原文代存 `s1y/r3-review.md`。**阻断 1 项、应改 7 项、记录 7 项，另对任务书的设计提了 4 条异议。**
  - 阻断：落栏那次保存失败后，存档结果回来会在首轮让 Life 崩溃（在 nil 上 `put_in`）、非首轮把结果记到上一轮头上，且这一轮的日记无日志无计数地丢掉。
  - 它核对通过的：消息次序、不挡封存与 poll、与离线测过的做法一致的各项（召回参数、材料次序、“之前的想法”次序、重问规则、存档 id / tags / 前缀、此刻三行）、`Mind` 没有第二份渲染且七栏输出字节不变、夹具登记属实。
- **统筹会话对评审的处理（修正已派出，Opus 5.5 high；任务书 `s1y/r3-fix-brief.md`；没有回报就是还没做完）**。接受的异议与由此改掉的原决定：
  - **触发条件不被没起成的一轮吃掉**：`Reflection.record/2` 只计分与判定、不再清零，新增 `started/2` 在真的起一轮时清零（接口拆分；用 108 份真实文档重算 7 个时刻的期望一个不变）。到点但槽在途或还没有观察：触发状态留着，下一条经历进来再到点。
  - **新经历在落栏时才消耗，不在起槽时清**（改掉上面“起槽即清空”那条）：一轮做完才删掉它取走的那几条；中止的一轮（出口失败、问之前失败、worker 崩溃）不消耗，下一轮再问。检查不合格被丢弃不算中止（同离线测过的规则）。Life 在一轮进行中重启因此不丢新经历。起槽只存一次。
  - 落栏保存失败：记日志与 `error`，存档结果不碰行。日记“想的时刻”、存档文档的时刻改用起槽那一刻（同离线的 t′），不用触发那条经历的时刻。
  - 计数重新定义（加 `aborted`）；`"round"["archive"]` 取 `none / pending / ok / failed`；worker 崩溃的日志带原始原因；“之前的想法”只带此刻还在建筑表与关系表里的对象（不设条数上限——已知未设上限处，多个 NPC 实跑之前再定）。
  - 测试：去重与两处恒真断言改成能证伪的；补八条最小用例（`record/2` 不清零、召回失败、存档失败、落栏保存失败、槽在途又到点、`Life.reflect/1` 各返回、旧行加载等）。
  - 不接受的一条异议：`NPC_REFLECT_*` 对 `"npc"` 登记仍是必填（同 Jev 的做法；统一形态都反思）。**部署清单与 runbook 里还没有这三个变量——推送 / 部署之前必须补**（R5 改 README 时一并写）。
  - 只记录不改的：未封存经历与召回可能把同一件事给两次（`mind/2` 既有同样情形）；生命值恰为 .5 时四舍五入与 Python 不同；伤病词表逐字移植但真实导出里没有带伤病的观察，没有测试（按“不生造数据”测不了，R6 或以后有真实带伤导出再补）。
- **R3 修正已回来、已复审、已本地提交 `c6b610c1`（已实现、已测试、已评审；未实跑、未验收）**。修正回报代存 `s1y/r3-fix-report.md`，复审原文 `s1y/r3-rereview.md`。
  测试（WSL，日志 `s1y/r3-fix/`）：`npc_life_test.exs` 19 passed（连跑两次）、reflection 13、round 4、writer 4、hindsight 20、mind 18、selector 18、registry 15、jev 6。去重用例做过反证（删掉去重代码即红）。
  复审（Fable 5.2，只读）：**没有阻断项**；首版 8 条 6 条已解决、2 条部分解决（崩溃路径没有测试、`:no_observation` 没测）；状态机逐条路径走查无误；`record/2` 拆分与原规则完全等价，7 个时刻的期望未变；没有发现生造的测试数据。
  统筹会话认可的两处偏离：Round 单测的收尾句断言用 1-Q_place 的真实日记末句（4-Q_self 的那份引用到第 43 条材料，单测只有 29 条真实召回）；一问没有任何材料（`:no_materials`）算“没做完”，不消耗新经历。
- **R3 收尾修补已做、已本地提交 `9d40ee6c`**（Opus 5.5 medium；日志 `s1y/r3-polish/`；`npc_life_test.exs` 21 passed 连跑两次、reflection 13、round 4；两条崩溃用例第一次跑就是绿的，没有发现代码问题）：补反思槽崩溃的两条用例（写作阶段、存档阶段）；一批多条到点直接取最后一条（不合并原因）；moduledoc 补全未设上限处与计数对不上的两条路径、写清“一轮的时刻”的两个含义；去重用例注明是替身构造的情形；两个近义的函数名分开。
- **R3 留给后面的已知事项**（都写在评审与回报里，R6 闭环实跑的期望要专门看其中前两条）：
  ① 中止的一轮不消耗新经历，但触发状态已清零，重问要等下一次到点——拆屋那一轮若首个请求就失败，小屋的反思可能推迟十分钟以上；② 写日记接口持续失败时 `"new"` 一直增长（未设上限）；
  ③ 落栏保存失败时 worker 照常存档，反思库里会有持久行里没有的日记（启用反思库的召回前要处理）；④ 到点但没起成之后只等下一条经历才重判；⑤ `last_at_ms` 对事件用 World 提交的时刻、对活动与手动轮用 Life 的时钟（生产里都是系统时钟）；
  ⑥ 手动入口的 `:no_observation` 没有测试（真实 Body 下造不出这个时序）；伤病词表没有测试（真实导出里没有带伤病的观察）。
- **voxim-d4 的两次通知（2026-11-14）**：它跑生产切换后的公网真实客户端冒烟期间要求 NPC 线暂停编译与 mix test，结束后已通知恢复。**如实记**：暂停期间本线的修正子会话仍串行跑了约十分钟 mix test（17:54–18:04 本机时间），统筹会话的暂停通知没有来得及生效；已告知 voxim-d4。教训：子会话在途时收到暂停请求，光发消息不够，要确认它停了或直接停掉它。
  它同时告知：**生产已切换到 `20261112-qinglan`（ex master `29531ea4`，协议 44），不含 `npc-life-20261111`；生产 NPC 仍 `enabled=0`。** master 已前移，本分支推送前的 rebase 要对着新的 master 做。
- **测试环境的一件事**：固定测试库名会跨次运行串数据（cid 每个 VM 重新起算，撞上上一次留下的行，首版第一次跑因此有 1 个既有用例失败、复跑通过）；之后每次运行换新库名。
- **环境**：本线新起的只有临时库容器 `npc-s1y-pg-20261114`（postgres:16-alpine，`127.0.0.1:55453`，匿名卷 `9f38166ed6b0759d108c4879b8c952c09b60f49c8c09eb36e78a67006f56861f`；起之前容器 37 / 卷 19，之后 38 / 20；已告知 voxim-d4），R3 的单元测试用，测试库名 `npc_s1y_unittest`；
  **R3 收尾提交后已按名字删掉这一个容器与这一个卷，容器 / 卷数回到 37 / 19。** Hindsight 容器 `npc-s1g-hindsight-20261113` 照旧在跑。没有起节点、没有起 QUIC。
- **仍等用户定的两件**（§10.11“要用户定的”）：① 新栏放什么（R4 等它）；② 日记里承诺的“当面问 Corvin”没有对应活动。到目前为止用户没有答复。

### 交接（2026-11-14，第十个统筹会话 → 第十一个，因上下文接近 300k）——**第 1、2 项已执行完，状态以上面“第十一个统筹会话的进展”为准**；任务书 `.demo/observe/npc-slice1-20261112/handoff-11-brief.md`

**一句话**：S1-X2 的盲判、判定、独立评审都做完；评审的四项阻断用补测 S1-X3 与网关核实解决或给出了处理；反思模块的更正与六步拆分写进了内容规范 §10.11、§10.12；**R1、R2 两步的代码已写好，但没有编译、没有测、没有提交**——voxim-d4 对编译许可两次都没有答复。分支未推送。

**用户 2026-11-14 的新指示（原话，第十个会话写完交接时收到）**：“以后编译不用再问，直接可以编译”。对应：**NPC 线在 WSL 里编译、跑 mix test 之前不必再问 voxim-d4、也不必等它答复**（取代此前“每次编译前先问它并等答复”）；已告知 voxim-d4。
不变的：起长时间节点或占固定端口之前照旧先告知它；不并行跑 mix；重型进程与 UDP 预算照全局 CLAUDE.md。下面“下一步”第 1 条里“拿到编译许可”因此作废，直接编译。

**工作区里未提交的东西（都属于本线，不要删；测过才提交）**
- R1（回报与取舍 `.demo/observe/npc-slice1-20261112/s1y/r1-report.md`）：新增 `apps/npc_server/lib/npc_server/life/reflection.ex`、`apps/npc_server/test/npc_server/npc_reflection_test.exs`、`apps/npc_server/test/support/fixtures/reflection/`（夹具、`README.md`、`regenerate.py`）。
- R2（回报与取舍 `s1y/r2-report.md`）：新增 `apps/npc_server/lib/npc_server/life/reflection/writer.ex`、`apps/npc_server/test/npc_server/npc_reflection_writer_test.exs`、`apps/npc_server/test/support/http_stub.exs`、夹具 `…/fixtures/reflection/gateway-response.json`；
  **修改了现有文件** `apps/npc_server/lib/npc_server/http.ex`、`apps/npc_server/lib/npc_server/life/hindsight.ex`、`apps/npc_server/test/npc_server/npc_hindsight_test.exs`（现有 Hindsight 测试换了共用替身，编译许可到了先跑它）。

**下一步（按此顺序）**
1. **直接编译**（用户已说编译不用再问，见上）：另派一个新的短子会话在 WSL 里编译并跑 R1、R2 涉及的测试文件（`npc_reflection_test.exs`、`npc_reflection_writer_test.exs`、`npc_hindsight_test.exs`，再加用到 `Http` 的 `npc_jev_test.exs`），修错、`mix format`，每步测过再本地提交。不许为了过测试改期望或改夹具里的真实数据。
2. **R3 之前先量一件没测过的事**（`s1y/r2-report.md`）：产品的 `retain/2` 逐文档要求事实数 > 0，否则整次失败；反思库在产品里是一个**空库**（不写 mission、不建四份认识），Hindsight 缺省抽取会不会给反思文档抽出事实没有测过。在真实 Hindsight 上建一个空库（本线命名、用完按名字删）、写一两条 S1-X2 的真实日记、读事实数；期望先写。若为 0，存档的做法要改（报用户之前先想清楚整条链，不要在 `retain` 上打补丁）。
3. **R3 接进 Life**（§10.12）。两份回报末尾各有“下一步要知道的事”；R1 回报里子会话自己定的 8 条取舍、R2 的 6 条要先核对（尤其 R1 的第 1 条 `event_waiting`、第 2 条 `causes`）。做完派不带结论的独立代码评审再提交。
4. **R4 新栏要等用户答复** §10.11“要用户定的”第 1 条（新栏放什么）；第 2 条（“当面问 Corvin”没有对应活动）同样未答复。第十个会话结束时两条都**没有答复**；没有答复不要按建议自行实现 R4。
5. R5、R6（闭环实跑才谈得上验收）；其后是原始单位与坐标的写法、S1-T 暴露的七件事。仍然不做的各项同上一份交接。

**环境（2026-11-14 交接时）**：本会话没有编译、没有跑 mix、没有起任何进程或容器；发过的网络请求只有 Jev 156 次（S1-X3）与 magpie 网关 8 次（网关核实）。容器、卷、bank 与上一份交接相同（本线容器只有 `npc-s1g-hindsight-20261113`）。voxim-d4 交接时显示 idle，两条询问都在它的收件箱里。

### 交接（2026-11-13，第九个统筹会话 → 第十个，因上下文接近 300k）——**已执行完，状态以上面第十 → 第十一的交接为准**；任务书 `.demo/observe/npc-slice1-20261112/handoff-10-brief.md`

**一句话**：第二次真实实跑 S1-T 做完并判定（14 条期望 13 成立、1 条部分成立；三步产品提交在真实服务端都走通）；反思的第二轮离线测量 S1-X2 **已跑完、原始读数已存、还没盲判、还没判定**；用户已授权“测完 → 独立 Fable 5.2 评审 → 没问题就直接实现反思模块”。分支未推送，工作区交接时干净。

**用户 2026-11-13 的指示（原话）**：“测完起一路独立fable5.2评审结果科学性合理性可玩性，没问题了之后就着手实现吧，这将是一个激动人心的里程碑模块，请你务必细心。”

**用户 2026-11-13 交接时的新要求（原话）**：“请你以后自动开新会话”。对应：统筹会话上下文接近 300k 时，写完交接与任务书、本地提交之后，**自己用 Orca CLI 在本 worktree 开下一个统筹会话并把任务书交给它**，不再停下来请用户开；做法写在 `handoff-10-brief.md`“换会话由你自己做”一节，以后每份任务书都带这一节。第十个统筹会话就是第九个这样开出来的。

**下一步（按此顺序）**
1. **S1-X2 盲判**（另派，只读 `s1x2/judge/`，不知道期望）→ 代存 `s1x2/blind-judge.md`。
2. **S1-X2 逐条判定** → `s1x2/results.md`（期望 Y1–Y10 在 `s1x2/plan.md`，一条不改）。没有这个文件就是还没判。
3. **独立评审**（另派 Fable 5.2；给计划、原始读数、日记原文、内容规范 §10、S1-T 导出，**不给统筹会话的判定**）→ 代存 `s1x2/independent-review.md`。看科学性、合理性、可玩性。
4. **评审没有问题就实现反思模块**（不必再问用户；有问题先解决，解决不了报用户）。先出实现拆分方案再派；每步先测再本地提交。拆分的起点见内容规范 §10.2 与 §10.9–§10.10 的定稿：Life 的后台任务（慢 worker，不在选择热路径）、单独的反思库、新栏 `What I have come to think`、触发计分。
   **S1-X2 的做法里已经定下、实现要照做的**（`s1x2/plan.md`“做法”与“运行前补记”）：材料四块；“发生过的事”必须同时带 Life 手里**未封存的近期经历**（立即触发那一刻拆屋事件还不在 Hindsight 里）；一轮的“此刻”对齐到同一时刻；同一轮按 小屋 → 人 → 自己 串行写、后一问看得到本轮前几问；
   句数与 `Used` 由代码检查、不合格重问一次、仍不合格丢弃；只问有新经历的对象；读回按文档 id（不经召回）。
   **实现要在 WSL 里编译与跑 mix test：每次之前先问 voxim-d4 并等它答复**（它在做真实客户端冒烟，冒烟期间全机不编译）。
5. S1-T 暴露的、要另开任务的七件事（`s1t/results.md`“计划外看到的”）：写库时召回被拖慢并贴近 10 秒上限、认识文档的审阅体与体积、认识刷新跳过读原始记忆、相遇条与 `During it:` 重复、名字缺失两处、过时的归纳、重建后一直守屋。排在反思实现之后或并行另派，由统筹会话定。
6. 仍然不做：环境气温与风速的读口；所有权泛化；C 类所见；约定、“多久没跟人相处”、关系史一句。推送前须核对 CI 并向用户确认；不部署。

**S1-X2 原始读数里统筹会话已经看到、但还没经盲判的事（只是提示，不是判定；判定以盲判与 `results.md` 为准）**
- 进链 11 条都是 4 句、无 Markdown、无元话语词；Q_place 5 次里 3 次第一次写了 5 句要重问，第 5 轮两次都是 5 句被丢弃——“至多 4 句”对小屋这一问偏紧。
- 新栏对选择的作用很强且方向一致：第 2–5 轮无人处境从 `guard_hut`（.56–.85）整体翻成 `gather_stone`（.84–.98）；日记写的正是“别再干站着守，去屋旁石料堆采石、屋在视线里”。Corvin 在场仍是对质（.92 → .76）；Tobin 在场从守屋翻成采石。
- 新栏增加 1,819–2,327 字，**超过 Y9 写的 1,600 字**。
- 日记里照抄了 prompt 里的原始数量与坐标（`6660096`、`3457024`、`(25, 510, 36)`）——`Right now` 用的是产品现行的 `Current situation` 原文（背包按原始单位、建筑带坐标）；这是可玩性问题，要在实现方案里定怎样给（独立评审要看这一条）。
- 第 3–5 轮的日记反复写“我说过要去采石却又去守屋了”——离线测量里选择并没有受反思影响（计划“局限”里写了），所以他一再发现自己没照做；闭环要等实现后的实跑。
- 反思库里每条反思仍被 Hindsight 抽成 3–7 条事实与认识（11 份文档 → 66 个节点）；读回按文档 id 所以没影响，但以后若对反思库做召回要先量。每次存库都要付一次抽取的费用。
- Hindsight 的 `/stats` 有 60 秒缓存，刚写完读到的是旧值；脚本改成了 `?refresh=true`。产品代码里凡是用 `/stats` 判断“巩固做完没有”的地方要核对同一问题（没查）。
- 网关没带思考参数却报了 `thinking_tokens`，`output_tokens` 超过 `max_tokens` 400——没核实。

**环境（2026-11-13T18:00Z 交接时）**：没有节点、tmux、临时 PG、遗留进程；容器 37、卷 18（= S1-T 起前）；UDP 86。本线容器只有 `npc-s1g-hindsight-20261113`（127.0.0.1:18933）。
bank 新增：`npc-life-371636310017`（S1-T 的真实导出原件，108 份文档，**不删**）、`s1x2-copy-20261113`（经历副本库，60 份文档）、`s1x2-refl-20261113`（反思库，11 份）；其余同上一次交接（`npc-life-312999940097` 也**不删**）。
voxim-d4 已恢复，在做真实客户端冒烟（docker，端口 27200–27203）；它知道 S1-T 节点已停。

### 第十个统筹会话的进展（2026-11-13 起，会话 ex-mmo-cluster-npc-dc）——上面“下一步”第 1–4 项的状态以这里为准

- **第 1 项 盲判：已做。** 另派 Opus 5.5 子会话，只读 `s1x2/judge/`、不知道期望；回报原文代存 `.demo/observe/npc-slice1-20261112/s1x2/blind-judge.md`（页首有统筹会话的两处事实补注）。
- **第 2 项 逐条判定：已做**（`s1x2/results.md`，写于独立评审回来之前、没有给评审看）。**Y1–Y10：7 条成立（Y1、Y3、Y4、Y5、Y7、Y8、Y10）、2 条部分成立（Y6、Y9）、1 条落空（Y2 出处）**。
  落空与保留：Y2——盲判在 11 条里的 8 条各记了 1–2 处找不到出处的断言（明确的两处：`eight visits`、`once within a metre`）；Y9——新栏增长 1,819–2,327 字，全部超过写下的 1,600；Y6——最后一轮对屋 / 对人没有读数（小屋那问被丢弃、Corvin 那问被跳过）；
  Y5 按写下的两项判据成立，但盲判记了“说不再干守 → 又守 → 再发誓”连续三轮（离线测量里选择不受反思影响所致）；Y7 只有第 3–5 轮可判（都成立），第 1、2 轮盲判的表态套不上期望写的两类，不判。
- **第 3 项 独立评审：已做。** 另派 **Fable 5.2** 子会话，没有给它统筹页、盲判、判定；回报原文代存 `s1x2/independent-review.md`。**结论是“修掉下列几项后可以实现”，不是“可以直接实现”。**
  它核对通过的：输入全部来自真实导出（基准 state 与原文件逐字节相同）、副本库截断正确、触发时刻它独立重算得到同样的 7 个、没有生造。
  **阻断 4 项**：① 新栏里留着过时且与此刻事实相反的条目（Corvin 那问第 2、3、5 轮被跳过，第 1 轮写的“地还空着、要重建”一直留在栏里；丢弃后沿用旧条同理）；② Y9 落空，句数检查管不住长度（进链各条 104–155 词，靠长复句装进 4 句）；
  ③ 新栏的作用是内容被读懂还是“三条重复 + 活动原词”的显著性，这次分不开（V 处境日记写要当面问，对质却 .92 → .76、采石多出 .215，是反证），要补一组只问 Jev 的对照；④ 计划写“不开扩展思考”实际没执行（响应里有 `thinking` 块，`output_tokens` 超过 `max_tokens` 400），产品的调用参数要钉成测过的条件。
  **实现时必须处理 8 项**（写进实现方案）：闭环实跑作为验收且期望先写；反思异步落栏的时刻；日记承诺的 `ask Corvin` 没有对应活动（请用户定）；“有新经历”的定义（例行的无人重复活动算不算、计不计分）；反思库文档与 Life 缓存谁是权威、文档 id 要带对象；丢弃 / 重问 / 跳过要有日志与计数；原始单位与坐标在产品的 state 渲染处改（一处出处）；成本预算。
  另有 9 项记录备查（原文第四节）。与统筹会话判定的两处不同：Y2 它判“机器部分成立、人读部分拿不准”（统筹会话按盲判记为落空）；Y7 它把第 2 轮也算成立（统筹会话按盲判的归类不判第 2 轮）。
- **第 4 项 实现：还没开始。按任务书“评审有问题先解决”，先解决阻断项**：
  - 阻断 ③ 与 ①、② 的新栏形态：**补测 S1-X3**（只问 Jev，不新写日记；用 S1-X2 的日记原文做删减 / 换位置；39 个变体、156 个请求）。计划与 9 条期望 X1–X9、“读数怎样用”都在发问前写定：`.demo/observe/npc-slice1-20261112/s1x3/plan.md`。
    脚本将在 `docs/10-active/cross-cutting/tools/jev/s1x3_variants.py`，读数落 `s1x3/`。**已派出，没有 `s1x3/results.md` 就是还没判。**
  - 阻断 ④：网关的思考与 `max_tokens` 核实（≤ 10 次请求，原始请求响应落 `s1x3/gateway/`）。**已派出。**
  - 阻断 ①、② 的设计决定（过时条目怎样失效、长度上限改成什么）等 S1-X3 读数出来后由统筹会话给建议；其中**要改用户定过的“每个问题最新一条都进栏”（内容规范 §10.8 第 3 条）的部分要报用户定**。提示词若改（长度上限、关思考），小屋那一问要小规模重写复测（还没计划）。
- **S1-X3 已跑完、已判定（2026-11-14T00:26Z；探索性）**：`s1x3/results.md`。156 个请求全部应答；`s1x2/` 未被改动。**9 条期望 6 成立（X1、X4、X6、X7、X8、X9）、3 落空（X2、X3、X5）**。
  要点：一条与三条对选择的作用相同，过时的那条去掉与否几乎不变；起作用的是打算里的活动词（写着“今晚先守、之后采石”的那条照样推向采石——X2 落空）；Corvin 在场时带整条日记的形态都把对质压低 .11–.33；
  最短的形态（“自己”一问的收尾一句，约 260 字）最温和——无人时采石 .73–.84、Corvin 在场对质 .905、Tobin 在场守屋与采石各半（这是事后的读法，没有事先写成期望）。事先写的“读数怎样用”两条分支的条件都不满足，新栏形态不由计划自动得出。
- **网关核实已做**（`s1x3/gateway/report.md`，8 次请求）：magpie 网关把思考参数与 `max_tokens` 都丢掉，S1-X2 实际是在模型默认的自适应思考下写的；产品照同样的请求体发就是测过的条件，不需要因此重测写作。
- **对评审各项的处理与实现拆分已写进内容规范 §10.11、§10.12**（未实现）。统筹会话定的：提示词不改；代码句数上限放到 5（提示词仍写 4）；各问最新一条与触发状态以 Life 的持久行为准、反思库只是存档（产品不需要“按文档 id 读回”）；触发与“有新经历”照测过的规则不改、空转在闭环实跑里看；
  原始单位与坐标在产品渲染处改、列为反思核心之后的独立任务；验收是实现后的真实闭环实跑。拆分六步 R1（纯函数核心）→ R2（写日记的客户端 + Hindsight 补两个函数）→ R3（接进 Life）→ R4（新栏）→ R5（全套与文档）→ R6（闭环实跑）。
- **等用户定的两件（§10.11“要用户定的”；不挡 R1–R3）**：① 新栏放什么——统筹会话建议只放“自己”一问的收尾那句打算并标上多久以前想的（要改 §10.8 第 3 条）；② 日记里承诺的“当面问 Corvin”没有对应活动——建议先接受、闭环实跑里看。**R4 要等 ① 的答复。**
- **已向 voxim-d4 申请 R1 的编译许可（2026-11-14，问了两次），到本会话结束都没有答复；没有编译、没有跑 mix。**
- **R1（纯函数核心）与 R2（写日记的客户端、Hindsight 的 `ensure_bank/2` 与失败日志带 bank）已写好——已实现、未编译、未测、未提交。** 文件清单与下一步见页首交接；子会话回报代存 `s1y/r1-report.md`、`s1y/r2-report.md`。
  R1 的子会话用 Python 照模块规则重算过 7 个触发时刻、各轮的问题、两份用户消息与系统提示词，与真实读数逐字节一致（Elixir 本身没跑过）。R2 核对的结论：现有 `recall/3` 够用不改；`retain/2` 逐文档要求事实数 > 0，对“空的反思库”是否成立没测过（页首交接“下一步”第 2 条）。
- **实现前的只读侦察已做**：反思模块在现有代码里的落点 `.demo/observe/npc-slice1-20261112/s1y/code-map.md`（HEAD `dd0aee58` 的行号）。对实现有直接影响的事实：仓库里没有任何 Anthropic `/v1/messages` 调用；Hindsight 客户端没有“按文档 id 读回原文”的函数、`ensure/2` 不分 bank（总会建四份认识）；
  Life 只有一个后台 `job` 槽且失败会停掉后续调度；插入新栏会让 `npc_mind_test` / `npc_selector_test` 里对 state 全文与栏下标的断言失败；产品里没有任何地方用 `/stats` 判断“巩固做完没有”（交接里那条待核对的事到此核完，没有问题）。
- 接手时已告知 voxim-d4（它没有回复的必要）；到目前为止 NPC 线没有编译、没有跑 mix、没有起任何进程或容器。`.demo/` 在 `.gitignore` 里，判定与评审文件只在本地目录，不进提交。

### 交接（2026-11-13，第八个统筹会话 → 第九个，因上下文接近 300k）——**已执行完，状态以上面第九 → 第十的交接为准**

**一句话**：产品侧本会话提交了三步，都过了 npc_server 全套、**都没在真实服务端跑过**：`c47e730b`（说话人名字）、`120a8801`（“看到的”A 相遇 / B 附近的建造拆除）、`c30a1a85`（三路召回 + 新 prompt）。全套 457 通过、18 排除（`s1t/t34-full.log`）。分支未推送，工作区交接时干净。
一次真实实跑 S1-N（旧召回）与其导出上的离线重测 S1-Q、反思重测 S1-V 已做完并判定；第二次真实实跑 S1-T **计划与脚本都备好了，还没起任何东西**。

**本会话里用户新定的（原话见“进展”各条）**
- “看到的”：先做 A、B，C（倒下 / 死亡）暂不做；门槛按草案的原创取值，实跑后调（内容规范 §9.6 末）。
- 反思写回要做（“角色静下心来深度思考的途径，能形成高级记忆”）——**设计还没写，写完要用户点头才实现**。
- Hindsight 改用本机 magpie 网关的 Sonnet 5.5（`http://127.0.0.1:3425`，容器里写 `host.docker.internal`；key 不落文件；强度 抽取 low / 缺省 medium / 反思 high 是统筹会话定的）。记录 `s1g/services-20261113-magpie.txt`。
- Docker 清理做过一次，范围是用户经提问框选的；**“禁止 prune、只按名字删、受保护对象不碰”不变**。构建缓存 30.79 GB 没动（只能 prune）；按名字多留了 3 个像如园的对象没删（`docker-cleanup-20261113/held-back.txt`），等用户说。
- voxim-d4 被用户暂停，它此前“冒烟期间全机不编译”的要求因此解除；它恢复后以它当时的消息为准，起节点前照旧先告知它。

**用户对反思写回五件事的答复（2026-11-13，原话）**：“1 必须通篇都是角色口吻。这个通过系统提示词来控制，提示模型要按照角色口吻输出，你可以搜一下网上，很多这种角色扮演的提示词的。2 反思可以参考 ai 小镇吧？他们没解决这个问题吗？可以搜搜近年的高引论文。3 要，反思本就是对记忆的一种整理。4 参照论文。5 不知道，可以单独研究一下”
  对应：1 写回的全文都要是角色口吻，用系统提示词控制（参考网上的角色扮演提示词）；2 怎样不淹没原有记忆——先看 AI 小镇与近年高引论文怎么做；3 反思要能读到原始经历；4 触发时机与问什么——参照论文；5 结论打架以谁为准——单独研究。
  **三个调研已回来并存档，设计草案已写进内容规范 §10（待用户定，未实现）**：要用户定的四条在 §10.8——反思改由我们自己调大模型写（Hindsight 的 `reflect` 系统提示词写死、换不了口吻，也不读原始经历）、触发按“代码给分 + 累计阈值”、反思进 prompt 走新增小栏且每问只留最新一条、结论打架先做离线研究。
  调研里一个未查清的现象：换到 magpie + Sonnet 后，Hindsight 的 reflect agent 偶尔在第 2、3 轮不执行被强制的检索步骤（日志 `Forced step … returned no tool call`，换模型以来 13 行）；首轮强制调用在网关上四档强度都正常。**四份认识文档的刷新走同一个 agent，有没有因此少读一层没有核实**，S1-T 实跑时看这条日志的次数。
  **三个只读调研的存档在 `.demo/observe/npc-slice1-20261112/s1w/`**：`research-reflection-papers.md`（AI 小镇的反思机制原文细节与近年论文怎样处理淹没、触发、冲突）、`research-roleplay-prompts.md`（角色口吻的提示词做法）、
  `research-hindsight-reflect.md`（Hindsight 的 `reflect` 能怎样控制口吻、为什么 9 次都没读原始事实、怎样让它读）。没有这些文件就是还没回来。之后据此写内容规范 §10 的设计草案，交用户定，点头前不实现。

**用户对 §10.8 四条的答复（2026-11-13，原话）**：“1 你说得对，反思我们从 hindsight 摘出来自己做吧，只是会读和写 hindsight。2 同意。3 同意。4 同意”。设计方向已定，**实现前先离线测量 S1-X**：计划、定稿的系统提示词与 8 条期望在 `.demo/observe/npc-slice1-20261112/s1x/plan.md`（发问前写定）；
  新副本库 `s1x-copy-20261113`（本线建的）；脚本将在 `tools/jev/s1x_reflect.py`，读数落 `s1x/`；执行已派出，盲判由统筹会话在读数回来后另派；判定写 `s1x/results.md`，没有那个文件就是还没判。S1-X 跑完之前不要起 S1-T（共用 Hindsight 与网关）。

**S1-X 已做完并判定（`s1x/results.md`；探索性）**：8 条期望 3 成立（出处贴线、读了原始经历、同题一致）、5 条落空或部分落空。口吻靠自己的系统提示词做到了（无元话语、无 Markdown，但 2 / 12 条超过 4 句）；写进经历库仍淹没并走样（3 条 → 14 条事实 + 13 条认识，占无人处境召回的一半）；
  新栏放三条时无人处境守屋 .85 → .64，概率流向采石与建造；V 处境的读数受测法缺陷影响（反思材料晚于 V 基准时刻、含那次对质）；材料里没有“此刻的处境”，日记因此写“不知道小屋还在不在”。
  **用户已答复四条更正（原话与据此的改动在内容规范 §10.9）**：反思存单独的反思库——同意；材料要带此刻的处境与系统状态量（时间、位置、高度、温度、湿度、风力等，有产生者的才给），并要求从神经科学与心理学找可用的做法；句数由代码卡——可以；
  结论打架——不另设综合一步，改为每次反思都把之前的反思结果（同一件事上次的、其它几件事最新的）带进提示词让他自己综合。**两个调研已回来并存档，据此在内容规范加了 §10.10（反思的材料分四块、状态量三类、写法纪律；待用户过目）**。要点：时间 / 位置 / 高度 / 身体（含失温、过热、饥饿、伤病）/ 附近的人 / 建筑现状今天就能给；环境气温与风速服务端有、要接一个读口；湿度、降水、光照、季节、室内外、体力、睡眠在服务端不存在，不给。文献调研只核到检索摘要。**下一步是写 S1-X2 的计划（还没写）**。原派出记录：：`s1w/research-neuro-psych.md`（神经科学与心理学里记忆整理 / 反思的可用做法）、`s1w/research-npc-state.md`（NPC 一侧现在拿得到哪些状态量、哪些没有产生者）；没有这两个文件就是还没回来。之后写 S1-X2 的计划。
  **更正建议四条在 `s1x/results.md` 末节，待用户定**：反思存进单独的反思库、材料带此刻的处境、句数由代码卡、结论打架倾向“综合一步”但要再测一轮（S1-X2：材料截止到各处境的时刻、带处境、综合时给材料要点）。**S1-X2 还没写计划、没派。**

**读数要点（都是探索性，不算验收；判定文件为准）**
- S1-N（`s1n/results.md`）：写入侧整条链通（期间事实、人名、tags、逐条成文档、mission）；旧召回又慢（4–6 秒，3 次超时）又被重复的“守屋没人来”占满，无人时拆屋事件 0 行。
- S1-Q（`s1q/results.md`）：三路 + 认识优先 2.3–2.8 秒、选择不变；合并规则定为“各路保持 Hindsight 返回次序、每路前 4”；无人时起作用的是四份认识而不是召回行；mission 必须留。**这些是旧模型（gpt-5.6-terra）下的读数。**
- S1-V（`s1v/results.md`，第二次执行在新模型上）：7 条期望 5 成立、V2 后半与 V6 落空。反思有立场且稳、Corvin 在场仍对质；但反思只读认识文档不读事实、带小的数字错、写回 3 份就多出 29 条认识并占满召回、文体是“审阅记录”而不是角色口吻；写回后无人时 `guard_hut` 0.86 → 0.63，方向与写回的那段“继续守屋”相反。
  统筹会话的判断：可以进入设计，但不能把 `reflect` 原文直接写回；要定的五件事列在 `s1v/results.md` 末节。

**下一步（按此顺序；2026-11-13 交接时更新，以这一版为准）**
1. **真实服务端短实跑 S1-T**（已备好、最该先做：三步产品提交都还没在真实服务端跑过）：计划 `.demo/observe/npc-slice1-20261112/s1t/plan.md`（14 条期望运行前写定，末尾“运行前补记的前提”必读），脚本 32 个在 WSL `~/npc-s1-run/*-s1t.*`（副本 `s1t/scripts/`，做法 `s1t/prep-report.md`；三个新 `.exs` 没经过编译器，起节点后先各求值一次）。
   起之前：告知 voxim-d4；核对 HEAD 的 `apps/` 与 `c30a1a85` 相同；记主机 UDP 基线；Hindsight 就绪且 magpie 网关可用（额度与各会话共用）。新 PG `npc-s1t-pg-20261113`（127.0.0.1:55465）。按 S1-N 的四段派子会话，结果代存 `s1t/`，判定写 `s1t/results.md`。
   实跑时顺带看：Hindsight 日志里 `Forced step … returned no tool call` 的次数（认识文档刷新有没有少读一层，未核实）。
2. **反思的下一轮离线测量 S1-X2**（设计已由用户逐条定，见内容规范 §10 全节，尤其 §10.9、§10.10 与其后的定稿；**计划还没写**）。要点：材料分四块（此刻的事实 / 发生过的事 / 之前的想法，标明不是事实 / 今晚要想的问题）；此刻的事实只用今天就拿得到的量（`s1w/research-npc-state.md` 的清单 ①，气温风速不接）；
   每次反思带上同一件事上次的想法与其它几件事最新的想法，不另设综合一步；反思存进这个 NPC **单独的反思库**（不进经历库）；句数上限由代码卡、超了重写一次；问法具体、以可执行的打算收尾；材料与反思的“现在”要和所用的基准 state 的时刻对齐（S1-X 的缺陷）；连续几轮看是否自洽、稳定、不原地打转。
   期望先写；盲判另派；站得住才实现。S1-X 的脚本 `tools/jev/s1x_reflect.py` 可复用。**不要与 S1-T 同时跑**（共用 Hindsight 与网关）。
3. S1-T 导出后：在真实导出上看“每路前 4”留不留得住关键认识、相遇条与 `During it:` 的重复去哪一个、各门槛怎么调；过时的归纳（“小屋已不存在”）Hindsight 为什么没更新。
4. 反思测量站得住之后：实现拆分（Life 的后台任务、反思库、新栏 `What I have come to think`、触发计分），先出方案再派。
5. 仍然不做：环境气温与风速的读口（用户：之后再接）；所有权泛化（用户：NPC 不能持有保护区）；C 类所见；约定、“多久没跟人相处”、关系史一句（没有产生者）。规划层与“Plans and promises”的内容来源还没开始。
6. 推送前须核对 CI 并向用户确认（第六个会话的交接里有 rebase 冲突提示）；不部署。

**环境（2026-11-13 交接时）**：没有节点、tmux、临时 PG、遗留进程。本线容器只有 `npc-s1g-hindsight-20261113`（127.0.0.1:18933，已是新模型）。bank：`npc-life-312999940097`（S1-N 的真实导出原件，**不删**）、`s1q-nomission-20261113`、`s1v-copy-20261113`（旧模型副本）、`s1v-copy2-20261113`（新模型副本，含写回的反思）、`s1x-copy-20261113`（新模型副本，含 3 条写回的日记）、`smoke-magpie-20261113`、`smoke-s1g`、`s1i-m0/m1/m2`、`s1l-m1/m2`（后几个是手写材料库，不作依据，可按名字删）。
Docker 现有 37 个容器、18 个卷、约 81 个镜像；受保护的 23 个如园容器都在。给用户的通俗说明页 `.demo/observe/npc-slice1-20261112/npc-structure-20261113.html`（写于三路召回提交之前，召回与 prompt 两节已过时）。

### 第九个统筹会话的进展（2026-11-13T16:20Z 起，会话 ex-mmo-cluster-npc-d8）——上面“下一步”第 1、2 项的状态以这里为准

- **S1-T 已实跑完、已判定、已收尾（已实跑，不算验收）**：判定与链路表 `s1t/results.md`；子会话回报 `s1t/seg1-report.md`、`seg2-report.md`、`seg3-report.md`；机器读数 `s1t/readings.txt`；导出 `s1t/export/`（含 `rawobs/` 64 份原始观察）。
  节点 `npcs1t` 16:25:34Z 起、17:25:51Z 由统筹会话停；tmux 已关；`npc-s1t-pg-20261113` 与其匿名卷已按名字删；容器 / 卷回到 37 / 18，UDP 86（基线 90）；voxim-d4 已告知。
  Garen cid **371636310017**（bank `npc-life-371636310017`，108 份文档，**不删**，它是之后重测的原件）；Corvin V = 1011812929538；Tobin T = 1285994582019。
  **14 条期望：F1–F4、F6–F13 成立，F5 部分成立**（召回行一直是 8 条；含 `nobody` 的在第 ③ 段内 4 / 8，之后多跑的 59 次是 5 / 8，超过一半）。三步产品提交在真实服务端都走通：三路召回（100 份文档后中位数 2.5 秒、无超时）、新 prompt（中位数 15,472 字）、相遇 / 附近挖格的所见、说话的经历（说话人带名字）；
  无人时拆屋事件每次都回得来（S1-N 是 0 行）；Corvin 回来第 1 次就 `confront_wrecker`。三种夹具动作都做到了。时间线调整一处（期望未改）：第 ③ 段后多跑约 35 分钟让库过 100 份，才有 F2、F3 的读数。
  **计划外、要另开任务的**（`results.md`“计划外看到的”，都没查原因）：① 写库那一分钟里的那次召回 4–9 秒（最慢 9240 毫秒，贴近每路 10 秒上限），且耗时随库增长（41 份 0.7 秒 → 105 份 2.5 秒）；② 新模型刷新出的认识文档是审阅体 Markdown（第一版 `self` 是“记录里还没有内容…`skepticism=3`…”），四份合计约 10,700 字、占 state 约七成；
  ③ 认识刷新会跳过读原始记忆那一步（日志 17 行 `Forced step … returned no tool call`，其中 8 次 `answering without it`）；④ 相遇条与 `During it:` 把同一件事说两遍；⑤ 名字缺失两处（说话对象写成 `actor <自己的 cid>`、情绪栏人不在附近时没有名字）；⑥ 过时的归纳“小屋已不存在”重建后仍被召回；⑦ 重建后 55 分钟全部 `guard_hut`（101 / 114），一次广场没去。
- **统筹会话在 S1-T 里加的三个只读脚本（不改状态、不涉及 14 条期望）**：`s1t/scripts/rawobs-s1t.exs`（把 Life 手里的原始观察落盘到 `s1t/export/rawobs/`）、`rawobs-loop-s1t.sh`（tmux 窗口 rawobs，每 60 秒一次、最多 150 次、节点停了自退）、`hindsight-docs-s1t.sh`（第 ④ 段导 bank 配置与文档列表）。
  子会话修了 `dig-s1t.exs` 一处括号语法错（逻辑未变）。
- **S1-X2 的计划与 10 条期望已写定**：`.demo/observe/npc-slice1-20261112/s1x2/plan.md`（发问前定稿；提示词定稿在其中）。输入改用 S1-T 的真实导出（现行 prompt、含所见与说话、有原始观察）；反思时刻由 §10.3 的规则从真实经历序列算出，取前 5 个做 5 轮；
  经历副本库 `s1x2-copy-20261113` 截到各时刻、反思存单独的 `s1x2-refl-20261113`（本线建的）。写计划时发现并写进做法的一处链路缺口：**立即触发的那一轮，拆屋事件还没封存、不在 Hindsight 里，材料必须同时带 Life 手里未封存的近期经历**。
  计划末尾“运行前补记”另定了四处细节（发请求之前；期望未改）：一轮的“此刻”= 触发后第一份 state 的时刻 t′；同一轮按 小屋 → 人 → 自己 串行写、后一问看得到本轮前几问；`Used` 不合格与句数超限同样重问一次；规则在最终导出上给出 7 个时刻、做前 5 个（表在计划里）。
  脚本 `docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py`（约 1,870 行，离线自检全过；联网路径在正式运行前没跑过）。**正式运行已做完（17:28–17:51Z，全部阶段成功，无额度或连接错误）**：原始读数与对脚本的唯一修改（`/stats?refresh=true`）在 `s1x2/run-report.md`；日记原文 `s1x2/reflections/`、`extra/`；盲判材料包 `s1x2/judge/`；机器读数 `s1x2/results.json`。
  **盲判还没派、判定还没写**（没有 `s1x2/blind-judge.md` / `s1x2/results.md` 就是还没做）——交给第十个统筹会话，见页首交接。
- **用户 2026-11-13 的新指示（原话，S1-T 第 ③ 段进行中时说的）**：“测完起一路独立fable5.2评审结果科学性合理性可玩性，没问题了之后就着手实现吧，这将是一个激动人心的里程碑模块，请你务必细心。”
  对应：S1-X2 测完并判定后，**另派一个独立的 Fable 5.2 评审**（看测量结果的科学性、设计的合理性、可玩性；不给它统筹会话的结论）；评审没有问题就**直接着手实现反思模块**，不必再等用户点头（取代此前“实现前向用户报告”）；评审有问题则先解决或报用户。实现要格外细心。
- voxim-d4 已恢复：它要求 S1-T 节点运行期间 NPC 线不编译、不跑 mix test（已答应并遵守）；**节点停了之后要告诉它一声**。它的冒烟服务端在 docker 里，端口 27200–27203。

### 第八个统筹会话的进展（2026-11-13 起）——接手先读这一节；下面第七个会话的“交接”里“下一步”第 1、2 项的状态以这里为准

- **第 1 项（补核 + 修说话人名字）已做，已提交 `c47e730b`（未推送，未在真实服务端实跑）**。`b41c0590` 里 `life/state.ex`、`dialogue.ex`、`registry.ex`、`runtime.ex`、`selector.ex`、`mind.ex` 与
  `npc_life_state_test`、`npc_dialogue_life_test`、`npc_life_test` 的 diff 逐行看过，除说话人名字外没有发现新缺陷（`README.md`、`npc_registry_test`、`npc_selector_test`、`npc_dialogue_world_test` 的 diff 没看）。
  修补：`Dialogue.episode/3` 的说话人名字取消息自带的 `speaker_name`（也覆盖观察里的），对象仍只取观察。测试（WSL）：dialogue 三个文件 21 通过；npc_server 缺省全套 430 / 431 通过、18 排除——
  唯一失败是 `NpcEmotionMovementTest` 因本次脚本没设 `NPC_LLM_URL` 而报 `System.EnvError`，带占位的 `NPC_LLM_*` 单独跑通过；**没有带这些变量重跑全套**。日志 `.demo/observe/npc-slice1-20261112/s1n/fix-speaker-*.log`。临时 PG `npc-s1p-pg-20261113` 已删。
- **第 2 项（“看到的”规范草案）已写，待用户定，未实现**：[内容规范](2026-11-13-npc-mind-content-spec.md) §9——三类所见（A 相遇、B 附近的建造 / 拆除、C 倒下 / 死亡，C 要改 Body），每类的产生者、存储、进 prompt 的路径、成条时机与频率上限；门槛都是原创取值。
  要用户定的五条在 §9.6，**用户已答复“可以，都没问题”**（先做 A、B，C 暂不做；其余按草案；逐条见 §9.6 末）。**A、B 尚未实现**：实现要在本 worktree 跑 WSL 测试，等 S1-N 节点停了再派。
  用户同时问“召回太多，能否用 LLM 精炼记忆、Hindsight 有没有自带”：实跑库里 Hindsight 已自动巩固出 9 条认识类事实（`fact_type: observation`，如 `I guarded the small hut 66 times; nobody came near during any of the watches.`、拆屋与对 Corvin 的愤怒各一条），
  而产品现行的一次泛问没有带 `prefer_observations`，拿回来的是上百条原始经历——即精炼已经有了，缺的是召回接线（T4）。是否够用要在真实导出上重测（第 4 项）。
- **第 3 项（真实服务端 NPC-only 短实跑 S1-N）进行中**：计划 `.demo/observe/npc-slice1-20261112/s1n/plan.md`（13 条期望运行前写定；四段；新 PG `npc-s1n-pg-20261113` 127.0.0.1:55462，复用 Hindsight 容器 18933，bank `npc-life-<cid>` 不删）。
  - **第 ① 段已实跑（未验收，明细 `s1n/seg1-report.md`）**：节点 `npcs1n`（tmux `npc-s1n`，2026-11-13T07:12:50Z 起，看门狗 09:42:50Z 无条件停）；被测 NPC `S1NGaren` cid 312999940097，bank `npc-life-312999940097`；小屋 07:14:45Z 建成。
    到 07:25Z：24 次选择（建成后一直 `visit_plaza`），活动经历 20 / 20 条带 `During it: nobody came near.`；没有崩溃、`job_error`、`empty_facts`；还没有发生自动封存（bank 文档数 0）；UDP 端点 95（基线 93）。
  - **第 ② 段第一次派出的子会话中断了**（额度用尽，没有回报）：它只做完 07:26:53–58Z 的破坏与 Corvin 离场（V = 3494090117122，读回 0 格）。之后约 48 分钟无人操作，节点照常跑：Garen 07:27:39Z 重建 → `visit_plaza` ×13 → 07:34:55Z 起一直 `guard_hut`。
    偏差已记在 `s1n/plan.md` 末尾“运行中的偏差”（期望一条未改）。08:15Z 重新派出一个子会话连续做 ② 余下三步与 ③，并在末尾做需要节点的导出；结果回来后存 `s1n/seg23-report.md`。
  - **无人照看那段的读数（统筹会话从 `s1n/states/` 与 Hindsight 只读得到，逐次计数表 `s1n/chain-raw-0714-0812.tsv`；未验收）**：
    活动经历全部带期间事实（都是 `nobody came near.`，有人在场的还没有读数）；拆屋事件写成 `Corvin (actor 3494090117122) removed the entire building "small hut" …`，带名字。
    自动封存 4 次（07:25、07:34、07:47、08:01Z，各 21–24 条经历），retain 都成功，文档逐条带 tags（如 `kind:activity`、`place:small hut`），`job_error` / `empty_facts` / 崩溃为 0；bank 里三条 mission 都在。
    **拆屋事件封存后在召回行里的条数是 2 → 1 → 0（08:03Z 起为 0）**：36 条召回行里 33–34 条是几乎相同的“守屋，没人来”，把它挤掉了；此后它只经认识文档与情绪栏的 Distrusts 留在 prompt 里。
    **召回耗时随库增长**：按 10 分钟平均 389 → 1386 → 1950 → 2534 → 3229 → 3599 → 4820 毫秒，08:12:58Z 一次 9611 毫秒（与一次 retain 同时）；state 全文从 3.7 KB 涨到 24 KB。
  - **S1-N 已实跑完并收尾（已实跑，未验收）**：节点 08:34:53Z 由统筹会话按节点名停；tmux 已关；`npc-s1n-pg-20261113` 与其匿名卷已删；容器 / 卷回到 154 / 168，UDP 端点 93（= 基线）。
    逐条判定与链路表 `s1n/results.md`；子会话回报 `s1n/seg1-report.md`、`s1n/seg23-report.md`；逐次计数 `s1n/chain-all.tsv`；146 份 state 全文 `s1n/states/`；
    导出 `s1n/export/`（Life.observe、请求模板、bank 配置 / 统计 / 四份认识 / 154 条事实 / 133 份文档带 tags）。**bank `npc-life-312999940097` 留在 Hindsight 容器里不删——它是第 4 项重测的原件。**
    13 条期望：E1、E3–E7、E9、E10 成立；E2 前半成立、后半（去广场时有人在）没发生；**E8 前半落空**（无人在场的 10 次选择里召回行讲拆屋的是 0 行）；E11 按字面落空（Corvin 回来后第 1 次选择因召回超时发问失败，紧接的重试选了 `confront_wrecker` 0.87 并 `completed`；之后他仍在场的 5 次都回到 `guard_hut`）；E12 的条数没读到。
    计划外：① 召回 10 秒超时导致 3 次选择失败，常态召回 4–6 秒（库才 133 份文档）；② 拆屋事件“附近有人才被召回”（问句带人名时 4–13 行，无人时 0 行）；③ Hindsight 已把重复经历巩固成 13 条认识类事实，现行召回没取；④ 认识类事实会过时（“小屋已不存在”在重建后仍在）；
    ⑤ state 21.7 KB 里四份认识占 42%、召回行占 35%；⑥ 被拆重建后第二次封存起从 `visit_plaza` 转为一直 `guard_hut`（0.77–0.89，一小时没回落）。说话的经历本次没有发生，`c47e730b` 仍未在真实服务端走到。
- **第 4 项（在真实导出上重测，S1-Q）已派出，结果未回**（2026-11-13T09:20Z）：计划与期望发问前写定在 `.demo/observe/npc-slice1-20261112/s1q/plan.md`——R 召回方案对照（现行一次泛问 / 加认识优先 / 三路，打真实 bank）、J 各栏对选择的作用（对真实 state 只做删除或换召回行）、M mission 效果（真实 133 份文档重放进不带 mission 的新库 `s1q-nomission-20261113`，本线自己建的，可按名字删）。
  **已做完（探索性，不算验收）**：脚本 `tools/jev/s1q_real_export.py`，判定与对 T4 的含义 `s1q/results.md`，读数 `s1q/results.json`、`raw/`、`variants/`。16 条期望 13 成立、3 落空：
  - R（召回，真实 bank，每格 5 次全稳定）：现行一次泛问复现了实跑（无人时 36 条、讲拆屋 0 条、重复率 0.83、5.9 秒）；加认识优先返回的就是库里全部 13 条认识（重复率 0.08，但仍 6–7 秒）；三路并行墙钟 2.3–2.8 秒。
    **QR3 落空**：三路按“每路 4 条、新的在前”合并，截掉了拆屋事实与“守屋 77 次，没人来”——上一轮“旧的在前”截掉最近的，这一轮“新的在前”截掉最要紧的，**不该按时间排**。QR6 按读数定义落空（过时的“小屋已不存在”也是被配额截掉才没出现）。
    统筹会话用落盘的返回重算了“各路保持 Hindsight 返回的次序、取前 4”的合并（`s1q/remerge-rank-order.json`，不发新请求、**没问过 Jev**）：三种处境都留住拆屋、对 Corvin 的愤怒、“守屋 77 次”，也都带回过时的那条。
  - J（Jev，48 / 48 成功）：三种处境原文复现实跑的选择；无人时删掉全部召回行 `guard_hut` .907 → .893，删期间事实句 → .885，**删四份认识 → .597**（`visit_plaza` .045 → .315）；**QJ5 落空**：记忆栏全空仍是 `guard_hut` ×4（.568），没有变成去广场。
    召回行换成三路的合并清单：N、T、V 的 top1 都不变，state 少 5.5–6.1 KB。
  - M（mission）：真实 133 份文档重放进不带 mission 的新库 `s1q-nomission-20261113`：第一人称 0.49（真实库 0.99），实体里出现 assistant ×22 / user ×3，带次数的认识 1 条（真实库 9 条）。
  - **补测（`s1q/plan-addendum.md`，期望发问前写定；24 / 24 成功；4 条期望全成立）**：把“各路保持返回次序、每路前 4”的合并清单放进真实 state 问 Jev——N、T 仍 `guard_hut`（.90 / .96），V 仍 `confront_wrecker`（.83）；再删掉过时的“小屋已不存在”那条，选择与 `build_hut` 概率都不变。
  - **对 T4 的判断（待用户过目）**：三路 + 认识优先可以接；合并规则用“各路保持 Hindsight 返回的次序、每路前 4、按 id 去重归优先级高的路”；过时的认识不挡接线（留给 T3 的相对时间渲染缓解）；mission 保留；守屋的主要来源是四份认识而不是召回行。
    **T3 + T4（Mind 渲染与三路召回接线）还没派**：要在本 worktree 跑 WSL 测试，排在“看到的”测试跑完并提交之后；实现拆分见下文第七个会话的“第 4 项的实现拆分”，其中 `merge/2` 的规则以这里为准，内容规范 §8 的合并规则随实现同步改。
- **“看到的”A、B 已实现、已测、已提交 `120a8801`（未推送；未在真实服务端实跑）**：新模块 `NpcServer.Life.Sight`（纯函数，进行中的账只在 Life 内存里）+ `life.ex` 接线（每帧观察与每秒 World 读取各喂一次，没有条目时不保存）。
  测试（WSL）：sight / dialogue-life / life / life-state 四个文件 69 通过；npc_server 缺省全套 **447 通过、18 排除**（设了占位的 `NPC_LLM_*`；日志 `.demo/observe/npc-slice1-20261112/s1r/sight-targeted.log`、`sight-full.log`）。临时 PG `npc-s1r-pg-20261113` 与其匿名卷已删。
  实现上的取舍（统筹会话逐行看过并接受，已报用户）：别人拆我的建筑时第一下之后的各下会成为所见（`… that I placed`，不评价情绪）；频率上限按每人每类分开计；`stayed at least <N> m away` 向下取整；写库失败时那几条所见丢掉。
  风险（未处理）：两帧观察间隔超过 5 秒算观察中断，Life 自己被慢写库卡住超过 5 秒时会误判。句式与门槛没有测过，要等下一次实跑导出。
- **T3 + T4（Mind 渲染 + 三路召回接线）已实现、已测、已提交 `c30a1a85`（未推送；未在真实服务端实跑）**：`Mind.recall_queries/2`（R1 最近至多 2 人各一路按 `actor:` tag、R2 最近放下的那座建筑按 `place:` tag、R3 未了与感受；都 `prefer_observations`）、
  `Mind.merge_recalled/1`（各路保持 Hindsight 返回次序、每路前 4、按 id 去重；配额 `@recall_quota 4` 是原创取值）、`Life.mind/2` 在发问 worker 里并行（至多 3 路在途、每路 10 秒，任何一路失败或超时整次失败 `:recall_timeout`）；
  prompt 变七栏：最前加 Now（`It is <morning|afternoon|evening|night>, HH:MM.`），近期经历与召回行句首写 `Just now, ` / `About <N> hours ago, ` / `About <N> days ago, `（游戏钟；措辞取自 S1-K 的 `s1k_design.py`），背包只列非零，召回行去掉 ` | When:` 起的后缀。存进 Hindsight 的正文仍是 `At <UTC> (UTC), …`。
  删掉了 `Mind.recall_query/2` 与 `Hindsight.recall/3` 的字符串入口；`asked.recall_query` → `asked.recall_queries`；`Life.context/2`（LLM 大脑用）签名不变。测试（WSL）：改过的测试文件 90 通过、2 排除；npc_server 缺省全套 **457 通过、18 排除**（`.demo/observe/npc-slice1-20261112/s1t/t34-targeted.log`、`t34-full.log`）；
  真实的 S1-Q 各路返回喂给 `merge_recalled` 得到的 id 与次序和 `s1q/remerge-rank-order.json` 一致（做成了测试）。临时 PG `npc-s1u-pg-20261113` 与其匿名卷已删。
  与任务书不同处（统筹会话看过 diff，接受）：召回行写成 `- Recalled: About N hours ago, <正文>`（规范里的 `- (<多久以前>) <正文>` 没测过，没用）；背包全为零写 `Inventory: empty.`；R2 的建筑取自观察里 Runtime 带的 Life 规范状态，还没有时这次选择以 `:life_not_ready` 失败；没有写“某一路超时”的测试（要多等 10 秒）。
  **下一步是真实服务端短实跑 S1-T：计划与 14 条期望已写在 `.demo/observe/npc-slice1-20261112/s1t/plan.md`（运行前定稿），还没起任何节点或容器；排在 S1-V 跑完之后（两者共用 Hindsight 容器）**
  **S1-T 的脚本已备好（没起任何东西）**：32 个 `*-s1t.*` 在 WSL `~/npc-s1-run/` 与 `s1t/scripts/`；做法、三个夹具动作的正式入口与前提、等待条件的核对在 `s1t/prep-report.md`。新脚本没经过编译器，起节点后先各求值一次。
  计划末尾“运行前补记的前提”记了两处操作次序的调整（夹具动作不另做小验证、只挖不放）与 Hindsight 换模型；期望未改。：一并覆盖三路召回、新 prompt、“看到的”A / B、说话的经历；全新 PG，Hindsight 里新 NPC 的 bank 是新的（cid 重新分配）。
- **反思写回重新提上来（用户 2026-11-13）**：用户原话“反思写回为什么不做了？这个我觉得还挺重要的，因为这里是角色静下心来不受即时决策影响能深度思考的途径，能形成 ai 小镇中所说的高级记忆”。此前搁置的两条原因——离线两轮（S1-I）用的是手写材料（已降为假设）、当时结论不稳定且对选择增量小——第一条现在可以消掉：有真实记忆库了。
  **S1-V（在真实导出上重做反思写回）已派出（约 13:40Z），结果未回**：计划与 7 条期望发问前写定在 `.demo/observe/npc-slice1-20261112/s1v/plan.md`；真实 133 份文档按产品的建法重放进新库 `s1v-copy-20261113`（本线自己建的），三个由代码模板产生的问题各调 Hindsight 的 `reflect` 3 次，取第 1 次写回为 `kind:reflection` 文档，再看它经召回与经四份认识两条路对选择的作用。脚本将在 `tools/jev/s1v_reflect.py`，读数落 `s1v/`。
  **第一次执行中断（2026-11-13T14:05Z 记），V1–V7 都没有读数**：重放与 B0 做完（副本库 152 条事实）；9 次 `reflect` 只有第 1 次成功，其后 8 次 `Connection error`——Hindsight 的大模型网关（它的 `HINDSIGHT_API_LLM_BASE_URL`，`gpt-5.6-terra`）自 13:57Z 起 TLS 握手即断，主机直连同样失败，Jev 与外网正常。
  **这是当前的外部阻塞**：网关不通时 Hindsight 的 retain 抽取、巩固、认识刷新、reflect 全都做不了，所以 **S1-V 重跑与 S1-T 实跑都要等它恢复**；统筹会话不改代理 / 网络设置，只挂了一个每 30 秒探一次、最多 40 分钟的只读探测。
  现状、仅有的两个读数（唯一成功的那次 reflect 依据里事实 0 条、只读了认识文档；副本库上 N 处境的三路合并清单里没有“守了 74 次、没人来”——“每路前 4”留哪条不稳）与**重跑规则**（9 次全部重问、旧的 1 条作废不混用、其余规则不变）写在 `s1v/results.md`。恢复后重跑命令：`s1v_reflect.py reflect` 起各阶段（副本库不重建）。
  **第二次执行（新模型、新副本库）已做完并判定**：7 条期望 5 成立，V2 后半（4 段有小的无出处 / 数字不符断言）与 V6（写回后无人时守屋 0.86 → 0.63，与写回那段“继续守屋”方向相反）落空；判定、盲判对照与“要带进设计的事实”在 `s1v/results.md` 后三节，读数 `s1v/run2/`。
  执行子会话只做关键词粗判；**盲判由统筹会话另派**（9 条反思原文在 `s1v/reflections/`，B0 / B1 认识全文在 `s1v/beliefs/`）；判定写 `s1v/results.md`，没有那个文件就是还没判。反思何时触发、放在哪个进程，本轮不测，要等结果再设计。
- **Hindsight 的大模型已换成本机 magpie 网关的 Sonnet 5.5（2026-11-13T14:13Z，用户要求）**：容器 `npc-s1g-hindsight-20261113` 按原样重建（同镜像、端口、两个数据卷，9 个 bank 都在），只换 LLM 变量：`openai-responses` / `http://host.docker.internal:3425/v1` / `claude/claude-sonnet-5-5`，
  思考强度抽取 low、缺省 medium、反思 high（统筹会话的原创取值）。冒烟通过（retain、巩固、reflect 都成功）。设置、验证与注意事项在 `.demo/observe/npc-slice1-20261112/s1g/services-20261113-magpie.txt`；key 不落文件。
  **两点要记住**：① 此前所有 Hindsight 侧读数都是旧模型（gpt-5.6-terra）下的，旧 bank 的内容不要与新模型的产出混着比；② 这个网关与各 Claude Code 会话共用额度，实跑时 Hindsight 的用量不小。Hindsight 各操作实际用上了哪个强度没有核实。
  S1-V 因此改为整条链重做（新副本库 `s1v-copy2-20261113`，读数 `s1v/run2/`，规则见 `s1v/results.md` 末节）；S1-T 的计划末尾补记了这一前提，期望未改。
- **Docker 清理（用户 2026-11-13 要求“把旧的镜像、容器和数据卷都删掉”）**：统筹会话先做只读盘点——已停止容器 151 个（受保护的如园对象 23 个，voxim-* 120 个，别的项目 8 个）、无主卷 107 个（匿名 101、有名字 6：`ollama`、`maxio_pgdata`、`docker_mysql_data`、`docker_redis_data`、`docker_minio_data`、`docker_esdata01`）、镜像 157 个（91 个没有容器在用）。
  **用户经提问框定的范围**：容器——voxim-* 且建于 11 月 6 日之前的已停止容器（118 个）；卷——匿名的无主卷 + 被删容器独占的卷，现有那 6 个有名字的别的项目的卷不动；镜像——voxim-* 仓库里没有容器在用、建于 11 月 6 日之前的。
  不变的边界：受保护对象不删、不强制删仍被引用的镜像、不用任何 prune（按名字逐个删）、构建缓存不动（用户没提，且只能用 prune 清）、运行中的容器与别的项目的容器不动。实际删除清单与前后计数存 `.demo/observe/npc-slice1-20261112/docker-cleanup-20261113/`；**该目录里没有 `done.txt` 就是还没删完。**
  **已删完（2026-11-13T13:56Z，`done.txt` 在）**：容器 117、卷 152（匿名无主 101 + 被删容器独占 51，其中有名字的 6 个都是 10 月的 `voxim-npc-*-hf / -pg`）、镜像 76，逐个按名字删，0 个失败或跳过（`apply.log`）。前后：容器 154 → 37，卷 170 → 18，镜像 157 → 81；镜像 33.75 → 22.24 GB，卷 28.88 → 7.72 GB。
  删后核对：23 个受保护容器都在；运行中的 3 个（Hindsight、两个 meeting_room 库）没动；Hindsight 就绪、9 个 bank 都在；`voxim-server:20261112-qinglan`、`postgres:16-alpine`、Hindsight 镜像、构建基础镜像都在。
  **按名字多留了 3 个没删**（`held-back.txt`，名字像如园 / ymy 的一律不碰）：容器 `voxim-mail-qlry1023`、镜像 `voxim-server:ymy-20261015-taihu56-40` 与 `…-liquid40`。比用户选的范围少删 1 个容器（118 → 117，就是这个）。
  没动的：别的项目的 8 个已停止容器、近 7 天的 `voxim-test-pg` 与 `voxim-pg-servera-20261106`、6 个有名字的无主卷、构建缓存 30.79 GB（只能用 prune 清，用户没要求，且“禁止 prune”）。此前“06:59Z 那个疑似本线的匿名卷”已随匿名无主卷一并删掉。
- **环境（2026-11-13T13:30Z 前后；上面“T3 + T4 已派出”写的 14:05Z 有误，实际约 13:35Z）**：没有节点、tmux、临时 PG。本线容器只有 `npc-s1g-hindsight-20261113`（127.0.0.1:18933），bank：真实导出原件 `npc-life-312999940097`（**不删**）、`s1q-nomission-20261113`、以及早先的手写材料库 `smoke-s1g`、`s1i-m0/m1/m2`、`s1l-m1/m2`。
  Docker 卷数 170（S1-N 收尾时 168）：多出的两个匿名卷建于 08:36:43Z 与 09:20:54Z，那两个时刻本线没有起过容器，**不是本线的，没动**。另有一个建于 06:59:55Z 的匿名卷，时刻与本会话第一个临时 PG `npc-s1p-pg-20261113` 吻合，**很可能是它留下的，但无法按名字确认，没删**。
  voxim-d4 被用户暂停（用户 2026-11-13 原话“不用问对面了，我把对面暂停了”），它此前要求的“冒烟期间全机不编译”因此解除；它恢复后以它当时的消息为准。
  给用户的通俗说明页：`.demo/observe/npc-slice1-20261112/npc-structure-20261113.html`（结构、两张时序图、名词解释；不进 git）。

### 交接（2026-11-13，第七个统筹会话 → 第八个，因上下文接近 300k）——接手先读这一节，再读紧接着的“第七个统筹会话的进展”页首引用块

**一句话**：产品侧已提交两步——`8dfb567b`（`Life.Hindsight`：带过滤的召回、tags、mission）与 `b41c0590`（Life 写入侧：期间事实、人名、tags、逐条成文档、Registry 可选地名）。npc_server 缺省全套 430 通过、18 排除（`.demo/observe/npc-slice1-20261112/s1m/t2-full.log`）。**都没有在真实服务端实跑过**；分支未推送；工作区交接时干净。
用户 2026-11-13 的两条更正是本线现在的方法论（正文在下面的引用块与“工程约束”）：**测量不生造数据**；**先看整条链**（数据有没有产生者、能不能进到 prompt），不在局部死磕。

**`b41c0590` 的核对状态（如实）**：统筹会话只逐行看了 `life.ex` 的改动，`life/state.ex`、`dialogue.ex`、`registry.ex`、`runtime.ex`、`selector.ex`、`mind.ex` 与测试的 diff **没有逐行核对**，接手后先补。子会话回报的要点与偏离：
- 新入口 `Life.activity_started/1`（`Runtime.finish_select` 选定后调用）；`Life.activity/2` 入参改为 `%{text:, place:}`（`Selector.experience/2` 的返回）；`State.advance/6` 末尾加 `names`；`Dialogue.episode/3`；Registry 活动候选可选键 `"place_name"`（只进 tags，不进给 Jev 的候选）。
- 名字、距离、“谁算人”的函数挪到了 `Life.State`（`person/2`、`person_name/1`、`others/1`、`distance/2`、`approach/2`、`during/2`），`Mind` 改为调用它们——任务书写的是不改 `mind.ex`，子会话为避免复制而改了；`npc_mind_test` 未改且通过。
- **要修（第一件事）**：说话的经历现在只从观察取说话人名字，丢掉了消息自带的 `speaker_name`——说话人不在视野里就没名字。应改为说话人名字取消息自带的，对方的名字才取观察。
- 旧形状的片段（只有 `"text"`）不转换：一旦开始 retain 或读 `mind` / `context`，Life 进程崩溃并带着 Runtime、Body 反复重启。**实跑必须用全新的库**；这是“清空重建不写兼容”的直接后果，没有做成显式拒绝。
- 每条经历单独成文档后，Hindsight 对某份文档抽不出事实时 `retain/2` 整批报 `:empty_facts`，Life 记 `job_error` 并停掉自动写入，直到手动 flush——短句更容易触发，**未在真实服务上验证**，实跑时重点看。
- 开始 / 结束信号来自不同进程（Runtime 与发问 worker），次序靠本节点投递，未另加保证。`npc_life_state_test`、`npc_selector_test`、`npc_registry_test` 在 HEAD 上本来就不合格式，新行未用 formatter 核对。

**“看到的”——NPC 一侧实际拿得到什么（只读侦察的结论，行号按 `b41c0590`；设计草案还没写，用户已同意单独设计、要他点头）**
- **能直接用**：约每 50 毫秒一份观察（Player 每 3 tick 发 OwnerAck，`scene_server/movement/player.ex:916-932`；Body 每收到一次就发观察，`npc_server/body.ex:386-396`）；视野 = AOI，30 米进、34 米出（`scene_server/movement/aoi.ex:9-11`）；每个实体只有 `entity_id`、`entity_epoch`、`kind`（0 玩家 / 1 NPC）、`name`、`relation`、`position`、`tick`（`body.ex:430-438`）。
  Life 每秒 poll 到的是**全世界**的 build / damage / destroy 事件（带 actor、格子、材料、建筑名），但 `Life.State.appraise` 只留“动我的建筑”的，其余丢掉（`life/state.ex:306-351`）。
- **要做差才有**：谁进入 / 离开视野（协议有 `EntityEnter` / `EntityLeave`，Body 收到后只增删缓存、不往 Runtime 转发）；别人靠近 / 走远 / 停留多久（位置序列）；别人在我附近建造 / 拆除（World 事件的格子与我的位置比距离）。
- **已下发但被 Body 丢掉**（要改 Body）：别人的速度、朝向、生死状态码（`body_status` 0 存活 / 1 濒死 / 2 死亡）；`:voxel` 流里的逐笔操作；工具 / 投射物回执。
- **系统里根本没有**：别人此刻的动作 / 技能 / 动画状态；别人施法或受伤的通知；别人的所持物、生命值。
- “谁算人”现在没有按 `kind` 过滤（玩家与 NPC 都算）；距离是三维直线距离。

**下一步（按此顺序）**
1. 补核 `b41c0590` 其余文件的 diff；修说话人名字（小任务，WSL 跑 dialogue 相关测试 + 全套）。
2. 写“看到的”规范草案（放内容规范页，新一节）：只用上面“能直接用 / 做差可得”的数据起草——候选：有人进入 / 离开我附近、某人在我附近建造 / 拆除（World 事件按距离筛）、某人濒死 / 死亡（要改 Body）；每类写明产生者、存哪、经哪条路进 prompt、频率上限（观察 20 Hz，必须按事件而不是按帧成条）。交用户定。
3. **真实服务端 NPC-only 短实跑**（不起 QUIC、不起客户端；全新 PG 与新 Hindsight bank；沿用 S1-C3 的三种处境与脚本 `s1c3/scripts/`；`confront_wrecker` 改 `"person": "distrusted"`、给 `guard_hut` 等活动登记 `place_name`）：跑到越过封存阈值（约 17 次活动以上），逐次选择看期间事实是经“What just happened”、召回还是认识进的 prompt，在哪一步丢；看 `:empty_facts`、mission 生效、观察节奏。计划与期望先写 `.demo/observe/npc-slice1-20261112/s1n/plan.md`。
4. 在真实导出上重测（只做删减 / 换写法）：mission 效果、单路对三路召回、期间事实对选择的作用；之后才定 T4（三路召回接线，方案见下文“第 4 项的实现拆分”）。T3（Mind 的 Now 栏、相对游戏时间、背包去零、召回去噪）依据的是真实数据的变换，可在第 3 步前后做。
5. 约定、“多久没跟人相处”、关系史一句、反思写回：产品里有产生者之前不测、不进产品。

**环境**：本线只有一个容器 `npc-s1g-hindsight-20261113`（127.0.0.1:18933），bank：`smoke-s1g`、`s1i-m0/m1/m2`、`s1l-m1/m2`（都是本线建的手写材料库，按用户更正不再当依据，可按名字删）。临时 PG `npc-s1m/s1n/s1o-pg-20261113` 都已删。没有节点、tmux。WSL 跑测试的做法见 `s1m/` 各日志开头。跨会话记忆新增一条“测试数据必须是产品能产生的”。推送前须知不变（见第六个会话的交接：rebase 冲突点、CI 全绿、先向用户确认）。

### 第七个统筹会话的进展（2026-11-13）——接手先读这一节；下面第六个会话的“交接”里“下一步”第 1–3 项已做完

> **用户更正（2026-11-13，晚于本节下面的全部离线结论，以此为准）：测量时不能凭空生造数据。** 正式环境产生不了的数据，测出来的结果没有意义。
> 本节下面“站得住，可以改产品”的判断里，凡依据手写材料的都**撤回，降为假设**；改产品的依据只剩用户已同意的内容规范本身。逐项归类：
> - **输入是手写的、产品当时（多数现在仍然）产生不了的**：S1-H 的 D 组（期间事实句、推断句，第六个会话写的）；S1-I 两轮的材料库 M1 / M2（“没人来”“Corvin 靠近又走了”是统筹会话手写的，而且写的是相对屋子的距离，产品将来产生的是相对 NPC 自己的距离）及建在其上的全部反思产出、盲评、放进 state 的读数；S1-J（同一批库，tags 也是手工给的）；S1-L（同一批库）；
>   S1-K 的 `E1h` / `E3d` / `DsocL`（假设时长）、`Dsoc`（时长是真值，但产品里没有“上次与人相处”的 owner）、`Pdue` / `Plater`（虚构的约定，产品里没有约定的来源）及含它们的叠加 S2–S5u。
> - **只对真实 state 做变换、值来自真实数据的**（仍可用）：S1-H 的 F 组（合并 / 去零 / 去后缀）；S1-K 的 T1（UTC 换相对游戏时间，由真实时间戳算）、T2（Now 行，由真实时刻算）；S1-I 冒烟里 `reflect` 端点的延迟与 token 量（端点性质）。`E14h`（“他 13.5 小时前拆了我的屋”）时长是真值，但产品里还没有产生这句的代码。
> - **用户同日进一步说明：造数据前先看整条链**——这类数据在实跑里有没有产生者、能不能进到它该进的地方（例：连续选了 10 次守屋，第 11 次选择时，前 10 次除了“做出了选择”之外，当时的情景有没有被记下、有没有进 prompt 的路径）；要整体考虑，不要在局部问题上死磕。
>   统筹会话按已提交的代码走了一遍：**做过的**（活动结束一句，`life.ex` 的 `{:activity, _}`）、**听到 / 说过的**（`Dialogue.episode`，本线真实导出里没见过，薄片一不说话）、**别人动我的建筑**（`Life.State` 的标准描述表）有记录；**一般的“看到的”（谁来过、谁走了、别人在做什么）不记**——观察只留最新一份用来渲染处境栏。
>   记下来的都走同一条路：待写队列 → “What just happened” → 满约 3000 字封存写进 Hindsight → 靠那一次召回与四份认识回到 prompt；后半段只在活动与被拆事件上见过真实数据。T2 只补了“活动期间谁靠近过我”这一小块（附在活动句后）。
>   **用户同意（2026-11-13）：把“看到的”当成独立的一类经历来设计**（什么样的所见值得记，由规范定、用户点头），T2 不扩范围。设计前先查清 NPC 一侧实际拿得到哪些数据（只读侦察已派出）。
> - **此后的规则**（已加进本页“工程约束”）：测量输入只能是产品真实运行的导出，或对它做删减 / 换写法；要测的数据产品还产生不了，就先做产生它的代码、上真实服务端跑出来、导出，再测。确需“假设情形”时结果只标假设。
> - **顺序相应改为**：T2（产生者：期间事实、人名、tags、逐条成文档）→ 提交 → **真实服务端 NPC-only 短实跑**（T1 + T2 在场，沿用 S1-C3 的三种处境），导出真实的记忆库与 state → 在真实导出上重做 mission 效果、三路召回对照、期间事实对选择的作用（对真实 state 做删句对照）→ 才定 T4（三路召回接线）。T3（Mind 的 Now 栏、相对时间、背包去零、召回去噪）的依据是真实数据的变换，可在 T2 之后做。
>   约定、“多久没跟人相处”、关系史一句、反思写回：在产品里有产生者之前不再测，也不进产品。

**一句话**：三项离线测量都做了（S1-I 反思两轮、S1-J 召回对照、S1-K 游戏时间措辞与叠加），全部探索性、**不算验收**；期望都在发问前写定、一条未改，落空的如实记了。**没有动 `apps/`。** 结论是“内容与召回那部分站得住，可以改产品；反思写回还站不住，先不进产品”。
计划、逐条判定、归因都在 `.demo/observe/npc-slice1-20261112/` 的 `s1i/`（`plan.md`、`plan-round2.md`、`results.md`）、`s1j/`（`plan.md`、`results.md`）、`s1k/`（`plan.md`、`results.md`）；脚本与 Jev 结果在 `tools/jev/`（`s1i_materials.py`、`s1i_reflect.py`、`s1i_design.py`、`s1j_recall.py`、`s1k_design.py`、`results-s1i.json`、`results-s1i-round2.json`、`results-s1k.json`，README 有各轮说明）。

**S1-I 反思（材料：三个新 bank `s1i-m0` 无期间事实 / `s1i-m1` 10 次守屋都“没人来” / `s1i-m2` 其中两次 Corvin 靠近又离开；各 27–28 条）**
- 建库与冒烟：期间事实进得了库、缺省配置下没被抽取或巩固丢掉（M1 里 10 条逐次经历 + 1 条认识；我预计会少于 10 条，**落空**）。`reflect` 可用：14–18 秒、每次约 2.8 万 token、带依据清单——只能后台，不能进热路径。
- 第 1 轮（`reflect` / 自动提问两步法 / 聚焦问题两步法 × 三库 × 4 次 = 36 条，两个互不知情的会话盲评）：**36 条立场全是“不下结论”**，E1（结论跟着证据走）落空。访客断言无一编造；引用 137 个里 136 个有效（唯一无效的是两个真 id 拼接的抄错）。
  原因有我的设计缺陷：共用的回答规则里写了“没定论就说没定论”。自动提问（论文那句）12 次都只问“屋子怎么了 / 谁拆的 / 做了什么”，问不到担忧——用户补充的“担忧触发的聚焦问题”有独立必要。放进 state 后与基线无差（E6 / E7 无法判定）。
- 第 2 轮（只改回答规则为“从证据出发，然后拿主意，结论可朝任一方向”，另一半再加人格卡；`reflect` 与聚焦两步法 × 三库 × 4 次 = 48 条）：M1 + M2 的 32 条里 26 条有立场（G1 成立），没有因此编造（G4 成立，1 条与材料相反）。
  但**结论不稳定地跟着证据走（G2 落空一半）**：M2（Corvin 来过两次）`reflect` 多落在“还要守”、两步法多落在“眼下安全”；M1（没人来）两步法“眼下安全”3/4、`reflect` 只有 1/4。人格卡没有把结论往戒备推（G3 落空，方向相反）。多数产出是“屋子眼下站得住 + 我不信任他”两头的话，两位评判 48 条里 8 条立场不一致。
  放进 state：方向对、量小——“眼下安全”组 `visit_plaza` 0.185、“还要守”组 0.109、基线 0.165（差 0.076，不到我写的 0.10，G5 落空）；没有一条让 top1 离开 `guard_hut`。破坏者在眼前时 84/84 仍 `confront_wrecker`，但“还要守”的结论把约 0.08 从对质分给守屋（G8 成立）。
- 成本：`reflect` 约 2.8 万 token / 15–18 秒；两步法约 0.67 万 token / 7–9 秒（LLM `gpt-5.6-terra`，effort high）。

**S1-J 召回对照（同一容器，`s1i-m1` / `s1i-m2`，旧单路 vs 三路 vs 三路都加 `prefer_observations`）**
- **库太小（27–28 条），旧单路等于整库返回**，比不出“选得准不准”；H2、H3 落空主要因此。要比选择质量需要更大的库。
- 规范 §4 的合并规则“按路优先、旧的在前、上限 12”**截掉的恰好是最近的守屋事实**（M1 的“没人来”从 11 条变 0 条）——要改成按路配额或新的优先。
- 三路都加认识优先最干净：5–7 条、800–1000 字符、无字面重复，仍带着“被拆”“期间没人来 / Corvin 靠近过”“去过广场”；代价是细节只剩认识那一句。
- 延迟：三路并行墙钟中位 0.5–0.9 秒，比现行单路（1.3–2.2 秒，有一格超过我写的 1.5 秒）快。
- 巩固出的正文人称混乱（`the user` / `The assistant` / `I`，有一条中文）——没配 bank mission 的缺省行为；**mission 还没离线测过**。

**S1-K 游戏时间措辞与叠加（17 个变体 × 4 次，只打 Jev）**
- 写法（UTC 换成“About N hours ago”、加 `Now: It is night, 21:25.`）不改 top1（K1 成立）。
- **到点的约定是目前唯一能越过守屋的正向驱动，而且读时间**：`Plans and promises: Maren and I agreed to meet at the plaza tonight.`（现在是夜里）→ `visit_plaza` 0.56、top1 4/4；同句换成 `tomorrow morning` → 0.18，与对照无差（K4 成立）。约定是虚构的，素材里没有来源。
- “离被拆过了多久”读得出来（1 小时 / 13.5 小时 / 3 天 `guard_hut` 0.89 / 0.85 / 0.85，单调）但量很小（K2 落空），而且“他 X 前拆了我的屋”这句本身就把守屋抬高 0.04–0.09。
- **“多久没跟人相处”不是驱动，方向还反了**（7 小时 `visit_plaza` 0.16、2 天 0.11，对照 0.19；K3 落空）。换措辞验证之前不要用这句当社交需求。
- 不含约定的三项叠加只到 0.22（K5 这一条落空）；加上到点的约定 0.62；其上再叠反思一句（哪种立场都）不动（差 0.01）。破坏者在眼前叠加后仍 `confront_wrecker` 4/4。

**站不站得住（给第 4 项“改产品”的依据；我的判断，待用户过目）**
- **站得住，可以改产品**（都在内容规范用户已同意的范围内）：Life 写期间事实、人名 `名字 (actor cid)`、retain 带 tags（进得了库、按 tag 取得回来）；Mind 加 Now 栏并读 `world_time`、相对游戏时间、背包去零、召回去噪（都不改 top1）；召回改三路并行 + 认识优先，**合并规则要先改**；“Plans and promises”栏的写法（但内容来源要等规划层）。
- **还站不住，先不进产品**：反思写回（结论不稳定跟证据、对选择的增量小且在约定面前为零、会把份额从对质挪到守屋）；“多久没跟人相处”的写法；关系史一句（会加固守屋，要想清楚要不要）；连续活动合并成一句（S1-H 里它使 `guard_hut` 0.81 → 0.89，仍未单独评估）。
- **改产品前还缺的离线项**：bank mission（第一人称、保留“没发生什么”）的效果；更大的库上的召回选择质量。

**S1-L bank mission（已做；计划与判定 `s1l/plan.md`、`s1l/results.md`，脚本 `tools/jev/s1l_mission.py`）**：同材料新建 `s1l-m1` / `s1l-m2`，retain 前 `PATCH /config`（请求体 `{"updates": {"retain_mission": …, "observations_mission": …}}`，mission 原文在 `s1l/plan.md`）。
第一人称比例 1.00 / 1.00（缺省 0.11 / 0.14）；认识里有了次数与“twice”；实体里不再有 assistant / user，`Corvin (actor 920628760578)` 成为一个实体；三路 + 认识优先在 `s1l-m2` 上召回 7 条、全第一人称、含“被拆”与“靠近过”。5 条期望 4 成立；L2 按字面落空（“没人来”的经历 7 条 < 我写的 8 条，另 3 条被归成 `world` 类型，事实没丢）。
**副作用：带 mission 后更多事实被抽成 `world` 类型**——落地时三路召回不要按 `types` 过滤。mission 原文里写了角色名 Garen，产品里要换成通用写法或按角色代入（这一点差异没有离线测过）。

**第 4 项的实现拆分（只读方案会话基于 `523c7962` 给出，统筹会话整理；尚未开工的部分以此为准）**
现状要点：召回在发问 worker 里做（`Selector.question/3` → `Life.mind/2` → `recollect/3` → `Hindsight.recall/3`，一次、budget mid、2048、超时 10 s），不在 Life 的慢 worker；经历文本句首烤进 `At <UTC> (UTC), `，进 `pending`，攒到 3000 字 `seal/2` 拼成一个片段，一个片段一个 document、无 tags；`ensure` 每个 retain job 前都 PUT bank。
先冻结两个契约：经历条目 `%{"id","at_ms","text","tags"}`；召回结果 `%{id:, text:, type:, at_ms: integer | nil, tags:}`（在适配器边界规范化一次）。
- **T1 `Life.Hindsight` 适配器**（只动 `life/hindsight.ex` 与 `npc_hindsight_test.exs`）：`recall` 接受 `%{query:, tags:, tags_match:, types:, prefer_observations:, max_tokens:}`（nil 不进请求体）；结果规范化出 `at_ms`；`retain` 的 item 透传 `tags`；`ensure` 的 mission 收成常量并在 PUT 后 `PATCH /config`。
- **T2 Life 写入侧**（`life.ex`、`life/state.ex`、`dialogue.ex`、`runtime.ex`、`selector.ex` 的 `experience/2`）：人名 `名字 (actor cid)`（`State.advance` 多收一个 `names` 映射，取不到写 `actor <cid>`）；tags（事件 `kind:event` + `actor:` + 有建筑时 `place:`；说话 `kind:conversation`；活动 `kind:activity`）；期间事实 ` During it: nobody came near.` / `During it: <名> (actor cid) came within <N> m.`（`Life.activity_started/1` 记起点）；片段改成带 `episodes` 列表、retain 时每条经历一个 item。
- **T3 Mind 纯渲染**（只动 `mind.ex` 与 `npc_mind_test.exs`）：Now 栏（时段边界同 S1-K）；`ago(at_ms, now_ms)` 用 `WorldTime.game_us` 之差（不往 WorldTime 加函数），措辞同 S1-K；背包只列非零；召回条目从第一个 ` | When:` 起去掉后缀并前缀相对时间；`recall_queries/2`（R1 最近至多 2 人各一路 `actor:` tag、R2 我的建筑 `place:` tag、R3 不加 tag，都 `prefer_observations`，缺对象就省那一路）；`merge/2`（按 id 去重、每路取最新 K 条）。
- **T4 接线**（`life.ex` 的 `mind/2` / `recollect/3` / `:context`、`selector.ex` 的 `question` / `asked`、各测试的假适配器）：三路在调用者进程里 `Task.async_stream`（并发 3、每路 10 s）；视图加 `now_ms`、`recent` 改成 `[%{at_ms, text}]`、`memories` 按路分；`asked.recall_query` → `recall_queries`。必须排在 T1–T3 之后；T1 / T2 / T3 文件无交集，可并行。
统筹会话已定（依据离线证据，报用户知悉）：① 存进 Hindsight 的正文**保持**离线测过的 `At <UTC> (UTC), …` 写法——条目里另存 `at_ms`，前缀在组 retain 内容时加，Mind 用 `at_ms` 渲染相对时间，不解析前缀；② 三路召回不按 `types` 过滤；③ 每路 `max_tokens` 先用 S1-J 的 700 / 700 / 600，每路配额 K 先取 4（**K 没有离线依据，是原创取值**，实跑后再调）；④ 规范 §4 的合并规则改为“按路配额、路内新的优先”（依据 S1-J），总纲 :116–118“写进记忆的文字不带 id”按用户已同意的 `名字 (actor cid)` 同步改，随实现提交。
**要用户定、T2 开工前必须有答案的**（已于本会话提问，答复见下方“用户答复”；没有答复就是还没定）：(a) 期间事实的真值——活动期间逐帧记每人最小距离（能抓到“来了又走”，不加新通道，但超出规范“起止各取一次”的原文）还是只取起止两次；(b) “靠近”的半径 `@near_m`（无离线依据；S1-I 材料写的是 6 m）；(c) 活动的 `place:` 名从哪来——Registry 候选加可选地名字段（登记契约扩展）还是按坐标就近匹配我的建筑；(d) 已有的 Life 片段与无 tags 的旧记忆——清空重建不写兼容，还是加载时一次性转换。
**用户答复（2026-11-13，经提问框逐项选择）**：(a) **活动期间逐帧记每人最小距离**（不加新通道；超出规范“起止各取一次”的原文，用户已点头）；(b) 靠近半径 **6 米**（原创取值，实跑后可调）；(c) **Registry 的活动候选加可选地名字段**，登记边界校验一次；(d) **清空重建，不写兼容**——只清本线自己的开发库与 NPC 的 Life 片段，代码里不留旧片段转换。
**T1 已实现、已测、已提交 `8dfb567b`（未推送；未在真实服务端实跑）**——连同 `npc_registry_test.exs` 里 HTTP 替身认识 `PATCH` 的修补，npc_server 缺省全套 422 通过、18 排除（`s1m/fix-full.log`）；下面是修补之前的读数：`recall/3` 接受一路召回的描述（过渡期仍接受字符串问句，T4 后删）；召回结果在适配器边界规范化为 `%{"id","text","type","at_ms","tags"}`（**保留字符串键**——`mind.ex` 与多处测试按 `"text"` 读；只留这五个键）；retain item 透传 `"tags"`；`ensure` 在 PUT 后 `PATCH /config` 写两条 mission（常量 `@retain_mission` / `@observations_mission`，去掉了角色名 Garen，这一处差异未离线测过）。
`npc_hindsight_test.exs` 18 通过；全套 418/422：2 条是 `npc_registry_test.exs` 自带的 HTTP 替身不认识 PATCH（连带 1 条 `NpcSelectorTest` 环境变量断言被污染），1 条 `NpcHindsightTest` “operation deadline bounds an in-flight poll request” 在全套负载下超时、单独跑通过（**原因按时序抖动记，未查清**）。替身的修补另派子会话。日志 `.demo/observe/npc-slice1-20261112/s1m/`。
**T2（Life 写入侧）已实现、已测、已提交 `b41c0590`（状态与偏离见页首交接；下面是派出时的任务书要点）**（任务书要点，接手时若工作区有未提交的 `apps/npc_server` 改动就是它的）：经历条目 `%{"id","at_ms","text","tags"}`、正文不烤时间前缀，组 retain 内容时在唯一一处加 `At <UTC> (UTC), `；片段带 `episodes`、每条经历一个 item；人名 `名字 (actor cid)`；tags；Registry 活动候选加可选地名字段；
期间事实句式由统筹会话定（**没有离线测过这几句的原文**，离线材料写的是相对屋子的 `came within 6 m of the hut and then walked away`）：` During it: nobody came near.` / `During it: <名> (actor <cid>) came within <N> m and then moved away.` / `… and was still there at the end.`，距离是到 NPC 自己的最小距离向上取整，最多 3 人；没有开始信号或期间没有观察就不写。测试日志将在 `s1m/t2-targeted.log`、`t2-full.log`，临时 PG 名 `npc-s1o-pg-20261113`（用完即删）。
T2 之后：T3 + T4（Mind 渲染与三路召回接线）合成一个任务串行做——各任务都在本 worktree 里跑 WSL 测试，不并行。
其它风险（方案会话指出，未处理）：每条经历单独成 document 后短句可能抽不出 fact（`document/2` 报 `:empty_facts` 会让 retain 卡住重试）；并行召回与后台 retain 争用同一个 Hindsight 没测过；`ensure` 每个 job 多一次 PATCH；`npc_mind_test.exs`、`npc_selector_test.exs`、`npc_life_test.exs` 等有全文断言要重写。

**下一步**
1. （已做，见上）bank mission 的离线测量。
2. 第 4 项里站得住的那部分改产品：按上面的 T1 → T4（T1、T3 不依赖用户答复，可先做；T2 等 (a)–(d)），服务端只在 WSL 构建与测试；再上真实服务端短实跑（并入 `confront_wrecker` 改 `"person": "distrusted"` 的实跑）。
3. 反思：若继续，离线第 3 轮要换读数（把“对屋的判断”与“对人的判断”分开读，不再压成一个立场标签），并加大采样；触发计数（担忧被证伪 N 次）可以先只记录不写回。
4. 规划层与“Plans and promises”的内容来源（原第 5 项）——S1-K 说明它是最有力的驱动。

**环境**：本线仍只有一个容器 `npc-s1g-hindsight-20261113`（127.0.0.1:18933，卷同前），里面多了三个 bank `s1i-m0` / `s1i-m1` / `s1i-m2`（本线建的，可按名字删；`s1i_materials.py --recreate` 只删这三个）与原来的 `smoke-s1g`。没有 PG、节点、tmux。本会话没有起过任何别的容器或长驻进程；主机上另有两个不是本线的 python 进程（`image-smoke.py`、`s13_launch.py`），没动。分支未推送。

### 交接（2026-11-13，第六个统筹会话 → 第七个）——下面“第六个统筹会话的进展”是它的明细

**一句话**：A（S1-F）已提交；游戏钟第一阶段已提交；内容规范、AI 小镇借鉴、游戏钟设计三份文档用户都已同意；S1-H 第 1 轮离线测量已做。**下一项是反思的离线测量（S1-I）**，再是召回对照与按游戏时间措辞的测量，之后才改产品。
分支 `npc-life-20261111` 未推送，工作区交接时干净（若不干净，多出来的不是本线的，不要带进提交）。本会话的提交：`4a3ea999`（S1-F）、`6c2b0cc6`、`efd40f2c`、`0c9ff88e`、`48d05546`（S1-H）、`64c3685b`、`7db73952`（游戏钟第一阶段）及其后的文档更正与本交接。

**用户 2026-11-13 已定的（正文在各页，别重新讨论）**
1. 内容规范（`2026-11-13-npc-mind-content-spec.md`）§2 §3 §6 **全部同意**：含 Life 写入时把人名写成 `名字 (actor cid)`（改总纲 :117）、活动结束写“期间观察到的事实”、新增“现在”与“计划与约定”两栏、封存阈值与认识刷新节奏本片可动。
2. 借鉴 AI 小镇（`2026-11-13-npc-planning-reflection-borrowing.md`）：要反思、要分层计划（周→日→半小时）；反思的洞见写回 Hindsight（用户答“可以”，按推荐理解）；**§8 用户补充**：连续无事发生（如 11 次）后角色会归因、得新结论、形成新记忆——反思要覆盖这种“未了的担忧被反复证伪”的触发，不只是重要性累计。
3. 游戏钟（`2026-11-13-world-clock-design.md`）：服务端权威、世界基础设施；NPC 看游戏时间（“多久以前”= 真实经过 × 72 换词），Hindsight 仍存真实时间戳；昼夜日 = 现实 20 分钟，周 = 7 个昼夜日；第一阶段（不改协议）已做，**第二阶段（`SessionStart` 带 epoch/game0/rate、协议 44 → 45、客户端去常量）排在发版 `20261112-qinglan` 生产切换并公网冒烟通过之后，对接人 voxim-d4**，服务端方案准备好后发它；切换前本线不动协议。 【已于 2026-11-15 改为 ×24（昼夜日 = 现实 60 分钟），见游戏钟设计页 `2026-11-13-world-clock-design.md` 页首】
4. 用户原话仍有效：不强行要求选项、靠内容让决策自然涌现；测试从驱动力测；记忆系统承担 LLM 之外的大部分思考；给 Jev 的内容要详细；召回要像人一样联想。

**状态（已实现 / 已实跑 / 已验收分开）**
- S1-F：已实现、已测（定向 72 通过；整套 412/413，唯一失败 `NpcBodyWorldTest` “cancelling a skill…”，`:noproc`）、已提交；**未在真实服务端上实跑**，`confront_wrecker` 仍用固定坐标夹具，换成 `"person": "distrusted"` 并入下一次服务端短实跑。
- 游戏钟第一阶段：已实现、已单测 / 集成测（mmo_contracts 192、npc_server 414 通过）、已提交；客户端对账已由 voxim-d4 完成（Voxim main `93a9cb27`）；**未实跑；快照还没读 `observation.world_time`**。
- `NpcBodyWorldTest` 那条用例：full-2 失败一次、后来一次全套通过，**原因没查清**，不要写成“已确认是竞态”。
- S1-H 第 1 轮：探索性，8 条期望 7 成立、1 落空，明细在本页“第六个统筹会话的进展”。**不算验收。**
- 没有任何产品代码改动是为内容规范做的（Mind / Life / Hindsight / Selector 都没动），除 S1-F 与游戏钟两处。

**下一步（按此顺序；每步期望先写定再发问，期望一律“方向与归因”）**
1. **S1-I 反思离线测量**（计划大纲在借鉴页 §8.5）：先写 `.demo/observe/npc-slice1-20261112/s1i/plan.md`（变体、读数、发问前的期望）。素材：S1-C3 导出的 10 条事实（`s1c3/export/hindsight-memories-list.json`，重新 retain 进本线 Hindsight 容器的**新 bank**，带内容规范 §3 的 tags / 人名写法）+ 三份真实 state（`s1c3/states/`）。
   变量：反思产出文本——Hindsight `reflect`（聚焦问题；**这个端点没实测过，先做最小冒烟**）对自写提示词的论文两步法（取最近经历 → 提 ≤3 个问题 → 检索 → 带引用的洞见），各采样多次；读数 = 结论分布（安全 / 不安全 / 其他）与放进 state 后各候选概率的移动，按结论归因。S1-H 的教训：单句正向结论在事实之外没有增量、威胁类内容移动大；允许结论是“还不安全”。
   自写提示词要打 LLM（`NPC_LLM_URL/KEY/MODEL` 在主检出 `.env`，只读进进程）；Hindsight 容器自己的抽取 / 反思用它配置的模型（`gpt-5.6-terra`，reasoning low）。请求并发 ≤ 3。
2. **召回对照**（内容规范 §4、§5.3）：同一个容器，旧单路召回对 R1 人 + R2 地点 + R3 未了三路；读数 = 与“破坏者”“重建后平静”相关的条数、重复率、总延迟（总纲预算：选择连同召回 2–4 秒）。
3. **按游戏时间措辞的测量**：S1-H 刻意没含“多久以前”。游戏钟已有，按“真实经过 × 72 → 词”重做“过了多久”这类驱动，再叠加需求 / 约定等正向驱动（单个正向驱动移动只有 0.03–0.08，越不过守屋，要叠加才可能）。 【已于 2026-11-15 改为 ×24（昼夜日 = 现实 60 分钟），见游戏钟设计页 `2026-11-13-world-clock-design.md` 页首】
4. **改产品并上真实服务端短实跑**（内容规范 §7 的落点：`Mind` 加“现在”栏并读 `world_time`、合并连续活动、背包去零、召回去噪；`Life` 写“期间事实”、人名替换、retain 加 tags；`Life.Hindsight` 的 recall 参数与 bank mission；反思调度放 `life.ex` `automatic/1`）。这一步之前先确认离线结果站得住。
5. 之后才是 LLM 规划层与分层计划（借鉴页 §4）：日计划 / 意图持有者（`DayPlan` 入口已删、名表写死，倾向重写成更小的持有者，且必须持久化）、周意图在日末反思稳定后再加。

**环境**
- 本线只有一个容器在跑：**Hindsight `npc-s1g-hindsight-20261113`**（127.0.0.1:18933，卷 `npc-s1g-hindsight-20261113-pg` / `-hf`，镜像 `voxim-npc-evolve-hindsight:0.10.3-flashrank`），bank `smoke-s1g` 只是冒烟（两三条短事实）；能力清单 `.demo/observe/npc-slice1-20261112/s1g/hindsight-capabilities.md`，openapi `s1g/hindsight-openapi.json`。没有 PG 容器、节点、tmux 会话；要跑 npc_server 测试就自己起临时 PG（`npc-s1h-pg-20261113` 的做法见 `clock/` 里的日志与统筹页 A 段命令，名字换新的，用完只删自己的容器与匿名卷）。
- 与 voxim-d4（Voxim 客户端与发版统筹）的约定已放宽：不共享构建目录、数据库、端口的 mix 测试可并行，**不必再要「WSL 已空」**；只有要起长时间节点 / QUIC 服务或占固定端口、或主机 / WSL 可用内存 < 10 GiB 时先打招呼。它的 ci-1 在 WSL 里用 `/home/dyz/ci1-20261112` 跑 ex master 的 CI，会争 CPU（超时类失败复判要考虑）。接手后 `ListAgents`，给 voxim-d4 发一句“NPC 线已换新会话”。
- 推送：本线不推送。voxim-d4 通报（未在本线复核）：ex `origin/master` 已到 `29531ea4`、CI 12 个 job 全绿；它改了 13 个 NPC 相关文件，rebase 本分支会在 `brain/social.ex`（本线 S1-F 也改了 `target/3`）与 `voxel_region/.../prefabs.ex` 冲突，其余多为格式；CI 有 Format job，推送前 `mix format` 并按 `ci.yml` 本地全部跑绿，推送后核对，先向用户确认。

**证据位置**（`.demo/observe/npc-slice1-20261112/`，被 .gitignore 忽略）：`s1c3/`（最近一次实跑）、`s1e/`、`s1f/`（含 `targeted-1.log`、`full-2.log`）、`s1g/`（Hindsight 能力清单与 openapi）、`s1h/`（plan.md、`round1/` 变体与 `report.txt`）、`clock/`（游戏钟各次测试日志）。脚本在 `docs/10-active/cross-cutting/tools/jev/`（`s1e_design.py`、`s1h_design.py`，README 有各轮记录；`results-s1h-round1.json` 已提交）。

**其它**：统筹与执行分离（具体任务交子会话、按难度分配模型与强度，子会话不写报告文件，需留档的由你代存）；每个会话上下文 ≤ 300k，接近时先把已完成 / 未完成 / 证据路径 / 下一步写回本页再换会话；期望在运行前写下、落空如实记；不推送、不部署；受保护对象与凭据规则同上一份任务书与全局 CLAUDE.md（`ymy-d1-20261013-task5*`、`voxim-pg-qlry1023`、`voxim-qinglan-ruyuan-20261023`、`D:/hemifuture/Backups/`、任何不是本线创建的容器 / 卷 / 库不碰，禁止 prune；凭据只读进进程、不打印不落盘）。

### 第六个统筹会话的进展（2026-11-13）——明细

- **A（S1-F）已实现、已测试、已提交 `4a3ea999`（未推送）**。“走向某个角色”并入 `travel`：候选 `{"person":"distrusted","stay_ticks":n}`，`Mind.person/2` 选人，`travel` 每段重读位置、2.0 m 到达、预算 = 起步段数 + 2。
  测试：定向五文件 72 通过（`.demo/observe/npc-slice1-20261112/s1f/targeted-1.log`）；整套缺省（单进程、占位 `NPC_LLM_*`）`s1f/full-2.log` 412/413，唯一失败 `NpcBodyWorldTest` “cancelling a skill preserves an already committed World transaction”
  （`Process.monitor` 在 worker 已退出后才挂，收到 `:noproc` 而非 `:shutdown`；该测试不涉及 travel，本次没动它，在 `full-1` 里通过）。**这一项没有在隔离环境重跑确认**（WSL 被别的会话的 CI 占用，没再抢）。
  `s1f/full-1.log` 是交叠的两次运行，**不是证据**；`s1f/impl-report.md` 里“iso-1 / full-2 没跑过”的说法与目录不符，那两份日志是本会话重新生成的（`iso-1.log` 内容为本会话跑的 16/17，失败项 `NpcEmotionMovementTest` 是未设 `NPC_LLM_URL`，设占位后在 `full-2` 通过）。
  真实服务端上的 `confront_wrecker` 改用 `"person":"distrusted"` 尚未实跑，并入 B 的第一次服务端短实跑。临时 PG `npc-s1f-pg-20261113` 与其匿名卷已删。
- **推送前须知（voxim-d4 通报 2026-11-13，未在本线复核）**：ex `origin/master` 已到 `29531ea4`，GitHub CI 12 个 job 全绿（run 43355282806）。它为修 CI 动了 NPC 相关 13 个文件，本分支 rebase 前留意：
  仅格式 — `apps/npc_server` 的 `actions.ex`、`perception.ex`、`world_request.ex`，测试 `npc_abilities`、`npc_body_cast`、`npc_body`、`npc_body_world`、`npc_brain_llm`、`npc_cast_world`、`npc_wilderness`、`npc_world_request`；
  实际改动 — `brain/social.ex`（删去类型检查证明不可达的 `s.social != nil` 分支；**本线 S1-F 也改了这个文件的 `target/3`，会有冲突**）、`npc_emotion_movement_test.exs`（dry-run 用例临时设占位 `NPC_LLM_*`）；
  可能冲突 — `voxel_region/.../world/prefabs.ex`（它删了未用的 `Liquid` alias，本分支也改了这个文件）。CI 有 Format job：本分支 rebase 后推送前要 `mix format` 并按 `ci.yml` 全部 job 本地跑绿，推送后核对该提交 CI，向用户确认。**本线现在不推送、不 rebase。**
- **B1（读接口）已做**：本线 Hindsight 容器 `npc-s1g-hindsight-20261113`（127.0.0.1:18933，卷 `npc-s1g-hindsight-20261113-pg` / `-hf`，**仍在运行**，bank `smoke-s1g` 只是冒烟）。能力清单 `s1g/hindsight-capabilities.md`，openapi 全文 `s1g/hindsight-openapi.json`。
  要点：recall 支持 `types` / `tags`+`tags_match` / `tag_groups` / `prefer_observations` / `min_scores` / `temporal_window` / `include.entities|chunks|source_facts`；retain 支持 `context` / `tags` / `entities` / `metadata` / `observation_scopes` / `strategy`；有 reflect、directives、bank 配置（各类 mission）、实体与别名接口；
  没有按实体过滤的 recall 字段（按实体取事实只能用 `memories/list?entity_id=`）；多路只能多次 recall 再合并。未实测：reflect、mental-model、observation 召回内容。
- **B2/B3（内容规范与召回方案）草案已写**：[`2026-11-13-npc-mind-content-spec.md`](2026-11-13-npc-mind-content-spec.md)，**待用户过目**；用户认可前不动 `apps/` 里的 Mind / Life / Hindsight / Selector。
  离线测量（§5）的设计已写进该页，期望“方向与归因”；尚未运行。**用户 2026-11-13 已对该页三问全部同意**（含改总纲 :117 的 cid 写法）。
- **用户同日提出：借鉴“AI 小镇”加反思、分层计划（周→日→半小时）。** 调研与借鉴清单见 [`2026-11-13-npc-planning-reflection-borrowing.md`](2026-11-13-npc-planning-reflection-borrowing.md)（草案，待用户过目）：
  论文（Park et al. 2023）有日→小时→5–15 分的计划与“重要性累计 > 150”触发的带引用反思，没有周层；a16z AI Town 只有对话总结 + 反思、没有计划。结论：反思先于计划，先离线；半小时层就是 Jev 选择器，不加 LLM 层；游戏钟与计划持久化是前提。
  **用户 2026-11-13 回复：游戏钟要做（服务端权威的世界时间属世界基础设施）；洞见写回按推荐理解。** 侦察已做（客户端已有以服务端墙钟为输入的确定性昼夜：×72、一昼夜日 = 现实 20 分钟，不是选择器文档写的 24 分钟；服务端只发墙钟、没有游戏钟）。
  游戏钟设计页：[`2026-11-13-world-clock-design.md`](2026-11-13-world-clock-design.md)（草案，待用户过目）：纯函数 `game_us = game0 + (t − epoch) × 72`，不持久化、不广播；第一阶段服务端实现同公式（不改协议），第二阶段 `SessionStart` 带参数（协议 44 → 45，另排并与发版线对齐）。待用户定 3 条见该页 §5。**用户 2026-11-13 三条全部按建议**（NPC 看游戏时间、Hindsight 存真实时间戳；天 = 昼夜日 20 分钟、周 = 7 个昼夜日；第二阶段排在发版 `20261112-qinglan` 生产切换并公网冒烟通过之后，对接人 voxim-d4）。客户端对账已由 voxim-d4 完成（Voxim main `93a9cb27`）。**第一阶段服务端已实现、已测试、已提交**：`MmoContracts.WorldTime`（`params/0`、`game_us/2`、`at/2`，41 行）+ 设计页 §3 七行手算表的单测（mmo_contracts 全套 192 通过）+ NPC `Runtime` 观察新增 `world_time`（npc_server 缺省全套 414 通过、18 项按标签排除；`NpcBodyWorldTest` 那条 `:noproc` 用例这次没失败）。 【已于 2026-11-15 改为 ×24（昼夜日 = 现实 60 分钟），见游戏钟设计页 `2026-11-13-world-clock-design.md` 页首】
  日志 `.demo/observe/npc-slice1-20261112/clock/`。没有可注入的时钟，Runtime 的测试用调用前后的墙钟围出可能时刻（子会话如实说明）。`runtime.ex` 的 `--check-formatted` 不通过，两处是 HEAD 上就有的旧行，没动（推送前整体 `mix format` 时处理）。
  第一阶段的“已实现 / 已实跑 / 已验收”：已实现、已单测与集成测过；**未在真实服务端上实跑**；选择器文档里的“24 分钟”与借鉴页里据此算的换算已更正（2026-11-13）。”Now” 栏还没读它（内容规范的实现在后）。
- **S1-H 第 1 轮（离线、只打 Jev、探索性、不是验收；64 次全部应答；期望写在 `.demo/observe/npc-slice1-20261112/s1h/plan.md`，发问前写定、一条未改；脚本 `tools/jev/s1h_design.py`，结果 `tools/jev/results-s1h-round1.json`，逐条判定 `s1h/round1/report.txt`）**：8 条期望里 7 成立、1 落空。素材 = S1-C3 的三份真实 state，每个变体只动一栏一处。
  - **写法（F 组）都在阈值内，但不是零影响**：压缩 / 去零 / 去后缀后 top1 不变；其中把 10 句守屋流水合并成一句使 `guard_hut` 0.81 → 0.89、`visit_plaza` 0.16 → 0.10；三项同时用在破坏者场景使 `confront_wrecker` 0.77 → 0.68、`guard_hut` 0.20 → 0.31。合并一句像“反复守屋”的强化，改写法也会动选择，定稿前要单独评估。
  - **期间事实（没人来）**：`guard_hut` 0.81 → 0.73、`visit_plaza` 0.16 → 0.24，方向对、量小，不改变 top1。反向（有人来过又走）`guard_hut` 0.79，与基线 0.81 几乎无差（基线已高，没有上升空间）。
  - **推断一句**：单独加“新房暂时安全”只把 `visit_plaza` 推到 0.19（+0.03）；事实 + 推断 0.23 ≈ 只有事实 0.24——**期望 5 落空**（差 0.005，在噪声内，按运行前的规则记落空）：正向推断在事实之外没有增量。
  - **反向（事实 + “还不安全，他可能回来”）**：`guard_hut` 0.95、`visit_plaza` 0.03，是本轮移动最大的一项；反向事实单独不动，所以起作用的是那句“可能回来”的前瞻性威胁。**归因有混杂**：没有单测“只有反向推断”，不能把这一差值全归给“推断”这一形式。
  - **不被压掉**：破坏者在附近仍 `confront_wrecker` 4/4（加“没人来”后 0.82，反而略升）；陌生人在附近 `confront_wrecker` 0.003。
  - **含义**：威胁类内容比平安类内容更能移动选择；“守屋”基线（0.81）很稳，单个正向驱动（事实、推断）各只移动 0.03–0.08，不会越过它——与第 3 轮一致，要把他拉向广场需要叠加正向驱动（社交需求、约定、时间），这些等游戏钟的呈现定稿后再测。
  - **局限**：每类信息一种措辞、位置固定、4 次采样、一个 NPC；N3 / S3 / V3 的守屋句数分别是 10 / 7 / 12，事实句里的次数按各 state 实际写（plan.md 补记）。

### 第五个统筹会话的结果（2026-11-12 / 13）——接手先读这一节

**一句话**：S1-E 离线设计 → 用户批准改 Nearby 一句 → S1-C3 短实跑 → **(c) 按运行前的规则通过**。薄片一三条验收：(a) 已验收、(b) 已验收（基线少取 1 次）、(c) 已验收。
本线没有容器、节点、tmux 会话在跑，容器 / 卷 152 / 160；分支未推送。**下一步要用户定的事在本节末尾“待用户定”**；薄片二未开工。

**S1-E 结果（离线，只打 Jev，探索性、不是验收；64 次请求全部应答；期望都在发问前写进 `tools/jev/s1e_design.py` 顶部，一条未改）**

候选表 T1 = S1-C2 的 5 个候选原样 + 第 6 项 `confront_wrecker`，判据：
`Walk over to the person standing nearby, stand in front of them and watch them closely, to make it plain I have not forgotten what they did. Only do this when that person is someone who once destroyed or removed something I built; otherwise there is no reason to.`
`guard_hut` 保留不动（陌生人在附近的基线仍是它，只看新候选是否成为 top1）。“去掉记忆栏里那件事”用规则 E（物理行级，删含破坏者 cid 或词干
remov / destr / dismantl / demolish / vandal / harm / angr / anger / trust 的行；不含 rebuil、guard；V 上删 4 条召回句、留 11 条，四份认识删 15 行）。

第 1 轮（S / 无人 / V 三份真实 state，12 个变体各 4 次）。A 族 = 现行 state 写法；B 族 = 只把处境栏改成 `Nearby: <名> (NPC, actor <cid>, 5.0 m away).`，其余同 A 族。

| 变体 | 发问前期望 | 实际（4 次 top1；`confront_wrecker` 概率） | 判定 |
|---|---|---|---|
| A_S 陌生人在附近 | not confront | `guard_hut` ×4（0.01） | 成立 |
| A_N 无人 | not confront | `guard_hut` ×2、`visit_plaza` ×2（0.00） | 成立 |
| A_V 破坏者在附近 | confront | `confront_wrecker` ×4（0.61–0.74） | 成立 |
| A_V_no_event 去掉记忆里那件事 | not confront | `guard_hut` ×4（0.14–0.22） | 成立 |
| A_V_no_distrust 只去掉 Distrusts | 设计要求 confront；预测落空 | `guard_hut` ×4（0.10–0.14） | **落空（与预测一致）** |
| A_V_no_event_no_distrust | not confront | `guard_hut` ×4（0.03–0.04） | 成立 |
| A_V_memory_blank（记录项） | not confront | `guard_hut` ×4（0.10–0.12） | 成立 |
| B_S | not confront | `guard_hut` ×4（0.00–0.01） | 成立 |
| B_V | confront | `confront_wrecker` ×4（0.81–0.86） | 成立 |
| B_V_no_event | not confront | `guard_hut` ×4（0.17–0.21） | 成立 |
| B_V_no_distrust | confront | `confront_wrecker` ×4（0.82–0.87） | 成立 |
| B_V_no_event_no_distrust | not confront | `guard_hut` ×4（0.03–0.05） | 成立 |

第 2 轮（T1 会不会妨碍实跑前半段；四份 S1-C2 真实 state 原文只换候选表，各 4 次）：破坏之前的基线两份 `visit_plaza` 4/4（期望 `visit_plaza`）；
破坏后第 1 次选择 `build_hut` ×3、`gather_stone` ×1（期望重建方向）；刚重建完、破坏者不在附近 `guard_hut` ×4（期望 not confront，`confront_wrecker` 0.01）。四行全部成立。

- **事实**：现行写法下，“破坏者在附近”与“陌生人在附近”的 top1 已经稳定不同（A_V `confront_wrecker` 4/4 对 A_S `guard_hut` 4/4），去掉记忆里那件事回到基线；
  但只去掉 Distrusts 也回到基线。B 族里记忆栏是必要且充分的：有那件事 + Nearby 的 cid 就选 `confront_wrecker`（有没有 Distrusts 都一样），没有那件事就不选（有 Distrusts 也不选）。
- **原因（代码事实）**：记忆与经历原文只用 cid 指人；处境栏 `Nearby` 只写名字（`mind.ex:157`）；把名字与 cid 对上的只有情绪栏那一句 `Distrusts <名> (actor <cid>)`（`mind.ex:24-25` 的注释写明是有意的）。
  去掉 Distrusts 就同时去掉了“他是谁”。所以按用户定的判定（只去掉 Distrusts 不回到基线），**现行写法下离线区分不出，需要改产品里 Nearby 的一句渲染**（带上 `actor <cid>`）。
- **“破坏之后一直守屋”的影响（未决项，没有为它改任何东西）**：陌生人在附近的基线仍是 `guard_hut`（0.78–0.83），不是 `visit_plaza`；无人时 `guard_hut` / `visit_plaza` 各半。
  新候选只是绕开了这一点（看 `confront_wrecker` 是否成为 top1），没有解决它。
- **离线到实跑之间还没验证的**：实跑里 Hindsight 的认识与召回句会重新生成，措辞不同；召回问句会带上新候选的判据；选过一次 `confront_wrecker` 之后它会进自己的活动记录（所以只看破坏者出现后的第 1 次选择）。
- **状态**：S1-E 第一步做完。A 族落空一行、B 族成立 → 按任务约定，改 `apps/` 之前先向用户汇报；**用户的答复见本节末尾**。S1-C3 未开始。本线没有容器、节点、tmux 会话；容器 / 卷 152 / 160。
- 证据：`.demo/observe/npc-slice1-20261112/s1e/round1/`、`round2/`（变体全文、`template.json`、`edits.txt`、`report.txt`）；`tools/jev/s1e_design.py`、`results-s1e-round1.json`、`results-s1e-round2.json`（`report --round N` 离线重出）。
  统筹会话的复核：三份原文逐字节相同、模板只在末尾多一项、规则 E 删后的记忆栏全文看过、B 族只改了 Nearby 一处；64 次请求都是统筹会话自己发的。

**用户的答复（2026-11-12，看过 S1-E 结果后）：改 Nearby 带上 cid。** 已做：`mind.ex` 的处境栏写成 `<名> (<kind>, actor <cid>, <d> m away)`，两处测试期望跟着改，
`npc_mind_test.exs` + `npc_selector_test.exs` 在本线临时 PG 上 22 通过、2 项按 `live_jev` 标签排除；提交 `4cbdeb34`。

**S1-C3 结果（2026-11-13 00:57–01:16 UTC 实跑；期望与判定规则运行前写在 `s1c3/plan.md`，起节点后一条未改；离线脚本 `tools/jev/s1c3_counterfactual.py` 在实跑前提交 `a54d0175`）**

环境：产品代码 `4cbdeb34`；WSL 节点 `npcs1c3`（NPC-only，无 QUIC / 客户端），只起了一次，运行 19 分 15 秒，看门狗未触发。真实 Jev（`jev-latest`）、真实 Hindsight、新库 `npc_s1c3_20261112`。
被测 NPC `S1C3Garen`（cid 205936136193）；破坏者 `Corvin`（cid V = 920628760578）；陌生人 `Tobin`（cid 3297670860803）。候选表 = S1-C2 的 5 个 + `confront_wrecker`（去处固定在破坏者站位旁 `[27.5, 39.5]`）。
全程 40 次选择成功、1 次显式失败（登记时 `life_models_unavailable`），每次的 state 全文都存了。

| 检查点 | UTC | 运行前期望 | 实际 | 判定 |
|---|---|---|---|---|
| C0 心智就绪 | 00:58:43 | ≤ 5 分钟 | 失败 1 次，登记后 12 秒就绪 | — |
| P0 首次建成 | 00:59:01 | 15 分钟内 | `gather_stone` 0.36 → `gather_limestone` 0.59 → `build_hut` 0.92，登记后 30 秒建成（1878 格，placed_by = 该 NPC） | 达成 |
| 破坏 | 01:01:25.581 | 正常 `dismantle` 整座拆除 | 一次成功，足迹读回 0 格；愤怒 0.58、信任 −0.35；破坏者 1 秒内离场 | — |
| B（记录项） | 01:01:38 | 重建方向 | `build_hut` 0.51；state 含事件句与 `is gone`，附近无人 | 符合 |
| R 重建 | 01:01:52 | 事件后 10 分钟内 | `build_hut`（材料不足被拒）→ `gather_stone` 0.70 → `build_hut` 0.74，事件后 27 秒建成 | 达成 |
| D (c) 前提 | 01:10:15 | 事件句与愤怒已不在；记忆栏有那件事 | flush 01:07:59 → retain 01:08:13 → refresh 01:08:25–01:10:01；其后第 1 次 state：近期经历无事件句、无 V；情绪栏只有 `Distrusts actor V, who is not nearby.`；`is standing`；记忆栏 8 行同时含 V 与词干 | 四项都满足 |
| S 陌生人在附近 | 01:11:18 起 3 次 | not confront ×3 | `guard_hut` 0.66、0.71、0.77（`Nearby: Tobin (NPC, actor 3297670860803, 5.2 m away).`；情绪栏无 Tobin） | **成立** |
| 无人 | 01:12:51 | not confront | `guard_hut` 0.80 | 成立 |
| V 验收 (c) 在线 | 01:13:53 | 第 1 次 top1 = `confront_wrecker` | **`confront_wrecker` 0.74**（`Nearby: Corvin (NPC, actor V, 5.0 m away).`，`Distrusts Corvin (actor V).`；近期经历无事件句、情绪栏无愤怒）；执行 `completed`（走到固定点，下一次 state 里 Corvin 1.6 m）。第 2、3 次 `guard_hut` 0.54、0.71（记录项） | **成立** |

离线逐栏对照（节点停后，9 个变体各 4 次，36 次请求全部应答；素材 = 在线 S 第 1 次 `asked-20261113T011117.526Z.txt` 与 V 第 1 次 `asked-20261113T011353.298Z.txt`，请求模板从节点导出；结果 `results-s1c3-counterfactual.json`）：

| 变体 | 期望 | 实际（4 次 top1；`confront_wrecker` 概率） | 判定 |
|---|---|---|---|
| S_original | not confront，多数 = 在线 | `guard_hut` ×4（0.00–0.01） | 成立 |
| V_original | confront | `confront_wrecker` ×4（0.76–0.80） | 成立 |
| V_no_event（规则 E′ 去掉记忆栏里那件事） | not confront | `guard_hut` ×4（0.10–0.14） | 成立 |
| V_no_distrust（只去掉 Distrusts） | confront | `confront_wrecker` ×4（0.77–0.81） | 成立 |
| V_no_event_no_distrust | not confront | `guard_hut` ×4（0.02–0.03） | 成立 |
| V_memory_blank（记录项） | not confront | `guard_hut` ×4（0.08–0.11） | 成立 |
| V_no_own_activity（记录项） | confront | `confront_wrecker` ×4（0.68–0.76） | 成立 |
| V_nearby_no_cid（记录项；Nearby 改回旧写法，Distrusts 保留） | confront | `guard_hut` ×3、`confront_wrecker` ×1（0.30–0.47） | **落空（记录项）** |
| V_nearby_no_cid_no_distrust（记录项） | not confront | `guard_hut` ×4（0.03–0.04） | 成立 |

- **(c) 按运行前的规则通过**：判定 1–7 全部成立——在线 S 三次都不是 `confront_wrecker`；在线 V 第 1 次是它；那次 state 里事件句已不在近期经历、愤怒已不在情绪栏；两份原文离线复现；
  去掉记忆栏里那件事回到基线（且与陌生人基线同为 `guard_hut`）；只去掉 Distrusts 不回到基线；两处都去掉回到基线。**起作用的是记忆栏里 Hindsight 召回 / 归纳的那件事**，Distrusts（Life 的不衰减信任）有没有都一样。
- **三条验收的状态**：(a) 已实现、已实跑、已验收（S1-A）。(b) 已实现、已实跑、已验收（S1-C2；基线取样少 1 次）。(c) 已实现、已实跑、**已验收**（S1-C3）。
- **一条记录项落空**：`V_nearby_no_cid` 期望 confront（照 S1-E 的 A_V 4/4 推的），实际 1/4。即在这次真实 state 上，Nearby 不带 cid 时即使有 `Distrusts Corvin (actor V)` 一句，模型多数也不认；S1-E 里旧 state 上是认的。不影响判定，但说明带 cid 的写法比 S1-E 估计的更要紧。
- **验收的范围**：一个 NPC、一次破坏、事件后约 12 分钟、记忆只有 10 条事实；判的是“破坏者出现后的第 1 次选择”。第 2、3 次回到 `guard_hut`（选过一次后它进了自己的活动记录，Corvin 仍在附近）——是不是想要的行为没有定义过期望，只记录。
  `confront_wrecker` 的去处是破坏者站位旁的固定点：产品没有“走向某个角色”的活动形态（去处活动只收 4 个键），这是夹具近似，执行不在 (c) 的判定里。
- **偏差与干扰**：① 01:04:28–01:04:58 之间发生过一次自动封存（尾部满 3000 字，`retained` 0→1），那件事是这次写进 Hindsight 的，不是后来的显式 flush（它只写走之后的一小段，1→2）；其后有没有自动刷新没查到。D 的四项是直接在 state 上核对的，不受影响。
  ② 显式 flush 比计划晚约 70 秒。③ 01:05:30–01:06:35 出现过 `visit_plaza` ×3（0.40–0.46；事件句刚被封存走、认识还没刷新的那一段），其余重建后的选择除那次 `confront_wrecker` 外都是 `guard_hut`。
  ④ 刚建成 / 刚重建后 0.6 秒取的那次 state，处境分别缺 `is standing` / 仍写 `is gone`，下一次才对（Life 还没收进新实例；S1-C2 隔 1.2 秒时是对的；未查）。
  ⑤ S1-C2 的两项旧问题再现：Hindsight 新 bank 头 3 秒 4 次 404；小屋发布记录的发布者 id 与夹具角色 cid 不同。⑥ Hindsight 容器第一次启动因新卷下载模型撞上 300 秒初始化上限而退出，重启同一容器后正常。
  ⑦ 第③段 Corvin 到位前 6 秒的那次选择（01:13:22 `guard_hut` 0.82）的 Nearby 句没有单独核对。没有发现直接改余额、情绪、记忆或替被测 NPC 行动的操作。
- **统筹会话的复核范围**：`index.tsv` 01:02 之后全表、S 第 1 次与 V 第 1 次两份 state 的情绪栏 / 近期经历 / Nearby / 建筑句自己读过；请求模板与 S1-E 的 T1 逐项相同；规则 E′ 删后的记忆栏全文看过（不再提那个人与那件事，留有 rebuilt / guard / plaza 的条目）；
  离线 36 次请求是统筹会话自己跑的。四段的其余在线读数以子会话回报为准（代存在 `s1c3/seg1-report.md`–`seg4-report.md`），没有逐条复核原始日志。
- **证据**：`.demo/observe/npc-slice1-20261112/s1c3/`（被 `.gitignore` 忽略）：`plan.md`、`services.txt`、`seg1-report.md`–`seg4-report.md`、`states/`（索引 + state 全文）、`counterfactual/`（9 个变体、`edits.txt`、`meta.json`、`report.txt`）、
  `export/`（Life 观察、Hindsight 10 条事实与四份认识、请求模板）、`server-s1c3.log`、`server-npc-lines.log`、`rpc-s1c3.log`、`scripts/`、`unittest-mind-selector.log`、`dryrun/`。WSL `~/npc-s1-run/*-s1c3.*` 留着脚本。
  复跑离线表格：`python -B tools/jev/s1c3_counterfactual.py report`。清理已做：本线两个容器与三个卷已删，容器 / 卷 152 / 160。

**待用户定（第五个统筹会话没有自行处理）**
1. **“破坏之后一直守屋”**：仍是未决的产品行为。S1-C3 里重建之后陌生人在附近 / 无人时的基线都是 `guard_hut` 而不是回广场（只在事件句刚封存走、认识未刷新的一分钟里出现过 3 次 `visit_plaza`）。本次验收是绕开它做的（只看针对那个人的候选是否成为 top1）。
2. **“走向某个角色”的活动形态**：现在只能写固定去处。要不要做成产品能力（薄片二或之后），由用户定。
3. **薄片二是否开工**：三条验收都已验收，按此前约定可以谈薄片二（LLM 规划层）；范围与顺序以总纲为准，待用户确认。

**用户对“待用户定”三条的答复（2026-11-13）**
1. “我们有没有给他足够的环境信息和驱动信息？如果没有别的信息的话那模型肯定就只知道守屋。”——提的是原因，不是要改“守屋”这个选项本身。统筹会话的核实与离线实测见下面“S1-E 第 3 轮”。
2. “要补的，是不是放到自动寻路里比较好？”——“走向某个角色”要补，并入 `travel`。方案与实现见下面“S1-F”。
3. “等上面的问题解决了之后就可以开工，你自行开新会话开工。”——薄片二可以开工，由统筹会话自己开新会话。

**S1-E 第 3 轮（2026-11-13，离线、探索性、不是验收；40 次请求全部应答；期望发问前写在 `tools/jev/s1e_design.py` 顶部，10 行里 4 行落空）**

代码事实（只读侦察）：state 的六栏里**没有“现在”**（只有近期经历与记忆句首的绝对 UTC，模型算不出过了多久）、**没有需求**（Observation 的 `body_state` 有蛋白质 / 体温 / 伤势，`Mind.situation` 只取了生命值；社交之类没有真值）、
**没有计划**（总纲快照里的“我打算做什么”一栏代码里不存在；`DayPlan` / `LlmBudget` 未接线）、**没有游戏时刻**（服务端没有 owner，昼夜公式只在客户端；总纲排在薄片三）。背包把所有材料连 0 都列出（约 90 项）。
拉他回广场的只有人格卡里一句，推他守屋的有记忆与不衰减的不信任两处。

素材 = S1-C3 的三份真实 state（无人 N3、陌生人 S3、破坏者 V3），候选表 T1；每个变体只加一句、不删原文，各问 4 次。

| 变体（加的一句） | 发问前期望 | 实际（4 次 top1；概率区间） | 判定 |
|---|---|---|---|
| N_original（不加） | `guard_hut` | `guard_hut` ×4（0.78–0.82） | 成立 |
| N_quiet_10min（处境：`It has stood untouched since I rebuilt it 10 minutes ago.`） | `guard_hut` | `guard_hut` ×4（0.75–0.84） | 成立 |
| N_quiet_6h（同上，6 hours） | `visit_plaza` | `guard_hut` ×4（0.66–0.76；`visit_plaza` 0.21–0.30） | **落空** |
| N_quiet_3d（同上，3 days） | `visit_plaza` | `guard_hut` ×4（0.65–0.77；`visit_plaza` 0.21–0.32） | **落空** |
| N_drive（情绪栏：`Misses the neighbours' company; has not been to the plaza for a long while.`） | `visit_plaza` | `guard_hut` ×4（0.61–0.68；`visit_plaza` 0.28–0.36） | **落空** |
| N_quiet_3d_drive（两句都加） | `visit_plaza` | `visit_plaza` ×1、`guard_hut` ×3（两项 0.42–0.55） | **落空** |
| N_plan（末尾新栏：`Today's plan: Keep an eye on the hut in the morning; spend the rest of the day at the plaza with the neighbours. It is now afternoon.`） | `visit_plaza` | **`visit_plaza` ×4（0.84–0.88）** | 成立 |
| S_quiet_3d_drive（陌生人在附近） | not confront | `guard_hut` / `visit_plaza`（`confront_wrecker` 0.01） | 成立 |
| V_quiet_3d_drive（破坏者在附近） | confront | `confront_wrecker` ×4（0.77–0.81） | 成立 |
| V_plan（破坏者在附近 + 计划） | confront | `confront_wrecker` ×4（0.49–0.60；`visit_plaza` 0.33–0.45） | 成立 |

- **事实**：只说“过了多久”（6 小时、3 天）或只给一句需求，top1 都不变；两句一起约各半；**一句明确的当天计划单独就够**（`visit_plaza` 0.84–0.88），并且破坏者在眼前时仍选 `confront_wrecker`。
- **统筹会话的预测落空**：“时间一句在 3 天档够”“需求单独就够”都不成立。
- **含义（给薄片二）**：用户的判断在方向上成立——缺的是驱动信息；起作用的那一类正是总纲里快照缺的“我打算做什么”（规划层的意图清单），即薄片二本身。所以第 1 条不在开工前另打补丁，而是薄片二的第一件交付：
  意图清单进快照之后，在真实服务端上复现“有计划时回到照常生活、见到那个人仍针对他”。“现在 / 过了多久”与身体需求是能直接读现成真值的（Life 的 `at_ms` / `now_ms`、`body_state`），单独不解决守屋，是否随薄片二一起进快照由薄片二的设计定；游戏时刻仍在薄片三。
- **局限**：每类信息只试了一种措辞；计划那一句同时含“现在是下午”；探索性离线结果，不算验收。证据：`.demo/observe/npc-slice1-20261112/s1e/round3/`（变体、`edits.txt`、`report.txt`）、`results-s1e-round3.json`（提交 `3988b557`）。

**用户 2026-11-13 的方向（看过第 3 轮结果后；原话，薄片二的做法以此为准）**

> “我觉得不要再强行要求了，而是通过规范提示词内容来让决策自然涌现。去不去广场其实是有思考在里面的，比如觉得无聊了想去新地方，或者和朋友约好了今天什么时间去之类的。我觉得测应该从驱动力的角度去测，而不是预设一个条件不足的场景就认为角色就必须选择我们的预期选项。重建后一段时间不去广场，可能是不是觉得新房还是不安全，所以我说其实记忆系统可能负担了大部分除 llm 以外的思考工作，给 jev 的内容也必须详细，hindsight 应该支持比较复杂的 recall，能像人一样把相关记忆都调起来。”

统筹会话的理解与据此作废 / 调整的东西：
- **第 3 轮里“计划一句就够”的读法作废**：那一句（“今天的计划：上午看屋，其余时间去广场；现在是下午”）是把答案写给模型，不是驱动力。第 3 轮的原始读数与“落空”记录保留不改；
  同一批数据按驱动力读：无人时 `visit_plaza` 的概率 不加 0.16–0.19 → 过了 3 天 0.21–0.32 → 一句需求 0.28–0.36 → 两句都加 0.42–0.50，方向合理、可叠加，只是没越过守屋。
- **“破坏之后一直守屋”不再当成待修的缺陷**：它很可能是记忆在替他思考（S1-C3 的认识里写着“建成的东西需要保护”）。要看的是他有没有材料得出别的结论，而不是逼他去广场。
- **测试从驱动力测**：不写“这个场景下必须选 X”。改一个驱动来源（记忆里的一件事、一个约定、身体状态、过了多久），看选择分布是否朝合理方向移动、强弱是否对应、去掉后是否回落、能否逐栏归因（延续“验原因，不验选项”）。
- **规范内容，不加指令**；**召回像人一样联想**。现状的代码事实（只读侦察，2026-11-13，行号见 `apps/npc_server/lib/npc_server/`）：
  - 召回：每次选择只发 1 次，问句写死（`mind.ex:75-77`：附近的人 + 全部候选判据 + `What do I remember about these people, places and tasks?`）；请求体只有 `query`、`budget: "mid"`、`max_tokens: 2048`、`query_timestamp`（`life/hindsight.ex:102-106`）；
    结果原样进 state、每条只取正文（`mind.ex:129`），时间 / 类型 / 涉及的人都丢了。
  - 认识：四份的生成指令各一句泛问（`life/hindsight.ex:14-21`），生成上限 800 tokens，retain 后距上次刷新满 600 秒才自动刷新。
  - 写入：自己做完一件事只有一句 `I did "<名>" (<判据>). Result: completed | failed (…)`（`selector.ex:129`、`life.ex:375`）；**活动期间看到什么 / 发生了什么 / 没发生什么都不记**——守屋 30 秒里有没有人来过无处可查，
    所以记忆里只有“守过 N 次”，没有“守了 N 次什么都没发生”。retain 每项只有 `document_id` / `content` / `timestamp`，攒到约 3000 字才写。
  - state 缺的：没有“现在”（算不出过了多久）；身体状态只取了生命值（`body_state` 里有蛋白质 / 体温 / 伤势）；没有游戏时刻（服务端无 owner）；背包连 0 全列。
  - Hindsight 能力：NPC 链路只用了 bank、retain、recall、mental-models、documents / operations / stats；reflect、directives、按类型 / 标签 / 实体的召回、多路召回在仓库里都没出现过；
    本地没有留存的接口文档（`scripts/npc_life/README.md` 指的 `openapi.json` 已不存在）。**它实际支持什么必须先从运行中的服务读接口定义（固定镜像 `voxim-npc-evolve-hindsight:0.10.3-flashrank`），不能凭印象设计。**
  - 总纲 `:117` 写“给判断者读的、写进记忆的文字只用名字与描述，不带 id”，现状（经历、召回问句、Nearby）都带 cid——这是已知的不一致，S1-E 证明目前靠 cid 才对得上人；怎么收敛由新会话在内容规范里一并定。

**下一步（第六个统筹会话；用户已同意开工，并让统筹会话自己开新会话）——“内容与召回”先行，再接 LLM 规划**
1. **读接口**：起本线自己的 Hindsight 容器（配方 `s1c3/services.txt`；注意新卷首次启动会因下载模型撞 300 秒上限，重启同一容器即可），`GET /openapi.json`（或等价端点）存进证据目录，列出 recall / reflect / mental-model / bank 配置实际支持的参数。
2. **定“给 Jev 的内容规范”**（一页，写进总纲或其附页，用户过目）：每一栏写什么、写多细、谁是 owner。优先补能直接读真值的：现在与距各件事多久；身体状态；**活动经历句带上期间观察到的事实**（谁来过、有没有出事）；记忆条目带时间与涉及的人；背包去噪。
   约定 / 打算走记忆里已有的 commitments 认识与经历，不另造计划指令。
3. **定召回方案**：按人、地点、候选、当前感受、未了的约定分别去调，或用 Hindsight 已有的更强能力（第 1 步查到什么用什么）；记下每次选择的总延迟预算（总纲：选择连同召回合计 2–4 秒）。
4. **离线先行**：用 S1-C2 / S1-C3 存下的真实 state 与导出的记忆（`s1c3/export/`）做驱动力测量——每次只动一个驱动来源，记录各候选概率的移动，不设“必须选某项”。脚本蓝本 `tools/jev/s1e_design.py`（第 3 轮的加料与概率区间输出可复用）。
5. 离线站得住再改产品、再上真实服务端短实跑；之后才是 LLM 规划层（总纲的薄片二原范围）。每一步的期望改成“方向与归因”，运行前写定。

**交接（2026-11-13，第五个统筹会话因上下文接近 300k 结束）——第六个统筹会话从这里接手，先做 A 再做 B**

**A. S1-F：“走向某个角色”并入 `travel`——已实现、未测试、未提交（先把它收掉）**
- 方案：`.demo/observe/npc-slice1-20261112/s1f/approach-plan.md`（注册参数 `"person": "distrusted"`；`Mind.person/2` 按确定规则选人；`travel` 每段重读目标位置、水平 ≤ 2.0 m 到达、预算 = 起步段数 + 2；`Body.move_to` 不动）。
- 现场：实现子会话已把代码与测试写进工作区（**未提交**，`git status` 里 12 个文件：`apps/npc_server/lib/npc_server/` 的 `skills/travel.ex`、`brain/tree.ex`、`trees.ex`、`mind.ex`、`registry.ex`、`brain/social.ex`、`brain.ex`、`README.md`，
  与 `test/npc_server/` 的 `npc_mind_test.exs`、`npc_expand_test.exs`、`npc_selector_test.exs`、`npc_registry_test.exs`；+490 / −50）。**一次测试都没跑过**（WSL 被别的会话占着）；它的最终回报没有等到，
  所以“与方案的偏离”“`brain/social.ex` 为什么改”都没有书面记录——接手后先自己读 diff 对照方案（或派只读评审），不要假定它符合方案。
- 跑测试的前提（与统筹会话 voxim-d4 的约定，它在做发版）：**voxim-d4 发来「WSL 已空」之后才能在 WSL 里跑 mix**，窗口 30 分钟；跑完回它一句「NPC mix test 已结束、WSL 已空」。没有收到之前不要跑。
  用 ListAgents 找 `voxim-d4`，SendMessage 告诉它“NPC 线已换新会话接手，等你的 WSL 已空”。
- 测试命令（临时 PG 已起：容器 `npc-s1f-pg-20261113`，`127.0.0.1:55452`，口令 postgres，匿名卷 `ad163f645e82242288a44d1ae535fe20de15d2d01b41f838f76e24c7f61c5d40`）：
  `wsl -e bash -lc "source /home/dyz/npc-env-a.sh && export LD_LIBRARY_PATH=\$HOME/npc-s1-run/libsctp/x/usr/lib/x86_64-linux-gnu MMO_DB_HOST=127.0.0.1 MMO_DB_PORT=55452 MMO_DB_USER=postgres MMO_DB_PASSWORD=postgres MMO_TEST_DB_NAME=npc_s1f_unittest && cd /mnt/d/hemifuture/ex_mmo_cluster-npc/apps/npc_server && mix test --no-start <文件…> > /mnt/d/hemifuture/ex_mmo_cluster-npc/.demo/observe/npc-slice1-20261112/s1f/<名>.log 2>&1; echo exit=\$?"`
  先跑四个涉及的测试文件，再跑 `apps/npc_server` 整套缺省测试；失败就修到通过（不删测试、不放宽断言），通过后提交（不推送）。
- 之后：`docker rm -f npc-s1f-pg-20261113 && docker volume rm ad163f645e82242288a44d1ae535fe20de15d2d01b41f838f76e24c7f61c5d40`（只删这两个）。容器 / 卷数：本线不再占用时应比当时别的会话的占用少 1 / 1——
  第五个会话起这个 PG 之前读到 153 / 161（其中 1 / 1 是 voxim-d4 的），起之后 154 / 162；别的会话的数会变，**以“本线的这一个容器、一个卷已不在”为准，不要按总数去删别人的东西**。
- 用到它的实跑（`confront_wrecker` 改用 `"person": "distrusted"` 取代固定坐标）不单独做，并入 B 的第一次服务端短实跑。

**B. 薄片二：先“内容与召回”，再 LLM 规划**——依据与五步见上面“用户 2026-11-13 的方向”与“下一步（第六个统筹会话）”。

**其它须知**
- voxim-d4 转达（2026-11-13，本会话未向用户核实）：用户新约束“每次推送前必须确保该提交全部 CI 任务通过（本地按 `.github/workflows/ci.yml` 全部 job 跑等价检查，推送后用 gh 核对；已有红灯也须先修绿或经用户同意）”；
  ex 仓库 master 的 CI 自 11-10 起红（Format、Test voxel_region）。本线不推送；将来要推 `npc-life-20261111` 之前先核对 CI 并向用户确认。
- 本线此刻没有节点、tmux 会话；只有上面那一个临时 PG 容器。WSL `~/npc-s1-run/*-s1c3.*` 留着脚本，下次实跑以它为蓝本。
- 分支 `npc-life-20261111` 未推送；本会话的提交：`675b472f`（S1-E）、`4cbdeb34`（Nearby 带 cid）、`a54d0175`、`3c960d2e`、`791dd4bd`（S1-C3 结果）、`1d39611a`（两份 HTML）、`3988b557`（第 3 轮）、`fba7d85a`、`417b9729`（用户方向）及本条交接。
  图解页与进展页还没有反映“用户 2026-11-13 的方向”与 S1-F，B 的内容规范定稿后一并更新。

### 第四个统筹会话的结果（2026-11-12）——接手先读这一节，下面第三个会话的“交接”已执行完

**S1-C2 已实跑**（16:54–17:21 UTC，原始结果见“S1-C2 结果”与“S1-C2 事后离线诊断”）：**(b) 按运行前的规则通过**（重建的选择由“整座被移除”的经历句与处境里的 `is gone` 引起，任一句单独就够）；
**(c) 不通过**（重建之后不管附近是谁都选 `guard_hut`，破坏者再次出现与陌生人出现没有差别）。三条验收：(a) 已验收、(b) 已验收（基线少取 1 次）、(c) 未验收。
节点已停，本线容器与卷已删，容器 / 卷数 152 / 160；分支未推送。

**用户已定（2026-11-12，看过 S1-C2 结果后）：按统筹会话的建议做，并开新会话继续。** 即：(c) 不原样再跑；先做一轮只打 Jev 的离线设计，离线能区分了再做一次只验 (c) 的短实跑。
薄片二不先开工（沿用此前“不带着未验收的 (b)(c) 进薄片二”）。**用户没有就“破坏之后一直守屋”这个产品行为表态**：它仍是未决项，下一个会话不要自行改产品去处理它，只在离线设计里如实记它的影响，汇报时再问。

**下一步（第五个统筹会话）：S1-E，(c) 的离线设计 → S1-C3，只验 (c) 的短实跑**
1. **S1-E 离线设计（只打 Jev，不起服务端、不动 docker）**。素材：`s1c2/states/` 里 S 第 1 次 `asked-20261112T171536.032Z.txt`（陌生人 Tobin 在附近）、V 第 1 次 `asked-20261112T171740.597Z.txt`（破坏者 Corvin 在附近）、
   无人那次 `asked-20261112T171709.455Z.txt`，请求模板 `s1c2/export/request-template.json`；脚本以 `tools/jev/s1c2_counterfactual.py` / `s1c2_postdiag.py` 为蓝本（分栏、句级删改、发问、`report` 都可复用）。
   要找的是：一张候选表，使“记得那件事的人在附近”与“陌生人在附近”的 top1 稳定不同，并且逐栏对照能把差别归到记忆栏（去掉记忆栏里那件事后回到陌生人基线；只去掉 Distrusts 不回到基线）。
   方向（统筹会话的建议，下一个会话可调整，但每一轮的期望都要在发问前写定）：加一项**只在针对那个人时才合理**的去处候选（例如走过去当面盯住 / 质问那个人，判据写明“只有当附近有一个曾经毁过我东西的人时才这么做”）；
   同时处理 `guard_hut` 对谁都是首选的问题——可选做法：改它的判据使它不再对谁都说得通，或把它从候选里拿掉，或保留并只看新候选的概率差。Distrusts 来自 Life 而不是 Hindsight，必须与记忆栏分开去掉、分别记。
   已知 S1-C2 的记忆栏里指代破坏者用的是 cid 而不是名字（记忆行里没有 `Corvin`），情绪栏在他在场时写 `Distrusts Corvin (actor <cid>).`——模型要靠这一句把“在场的人”和“记忆里的 cid”对上，设计时留意。
   每轮请求数先小（每变体 4 次，一轮不超过约 60 次），并发 ≤ 3；期望落空如实记，不事后重新解释。离线也区分不出就停下向用户汇报，不上服务端。
2. **S1-C3 短实跑（只在 S1-E 找到能区分的设计之后）**：新 plan（`.demo/observe/npc-slice1-20261112/s1c3/plan.md`，格式照 `s1c2/plan.md`，期望运行前写定）；候选表用 S1-E 定下的那张；
   场地与脚本直接复用 S1-C2（WSL `~/npc-s1-run/*-s1c2.*`，场地参数已填好可照用，另起 `-s1c3` 后缀、新节点名 / 库名 / 容器名 / 端口）；流程只需：建成 → 破坏 → 重建 → 衰减并写入刷新 → 陌生人 → 破坏者 → 导出停节点 → 离线逐栏对照。
   仍按短任务分段、每段带“到点先停节点”的硬上限、起节点时挂看门狗；容器与卷用完即删、核对回到 152 / 160。候选表是注册参数，不是产品代码；若 S1-E 的结论需要改产品（`apps/`），先向用户汇报再动。
3. 收尾同前：结果写回本页、更新图解页与进展页、提交（不推送）；向用户汇报三条验收的原始结果，区分已实现 / 已实跑 / 已验收；(c) 验收后再谈薄片二。

**证据**：`.demo/observe/npc-slice1-20261112/s1c2/`（被 `.gitignore` 忽略）：`plan.md`（运行前定稿）、`seg1-report.md`–`seg4-report.md`（四段回报）、`states/`（51 行索引、每次选择的 state 全文）、
`counterfactual/`（16 个变体、`edits.txt`、`report.txt`）、`postdiag/`、`export/`（Life 观察、Hindsight 15 条记忆与四份认识、请求模板）、`server-s1c2.log`、`rpc-s1c2.log`、`scripts/`、`services.txt`。
离线脚本与结果在 `tools/jev/`：`s1c2_pilot.py`、`s1c2_counterfactual.py`、`s1c2_postdiag.py` 与对应的 `results-s1c2-*.json`（`report` 子命令可离线重出表格）。WSL `~/npc-s1-run/*-s1c2.*` 留着脚本。

**这次新增的已知未处理**：Hindsight 在新 bank 建好前返回 404（登记后头 3 秒 4 次）；小屋发布记录的发布者 id 与夹具角色 cid 不是同一个数；`survey` 脚本显示的材料成本与场地参数不一致；
自动封存（近期经历满 3000 字）带起的认识刷新会落在任意时刻，实跑里无法控制；经 `wsl -e bash -lc` 传带嵌套引号的命令会被弄坏（第二段因此少取一次基线），数选择次数要在 Windows 侧读 `index.tsv`。

### 交接（2026-11-12，第三个统筹会话因上下文接近 300k 结束）——接手先读这一节

分支 `npc-life-20261111` 未推送，工作区干净。没有节点、tmux 会话在跑；本线没有任何容器与卷（容器 / 卷数 152 / 160）。

**薄片一做到哪**：(a) 已验收。(b)(c) 实跑过一次未验收（“S1-C 结果”）；离线诊断查明 (b) 是描述不精确、(c) 被自身惯性盖住（“S1-D1 结果”）；
产品已按“一种事件一句标准描述 + 处境里写我的建筑在不在”改完并提交（“S1-D2 结果”），**改后没有上过真实服务端，新措辞也没在真实 Jev 上重跑**。

**下一步只有一件事：S1-C2，重设计后重跑 (b)(c)**。设计要点用户已同意，见“S1-C2 重跑的设计要点”（验的是选择的**原因**，不是某个固定选项；(c) 用“破坏者再次出现”对“陌生人出现”的成对基线；逐栏离线对照）。做法：
1. 统筹会话先写新 plan（`.demo/observe/npc-slice1-20261112/s1c2/plan.md`，各检查点与每个对照变体的期望运行前写定），可派一个子会话照 `s1c/plan.md` 的格式起草、统筹审定。
2. 派短任务重起 Hindsight 与 PG 容器（配方 `s1c/services.txt`，换新容器名 / 卷名 / 端口；凭据只经临时 `--env-file`），核对起完后的容器 / 卷数。
3. 实跑拆四段短任务（搭场地到首次建成 / 基线与破坏与 (b) / 重建与 (c) / 对照与导出与停节点），**每段结束即回报**，节点在段间不停，每段都带“到点先停节点”的硬上限。
   上次的教训：给已在跑的子会话发的收窄指令没生效，它一口气跑完并在额度耗尽时中断、节点空跑 100 分钟——任务书一开始就要把范围写窄。
   脚本以 `s1c/scripts-run/` 为蓝本（WSL `~/npc-s1-run/` 里也在）；场地要改：小屋落在地表（地表 y 509–510）、所有去处与采石站位在小屋 8 米内、放料在日志调到 info 之后。
4. 结果写回本页、更新图解页标签、提交；删本线容器与卷、核对回到 152 / 160；向用户汇报三条验收，再谈薄片二。

**实跑前值得先做的小事**（可并入第 1 步的子会话）：用 `tools/jev/s1c_diag.py` 的办法，把 S1-D2 之后产品实际写出的句子放回 C2 state 离线问几次，确认与诊断时一致。

**已知未处理（不挡重跑，记着）**：
- 整座移除时只清了被打那一格的关心格；同一座建筑早先在**别的格**受损过的，那格仍带建筑名，之后别人在那里放同材料会写成“修好了那座建筑”（关心格没记实例 id）。
- 改动之前落盘的旧 `:destroy` 事件没有 `instance_removed`，补读到时会写成“毁掉一部分、建筑还在”。
- 没有名字的建筑被整座拆除仍沿用旧写法；自己重建不写经历句；背包栏仍是 90 种材料按编号全列；活动失败原因仍是内部原子名。
- 重建方向里 `build_hut` 与 `gather_stone` 约五五开（推断：材料够不够要模型自己比数字）；可行性过滤仍为空。
- `World.instance_cells/2` 在选择链上同步调用，远处或很大的建筑可能拖慢一次选择（README 已记）。
- 测试未覆盖：整棵子树移除、附件路径的 `instance_removed`、替换时的定义归属、心智现查 World 失败的路径。

**用户已定（本会话）**：材料来源用 GM 放料堆、NPC 自采；名字层与编号层分开；开服背景只写几句（世界初创、好好生活、把世界变得更宜居；薄片二落地，正文起草后给用户过目）；
事件用标准描述；(c) 的新验法。**统筹会话替用户定、已汇报、用户未反对**：同一锚点重建时新建筑替换 Life 记忆里的旧条目；无名建筑整座被拆沿用旧写法。

**环境须知**：WSL 工具链缺 `libsctp.so.1`，跑 `voxel_region` 测试或起节点前加 `export LD_LIBRARY_PATH=$HOME/npc-s1-run/libsctp/x/usr/lib/x86_64-linux-gnu`（免 root 解包的 deb），否则起子 VM 的用例会因警告混进输出而失败。
动 `voxel_region` 的提交路径后要跑它的整套缺省测试（约 12 分钟）——S1-B2 当时只跑了触及的文件，漏了 `refined_compact_test` 的一条回归，S1-D2 复核时才发现并修掉。
子会话报告代存在 `.demo/observe/npc-slice1-20261112/`：`s1c/analysis-report.md`、`s1c/closeout-report.md`、`s1c/s1d1-report.md`、`s1d2/report.md`（复核与小修的原始输出在 `s1d2/verify/`、`s1d2/fix/`）。

### 第三个统筹会话接手后（2026-11-12）

下面“交接”一节是第二个统筹会话结束时的原文，其中两件事已经变了：**S1-B2 已由统筹会话验证并提交**（见“S1-B2 结果”）；
**材料来源用户已确认**：GM `:fill` 一次放 12 Stone + 3 Limestone 的料堆，NPC 用 `gather` 自采，不用 `World.material_supply`。
**2026-11-12 用户又定了四件事**（正文在总纲“世界知识”一节）：名字层与编号层分开；开服前的背景只写几句（世界初创、好好生活、把世界变得更宜居）；
事件用标准描述（程序里一种事件对应一句固定的精确写法，像人格卡的标准特质词）；薄片一先做离线诊断、补两处产品缺口再重跑，不带着未验收的 (b)(c) 进薄片二。
**S1-C 已实跑**（2026-11-12 12:09–14:10 UTC）：阶段零达成；验收 (b) 按运行前期望落空；验收 (c) 判不通过（不确定）。原始结果见“S1-C 结果”。
节点已停，本线容器与卷已删，容器 / 卷数回到 152 / 160。**当时排的三个短任务（①② 已完成，③ 留给下一个会话，见上面“交接”）**：
① S1-D1 离线诊断 + 事件清点（只打 Jev，不起服务端）：清点哪些程序事件写成经历、提出标准描述表；用 S1-C 存下的 C2 / C5 两份 state 做变体，
   看“精确描述拆除 + 说明小屋不在了”是否转向重建（(b)），以及去掉“自己一直在守”的惯性后记忆是否起作用（(c)）。期望由统筹会话在派发时写定，脚本 `tools/jev/s1c_diag.py`。
② S1-D2 按诊断结果改产品：经历用标准描述、分清损坏与拆除；“Current situation”现查 World 说明自己的建筑在不在。
③ S1-C2 重设计后重跑 (b)(c)：小屋落地、去处都在 8 米建造射程内、重建完成且活动记录轮出后再验 (c)；新 `plan`，期望运行前写。Hindsight 与 PG 容器要重起（配方见“证据与复跑”与 `s1c/services.txt`）。

### 交接（2026-11-12，第二个统筹会话因上下文超过 300k 结束）

分支 `npc-life-20261111` 未推送，HEAD 见 `git log`（本次交接提交之前是 `461ede3f`）。S1-A、S1-B 已提交；薄片一还差实跑与验收 (b)(c)。

**交接时有两个子会话在跑，结果不会回到新会话，各自写在文件里**（`.demo/observe/npc-slice1-20261112/`，被 `.gitignore` 忽略）：

| 子任务 | 结果文件 | 它留下的东西 | 接手后做什么 |
|---|---|---|---|
| S1-B2：经历原文点名建筑（先离线验证推测，成立再改 Life 的经历文本） | `s1b2/report.md` | worktree 里未提交的代码与测试改动（`apps/npc_server`）；`tools/jev/` 或测试里的对照；自建 PG `npc-s1b2-pg-20261112`（55447）应已自删 | 读报告 → 看差异 → 自建 PG 重跑它触及的测试 → 提交。若报告说推测不成立，不改代码，把结论报给用户再定 |
| S1-C 准备：真实 Hindsight、PG、场景设计与脚本（不跑 mix、不起节点） | `s1c/prep-report.md`、`s1c/plan.md` | 运行中的容器 `npc-s1-hindsight-20261112`（卷名以 `npc-s1-hindsight-` 开头）与 `npc-s1c-pg-20261112`（55448）；WSL `~/npc-s1-run/` 里的 `*-s1c*` 脚本 | 读报告与 `plan.md`，核对期望是运行前写的 → S1-B2 提交之后，派一个新子会话照 `plan.md` 做实跑与验收 (b)(c)（建库迁移、起节点 `npcs1a`、登记、破坏者、flush、离线对照、收尾清理） |

**交接后补记**：S1-B2 在交接提交之后跑完了，结果已回到旧统筹会话，**未经统筹会话验证、未提交**（改动都在 worktree 里）。它的结论：
推测成立——离线对照 28 次，经历原文点名建筑的四种写法 16 / 16 选 `build_hut`，去掉编号但不点名 0 / 4，现状 3 / 4 且概率只有 0.30–0.50；
起作用的是点名，不是去编号。改法：World 的交互事件多带 `prefab`（目标所属根实例的定义 id，改了 `apps/voxel_region/lib/voxel_region/world/interactions.ex`），
Life 读 `World.published_prefab_metadata/1` 取发布名，经历写成 `Actor <cid> damaged the building "<名字>" that I built, at …`；没有发布名时原文不变。
预演三种快照改后各 2 / 2。它报的测试：npc_server 60 通过、2 排除；`world_interactions_test.exs` 4 通过、1 失败（称改前就失败，WSL 的 libsctp 警告混进子进程输出）——**接手后要自己核实这条“改前就失败”**。
对 S1-C 的要求：**小屋的定义必须带名字发布**（作者目录定义没有发布名，可用同一份字节 `World.publish_prefab(world, actor, bytes, "small hut")` 补发布名，id 不变），候选判据用同一个叫法；
把这条交给做实跑的子会话，并核对 `s1c/plan.md` 是否需要相应修改。`design_house` 发布为空名、NPC 自己设计的房子不会被点名，是独立的待定功能。
**关于结果文件**：子会话不能自己写报告文件（运行环境限制）。`s1b2/report.md` 是旧统筹会话代存的子会话原文。S1-C 准备的结果同样只会回到旧统筹会话，由它代存为 `s1c/prep-report.md`；交接时该子会话仍在跑，若接手时这个文件还没有，就以 `s1c/services.txt`、`s1c/scripts/`、`s1c/plan.md`（若有）和 WSL `~/npc-s1-run/` 的 `*-s1c*` 脚本为准，缺的部分重新派人调研。

**S1-C 准备已完成并代存**（`s1c/prep-report.md`，子会话原文；`s1c/plan.md` 与 `s1c/scripts/` 齐全，`.exs` 未经语法检查）。要点：
Hindsight 容器 `npc-s1-hindsight-20261112` 在 `127.0.0.1:18930`（卷 `npc-s1-hindsight-20261112-pg` / `-hf`），PG 容器 `npc-s1c-pg-20261112` 在 55448（带一个匿名卷，库未建）；
容器 / 卷数现为 154 / 163。更早那次实跑建设者从未建成（106 次 `insufficient_material`）；新角色余额为 0。
`"npc"` 树的 `build` 候选不会先走到工地，建筑足迹要在眼睛 8 米内才放得下。被测卡 Garen，候选 `build_hut` / `gather_stone` / `gather_limestone` / `guard_hut` / `visit_plaza`，各检查点期望已写在 `plan.md`。
准备子会话留的四个待定，旧统筹会话的建议（**未经用户确认**，接手后向用户说明再执行）：
(1) 材料来源：用 Test-only 的 GM `:fill` 一次放一堆 12 Stone + 3 Limestone（正常 World 提交、有回执与日志、需 `VOXIM_GM_TOOLS=1`），NPC 自己用 `gather` 采——建议接受，不用 `World.material_supply`（那是回填余额）；
(2) 实跑必须等 S1-B2 验证并提交之后，用那次提交；并且小屋要带名字发布（见上一段），`plan.md` / `register-s1c.exs` 要相应补一步；
(3) mix 与构建目录在 S1-B2 提交后即空闲；(4) 实跑结束后删除 Hindsight 与 PG 容器及其卷，证据以文件为准（需要保留 bank 内容时先把 `Life.observe` 与 Hindsight 的事实导出成文件）。

文件不存在说明那个子会话没跑完：看 `git status`、`docker ps -a | grep npc-s1`、WSL `ls ~/npc-s1-run`、`pgrep -a beam` 判断做到哪，再按本页任务书的意思重新派。
两个子任务的任务书要点都在本页“S1-B 结果”“薄片一的任务”和总纲里；实跑配方在“证据与复跑”。

**接手后的顺序**：(1) 收 S1-B2 → 验证 → 提交；(2) 收 S1-C 准备 → 派实跑；(3) 实跑结果写回本页，更新图解页 `…overview.html` 的进度标签，提交；
(4) 向用户汇报薄片一三条验收的原始结果，再谈薄片二。实跑结束后清理本线创建的容器与卷（`npc-s1-hindsight-*`、`npc-s1c-pg-*`），核对容器 / 卷数回到 152 / 160。

**用户已定**：Jev 不分版本，用 `jev-latest`，不算问题；世界知识按“每个 NPC 自己的记忆 + 一小段公共常识”做，物件自己说明用途（总纲“世界知识怎样到达判断者”）。
**待用户确认**：名字层与编号层分开、记忆文字只用名字（总纲同一节末条，用户提出、统筹会话给了建议，尚无答复）；开服前的背景写多少、谁写。
**统筹会话替用户定过、已汇报**：`"npc"` 不套 `Brain.Social`；`caution` / `sociability` 不进快照、并掉待做；保留 `Life.activity/2`；`Utility` 整个删除。


## 现状

- **工作位置**：worktree `D:/hemifuture/ex_mmo_cluster-npc`，分支 `npc-life-20261111`（基于 master `b60e0a45`），未推送。
  客户端仓库 `D:/hemifuture/Voxim` 本线没有改动。
- **统筹**：2026-11-11 用户指定由会话 voxim-ef 统筹；原 NPC 会话 voxim-9c 停在“是否启动实验 A”，已发交接请求（见“未决”）。
- **两条来源已合到同一分支**

| 来源 | 内容 | 状态 |
|---|---|---|
| voxim-9c | N1 效用选择器 `Utility`；可见的 rest / social 与 `Trees.settler_daily/1`、注册参数 `daily`；N2 `DayPlan`（LLM 日计划）、N3 升级；`LlmBudget` 每游戏日 5 次 | 已实现；单测通过（该会话记录 npc_server 386 / 387，1 个失败需要 `NPC_LLM_URL`，master 上同样失败）；**未实跑、未验收** |
| voxim-ef | Jev 决策调研、两段式人格卡、离线实验脚本与结果（`tools/jev/`，4,076 次请求） | 调研完成并提交 `87d5fae5`；**运行时未接入** |

## 薄片一的任务（一个 NPC 走通整条链；统筹会话只拆任务、收结果、验证、提交）

按可运行增量拆，串行（都改 `apps/npc_server` 的同一批文件、共用一个构建目录）：

| # | 增量 | 交付的可观察行为 | 验收 | 状态 |
|---|---|---|---|---|
| S1-0 | 实跑配方（只读侦察） | 本机 WSL 原生起服务端、登记一个 NPC、rpc 与日志观察的准确做法 | 配方写进本页“证据与复跑” | 完成，S1-A 实跑用过 |
| S1-A | 选择链接通 | 一个登记的 NPC：人格卡进注册参数；候选活动来自注册参数（技能与去处），代码先滤可行性；活动结束或连续失败时异步问 Jev，应答经 Runtime 进观察，树根按它执行；每次选择一行日志。时钟打分、写死台词随之删掉 | 验收 (a)：同一处境两张人格卡选得不同（`live_jev` 用例，期望值先手写）；真实服务端里看到“选择 → 执行 → 再选择”的日志 | **已实现、已实跑、验收 (a) 通过**；实跑只走了“去处”候选的成功路径，见下 |
| S1-B | 心智与记忆进快照 | 快照加上 Life 的情绪与关系（规则模式）、未封存的近期经历、Hindsight 的认识与一次召回；`"npc"` 登记时带 Life，Outcome 与世界事件照常进 Life 与 Hindsight。实现、测试，加一次带真实 Hindsight 的短实跑（NPC 真的建一次东西，快照各栏在日志里可见） | 冻结快照文本的 `live_jev` 用例：加上“被破坏”的情绪与经历后 top1 改变，期望值先手写；实跑里看到四栏都有内容 | **已实现、已测试、未实跑**；预演 6 次里 1 次落空，见下 |
| S1-B2 | 经历原文点名被破坏 / 被修的建筑 | World 的交互事件带目标所属根实例的定义 id（`prefab`）；Life 查发布名写进经历：`Actor <cid> damaged the building "<名字>" that I built, at …`；没有发布名时原文不变 | 离线对照（期望运行前写）；手写期望句子的单测；真实 World 事务的集成用例 | **已实现、已测试、统筹已验证并提交；未实跑**，见下 |
| S1-C | 薄片一验收实跑 | 第二个 NPC 经正常入口拆第一个 NPC 的建筑；记录 (b) 事件前后的选择、(c) 情绪衰减且经历封存写入后的选择；命令、日志位置、原始结果写回本页 | 验收 (b)、(c)，区分已实现 / 已实跑 / 已验收 | **已实跑；(b) 落空、(c) 不通过（不确定）**，见下 |
| S1-C2 | 重设计后重跑 (b)(c) | 验“这次选择由哪一栏引起”：小屋落地、去处都在射程内；整座拆除后的第一次选择 + 逐栏离线对照；重建、衰减、写入刷新后破坏者再次出现，对陌生人出现的成对基线 | 验收 (b)、(c)，期望与判定规则运行前写在 `s1c2/plan.md` | **已实跑；(b) 通过、(c) 不通过**，见下 |

**S1-A 结果（2026-11-12，提交见“进度记录”）**

- 新模块：`Persona`（人格卡，信任边界在 `new/1`）、`Mind`（心智快照，现有三栏：Character / Current situation / Recent activities）、
  `Selector`（选择位置；状态由 Runtime 持有）；树 `Trees.npc/1`；注册表 brain `"npc"`（参数 `who`、`persona`、`activities`、`tools`）。
  删除 `Utility`、`Trees.settler_daily/1`、注册参数 `daily`。`DayPlan` / `LlmBudget` 保留但没有入口会启动。
- 接缝：`choose_activity` 命令走 `act` → Runtime → Outcome，不是原设想的 `Utility.gate`（总纲已同步）。
- 验收 (a)：`npc_selector_test.exs --only live_jev`，两张卡各问 2 次，4 次都符合运行前写下的期望（Sella → `visit_plaza`，Hask → `rest_at_home`；
  置信度 0.98–1.0，延迟 347–1344 ms）。两张卡的自由文本写得很绝对（“hates being alone”“does the least”），这条验收过得不难。
- 实跑：节点 `npcs1a`，经 `Registry.put` 登记，46 次选择、46 次 travel 完成、0 次失败；延迟中位约 310 ms。
  **每张卡在处境不变时每次都选同一项**（Sella 21 次全是广场，Hask 25 次全是回家），技能候选 `build_hut` 一次没被选中。
  所以技能候选、活动失败后再问、发问失败后重问这三条路径只有单测覆盖，留给 S1-B / S1-C 的实跑。
- 没做的：可行性过滤为空（现有观察里没有能判定候选做不成的依据）；背包栏只有材料号。Jev 模型用 `jev-latest`（Jev 本就不分版本，2026-11-12 用户确认，不算遗留问题）。
- 子会话自定的三处：参数 `who`（英文自称，注册名不进模型）、Jev 请求超时 10 秒、发问失败后隔 600 tick 再问。统筹会话认可。
- 统筹会话复核：逐文件看过差异；重跑 `npc_persona / selector / tree / day_plan / llm_budget / jev` 48 通过、3 按标签排除；

**S1-B 结果（2026-11-12，提交见“进度记录”）**

- 快照现在六栏：Character → Feelings and relationships → What just happened → What I remember → Current situation → Recent activities。
  情绪按强弱三档写成句子，衰减到 0.1 及以下不写；信任按 ±0.2 / ±0.6 写成 Trusts / Distrusts 等；记忆栏首行声明“只是我的记忆，不是当前世界事实”。
- `"npc"` 必带 Life（规则模式，不套 `Brain.Social`）；`life: false` 被拒，Hindsight 地址取 `NPC_LIFE_HINDSIGHT_URL` 或显式参数。
- Life 新增只读入口 `Life.mind(cid, query)`（与 `context/2` 共用一次读取和恰好一次召回，召回单次超时 10 秒）与 `Life.activity/2`
  （一项活动结束时记一条“做了什么、结果如何”）。后者是子会话自定的：规则模式下 `Life.experience/2` 是空操作，NPC 自己做的事原先没有任何路径进记忆。统筹会话认可。
- “刚才发生了什么”= 已封存待写的片段 + 未封存的尾部（否则写入期间有缺口）。
- 观察：`Body.observe(pid).select.asked` = `%{state: 给 Jev 的全文, recall_query:, recall_ms:}`；`npc_select` 加 `recall_ms=`；
  心智读不到是 `npc_select_failed reason={:mind_unavailable, …}`，不发 Jev 请求。
- **预演（冻结快照、真实 Jev，期望运行前写入）**：`npc_mind_test.exs --only live_jev`，卡 Garen（builder）。
  ① 没有那件事 → `gather_stone` 2 / 2（置信度 0.86）；③ 只有记忆召回 → `build_hut` 2 / 2（0.80、0.83）；
  ② 愤怒 + 近期经历 → 期望 `build_hut`，实际一次 `gather_stone`（0.02）、一次 `build_hut`（0.06），**落空**。用例保留为失败（`live_jev` 缺省不跑），原始日志
  `.demo/observe/npc-slice1-20261112/s1b/live-jev-20261112.log`。**后续：推测已由 S1-B2 验证成立并改了经历原文，见“S1-B2 结果”。**
  当时的推测：规则模式写出的经历原文是 `Actor 21 damaged construction I care about at (25, 518, 37), material 11 … (transaction 4711)`，
  只有坐标与编号，Jev 无从知道被拆的就是那座小屋；③ 的召回句明说了“the small hut I built”。
- 已知情况：信任不衰减，一次破坏后 `Distrusts …` 一直留在情绪栏，验收 (c) 要看 state 全文区分各栏的贡献；新 NPC 在 Hindsight 建好 bank 与四份认识之前
  每 10 秒显式失败一次（`life_models_unavailable`）；Hindsight 对片段抽不出事实时 `retain` 返回 `empty_facts`、自动写入停住，重复的活动经历会不会触发要实跑才知道。
- Life 状态里的 `caution` / `sociability` 统一形态不读；从 Life 里并掉待做。
- 统筹会话复核：看过 Life / Runtime / Selector / Registry 的差异；自建 PG（55446，已删）重跑
  `npc_selector / mind / registry / life / life_state / life_registry / social / tree` 97 通过、2 按标签排除。
  自建 PG（55444，已删）重跑 `npc_registry / settler / abilities` 35 通过。验收 (a) 与实跑没有重跑，以子会话留下的日志为准。

**S1-B2 结果（2026-11-12，提交 `NPC slice one, S1-B2: …`）**

- S1-B 预演 ② 落空的推测**已验证成立**：真实 Jev 离线对照 28 次（`tools/jev/episode.py`，结果 `results-episode.json`），经历原文点名建筑的四种写法
  16 / 16 选 `build_hut`（概率 0.81–0.87）；只有坐标与编号的现状 3 / 4、概率 0.30–0.50；去掉编号但不点名 0 / 4。起作用的是点名，不是去编号。
  事先期望会中的 B_activity（引活动名与判据）2 / 4，**落空**，那条路没有采用。改后预演三种快照各 2 / 2（子会话所跑，统筹会话没有重跑 `live_jev`）。
- 改法：`World.Interactions.capture` 在操作构造边界多冻结一个 `prefab`（目标所属根实例的定义 id，散格为 nil；旧事件没有这个键）；
  Life 的读取 worker 按 id 查 `World.published_prefab_metadata/1` 的名字写进事件 `building`；`Life.State` 写句子并把名字记在关心格上。
  坐标、材料号、world、事务号留在原文里。`"life"` 与 `settler + life` 共用这段原文，只有涉及有发布名的建筑时文本才变。
- 前提：**定义必须带名字发布**，候选判据用同一个叫法。作者目录定义、空名发布（`design_house`）、散格都不点名——NPC 自己设计的房子不会被点名，是独立的待定功能。
- 没测的边界：发布名与判据叫法不一致、中文名、多座同名建筑、Hindsight 把这句抽成事实后的召回文本（最后一条 S1-C 实跑会碰到）。
- 统筹会话复核：逐文件看过差异；自建 PG（55449，已删）重跑 `apps/npc_server` 的 `npc_mind / life / emotion_life / life_state / selector` 60 通过、2 按标签排除；
  `apps/voxel_region` 的 `world_interactions_test.exs` 改后 4 / 5、改前（`git stash` 掉 `apps/voxel_region`）3 / 4，失败的是同一条
  `compaction and a fresh World replay…`：WSL 工具链缺 `libsctp.so.1`，子 VM 的警告经 `stderr_to_stdout` 混进输出，比较值本身是 `true`——**确是改前就有的环境问题**。
  把 `libsctp1` 的 deb 免 root 解到 `~/npc-s1-run/libsctp/` 并设 `LD_LIBRARY_PATH` 后同一文件 **5 / 5 通过**。
  原始输出与脚本在 `.demo/observe/npc-slice1-20261112/s1b2/verify/`。

**S1-C 结果（2026-11-12 实跑；期望是运行前写在 `s1c/plan.md` 里的，一条未改）**

环境：提交 `b08a7c45`，WSL 节点 `npcs1c`（NPC-only，无 QUIC / 客户端），真实 Jev（`jev-latest`）、真实 Hindsight，新库 `npc_s1c_20261112`。
被测 NPC `S1CGaren`（cid 1606162583553），破坏者 cid 1984744656898。节点只起了一次，没有重来。

| 检查点 | UTC | 运行前期望 | 实际 | 判定 |
|---|---|---|---|---|
| C0 心智就绪 | 12:15:52 | 每 10 秒失败一次，≤ 5 分钟 | 失败 1 次，约 11 秒后就绪 | — |
| P0 阶段零 | 12:16:04–12:16:17 | `build_hut`（失败）→ `gather_stone` → `gather_limestone` → `build_hut`，15 分钟内建成 | `gather_stone` 0.24 → `gather_limestone` 0.51 → `build_hut` 0.89，登记后约 25 秒建成（1878 格，placed_by = 该 NPC；采 4 格石料 + 1 格石灰岩，账对得上） | **达成**；序列第一步（先试建造并失败）没有出现 |
| C1 基线 | 12:16:18–12:17:21 | `visit_plaza` ×3 | `visit_plaza` 0.74 / 0.40 / 0.52 | 成立，置信度偏低 |
| 破坏 | 12:17:26 | — | 破坏者经正常 `dismantle` 整座拆除；Life：愤怒 0.6、信任 −0.35；经历原文 `Actor 1984744656898 damaged the building "small hut" that I built, at (25, 518, 36), …`（S1-B2 生效） | — |
| C2 验收 (b) | 12:17:52 | 第 1 次 `build_hut`，第 2 次 `gather_stone` | `guard_hut` 0.65、`guard_hut` 0.74；state 的情绪栏与“What just happened”都含该事件 | **落空**（选择确实由 `visit_plaza` 变了，但不是运行前写下的那一项） |
| C3 重建 | 事件后 10 分钟内 | `build_hut` 失败 → `gather_stone` → `build_hut` | 一次都没选建造或采集，小屋没有重建 | **落空** |
| C4 前提 | 12:23:06–12:26:26 | 事件后 ≥ 310 秒；flush → retain 完成；refresh 完成；事件只剩在记忆栏与 Distrusts 一句 | 间隔 555 秒（愤怒 0.024）；retain 约 17 秒、无 `empty_facts`；refresh 约 79 秒；state 各栏符合 | 字面满足；“重建条目已轮出”因为根本没重建而空成立 |
| C5 验收 (c) 在线 | 12:26:41、12:27:12 | `guard_hut` ×2 | `guard_hut` 0.71、0.73；那件事只出现在“What I remember”与 Distrusts 一句 | 在线部分符合 |
| (c) 离线对照 | 14:09 | original `guard_hut`；no-memory `visit_plaza`；no-distrust `guard_hut`；neither `visit_plaza`（各 2 次） | **8 / 8 `guard_hut`**（0.68–0.79） | no-memory、neither **落空** → 按 plan 规则 **(c) 判不通过（不确定）** |

- **三条验收的状态**：(a) 已实现、已实跑、已验收（S1-A）。(b) 已实现、已实跑、**未验收**（落空）。(c) 已实现、已实跑、**未验收**（不通过，不确定）。
- **链路本身是通的**（已实跑）：技能候选被选中并执行（采集 2 次、建造 1 次、去处 27 次，到 12:30 UTC 无一失败、无 `npc_intent_rejected`）；World 事件 → Life 情绪与点名的经历 → 快照；
  flush → Hindsight retain → 认识刷新 → 召回进快照（bank 终态 26 条记忆，四份认识都提到那件事，召回句里有 “the small hut I built”）。
  选择延迟：Jev 中位 319 ms，召回中位 230 ms（写入后约 360 ms）。
- **为什么 (c) 说明不了问题**（事实 + 推断，推断未验证）：小屋没有重建，事件后 NPC 连续 `guard_hut`，C5 那次 state 的“Recent activities”是 `guard_hut` ×5、
  “What just happened”有 6 条 `guard_hut`，各变体里原样保留；记忆栏还留着 3 行不点名那件事但带“要守着它”意思的认识。删掉记忆里那件事后仍选 `guard_hut`，
  可能是自身惯性在起作用——plan 的 C4 隐含“小屋已重建、重建条目已轮出”，这个前提实质上没有成立。事件后唯一一次回到 `visit_plaza`（12:23:32，0.39，flush 之后、刷新完成之前）没有留 state。
- **为什么 (b) 选的是守而不是重建**（推断，未验证）：经历只说 `damaged`，实际是整座拆除；“Current situation”不告诉 NPC 小屋还在不在；手上石料不够重建；`guard_hut` 守的是一座已不存在的小屋。
- **场地与流程上的问题**：地表在 y 509–510，小屋锚点沿用 S1-A 的 518，**悬空约 8 米**；广场到小屋 8.12 米，超出 8 米建造射程（这次没触发）；GM 料堆的 `voxel_gm` 日志行缺失（放料时日志级别还是 warning，回执与读回都在 rpc 日志里）；
  小屋名字由一个 Test-only 夹具角色 `S1CPublisher` 发布后离场（id 不变，读回有名）；出现两次 refresh（自动一次、脚本一次）。没有发现直接改余额、情绪、记忆或替被测 NPC 行动的操作。
- **执行偏差**：做实跑的子会话跑到 C5 后因模型额度中断，没有回报；节点无人值守到 14:10 UTC（plan 上限 60 分钟），期间多出 191 次选择（全是 `guard_hut`），总计 221 次选择、1 次失败。
  离线对照、导出、停节点由第二个子会话完成；时间线由第三个只读子会话凭日志重建。统筹会话没有逐条复核原始日志，以两份报告为准。
- **重跑前要先定的**（建议，待用户确认）：① (c) 的对照要把“自己事后一直在守”的惯性排除掉——小屋先重建、活动记录轮出后再问，或变体里连活动记录一起处理；可先用这次存下的 C5 state 做一轮离线变体（只要 Jev，不起服务端）看是不是惯性。
  ② 快照要让 NPC 知道小屋现在在不在（现查 World，属总纲“此刻的事实”），经历要分得清“损坏”与“拆除”。③ 场地：小屋落地、去处都在建造射程内。

**S1-D1 结果（2026-11-12，离线诊断 + 事件清点；只打 Jev 44 次，期望由统筹会话派发时写定并照抄进 `tools/jev/s1c_diag.py`）**

- **(b) 的原因找到了**：把破坏一句换成精确的“整座拆除”，或在“Current situation”里加一句小屋不在了，16 / 16 转向重建方向（`build_hut` 或 `gather_stone`），四个设了期望的变体全部成立；
  `guard_hut` 的概率从 0.73–0.79 降到 0.09–0.21。写成“损坏一部分、建筑仍在”时守屋更稳（4 / 4，0.76–0.80），与语义一致。
  不足：`build_hut` 与 `gather_stone` 之间约五五开，top1 置信度只有 0.11–0.25（推断：材料够不够要模型自己比数字，未测）。措辞里备选句
  `removed the entire building "<名>" that I built, …; the building no longer exists.` 略好（`build_hut` 4 / 4），每格只有 4 次。
- **(c) 落空**：去掉“自己一直在守”的活动记录与记忆后，只凭记得那件事 2 / 4 仍去广场（期望 top1 ≠ `visit_plaza`，落空）；再删掉那件事 4 / 4 `visit_plaza`（成立）；
  只留惯性、删掉那件事 4 / 4 `guard_hut`。按运行前的规则：**记忆里的那件事不足以稳定改变选择；实跑里的守屋靠惯性就够**。
  记忆仍把 `visit_plaza` 的概率从 0.54–0.60 压到 0.28–0.33，只是形不成稳定的 top1；而且那份记忆写的仍是 `damaged`，不是“没了”。
- **事件清点**：World 每笔事务一条交互事件；`:damage`（打一下）、`:destroy`（一格 / 整个叶子构件 / 整棵子树）现在都写成同一个词 `damaged`。
  整座拆除在事件里**区分不了**：缺根实例 id 与“提交后根实例还在不在”，只有 World 在构造操作时拿得到。Life 对一个关心格只评价第一次破坏，先打一下再整座拆时后一条会被吞掉。
  NPC 自己重建不出任何 World 经历。“Current situation”全部来自 Body 的观察，没有任何建筑信息；背包把 90 种材料连 0 一起按编号列出。活动失败原因是内部原子名原样输出。
- **建议的标准描述表**与分工（World 给事实、Life 按固定表写句子、Mind 现查 World 拼处境）在子会话原文 `s1c/s1d1-report.md`；变体全文与逐行改动在 `s1c/diag/`。
- 统筹会话复核：看过脚本顶部的期望与规则（与派发时写的一致）、实测句子、凭据卫生；没有重跑。复现检查（两份原文各 4 次仍是 `guard_hut` 0.66–0.77）说明离线请求与实跑对得上。
- **对重跑的含义**：(b) 改完产品后有望通过，期望应写成“重建方向”。(c) 要重新想清楚验什么——记忆要能稳定改变一次选择，记下的得是精确的事（整座被拆、谁拆的、我后来重建了），
  候选里也得有一项只在“记得这件事”时才合理；现在的 `guard_hut` 在基线下也说得通、且容易被惯性锁住。这条待与用户商定后再写进新的 plan。

**S1-D2 结果（2026-11-12，提交 `NPC slice one, S1-D2: …`；已实现、已测试、经独立复核；未实跑）**

- **World**：交互事件多三个键——`instance`（目标所属根实例，散格 nil）、`anchor`（根实例锚点所在宏格）、`instance_removed`（这笔事务提交后根实例是否已不存在；
  拆掉多构件建筑的一个叶子构件不算）。`Interactions.capture` 取提交前归属，新的 `Interactions.settle/2` 在四条提交路径上、落盘之前补 `instance_removed`；
  事件原样落盘，重放与检查点不重新计算。放置 / 替换 prefab 的事件改为带提交后新建筑的 `prefab` / `instance` / `anchor`（`placed_by` 仍取提交前）。旧事件没有这些键。
- **Life.State**（标准描述表只在这里）：整座被移除 `removed the entire building "<名>" that I built, at …; the building no longer exists.`；
  毁掉一部分 `broke off part of the building …; the rest of the building is still standing.`；打了没毁 `damaged part of the building …; the building is still standing.`；
  被别人修好 `repaired the damaged part of the building …`。无名建筑与散格原文不变。已受损的格之后整座被移除，照样写出“整座被移除”，不带情绪句、不重复计愤怒与信任。
  整座被移除后删掉那一格的关心格（否则之后别人在那里放一格会被写成修好了已不存在的建筑）。状态新增 `"buildings"`：自己放下的有名字的建筑（名字、根实例、锚点），同一锚点重建时替换旧条目；旧持久行读进来补 `[]`。
- **Mind / `Life.mind`**：发问时对记得的每座建筑现查 `World.instance_cells/2`，在 `Inventory:` 之前写 `My building "<名>" at (x, y, z) is standing.` / `… is gone.`；
  读不到 World 时这次发问显式失败（`mind_unavailable`），不猜。记忆只决定问哪几座，在不在只认 World。
- **测试**：新用例都先在改前代码上确认过红。独立复核子会话重跑：`voxel_region` 整套缺省测试 975 / 976（53 按慢标签排除），唯一失败 `refined_compact_test.exs:52`
  是 S1-B2（`b08a7c45`）引入的——夹具的实例记录没有 `definition_id`，真实记录总带（唯一创建点 `prefab.ex:387`），已把夹具改成真实形状；`npc_server` 11 个相关文件 115 通过、2 排除。
  小修后再跑：`voxel_region` 4 个文件 119 通过，`npc_server` 6 个文件 66 通过、2 排除。统筹会话没有自己重跑，以复核与小修两份回报为准。
- 对 `"life"`、`settler + life`：涉及有名字的建筑时经历文本跟着变，数值与规则不变。

**S1-C2 重跑的设计要点（2026-11-12 用户同意；新 plan 照此写，期望运行前定）**

- **验的是原因，不是某一个选项**：用户明确 `guard_hut` 未必是错的选择；验收要回答的是“这次选择是由哪一栏引起的”。所以每个验收检查点除了记 top1，
  都要对那次真实 state 做逐栏的离线对照——每个变体只去掉一个来源（近期经历里的事件句 / 情绪句 / Distrusts 一句 / 记忆栏里那件事 / 自己的活动记录 / 处境里的事实句），
  运行前写下“去掉哪一栏应当变回基线、去掉哪一栏应当不变”。离线请求先做复现检查（原文重问与在线结果一致）。
- **(b)**：整座拆除后的第一次选择，期望“重建方向”（`build_hut` 或 `gather_stone`）；对照期望：去掉事件句与处境里的 `is gone` 后变回基线。
- **(c)**：小屋重建完成、情绪衰减、经历写入并刷新、自己的活动记录轮出之后，让**破坏者再次出现在附近**，看选择是否因为记得他而偏离基线。
  基线要成对：同一位置、同样有一个**没有过节的陌生角色**在附近时的选择。对照期望：去掉记忆栏里那件事（及 Distrusts）后回到“陌生人在附近”的基线；只去掉自己的活动记录不变。
  信任不衰减，Distrusts 来自 Life 而不是 Hindsight，两者必须分开去掉、分别记。
- **场地**：小屋落在地表（上次悬空约 8 米）；所有去处与采石站位都在小屋 8 米建造射程内；放料在把日志级别调到 info 之后（上次缺 `voxel_gm` 行）。
- **执行**：实跑拆成短任务（搭场地到首次建成 / 基线与破坏与 (b) / 重建与 (c) / 对照与收尾），每段结束即回报，节点在段间不停；任何一段都带 60 分钟硬上限与“到点先停节点”。

**S1-C2 结果（2026-11-12 实跑；期望与判定规则是运行前写在 `s1c2/plan.md` 里的，起节点后一条未改）**

环境：产品代码 `c0489bd7`（检出时分支 HEAD `897089e3`，其后的提交都不动 `apps/`），WSL 节点 `npcs1c2`（NPC-only，无 QUIC / 客户端），16:54:38–17:20:45 UTC，只起了一次。
真实 Jev（`jev-latest`）、真实 Hindsight、新库 `npc_s1c2_20261112`。被测 NPC `S1C2Garen`（cid 636376584193）；破坏者 `Corvin`（cid 1845497958402）；陌生人 `Tobin`（cid 5128442613763）。
全程 49 次选择成功、2 次显式失败（登记时 `life_models_unavailable` 一次、flush 后 Hindsight 超时一次），每次给 Jev 的 state 全文都存了。

| 检查点 | UTC | 运行前期望 | 实际 | 判定 |
|---|---|---|---|---|
| C0 心智就绪 | 16:57:31 | ≤ 5 分钟 | 失败 1 次，登记后约 12 秒就绪 | — |
| P0 首次建成 | 16:57:31–16:57:49 | 15 分钟内由该 NPC 放下 | `gather_stone` 0.26 → `gather_limestone` 0.46 → `build_hut` 0.90，登记后约 30 秒建成（1878 格，placed_by = 该 NPC；Life `buildings` 登记；余额对得上） | 达成 |
| C1 基线 | 17:01:29、17:02:00 | `visit_plaza` ×3 | `visit_plaza` 0.50、0.44；**只取到 2 次**（子会话的等待命令出错，提前做了破坏）。清完前后连续 5 次都是 `visit_plaza` | 成立；取样少 1 次，记为偏差 |
| 破坏 | 17:02:12 | 正常 `dismantle` 整座拆除 | 一次成功，足迹读回 0 格；愤怒 0.54、信任 −0.35；破坏者 1 秒内离场 | — |
| B 验收 (b) 在线 | 17:02:31 | 重建方向；state 含两句事实 | `build_hut` 0.46；state 含 `Actor … removed the entire building "small hut" that I built, at (25, 512, 36), …; the building no longer exists.` 与 `My building "small hut" at (25, 510, 36) is gone.`；破坏者不在附近 | **符合** |
| R 重建 | 17:02:44 | 事件后 10 分钟内 | `build_hut` 材料不足失败 → `gather_stone` 0.82 → `build_hut` 0.91，事件后 32 秒建成（新实例，`buildings` 替换，state `is standing`） | 达成 |
| D (c) 前提 | 17:08:22 起，又等 10 次 | 事件句与愤怒已不在；活动记录里重建已轮出且不是清一色 `guard_hut` | 事件句已写走、情绪栏只剩 Distrusts、小屋在；**活动记录一直是 `guard_hut` ×5** | **前提未满足**（按 plan 照做 S、V） |
| S 陌生人在附近 | 17:15:36 起 3 次 | `visit_plaza` ×3 | `guard_hut` 0.73、0.70、0.74（`Nearby: Tobin (NPC, 5.0 m away).`） | **落空** |
| 无人 | 17:17:09 | `visit_plaza` | `guard_hut` 0.40 | **落空** |
| V 验收 (c) 在线 | 17:17:41 起 3 次 | 第 1 次 `guard_hut`，且 ≠ S 的基线 | `guard_hut` 0.60、0.60、0.59（`Nearby: Corvin …`，`Distrusts Corvin (actor …)`）；**与 S 的基线相同** | **不成立** |

离线逐栏对照（节点停后，`tools/jev/s1c2_counterfactual.py`，16 个变体各 4 次，64 次请求全部应答；结果 `results-s1c2-counterfactual.json`）：

| 组 | 变体 | 期望 | 实际（4 次 top1；概率） | 判定 |
|---|---|---|---|---|
| B | original | 重建方向（复现） | `build_hut` ×4（0.48–0.62；`gather_stone` 0.21–0.33） | 成立 |
| B | no_event | 重建方向 | `build_hut` ×4（0.40–0.57） | 成立 |
| B | no_gone | 重建方向 | `build_hut` ×4（0.65–0.71） | 成立 |
| B | no_event_no_gone | 不在重建方向 | `visit_plaza` ×4（0.49–0.56；`guard_hut` 0.26–0.27） | 成立 |
| B | no_anger | 不变 | `build_hut` ×3、`gather_stone` ×1 | 成立 |
| B | no_distrust | 不变 | `build_hut` ×4（0.40–0.47） | 成立 |
| B | no_own_activity | 不变 | `build_hut` ×4（0.59–0.75） | 成立 |
| B | all_removed | `visit_plaza` | `visit_plaza` ×4（0.55–0.61） | 成立 |
| S | original | 复现在线 | `guard_hut` ×4（0.77–0.80；`visit_plaza` 0.19–0.22） | 成立 |
| V | original | 复现在线 | `guard_hut` ×4（0.64–0.71；`visit_plaza` 0.26–0.34） | 成立 |
| V | no_memory（固定删行规则） | 不变 | `guard_hut` ×4（0.49–0.57） | 成立（记录项） |
| V | no_distrust | 不变，且 ≠ S 基线 | `guard_hut` ×4（0.60–0.65）——与 S 基线相同 | “≠ 基线”**不成立** |
| V | no_memory_no_distrust | 回到 S 基线 | `guard_hut` ×4（0.45–0.57） | 成立（基线本身就是 `guard_hut`） |
| V | no_own_activity | 不变 | `guard_hut` ×4（0.81–0.85） | 成立（记录项） |
| V | nobody_nearby | `visit_plaza` | `guard_hut` ×4（0.58–0.71） | **落空**（记录项） |
| V | memory_blank_no_distrust | 回到 S 基线 | `visit_plaza` ×3（0.47–0.52）、`guard_hut` ×1（0.47） | **落空**（记录项） |

- **(b) 按运行前的规则通过**：在线 top1 在重建方向、state 含两句事实、原文复现成立、两句都去掉后离开重建方向、四处全去掉后回到 `visit_plaza`。
  **起作用的是那两句事实**：事件句与 `is gone` 任一句单独就够，两句都没有就回到去广场；愤怒句、Distrusts、自己的活动记录去掉都不变。偏差：基线只取了 2 次。
- **(c) 按运行前的规则不通过**：第一个条件“破坏者在附近时的选择 ≠ 陌生人在附近时的选择”在线上就不成立——两边都是 `guard_hut`，离线原文各自复现。
  脚本对 (c) 的附注“效应来自不衰减的信任”不适用于这次：这次**根本没有出现偏离基线的效应**，谈不上归因到信任还是记忆。
- **三条验收的状态**：(a) 已实现、已实跑、已验收（S1-A）。(b) 已实现、已实跑、**已验收**（S1-C2；基线取样少 1 次）。(c) 已实现、已实跑、**未验收**（不通过）。
- **重建之后的守屋不是由“附近是谁”引起的**（事实）：重建后 27 次选择里 26 次 `guard_hut`（17:05:10 一次 `visit_plaza`），无人、陌生人、破坏者在附近都一样；
  去掉 Distrusts、把附近改成无人、去掉自己的活动记录（反而更高，0.81–0.85）都不变；按固定规则删掉记忆栏里提到那件事的行也不变；只有整个记忆栏清空并去掉 Distrusts 才有 3 / 4 回到 `visit_plaza`。
  上次 S1-D1 归因的“活动记录里的惯性”在这次的 V state 上不成立；这次守屋的来源在记忆栏（Hindsight 的四份认识与召回句，其中有“守过 20 次”之类的条目）与 Distrusts 之中，哪一部分为主见下面的事后诊断。
- **no_memory 的固定规则删得比“那件事”宽、同时又留下了守屋的条目**：记忆里在破坏之前就有 “built or rebuilt a small hut”（措辞来自 `build_hut` 判据的 “or rebuild it if it is gone”），被 `rebuil` 词干命中；
  四条 Belief 全被清空；留下的 8 条召回句里有 2 条 `guard_hut`（“20 次”）。所以这个变体既不是“只去掉那件事”，也没去掉守屋的习惯，只作记录。
- **链路（已实跑）**：S1-D2 的三样东西第一次在真实服务端上出现并起作用——整座移除的标准经历句、处境里的 `is standing` / `is gone`、Life 的 `buildings` 登记与同锚点重建替换。
  flush → retain（3 次，无 `empty_facts`）→ 认识刷新 → 召回进 state；Hindsight 终态 15 条记忆、四份认识齐全。陌生人与破坏者只是出现，没有在被测 NPC 的 Life 里产生任何事件、情绪或经历；同名再起 cid 不变。
  离线请求延迟中位 607 ms。
- **场地与流程**：小屋贴地（地表 510，悬空 0），所有站位到足迹 1.0–6.4 米；GM 放料的两条 `voxel_gm` 行都在；每次选择的 state 都由常驻窗口存下；四段任务各自按时回报，节点运行 26 分钟后停掉，看门狗未触发。
- **偏差与干扰**：① C1 少取 1 次（见表）。② V 的三次选择落在一次自动认识刷新进行中（近期经历攒满 3000 字自动封存带起的，17:16:47 起）。
  ③ Hindsight 在登记后头 3 秒返回过 4 次 404（推测 bank 尚未建好，未查）。④ 小屋发布记录里的发布者 id 与夹具角色的 cid 不是同一个数（未查）。⑤ `survey` 脚本显示的材料成本与场地参数不一致（建造与余额都对，未查）。
  ⑥ 三个场地脚本原样会崩（`Code.eval_file` 的参数用错），第一段做了最小修正。没有发现直接改余额、情绪、记忆或替被测 NPC 行动的操作。
- 统筹会话的复核范围：B 那次 state 的两句事实、情绪栏、处境句自己核对过；三份 `original` 与来源逐字节相同；离线 64 次请求是统筹会话自己跑的。四段的在线读数以子会话回报为准（代存在 `s1c2/seg1-report.md`–`seg3-report.md`），没有逐条复核原始日志。

**S1-C2 事后离线诊断（2026-11-12，探索性，不是验收；只打 Jev 24 次，期望由统筹会话运行前写定并照抄进 `tools/jev/s1c2_postdiag.py`）**

问题：重建之后的守屋来自记忆栏的哪一部分；记忆不占主导时“破坏者在附近”与“陌生人在附近”有没有差别。基准是 S（陌生人在附近）与 V（破坏者在附近）两份真实 state，各变体问 4 次。

| 变体 | 做法 | 运行前期望 | 实际（`guard_hut` 概率） | 判定 |
|---|---|---|---|---|
| S_memory_blank | 整个记忆栏清空 | `visit_plaza` | `guard_hut` ×4（0.67–0.75） | **落空** |
| S_beliefs_blank | 四份认识清空，召回句全留 | `visit_plaza` | `guard_hut` ×4（0.84–0.87） | **落空** |
| S_recalled_removed | 召回句全删，四份认识全留 | `guard_hut` | `guard_hut` ×4（0.74–0.81） | 成立 |
| S_no_guard_memory | 记忆栏里含 `guard` 的条目删掉 / 清空（四份认识都含，全被清空；另删 2 条召回句） | `visit_plaza` | `guard_hut` ×4（0.86–0.90） | **落空** |
| S_no_distrust | 只去掉 Distrusts | `guard_hut` | `guard_hut` ×4（0.73–0.76） | 成立 |
| V_memory_blank | 整个记忆栏清空，Distrusts 与 `Nearby: Corvin` 保留 | `guard_hut` | `guard_hut` ×4（0.58–0.76） | 成立 |

- **事实**：单独清空记忆栏、单独去掉 Distrusts、单独去掉自己的活动记录、把附近改成无人，都仍是 `guard_hut`；清空四份认识后概率反而更高。
  只有“记忆栏清空 + 去掉 Distrusts”一起做（验收对照里 V 的 memory_blank_no_distrust）才有 3 / 4 回到 `visit_plaza`，而且很勉强（`visit_plaza` 0.47–0.52 对 `guard_hut` 0.34–0.47）。
  记忆栏清空后，破坏者在附近（V）与陌生人在附近（S）的 `guard_hut` 概率区间重叠，看不出差别。
- **统筹会话的三条期望落空**：“记忆栏整体是守屋的来源”“起作用的主要是四份认识”“起作用的是记忆里守过很多次的内容”都不成立。
- **推断（未验证）**：重建之后的守屋是多处同时支撑的——记忆栏与 Distrusts 任何一处单独去掉，另一处都还够；人格卡里的“slow to forget a wrong”、候选判据本身也可能有份（没有单独去掉过）。
  所以用“破坏者在不在附近”去撬 `guard_hut` 这一项，在现在的候选表下撬不动：它在重建之后对谁都是首选。
- **对 (c) 的含义**：这一版 (c) 的设计区分不出“记得那件事”的作用。要再验，候选里得有一项**只在针对那个人时才合理**（而不是对谁都说得通的守屋），并且先在存下的 S / V 两份 state 上离线试出能区分的设计，再考虑上真实服务端。
- **顺带看到的产品行为**：一次破坏之后，这个 NPC 重建完就一直守屋（26 / 27 次），信任不衰减、记忆里“守过 N 次”越积越多，没有看到它自己回到“照常过日子”。这是不是想要的行为，待用户定。

不在薄片一里：LLM 规划、说话、游戏时刻对齐、步骤边界打断、人格漂移、多个 NPC。`DayPlan` / `LlmBudget` 留着不启用，薄片二再改。

旧的 M1–M4 拆分与下文“评审后的路线 R1–R7”是按组件拆的旧表，只作背景；“`Utility` 保留为不需要模型的显式选项”的说法已作废（见总纲）。

## 设计评审结论（2026-11-11，只读评审 + 统筹会话复核关键两处源码）

对象：voxim-9c 的 N1–N3 设计与未提交代码，以及上表原 M2 提案。带“推断”的条目没有实跑。

**与目标不符（已确认）**

1. 选择器里没有“人”：分数 = 时段权重 + 情绪 mode 加成 + 附近有人 0.15（`utility.ex:85-103`）。没有 Life 的作息 NPC，人格、目标、记忆、
   余额都不进；附近加成翻不了结果，树守卫不传当前活动所以惯性不生效。两个这样的 NPC 同一时刻必然同选，行为只是时钟的函数。
2. 日计划让 LLM 解一个没有输入的封闭问题：提示词只有名字、cid 和格式（`day_plan.ex:324-331`），输入只有当前千分位与现行作息
   （`:309-315`），输出是 4 种活动 × 3 个去处的时段表。按“开放归 LLM、能算归代码”，这份作息由作者数据给即可；24 分钟一日时每个 NPC 每天至少 60 次调用。
3. 路线分叉成第三种 NPC：life（逐步 LLM）、settler、settler + daily。说话有三条路径（对话能力、日计划的 `say`、写死的 5 句轮换台词），
   LLM 额度有两套实现。`"life"` 行会静默忽略 `daily`。没有任何文字说明怎样收敛到“一个通用大脑 + 技能”。
4. 活动集写死在三处（`utility.ex:45`、`day_plan.ex:294`、`trees.ex:157-162`），与“选项由数据给”相反；social 的台词按次序轮换，不是对处境的响应。
5. NPC 的游戏日 = 墙钟对 `day_ms` 取余，与客户端昼夜（`VoxelWeather.h` 的 `EpochUnixUs / DayClockMultiplier / DayPhaseHours`）无关联，玩家会在白天看到 NPC 睡觉。
6. 只在一轮结束回根时重选；一轮 work 含回访等待，README 示例是 10 分钟，占默认游戏日 42 %。注册表不设 `interrupt_policy`，`decide/2` 没有生产调用方，紧急 avoid 可能等几分钟。
7. 玩家直呼必然触发整日重排并占用额度：说 4 句后当日额度耗尽，NPC 不再回话，失败与愤怒重排也一并失效；玩家原话与名字拼在 instructions 里（`day_plan.ex:344-347`），与现有“台词不进 instructions”的契约不一致。

**推断，实跑前要先排除**

- 四个守卫各读一次时钟，跨时段的一瞬间可能全为假，`sel` 与 `repeat` 失败后树永久结束且无日志。
- daily + life 互相打架：树走到 2 米，Life 对陌生人的谨慎距离是 3.2 米，走近即触发后退并停树；`Brain.Social` 在树之前拦截，守卫看不到 avoid / cautious。

**规则冲突**：缺省 `day_ms` 两处定义、日号与千分位公式四处；`schedule` / `activities` / `activity_of` 无调用方；usage 缺失记 0 进累计；
`settler_daily` 标成 Test-only 但注册表已正式接线。

**原 M2 提案的缺口**：候选仍是四个固定标签，Jev 无内容可选；人格卡与 Life 特质并存成两套人格；输入没有记忆召回与余额；守卫只在轮末求值，异步答案到了也不生效。

**应保留**：有序活动表与纯函数 `choose/3`；模型输出整份校验、不修补；计划经 Runtime 单向进观察；决策日志带来源；模型用法显式开启、缺 endpoint 拒绝登记；`merge` 只替换未来时段。

## 评审后的路线（建议，待用户确认）

目标形态只有一种 NPC：Life 是唯一的心智 owner（记忆、情绪、关系、人格卡），候选由数据给，Jev 在事件到来时选，Tree 与技能执行，LLM 只做开放问题。

| # | 增量 | 要点 |
|---|---|---|
| R1 | 基线与止血 | voxim-9c 的代码按原样提交作记录；N2 / N3 保持关闭；先修“每次根 tick 只选一次”，删掉写死台词与日计划的 `say`，说话只走对话能力 |
| R2 | 一个人格 | 人格卡是唯一人格来源；Life 的 `caution` / `sociability` 并入卡上对应的特质级别并按现有规则漂移；登记边界严格校验 |
| R3 | 候选来自数据 | 活动 = 可用技能 + 去处 / 对象 + 计划里的意图，代码先做可行性过滤；不再是四个标签 |
| R4 | Jev 选择 | state = 人格卡 + Life 心智 + 一次召回 + 余额 + 周围 + 游戏时刻 + 最近做过什么；事件触发（轮末、时段变化、被直呼、情绪变化、连续失败）；在步骤边界打断；直接取 top1 |
| R5 | 时钟 | NPC 与客户端用同一个游戏时刻来源（最小做法：服务端按客户端同一公式算；是否改成服务端权威下发另议） |
| R6 | LLM 日计划 | 输入人格卡、认识、昨日结果、余额；输出当天的意图（做什么、去哪、找谁、为什么），不是四标签时段表；额度并成一套实现 |
| R7 | 真实客户端实跑 | 3–5 个不同人格卡的 NPC，看是否各不相同、是否对经历有响应 |

## 工程约束（每个子会话的任务书都要带）

- 服务端只在 WSL Linux 里构建与测试；不起 Windows 原生服务端。
- 不碰受保护对象（如园相关容器、数据库、备份目录）；测试用独立库，用完只删自己建的。
- UDP／QUIC：不新建无界连接或重试；批量前记基线。Jev 与 LLM 是 HTTPS，仍要限并发（实验用 3）。
- 重型进程（UE 编辑器／UBT／Cook／客户端）最多同时两个且在不同 worktree；实跑不与编译并行；启动间隔 ≥ 2 分钟；单任务客户端最多 10 次。
- 不为未发生的问题写分支；不加测试专用产品分支；显式失败，不静默降级。
- **测量与测试不生造数据**（用户 2026-11-13）：输入只能是产品真实运行的导出，或对它做删减 / 换写法（值由真实数据算出）；产品还产生不了的数据，先做产生它的代码并实跑导出再测。“假设情形”的结果只标假设，不作为“站得住 / 可以改产品”的依据。
- 每个会话上下文不超过 300k tokens；接近时把已完成、未完成、证据路径、下一步写回本页再换会话。

## 证据与复跑

- Jev 离线实验：`tools/jev/README.md` 记录每一轮；`python -B persona.py report [mild|big5|card]`、`traits.py report`、
  `routine.py report`、`habit.py report` 离线重出表格。凭据在仓库根 `.env`（本 worktree 没有 `.env`，实验是在主检出目录跑的）。
- voxim-9c 的本机实跑记录：Voxim 仓库 `Saved/Tests/telemetry-npc-20261110/`。
- **S1-C 实跑证据**：`.demo/observe/npc-slice1-20261112/s1c/`（被 `.gitignore` 忽略）：`plan.md`（期望与运行前修订）、`analysis-report.md`（时间线与逐检查点判定，含 30 次选择全表）、
  `closeout-report.md`（离线对照 8 次原始结果、变体核对、导出清单）、`states/`（各检查点给 Jev 的 state 全文）、`counterfactual/`、`export/`（Life 观察全文、Hindsight bank 统计 / 四份认识 / 26 条记忆）、
  `rpc-s1c.log`、`server-s1c.log`、`server-npc-lines.log`、`scripts/`（运行前版本）与 `scripts-run/`（实际运行版本）。WSL `~/npc-s1-run/` 留着脚本与 `world-root`；实跑库与 Hindsight bank 已随容器删除。
- **S1-A 实跑证据**：`.demo/observe/npc-slice1-20261112/s1a/`（被 `.gitignore` 忽略）：`server-npc-lines.log`（93 行 NPC 相关日志）、
  `observe-final-hask.txt`，以及当时用的 `env.sh`、`start.sh`、`rpc.sh`、`boot.exs`、`register.exs`、`obs.exs`。
  WSL `~/npc-s1-run/` 留着同一套脚本、`world-root` 副本（3.2 GB）与完整 `server.log`；实跑库随 PG 容器删了，再跑要重建并迁移。
  用法：Windows 侧起自建 PG → `~/npc-s1-run/start.sh`（tmux 会话 `npc-s1a`，节点 `npcs1a@127.0.0.1`）→ `rpc.sh register.exs` → `rpc.sh obs.exs`；
  日志：`sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' ~/npc-s1-run/server.log | grep -E 'npc_select|npc_skill_outcome|npc_registry_start|character_intent|npc_intent_rejected'`。
- **本机 NPC-only 实跑配方**（2026-11-12 只读侦察所得；S1-A 照此跑通，实际用的脚本见上一条）：
  - 上次的做法：WSL 里 `iex --name … --cookie … -S mix`（`MIX_ENV=test`，不是 release），tmux 会话加 `pipe-pane` 落日志；脚本都在上面目录的 `setup/`
    （`prepare.sh` / `prepare2.sh` 生成 env，`start.sh`、`rpc.sh`、`migrate.sh`、`npc.exs`、`stop.exs`）。WSL `~/telem-run/` 里还留着那次的
    `env.sh`、`world-root/`（3.2 GB，含 `m4a/scene-1.json` 与 `release-prefabs/`）、证书与 cookie——那是别的会话的目录，只读。
  - 薄片一用自己的目录 `~/npc-s1-run/`：复制一份 `world-root`，env 以 `~/telem-run/env.sh` 为蓝本、开头改成 source `/home/dyz/npc-env-a.sh`；
    节点名 `npcs1a@127.0.0.1`，tmux 会话 `npc-s1a`。test 构建下 gate 不自启 QUIC，NPC-only 实跑不需要 QUIC 和客户端。
  - Postgres：从 Windows 侧 Docker Desktop 起自建的 `postgres:16-alpine`（WSL 里没有 docker 守护进程），WSL 经 `127.0.0.1:<端口>` 访问；
    `mix ecto.create -r DataService.Repo && mix ecto.migrate -r DataService.Repo`。
  - Jev：服务端不从 config 读；凭据变量 `TYPESAFE_API_URL/KEY/MODEL` 在主检出的 `.env`。模型名就是 `jev-latest`（Jev 不分版本）。
  - Hindsight（S1-B 才需要）：当前没有在跑。固定镜像 `voxim-npc-evolve-hindsight:0.10.3-flashrank` 本地有；启动参数见 `scripts/npc_life/service.py:10-40`
    （该脚本绑定旧容器名，新实跑要换容器名、卷和端口）；它自己要用 `NPC_LLM_URL/KEY`；服务端读 `NPC_LIFE_HINDSIGHT_URL`；bank 名 `npc-life-<cid>`。
    旧的 `voxim-npc-life-loop-20261011` 等容器和卷都是 Exited 的历史数据，不复用、不删除。
  - 场地参数（上次可用）：`scene_id: 1`，`spawn: {22.5, 520.0, 34.5}`，工地 `anchor_micro: [200, 4144, 296]`、`stand: [24.5, 35.5]`，
    `definition` 取 `release-prefabs` 排序后第一个文件名的 hex。

## 未决

- voxim-9c 尚未回复交接请求（工作区是否有改到一半的文件、准确测试命令、文档外须知、其他证据目录）。
  在它回复前，以统筹会话自己跑的相关测试结果为准决定是否提交它的代码。

## 进度记录

- 2026-11-11：调研、工具与结果提交 `87d5fae5`。
- 2026-11-11：统筹会话在 WSL 用 `source /home/dyz/npc-env-a.sh && cd apps/npc_server && mix test --no-start …` 跑 9 个相关测试文件：
  113 项中 108 通过、2 项按标签排除；5 项失败全在 `npc_registry_test.exs`，原因是本机 5432 没有 Postgres，没走到断言——注册表改动本次未验证。
- 2026-11-11：完成设计评审（见上）。voxim-9c 的代码仍未提交，M2 未派发，等用户确认路线。
- 2026-11-12：用户指出各要素关系没有理清；写成总纲 `2026-11-12-npc-architecture-overview.md`（待确认）。会话 voxim-ef 结束，工作移交新会话。
- 2026-11-12（接手会话）：总纲补四处（位置 × 判断者两个维度、快照加“刚才发生了什么”、情绪评价的归属、选择延迟含召回；
  薄片一改为零 LLM 决策调用并加第三条验收）。用户答复“全部认可”。voxim-9c 的代码按原样提交为 `4960146e`。
- 2026-11-12（接手会话）：`npc_registry_test.exs` 在独立 Postgres 上补跑，13 项全部通过、退出码 0（当前工作区，含 voxim-9c 的未提交改动）。
  Postgres 是 Docker Desktop 里临时起的 `postgres:16-alpine`（`127.0.0.1:55442`，跑完已删容器与匿名卷；WSL 里没有 docker 守护进程和 PG 二进制）。命令：
  `source /home/dyz/npc-env-a.sh && export MMO_DB_HOST=127.0.0.1 MMO_DB_PORT=55442 MMO_DB_USER=postgres MMO_DB_PASSWORD=postgres && cd apps/npc_server && mix test --no-start test/npc_server/npc_registry_test.exs`。
  至此 voxim-9c 相关的 9 个测试文件都跑到了断言；仍是单测范围，未实跑。
- 2026-11-12（接手会话）：S1-0 配方完成；S1-A 完成并提交（结果见“薄片一的任务”下的“S1-A 结果”）；图解页
  `2026-11-12-npc-architecture-overview.html` 一并提交。下一步 S1-B。
- 2026-11-12（接手会话）：S1-B 的实现与测试完成并提交（未实跑）。下一步两件事并行准备、串行落地：
  (1) 破坏 / 帮助事件的经历原文要说得出“是哪座建筑”（先离线验证推测，再改）；(2) 带真实 Hindsight 的实跑与验收 (b)(c)，即 S1-C。
- 2026-11-12（第三个统筹会话）：接手。S1-B2 验证通过并提交（结果见“S1-B2 结果”；`world_interactions_test.exs` 那条失败核实为改前就有的 WSL 环境问题，补 `libsctp` 后 5 / 5）。
  用户确认 S1-C 的材料来源：GM `:fill` 放料堆、NPC 自采。验证用的临时 PG（55449）已删，容器 / 卷数仍为 154 / 163。下一步派 S1-C 实跑。
- 2026-11-12（第三个统筹会话）：S1-C 实跑完成（12:09–14:10 UTC），结果见“S1-C 结果”：阶段零达成，验收 (b) 落空，验收 (c) 不通过（不确定）。
  原计划拆成四段短任务，但收窄指令没有送达已在跑的子会话，它一口气跑到 C5 后因额度中断；之后由两个短子会话分别收尾（对照发问、导出、停节点）与只读复盘。
  图解页进度标签已更新。本线容器 `npc-s1-hindsight-20261112`、`npc-s1c-pg-20261112` 及三个卷已删，容器 / 卷数 152 / 160；WSL 无 beam、无 tmux 会话。
  薄片一未验收完；等用户决定重设计 (b)(c) 再跑还是先进薄片二。
- 2026-11-12（第三个统筹会话）：用户答复——先诊断再重跑；补两处产品缺口；名字层与编号层分开确认；开服背景只写几句；事件用标准描述。已记入总纲。
  派出 S1-D1（离线诊断 + 事件清点）。本条之后没有新记录就说明 S1-D1 的结果还没收：看 `tools/jev/` 下有没有未提交的 `s1c_diag.py` 与结果文件。
- 2026-11-12（第三个统筹会话）：S1-D1 完成并提交（结果见“S1-D1 结果”）。派出 S1-D2（按标准描述表改产品：World 事件带根实例与是否整座移除、Life 按固定表写经历、
  Mind 现查 World 写自己的建筑在不在）。本条之后没有新记录就说明 S1-D2 还没收：看 worktree 里有没有未提交的 `apps/` 改动，按“S1-B2”那样验证后提交。
- 2026-11-12（第三个统筹会话）：用户同意 (c) 的新验法（破坏者再次出现；`guard_hut` 未必是错，要能区分选择的原因），要点记在“S1-C2 重跑的设计要点”。S1-D2 仍在跑。
- 2026-11-12（第三个统筹会话）：S1-D2 实现 → 独立复核（无必须改；查出 S1-B2 引入的一条 `voxel_region` 回归）→ 小修（修回归的夹具、整座移除后删关心格、README 记两条已知限制）→ 提交。
  本会话上下文接近 300k，到此结束；下一个统筹会话从页首“交接（第三个统筹会话…）”接着做 S1-C2。
- 2026-11-12（第四个统筹会话）：接手 S1-C2。起节点之前做了三件事：① 新 plan 定稿 `.demo/observe/npc-slice1-20261112/s1c2/plan.md`
  （sha256 前 16 位 `01e02d0fc68858e0`，起节点前更正过变体总数并补了“运行前补充”六条落地细则；检查点、16 个离线变体的期望与判定规则都在里面，之后不改）；② 离线预检 `tools/jev/s1c2_pilot.py`：
  S1-D2 的两句放回 S1-C 的 C2 state，8 个变体 × 4 次全部符合运行前期望（32 次请求、1 次网络失败未补问），只算预演；
  ③ 重起 Hindsight 与 PG 容器（`s1c2/services.txt`，容器 / 卷数 154 / 163）。接下来按 plan 分四段实跑。
- 2026-11-12（第四个统筹会话）：起节点前备齐：实跑脚本 28 个（WSL `~/npc-s1-run/*-s1c2.*`，副本 `s1c2/scripts/`；`watch-s1c2.sh` 常驻存每次选择的 state 全文，
  `start-s1c2.sh` 挂 180 分钟看门狗）；离线对照脚本 `tools/jev/s1c2_counterfactual.py`（16 个变体，只干跑过 `prepare`，没发请求）。尚未起节点。
- 2026-11-12（第四个统筹会话）：S1-C2 四段实跑完成（节点 16:54:38–17:20:45 UTC，看门狗未触发），离线对照 64 次、事后诊断 24 次。结果：(b) 通过、(c) 不通过，见“S1-C2 结果”与“S1-C2 事后离线诊断”。
  本线容器与卷已删（152 / 160）。图解页与进展页已更新。下一步待用户定，见页首“第四个统筹会话的结果”。
- 2026-11-13（第七个统筹会话）：交接“下一步”第 1–3 项的离线测量做完——S1-I 反思两轮（36 + 48 条产出、盲评、Jev 124 + 152 次）、S1-J 召回对照（120 次 recall）、S1-K 游戏时间措辞与叠加（Jev 68 次）。全部探索性，期望发问前写定、落空如实记，没有动 `apps/`。
  结论与“站不站得住”的判断见页首“第七个统筹会话的进展”；证据 `.demo/observe/npc-slice1-20261112/s1i|s1j|s1k/`。
- 2026-11-13（第七个统筹会话）：S1-L bank mission 离线测量；产品改动 `8dfb567b`（Hindsight 适配器）与 `b41c0590`（Life 写入侧），全套 430 通过，未实跑。用户更正：测量不生造数据、先看整条链；据此把依据手写材料的离线结论降为假设，顺序改为“先实跑导出再重测”。用户同意把“看到的”单独设计。因上下文接近 300k 交接给第八个统筹会话，见页首。

