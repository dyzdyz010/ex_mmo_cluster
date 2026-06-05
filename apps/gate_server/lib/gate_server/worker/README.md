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
  - 每个浏览器 WebSocket 客户端的协议和会话进程；为本地移动 ACK 启动一个
    linked 高优先级发送进程，避免 ACK 被体素快照/批量下行消息堵在同一个
    GenServer 邮箱后面
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

浏览器本地玩家移动 ACK 使用同一条 WebSocket 传输和同一个 `0x8B` 二进制协议，
但发送路径从 `ws_connection.ex` 的普通会话邮箱拆到 linked ACK sender。ACK sender
只负责编码并把二进制帧交给 WebSocket owner；分区刷新、聊天区域更新和体素订阅维护仍
回到 `WsConnection` 会话进程异步执行。这样 ACK 不被 bulk/voxel 下行阻塞，同时 Gate
仍保持协议适配和订阅协调职责，不拥有移动权威状态。

移动输入上行也必须保持同样边界。`tcp_connection.ex`、`ws_connection.ex` 和 UDP
快速通道只能调用 `SceneServer.PlayerCharacter.submit_movement_input/2` 把输入写入
Scene 的移动输入缓冲；不能对 player actor 做每帧同步 call 或 cast。权威 tick、输入
重放、碰撞、AOI 快照和 `movement_ack` 仍全部由 Scene 的 `PlayerCharacter` 执行。
这个边界保证本地 60Hz 连续输入不会把 actor 邮箱变成输入队列，从而拖慢服务端 ACK。
