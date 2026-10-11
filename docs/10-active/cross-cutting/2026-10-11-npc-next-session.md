# NPC 连续自主生活、自给自足与人格模型：下一会话

用户于2026-10-11明确要求：“这是阶段性成果，请你先做成单独后端接入npc，然后新开一个会话继续做跨越连续自主生活以及自给自足和人格模型。话说npc的聊天功能做完了没有？”这是续接同一目标的执行授权。先完成独立后端与交接，新会话接管后继续实施和验证，不只给方案。

## 2026-10-11 20:16（UTC+8）优先级与并发交接——当前状态

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
5. 聊天状态：**未完成，且用户现已明确升为首要任务，要求玩家↔NPC与NPC↔NPC同时支持**。旧`Body.say`恒拒`chat_unavailable`、Runtime/Brain只有heard接缝；由原会话负责正式通道，不把已有占位或heard接缝当成完整聊天。本自主生活续接会话按页首分工避开对应文件和运行生命周期。

按最小充分测试先反例后实现；必要的真实模型实验固定样本/预算/失败判据，不重采样掩盖失败。最终继续在本分支提交代码、文档和可复现证据，未获授权不合并或推送。
