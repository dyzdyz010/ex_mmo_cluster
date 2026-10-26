# 体素拆分方向稿 v7 改写报告（2026-10-26）

对象：`docs/10-active/voxel-authority/2026-10-26-voxel-authority-sharding.md`，已就地从 v6 改写为 v7，status 为“v7 待复核”。没有提交、没有改代码，没有运行服务或测试，没有操作 Docker 或数据库，也没有切换分支。评审报告未改。
v6 正文没有进 git。评审报告按 v6 的行号引用，v6 的变化摘要见 `v6-draft-report.md`。篇幅从 109,196 字节减到约 69 KB：v1–v6 的逐条变更表压成一张历史摘要表，父稿已有的内容只引用，不再复述。

## 1. 变更摘要

1. **迁移授权**：迁移行里的化身列只作历史记录。收尾、翻转、释放、解冻一律按分区行的当前化身授权，旧化身由分区行栅栏隔开。H 定义为停写提交自身的 seq，停写只在 `thermal_run == nil` 的边界发生。成员集合按停写时源算出的当前闭包确定，且必须包含在已跟随集里。持有未收口迁移的一方自己重读迁移行（§4.1、§4.2）。
2. **持久化**：写授权改为两种，即权威写和迁移历史写回（内容版本 ≤ H）。在途切点照常写完。行内容版本与发布前缀分开记。`fin_empty` 时翻转后立即释放；收尾非空时把下一次常规切点提前（共用、限速）。再迁等待计入期限。“剔除后照常发布”“只放宽状态守卫”“强制紧急切点”三种修法都没有采用（§4.4）。
3. **跟随**：只用于预拷贝。源在同一回调里取可恢复快照并登记跟随，快照和增量走同一条 FIFO；每笔提交都发送，投影为空也发；预拷贝限速并带信用窗口（§3.6）。
4. **请求与动作**：Gate worker 在出队时取当前 ctx；工具结果按 cid 写回；World 侧会话改按 Gate 会话键。交接载荷携带去重、冷却、结果会话、认领第一角和待施放状态。超时视为结果未知。R ∪ W 中任一页属于在途成员，请求就排队。改用通用的按所有权转发，删去迁移专属指针。T2 时 seal 不取消施法，投射物按 cid 认施法者（§4.3、§4.5、§4.6）。
5. **D7-A″**：阻挡改为分区级记录；投票覆盖全部列内页，不跳过任何页；导入时原子补验；决定之后挂起请求重新路由（§4.10）。
6. **集合与期限**：恢复三个集合 S_sim（Q1）、O、P；只设一个规划者；争用即触发合并；期限从需求形成起算；写明输入包络和容量不等式（§3.3）。
7. **§9**：只分三类——用户已定（附原话）、仍需用户、工程默认。
8. **§8**：交付步各标内容分类，S0 可以并行开工；每条通过条件配一条最小坏例；E1、E2 的范围分开；有界性门槛放在 S4 + P5 之后，青岚排在最后。

## 2. 逐条对照

| 清单项 | 落点 | 做法 |
|---|---|---|
| 1 迁移状态机与授权 | §4.1 每笔写都 `FOR SHARE` 执行者分区行（当前化身）；§4.2 表“源 / 目标化身 bump”两行与“自维护收敛”；§4.3 的 H、异步结果归属 | 当前化身可以继续 prepared 的接管和 committed 的收尾，旧化身被栅栏隔开。H 包含 seq < H 的全部提交。成员闭包在停写时最终确定。在跑的热 run 由停写边界排除；跨回合切点批次走历史写回；投射物的迟到采样对冻结实体丢弃，人物交付按收据幂等。源存活但没收到通知时，自己重读迁移行 |
| 2 持久化完整性与再迁 | §4.1 迁移历史写回；§4.4 的“行内容版本与发布前缀分开”“收尾”“GC” | 已受理的 C ≤ H 写回可以写完。收尾版本 H 与前缀 C 分开记。空收尾立即释放。GC 查链引用，退役流同样适用。再迁等待计入 D_T1 / D_T2 |
| 3 跟随构造 | §3.6 的“建立”“运输”“资源” | owner 在一次回调里固定快照与边界并登记，因此不需要 PG 历史保留。每笔都发，前驱不断；投影保留删除和身份（S1a 前提）。按字节 / 日志限速、带信用窗口、限制并发；慢消费者断开后重建 |
| 4 请求与在线动作连续性 | §2 编辑链路事实；§4.5 第 5–8 条；§4.6 | 以 Gate 单 worker 的同步调用为基础，不采用 Fable 的 Player 抢跑反例。旧 ctx 改为出队时重绑定；结果写回按 cid；会话随交接载荷迁移。R-only 与混合闭包按 §3.1 排队并提出需求。迟到窗口补发封口。超时视为结果未知。取消转发指针，改用通用路由规则 |
| 5 D7-A″ 覆盖不变量 | §4.10 | 新物化页和导入页由分区级阻挡覆盖；prepared 页按 H 内容投票；导入补验；解冻后页回到源（源已复核）；决定之后的导入没有旧阻挡可以复活；挂起请求重新路由 |
| 6 三集合与期限 | §3.3 | S_sim / O / P；d_pre、d_merge 从需求形成起算，含规划、源忙、连锁 / 再迁、成员变化；d_merge = f(较小岛规模, 限速带宽, 排队)；列出包络维度 |
| 7 §9 重写 | §9 | 用户决定附原话；仍需用户的只剩 D3 包络、不可写窗口阈值、E 容差、T_claim、D11、D12；D1、D2、D4、D5、D6、D8 转为工程默认 |
| 8 §8 验收 | §8 验收表与“判定器” | 预期按 D13 ② 定；每条通过条件有一条最小坏例（合成轨迹自证）；零迁移 / 零样本 / 漏选 / 不覆盖交接一律判失败，E3 未命中判“未覆盖”；K = 1 按输入序号与路线进度对齐；E1 不换 Scene |
| 用户 D14 / D13 / D9 / D10 / D7 | §3.6 / §3.3、§7 / §3.1 / §3.3 / §4.10 | 照原话写入 |
| 统筹 1–6 | R1 §4.3、§4.6；R2 §3.3；R3 §0 表；R4 §4.3；R5 §8；R6 S1b | 见 v7 §0 表 |

**统筹裁定 2 的选择**：唯一规划者（控制面）。理由：争用判定要同时看到两侧派生的预取集，而预取集不持久，只有同时接收两侧上报的进程才能做唯一裁决者。如果采用“目标自写 planned 行”，裁决会分散到 PG 唯一键、源的停写判断和控制面的合并规划三处。规划等待和吞吐计入 d_pre，S2 实测；如果实测成为瓶颈，再把 T1 的规划下放，合同不变。双方立场记在 §10。

## 3. 仍未闭合（详见稿 §10）

- 规划者归属：Fable 与 Astra 立场不同，当前取唯一规划者，S2 实测后再看。
- T2 时身体热交换登记作为流级数据随迁，属推断，S3 前核实。
- 客户端在 M4a 成功时结束对话（`VoxelM1Client.cpp:563`），要在 NPC 进入多分区之前（S4 前）处理。
- 投射物人物命中与 K = 1 的等价性属推断，由 E2 验证。
- 成员移出热工作集的耗时，S2 测量。
- 参数 t_fin、T_abort、保留超时、信用窗口、并发数、限速值，留到 S2 / S3 实测。

## 4. 新核实与未核实

**本轮打开源码核实**（服务端相对 `apps/`）：

- `voxel_region/lib/voxel_region/world/page_cut.ex:24`：`@interval_ms 30_000`。Fable 引作 `:29`，Astra 引作 `:24`，以 `:24` 为准。
- `gate_server/lib/gate_server/session/quic_connection.ex`：
  - `:615-619`：worker 只在为空时创建；
  - `:630-644`：入队时捕获 `world_ref / player / identity` 等 ctx；
  - `:648-661`：worker 逐条同步执行 `Dispatch.handle`；
  - `:706-729`：收到 Ready 后调用 `commit_transfer` 并切换路由；
  - `:796-810`：输入转发给待定 Player。
- `scene_server/lib/scene_server/movement/player.ex`：
  - `:521-537`：`handle_call({:gm_teleport, ...})`，要求落点在窗口内；
  - `:1428-1441`：`travel / relocate`，窗口内瞬达；
  - `:1039-1047`：`begin_body_detach` 先调用 `cancel_cast`；
  - `:2101-2105`：`revive == :pending` 时即使同窗也请求新窗口；
  - `:205-220`：`transfer_cut` 继承 `tool_action` 等字段。
- `scene_server/lib/scene_server/movement/tool_action.ex:10-20`：`authorize_tool → tool_intent → finish_tool`。
- `voxel_region/lib/voxel_region/world.ex`：
  - `:139,141`：`prepared_intent` 的 `GenServer.call(..., 300_000)`；
  - `:1384-1402`：快照与订阅在同一回调里建立；
  - `:1632-1639`：DOWN 时按 pid 删除 tool / spell / build 会话与 `claim_corners`。
- 会话键：`world/production.ex:108`、`world/attachment_ops.ex:18` 用 `actor.gate`；`world/tools.ex:136`、`world/casting.ex:84` 用 `actor.player`。
- `world/thermal.ex:90-91`：`remaining: 0.5`。
- `world/projectiles.ex:18-27`：单个异步 Task；`:29-37`：年龄匹配才接纳；`:46-53`：交付结算。
- `world_server/lib/world_server/movement/projectile.ex:26-39`：按 `source.identity` 与 `life_generation` 匹配施法者，找不到则命中为空；`:44-54`：按 cid 交付并返回原收据。
- `voxel_region/lib/voxel_region/collision_stream.ex:17-35`：完整 XYZ 窗口盒与 1/4 tile 滞回。
- Voxim：
  - `Movement/VoxelM1Client.cpp:25-30`：`PlayerConnectionState` 返回 0 / 1 / 2 / 3；
  - `:563`：`DialogueLog.End("scene_changed")`；
  - `Dialogue/VoximDialogueWidget.cpp:117`：“已离开场景，发送结果未知”。

**沿用评审核实、本轮未重开**：

- Ongaro §6.3 原句、PG Exported Snapshots 原句、OTP 24 call alias 原句：均由 Astra 打开。
- Folia “left ambiguous”：Astra 指出这句说的是分段 N，不是合并半径。稿内“依据”一节已更正。

**未核实**：

- 现有 UMG 资产中有没有适合做传送加载的遮罩。
- T2 时身体热交换登记能否按流级数据迁移。
- Gate 在 World 调用超时退出时的现行处理。
- Dispatch 对 `GenServer.call` 退出的捕获方式。
- 外部时延数值对本项目是否适用。

## 5. 复核吸收（2026-10-26，v7 单轮复核 → v7 定稿候选）

输入：`review-fable-sharding-v7.md`（4 条措辞级必改）、`review-astra-sharding-v7.md`（3 条严重必改，另列文档修正），以及统筹合并的 8 条。设计稿 status 改为“v7 定稿候选（单轮复核已吸收，待用户批准）”。新增复核吸收表 K1–K8（稿 §0 末）。篇幅 74,423 字节，比初稿多约 5.5 KB；为此压缩了 §7 精确入口、依据表（删 PingCAP、SpatialOS 两行）和测量段。

| 统筹条目 | 落点 | 做法 |
|---|---|---|
| 1 转发收窄 | §3.1 执行规则、§4.5 第 5–6 条、§0 M4 / K1 | 转发只发生在一处：迁移队列在决定后重新路由一次——committed 发给该迁移的 dst，aborted 在源本地执行。删除“按已知最新所有权转发”。§3.1 的需求队列与 §4.10 的认领挂起队列，若其请求触及的页成为迁移成员，就在 H 并入该迁移队列。Astra 3.3 的跳数修正因此不再需要 |
| 2 角色接纳接缝 | §4.6 三条 + S1b / S3 行 + 角色接缝判定器 | 待定移交期间，Gate worker 暂停出队，到 `commit_transfer` 成功或移交中止再出队（只等 Ready 往返；移交不等编辑回包，不会形成环）。已接纳的在途 actor 改为按 cid、会话（Gate）和 `life_generation` 刷新，原 ingress 时间与 `action_key` 保持不变。待施放：世界侧 `pending_casts` 由 dst World 唯一接管（新 Player monitor，按 cid、会话、生命代次授权）；Scene 侧前摇定时器由新 Player 按绝对到期时刻重建 |
| 3 对话连续 | §4.6 “对话”、S3 行、验收表“动作与对话零中断” | 写明 `DialogueLog` 是玩家 `say` 的投影，与 NPC 无关。正常 T2 时，话题（听众集合、轮次、在途请求）随移交改用新身份，结果由新 Scene 回给同一会话，客户端移交成功后不再 `End`。参与者没有随迁的话题，在途请求显式回原因码；TC 传送同一规则。待定移交期间的 `Say` 改走编辑序列，不再回 `transfer_in_progress`。归 S3 交付，Global system |
| 4 中止订阅出口 | §4.5 第 3–4 条、§4.2 解冻行、订阅连续判定器 | 订阅 owner 自己观察决定。aborted 时向源 `subscribe_handover(m, H)`，从 H 的后继起连续补流（含 U_m）；保留下限已放开或源已重启时，按 `cursor_expired` 整窗重取 |
| 5 S2 Scene 分工 | §3.6 “Scene 分工（S2）”、S2 行、E1 | K = 2 起，越界判定改为“所在页是否归本分区”，取代 `config.authority` 静态盒（`player.ex:1706-1710`）。移交只随 T2 发生；动态重分与 K ≥ 3 留在 S4 |
| 6 写授权措辞 | §4.1、§4.2 翻转行 / 释放行、§4.4 收尾 | 每行在写事务内 `FOR SHARE` 其 owner 行与迁移行，两种条件按行取并。中止后的在途批次按权威写通过。`released_seq = 0` 的快路在同一事务里清占用。收尾改述为“首个 C ≥ H 的发布完整承接成员 H 时内容，已承接的干净单元不重写”（C = H 也包括在内） |
| 7 删除推断 | §3.5 表、§4.6 “随 T2 迁移的玩家”、S1a 行、§10 | 删掉“身体热交换登记随 T2”。T2 的 seal 只去掉 `cancel_cast`，`body_detach` fence 保留（即时回复）；身体由新 Player 的 `body_tick` 在 dst 重新登记，2.5 s 无心跳自动摘除 |
| 8 文档修正 | §3.1 R / W 定义、§4.3 / §4.4 引用、§8 交付表与验收表 | R / W 在稿内给出最短定义；“§6.2”改为“§6 号块”。交付表分类改为“代码 Global system / 验收 Test-only”。S0 只卡两处前置：电路分量检查等 D11，粗层段等行键。验收表新增“正常场景零容忍：结果未知、会话终止、`cursor_expired`、迁移导致的工具中断”；“恰好一个结果”要核对双端可见的权威事务 |
| 其余交付步项 | §10 “交付步指针” | 每项一句：交接载荷结束标记、同 (src, dst) 冷页批量迁移与按迁移数 / s 计容量、未驻留冷页跟随读 PG、分批快照的边界、参数实测、`merge_late` 只由合成轨迹覆盖、供需不等式只是必要条件、目标 5 在 S4 后才成立、D11 ② 不预做第二套算法 |

**本轮补核源码**：
- `scene_server/lib/scene_server/movement/player.ex`：`:186-204` 导入时为 `transfer: :prepared`；`:361-372` `authorize_tool` 要求 `transfer: nil`；`:670-676` 前摇定时器发给本进程；`:1005-1018` `body_tick`；`:1702-1712` 按 `config.authority` 判越界。
- `voxel_region/lib/voxel_region/world/tools.ex:578-584`：`current_actor` 回调 `actor.refresh.(actor.player, …)`。
- `world/casting.ex:106-118`：monitor 并发消息给 `actor.player`。
- `world.ex:1521-1529`：`body_detach` fence；`:1570` `pending_casts` 按 cid 存取。
- `thermal.ex:82-85`：2.5 s 无心跳自动摘除。
- `scene_server/lib/scene_server/movement/scene.ex:450-462`：移交时调 `Dialogue.leave`；`dialogue.ex:43-53`：删除旧身份的听众资格与在途请求；`:238-249`：找不到话题即 `conversation_expired`。
- `quic_connection.ex:766-787`：待定移交期间 `Say` 回 `transfer_in_progress`。
- Voxim `Dialogue/VoximDialogueLog.h:4`、`.cpp:20-23`：`End` 只改写待确认请求的原因。

**不同意而未采纳**：没有。

**部分保留**：Fable 主张删去“`body_detach` 收口”，Astra 要求取消它时保留等价收口。这里取两者的交集——不迁移身体登记，但保留 `body_detach` fence，因为它是即时回复的消息，不会带来等待。
