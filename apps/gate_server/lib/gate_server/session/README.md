# Gate 会话层（传输无关）

本目录是 Gate **会话语义的唯一所有者**：一条客户端连接从鉴权、进场、移动、聊天、技能到
体素意图的全部行为都在这里定义，TCP 与 WebSocket 两条链路共用同一份实现。

设立本目录之前，`worker/tcp_connection.ex` 与 `worker/ws_connection.ex` 是两份逐字镜像
（约 2000 行重复），任何修复都要人工同步两遍——`VoxelIntentResult` 的 `authoritative`
透传（幽灵块点修通道）就曾只打在 TCP 一侧，WS 静默漂移了整整一个阶段。

## 模块职责

| 模块 | 职责 | 唯一性 |
|---|---|---|
| `sink.ex` | 出站传输契约：编码后往哪写、observe 事件名前缀 | 两条链路**唯一**的真实差异 |
| `dispatch.ex` | 上行消息的会话状态机与分发 | 会话语义唯一入口 |
| `auth.ex` | token / cid / 角色档案 | Gate 侧唯一鉴权信任边界 |
| `scene.ex` | scene 节点发现、进场、移动输入、快照归一 | 与 Scene 协作的唯一契约面 |
| `call.ex` | 跨进程调用，exit → 显式 error | 会话调用超时的唯一定义 |
| `observe.ex` | 结构化调试字段构造（含下行 payload 解码） | CLI / 日志字段唯一来源 |
| `debug_probe.ex` | `0x6E VoxelDebugProbe` 命令执行 | 非 GUI 调试面唯一入口 |

体素意图的执行管线在 `../voxel/`（`intent_pipeline.ex` / `prefab_placement.ex` /
`result_frame.ex` / `subscribe_intent.ex`），由 `dispatch.ex` 调用。

## state 契约

`Dispatch.handle/2` 只读写下列键，不碰传输私有字段（socket / owner_pid / egress / udp_peer）：

`:sink` `:status` `:cid` `:scene_ref` `:agent` `:token` `:auth_claims` `:auth_username`
`:auth_session_id` `:voxel_worker` `:fast_lane`（`:enabled` 时还需 `:udp_ticket`）。

传输能力的差异用 **state 里的显式字段**表达，不用「两份分支各写各的」表达：浏览器没有
UDP 快车道，就是 `fast_lane: :unsupported`，由共享 dispatch 显式回错误帧。

## observe 事件命名

事件名由业务侧给出，前缀由 sink 决定：TCP 无前缀、WS 加 `ws_`（例如 `voxel_edit_intent_applied`
与 `ws_voxel_edit_intent_applied`）。历史上两侧都带自己传输名的移动三事件走
`Sink.emit_transport_tagged/3`，得到 `tcp_movement_received` / `ws_movement_received`。

## 加新功能时

1. 新的上行消息 → 加 `dispatch.ex` 的 clause，两条链路同时生效。
2. 新的下行帧 → 经 `Sink.send_encoded/2`（需编码）或 `Sink.send_raw/2`（生产方已含 opcode）。
3. 新的调试字段 → 加 `observe.ex`，不要在连接进程里就地拼 map。
4. 只属于某条传输的行为 → 留在 `worker/` 对应连接进程，并在 state 里加显式能力字段。

## G1 当前字节边界

`Dispatch.decode/1` 与 `Sink.encode/1` 在现有组合边界直接调用 `MmoContracts.Session.Codec` / `MmoContracts.Voxel.Codec`；
各领域 guard 唯一定义 opcode/tag 归属，selector 不实现字节规则。TCP/WS 使用同一上行 selector，`send_encoded/2` 使用同一下行 selector。
`GateServer.Codec` 仅处理尚有活调用方的旧移动、fast-lane、NPC/战斗、Scene 等领域；UDP 仍用它处理旧 fast-lane。
没有新传输行为，也没有 Gate→Scene 的新 Movement struct 依赖。Sink 完成纯 codec 接线后交 T1 继续传输实施。
