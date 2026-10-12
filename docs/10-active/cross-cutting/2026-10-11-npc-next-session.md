# NPC 连续自主生活、自给自足与人格模型：下一会话

## 2026-10-12 本轮收口

用户要求先停止设计讨论，记录后整理代码、合并分支、提交推送并保持当前工作区干净。
角色卡、共享提示词、心智边界、flush修复方向与后续最小验证统一记录于
[长期自洽设计稿页首](2026-10-11-npc-long-horizon.md)。这些是待实施设计，不在本轮补做新功能。
既有实验均已停止，最后一轮happy path的行动结果可用，记忆收尾明确失败；详见下文。
下文按时间保留历史记录；旧的“启动/续跑”要求均不再是当前执行指令，后续需从本节收口状态继续。

### 合并范围与验证入口

收口分支为`capability-library-20261007`，目标为远端默认分支`master`。
代码与测试收口提交为`162d0349`；本节验证对应其源码树，设计与结果记录单独提交。
基线`f94a3d72`到既有分支头`2e67b69a`共73个提交，涉及协议、持久化、移动、World与NPC；
因此本次除了未提交的手动决策/脚本增量，还复验这段范围直接修改的测试，不扩大到无关全仓测试或付费实跑。
新增代码复用正式Body → Runtime → Llm链路；CLI桥接、年度/短场景驱动均为Test-only。
合并审查另修正技能`data.memory_error`判定与trace停止失败后的最终状态落盘，保留普通玩法`data:null`结果契约；
这两项有先失败再通过的最小反例，不含已披露的Life flush设计改造。

可复现入口：

```powershell
# 在 apps/gate_server 中验证本次运行时增量。
mix test --no-start test/gate_server/npc_brain_llm_test.exs test/gate_server/npc_life_registry_test.exs
# 在仓库根目录验证实验驱动；不调用真实模型。
python -B -X utf8 -m unittest discover -s scripts/npc_life -p 'test_*.py'
python -B -X utf8 -m unittest discover -s scripts/npc_dialogue -p 'test_*.py'
python -B -X utf8 -m unittest discover -s scripts -p 'test_npc_run07_observe.py'
python -B -X utf8 -m unittest discover -s scripts -p 'test_npc_soak_sampler.py'
```

跨app复验文件由`git diff --name-only f94a3d72 2e67b69a -- '*_test.exs'`得到，按app分别执行`mix test --no-start`；
排除上述已单独验证的两个文件与显式长期`npc_settler_soak_test.exs`，其余默认排除标签保持不变。
完整展开命令与本机日志保存在`.demo/observe/npc-merge-20261012/test-commands.json`及同目录app日志。
数据库使用本机既有PostgreSQL端口26769，用户名/密码从该容器配置读取且不入产物；
不指定`MMO_TEST_DB_NAME`，由`MmoTest.Database`创建本次VM独占库并在结束时删除。
首次data_service运行因默认5432无服务而3项invalid，原日志保留；改用上述隔离配置后3项通过。

验证结果：运行时增量42项通过；协议38项、持久化3项、Scene 73项、World 105项通过。
Gate其余范围首次264/267通过、9项按默认标签排除：Registry旧完整profile漏`cadence: automatic`，
旧Body用例仍把say当占位拒绝，全能力接缝参数遗漏say/set_plan。同步现行契约后前两项通过；
最后一项进一步证实公共`Body.command`漏转发set_plan，已补入既有Runtime转发列表，
真实Body → Runtime → Memory接缝同时核对终态与保存内容后通过（存储为该用例既有Agent替身）。
没有放宽能力集合相等或`invalid_command`断言；复验只选择失败项，没有重跑已通过的大范围。
对应日志为`gate-server-failed-recheck.log`与`body-plan-seam-green.log`。去重后覆盖528项Elixir测试。
Python：npc_life 73项、对话判定10项、run07观察2项、soak判定4项，共89项通过；
合法`data:null`的补充修正后，小时/短场景驱动14项再次通过，不重复累计。
修改的Elixir文件格式检查、`git diff --check`通过。只读合并审查修正了明确缺陷；
本轮未重新运行真实模型、长期挂机或UE客户端，既有happy path的`failed_cleanup`结论保持不变。

## 2026-10-12 17:52 happy path 行动阶段完成（最新）

run-02 两段行动已结束：30 次真实决策，3 次 move_to 均进入容差并停稳，6 次 look、6 次 remember、
7 次 say（6 次接纳，1 次 conversation_expired）、7 次 set_plan、1 次自主 wait。
松岚第一段实走东侧，第二段分享、记事并休息；知衡按 LifeBuilder 的介绍实走南侧，
LifeBuilder 按邻居介绍实走东侧。三人均有本轮真实“走到—观察—分享—记事”，未采集或建造。
不能把第一段 LifeBuilder/知衡讲述的旧行走计成本轮新移动；也不能把松岚算作新访问了两处。

知衡四份认识已在行动期更新，包含本轮散步提议；self 仍自称 builder，与现有建设者提问模板对应，
角色刻画尚有偏差。三人 canonical traits/relationships 本轮未变化；本轮主要验证经验复用和交流带动行动。
实际约20分钟才完成30次决策，决策 usage 为1,433,907 token（不含记忆服务）；效率仍有改进空间。
只读汇总在 `run-02/action-summary.json`，原始证据为 steps 与 checkpoint-00000/00002。
最终于18:02:45（UTC+8）结束，状态 `failed_cleanup`：最终检查点等待记忆归档600秒超时，
错误 `memory checkpoint did not drain`，未生成final checkpoint，不能称整轮无错误完成或记忆已全部归档。
已通过实际Registry核对三人恢复原登记：LifeBuilder/松岚为settler、知衡为llm，均未启用Life；
30步与两个阶段检查点保留，不追加重试或改写已有实验结果。

### 19:05 只读定位归档超时

根因已由持久状态、远端操作与桥接记录交叉核对：`hourly_year.checkpoint`把经历写入与认识刷新一起等，
要求所有Life的job为空，总期限600秒；retain成功后Life会自动启动串行的四模型refresh。
建设者新片段17:54:48巩固完成、知衡17:56:11完成，但建设者最后一份承诺认识18:04:42才完成，
晚于18:02:45驱动退出；知衡关系认识18:04:23完成，其剩余两份本轮刷新未继续发起。
收尾开始后桥接共启动30个记忆模型请求，exit_code全部为0；这是整个收尾期限与后台工作范围不匹配，
不是本轮观察到的单次模型错误。恢复原登记会停止Life worker，远端已提交操作仍可能继续完成，
所以不能把远端completed等同于NPC本地cache已经接回。

另有实际flush语义缺口：松岚当时job=refresh，flush在封尾之前返回ok/busy；驱动只检查ok包装，
也没有检查pending_episodes。现查松岚仍有6条、2404字符pending经历，已持久保存但未送入Hindsight，
低于3000字自动封片阈值。建设者/知衡pending和fragments均为0、retained分别9/4，dirty仍为true。
修复方向应分清经历写入完成与认识刷新完成，并由Life明确维护busy期间flush的接纳与完成语义；
不是延长超时或追加重试。本次只读诊断，未改运行时或重启Life。
证据：`run-02/diagnosis-110514.json`、`diagnosis-models-1106.json`、`run-01/bridge/calls.jsonl`。

心智现状核对：当前Life/LLM把数值mind、四份文字认识与一次召回作为决策输入；
`State.behavior`的社交距离硬规则只由Social/Tree路径调用，本轮三名LLM并未调用它。
新个体固定初值为caution=0.2、sociability=0.5，尚无按角色卡初始化；对话不直接改变数值情绪、人格或信任。

### 17:33 启动记录

用户明确要求先设计再开始，按实际效果看经验形成与心智，只跑happy path，不做无谓兜底或理论归因。
新场景“邻里植物散步”：各找一处植物点实地访问并交流，再去邻居介绍的地点应用经验。
入口`scripts/npc_life/happy_path.py --out .demo/observe/npc-happy-path-20261012/run-02`，
17:32:25（UTC+8）启动PID208168，桥接PID208556，真实模型gpt-6.1-sol/medium。
两段各600秒内最多24次决策，已发动作等终态；结束保存检查点、恢复原登记，保留新记忆与位置。
首步LifeBuilder已自主say并获done，分享此前枫木/蕨观察与行走经验；尚不等于本轮实际移动或全部目标完成。
实时只读progress/steps及活进程；桥接日志在同实验run-01/bridge/calls.jsonl。
run-01仅准备阶段误等后台refresh超时，决策0次；已核对Life缓存可用契约并删除此多余等待，原失败保留。
旧run-05实际已于14:17结束：269步、两个真实小时，模型返回capacity；下面11:54启动记录是历史。

## 2026-10-12 运行核查与桥接误停修复（历史记录）

用户问当前情况时，run-04已于10:46停止，不能称仍后台运行。
实际完成32步：4 survey、6 look、7 say、7 move_to、4 remember、3 set_plan、1 inspect。
say中5次接纳、2次conversation_expired拒绝；move_to中6次done、1次no_path，done也不全部等于精确到达。
知衡主动询问通行需求，LifeBuilder回复，知衡继续同一会话；松岚后续分享自己的成功试走。
有真实自主往返、探索与反思记录，尚无采集或建设，也未完成一个完整小时。

根因是桥接把CLI中间 `error: Reconnecting... tls handshake eof` 当最终失败，
尽管同调用随后 `turn.completed` 且有真实usage。不是余额或登录额度不足。
已修正为以turn.failed/完成终态及usage判定，新增恢复重连反例先RED后GREEN，桥接4项通过。
旧失败结果不改写，额外36080实际token写入run-04/cost-reconciliation.json；
该次输出未交付NPC且不重放陈旧意图，后续从真实现状重新决策。

当前run-05于11:54启动，PID209764；桥接PID209360，实际日志wiring-01/bridge-04/calls.jsonl。
沿用三人永久身份、位置、计划、笔记、独立bank和同一服务镜像；记忆无待操作/巩固，最终checkpoint无Life错误或未存尾部。
已知成本62960075 token作为新轮prior基线，旧未知usage1次不清零。当前真值只认run-05/progress与活进程。

## 2026-10-12 修正小时调度：放开连续思考与行动（历史记录）

用户指出没有行动，要求“放开预算，像真人一样思考”。核对三份真实请求，每份均有40个工具，
包含say、survey、move_to、gather、build、place；不是漏注入接口列表。
根因是本轮驱动错误地把小时边界变成每人一次工具调用的门禁：三人先选set_plan，
计划仅存入NpcMemory，不自动执行；于是所有后续行动被挡住一个真实小时。

已按正式停止入口结束run-03，保存3个成功set_plan、新计划、原始trace和累计成本。
改为小时内连续三人轮转，非wait动作同调用终态后继续决策；仅模型wait暂停该角色，
新直接发言通过正式Dialogue契约判定并提前唤醒。小时仍只统计真实经过时间，不是LLM调用预算。
工具调用有独立sequence/tag，避免同小时反复复用身份。实验预算仍无总量上限，不强制任何say/移动/采材工具。

当前 `.demo/observe/npc-three-life-20261012/run-04/`，PID185780；桥接仍PID76608。
建设者第一步自主survey（59,-521到70,-512）已获同调用号Body done，实际在执行旧轮保存的新计划。
先前已知61577588 token纳入本轮prior基线（包括初次CLI预检与此前桥接调用），不是重新清零预算。
运行状态只认当前progress、steps和活进程；下面run-03启动快照为历史。驱动11项、桥接3项通过，
集成测试明确证明set_plan后同小时第二轮再次给同角色许可，不需要等小时边界。

## 2026-10-12 当前会话实际接管与启动（覆盖下面待执行口径）

本工作区全部已有未提交改动保留，没有再新建用户接手会话或 checkout。
本机 CLI 0.161.0 的 ChatGPT 登录已真实调用指定 `gpt-6.1-sol / medium`，接通本机桥接，
Demo 决策与 18908 独立 Hindsight 均使用它；没有提取登录令牌或退回旧余额不足端点。
原两人的持久 Life 在接线重启前后严格相等，正式镜像身份没有改变。
证据 `.demo/observe/npc-codex-20261012/{preflight-01,wiring-01}/`；桥接当前 PID76608，
实际 CLI 事件与 usage 在 `wiring-01/bridge-03/calls.jsonl`（早期桥接目录也保留）。

角色现为 LifeBuilder / 建设者 / cid607440080896、松岚 / 探索者 / cid51107598336、
知衡 / 学者 / cid10938748928（真实 Registry 新登记返回），每人独立 `npc-life-{cid}`。
提示词 `scripts/npc_life/hourly_year.py:LIFE_GOAL`；角色倾向 `ROLES`，实际提示在运行 `protocol.json`。
登记、轮转、小时证据、记忆基线、检查点及恢复共用本轮从 Registry 得到的三人 cid 集合。

当前新轮 `.demo/observe/npc-three-life-20261012/run-03/`，PID207740。
真实首轮已完成3步，三人各自选择 `set_plan` 并有同调用号 `Body done`；
计划分别为改善通行、结束休息重新探索、观察并向邻居请教。尚无新 `say`、采集或建设。
首轮完成后等待真实小时边界；最新状态只认该轮 `progress.json` 与活进程，不能将本条快照当全年完成。

**时间决策**：现有 Scene 身体按1 Hz推进，World事件、Life情绪走真实时间，没有可复用的统一加速时钟。
为停止旧轮绕过3600秒等待的空转，新轮按真实3600秒计一个完成小时，完整小时与完成决策轮数分开。
8760小时因此需要365天持续在线；营养只在伤口修复时消耗，不是全年饥饿生存验收。
该执行方式不是加速模拟一年。以后若要求快速一年物理演化，必须先设计正式 owner 的统一时间接缝，不能回填身体/情绪或伪造时间。

失败均保留：新轮run-01因与旧实验共用trace短名准备失败，run-02因新学者bank尚未初始化而失败，
二者未发NPC决策；修复为完整运行身份与Life readiness后读三人记忆基线。
Hindsight初次样本零facts被显式拒绝，另一次CLI内部重试配置使用保留provider名失败；
后续独立明确事件样本实际抽取2条facts，随后才启动run-03。桥接不主动重试，Hindsight retries=0，CLI内部采用官方默认。

旧已知累计61306557 token及旧1条usage未知失败继续保留；本机初次预检22927 token，
全部后续桥接调用另在各 `calls.jsonl` 逐笔累计。Hindsight status 的输出指标不包含reasoning，
本轮总成本核算须以CLI `turn.completed.usage`计入完整output，不能把两套指标相加重复计费。
预算仍无实验侧总上限，外部登录限额/可用性仍是实际服务条件，尚无货币金额依据。

最小验证：驱动9项与桥接3项通过；新bank时序反例对旧顺序失败、对新顺序通过。
真实接入证明范围与状态/停止命令见 `scripts/npc_life/README.md` 页首；没有新UE客户端验收。

## 2026-10-12 新会话接管：三角色的新实验（历史执行要求）

用户要求“在新会话开始新实验，还是3个不同角色的npc”，并已明确选择 **探索者、建设者、学者**。
这是执行交接，不是只写方案。新会话在当前 `ex_mmo_cluster-capabilities` 工作区接手全部未提交成果；
原会话完成交接后停止写入，不新建缺失当前补丁的 checkout，不回滚已有改动。

新会话终端已创建：`NPC三角色美好生活新实验`，handle `term_534b2009-44cc-4365-833d-aaaa5c5a7e60`，
同一 worktree id 为 `e978d567-17b7-4643-928f-9443d486c122::C:/Users/DYZ/Documents/dev/hemifuture/ex_mmo_cluster-capabilities`。
启动命令指定 `gpt-6.1-sol` / `medium`，TUI 已显示该配置；这只证明接手会话配置，不代表 NPC 后端已接通。

- 共同方向继续引用 `hourly_year.py` 的 `LIFE_GOAL`：好好探索了解世界、生活、建设、学习，为了美好而建设。
  角色是兴趣与生活倾向，不是脚本强制动作：探索者侧重发现与分享，建设者侧重宜居和实际改善，学者侧重观察、验证和交流学习。
  可让松岚任探索者、LifeBuilder 任建设者，通过正式 Registry 新增独立学者；新名字可自定，真实 cid 由登记结果取得，不能编造。
  保留原两人的经历、关系、计划与库存；由模型按新目标自主修订旧计划，不替模型写入已完成经历。
- 继承至少一年、按小时共 **8,760 小时**、`gpt-6.1-sol / medium`、实验侧总预算放开的要求。
  旧轮的累计用量和失败仍保留，新轮必须用新运行标识和目录；不得把旧轮1,689小时或新启动当作新轮全年完成。
- 用户上一条后端需求为“之后llm api能不能换为复用当前codex”。本机已核实 Codex CLI 0.161.0 且为 ChatGPT 登录，
  但尚未接入实验，也未验证该登录下指定模型可调用。以官方本机 Codex 接口复用登录为接入方向，
  先验证指定模型，再接真实 NPC 决策与独立 Hindsight 流量；不提取登录凭证充当通用 API key，不静默退回余额不足的旧端点。
  这不等于共享本聊天上下文。已有只读发现与官方资料索引：`.demo/observe/npc-codex-20261012/discovery-01/findings.json`。
- 现有 `hourly_year.py` 仍是两人驱动，多处 RPC 固定两个 cid，不能只改 `CIDS` 就声称三人接通。
  新会话先检查登记、顺序轮转、小时完成判定、记忆计费、检查点及清理恢复，使用同一角色集合，按改动契约做最小充分验证。
- 上轮97.69%等待、无交谈，且只推进小时标签，World/身体/情绪仍走现实时间。
  新会话必须明确并处理生活时间推进的真实边界；若仍仅为决策采样，必须如实标注，不能宣称一年物理生存。
  先观察真实三角色闭环中的目标更新、对话、探索、采集、建设及记忆，记录模型自主选择而非强制挑工具；
  不靠无限重复同样等待或人为补料制造结果。先读长程实验页首的原因分析，避免重演已知设计缺口。
- 唯一当前服务组合仍是 Demo `voxim-npc-life-demo-20261011`（27361/27363）和 Hindsight `voxim-npc-life-loop-20261011`（18908）；
  18888/18898 属于其他实验。先只读核验活进程、登记、镜像和存档，再变更本任务资源，避免双启动。
  使用正式 Registry/Body/Runtime/Llm 与 World 权威结果，不构造第二套模拟真值。
- 开始前读 `AGENTS.md`、系统正交纲领、`../Voxim/Docs/Testing.md`、`scripts/npc_life/README.md` 和长程实验页首。
  进度、错误、实际模型/effort、usage、每人动作与同调用号终态、当前计划和对话必须可从 CLI/结构化日志读取。
  稳定启动后给用户新会话中的实际进度、产物路径及可编辑提示词位置；外部失败要明确报告，不宣称仍在后台正常运行。

## 2026-10-12 目标提示词更新（待下次加载）

用户指定两名 NPC 好好探索了解世界、好好生活、好好建设、好好学习，并“为了美好而建设”。
唯一目标配置为 [`hourly_year.py` 的 `LIFE_GOAL` / `GOALS`](../../../scripts/npc_life/hourly_year.py)，
共同方向只定义一次，保留各自身份；提示允许主动修订旧守望/休息计划并选择具体下一步。
本次只更新目标文案，未清除持久计划或记忆，未重启实验、切换模型后端或发出模型请求。
新目标将在下次驱动登记时加载；尚未验证它对真实自主行为的效果，旧运行的失败及行为证据保持原样。

## 2026-10-12 06:54（UTC+8）核验：一年实验已因模型服务余额不足停止

`run-01/progress.json` 为 `failed`：完整完成1,689/8,760小时（70天9小时），3,379步；第1,690小时LifeBuilder请求收到HTTP403，正文 `insufficient balance / billing_error`。任务于03:44:54结束，PID199876已退出。实验侧无token上限，外部账户余额仍是服务条件；没有自动重试或重开新轮。

本轮零次 `say`，3,301次wait，其余为48次look、26次inspect、2次set_plan、1次survey和1次move_to。决策usage为58,886,946 token，记忆新增404,386，另有预检4,278；失败请求未返回usage（`usage_unknown_requests=1`），不估造金额或把其记成已知零费用。全年与自主交谈都未达成。

已核实 `checkpoint-01689-final.json` 留存，双方Life无错误、无在途job或未存片段/话语；Registry已恢复原settler，两个服务容器仍运行。继续需要先恢复指定模型服务的可用余额，并处理已有第1,690小时半完成步骤；现有run入口不支持直接原地续跑，不得重置计数、覆盖run-01或重复执行已完成步骤。下面启动记录为历史。

## 2026-10-11 22:45（UTC+8）：一年小时采样启动记录，覆盖此前旧预算阻塞

用户明确授权至少模拟一年、预算全部放开、模型 `gpt-6.1-sol / medium`，并选择 **8,760 小时**。
新任务已在后台启动：PID `199876`，入口 `scripts/npc_life/hourly_year.py`，当前进度真值为
`.demo/observe/npc-year-20261011/run-01/progress.json`。**接管必须先读进度、核对进程，禁止重复启动第二轮。**
8,760 是目标，不能把启动或最初小时通过称作一年完成。

- 本轮是 Test-only 小时决策采样，World 物理、事件时戳和情绪衰减仍走真实时间；不是全年物理生存验收。
- 正式 Registry 的两个原 NPC 都使用 `life/cadence=manual/max_requests_per_hour=unlimited`；每小时各一次真实模型请求，先手交替，动作同调用号终态后推进。旧心智、计划、记忆、库存保留，没有玩家代答、补料或写入虚构经历。
- 正式独立 Demo 已换成 `voxim-server:20261011-npc-year-manual02`，image ID `sha256:cac4e3f29feadfa02a5bf997ba527c1a3c128b6e8d33549ba54965994c8c762a`，沿用 27361/27363 与记忆 18908。构建来源为 `2e67b69a` 加当前手动步进工作区补丁，精确四模块 SHA256 在 `build-02/manifest.json`，实际加载身份在 `run-01/execution.json`；不要称为原954528c1镜像。
- 模型与 Hindsight 实际生效配置都已核实；记忆抽取输出英文、SDK retries=0。`wiring-01/`证明升级前后持久 Life 行逐项相等，模型预检实际4,278 token；历史2,010,947仍计入，新授权没有总量上限。
- 严格 token 计数预检失败保留为历史，解除总额上限后不再作为本轮门禁。HTTP、读取记忆或写入记忆失败停止后续；普通玩法拒绝记录为经历，不冒充成功。
- 已有真实首小时两人 `look/Body done`；22:54:38首日记忆检查点通过，22:55:10快照完成26小时且仍运行。首日48步为2次look、46次wait，没有新增自主对话；输入能看见彼此，保留的旧计划倾向等待。后续行为与最终时长以运行产物为准，不先写成通过。需要停止时使用 `hourly_year.py stop --out .demo/observe/npc-year-20261011/run-01`，等待当前请求/动作结算并恢复原登记；manual 配置在节点重启后不会自动发模型请求。

完整契约与证据索引见 [长程实验页首](2026-10-11-npc-long-horizon.md)。测试/判定器审查发现的记忆失败漏判已修正；35个Brain用例（其中34一次通过、1个夹具期望修正后定点通过）、8个LifeRegistry用例及6个Python判定用例的原命令/结果保留在 `npc-year-20261011/validation/`，不把重叠命令数量相加。

用户于2026-10-11明确要求：“这是阶段性成果，请你先做成单独后端接入npc，然后新开一个会话继续做跨越连续自主生活以及自给自足和人格模型。话说npc的聊天功能做完了没有？”这是续接同一目标的执行授权。先完成独立后端与交接，新会话接管后继续实施和验证，不只给方案。

## 2026-10-11 能力库续接——当前状态

用户已明确让本会话继续，并要求完成聊天函数库接入，让NPC自主交谈。核对后确认对话阶段已把 `say` 纳入统一 `Abilities`，本轮补默认life档案与生活工具共存、两个真实Body/Runtime/Llm无玩家开场→回复→回到工作的接线测试，11项通过；模型/Hindsight为替身，不能称真实模型自主交谈已新增验收。已修正能力库文档中仍写“say不投影”的当前口径。

**新增预算授权已生效**：用户回答“追加 1,000,000 token”，累计上限改为3000000，历史实际2010947继续计入，余989053。本轮新增模型生成0；旧超额10947未清零。旧对话失败账本不改写，授权和只读接管证据在 `.demo/observe/npc-autonomy-20261011/resume-01/`。

**付费场景未启动，外部计数契约未通过**：新的Test-only统一预算代理覆盖决策/记忆出口，15个本地反例通过并经审查修正并发、重启未知预留、结果回传丢失、结算存储故障和实际输入计数不一致。真实兼容服务的完整历史请求count预检出现502；随后相同计数字段返回11694，而原实际输入为10294，不能用该接口声称严格总量预算已接通。`budget_service.setup`在任何容器写入前必须通过该预检；本轮没有部署预算容器、改共享服务环境或切NPC后端。请先解决/查证供应方计数差异，不重置账本、删除失败或偷偷改成软轮询门槛再开跑。

- **现场生命周期**：仍是正式源码954528c1、Hello40；原Demo27361/27363和18908 Hindsight运行。两个NPC仍为settler且无life参数；没有本轮UE双端、模型请求或trace。世界cursor48、LifeBuilder木料余额0，指定六格天然木料仍在；target由旧玩家修复，不能算NPC恢复。
- **代码/文件占用**：本轮修改两份NPC测试、能力库/README/阶段/交接文档；新增 `scripts/npc_life/{budget_proxy,budget_service,live_autonomy}.py` 及其离线测试，服务生命周期补支持同一不可变镜像ID。无对话协议、Scene/session/client源码修改，无跨树写入；收口后没有在途写入。
- **下一次固定实验**：`live_autonomy.py`使用Hello40隔离客户端，双端先旁听两NPC自发往返，再放行两次玩家破坏与NPC有限材料修复；预登记560秒、失败停止后续、逐笔actor/seq/余额/canonical/客户端对账。当前仅离线门禁，尚未真实运行。Hindsight英文输出和0重试/180秒超时写在预算部署脚本，尚未在现场应用；旧中文抽取/承诺误归因失败保留。

详细依据、测试命令和残余缺口见[自主生活阶段](2026-10-11-npc-autonomy.md)。先前“不足额度”状态仅是历史，当前阻塞是计数契约，不能再次要求用户重复追加预算。

## 2026-10-11 对话收口——历史检查点

对话第一版已接入并实跑，结果唯一正文为 [对话阶段](2026-10-11-npc-dialogue.md)。玩家与两个独立NPC公开交谈、指定对象、旁听加入和远距拒绝已有证据；客户端准星目标、UMG中文及系统拼音也已实跑。完整双端回放被决策预算门槛停止，不能以已完成发言的功能复判冒充整轮成功。

当前正式release为954528c1、Hello40；客户端隔离worktree `C:/Users/DYZ/orca/workspaces/Voxim/npc-dialogue-20261011`，布局版本bb2c4403。服务端仍在本分支，均未合并主树。独立Demo沿用27361/27363和记忆18908。

**预算已耗尽且超额**：累计2010947/2000000，超10947；原因是决策软门槛未计同时发生的后台记忆处理。LifeBuilder/cid607440080896与松岚/cid51107598336现均为settler，且移除life参数，禁止按下面历史说明自行恢复付费工作。存档、人格与历史保留，Hindsight无待操作/巩固；只读冷重启验证和本地召回不新增模型费用，各NPC仍有4条已落库的待retain尾部。新预算未授权，逐请求前的总费用控制亦未完成。

下一阶段连续自主生活、自给自足、人格模型仍待推进，现有对话短场景不能证明长期自洽。后续接管先读本轮 `.demo/observe/npc-dialogue-20261011/budget-ledger.json` 与阶段结果，费用不因换会话或重启重置。

## 2026-10-11 20:16（UTC+8）优先级与并发交接——历史检查点

**用户最新要求：先做对话，必须同时支持玩家↔NPC、NPC↔NPC。** 原会话接管正式 say/heard 设计与实现；本续接会话保存自主生活阶段，冻结共享 Demo 升级与 NPC 后端切换。以下当前状态覆盖本文后面首次交接时的 life/1h 描述；后面的旧阶段证据仍保留。

- **文件占用**：自主生活产品代码已提交，不再占用或修改 `apps/gate_server/lib/gate_server/npc/{brain/llm.ex,runtime.ex,body.ex,abilities.ex,README.md}`，也不修改 Session/Scene/客户端对话接入边界。后续自主生活工作限 `scripts/npc_life/{autonomy.py,test_autonomy.py,long_horizon.py,test_long_horizon.py,demo.py}` 及本页、`2026-10-11-npc-autonomy.md`；本次保存完成后无在途写入。对话会话可以基于当前提交修改上述产品文件。
- **代码基线**：`0ceeb544` 保存 Life 最近八种失败调用、跨轮/重启可见，并给 survey 显式脚层、no_path 同快照诊断；`d90fafd9` 加入 sociability 及有限材料组件闭环；`5b4cd58e` 补采集 actor/seq 对账与注释。产品全部在本分支，未合并/推送。
- **Demo 当前实际版本**：正式 release 源码 `5b4cd58ed6e5436c1e9fab18c9c6e11f6bba922d`，镜像 `voxim-server:20261011-npc-life-5b4cd58e`，image ID `sha256:999c33b462ff68817badd99def129c96608880d819b6ad52426a6813f1cba6fa`。这是最新优先级消息到达**之前**已经完成的一次升级；之后未升级或切后端。旧 canonical 只新增 sociability=0.5，其余字段逐项相等；缓存/原历史未重算。证据 `npc-autonomy-20261011/upgrade-01/`。
- **运行生命周期**：Demo 容器和18908 Hindsight仍运行；LifeBuilder/cid607440080896 当前持久登记为 **settler**，保留 Life sidecar；`Life.error=null`，world cursor48。无本续接会话启动的 UE 双端进程、LLM 请求或 trace，无待完成 Hindsight 操作/巩固。切回 settler 发生在接管开头并有 `takeover-01/` 记录，不是为重复获取请求额度。请勿按后文旧 life/1h 描述重复恢复或登记。
- **累计预算**：截至 `2026-10-11T12:16:52Z`，本会话外部模型新增 **0**；累计仍 **1,243,611 / 2,000,000**，余 **756,389**。升级后服务日志无 LLM decision/request_failed；NPC bank usage 与接管快照相等，pending_operations/pending_consolidation均0。预算没有重置。只读核查和完整登记状态见 `.demo/observe/npc-autonomy-20261011/chat-priority-handoff-01/manifest.json`、`runtime.json`、`hindsight-status.json`。
- **已经验证**：旧两次 no_path 是把实心地表417当脚层；同世界只读复演，418均可达，未改碰撞算法。组件 Life/State/Social/资源45项通过；补审后的资源/Survey/Memory/LLM直接回归17项通过；新驱动17项离线测试通过（数字属于不同命令，不相加充当独立总数）。真实 World/Scene/Body 两轮有限材料采集→消费→破坏后恢复通过，但动作由测试安排，**不能称模型自主重建成功**。
- **未执行/未证明**：本轮真实 LLM 自主采材/两次重建、两端复制验收、人格模型配对均未启动；未证明长期自主活动，更未证明30天自主生活。聊天仍由对话会话完成和验收，旧 say/heard 接缝不是聊天完成。
- **驱动待收口**：新增 `autonomy.py` 已有玩家仅破坏、两轮资源收据、每轮两端事务门禁；新运行ID拒绝覆盖旧trace；最后HTTP返回不等于动作终态，恢复settler前先关闭验收窗口。审查发现的角色查询API、提前放行、取消末动作与后端归属漏洞已修并有离线反例。**预算目前仅350000决策usage轮询门禁+100000在途/记忆预留，尚无逐请求发出前的硬token门禁；错误响应的轮询停止也未严格排除生产退避重试竞态。不得把驱动称作已完成正式验收或在未收口前启动昂贵实验。**

详细契约、依据、失败日志与剩余项见 [自主生活阶段](2026-10-11-npc-autonomy.md)。当前对话工作无需重新验证上轮冻结的全部事实，按自己的变化边界选择最小充分测试。

## 工作区与不可变约束

- 当前worktree：`C:/Users/DYZ/Documents/dev/hemifuture/ex_mmo_cluster-capabilities`，分支 `capability-library-20261007`；继续在此工作，不动主树 `../ex_mmo_cluster`。新会话复用此worktree，不新建一个丢失阶段成果的checkout。交接后原会话停止写入。
- 先读本仓AGENTS、系统正交纲领、`../Voxim/Docs/Testing.md`、`../Voxim/Docs/Gameplay/NpcEvolve/NextLoop.md`及其同目录README结论/接入要点，再读本页引用的阶段文档。Voxim唯一客户端，禁止验证归档客户端。
- Hindsight0.10.3+flashrank，ONNX BGE-small/CLS/查询前缀；记忆按片段英文批写，决策使用缓存四模型+一次召回；不引入Concordia。人格/情绪仍由NPC显式状态与权威事件规则评价维护，数字查World，每个维度要影响行为。
- 独立Demo的Hindsight只用18908，**不碰18888/18898**（其它代理实验）。LLM key绝不落盘；模型预算持续累计，不能因换会话/重启重置。
- 真实双端单场景约10分钟，持续演化用服务端测试的受控时钟。保持首个失败阶段停止，不为获得绿灯人工注入运行中NPC心智、余额或完成结果。明确已实现/已实跑/已验收/未证明。

## 已交付阶段与证据

- 人生最小闭环：[原阶段](2026-10-11-npc-life-loop.md)，最终证据 `.demo/observe/npc-life-20261011/final-04/manifest.json`。六轮伤害/帮助、真实社会行为与人格陌生人对照、服务/Hindsight冷恢复。其失败/时间超目标及时间派生偏差不能抹掉。
- 长期自洽基础：[续验阶段](2026-10-11-npc-long-horizon.md)，`.demo/observe/npc-long-horizon-20261011/final-01/manifest.json`。当前计划独立存NpcMemory `kind=intention/key=current`，不要碰Wilderness已占的`plan/current`；Life模式补回近期笔记。LLM等待/请求期间的新权威评价可唤醒，旧response不会覆盖新dirty。
- 受控时间1/7/30天与owner恢复通过（外部记忆替身），不等于30天模型连续生活。真实12次配对意向随自传身份变化，检验Hindsight+显式关系整体；未执行合作行为，不能单独归因Hindsight。
- 同NPC现场22决策：13个Body done，2个no_path rejected，7个Brain本地wait。发现缺损后自拟采材修复计划，玩家修复后look纠正假设、取消过期步骤、实际保存新计划/笔记。双端229.294秒，43/44/45/47四笔事务全量对账。**NPC没有自主采材或重建成功**，不能跳过这个缺口。
- 新两条经历批为第3个Hindsight文档，四模型刷新完成；完整服务冷启动后canonical/cache/plan/note严格相等。最新伤害/帮助计数7/7，谨慎0.40，A信任-1、B+1。数值只在调试层。
- 旧饱和信任经历文字仍写changed，Hindsight帮助事实仍可能+10ms，均不是World数值真值。已有界限保留，不扩大“完整人生完成”的结论。
- 最终审查修复4b06b564：真实驱动A destroy确认才放行B build；观察异常不跳过恢复/停止trace；恢复失败显式停用本任务登记。10项离线反例/接线通过。不要为了复跑删除旧trace绕过预算，下一阶段需新运行标识并累计已有用量。

## 独立后端

新增正式登记名 `brain: "life"`。它复用 `Brain.Llm`、`Life`、`Memory`、`Body`，不是另造LLM循环。`goal`/`tools`必填，`life`省略时使用环境`NPC_LIFE_HINDSIGHT_URL`；可显式传`%{"url" => ...}`，禁止`life=false`；默认60/h，显式1..60。旧llm/settler可选Life方式保留。

生产入口与CLI例子见 `apps/gate_server/lib/gate_server/npc/README.md`；续验的`long_horizon.py freeze/pairs/live`已改用life入口。Registry配置新反例先RED，LifeRegistry+Registry17项通过，驱动入口10项通过。正式release源码`9b52cde9`已构建部署，image `voxim-server:20261011-npc-life-9b52cde9`。同一个LifeBuilder已持久登记为life，真实首轮look返回Body done；旧计划、笔记进入首轮上下文，canonical/cache保留。后端结果在 `.demo/observe/npc-life-backend-20261011/manifest.json`。

**首次交接的历史状态（已被页首20:16状态覆盖）：当时NPC正在life后端，临时限1请求/小时，首个请求已用；trace已停。** 接收会话随后已按授权恢复settler并记录；不能因重新登记而重复获得新额度。

## 运行资产与预算

- 服务端：`voxim-npc-life-demo-20261011`，HTTP27361、QUIC27363（loopback）；正式Dockerfile/release。镜像/加载摘要以本轮后端manifest及`server/version.json`为准。
- 持久数据：world `4ecf1f7864707144`，NPC `LifeBuilder` / cid `607440080896`；PG库 `voxim_npc_life_20261011`；Hindsight bank `npc-life-607440080896`。
- Hindsight容器 `voxim-npc-life-loop-20261011`，host18908→8888，network `caplib-20261008-net`，容器内服务地址 `http://voxim-npc-life-loop-20261011:8888`。
- 辅助工具：`scripts/npc_life/demo.py`（rpc/observe/upgrade），`service.py`（只管理独立记忆实例），`long_horizon.py`（固定模型与双端驱动）；只读导入Voxim R7 harness，`sys.dont_write_bytecode=True`，不得向主客户端目录写pycache。
- 关注格 `[61,416,-517]` material19。历史A=`1132722130946`，B=`1133355470852`；后续动作必须走正常玩家/NPC入口，不能借旧事件冒充新样本。
- 上阶段1,233,856 + 后端接入9,755 = 累计外部模型token **1,243,611 / 2,000,000**，余 **756,389**。决策60/h与后台Hindsight成本分别记录。代理自身token不等于上述外部模型用量。新会话不是预算重置。

## 新会话任务

1. 先核对接入结果与真实能力缺口，形成一小段可证伪的下一阶段契约。用户要求继续做，不以再次请求开工授权为由停下；不确定的产品偏好可早问，同时推进独立工作。
2. 连续自主生活：跨多轮目标/计划/环境变化继续推进，明确阻塞、失败、完成、放弃与新目的之间的选择依据；验证安静期、离线/重启、实际受拒之后不会遗忘目的、反复同一失败或空转耗费。不要以无限期挂机代替测试，也不要强塞固定动作序列假装自主。
3. 自给自足：从有限合法初始资源出发，查World身体/背包/资源，自己取得需要的材料或食物、消费/恢复并继续生活；优先排查已实跑两次no_path的具体原因。先证实身体需求/资源闭环的现有owner和正常接口，不能创建第二真值或靠直接补余额做成成功。
4. 人格模型：在现有谨慎慢变量上，按用户可感知行为选最小必要维度；查询一手依据，明确稳定性、受经历缓慢改变与短时情绪的不同时间尺度。每个新增维度有行为对照和事件溯源，持久化/重启/时间测试；不盲目照搬心理学模型。
5. 聊天状态：正式玩家↔NPC与NPC↔NPC通道及函数库say已由对话阶段接入；当前证据/缺口以页首和对话阶段为准。旧占位描述仅是首次交接时历史，不能继续作为现在的功能状态。

按最小充分测试先反例后实现；必要的真实模型实验固定样本/预算/失败判据，不重采样掩盖失败。最终继续在本分支提交代码、文档和可复现证据，未获授权不合并或推送。
