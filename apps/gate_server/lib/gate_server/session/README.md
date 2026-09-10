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

## Voxim M3 QUIC 快照合包

入场时 listener 调用 `Scene.join/4`，将返回的唯一 Player PID 随 identity 交给连接保存。
此后 InputBatch、Ready 与 TimeProbe 直接走 `SceneServer.Movement.Player` 的公开 API；
不会逐输入经过 Scene 邮箱。Scene.leave 仍负责撤销成员，listener 先旧 leave 后新 join，
旧 epoch 的输入/输出不能影响新路由。鉴权、角色归属和 wire decoder 仍在 Gate 完成。

`quic_connection.ex` 拥有每连接的异步可靠流与可替换 datagram 队列。Snapshot 按实体替换尚未提交的旧记录，
以 `{首次入队序号, entity_id}` 为有序树键；替换保留原次序和等待起点，发送后再次到达才进队尾。
因此持续更新不会让已发送的低 ID 在每个 tick 重新插队，饿死高 ID。entity → key 索引不成为 AOI 真值。
OwnerAck 在树中单独置于快照之前，仍逐包获取 native 发送进展；Control / Voxel 的可靠队列与之隔离。

相同 identity / server_tick 的相邻待发记录合包，仅在包内按 entity_id 排序后通过 `MmoContracts.Movement.Codec` 编码。
每个候选包都以完整 envelope 的实际字节数与 quicer `dgram_max_len` 比较；没有固定每包实体数或额外 1200 字节上限。
包容不下的记录留在原队列。不同 tick 不混装；entity_epoch、interest_generation、collision_revision、state 均保留原值，
其中 revision 是 record 字段，允许同一实际 tick 的记录携带不同 revision。生命周期继续可靠发送，AOI / 客户端继续拥有 generation 接纳规则。

依据 [RFC 9221 §5](https://datatracker.ietf.org/doc/html/rfc9221#section-5)：DATAGRAM 不分片，必须遵守实际路径/协商大小；
使用 [OTP gb_trees](https://www.erlang.org/docs/27/apps/stdlib/gb_trees.html) 的有序迭代与删除，消除原来每发一条记录扫描整个 map 的成本。
此队列只对现有不可变记录调度，不改变 wire、20 Hz 发布频率或可靠性。编码尝试限制在一个 datagram 的容量内，未建立通用优先级调度框架。

公开 `:stats` 增加累计 `snapshot_records_sent`、`snapshot_datagrams_sent`、`snapshot_bytes_sent`，
可取窗口差值测量 records/s、datagrams/s 与编码负载字节；它们计 native 提交，不能当作客户端实际收到的记录数。
既有 `datagrams_sent` 包含 OwnerAck。字节统计不含 QUIC/IP 开销。

独立 VM / 真实 QUIC probe（不启动 Scene、不部署共享服务）：在 Voxim 执行
`python Docs/M3/tools/gate-run.py --out Docs/M3/runtime/gate-check`；加 `--batching` 只跑合包用例。
该入口验证实际协商上限、恰好装满/差一字节、剩余单条、替换后的 tick / revision / generation、ACK 优先和可靠流。
真实 20 / 200 人集成吞吐与 ACK 进展仍由 Voxim M3 运行验收记录。

## Voxim M4a 受控移交

`QuicConnection` 在收到当前 Player 的越界请求后同步 `Player.seal/2`，使先前输入与 seal
来自同一 Gate 发送者。listener 经现有 `route_module` 调用 World prepare，先预留新 session epoch，
角色表仍保持旧 identity。连接可靠发送 `Session.Transfer`，等待客户端按切点 Fence、N/R 完成重绑。
等待期间旧、新 identity 的 InputBatch 都改绑到被动目标 Player，datagram 与 control stream 共用同一入口；
不再向源发送输入，不重编号输入序列或 tick，其他身份只计入 stale_identity。

匹配新 identity 与移交 N/R 的 Ready 才触发 listener commit。listener 以 Gate PID 与旧 identity
比较当前角色 owner，World 完成源 detach / 目标 activate 后才更新 owner identity / scene_ref。
重复登录改变 owner 会使旧 Gate prepare / commit 明确失败；连接结束显式清理源与待提交目标，
Player 对 Gate 的 monitor 还负责连接退出后的生命周期清理。旧 Ready、错误 N/R 与提交后重复 Ready
明确关闭连接，不能二次激活。目标输出在提交返回后按新身份接纳；旧输入和旧输出被隔离。

提交清空旧待发 datagram 和 snapshot 索引，但保留 `datagram_busy`，由真实 native sent 事件释放发送槽。
旧 Fence 在等待期间仍可正常下行，可靠 Control 与 Voxel 两条流不假设相互到达顺序。
依据 [OTP Processes: Signals](https://www.erlang.org/doc/system/ref_man_processes.html#signals)
的同发送者顺序语义，seal 必须由转发输入的 Gate 发起；listener 的单邮箱完成角色归属比较和提交，
不新增第二份 authority 目录。World / Scene 拥有目标准备与碰撞一致性，Gate 不复制该校验。

`:stats` 提供 `transfer_prepared`、`transfer_committed`、`transfer_pending_inputs`、`transfer_last_us`，
以及 `pending_transfer` 的新 identity、切点 tick / seq、N/R、输入批次数与等待微秒数。
`mmo_transfer_prepare` / `mmo_transfer_commit` 日志记录旧/新 Scene 与 epoch、切点、N/R、
单调时间与等待输入样本数，不记录 Join token。时间是 Gate 本地 monotonic，不能拿跨 VM 原值相减。

最小测试为现有 `test/gate_server/quic_connection_test.exs` 的 `M4aGateTransferTest`，
纯 callback 测试不启动 QUIC / Scene 服务，覆盖 seal→prepare、等待输入、Ready、owner CAS 和旧输出隔离。
真实 QUIC 与双 UE 移交仍由 Voxim M4a 集成入口验证，callback 通过不代表运行验收。

M4a 并发编辑实跑发现：冷区域的 `World.prepare` 耗时曾占住 Gate 会话约 30 秒，连 Player 的移交请求都只能排在其后。
现在普通单格、批次与 Prefab 的 `Dispatch.handle/2` 均由连接首次编辑时懒启动的一个 linked worker 串行执行；
Gate 完成既有连接身份、Scene 标签与 bounds 接纳后，只投递已经接纳的请求与不可变 context。
worker 共用原 Dispatch、World 和 Sink，不分配事务或复制写入逻辑；连接 `terminate` 会结束 worker，异常退出也由 link 结束该连接。
Prefab 的 footprint / instance 坐标权限查询仍在 Gate，尚未改变该现有接纳边界。

编辑回执的 `Sink.quic` 使用连接独有 `make_ref`，在正常 Scene 移交中保持不变；新连接重新生成，closing 状态拒收回执。
Movement、Player 下行仍严格匹配 Session.Identity，编辑回执的连接归属不使旧运动身份重新有效。
`stats` 增加 `edit_pending`、`edit_completed`、`edit_queue_wait_us`、`edit_worker_us`，后两项是连接内观测最大值；
`mmo_edit_completed` 逐请求记录原 request_id / scene_id、排队及 worker 微秒数，排队与实际编辑耗时分别可见。

依据 [RFC 9000 §2](https://www.rfc-editor.org/rfc/rfc9000.html#section-2)，QUIC 流内有序而流间没有全局到达顺序。
Ready 在 control、编辑在 voxel，因此目标 Scene 编辑可能先到，旧 Scene 编辑也可能在 Ready 提交后才到。
当前 M4a 明确只有两个共用 canonical World 与 L0/bounds 的 Scene：连接接纳 current、pending 目标及本次提交的
`previous_scene_id` 标签，第三 Scene 与越界坐标照常拒绝；previous 只保留一个标量，重连清空。
该标签只容纳同一已鉴权角色连接的迟到编辑，执行仍路由到已验证的唯一 World；不用于运动输入路由。
未来扩展多 Scene 时须重新定义 voxel 标签语义，本轮不建立历史身份列表或标签退休状态机。

单 worker 的 FIFO 与回执→完成事件顺序直接使用 [OTP 同发送者顺序](https://www.erlang.org/doc/system/ref_man_processes.html#signals)。
`M4aGateTransferTest` 在真实 Dispatch / World.prepare 入口用测试 source 栅栏阻塞编辑，验证 Gate 在其间继续处理输入与 Ready、
批次 FIFO、移交后回执、closing / 新连接隔离，并覆盖跨流新旧标签、第三 Scene 与 bounds 拒绝。
复现：在 Voxim 运行 `python Docs/M4a/tools/test.py --gate --out Saved/M4a/edit-worker-repeat voxim_aoi`；
改前 Gate 阻塞见 `Saved/M4a/edit-worker-red`，跨流标签改前失败见 `Saved/M4a/edit-scene-red`，最终定向回归 `edit-scene-green` 为 18/18。
