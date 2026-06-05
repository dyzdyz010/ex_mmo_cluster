# Gate 工作进程运行时边界

本目录包含组成 Gate 传输层的运行时工作进程。

## 关键工作进程

- `interface.ex`
  - 服务发现，以及下游 `scene_server`、`world_server`、`auth_server` 节点查找
  - 该进程是 Gate 对下游服务位置视图的 **authority**；连接进程只读不写。
  - 硬依赖 `scene_server` 缺失时，不再硬匹配 `await` 而崩溃重启（cluster-discovery-3）：
    采用**有界重试 + 指数退避**解析依赖，耗尽尝试预算后进入受控的 `:degraded` 态
    （进程存活、发 `gate_interface_degraded` observe 事件、继续应答查询），
    恢复通过 `retry_dependencies/1` 显式触发，而不是依赖监督树重启当重试。
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
订阅表必须保存 World 路由返回的区域、租约、owner 纪元和 Scene 节点；迁移后重绑定时，
连接进程会重新查询 World，并在新路由不同的时候重新向 Scene 订阅。

体素冲击意图也要先校验连接角色和服务端技能表，再经过 World 路由，最后由 Scene 带租约
执行写入并通过 DataService 持久化。这样 Gate 可以被观察为路由器和协议适配器，而不会
变成体素权威。
