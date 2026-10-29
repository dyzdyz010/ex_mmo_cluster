---
status: approved v7（2026-10-26 用户批准；单轮复核已吸收）（2026-10-26：吸收 v6 两轮评审合并清单、用户 2026-10-26 决定与 v7 单轮复核；按两仓 AGENTS.md 设计 / 执行纪律收紧）
parent: [2026-10-24-world-region-paging.md](2026-10-24-world-region-paging.md)（approved v4；本稿取代其“第二阶段：按空间拆裁决权”大纲与 Q6，修订 P6 的所有权部分；Q1 原样保留）
code: ex_mmo_cluster master 3d0668e5（M2a 已提交）；服务端行号以 2026-10-26 工作树为准（同时给表达式）；客户端行号在 Voxim `Source/Voxim/` 下（e3d35494）
reviews: 2026-10-24-world-region-paging/ 下 v1：review-fable-sharding.md、review-astra-sharding.md；v2：review-fable-sharding-cross.md、review-astra-sharding-cross.md；v3：review-fable-sharding-v3.md、review-astra-sharding-v3.md；v4：review-astra-sharding-v4.md；v5：review-astra-sharding-v5.md；v6：review-fable-sharding-v6.md、review-astra-sharding-v6.md、review-fable-sharding-v6-cross.md、review-astra-sharding-v6-cross.md；v7：review-fable-sharding-v7.md、review-astra-sharding-v7.md（单轮复核，吸收见 §0 末）
owner: 分区表、迁移计划（唯一规划者）、中止、保护区登记 = World 控制面（WorldServer）；停写与收尾释放 = 源分片；翻转与导入 = 目标分片（一笔 PG 事务）；分区内体素真值 = 该分区的体素分片；持久化与写者拒旧 = DataService
protocol: S2–S4 协议 41 字段布局与客户端不改（D13 ②，用户已定）；近景按页版本 / 会话观察序号与远景片段一起在 S5 冻结为协议 42；服务端内部顺序合同要改（§6）
---

# 体素权威按空间拆分，与 Scene 分区对齐（第二阶段决策稿）

> **2026-10-27 最新用户语义覆盖**：世界中的活动过程不能因无人、渲染窗口或预算停止演化。下方 approved v7 保留原批准历史；§3.2“非模拟页为墙→零通量”证明、§3.3 窗口/ticket 模拟资格及其 S0/S2/S3/P5 依赖已失效，不能继续照旧施工。D12 当前分区拟态上限仍有效，旧区拟态继续自然演化；D11 ② 天然超限整体冻结与新要求冲突，停止作为合法方案。替代工程合同见 [持续世界决策稿](2026-10-24-world-region-paging/continuous-world-decision.md)（待审，尚非批准新算法）与 [修订执行计划](2026-10-24-world-region-paging/execution-plan.md)。故障路径仍不保证零停顿，不额外承诺服务器停机期间物理实时计算。

## 0. v6 → v7 变更表

编号：M1–M8 = 两份交叉评审的合并清单（`review-astra-sharding-v6-cross.md` §6.1、`review-fable-sharding-v6-cross.md` §6）；U* = 用户 2026-10-26 决定；R1–R6 = 统筹裁定。

| 编号 | v6 问题 | v7 规则 | 位置 |
|---|---|---|---|
| M1 | 收尾 / 翻转守卫比较迁移行里的历史化身，源或目标换化身后永不收口；H 含义、成员闭包、异步效果归属未定；源活着但没收到通知时无人推进 | 迁移行的化身列只记历史；继续执行一律以**分区行当前化身**获权，旧化身被分区行栅栏隔离。H = 停写提交自身的 seq；停写只在 `thermal_run == nil` 边界；成员 = 停写时源算出的当前闭包（须 ⊆ 已跟随集）；H 前发出、H 后返回的异步采样对冻结实体丢弃。持有未收口迁移的一方自行重读迁移行，通知只作加速 | §4.1、§4.2、§4.3 |
| M2 | prepared 后在途切点批次被判僵尸；收尾与前缀混为一个号；done 绑定常规切点拖住再迁 | 写授权分两种：权威写、**迁移历史写回**（内容版本 ≤ H 的成员行，prepared / committed 均可写完）。行内容版本与发布前缀分开。成员 H 时无未发布单元 → 空收尾，翻转后立即释放；否则把下一常规切点提前（共用、限速），不强制紧急切点。再迁等待计入期限 | §4.1、§4.4 |
| M3 | 跟随建立先读 PG 后登记有缝；按页筛选与全流前驱冲突；无背压 | 由 owner 在同一回调里取可恢复快照并登记（沿 `world.ex:1391-1402` 形态），快照与增量同一 FIFO；**每笔都发**（投影可空）保全流前驱；预拷贝按字节 / 日志负载限速，发送带信用窗口，慢消费者超限即断开重建 | §3.6 |
| M4 | 请求转发只看源队列；旧 ctx、结果、冷却、超时、R-only、迟到窗口、转发指针未闭合 | 基于实际链路（每会话一个 Gate 编辑 worker 同步调用，`quic_connection.ex:648-661`）：ctx 在**出队**时取当前路由；结果写回按 cid 找当前 Player；去重 / 冷却会话改按会话（Gate）键并经**交接载荷**随角色迁移；超时 = 结果未知；R ∪ W 任一页触及在途成员即排队；取消迁移专属转发指针，转发只用于迁移队列决定后的一次重新路由（目标 = 该迁移 dst） | §4.5、§4.6 |
| M5 | 按页阻挡漏新物化页、迟到导入复活旧阻挡、prepared 页投票无规则、挂起请求去向不明 | 阻挡改为**分区级**记录（已投 yes 的 pending 认领），不随页迁移；投票覆盖全部自有列内页（含 prepared 页的 H 内容、未驻留但有持久记录的页），不跳过；导入在目标已投 yes 时原子补验；决定应用后挂起请求回到统一路由 | §4.10 |
| M6 | S_want 混入 r_own；冷页竞争无仲裁；期限从“计划”起算、漏排队与再迁 | 恢复三集合：S_sim（Q1）/ 所有权闭包 O / 预取集 P。唯一规划者去重；P 与他区 O ∪ P 相交即触发合并（不做固定一侧仲裁）。d_pre、d_merge 从**需求形成**起算，含规划等待、源忙、连锁 / 再迁、成员变化；d_merge = f(较小岛规模, 限速带宽, 排队)；声明输入包络维度 | §3.3 |
| M7 | §9 混有已定项与工程问题 | §9 重写：记录用户决定原话；只留首测后需用户定的数值与 D11、D12；其余转工程默认 | §9 |
| M8 | 验收预期与 D13 ① 冲突；坏例只有一个；E1 / E2 范围不清 | 按 D13 ② 定预期；每条通过条件各有最小坏例（判定器对合成轨迹自证，不建故障注入框架）；零迁移 / 零样本 / 漏选 / 不覆盖交接判失败；K = 1 按同输入与路线进度对齐；E1 独行玩家不换 Scene，跨 Scene 移交只在 E2 | §8 |
| U-D14 | 同窗口瞬达 | 单分区也取消；GM 直接改位置入口归 Test-only 诊断 | §3.6、§9 |
| U-D13 | ① / ② 待选 | ②：所有权闭包覆盖窗口，协议 41 与客户端不改；近景协议并入 S5；S3 删除边界带与近景协议工作 | §3.6、§7、§8 |
| U-D9 | 足迹触他岛拒绝 | 不拒绝：排队并触发提前合并（迁小岛），翻转后执行 | §3.1、§5 |
| U-D10 | 合并后 ticket 超限 | 保留全部已有过程，上限只限制新发 ticket | §3.3 |
| U-D7 | A″ 待定 | 采纳 A″：认领确认期间矩形内他人编辑延后至决定（有超时），committed 按保护拒绝、aborted 照常执行 | §4.10 |
| R1 | 合并时动作连续性 | 工程默认：正常 T2 不取消施法、不丢命中、不归零冷却 / 去重；在线迁移口径 = 重启等价 + 交接载荷；重启等价只用于故障 | §4.3、§4.6 |
| R2 | 规划者 | 选**唯一规划者**（控制面），规划等待与吞吐计入 d_pre；理由见 §3.3 | §3.3 |
| R3 | 危险修法 | 不采用：剔除切点成员照常发布、只放宽状态守卫、每个 T1 强制全流紧急切点、seal 无条件等全部旧请求回包、prepared 页跳过投票、登记后无保留读 PG | §4.1、§4.4、§4.6、§4.10、§3.6 |
| R4 | Fable 降级项 | 采纳措辞：墙钟实体按经过时间扫过缺口，固定步进内核少走 < 一回合不补算；保留 Astra 事实（热 run 固定 0.5 模拟秒、液体每步配额、人物命中按当前位置采样） | §4.3 |
| R5 | 长期有界性 | S2 / S3 为有限路线 / 时长 / 规模的 Test-only；Global system 与青岚的长期有界门槛在 S4 负载重分与 P5 驻留淘汰之后；覆盖行可随探索增长，常驻页 / 跟随 / 缓存必须可回收 | §8 |
| R6 | 去重前提 | 去重 / 结果 / 冷却接续合同列为 S2 首次转发的前置（S1b 交付） | §4.6、§8 |

**v7 删除的 v6 机制**：边界带跟随页（v6 跟随用途 b）及其“随玩家数有界”论证；跟随者在封口处改跟随（用途 c）；跟随建立时读 PG 再登记；以迁移行历史化身为守卫的“第三种授权”（并入迁移历史写回）；迁移专属转发指针及其退休条件；“请求方改投前清空在途请求”（由 Gate 单 worker 事实取代）；D9 拒绝；按页记、随迁移导出导入的写入阻挡；E2 的产品内翻转延迟注入；合并沿用 v5 TC 顺序取消施法；§9 中 D2、D4、D5、D13、D14 的选项行；v1–v6 逐条变更表（压成下表）。v6 的“中止后向源 `(m, H)` 自续”**保留**（初稿误删，复核恢复，§4.5 第 3 条）。

**v7 单轮复核吸收**（F7 = `review-fable-sharding-v7.md`，A7 = `review-astra-sharding-v7.md`）：

| 编号 | 复核意见 | 处理 | 位置 |
|---|---|---|---|
| K1 | F7-1 通用转发与 §3.1 冲突；A7-3.3 跳数界不成立 | 转发只用于迁移队列决定后一次重新路由到 dst；本地等待队列在 H 并入迁移队列；其余走 §3.1 | §3.1、§4.5 |
| K2 | A7-2.1 待定 Player 拒授权、在途 actor 回调旧 Player、待施放无接管者 | 待定移交时 worker 暂停出队；actor 按 cid + 会话 + 生命代次刷新；待施放世界侧 / Scene 侧各一个接管者 | §4.6 |
| K3 | A7-2.2、F7-2(2) 对话结束针对玩家 `say` | 话题、身份、在途结果随 T2；移交成功不 `End`；S3 | §4.6、§8 |
| K4 | A7-2.3 中止后无续流起点 | 恢复中止分支：从源 H 后继续流含 U_m；过期 / 源重启 → `cursor_expired` | §4.5 |
| K5 | F7-2 静态 Scene 盒使 E1 换 Scene | S2 起 Scene 分工按分区页所有权 | §3.6、§8 |
| K6 | F7-3、A7-M1 写授权、直接 done、owner 行锁、C = H | 按行在事务内取并；中止后按权威写；快路清占用；owner 行 `FOR SHARE`；首个 C ≥ H 发布 | §4.1、§4.2、§4.4 |
| K7 | F7-2(2) 身体登记无需迁移 | 删除推断，`body_detach` fence 保留 | §4.6 |
| K8 | A7-5.2–5.4、M8 文档与验收 | R / W 最短定义；索引改正；代码分类与验收分类分开；S0 只卡 D11 与行键；未知结果等零容忍 | §3.1、§8 |

## 0′ 历史摘要（v1–v6；逐条处理见各轮评审报告与 git 3d0668e5 中的 v5）

| 版本 | 主要变化 |
|---|---|
| v1→v2 | 绑定组与三类闭包；R-merge；owner 行 `FOR SHARE` / `UPDATE` 冲突；流 id 与导入基线；服务端两处 `+ 1` 断言与 45 处 `seq + 1`；保护区 Y 不限 |
| v2→v3 | 迁移占用列与守卫；导入 / 释放提交恰好一次；按段可见版本；续订点 = 导入提交；seq 与 aid 分开、PG 计数行号块；在飞实体为流级数据；分区生命周期与基础槽 |
| v3→v4 | 迁移行 = 决定状态 + 两个独立完成事实；封口序号 H 与冻结区间分开；保护区两阶段决定（物理只在决定后变化）；液体按页授予、Q1 墙 |
| v4→v5 | 占用保留到 done、释放按“冻结于 m”作用域；续订保留下限与 `cursor_expired`；认领参与者固定、投票绑定 pending、按版本幂等 |
| v5→v6 | 用户不接受边缘停顿：领导权转移（跟随预拷贝 → 源停写一笔提交 → 目标一笔事务翻转导入）、基线 = 源已发布页 + 源日志 ≤ H、请求排队转发、所有权前置、提前合并、在飞实体不平移锚点、传送一律加载、事故路径分列（v6 正文未入 git，评审报告按其行号引用） |

## 0″ 结论（v7）

1. **方向不变**：一张页粒度分区表；Scene 与体素分片同表划界、同址、不同进程；普通编辑 World 进程消息数为 0。
2. **硬约束**：绑定组不跨分区；模拟岛的所有权闭包（岛 ∪ 外圈 ∪ 绑定组）属于同一分区。
3. **交接 = 领导权转移**：目标先跟随成员 → 源在合法边界停写（持久 prepared）→ 目标一笔 PG 事务翻转并导入。继续执行以分区行当前化身获权；在途切点按迁移历史写回写完；交接期间请求排队、翻转后转发。
4. **所有权前置与提前合并**由唯一规划者执行，期限从需求形成起算；预取带与他区相交即合并。正常路径无编辑拒绝（含 D9）。
5. **在线动作连续**：正常 T2 携带交接载荷（去重 / 冷却 / 结果会话、待施放、认领角）与 Scene 侧对话话题，不取消施法、不结束对话；在途 actor 按 cid 与会话 / 生命代次重绑定；投射物按 cid 认施法者。
6. **D13 ②**：窗口永在本分区，S2–S4 协议 41 与客户端不改；近景与远景协议在 S5 一起冻结。**传送一律进加载**，单分区同样。
7. **故障是事故路径**（§4.8），显式降级并计数；正常运行指声明输入包络之内（§3.3）。
8. **S0（M2b、P6）不依赖本稿迁移合同**，可与批准并行开工（只有电路分量检查等 D11、粗层段等行键）；分片运行时代码属 Global system，S2–S4 的阶段验收为 Test-only；长期有界与青岚门槛在 S4 + P5 之后（§8）。

## 1. 目标与非目标

用户 2026-10-26：“只有世界级需要协调的内容才到 world 不是么？”“体素真值从长远来看就是要和 scene 的边界对齐吧？”“关于边缘暂停，我不接受。”

**目标**（承接父稿 1–4）：5. 活跃区域互不相接时吞吐随分区数增长，上界是同时存在的岛数；6. 普通编辑（含扣料）World 进程消息数为 0；7. 分片崩溃只影响本分区，恢复 = 本流 O(脏页 + 日志后缀)（刚导入的成员另加源日志 ≤ H）；
**8. 边缘零停顿**：在声明输入包络内且无进程 / 节点 / PG / 控制面故障时，玩家走过分区边界、两群玩家相接触发合并时，相对 K = 1 同输入基线：停步与编辑确认时延不增加（容差首测后由用户定）、拒绝数增量为 0、已开始的动作不被取消；交接不可写窗口目标 < 一回合（S3 实测）。

**非目标**：halo 与跨分区数值耦合；跨分区原子提交（迁移与 D7-A″ 认领各有限定合同）；锁步时钟；单个热点岛的水平扩展（§3.7）；跨机器时钟（多分区只支持同一时间域）；传送无缝；故障下零停顿。

## 2. 现状（事实；服务端路径相对 `apps/`）

- **World**：单 GenServer、全局单调 `seq`（`voxel_region/lib/voxel_region/world.ex:1-8`）；裁决、定时模拟、下发、角色账、目录、每笔同步写日志（`world/edits.ex:198-201` `with :ok <- Log.append_log(...)` 之后才 fanout）。日志条目去掉 `liquid_falls / casts / operation`（`world/log.ex:30-32`），改实例表 / 附件归属时写整表（`:16-27`）。
- **M2a**：切点只在 `state.seq > published` 时开、等 `thermal_run == nil`（`world/page_cut.ex:177-200`），开时冻结整流脏单元并清脏集（`:193-196`），跨回合逐批写（`:237-246`，4 批信用 `@window 4`），常规节拍 `@interval_ms 30_000`（`:24`）；存储原子发布最后批次与前缀（`data_service/lib/data_service/voxel/page_store.ex:62-83`），一批行写同一个传入 `cut_seq`（`:164-175`），渐进删 `seq ≤ prefix` 的日志与被取代旧段（`:147-162`），启动清 `cut_seq > prefix` 残留（`:35-42`）。
- **热 / 液体步进**：热 run 固定 `remaining: 0.5` 模拟秒、跨消息保存（`world/thermal.ex:90-92`）；液体按每步配额（`world/liquids.ex:367-369`）。
- **投射物**：同时只有一个异步采样 Task（`world/projectiles.ex:18-27`），只接纳年龄匹配的结果（`:29-37`）；Scene 侧按墙钟算年龄、按 `source.identity` 与 `life_generation` 找施法者，找不到则 `hits = []`（`world_server/lib/world_server/movement/projectile.ex:26-39`），人物位置取采样时刻当前值；已冻结的人物交付按 cid 重投、Player 返回原收据（`:44-54`）。
- **编辑链路**：每会话一个 Gate 编辑 worker，入队时捕获 `world_ref / player / identity` 等 ctx（`gate_server/lib/gate_server/session/quic_connection.ex:630-644`），worker 逐条同步 `Dispatch.handle`，上一条返回才取下一条（`:648-661`）；工具经 `Player.authorize_tool → World.tool_intent → Player.finish_tool`（`scene_server/lib/scene_server/movement/tool_action.ex:10-20`）；World 调用超时 300 s（`voxel_region/lib/voxel_region/world.ex:139,141` `GenServer.call(..., 300_000)`）。
- **去重 / 冷却**：全在 World 内存——建造 / 附件按 `actor.gate`（`world/production.ex:108`、`world/attachment_ops.ex:18`），工具 / 施法按 `actor.player`（`world/tools.ex:136`、`world/casting.ex:84`），冷却 `next_us` 以 Gate 入口时钟裁决（`damage.ex:326-336`）；进程 DOWN 即删（`world.ex:1632-1639`）。客户端无重发（Fable v6 首轮核实 `VoxelIntentLedger` / `VoxelGateConnection`）。
- **M4a 移交**：seal 先 `cancel_cast` 再 `body_detach`（`scene_server/.../movement/player.ex:1039-1047`）；新 Player 继承 `tool_action` 等（`:205-220`）；Gate 等客户端 Ready 才 `commit_transfer`（`quic_connection.ex:706-729`），期间输入转给待定 Player（`:796-810`）；客户端移交只换身份、预测不停（`Movement/MmoPrediction.cpp:271-292`），但成功后 `DialogueLog.End("scene_changed")`（`Movement/VoxelM1Client.cpp:563`）。
- **窗口**：完整 XYZ tile 盒、中心 tile 外扩 1/4 tile 滞回（`voxel_region/lib/voxel_region/collision_stream.ex:17-35`）；travel 盒 = 窗口盒内收 1/4 tile（`player.ex:2072-2087`）；复活 `revive: :pending` 即使同窗也请求新窗口（`:2101-2105`）；快照与订阅在同一 owner 回调建立（`world.ex:1384-1402`），canonical 订阅者每笔都收到（投影可空，`world/observation.ex:394-409`），这是 `player.ex:1830`、`collision_updates.ex:256` 两处 `+ 1` 断言的前提。
- **传送**：落点在当前窗口内且无待装窗口时下一 tick 瞬达（`player.ex:1431-1441`），测试断言此行为（`scene_server/test/scene_server/movement/beacon_travel_test.exs:136-158`）；GM 直接改位置是独立入口，落点须在窗口内（`player.ex:521-537`）。客户端有连接 / 加载 / 游玩 / 结束状态（`Movement/VoxelM1Client.cpp:25-30`，只看 Prediction 是否启动），信标交互以 `Relocations` 计数变化判“已传送”（`VoxelRender/VoxelBeaconInteraction.cpp:133-150`）。
- **保护区**：x/z 矩形、Y 不限（`voxel_region/lib/voxel_region/protection.ex:2-7`）；占用判据扫驻留内存（`world/claims.ex:84-93`）；`commit_protection` 重建热域、唤醒液体（`:98-110`）；`claim_corners` 仅内存、按 pid 键。
- **客户端单 seq 域**（S5 才动）：自举 / 窗口 / fence / 移交、`AppliedSeq`、意图账与属性比较共用一个会话 seq（`MmoPrediction.cpp:112,280-281`、`VoxelM1Client.cpp:446-453,545,588,620,906`、`VoxelLodWorld.cpp:1603,1634-1639`、`VoxelIntentLedger.cpp:46`、`VoxelDamageState.cpp:15,112,125`；Session codec `session/codec.ex:27,33,39,90`）。
- **实测**（父稿）：M2a（4 份）8 窗口回合 p50 / p99 / 最长 34 / 384 / 521 ms，常规切点中位 30 ms。

## 3. 方案

### 3.1 名词、闭包与执行规则

- **页** = L0 页（64 m 立方）。**分区** = 一组页 + 同址 Scene 与体素分片。**基础槽** → 分区是小表；**覆盖行** = 迁移过的页 / 角色的 owner 行。
- **绑定组**（并查集，必须同区）：一棵预制件树的 home 页 ∪ 全部覆盖页；一个 aid 的 home 页 ∪ 槽页；共享页传递合并。组关系由页内身份记录派生（M2b），不另存第二份真值。
- **读取闭包 R(op)** = ring、射线、祖链、home 查找、保护判定所读的页；**写入闭包 W(op)** = 目标格、home 的 g=2 / g=3、整树覆盖页、aid 槽页、角色行（消费者 `world/tools.ex:593-619` 意图范围、`world/claims.ex:17-21` 整件足迹）。唯一只读例外：信标目的地有效性（`world/beacons.ex:97-100`）与保护区登记的版本化只读投影。
- **执行规则（D9，用户已定）**：R ∪ W 全归本分区 → 本地执行。否则该请求在本分区排队（Gate 调用照常等待），缺的页成为需求交唯一规划者（§3.3）：冷页 → T1 到本分区；属他区闭包或预取集 → 提前合并（迁较小岛）。需求页翻入本分区后在本地执行；若本分区的页反被合并迁走，该请求在 H 并入迁移队列，随之转到 dst（§4.5 第 6 条）。这是触及非自有页请求的唯一处理，不另设按所有权的通用转发。正常路径没有编辑拒绝；代价是这一笔确认多等一次 T1 / 合并。玩家工具与维护入口同一规则。

### 3.2 零通量：条件证明

若 (a) P6 按 Q1 实现（液体只读 `dy ∈ {0,-1}` 与两层侧邻 `world/liquids.ex:344`；辐射遇非模拟页为遮挡；投射物停边界持 ticket；身体 / 拟态接触只在模拟页），(b) 接缝两侧各至少一页非模拟页，(c) 两岛闭包相接前完成合并（§3.3；迟到按 Q1 墙），则分区间物理通量为零，守恒按分区成立。S0 最小反例：Y 向下落、射线穿冷页、边界重开唤醒、拟态 span 跨页、身体接触。

### 3.3 三集合、所有权前置、提前合并与期限

- **S_sim（模拟集，父稿 Q1 原样）**：每个玩家的近景窗口盒（已安装 ∪ 已请求 ∪ 待装）外加一圈页，∪ ticket ∪ 当前导通发现的电路分量（Q1 ⑤）。接纳按页：本页及其外圈都归本分区才推进；液体等计算单元止于已接纳域，未接纳页按 Q1 为墙；唯一整体授予是电路分量。
- **岛**：S_sim 按页相邻连通，并入相交绑定组；两岛闭包相交即为同一岛；迭代到不动点。**所有权闭包 O(岛)** = 岛 ∪ 外圈 ∪ 相交绑定组。约束：O ⊆ 一个分区；外圈页不能被 T1 划走。
- **预取集 P(分区)** = 与本分区各 O 的 XYZ 页距 ≤ d_pre 的页；d_pre ≥ 一 tile，保证下一个可能请求的窗口盒及其 O 已在 P 内。由 Q1，窗口 ⊆ S_sim ⊆ O，故 D13 ② 自然成立：窗口永在本分区。
- **需求**：分区每拍算 O、P，把“P 中不归己的页”及 O / P 摘要的变化上报规划者（派生、不持久）。重复上报是同一需求的观察，不新建迁移；需求消失时规划者撤销对应的 planned（planned 无副作用）。
- **唯一规划者（R2）**：控制面中一个进程规划全部 T1 / T2 / TC，按页 / 绑定组去重——每个 key 至多一个未终结迁移（重启时从 PG 未终结迁移行重建索引）。分类：页不在任何他区 O ∪ P 内 → T1 到需求方；页在他区 O ∪ P 内 → **两岛合并**（较小岛迁往较大岛所在分区，按成员页数，并列按分区 id），不做“固定一侧”仲裁；合并未终结期间，落在两侧 P 交集里的冷页只 T1 给该合并的目标。
  理由：争用判定须同时看到两侧派生、不持久的 P，只有同收两侧上报的进程能作唯一裁决者；“目标自写 planned 行”会把裁决分散到 PG 唯一键、源停写判断与控制面合并规划三处。规划等待与吞吐计入 d_pre 并在 S2 测量；成瓶颈再下放 T1 规划，合同（每 key 唯一未终结迁移、争用即合并）不变。
- **期限（均从需求形成起算）**：
  - D_T1 = 规划排队与规划 + 跟随建立与追平（成员字节 / 限速带宽）+ 源等合法边界（源回合，M2a p99 384 ms）+ 停写事务 + 翻转事务 + 前次迁移 done 等待（若该页刚迁过）+ 成员变化重试。d_pre ≥ v_max · D_T1 + 一 tile。
  - D_T2(A, B) = 规划排队 + 涉及 A 或 B 的未终结合并剩余时间（成员重叠时含其 done 等待）+ 较小岛字节 / 限速带宽 + 追平 + 源边界 + 停写 + 翻转 + 玩家 M4a 移交（含客户端 Ready 往返）。合并触发：O_A 与 O_B 页距 < d_merge(A, B)，d_merge(A, B) ≥ max(2 · d_pre + 一页, 2 · v_max · D_T2(A, B) + 一页)；前一项保证预取带相交前已触发合并。规划者按实测速率逐对估算 D_T2，即 d_merge = f(较小岛规模, 限速带宽, 排队)。不相交的岛对可并行合并；连锁时优先选不与未终结迁移成员重叠的方向。
  - **容量不等式**：长期需求率（页 / s、字节 / s）须小于规划与迁移完成率，否则任何有限 d_pre 都无法使队列有界。
- **输入包络维度**（数值首测后由用户定，§9）：v_max（含 Y 向下落）、每分区与总玩家数、同时合并数与连锁长度、较小岛页数 / 字节 / 绑定组规模、每分区提交率与日志字节率、需求率、规划者吞吐。包络先于测量声明，不以“迟到”反推越界。
- **迟到**（事故尾部）：闭包相接时合并未翻转，或玩家到达时 P 页未归己——接缝按 Q1 为墙；D13 ② 下窗口请求等所有权，表现为慢准备停步。记 `merge_late` / `prefetch_late`（岛、时长、原因）；包络内必须为 0。
- 合并后不立即拆分；拆分在 S4 以 d_split > d_merge 滞回进行。依据：Folia 合并半径不变式与“tick 中不得扩张”、BigWorld 迁移边界约加 10 m 防抖（见“依据”）。
- **ticket 上限（D10，用户已定）**：按分区计；合并后保留全部已有过程（合并分片承担合计负载，计入包络），上限只限制新发 ticket；新过程拿不到 ticket 时按 Q1 冻结规则处理。
- **电路分量检查（D11，已定）**：当前选择以 [§9 D11](#9-用户决定与待定项) 为准。现目录 6 种导电材料无世界生成来源，worldgen v2 “矿脉均后置”，旧目录 id 24 为 CopperOre。

### 3.4 体素分片

分片 = 今日 `VoxelRegion.World` 以本分区页集为作用域运行（推断：改动在装页、路由、写者凭证、表刷新与 §6 顺序合同）。独占本分区页的常驻真值、本流日志 / 前缀 / 切点 / 写回、本分区模拟、编码与观察、在线角色账、本流流级数据。

### 3.5 非页状态的归属

| 状态 | 归属 | 迁移 |
|---|---|---|
| 余额、能量、配方 / 进食账与游标、相变库存、信标调谐 | 角色行（cid） | 随 TC / T2 |
| 去重 / 冷却 / 结果会话、认领第一角 | 在线态，按会话（Gate）键 | 随 T2 / TC 的交接载荷（§4.3）；不入日志 |
| 在飞投射物、拟态（含已锁定 `impact_delivery`） | 流级数据，span 页入岛闭包 | 随 T2：停写时标“冻结于 m”、导入加入、释放移出；不平移锚点（§4.3） |
| 每角色拟态上限 | D12 已定，当前分区计数及传送后行为见 [§9 D12](#9-用户决定与待定项) | 无跨分区归还消息 |
| 热总账 | 每流一本 | 迁移行 `stock_j`；全局审计 = 各流已发布账 + done 迁移进出对消 |
| 页内热源、信标记录 | 页数据（信标 id 由 PG 唯一键保证） | 随页 |
| 目录 / 参数 | 控制面带摘要发布；每分区“已应用摘要”行 | 翻转要求两端摘要相等 |
| 维护回执 | PG 唯一键表，执行分片的提交事务内插入 | 冲突返回原收据 |
| 保护区 | 控制面登记 + 认领两阶段决定（§4.10） | 阻挡为分区级记录，不随页 |
| 交互历史（512 条） | 每流 | 游标按流 |

### 3.6 跟随（预拷贝）、窗口与传送

- **范围**：多分区只支持流送模式；S2–S4 不运行 NPC 与其他无窗口实体（Test-only 范围声明），NPC 的所有权半径在 S4 前定。
- **跟随只用于预拷贝**：迁移 planned 后，目标跟随全部成员，交接时由跟随转为拥有。跟随页不裁决、不模拟、不写回、不持久，重启即丢；唯一升格是导入，其依据是 PG 中的 prepared 行与源日志 ≤ H，跟随状态因与 PG 回放同值而被采用；缺失时从 PG 重装，不当空气或成功。不复用 Replica（只存载荷字节、来源限定唯一 World，`replica.ex:2-5`）。
- **建立（M3）**：目标向源发跟随请求；**源在同一回调里**取成员的可恢复快照（与日志同一投影：去掉 `liquid_falls / casts / operation`）并登记跟随发送进程，快照分块与之后的增量走同一 FIFO（沿 `world.ex:1391-1402` 与 CanonicalFeed 形态）。快照与增量共用精确边界，建立期间无需 PG 历史保留；快照可按页分批建立，每批各有边界 seq。
- **运输**：源**每笔提交都发**（只含成员投影，空投影只带 `(seq, 前驱)`），跟随者按全流前驱校验连续，“消费到 H”字面成立。投影须保留删除、跨页身份与流级实体（S1a 前提：日志条目按页投影，含墓碑；现日志在实例表变化时写整表）。
- **资源**：每个源对全部跟随者的预拷贝按字节 / s 与日志字节 / s 限速；发送进程带信用窗口（与 PageWriter 4 批同形）；积压超过信用即断开该跟随，迁移停在 planned，稍后重建（计入期限）；每分区并发预拷贝数有上限。跟随页总量 ≤ 指向本分区的未终结迁移成员之和，迁移终结即释放；上界由包络中的岛规模与同时合并数决定，不按玩家数宣称。
- **窗口**：D13 ②（用户已定）——窗口永在本分区（§3.3），CollisionStream 只向本分区分片请求，协议 41 与客户端不改。travel 盒与慢准备停步沿用现行，单分区同样存在，验收以 K = 1 为基线（§8）。
- **Scene 分工（S2）**：现行 Player 以配置静态盒判越界并发 M4a 请求（`player.ex:1706-1710` `inside?(position, state.config.authority)`；`movement/authority.ex:1-21`），独行玩家走进分区 2 基础槽就会换 Scene。K = 2 起改为按分区页所有权判定：玩家所在页归本分区即留在本 Scene；页被合并迁走后同一判据触发 M4a，移交只随 T2 发生。动态重分与 K ≥ 3 留 S4。
- **跨分区实体可见**：分属两分区的玩家相距至少 d_merge，不在彼此 AOI（30 / 34 m，`movement/aoi.ex:3`）内（推断，S3 验证）。
- **传送（D14 ①，用户已定）**：信标等正式传送一律进加载，不论远近、是否跨分区、是否同窗。删除 `player.ex:1431-1441` 的窗口内瞬达，一律走 `relocate → stream_window`（`revive: :pending` 已保证同窗也请求新窗口，`:2101-2105`）；`beacon_travel_test.exs:136-158` 按新契约改写。加载期间可做 T1 / 合并、TC 与 Scene 移交、窗口安装；完成事实 = 落点 O 归玩家新分区 ∧ 新窗口的 canonical 快照、碰撞与 fence 已被客户端消费，客户端加载状态（`VoxelM1Client.cpp:25-30`）与信标界面以该完成事实退出，不再以 `Relocations` 计数判定。GM 直接改位置（`player.ex:521-537`）归 Test-only 诊断，不是正式传送。传送不计入零停顿验收，只测加载时长分解。

### 3.7 热点

连成一片的人群由一个分片承载，岛规模受包络约束；超出先做分支 B，再视实测立“岛内 halo 分解”稿（LAMMPS “subdomains are extended with ‘ghost’ atoms up to the communication cutoff distance”，https://docs.lammps.org/Developer_par_part.html ）。

## 4. 所有权交接合同（T1 冷页、T2 岛、TC 角色）

### 4.1 行、锁与写授权

- PG 行：`voxel_partition(id, incarnation, state ∈ {running, stopped}, node)`；`voxel_base_slot(slot, partition)`；`voxel_owner(key, partition, version, migration)`（key = 页或 cid）；`voxel_owner_base(key, stream, seal_seq)`（基线链项 `(流, H)`）；`voxel_migration(...)`、`voxel_migration_member(migration, key)`。
- **物化**：对无覆盖行的页，同一事务 `SELECT … FOR SHARE` 基础槽行，再 `INSERT … VALUES (key, 槽的分区, 0, NULL) ON CONFLICT DO NOTHING`（值确定）。
- 每笔写事务都按规范键序 `FOR SHARE` 执行者的分区行并要求 `incarnation = 我 ∧ state = running`（“我”= 执行进程的**当前**化身），再按种类核验：
  每行在写事务内同时 `FOR SHARE` 其 key 的 owner 行（及所引迁移行），满足下列**任一**条件即通过——按行取并，不按预先标记的种类单选：
  - **权威写**（日志追加、页段 / 角色行 / 流级行写回、前缀发布）：owner 行 `partition = 我` 且 `migration` 为空或其迁移 `dst = 我 ∧ state = committed`。
  - **迁移历史写回**（只限段 / 角色 / 流级行，不含日志追加）：`migration = m`，m 行 `src = 我 ∧ state ∈ {prepared, committed} ∧ released_seq IS NULL`，且该行**内容版本 ≤ H(m)**。它覆盖停写前已开切点（C ≤ H）的剩余批次与此后切点里的成员收尾行（内容版本 = H）；“停写”只封新权威演化，不丢已确认历史。
  - 迁移中止后（占用已清、`partition = src`），在途批次按权威写通过，不判僵尸。
  - **退休本流历史**（GC）：见 §4.4。
- **所有权变更**（占用、翻转、中止、化身 bump、槽改派）：按规范键序 `FOR UPDATE` 再更新。FOR SHARE “blocks other transactions from performing UPDATE, DELETE, SELECT FOR UPDATE or SELECT FOR NO KEY UPDATE on these rows”（PostgreSQL explicit-locking，已核实）。
- **错误分类**：40P01 / 40001 → 整笔重试；只有加锁后核验失败（`:stale_owner`）才说明本进程是僵尸 → 停止。正常运行中源不会撞拒绝：成员自 H 起不进任何新权威写，源后台对成员只写内容版本 ≤ H 的行。成本（1 + k 个行锁读）S2 实测。

### 4.2 迁移状态机

迁移行 `voxel_migration(id, kind, src, dst, src_incarnation, dst_incarnation, state ∈ {planned, prepared, committed, done, aborted}, seal_seq H, frozen_at F0, imported_seq, open_at F1, released_seq, unfrozen_seq, stock_j, fin_empty)`。`src_incarnation` / `dst_incarnation` 只记实际执行停写 / 翻转的化身（历史），**不作继续执行的守卫**。
决定点唯一：prepared 之后目标翻转与控制面中止都先 `FOR UPDATE` 迁移行并要求 `state = 'prepared'`。

| 转移 | 执行者 | 同一 PG 事务内的守卫与动作 |
|---|---|---|
| → planned | 规划者 | 插迁移行与初始成员（W / 岛的闭包，T2 含外圈）；通知目标跟随 |
| planned 撤销 | 规划者 | 需求消失：`WHERE state = 'planned'` 置 aborted、`unfrozen_seq = 0`（停写尚未发生，无副作用；跟随随之退订） |
| planned → prepared（停写） | 源 | 本地前置：当前闭包（源每拍算）⊆ 目标已跟随集且目标报告落后 ≤ 一回合；否则不停写，目标扩展跟随后再试。在 `thermal_run == nil` 的回合边界提交**停写提交**，其 seq 即 H：物化成员 owner 行；`UPDATE voxel_owner SET migration = m WHERE key ∈ 最终成员 AND partition = src AND migration IS NULL`，行数 = 成员数；写最终成员集、H、F0、`stock_j`、`fin_empty`（成员在 H 是否无未发布单元）、`src_incarnation = 我`；流级实体打“冻结于 m”；`WHERE state = 'planned'`。成功后同回合：成员移出源的热 / 液体 / 投射物 / 电路工作集，触及成员的请求入迁移队列，在跟随流与成员窗口订阅者的 FIFO 中发封口与交接载荷（§4.3、§4.5） |
| 代为停写（源 stopped） | 规划者 | 源已停止且满足 §4.7 前置；H = 源流最后一笔；`released_seq = 0`；之后与常规迁移同路径 |
| prepared → committed（翻转 + 导入） | 目标 | 本地前置：已消费跟随流至 H 与交接载荷；跟随丢失或目标刚重启 → 经基线链 `(src, H)` 从 PG 重装（无交接载荷，按事故计 `handover_payload_lost`）。事务：`FOR UPDATE` 迁移行要求 prepared；两端已应用目录摘要相等；成员 `partition = src AND migration = m` 行数 = 成员数；翻转 `partition = dst, version + 1`（占用保持到 done）；写基线链；导入提交 I_m；`dst_incarnation = 我, imported_seq, open_at, state = CASE WHEN released_seq = 0 THEN 'done' ELSE 'committed' END`，为 done 时同事务清 `migration = m` 的占用。不校验源存活（prepared 即“源自 H 起写不进成员”的持久事实）。提交后同回合开放成员，通知源 |
| committed → done（释放） | 源 | 条件：`fin_empty`，或源首个 C ≥ H 的发布已完成（它完整承接成员 H 时内容，§4.4）。释放提交 R_m：删除“冻结于 m”的内存表示与迁出角色的在线会话；`released_seq = R_m, state = 'done'`，清 `migration = m` 的占用；`WHERE state = 'committed' AND released_seq IS NULL` |
| planned / prepared → aborted | 规划者 | 事故路径：目标在 T_abort 内未运行或报告不可导入。只清本迁移占用 |
| aborted：解冻 | 源（曾 prepared） | 解冻提交 U_m，`unfrozen_seq = U_m`；排队请求在源本地按序执行；已收封口的订阅者按 §4.5 第 3 条从 H 后继续流 |
| 源化身 bump | 规划者 | 该源 planned 全部 aborted（`unfrozen_seq = 0`）；prepared / committed 不中止：新化身从 PG 把占用为 m 的成员作冻结装入，以当前化身完成收尾、释放或解冻 |
| 目标化身 bump | 规划者 | 不中止；新化身经基线链重装后以当前化身翻转并写 `dst_incarnation`；T_abort 内未运行才中止 |

- **再迁门槛**：占用到 done 才清，再迁要求 `migration IS NULL`；再迁等待计入 §3.3 期限。
- **自维护收敛**：任一分区对自己作为 src 或 dst 的未终结迁移，持有排队请求时每回合、否则每个常规切点节拍重读迁移行；翻转通知只是加速。恢复扫描：源 → prepared（保持冻结）、committed 未释放（收尾释放）、aborted 未解冻（解冻）；目标 → prepared（重装翻转）；规划者 → planned 超时撤销、prepared 超 T_abort 中止。
- **不可写窗口 [F0, F1]** = 停写事务 + 封口到达与目标消费剩余（≤ 一回合）+ 翻转事务 + 至目标下一回合；不含切点与控制面往返。M4a `transfer_cut → transfer_resumed` 另记。目标 < 一回合，S3 实测。
- 与 Raft 的差异：Ongaro §3.10 先停新请求再补齐日志；本稿停写前已跟随，停写后只补 ≤ 一回合；转移期间请求排队转发（Raft 原文未规定，raft-rs 丢弃提案）。

### 4.3 提交、交接载荷与在途过程

- **H**：停写提交自身的 seq。成员在 H 的状态 = 源流 seq < H 的全部提交之后的状态；停写提交只带冻结标记、`stock_j` 与 `fin_empty`。停写只在 `thermal_run == nil` 边界（与切点开启同一判据），H 前在跑的热 run 必已提交。
- **导入提交 I_m**：取号见 §6 号块；成员状态取自跟随或基线链重装（同值）；加入流级实体；成员页全部标脏（供链截断）。
- **交接载荷（R1，在线迁移口径 = 重启等价 + 交接载荷）**：源在 H 之后紧接着经跟随 FIFO 发送日志之外的在线态——迁出角色的建造 / 附件 / 工具 / 施法会话（去重水位、缓存结果、冷却 `next_us`）、认领第一角、世界侧待施放与已接纳动作结果。目标在导入时装入。实时落体帧与操作反馈是纯显示，不携带。重启等价只用于故障重建（载荷丢失时）。
- **在途过程**：不平移时间锚点。墙钟实体（投射物）由目标首拍按经过时间扫过 [age_H, now] 的缺口（`flight_segments`）；人物命中按采样时刻当前位置判定（`world_server/.../projectile.ex:26-39`），与 K = 1 下一次慢采样回合同口径（推断，E2 按命中结果对 K = 1 验证）。固定步进内核（热 run 0.5 模拟秒、液体每步配额）在 [F0, F1] 少走 < 一回合、不补算，与 Q1 “不补算”同口径，E2 以进度计数对 K = 1 比较。要求源与目标同一时间域。
- **异步结果归属**：H 前发出、H 后返回的投射物采样结果，对“冻结于 m”的实体一律丢弃，由目标首拍重采；已发出的人物交付按 cid 重投得原收据（`projectile.ex:44-54`），不重复结算。
- **施法者身份**：投射物按 `(cid, life_generation)` 经当前 owner 认施法者，候选人物取投射物所属分区的 Scene，不再比较会话 identity（现行 M4a 换会话后 `hits = []`，同时修正）。
- **解冻提交 U_m**（事故路径）：时间锚点后移 `解冻时刻 − F0`，按 Q1 不补算；随 U_m 持久、只做一次。
- **恰好一次**：每笔提交与其状态转移同库同事务；重复请求读迁移行后返回同一 seq。

### 4.4 持久化：基线链、收尾、GC、再迁

- 流 = 一个分区的日志流；日志、页段、角色行、流级行带流 id；前缀表主键 `(cv, 流 id)`；残留清理只删本流 `cut_seq > prefix(本流)`（现 `page_store.ex:35-42` 按 cv，须改）。
- **行内容版本与发布前缀分开**：每行自带内容版本（表已有逐行 `cut_seq`，改写入接口 `page_store.ex:164-175` 使同批行可带不同版本，不改表结构）；发布前缀是切点号 C。
- **基线链**：链项 `(Q, H_Q)`。成员页 p 的可见版本按段取 max{ 本流 `cut ≤ prefix` 的行 ∪ 链中每项下 Q 流 `cut ≤ min(H_Q, prefix(Q))` 的行 }，不足 H_Q 时叠加 Q 流日志中该页 seq ∈ (版本, H_Q] 的条目。恢复链 = 源已发布页 + 源日志 ≤ H（仅成员）+ 目标日志；跨迁移同页 seq 单调（§6 号块）。
- **收尾**：停写前已开的切点（C < H）照常写完并发布（迁移历史写回）；首个 C ≥ H 的切点（停写后无新提交时即 C = H）把成员仍未发布的单元以内容版本 H 写入，已被旧切点完整承接的干净单元不重写。因开切点即冻结全部脏单元（`page_cut.ex:193-196`）、全批确认后才发布（`:244-246`），首个 C ≥ H 的发布完整承接成员 H 时内容，无需剔除或另建切点。`fin_empty` 时（成员在 H 无脏单元、不在未发布切点中——冷页 T1 的常态）翻转后立即释放。非空收尾时，源把下一常规切点的到期提前到 now + t_fin（多迁移共用一次，切点仍走常规冻结与信用限速；t_fin S3 定）。不采用：剔除切点成员照常发布、只放宽状态守卫、每个 T1 强制紧急切点（R3）。
- **日志保留**：渐进删日志只删 `seq ≤ 前缀`；前缀越过 H 时成员 H 版本已在页表，故 ≤ H 日志不会早删。源在收尾前崩溃：前缀 < H，日志未删，`clear_unpublished` 清掉的标 H 残留由新化身按日志重做——这是预期恢复路径。
- **链截断**：成员页在本流写回并发布后删该页链项（随常规写回摊开）；再导出时未截断的链原样传递。
- **I4**：源对某页无任何可见版本时基线记 `never_edited`。
- **GC**（退休本流历史）：删本流 ≤ 前缀的日志、被取代旧段、已迁出页且不被任何链引用的段，同一事务 `FOR SHARE` 相应 owner 行并检查链引用，与翻转写链互斥；已停止 / 退役分区的流同样受此约束，被引用的段与 ≤ H_Q 日志保留到全部引用截断。
- **一致读取**：分片先登记新化身再在一个 REPEATABLE READ 事务里读 owner 行、基线链、链所引他流区间、本流行、前缀与后缀。多分区组合根只支持 PG 后端。

### 4.5 订阅屏障与请求路由

1. **封口**：停写回合，源对成员页的窗口订阅者经其发送进程发 `{:handover, m, H}`（Erlang 同源保序，已核实）。CollisionStream 把它作为普通事件进 FIFO；Player 消费到它才停止接受源对成员的 delta、等目标首笔。
2. **迟到窗口**：H 之后到达、触及成员的窗口请求，源回 H 快照并在同一 FIFO 紧接 `{:handover, m, H}`，新订阅者与原订阅者走同一续订路径。
3. **续订**：订阅 owner 自己观察迁移决定（§4.2 自维护，通知只加速），按结果选一个出口：committed → `subscribe_handover(m, H)` 从 I_m 起按序补发目标保留事务，不以目标当前 seq 作续订点；**aborted → 向源 `subscribe_handover(m, H)`，从 H 的后继起按源流前驱连续补发（含 U_m 及其后），恢复接纳源对成员的 delta，不等不存在的 I_m**。保留下限：源钉 H、目标钉 I_m，约束内存退休（`world/page_cut.ex:259`）与日志删除，只在内存、随超时放开；放开后到达或源已重启 → `cursor_expired` → 显式整窗重取并计数（事故）。
4. **前驱**：每笔提交记本流前驱 seq；Player 按流校验，封口后对成员期望首笔 = I_m（中止时为源流 H 的后继）。
5. **排队**：源在 [H, 决定] 收到 R ∪ W 任一页触及成员的请求（编辑、维护、意图、交互）按到达顺序进该迁移队列，不回复、不拒绝；本地等待队列（§3.1 需求、§4.10 认领挂起）中触及成员的请求在 H 并入该队列；目标在翻转前收到触及“dst = 我 ∧ prepared”成员的请求同样排队至翻转。触及多个未终结迁移的请求排在最早者的队列。
6. **转发（只此一处）**：决定后迁移队列按序重新路由一次——committed → 转发给该迁移行的 dst，携原调用方 `from`，dst 按常规接纳（含其认领阻挡）执行并 `GenServer.reply/2` 直接回包；aborted → 源在 U_m 后本地执行。dst 精确已知，无需按所有权查找或转发指针。其余任何触及非自有页的请求一律按 §3.1（排队 + 需求）。依据：BigWorld “Each ghost knows its real cell, so that it can forward messages to its real version to be processed.”（第三方镜像）。
7. **顺序**：每会话至多一个在途编辑请求（Gate 单 worker 同步调用，§2），故按序转发保持同一请求方顺序；施法经 Player 的特殊入口按动作生命周期随 T2 携带（§4.6）。跨请求方的顺序与 K = 1 同为到达序。
8. **恰好一次与结果未知**：队列只重新路由一次；PG 提交原子；去重会话随交接载荷迁移，同 `client_intent_seq` 重投由当前 owner 去重（建造 / 附件返回原结果，工具返回 `replayed_attack`，现行语义）。调用超时（300 s）只表示结果未知：Gate 回“结果未知”原因码，服务端不重做（OTP 24 起迟到回复不可达，Astra 引原文）。`:stale_owner` 是 PG 写时底线，与转发互不替代。
9. 多分区阶段不运行 Replica、不支持非流送 Scene。

### 4.6 角色、Scene 移交与在线动作连续（R1、R6）

角色接纳接缝（K2）有三处，各一个 owner；保留 Gate 单序列，不引入 seal 等全部回包：
- **尚未接纳的请求（Gate，S1b，Global system）**：编辑 worker 在**出队**时取当前 ctx，不再用入队时捕获的 ctx（`quic_connection.ex:630-644`）。Gate 有待定移交时 worker 暂停出队，到 `commit_transfer` 成功（取新 Player）或移交中止（取原 Player）后再出队——旧 Player sealed、待定 Player `transfer: :prepared` 时都拒绝授权（`player.ex:350-403` 要求 `transfer: nil`，导入态见 `:186-204`）。这只是 worker 等 Ready 往返；Gate 主进程照常处理 Ready 与输入，移交不等编辑回包，无环。`Say` 同走此序列，不再在待定移交时回 `transfer_in_progress`（`quic_connection.ex:768-786`）。
- **已接纳的在途 actor（World，S1b）**：Player 授权后、World 裁决前跨过 H 的请求，执行时 `current_actor` 不再回调 `actor.player`（`world/tools.ex:578-584`），改按 cid 经当前 owner 刷新，并要求同一会话（Gate）与 `life_generation`；保留原 `received_us` / `clock_node` 与 `action_key`；死亡、施法、会话校验照旧由当前 Player 做。结果回原 `from`（Gate worker），`finish_tool` 按 cid 交当前 Player（`tool_action` 已随 `transfer_cut` 继承，`player.ex:205-220`）。World 侧会话按会话（Gate）键，进程退出或角色迁出时退休。K = 1 下即修正 M4a 换 Player 后冷却 / 去重归零。
- **待施放（S3）**：世界侧 `pending_casts`（含 `from`，`world/casting.ex:106-118`）随交接载荷，唯一接管者是 dst World：导入时对新 Player 建 monitor，释放授权按 cid + 会话 + 生命代次匹配（现按 pid，`world.ex:1570-1582`）；源在 H 移除该记录与 monitor，旧 Player 退出不影响。Scene 侧前摇定时器（`player.ex:670-676` `release_cast`）随 `transfer_cut` 携带绝对到期时刻，唯一接管者是新 Player，按剩余时长重建。
- **随 T2 迁移的玩家**（合并）：角色行是 T2 成员；分区页所有权变化触发 M4a（§3.6）；seal **只去掉 `cancel_cast`**，`body_detach` fence 保留（即时回复，`world.ex:1521-1529`）。身体登记不迁移：新 Player 的 `body_tick` 在 dst 重新登记（`player.ex:1007-1018`），无心跳 2.5 s 自动摘除（`thermal.ex:82-85`）。
- **对话（S3，Global system）**：`DialogueLog` 是玩家 `say` 的 M1 投影（`Dialogue/VoximDialogueLog.h:4`），与 NPC 无关。现行移交时旧 Scene `Dialogue.leave` 删除旧身份的听众资格与在途请求（`scene_server/lib/scene_server/movement/scene.ex:450-462`、`scene_server/lib/scene_server/dialogue.ex:43-53`），目标找不到话题即 `conversation_expired`（`dialogue.ex:240-248`），客户端移交成功即把待确认发言标“已离开场景，发送结果未知”（`VoxelM1Client.cpp:563`、`VoximDialogueLog.cpp:20-23`）。正常 T2：旧 Scene 把参与者随迁的话题（听众集合、轮次、在途请求）随移交交给新 Scene，身份换为新 identity，在途发言的结果由新 Scene 回给同一会话；移交成功客户端不再 `End`，待确认发言继续等服务器结果。参与者未随迁的话题由旧 Scene 对在途请求显式回原因码。传送（TC）同一规则：目标没有该话题即显式 `conversation_expired`，客户端不自行猜测。协议 41 布局不变。
- **单独迁角色（TC）**：只在传送加载、换分区登录、退役中出现，不在零停顿目标内：Scene seal → 取消施法、`body_detach` → `BodyStore.save` → TC（领导权转移）→ `commit_transfer` → `BodyStore.claim`。TC committed 前失败 → 角色留源、移交中止；之后失败 → 会话关闭，重连时在角色行当前 owner 分区登录。换分区登录：源运行中正常迁移；已停止 → 代为停写；故障中 → 待故障转移，期间登录显式失败（D2，工程默认）。

### 4.7 分区生命周期

- **启动**：bump 化身、置 running；分片先登记再读快照。
- **停止前置条件**：无已接纳模拟页、流级瞬态为空或已迁出、无未决迁移、无跟随。
- **停止 / 退役**：停止接纳 → 发布全部 → 置 stopped 并 bump。退役 = 迁走全部覆盖行（含离线 cid）+ 改派基础槽；其流的被引用历史按 §4.4 保留。
- **故障转移**：bump（只撤销其 planned）→ 新节点启动。

### 4.8 故障（事故路径）

| 故障 | 行为 |
|---|---|
| 分片崩溃 | 本节点重启按 §4.4 恢复；期间该分区意图显式失败、Scene 停 Tick；跟随它的迁移停在 planned 待重建 |
| 节点崩溃 / 僵尸 | 故障转移；僵尸下一笔写被拒并自停，此前可能仍向本节点读者供旧快照；会话随之关闭 |
| 控制面停机 | 本分区内编辑与模拟照常；prepared 迁移照常翻转；新规划、登录、移交、目录发布、认领显式失败；前置与合并停止 → 慢准备停步，计 `prefetch_late` / `merge_late` |
| PG 不可用 / 死锁 | 提交失败、意图显式失败；40P01 / 40001 整笔重试 |
| 源在 prepared 后崩溃 | 目标照常翻转（必要时重装，交接载荷丢失按重启语义）；排队请求随源丢失 → 调用方结果未知 |
| 目标翻转前崩溃 | 新化身重装后翻转；T_abort 内未运行则中止、源解冻（锚点后移，可见暂停） |
| 超出包络 | `prefetch_late` / `merge_late`，表现同控制面停机 |

### 4.9 I1–I5

I1 单写者 ← §4.1 冲突边界（源自 H 起只写内容 ≤ H 的历史行）+ §4.2 守卫（当前化身栅栏）；转发不改变 I1。I2 交接点合法且持久 ← 停写在 `thermal_run == nil` 边界、日志先于广播、基线只引已持久 ≤ H 内容。I3 可见版本正确 ← §4.4 可见规则 + 同页单调 + 行内容版本。I4 ← `never_edited`。I5 ← R / W 准备核验 + 父稿 P4。通过 §8 判定器后才可在已覆盖失败模型内声称成立。

### 4.10 保护区认领（D7-A″，用户已定）

唯一的跨分区两阶段决定。用户：认领确认期间矩形内他人编辑延后到决定后（有超时），committed 按保护拒绝，aborted 照常执行。
- **登记**（控制面，PG）：`protection_region(id, rect, holder, state ∈ {pending, committed, aborted, released}, version)`、`protection_participant(region, partition)`、`protection_vote(region, partition, vote)`。
- **发起**：检查与 pending / committed 区域不重叠、持有数量；参与者 = 此刻全部 running 分区；有既未运行又未退役的分区 → 直接 aborted；写 pending。
- **拓扑互斥**：pending 期间只排队分区起停 / 退役与列内基础槽改派；迁移照常。
- **阻挡 = 分区级记录（M5）**：投 yes 的分区在本流全局行记 `(认领 id, rect, version)`。只要记录存在，本分区所拥有的、落在 rect 内的任何页——含此后首次物化的页与导入的页——上的非持有者写请求都排队至决定。阻挡不随页迁移，故决定后到达的导入不会带回旧阻挡。
- **投票**：参与者在合法提交边界一笔本流提交，事务内 `FOR SHARE` 认领行要求 pending；复核本分区拥有的全部列内页：驻留页按 `world/claims.ex:84-93`；未驻留但有持久记录（本流或链中段行）的页装入后复核；`never_edited` 页为无占用；**prepared 成员按其 H 内容复核**（冻结、源与他人都写不进，翻转后归目标的写受目标自己的投票或导入补验约束）。不跳过任何页（R3）。无他人占用 → 记阻挡、投 yes；有 → no。认领已非 pending 则整笔回滚。
- **导入补验**：目标已对某 pending 认领投 yes 且导入成员落在其 rect 内时，翻转事务内 `FOR SHARE` 认领行（要求 pending）复核这些页，有他人占用则把本分区票改为 no；目标未投票则其后投票覆盖；认领已决定则无需处理（保护投影按 rect 生效）。
- **决定**：控制面 `FOR UPDATE` 认领行——全部 yes → committed；任一 no 或超时 T_claim → aborted；version + 1。
- **生效（按版本幂等）**：各分区记“已应用保护版本”，在提交边界：committed → 装入保护投影（`world/claims.ex:98-110` 全部效果）、删阻挡记录，挂起请求按保护拒绝；aborted → 删阻挡记录，挂起请求按序在本分区重新接纳（其页若在挂起期间迁走，请求已在 H 并入迁移队列，§4.5 第 5 条）。物理只在决定后变化，不补偿撤销。
- **恢复 / 释放**：分区重启从本流恢复阻挡记录与已应用版本，补做已决定未应用的；控制面重启把 pending 推到决定。释放：控制面置 released、version + 1，各分区按版本移除投影。
- 正常可见代价：认领回复与矩形内他人编辑最多延后 T_claim（数值首测后由用户定，须小于编辑调用超时）。

## 5. 必答难题索引

a 跨分片事务：扣料本地；存量整件因绑定组本地；足迹缺页先 T1 或合并后执行（D9）；电路分量整体授予；信标目的地只读检查。b 边界 §3.2–3.3。c 顺序 §4.5、§6。d 交接 §3.3、§3.6、§4。e 持久化 §4.4；粗层归属随 L0 页（`world/canopy.ex:30-31`），行键 `(level, L0 页)` 须在 M2b 粗层段落地前定。f 号源 §6。g 拆合 = 起停分区 + 迁移。h §4.8。

## 6. 序号与身份

- **提交号 seq**：一笔事务一个。45 处 `seq + 1` 中表示“本笔将取得的提交号”的改读 `state.next_seq`；游标下界（如 `log_projection.ex:39`）不改；逐处分类在 S1b 实施时做。
- **附件号 aid**：本流独立号块，按需逐个取，不再 `max(serial, seq) + 1`。
- **前驱链**：日志行记本流前驱 seq；`collision_updates.ex:256`、`player.ex:1830` 改校验前驱。积压：`page_cut.ex:118` 改为本流已提交未发布事务数。
- **K = 1 等价口径**：seq 逐项相等；aid 只验唯一、引用一致、回执与提交一致（客户端只按相等比较 aid，`VoxelDamageState.cpp:176-177`）。
- **号块（K ≥ 2）**：每类一行 `voxel_number(cv, kind, next)`，`UPDATE … SET next = next + n … RETURNING next - n`，提交后才用（READ COMMITTED 下同行更新串行，已核实）；不用 sequence。承诺全局唯一、流内单调、同页 / 同角色跨迁移单调，不承诺跨流实时有序。导入取号：`max(state.seq, H, 成员最后 seq) + 1` 在已领块内则用之，否则领新块（Lamport IR2(b)）。首次启用起点 > 现有全部已发号。

## 7. 近景与远景协议（S5）

- S2–S4：近景窗口永在本分区（D13 ②），协议 41 不改。远景 overlay 订阅只连本分区流；他分区远景区域取 PG 最新已发布版本，完整、真实、**不保证有限陈旧**，只在重取时刷新；验收不覆盖远景，不进青岚。
- **S5 协议 42 一次冻结**（同一版本身份与字节样本）：远景片段 `(level, L0 页)` 与片段版本、完整 / 增量 / 删除、初取与订阅屏障、缓存失效、聚合 owner；近景事务身份 / 内容按页版本与会话观察序号分离，覆盖属性完整快照与无记录语义、窗口 / 碰撞 / fence / Ready / Transfer 与各来源前缀的对应、`TransactionCores` 的取删、意图账“无新事务 / 已应用”的退休边界；近 / 远景不共享可写全局水位。

## 8. 交付顺序、判定器与测量

| 步 | 内容 | 验证 | 分类（运行时代码 / 阶段验收） |
|---|---|---|---|
| S0 | M2a 收尾；M2b（按需装页、身份定位、读取闭包、粗层逻辑片段）；P6 + Q1 边界语义 + ticket + 唤醒 + 活动索引恢复；D11 | 父稿“模拟边界 / 预算冻结与重启 / 边界唤醒 / 冷页视线” + §3.2 反例；P6 后 8 窗口基准不退化 | Global system。**不依赖本稿迁移合同，可立即开工**；只有两处前置：电路分量检查等 D11，粗层段落地等行键 `(level, L0 页)`（§5 e） |
| S1a | 全局行拆为角色行 + 真全局行；投射物 / 拟态为流级数据；热总账按流；信标页数据；绑定组与岛的计算（只算不分区）；日志条目按页投影（含删除、跨页身份）；D12 | 现有测试 + m2a 判定器；重启等价；按页投影回放 = 整笔回放（含同笔改整表与页内容） | Global system |
| S1b | `next_seq`、aid 号块、前驱链、积压计数；行内容版本写入接口；Gate ctx 出队取当前路由且待定移交时暂停出队、`Say` 同序列；在途 actor 按 cid + 会话 + 生命代次刷新、结果按 cid 写回、World 会话按会话键；投射物按 cid 认施法者；D14 ①（取消瞬达、加载完成事实、客户端加载状态接线，K = 1 即生效） | §6 等价口径；跨块反例；K = 1 下 M4a 移交期间编辑与 `say` 不被拒、移交后冷却 / 去重延续、投射物仍命中；信标同窗 / 异窗都进加载（真实客户端） | Global system（随后可进青岚） |
| S2 | 两个静态分区：分区表 / 基础槽 / owner 行与锁、每流持久化、基线链、迁移历史写回与收尾、号块、按表路由；Scene 分工按分区页所有权判定（§3.6）；跟随预拷贝；唯一规划者；T1 与所有权前置；请求排队与转发、交接载荷；TC 与换分区登录；传送加载跨分区 | 隔离库、两 BEAM 节点、同一时间域；先接通 E1 最短链路（真实双客户端），再补测量；分片崩溃隔离；传送加载 | 代码 Global system / 验收 Test-only（K = 2、有限路线） |
| S3 | T2 与提前合并、玩家 M4a 不取消动作、待施放接管、对话话题随迁与客户端不 `End`、在飞实体随迁、D7-A″ | 真实双客户端 E2、E3（含跨交接 `say`）；有界多岛合并场景 | 代码 Global system / 验收 Test-only |
| S4 | 动态拆合（d_split 滞回）、负载重分、退役、NPC 所有权半径、K ≥ 3 Scene 分工 | 分散 / 聚集基准、长时运行的覆盖行 / 常驻字节 / 负载曲线 | 代码 Global system / 验收 Test-only |
| S5 | 协议 42（近景 + 远景，§7） | golden 与 Voxim codec 同一字节样本；双客户端对照 | Global system |
| P5 | M3 其余：驻留淘汰与统一缓存预算、D1、角色账退休 | 父稿 | Global system |
| 青岚 | 多分区接入分发 | 前提：S4、P5、S5 完成且长期有界验收通过；版本冻结与打包冒烟按 AGENTS 分发规则 | Distribution-only |

- **决策门槛**：S0 前定 D11；S1a 前定 D12；S3 首测后定 D3 包络与 d_merge、不可写窗口阈值、T_claim、E 判据容差。
- **闭环优先**：每步先在真实环境接通最短链路再补测量；评审、归档、报告润色不阻塞集成。只为本步触及的契约写判定器；判定器自证用最小合成轨迹，不建通用故障注入框架（Voxim `Docs/Testing.md` §1、§5）。
- **有界性（R5）**：S2 / S3 是有限路线 / 时长 / 规模的 Test-only，报告覆盖行数、每分区常驻页与字节、跟随页数、活跃岛负载与再激活曲线。覆盖行随探索增长是持久元数据，可接受；常驻页、跟随、缓存必须可回收（跟随随迁移终结释放；常驻页待 P5）。Global system 与青岚的长期有界门槛不早于 S4 负载重分与 P5 驻留淘汰。

**边缘零停顿验收**（Test-only；真实双客户端，经正常输入与准星交互；区分已实现 / 已实跑 / 已验收）：
- **基线**：同一构建、同一输入脚本在 K = 1 下运行；按输入序号与路线进度对齐、取共同采样窗口，比较时长而不只是事件数；窗口安装本身的慢准备在两边都计入，比较的是增量。
- **E1 走过边界（S2）**：A 在分区 1 持续编辑；B 以 v_max 从分区 1 冷地走入分区 2 基础槽冷地并在两侧编辑，往返、沿接缝斜走、跳跃与下落。独行玩家的所有权随人前移，Scene 分工按所有权（§3.6），故**不换 Scene**，只验证 T1 前置。
- **E2 相向合并（S3）**：两客户端分处两分区相向而行至触发合并、相遇、并排挖放；双方带在飞投射物、施法前摇与认领第一角跨过交接；跨 Scene 移交只在此出现。另跑三群串行接近的有界场景验证连锁与再迁等待。
- **E3 交接中编辑（S3）**：E2 的合并期间被迁一侧每拍一笔编辑（含同格先挖后放），须有请求落在 [H, 决定]。
- **记录**：停步区间与原因（服务端 travel 约束、客户端 `UnsupportedRange` / `CanPredict`）；权威 tick 推进与另一客户端可见位置；编辑确认时延；拒绝数按原因码；不可写窗口分布（T1 / T2 分列）；转发数与增量时延；`merge_late`、`prefetch_late`、`handover_payload_lost`、`cursor_expired`、会话终止原因；施法取消、工具中断、认领角丢失；投射物命中结果；液体 / 热进度计数；预拷贝字节、时长与峰值速率。

| 通过条件 | 最小坏例（判定器必须判失败的合成轨迹） |
|---|---|
| 停步时长相对基线增量在容差内 | 边界附近多一段 1 s 停步；或停步次数相同但一次从 10 ms 变 1 s |
| 权威推进不中断 | 客户端预测在走、服务端权威 tick 停 2 回合 |
| 拒绝数增量 0（含 `migrating`、`stale_owner` 与足迹类） | 一笔 `stale_owner` |
| 每个请求恰好一个结果，且与双端观察到的权威事务一致；同一请求方顺序保持 | 同一请求两次提交；先挖后放执行成先放后挖；回包成功但另一端无对应事务 |
| 正常场景零容忍：“结果未知”、会话终止、`cursor_expired`、迁移导致的工具中断均为 0 | 交接后出现一次结果未知或一次 `cursor_expired` |
| 确认时延增量在容差内 | 一笔在队列中等 2 s |
| 已开始的动作与对话零中断 | 合并时出现一次 `cast_cancelled`、认领第一角丢失、`say` 结果为 `scene_changed` / `conversation_expired` |
| 投射物命中结果与基线一致 | 交接后施法者失配、命中为空 |
| 物理进度与基线差 < 一回合 | 成员液体 / 热进度停 2 回合 |
| `merge_late = prefetch_late = handover_payload_lost = 0` | 出现一次 |
| 不可写窗口 p99 < 一回合（阈值首测后由用户定，未定前只出报告） | — |

零迁移、零样本、缺一端角色或指标、采样窗口不覆盖交接前 / 中 / 后 → 判失败；E3 无请求落在 [H, 决定] → 判“未覆盖”，不算通过。

**判定器**（Automation，Test-only，各在触及它的交付步加入，只验本步契约）：岛闭合（S1a / S2：授资格、发 ticket、导入后 O ⊆ 本分区）；双写（S2：审计表记每笔接纳的流、化身与各 key owner version，断言与已提交所有权区间及当前化身一致；反例 = 换化身后旧化身写、翻转后源写成员）；订阅连续（S2：按流核对前驱与封口 / 首笔；反例 = 空投影漏发、迟到窗口未收封口、中止后订阅者仍等 I_m）；恰好一次（S2：重复翻转 / 释放 / 解冻后热账、余额、锚点只变一次）；基线链（S2：反例 = 源收尾前崩溃、目标重启丢跟随，断言重装成员与跟随状态逐页相等）；在途切点（S2：反例 = C < H 批次在 prepared 后写入、迁移中止后写入，断言不误判僵尸且前缀推进后成员可见）；角色接缝（S1b / S3：反例 = 待定 Player 期间出队一条编辑、旧 Player 授权后跨 H 的请求、前摇中合并，断言各恰好完成一次且冷却不归零）；D7 入口（S3：反例 = 投票后首次物化页被他人建造、决定后迟到导入、prepared 页投票、挂起请求所在页已迁走）。

**测量**（阈值首测后由用户定）：扩展效率；热点不退化；World 热路径消息数；需求率、规划等待与吞吐、计划→翻转；T2 端到端、预拷贝时长与带宽、不可写窗口、停写 / 翻转 / 移出工作集耗时、同分片其他岛停顿、M4a 区间；转发队列；跟随内存与流量、日志保留延长、恢复链长度、写放大；传送加载分解；行锁与重试；BEAM 堆 / RSS / GC / mailbox；PG 写入与池等待；故障下其余分区 p99 与恢复时长。记录版本、硬件、拓扑、玩家分布、预热、共同采样窗口、样本数。

## 9. 用户决定与待定项

**用户已定（2026-10-26）**

| 项 | 原话 | 落点 |
|---|---|---|
| 总前提 | “关于边缘暂停，我不接受。”“传送不是问题，允许加载，不必无缝，传送后不管多近都要进加载，可以做所有的加载工作。” | §1 目标 8、§3.6 |
| D14 ① | “同一窗口也进加载”：单分区也取消 `player.ex:1430-1441` 窗口内瞬达；GM 直接改位置入口（`player.ex:521-537`）按 Test-only 诊断归类，不算正式传送 | §3.6、S1b |
| D13 ② | 保持已批准 Q1（模拟半径 = 近景窗口 + 一圈页）；所有权覆盖窗口，协议 41 与客户端不改；近景按页版本 / 会话观察序号等协议改动并入 S5 与远景一起冻结 | §3.3、§3.6、§7 |
| D9 | 足迹伸到他岛时不拒绝：该编辑排队并触发提前合并（迁小岛），合并翻转后执行；代价是这一笔确认多等一次合并时间 | §3.1 |
| D10 | 合并后保留全部已有过程，ticket 上限只限制新发 ticket；合并后的分片承担合计负载 | §3.3 |
| D7 A″ | 认领确认期间矩形内他人编辑延后到决定后（有超时），committed 按保护拒绝、aborted 照常执行 | §4.10 |

**仍需用户（首测或对应交付步前）**

| # | 问题 | 何时 | 说明 |
|---|---|---|---|
| D3 | 输入包络数值与 d_merge / d_pre 确认 | S2 / S3 首测后 | 维度见 §3.3；包络内迟到须为 0，包络外按事故 |
| — | 不可写窗口阈值、E 判据容差（停步、确认时延）、T_claim | S3 首测后 | 未定前只出报告、不判通过 |
| D11 | 电路分量上限检查对象 | 用户 2026-10-27 已定 ① | ①（“按推荐来”）：接线时按潜在连通图（忽略开关与温度）检查、只计玩家放置 / 加工的导体，超限拒接；经天然矿脉在运行中合成的超限分量按 ② 整体冻结并提示 |
| D12 | 每角色拟态上限 | 用户 2026-10-27 已定，S1a 落地 | 采用推荐：只统计施法者当前分区内本人拟态数；角色传送后旧分区拟态继续自然演化、不计入新分区上限，短时全局数可超过单分区上限；不增加跨分区归还消息。执行与验收见 [execution-plan.md 的 A2](2026-10-24-world-region-paging/execution-plan.md#a2-流级实体热账与-d12) |

**工程默认（不改玩家可见语义，不再征询）**：D1 分区原则（绑定组 + 岛闭合 + 领导权转移）；D2 角色账写权随角色所在分区；D4 热点由单分片承载、规模入包络；D5 远景按协议 42 片段；D6 号源（计数行号块 + `next_seq` + 独立 aid + 前驱链）；D8 顺序（M2b、P6 在拆分前）；合并时动作连续、在途过程不平移锚点、交接期间操作排队转发（R1）。

## 10. 仍未闭合与交付步指针

- **规划者归属（双方立场）**：Fable 主张 T1 planned 行由目标自写；Astra 主张单一控制 owner。取唯一规划者（§3.3）；S2 实测供给，成瓶颈再下放 T1 规划，合同不变。
- **推断待证**：投射物人物命中与 K = 1 等价（E2）；成员移出热工作集耗时（`Thermal.rebuild_work`，S2 测）。
- **交付步指针**：交接载荷结束标记（S2）；同 (src, dst) 同拍冷页合成一条迁移、容量不等式按迁移数 / s 计（S2）；源未驻留冷页的跟随直接读 PG 已发布版本（S2）；分批快照只应用其边界之后的投影（S2）；参数 t_fin、T_abort、保留超时、信用窗口、并发数、限速值实测定（S2 / S3）；`merge_late` 事故路径只由判定器合成轨迹覆盖（S3）；平均供需不等式只是必要条件，突发与闭包扩大计入实测等待（S2 / S3）；合并不拆分使目标 5 只在 S4 后成立（S4）；D11 ② 只是备选，不预做第二套图算法（S0）；动态边界与 K ≥ 3 Scene 分工、Replica 与非流送 Scene、远景全套（对应步）。

## 依据（外部；“已核实”= 前轮或本轮打开原文看到原句）

| 结论 | 出处与原句 | 用在 |
|---|---|---|
| 领导权转移：旧 leader 先停新请求、补齐目标日志；超时中止 | Ongaro, *Consensus: Bridging Theory and Practice* §3.10，https://web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf ：“The prior leader stops accepting new client requests.” 已核实；原文注明 “we have not currently implemented or evaluated this leadership transfer approach.” | §4.2 |
| 会话记录最新序号与响应 | 同上 §6.3：“The session tracks the latest serial number processed for the client, along with the associated response.”（Astra 交叉评审打开原文，本轮未重开） | §4.5 |
| 转移中实现上丢弃提案 | raft-rs `src/raft.rs`，https://github.com/tikv/raft-rs/blob/master/src/raft.rs ：“transfer leadership to {lead_transferee} is in progress; dropping proposal” 已核实 | §4.2 |
| 预拷贝 + stop-and-copy | Clark et al., NSDI 2005，https://www.usenix.org/legacy/event/nsdi05/tech/full_papers/clark/clark.pdf ：“an OS running a Quake 3 server to migrate with just 60ms downtime.” 已核实；不作回合预算 | §4.2 |
| ghost 只读副本、向 real 转发；迁移边界约加 10 m | BigWorld Server Overview §5.1.8–5.1.11（第三方镜像 https://github.com/Monstrofil/bigworld_docs/blob/master/server_overview.pdf ）：“Each ghost knows its real cell, so that it can forward messages to its real version to be processed.”“The boundary is artificially increased (by about 10 metres) to avoid hysteresis.” 已核实，非官方来源 | §3.3、§4.5 |
| 合并半径不变式、tick 中不得扩张 | Folia，https://docs.papermc.io/folia/reference/region-logic/ ：“a ticking region cannot expand the chunk positions it owns as it ticks.” 已核实；合并半径数值未核实（v6 把 “left ambiguous” 归给它有误，该句讲分段 N） | §3.3 |
| FOR SHARE 阻塞 UPDATE；同行并发 UPDATE 等待后重做；40001 / 40P01 | PostgreSQL explicit-locking、transaction-iso、errcodes-appendix，https://www.postgresql.org/docs/current/ 下对应页 已核实 | §4.1、§6 |
| 快照与变更流共享精确边界（类比，不引入逻辑复制） | PostgreSQL Logical Decoding, Exported Snapshots：“which will show exactly the state of the database after which all changes will be included in the change stream”（Astra 打开原文，本轮未重开） | §3.6 |
| 超时后迟到回复不可达 | gen_server 文档：“Starting with OTP 24, gen_server:call uses process aliases, so late replies will not be received.”（Astra 打开原文，本轮未重开） | §4.5 |
| 同源信号保序 | Erlang Processes：“if an entity sends multiple signals to the same destination entity, the order is preserved” 已核实 | §4.5 |
| 接收消息后时钟前推 | Lamport 1978 IR2(b)，CACM 21(7) p.560 已核实 | §6 |
| 仓内 owner_epoch 拒旧 | `data_service/lib/data_service/body_store.ex:43-51` | §4.1 |

**未核实、不据以论证**：SpatialOS “checkout 区域大于 authority 区域”的直接原句；MultiPaper “一般编辑转发给 owner”；Folia 合并半径数值；BigWorld 官方来源；任何外部时延数值对本项目的适用性。

## 进度日志

- 2026-10-26：v1 调研 → v2（独立评审）→ v3（交叉评审）→ v4、v5（复核）→ v6（用户不接受边缘停顿、传送一律加载）；各轮摘要见 §0′。
- 2026-10-26：v6 经 Fable / Astra 独立与交叉评审（一致：按合并清单闭合后可批准方向）；用户定 D7 A″、D9、D10、D13 ②、D14 ①。v7 初稿按 §0 吸收并按 AGENTS 纪律收紧。
- 2026-10-26：v7 单轮复核（Fable：4 条措辞级；Astra：3 条严重）按 §0 末 K1–K8 吸收：转发收窄到迁移队列一次重新路由、角色接纳接缝与待施放接管、对话随迁、中止订阅续流、K = 2 Scene 分工按所有权、写授权按行取并、删身体迁移推断、文档修正。v7 定稿候选，待用户批准。
