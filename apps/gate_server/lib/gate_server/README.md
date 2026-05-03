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
- 体素区块退订 `ChunkUnsubscribe` 会移除 Gate 保存的订阅状态，并向 Scene 做幂等退订。
- 体素冲击意图 `VoxelImpactIntent` 同样必须先经过 World 路由和租约发放。Gate 只把
  客户端世界坐标换算为区块坐标和区块内坐标，再把带租约的写入请求转交给 Scene；
  Scene 通过 DataService 写入令牌校验并持久化后，Gate 才返回 `VoxelIntentResult`。
  Gate 还会先校验当前连接的有效角色 ID 和服务端技能表，避免未知技能直接写入体素。
- `udp_acceptor.ex` 拥有共享 UDP 套接字，但权威判断仍委托给连接层和场景层。
- `stdio_interface.ex` 只提供观察和轻量控制入口，不能成为第二份运行时事实来源。

Gate 不拥有体素真相。体素流量中，Gate 只拥有传输、会话状态和结构化观测事件；
World 拥有区域权威和租约，Scene 拥有热区块状态，DataService 拥有带围栏的持久化。
