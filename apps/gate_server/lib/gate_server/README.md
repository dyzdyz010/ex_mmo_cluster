# GateServer 运行时边界

`GateServer` 是面向客户端的传输层和控制入口。这里负责认证、会话、TCP / WebSocket /
UDP 连接状态和结构化观测日志，不拥有权威玩法状态。

## 顶层监督树

`GateServer.Application` 启动：

- `GateServer.InterfaceSup`
  - 服务发现和下游节点查找入口，测试环境之外启用
- `GateServer.FastLaneRegistry`
  - UDP 快速通道的票据、会话和客户端地址绑定表
- `GateServer.StdioInterface`（可选）
  - 面向自动化的运行时检查入口
- `GateServer.TcpAcceptorSup`
  - TCP 监听接入进程，测试环境之外启用
- `GateServer.TcpConnectionSup`
  - 每个 TCP 客户端一个 `GateServer.TcpConnection`
- `GateServer.WsConnectionSup`
  - 每个 WebSocket 客户端一个 `GateServer.WsConnection`
- `GateServer.UdpAcceptorSup`（测试环境之外启用）
  - 快速通道共享 UDP 套接字进程

## 工作进程职责

- `worker/tcp_acceptor.ex`
  - 接收 TCP 套接字并交给连接进程
- `worker/tcp_connection.ex`
  - 每个 TCP 客户端的协议和会话进程
- `worker/udp_acceptor.ex`
  - 移动快速通道的共享 UDP 收发进程
- `worker/fast_lane_registry.ex`
  - 票据签发、客户端地址绑定和空闲清理

## 协议分层

- `codec.ex` 负责二进制帧和结构化元组之间的转换。
- `tcp_connection.ex` 和 `ws_connection.ex` 负责连接内分发与会话状态机。
- 聊天 `ChatSay(0x08)` 不再走 Scene AOI 热循环，且保持为兼容世界频道帧。
  `ChatSayScoped(0x0A)` 只允许客户端声明 `world` / `region` / `local` scope；
  `GateServer.ChatScope` 必须从当前连接的服务端 `partition_context` / `chat_context`
  派生实际频道，客户端不能上传 `region_id`、`chunk_coord` 或位置来决定频道。连接进场
  成功后，Gate 把服务端会话注册到 `ChatServer.RuntimeDirectory`；目录只按
  `logical_scene_id` 选择分片，分片内 `ChatServer.Runtime` 负责频道投递计划、消息 ID
  和结构化日志，再把 `ChatMessage(0x89)` cast 回 Gate 连接进程编码下发。Gate 不拥有
  聊天真相。默认路径在目录不可用时失败关闭，不会隐式落回旧单例 Runtime。
  当 `partition_context` 带有 World window 派生的 `candidate_region_ids` 时，local
  chat 会把这些服务端候选 region 传给 Chat runtime 作为预选 hint；Chat 仍按服务端
  `chunk_coord` 做精确半径过滤，客户端仍不能提交候选 region。Gate 只有在
  `candidate_region_radius` 覆盖本次 local 半径时才使用该 hint；覆盖不足时会退回普通
  local chunk-window 计划，避免跨 region 的合法近邻被静默漏发。
- `GateServer.PartitionContext` 是连接级的权威分区上下文 planner。它消费 Scene 返回的
  服务端权威位置和 World partition window，计算当前 chunk / region、订阅 diff 和
  Chat presence 刷新数据。它是纯模块，不调用 World / Scene / Chat；连接进程或 CLI
  smoke 负责应用结果。位置到 chunk 的换算必须走 `SceneServer.Voxel.Types` 的 canonical
  厘米坐标规则，不再使用客户端或 Gate 本地的临时 `/16` 推导。
- `GateServer.PartitionRuntime` 是 TCP / WebSocket 共用的区域上下文运行时桥接。连接进程
  收到 Scene 的 `movement_ack` 后会先把 ACK 发回客户端，再通过
  `GateServer.PartitionRefresh` 启动带 generation fence 的异步 World 路由 / 分区规划；
  这段慢速控制面查询不会阻塞连接进程继续处理 debug probe 或后续输入。只有最新 generation
  且 `auth_tick` 与当前 pending ACK 匹配的 refresh decision 会回到连接进程内应用 Chat /
  体素订阅副作用；晚到或 tick 不匹配的旧结果会记录为 dropped，不会触碰 Chat presence、
  Scene subscriber 或本地连接 state。订阅应用前会用 owner 进程当前 state 重算 diff，
  避免异步期间的新订阅、版本 ledger 或投递队列被旧计划清掉。
  同 chunk 不调用 World / Chat，跨 chunk 才拉取 World partition window、调用
  `PartitionContext`、刷新 Chat presence，并记录 `partition_context`、
  `last_partition_refresh` 和订阅应用摘要。Chat session 尚未注册时，runtime 会用
  World 解析出的 authoritative presence 重新 join；Chat refresh 失败会记录
  `pending_chat_presence` 并在后续同 chunk ACK 上重试，但不会反向影响 movement ACK。
  同步 API 仍用于 enter-scene bootstrap 和纯模块测试；如果 Scene 订阅应用失败，
  movement / partition / chat 上下文仍保持服务端权威结果，失败原因写入
  `last_partition_refresh.subscription_apply_status` 和 observe log。
- 体素区块订阅必须先请求 `WorldServer.Voxel.MapLedger` 路由。World 返回当前区域租约
  后，Gate 才能通过 `GateServer.Voxel.SubscriptionRuntime` 向
  `SceneServer.Voxel.ChunkDirectory` 建立真实订阅；初始快照和后续快照回退推送都由
  Scene 区块进程发给 Gate，再由 Gate 转发给客户端。TCP / WebSocket 的显式
  `ChunkSubscribe` 和 movement boundary refresh 共享这一套订阅应用、回滚和日志逻辑。
- Gate 会在 TCP / WebSocket 转发 `ChunkSnapshot` / `ChunkDelta` 时维护每连接的
  `forwarded_chunk_versions`。这份账本只表示 Gate 已经跨过本地发送边界，不能证明客户端
  已收到；它只用于校验后续 `VoxelChunkAck` 或 legacy `ChunkSubscribe.known` 是否没有超前。
  后续显式订阅和 movement boundary refresh 传给 Scene 的 `known_version` 都来自
  `client_ack_versions`，并会排除已被 `DeliveryScheduler` 标记为 `resync_required` 的 chunk。
  Scene 仍决定是否发送快照，客户端不能用 ACK 声明体素真相。
- Scene 推来的实时 `ChunkSnapshot` / `ChunkDelta` 和 `FieldRegionSnapshot` 不再绕过
  Gate 预算。TCP / WebSocket 连接会先经过
  `GateServer.Voxel.DeliveryScheduler`，超出当前连接发送窗口的体素状态数据会进入有界待发
  队列；`forwarded_chunk_versions` 只在 TCP 写出成功或 WebSocket frame 交给连接 owner
  后更新。
  `ObjectStateDelta` 是对象事件 lane，会经过同一 observe 面但不进入可阻塞状态队列，避免场域
  10Hz 快照高峰拖慢破坏、掉件等对象事件。
  `ChunkInvalidate` 属于控制流，会绕过数据预算、清掉同 chunk 的待发数据和版本提示后
  立即下发，避免客户端先收到过时数据再收到失效通知。
  `FieldRegionDestroyed` 同样属于控制流，会立即下发并清掉同一场域区域的待发 snapshot，
  避免客户端在场域已经消失后继续看到过期 overlay。
  队列满时不会丢弃已经排队的旧 delta 来保留新 delta；新帧会被丢弃并把该 chunk 标记为
  需要后续 snapshot / invalidate 重新闭合同步链路，避免向客户端发送断链 delta。
- Gate 保存的体素订阅会记录 `region_id`、`lease_id`、`owner_scene_instance_ref`、
  `owner_epoch` 和实际 Scene 节点。迁移 cutover 后，World/Scene 发出的
  `ChunkInvalidate(reason=:migration_cutover)` 会让 TCP / WebSocket 连接自动重查 World 路由，
  并把受影响订阅重绑到新租约。若连接当前 `partition_context` 指向同一个 chunk，
  Gate 会在新订阅成功后同步刷新本地分区身份，把 `lease_id`、`owner_epoch`、
  `owner_scene_instance_ref` 和 `assigned_scene_node` 更新为 World cutover 后的结果，并标记
  `boundary_kind=:authority_cutover`；静止玩家不需要再等下一次移动 ACK 才摆脱旧权威路由。
  `voxel_rebind <logical_scene_id> <region_id|all>` 仍保留为 WebSocket 调试探针，并复用同一套
  失败 pending 语义：自动重绑失败会把旧流移入 `voxel_subscription_rebind_pending`，后续手动
  rebind 会重新查询 World 并恢复活跃订阅。结构化日志会记录 requested / routed / skipped /
  subscribed_new / unsubscribed_old / completed / error；WebSocket 手动调试入口额外使用
  `voxel_subscription_rebind_aggregate_*` 记录整次命令摘要，避免和逐订阅事件混淆计数。
- 体素区块退订 `ChunkUnsubscribe` 会移除 Gate 保存的订阅状态，并向 Scene 做幂等退订。
- 体素冲击意图 `VoxelImpactIntent` 同样必须先经过 World 路由和租约发放。Gate 只把
  客户端世界坐标换算为区块坐标和区块内坐标，再把带租约的写入请求转交给 Scene；
  Scene 通过 DataService 写入令牌校验并持久化后，Gate 才返回 `VoxelIntentResult`。
  Gate 还会先校验当前连接的有效角色 ID 和服务端技能表，避免未知技能直接写入体素。
- 场运行时意图 `FieldConductIntent(0x75)` 是交互式导通/放电的低延迟入口。Gate 只
  解码、校验会话、按源格所在 chunk 查询 World 路由，并把请求转给 Scene 侧
  `FieldRuntime.ensure_conduction_path/1`；FieldRegion 的创建、tick、快照和销毁仍由
  Scene/ChunkProcess 拥有。客户端不得用提交成功本身表现闪电，只能等 `0x73`
  `FieldRegionSnapshot` 到达后表现。
- `udp_acceptor.ex` 拥有共享 UDP 套接字，但权威判断仍委托给连接层和场景层。
- `stdio_interface.ex` 只提供观察和轻量控制入口，不能成为第二份运行时事实来源。
  可用命令包括 `snapshot`、`connections`、`players`、`npcs` 和 `voxel`；其中 `voxel`
  会以内联快照说明 Gate 连接订阅、World 区域租约、Scene 热区块目录和 DataService
  写入令牌 / 快照表。

Gate 不拥有体素真相。体素流量中，Gate 只拥有传输、会话状态和结构化观测事件；
World 拥有区域权威和租约，Scene 拥有热区块状态，DataService 拥有带围栏的持久化。

## 非 GUI 冒烟验证

`mix gate_server.voxel_smoke` 会在单个 BEAM 节点内启动最小本地运行时，用真实 WebSocket
二进制帧驱动 `ChunkSubscribe`、`VoxelImpactIntent`、快照推送和 `ChunkUnsubscribe`：

- Gate 日志：解码、路由、订阅、意图应用和快照转发。
- World 日志：区域登记、租约发放和区块路由。
- Scene 日志：热区块启动、订阅、持久化后快照推送和退订。
- stdio 日志：`server_stdio event="voxel"` 格式的运行时快照，默认写入 `.demo/observe/`。

该 smoke 会自己启动 `data_service`，确保 `DataService.Repo` 可用；初始订阅仍断言 `ChunkSnapshot`，后续热路径断言 `ChunkDelta`，并在读取 PostgreSQL 快照前通过 `ChunkProcess.flush_persistence/2` 等待异步持久化落盘。CLI summary 中的 `updated_frame_type=delta`、`stored_snapshot_version` 和 `unsubscribe_stopped_push` 是当前自动化验收的关键字段。

`mix gate_server.partition_presence_observe` 是分区上下文的无 GUI 验证入口。它构造一次
“权威位置跨 chunk/region”移动，向 World 获取 partition window，调用 Gate
`PartitionContext` 计算订阅 diff，再刷新 Chat runtime 中该玩家的 presence。stdout 会输出
`from_chunk`、`to_chunk`、`from_region_id`、`to_region_id`、`boundary`、订阅增删计数和
`chat_presence_updated`；Gate observe log 会写入 `gate_partition_presence_resolved`。同 chunk
移动会输出 `boundary=none`、订阅 diff 为 0、`chat_presence_updated=false`，用于验证快路径
没有触发 World / Chat 刷新。

`mix gate_server.partition_subscription_observe` 是分区订阅应用的无 GUI 验证入口。它构造
同样的权威移动边界，但会启动本地 Scene chunk directory，通过
`SubscriptionRuntime` 真实执行一次订阅 diff：先订新 chunk，再幂等退订旧 chunk。stdout
会输出 `subscription_apply_status`、`subscribe_count`、`unsubscribe_count`、
`retained_count`、目标 chunk 的 `target_known_version_source` / `target_known_version_for_scene`
和 `active_subscription_count`；Gate observe log 会写入
`voxel_subscription_diff_applied` / `voxel_subscription_diff_failed` 以及
`gate_partition_subscription_resolved`。同 chunk 移动会输出 `subscription_apply_status=none`
和 0 增删，证明快路径没有重绑流。`--known-version-mode forwarded|acked|acked-resync`
可复现“只转发未 ACK 不复用”、“客户端 ACK 后可复用”和“ACK 过但需要 resync 时强制重新同步”
三种边界。

`mix gate_server.partition_failure_observe` 是跨区控制面失败恢复的无 GUI 验证入口。它不启动
真实下游集群，而是通过 `GateServer.PartitionRuntime` 的注入缝驱动同一条权威移动边界，
复现 World 不可路由、Chat presence 刷新失败、Scene 订阅应用失败三类故障。stdout 会输出
`failure`、`refresh_status`、`authoritative_status`、`partition_context_region_id`、
`partition_context_chunk`、`chat_context_region_id`、`chat_context_chunk`、
`previous_context_preserved`、`partition_context_updated`、`chat_context_updated`、
`pending_chat_presence`、`pending_subscription_result` 和 `subscription_apply_status`；Gate observe log 会同时保留 runtime 原始失败事件和
`gate_partition_failure_resolved` 汇总。该入口用于确认：World 不可路由时连接继续保留旧的可用
分区 / 聊天上下文；Chat 失败时分区上下文已经跟随服务器权威位置更新，但聊天 presence 和订阅
diff 进入待重试状态；Scene 订阅失败时分区和聊天上下文不回滚，只把订阅失败原因暴露给后续恢复。
其中 `refresh_status` 表示本次控制面刷新调用是否完整成功；`authoritative_status` 表示
`PartitionRuntime` 对权威分区状态的判定，避免把 Chat / Scene 副作用失败误读成分区未前进。

`mix gate_server.chat_scope_observe` 是分区驱动聊天作用域的无 GUI 验证入口。它构造
当前连接的服务端 partition/chat context，只让“客户端”提交 scope 和正文，然后通过
`GateServer.ChatScope` 派生实际 Chat runtime channel。stdout 会输出 `scope`、
`channel`、`candidate_region_ids`、`candidate_region_radius`、`server_derived`、`recipient_count` 和 `skipped_count`；Gate observe log 会写入
`gate_chat_scope_resolved`，Chat observe log 会写入 `chat_delivery_planned`，用于确认
区域/本地聊天没有使用客户端自报分区字段。

`mix gate_server.chat_boundary_observe` 是跨分区移动后聊天作用域的无 GUI 验证入口。它用
私有 World `MapLedger` 和 Chat runtime 构造一次“旧 region -> 新 region”的权威移动，
先走 `PartitionRuntime` 刷新 Gate 的 `partition_context` / `chat_context`，再用刷新后的
服务端上下文派生 scoped chat channel 并真实投递。stdout 会输出 `boundary`、
`from_region_id`、`to_region_id`、`chat_presence_updated`、`channel`、
`voxel_subscription_apply`、`old_region_delivered`、`new_region_delivered` 以及
Gate / Chat / World 三份 observe log 路径；Gate log 写入 `gate_chat_boundary_resolved`，
Chat log 写入 presence 更新和投递计划，World log 写入本次 partition window 查询。该入口用于确认无缝跨区移动后，区域/本地聊天不会
继续按旧 region 投递，也不会接受客户端自报分区。该 CLI 不创建真实 Scene 订阅 runtime；
体素订阅应用在此入口中显式跳过，避免聊天边界 smoke 产生无关的 Scene unavailable 失败日志。

`mix gate_server.migration_cutover_observe` 是分阶段迁移 cutover 后 Gate 自动重绑的无 GUI
验证入口。它不再走 World 的 convenience `migrate_region/4`，而是按 canonical 顺序驱动：
`begin_migration -> plan slice -> migration_handoff -> Scene prewarm -> World prewarm ACK ->
Scene final catch-up -> World final catch-up ACK -> cutover -> invalidate -> Gate rebind`。
CLI 用两个独立 `ChunkDirectory` 模拟 source / target Scene，source 会先写入一个真实热 chunk，
target 预热和最终追赶都从 DataService snapshot 读取，World 只在 ACK 完整后切换
`lease_id / owner_epoch / owner_scene_instance_ref / assigned_scene_node`。该任务每次运行都使用私有
`VoxelChunkSup`，退出时清理临时 source / target 热 chunk，不会把 smoke 数据挂到已有 Scene
运行树下；同时会读取当前 `WriteTokenStore`，为本次 smoke 选择递增 token version，避免无 GUI
调试入口因为同一 scene/region 的旧测试 token 而被 CAS 误判为 stale。stdout 会输出
`prewarm_ack_count`、`final_catchup_ack_count`、`source_persisted_count`、
`target_loaded_count`、旧租约 stale 校验结果、`rebind_status`、`rebound_count` 和
`snapshot_restored`，并把成功重绑后的 `partition_context_lease_id`、
`partition_context_epoch`、`partition_context_owner`、`partition_context_scene_node` 打到同一行，
便于确认 Gate 本地路由身份已经跟随服务器 cutover 刷新；同一 observe log 会同时写入 World 的
`voxel_migration_*`、Scene 的
`voxel_migration_slice_prewarm_*` / `voxel_migration_slice_final_catchup_*` /
`voxel_chunk_invalidate_pushed` 与 Gate 的 `voxel_subscription_rebind_*` 事件和
`partition_context.boundary_kind=:authority_cutover` / `assigned_scene_node` 摘要，便于确认切换链路
没有依赖客户端乐观状态。
该 CLI 不创建真实 socket；TCP / WebSocket 连接级自动重绑由对应 worker 集成测试覆盖。
若新租约订阅失败，Gate 会把该 chunk 从活跃订阅表移到
`voxel_subscription_rebind_pending`，避免继续把已经被 Scene 失效的旧租约显示成可用流；CLI 的
`--simulate-rebind-failure` 会输出 `gate_migration_cutover_rebind=failed` 和
`pending_rebind_count=1`，用于无 GUI 检查失败恢复面。

`mix gate_server.chunk_version_observe` 是体素版本账本的无 GUI 验证入口。它构造一条
`ChunkSnapshot` 和一条 `ChunkDelta`，走 `GateServer.Voxel.ChunkVersionLedger` 记录路径，
stdout 输出 `forwarded_chunk_versions`，Gate observe log 写入
`gate_chunk_version_observe`。TCP / WebSocket 的 `voxel_transport` debug probe 也会输出
同一字段，便于无界面排查“为什么这次订阅是否还会发完整 snapshot”。

`mix gate_server.delivery_scheduler_observe` 是实时体素下发调度的无 GUI 验证入口。它构造
一次快照、一次超预算增量、一次失效通知、一次对象状态更新和一次场域快照/销毁链路，
stdout 输出 queued / deferred / pruned / sent 计数，Gate observe log 写入
`gate_voxel_delivery_scheduler_observe` 和每次 offer 的调度结果。TCP / WebSocket 的
`voxel_transport` debug probe 会同时输出
`voxel_delivery_queue_count`、`voxel_delivery_deferred_count`、
`voxel_delivery_sent_count`、`voxel_delivery_event_sent_count` 等字段。

Prefab 0x67 dispatch bulk-routes all touched chunks through World MapLedger and
requires every route to carry `RegionAssignment.assigned_scene_node`:

- Single-chunk placements call `ChunkDirectory.apply_intents/2` directly and
  emit `*_prefab_single_chunk_fast_path_*`.
- Multi-chunk placements whose participants all resolve to the same concrete
  `{ChunkDirectory, scene_node}` run a local prepare/commit/abort through
  `GateServer.Voxel.PrefabLocalTransaction` and emit
  `*_prefab_same_owner_fast_path_*`.

Plans are grouped by concrete Scene owner `{ChunkDirectory, scene_node}`, not by
lease. A Scene-owner participant may cover several `{region_id, lease_id}`
owners; the plan carries `chunk_owners` so World and Scene still write correct
object-owner metadata. Split-owner plans use World `TransactionCoordinator` /
`TransactionExecutor` with `scene_opts_by_participant` keyed by
`participant_key`. Scene applies the direct chunk path in macro-grouped batches,
so a right-click boundary-snap prefab that touches multiple macro cells inside
one chunk stays on the lowest-latency path, while same-owner cross-chunk prefabs
avoid the World coordinator round trip.

The route contract is intentionally strict: Gate does not call
`scene_server_for_owner`, does not infer Scene ownership from
`owner_scene_instance_ref`, and does not build lease-only participants. Missing
`assigned_scene_node`, `participant_key`, or `chunk_owners` rejects the prefab
plan before dispatch.
