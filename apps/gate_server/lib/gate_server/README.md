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
- 体素区块订阅必须先请求 `WorldServer.Voxel.MapLedger` 路由。World 返回当前区域租约
  后，Gate 才能向 `SceneServer.Voxel.ChunkDirectory` 建立真实订阅；初始快照和后续快照
  回退推送都由 Scene 区块进程发给 Gate，再由 Gate 转发给客户端。
- Gate 保存的体素订阅会记录 `region_id`、`lease_id`、`owner_scene_instance_ref`、
  `owner_epoch` 和实际 Scene 节点。迁移 cutover 后，WebSocket 连接可以通过
  `voxel_rebind <logical_scene_id> <region_id|all>` 调试探针重查 World 路由，并把已有订阅
  重绑到新租约；结构化日志会记录 requested / routed / skipped / subscribed_new / error。
- 体素区块退订 `ChunkUnsubscribe` 会移除 Gate 保存的订阅状态，并向 Scene 做幂等退订。
- 体素冲击意图 `VoxelImpactIntent` 同样必须先经过 World 路由和租约发放。Gate 只把
  客户端世界坐标换算为区块坐标和区块内坐标，再把带租约的写入请求转交给 Scene；
  Scene 通过 DataService 写入令牌校验并持久化后，Gate 才返回 `VoxelIntentResult`。
  Gate 还会先校验当前连接的有效角色 ID 和服务端技能表，避免未知技能直接写入体素。
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

Prefab 0x67 dispatch has a single-chunk fast path: after MapLedger routing, if
all rasterized cells land in one chunk under one lease, Gate calls
`ChunkDirectory.apply_intents/2` directly and emits
`*_prefab_single_chunk_fast_path_*`. Cross-chunk or cross-lease plans still use
World `TransactionCoordinator`/`TransactionExecutor`.
Scene applies that direct path in macro-grouped batches, so a right-click
boundary-snap prefab that touches multiple macro cells inside the same chunk
still stays on the low-latency path.
