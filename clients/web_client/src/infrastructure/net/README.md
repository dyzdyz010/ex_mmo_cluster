# Net (infrastructure)

职责：

- 维护体素协议 opcode、codec，以及 `MovementTransport` 的具体适配器。
- 浏览器侧网络接入必须保留 CLI/observe 可观测面，至少能读到 transport mode、订阅状态、消息收发与错误原因。

结构：

- `opcodes.ts` / `gateProtocol.ts` — 纯 codec，把线格式映射到 `@domain/movement/types` 里的契约类型。
- `simulatedMovementTransport.ts` — 离线仿真适配器，本地输入按顺序立即合成 ack；不再生成装饰性远端 actor，避免把本地 fallback 误看成真实 NPC/AOI。
- `serverMovementTransport.ts` — 真实 WebSocket 适配器，握手失败或 ready 前断开会内嵌回退到 simulated-local，并把原因写进 observe/HUD/CLI。

当前阶段：

- movement 已接入真实浏览器 transport：`auth_server /ingame/ws` -> `AuthServerWeb.GameWebSocket` -> `GateServer.WsConnection`。
- `clients/web_client` 默认优先尝试 `server-ws`；可通过 `VITE_MOVEMENT_TRANSPORT=simulated` 强制使用 simulated-local。
- movement 协议当前会解码 `MovementAck` / `PlayerMove` 的 `movement_mode`，并把服务端坐标 `(x,y,z)` 转成浏览器坐标 `(x,z,y)`；跳跃的竖直轴在浏览器中是 `Vector3.y`。
- 体素协议 `0x60..0x6F` 仍主要保留 opcode 与接口边界，真实 chunk subscribe / snapshot / delta / edit ack 流还未接到服务端。
  当前 canonical 设计见 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`：
  `SceneServer.Voxel.*` 持有 hot chunk truth，voxel payload 统一 big-endian，
  server v1 使用 `MicroPerMacro=8` 和 512-bit refined occupancy。玩家侧 movement/skill
  表现可以本地预测或预演；体素 confirmed data 只能由服务器 snapshot/delta/result 更新。

约束：

- 本目录实现 domain 定义的 port (`@domain/movement/transport`)，不能反向让 domain 依赖这里。
