# Gate 工作进程运行时边界

本目录包含组成 Gate 传输层的运行时工作进程。

## 关键工作进程

- `interface.ex`
  - 服务发现，以及下游 `scene_server`、`world_server`、`auth_server` 节点查找
- `tcp_acceptor.ex`
  - 接收新的 TCP 套接字
- `tcp_connection.ex`
  - 每个 TCP 客户端的协议和会话进程
- `ws_connection.ex`
  - 每个浏览器 WebSocket 客户端的协议和会话进程
- `udp_acceptor.ex`
  - UDP 快速通道的共享收发进程
- `fast_lane_registry.ex`
  - UDP 绑定用的票据和会话注册表

## 设计规则

这里的工作进程必须保持传输和会话职责。权威玩法状态属于 Gate 之外。

体素区块订阅要先向 `WorldServer.Voxel.MapLedger` 查询当前租约，再向 Scene 建立真实订阅；
后续区块变化由 Scene 推送到 Gate，Gate 只负责转发。体素退订必须同步清理 Gate 订阅表和
Scene 区块订阅者。

体素冲击意图也要先校验连接角色和服务端技能表，再经过 World 路由，最后由 Scene 带租约
执行写入并通过 DataService 持久化。这样 Gate 可以被观察为路由器和协议适配器，而不会
变成体素权威。
