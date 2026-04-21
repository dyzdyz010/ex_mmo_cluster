# Net

职责：

- 维护体素协议 opcode、codec、transport 和 session runtime。
- 浏览器侧网络接入必须保留 CLI/observe 可观测面，至少能读到 transport mode、订阅状态、消息收发与错误原因。

当前阶段：

- movement 已接入真实浏览器 transport：`auth_server /ingame/ws` -> `AuthServerWeb.GameWebSocket` -> `GateServer.WsConnection`。
- `clients/web_client` 默认优先尝试 `server-ws`；若在 ready 前 bootstrap / auth / enter-scene 失败，会自动回退到 `simulated-local`，并把原因写进 observe/HUD/CLI。
- 体素协议 `0x60..0x6F` 仍主要保留 opcode 与接口边界，真实 chunk subscribe / snapshot / delta / edit ack 流还未接到服务端。
