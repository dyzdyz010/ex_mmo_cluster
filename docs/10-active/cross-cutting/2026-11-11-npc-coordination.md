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
| S1-C | 薄片一验收实跑 | 第二个 NPC 经正常入口拆第一个 NPC 的建筑；记录 (b) 事件前后的选择、(c) 情绪衰减且经历封存写入后的选择；命令、日志位置、原始结果写回本页 | 验收 (b)、(c)，区分已实现 / 已实跑 / 已验收 | 未开始 |

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
  `.demo/observe/npc-slice1-20261112/s1b/live-jev-20261112.log`。
  推测（未验证）：规则模式写出的经历原文是 `Actor 21 damaged construction I care about at (25, 518, 37), material 11 … (transaction 4711)`，
  只有坐标与编号，Jev 无从知道被拆的就是那座小屋；③ 的召回句明说了“the small hut I built”。
- 已知情况：信任不衰减，一次破坏后 `Distrusts …` 一直留在情绪栏，验收 (c) 要看 state 全文区分各栏的贡献；新 NPC 在 Hindsight 建好 bank 与四份认识之前
  每 10 秒显式失败一次（`life_models_unavailable`）；Hindsight 对片段抽不出事实时 `retain` 返回 `empty_facts`、自动写入停住，重复的活动经历会不会触发要实跑才知道。
- Life 状态里的 `caution` / `sociability` 统一形态不读；从 Life 里并掉待做。
- 统筹会话复核：看过 Life / Runtime / Selector / Registry 的差异；自建 PG（55446，已删）重跑
  `npc_selector / mind / registry / life / life_state / life_registry / social / tree` 97 通过、2 按标签排除。
  自建 PG（55444，已删）重跑 `npc_registry / settler / abilities` 35 通过。验收 (a) 与实跑没有重跑，以子会话留下的日志为准。

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
- 每个会话上下文不超过 300k tokens；接近时把已完成、未完成、证据路径、下一步写回本页再换会话。

## 证据与复跑

- Jev 离线实验：`tools/jev/README.md` 记录每一轮；`python -B persona.py report [mild|big5|card]`、`traits.py report`、
  `routine.py report`、`habit.py report` 离线重出表格。凭据在仓库根 `.env`（本 worktree 没有 `.env`，实验是在主检出目录跑的）。
- voxim-9c 的本机实跑记录：Voxim 仓库 `Saved/Tests/telemetry-npc-20261110/`。
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
