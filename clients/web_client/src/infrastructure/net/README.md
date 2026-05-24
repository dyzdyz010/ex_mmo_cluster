# Net (infrastructure)

职责：

- 维护体素协议 opcode、codec，以及 `MovementTransport` 的具体适配器。
- 浏览器侧网络接入必须保留 CLI/observe 可观测面，至少能读到 transport mode、订阅状态、消息收发与错误原因。

结构：

- `opcodes.ts` / `gateProtocol.ts` — movement 纯 codec，把线格式映射到 `@domain/movement/types` 里的契约类型。
- `voxelProtocol.ts` — server-authoritative voxel S1 codec，负责编码 `ChunkSubscribe` / `VoxelImpactIntent` / `FieldConductIntent` / `VoxelDebugProbe`，解码 `ChunkSnapshot` / `VoxelIntentResult` / `VoxelDebugProbe`。
- `simulatedMovementTransport.ts` — 离线仿真适配器，本地输入按顺序立即合成 ack；不再生成装饰性远端 actor，避免把本地 fallback 误看成真实 NPC/AOI。
- `serverMovementTransport.ts` — 真实 WebSocket 适配器；握手失败或 ready 前断开时保持 `server-ws` 但标记 `connectionStatus=disconnected`，把原因写进 observe/HUD/CLI；同一个 socket 也提供薄 voxel transport port，供网页体素同步层复用。HTTP auth/dev_seed 默认走 Vite `/ingame` 同源代理；WebSocket 默认读取 `VITE_GAME_WS_URL`（兼容旧的 `VITE_WS_URL`），未配置时走当前 host 的 `/ingame/ws`。

当前阶段：

- movement 已接入真实浏览器 transport：`auth_server /ingame/ws` -> `AuthServerWeb.GameWebSocket` -> `GateServer.WsConnection`。
- `clients/web_client` 默认使用 `server-ws`；可通过 `VITE_MOVEMENT_TRANSPORT=simulated` 强制使用 simulated-local。
- movement 协议当前会解码 `MovementAck` / `PlayerMove` 的 `movement_mode`，并把服务端坐标 `(x,y,z)` 转成浏览器坐标 `(x,z,y)`；跳跃的竖直轴在浏览器中是 `Vector3.y`。`PlayerState(0x8C)` 会进入 observe/CLI 快照；其他已知但浏览器暂未消费的下行帧会记录为 `known_downlink_unhandled`，不应被记为 `message_ignored`。
- 体素协议 `0x60..0x75` 已接入 S1：`ChunkSubscribe -> ChunkSnapshot/ChunkDelta`、`VoxelImpactIntent -> VoxelIntentResult`、break sentinel、`PrefabPlaceIntent` v1、`VoxelDebugProbe` 和 `FieldConductIntent(0x75)`。
  放电类 field action 默认走已连接的 WebSocket intent 通道；客户端提交后只登记待表现请求，必须收到服务端 `FieldRegionSnapshot(0x73)` 后才渲染闪电。
  当前 canonical 设计见 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`：
  `SceneServer.Voxel.*` 持有 hot chunk truth，voxel payload 统一 big-endian，
  server v1 使用 `MicroPerMacro=8` 和 512-bit refined occupancy。玩家侧 movement/skill
  表现可以本地预测或预演；体素 confirmed data 只能由服务器 snapshot/delta/result 更新。

约束：

- 本目录实现 domain 定义的 port (`@domain/movement/transport`)，不能反向让 domain 依赖这里。

`serverMovementTransport.debugSnapshot()` / `voxelDebugSnapshot()` 必须能被 `window.__voxelCli.run("transport")` 直接读取到收发状态。voxel 字段现在包含 `receivedVoxelSnapshotCount`、`receivedVoxelDeltaCount`、`receivedVoxelInvalidateCount`、`receivedVoxelIntentResultCount` 和 `lastDelta`，用于从 CLI 判断 ChunkDelta 是否已到达，而不依赖画面判断。
