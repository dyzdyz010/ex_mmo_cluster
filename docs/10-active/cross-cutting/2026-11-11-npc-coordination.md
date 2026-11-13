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
- **T3 + T4（Mind 渲染 + 三路召回接线）已派出（2026-11-13T14:05Z），结果未回**：一个子会话串行做，临时 PG `npc-s1u-pg-20261113`（127.0.0.1:55464），日志将在 `.demo/observe/npc-slice1-20261112/s1t/t34-targeted.log`、`t34-full.log`；基线 447 通过、18 排除。**接手时工作区里 `apps/npc_server` 的未提交改动就是它的，没有本节的“已测”条目就不要提交。**接线规则见上面“对 T4 的判断”，实现拆分见下文第七个会话的“第 4 项的实现拆分”。做完后要再上一次真实服务端短实跑，一并覆盖“看到的”与三路召回（计划届时写 `s1t/plan.md`）。
- **反思写回重新提上来（用户 2026-11-13）**：用户原话“反思写回为什么不做了？这个我觉得还挺重要的，因为这里是角色静下心来不受即时决策影响能深度思考的途径，能形成 ai 小镇中所说的高级记忆”。此前搁置的两条原因——离线两轮（S1-I）用的是手写材料（已降为假设）、当时结论不稳定且对选择增量小——第一条现在可以消掉：有真实记忆库了。
  **S1-V（在真实导出上重做反思写回）已派出（约 13:40Z），结果未回**：计划与 7 条期望发问前写定在 `.demo/observe/npc-slice1-20261112/s1v/plan.md`；真实 133 份文档按产品的建法重放进新库 `s1v-copy-20261113`（本线自己建的），三个由代码模板产生的问题各调 Hindsight 的 `reflect` 3 次，取第 1 次写回为 `kind:reflection` 文档，再看它经召回与经四份认识两条路对选择的作用。脚本将在 `tools/jev/s1v_reflect.py`，读数落 `s1v/`。
  执行子会话只做关键词粗判；**盲判由统筹会话另派**（9 条反思原文在 `s1v/reflections/`，B0 / B1 认识全文在 `s1v/beliefs/`）；判定写 `s1v/results.md`，没有那个文件就是还没判。反思何时触发、放在哪个进程，本轮不测，要等结果再设计。
- **Docker 清理（用户 2026-11-13 要求“把旧的镜像、容器和数据卷都删掉”）**：统筹会话先做只读盘点——已停止容器 151 个（受保护的如园对象 23 个，voxim-* 120 个，别的项目 8 个）、无主卷 107 个（匿名 101、有名字 6：`ollama`、`maxio_pgdata`、`docker_mysql_data`、`docker_redis_data`、`docker_minio_data`、`docker_esdata01`）、镜像 157 个（91 个没有容器在用）。
  **用户经提问框定的范围**：容器——voxim-* 且建于 11 月 6 日之前的已停止容器（118 个）；卷——匿名的无主卷 + 被删容器独占的卷，现有那 6 个有名字的别的项目的卷不动；镜像——voxim-* 仓库里没有容器在用、建于 11 月 6 日之前的。
  不变的边界：受保护对象不删、不强制删仍被引用的镜像、不用任何 prune（按名字逐个删）、构建缓存不动（用户没提，且只能用 prune 清）、运行中的容器与别的项目的容器不动。实际删除清单与前后计数存 `.demo/observe/npc-slice1-20261112/docker-cleanup-20261113/`；**该目录里没有 `done.txt` 就是还没删完。**
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
3. 游戏钟（`2026-11-13-world-clock-design.md`）：服务端权威、世界基础设施；NPC 看游戏时间（“多久以前”= 真实经过 × 72 换词），Hindsight 仍存真实时间戳；昼夜日 = 现实 20 分钟，周 = 7 个昼夜日；第一阶段（不改协议）已做，**第二阶段（`SessionStart` 带 epoch/game0/rate、协议 44 → 45、客户端去常量）排在发版 `20261112-qinglan` 生产切换并公网冒烟通过之后，对接人 voxim-d4**，服务端方案准备好后发它；切换前本线不动协议。
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
3. **按游戏时间措辞的测量**：S1-H 刻意没含“多久以前”。游戏钟已有，按“真实经过 × 72 → 词”重做“过了多久”这类驱动，再叠加需求 / 约定等正向驱动（单个正向驱动移动只有 0.03–0.08，越不过守屋，要叠加才可能）。
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
  游戏钟设计页：[`2026-11-13-world-clock-design.md`](2026-11-13-world-clock-design.md)（草案，待用户过目）：纯函数 `game_us = game0 + (t − epoch) × 72`，不持久化、不广播；第一阶段服务端实现同公式（不改协议），第二阶段 `SessionStart` 带参数（协议 44 → 45，另排并与发版线对齐）。待用户定 3 条见该页 §5。**用户 2026-11-13 三条全部按建议**（NPC 看游戏时间、Hindsight 存真实时间戳；天 = 昼夜日 20 分钟、周 = 7 个昼夜日；第二阶段排在发版 `20261112-qinglan` 生产切换并公网冒烟通过之后，对接人 voxim-d4）。客户端对账已由 voxim-d4 完成（Voxim main `93a9cb27`）。**第一阶段服务端已实现、已测试、已提交**：`MmoContracts.WorldTime`（`params/0`、`game_us/2`、`at/2`，41 行）+ 设计页 §3 七行手算表的单测（mmo_contracts 全套 192 通过）+ NPC `Runtime` 观察新增 `world_time`（npc_server 缺省全套 414 通过、18 项按标签排除；`NpcBodyWorldTest` 那条 `:noproc` 用例这次没失败）。
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

