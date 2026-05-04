# Web Client Browser Transport Gap (2026-04-21)

## 结论

当前仓库已经有可供浏览器 `clients/web_client` 直接复用的游戏 WebSocket bridge。本文最初记录的是
2026-04-21 的 movement-only 缺口；截至当前实现，该 bridge 已扩展到 **movement/auth/enter-scene +
server-authoritative voxel S1**。

现状是：

1. `gate_server` 仍然以 raw TCP/UDP 作为游戏传输面。
2. `auth_server` 现在同时提供：
   - `POST /ingame/auto_login`
   - `GET /ingame/ws`
3. `/ingame/ws` 通过 `AuthServerWeb.GameWebSocket` 把浏览器二进制帧桥接到 `GateServer.WsConnection`。
4. 该桥接链已经能跑通 `auth -> enter-scene -> movement_ack -> player_move`。
5. `visualize_server` 的 WebSocket 仍然只是 Phoenix LiveView 场景可视化，不承担游戏 transport。
6. 体素协议 `0x60..0x6F` 的服务端权威第一版规范见 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`；网页客户端已接入 `ChunkSubscribe / ChunkSnapshot / VoxelImpactIntent / VoxelIntentResult / VoxelDebugProbe`，`ChunkDelta` 与 prefab intent 后续再补。

因此网页客户端当前阶段采用“movement 在线 + voxel 服务端权威 S1 + 可显式离线回退”的验证策略：

1. **真实 server-ws movement 闭环**
   - auto_login
   - websocket upgrade
   - auth / enter-scene
   - movement ack / remote snapshot
2. **server-authoritative voxel S1 闭环**
   - dev seed 准备 World lease 和 DataService 写入令牌
   - `ChunkSubscribe -> ChunkSnapshot` 应用权威 chunk
   - `VoxelImpactIntent -> VoxelIntentResult` 提交宏格放置
   - HUD + `window.__voxelCli` + 结构化 observe 日志
3. **回退路径**
   - 当真实 backend 在 ready 前失败时，自动回退到 `simulated-local`
   - 保证 `preview` / 脱机调试 / 后端未启动时仍能验浏览器运行时

后续继续补：

1. `ChunkDelta`、break intent、prefab intent 与多 chunk 自适应订阅
2. Gate 按 World 路由 owner 精确选择 Scene 节点，而不是当前单节点 Scene path

## 已核对的仓库事实

- `apps/auth_server/lib/auth_server_web/controllers/game_socket_controller.ex`
- `apps/auth_server/lib/auth_server_web/game_web_socket.ex`
- `apps/gate_server/lib/gate_server/worker/tcp_acceptor.ex`
- `apps/gate_server/lib/gate_server/worker/udp_acceptor.ex`
- `apps/gate_server/lib/gate_server/worker/ws_connection.ex`
- `apps/gate_server/lib/gate_server/codec.ex`
- `apps/auth_server/lib/auth_server_web/controllers/ingame_controller.ex`
- `apps/auth_server/lib/auth_server_web/router.ex`
- `apps/visualize_server/lib/visualize_server_web/endpoint.ex`
- `apps/visualize_server/lib/visualize_server_web/live/scene_live/index.ex`
- `docs/2026-04-10-传输协议现状与后续规划.md`
- `docs/2026-04-17-上线-Docker-CI-部署方案.md`
- `scripts/run_ws_dual_smoke_supervised.js`

## 当前实现策略

本仓库中的 `clients/web_client` 当前策略应表述为：

1. 已接真实 browser movement transport，并保留 CLI/observe 调试面
2. 默认 voxel 世界为 `server-authoritative`，`VITE_VOXEL_SYNC=offline` 才进入离线本地模式
3. 真实 movement backend 不可用时，自动回退到 `simulated-local`
4. 继续把浏览器端世界作为 movement 与 voxel 协同调试承载层维护好
