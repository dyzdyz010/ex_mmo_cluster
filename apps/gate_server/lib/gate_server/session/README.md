# Gate 会话层

本目录定义 Voxim QUIC 会话：`quic_connection.ex` 负责鉴权、入场、输入与出站字节，体素意图经连接懒启动的一个
linked 编辑 worker 串行执行。

| 模块 | 职责 |
|---|---|
| `quic_connection.ex` | QUIC 连接进程：按通道选 codec 解码，路由移动输入与体素意图 |
| `dispatch.ex` | 体素意图（工具、生产、附件、Prefab、施法、编辑）转给 `VoxelRegion.World` 并回执 |
| `sink.ex` | 出站契约：按现行领域 codec 编码后交给连接 owner |
| `auth.ex` | token / cid / 角色档案，Gate 侧唯一鉴权信任边界 |
| `claims.ex` | 会话身份与 epoch 分配 |
| `call.ex` | 跨进程调用，exit → 显式 error |

B2 的 Ready 前材料库存查询与作者权限拒绝测试属于本会话边界，位于
`test/gate_server/voxim_production_dispatch_test.exs`（只测试）。它调用真实 Dispatch、Sink 和 World，
利用 Gate 已有的 `voxel_region` 依赖，不让 World 测试反向依赖 Gate。
在 `apps/gate_server` 执行 `MMO_DB_PORT=5433 mix test test/gate_server/voxim_production_dispatch_test.exs --no-start --seed 0`。

## Voxim M3 QUIC 快照合包

### 公网 QUIC 包长约束（全局系统功能）

`Transport.QuicListener` 在创建 MsQuic 配置时统一设置 `minimum_mtu=1248`、`maximum_mtu=1252`（IP 包长；IPv4 UDP 载荷最多 1224 B），
并在 listener 启动日志记录端口与该值。新连接、重新连接和服务重启均从这一处取得限制，包含 PMTU 探测与正常数据发送。
可靠 Control / Voxel 流由 QUIC 自动分包；下面的 DATAGRAM 队列仍使用 native 通知的 `dgram_max_len`，不复制一个应用层包长常量。

依据 [RFC 9000 §14](https://www.rfc-editor.org/rfc/rfc9000.html#section-14) 的避免 IP 分片要求，以及
[MsQuic Settings](https://github.com/microsoft/msquic/blob/main/docs/Settings.md) 对 `MaximumMtu`（含 IP / UDP 头）的定义。
2026-09-15 公网实测大包 DF 被清除，重复 IPv4 ID 导致不同 UDP 包头尾错拼；1252 → 1500 → 1252 的真实 Mixed TUN
入场对照分别收到 0 / 619 / 0 个校验错误包。详见 Voxim `Docs/Playtest/udp-path-investigation.md`。
该约束以每份数据需要更多 UDP 包为代价，保证当前已复现路径上的可靠传输；不修改消息格式、世界语义、发布频率或重试策略。
初始 MTU 显式使用 QUIC 1200 B 最小载荷加 IPv6 / UDP 头的 1248 B，避免仅限制探测上限时握手仍使用库的较大默认初始值。
Voxim 的 `FMmoQuicConnection` 同时限制客户端初始 / 最大 MTU，覆盖双向握手与上行探测；只改服务端的版本曾捕获到 1260 B UDP 握手包，因此配套客户端必须一并使用新的传输配置。

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
