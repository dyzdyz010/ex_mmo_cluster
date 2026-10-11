# NPC 连续自主生活、自给自足与人格模型：下一会话

用户于2026-10-11明确要求：“这是阶段性成果，请你先做成单独后端接入npc，然后新开一个会话继续做跨越连续自主生活以及自给自足和人格模型。话说npc的聊天功能做完了没有？”这是续接同一目标的执行授权。先完成独立后端与交接，新会话接管后继续实施和验证，不只给方案。

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

生产入口与CLI例子见 `apps/gate_server/lib/gate_server/npc/README.md`；续验的`long_horizon.py freeze/pairs/live`已改用life入口。Registry配置新反例先RED，LifeRegistry+Registry17项通过，驱动入口10项通过。后端构建/现场接入结果记录在 `.demo/observe/npc-life-backend-20261011/`；交接时应先读该目录最终manifest确认执行版本和当前NPC后端，不猜它在跑什么。

## 运行资产与预算

- 服务端：`voxim-npc-life-demo-20261011`，HTTP27361、QUIC27363（loopback）；正式Dockerfile/release。镜像/加载摘要以本轮后端manifest及`server/version.json`为准。
- 持久数据：world `4ecf1f7864707144`，NPC `LifeBuilder` / cid `607440080896`；PG库 `voxim_npc_life_20261011`；Hindsight bank `npc-life-607440080896`。
- Hindsight容器 `voxim-npc-life-loop-20261011`，host18908→8888，network `caplib-20261008-net`，容器内服务地址 `http://voxim-npc-life-loop-20261011:8888`。
- 辅助工具：`scripts/npc_life/demo.py`（rpc/observe/upgrade），`service.py`（只管理独立记忆实例），`long_horizon.py`（固定模型与双端驱动）；只读导入Voxim R7 harness，`sys.dont_write_bytecode=True`，不得向主客户端目录写pycache。
- 关注格 `[61,416,-517]` material19。历史A=`1132722130946`，B=`1133355470852`；后续动作必须走正常玩家/NPC入口，不能借旧事件冒充新样本。
- 上阶段累计外部模型token **1,233,856 / 2,000,000**；后端现场接入如有新增请求，读本轮manifest更新余量。决策60/h与后台Hindsight成本分别记录。代理自身token不等于上述外部模型用量。新会话不是预算重置。

## 新会话任务

1. 先核对接入结果与真实能力缺口，形成一小段可证伪的下一阶段契约。用户要求继续做，不以再次请求开工授权为由停下；不确定的产品偏好可早问，同时推进独立工作。
2. 连续自主生活：跨多轮目标/计划/环境变化继续推进，明确阻塞、失败、完成、放弃与新目的之间的选择依据；验证安静期、离线/重启、实际受拒之后不会遗忘目的、反复同一失败或空转耗费。不要以无限期挂机代替测试，也不要强塞固定动作序列假装自主。
3. 自给自足：从有限合法初始资源出发，查World身体/背包/资源，自己取得需要的材料或食物、消费/恢复并继续生活；优先排查已实跑两次no_path的具体原因。先证实身体需求/资源闭环的现有owner和正常接口，不能创建第二真值或靠直接补余额做成成功。
4. 人格模型：在现有谨慎慢变量上，按用户可感知行为选最小必要维度；查询一手依据，明确稳定性、受经历缓慢改变与短时情绪的不同时间尺度。每个新增维度有行为对照和事件溯源，持久化/重启/时间测试；不盲目照搬心理学模型。
5. 聊天状态：**未完成**。`Body`的`say`恒拒`chat_unavailable`，能力库不投影say；Runtime/Brain虽有heard接缝，但真实玩家↔NPC对话、回复呈现及对话经历闭环没有验收。用户本次是询问状态，尚未明确要求在本轮把聊天单独做完；若下一阶段需要它，应明确列为独立增量并沿同一正式玩家聊天链路接入，不能用已有占位谎报完成。

按最小充分测试先反例后实现；必要的真实模型实验固定样本/预算/失败判据，不重采样掩盖失败。最终继续在本分支提交代码、文档和可复现证据，未获授权不合并或推送。
