# gate_server

正式文档已迁移到 `docs/` 目录。

- [2026-04-10-应用说明](docs/2026-04-10-应用说明.md)

2026-09-19 F09（只测试）：`tcp_connection_protocol_test.exs` 的体素订阅和旧 heightmap
拒绝用例改为复用实际 TCP 鉴权/进入场景报文，不再用 `:sys.replace_state` 设置会话。
鉴权及角色归属查询走真实 AuthWorker/DataService；场景接纳由文件内既有 FakePlayerManager
提供，不能把此测试称为真实 Scene 或双客户端验收。成功断言同时核对用户名、active_cid、
scene_ref、出生位置和输入序号，避免仅有 `status=:in_scene` 就让用例通过。
`MMO_DB_PORT=5433 mix test test/gate_server/tcp_connection_protocol_test.exs --no-start`
在独立测试数据库中 30 项通过。

后续两份 WebSocket 体素测试也已改为 `test/support/voxel_session.exs` 提供的正常报文接纳。
共同夹具通过 test_helper 加载，不互相依赖兄弟测试文件。账户、角色归属和 token 校验走真实
AuthWorker/DataService；Scene 接纳替身只接收已授权角色档案，体素裁决和数据库写入仍走原入口。
两份 WS 共 42 项通过；与 TCP 合跑 72 项通过，验证共享命名进程和测试数据库生命周期不冲突。
此处的 WS 验证直接驱动连接的 frame 入口，没有启动浏览器或真实 WebSocket 网络握手；
跨 region 测试仍是单 BEAM 的双区域组件集成，不称为跨节点或双客户端验收。

`smoke/` 下的 `GateServer.VoxelSmoke` 是 Test-only 的旧 WS 协议 smoke；通过真实鉴权/进场帧建立会话，
不再强设 `:in_scene` 或清空整套共享体素表。运行前准备实际角色，设置环境变量
`MMO_SMOKE_TOKEN`，再执行 `mix gate_server.voxel_smoke --username tester --cid 42`；
用户名、角色和 token 必须对应。测试可显式用 Scene 接纳替身，不能据此宣称 Voxim QUIC 双端验收。
`mix.exs` 只在 dev/test 编译 `smoke/` 及其 CLI、VoxelSmokeLocalInterface 和 Paths；prod 仅编译 `lib/`，
Gate 不通过 smoke 依赖引入 Auth；部署组合仍可独立包含正式 Auth 服务。
依据 [Mix 的 elixirc_paths](https://hexdocs.pm/mix/1.18.4/Mix.Tasks.Compile.Elixir.html)。
2026-09-19 已核对现有 test 的 `.app` 和 BEAM 包含四个 smoke 模块；
`../Voxim/Saved/EngineeringAudit/voxim-audit-materials-01/version.json` 指向的冻结 Linux prod 构建
在 Gate `.app` 与 BEAM 中均不包含它们。这是编译产物边界证据，不代表分发包或双客户端验收。
smoke 退订断言同时检查等候意图结果时已暂存的推送和后续 mailbox，避免漏报提前抵达的 delta。
本次 `MMO_DB_PORT=5433 mix test test/gate_server/voxel_smoke_test.exs --no-start` 三项通过。
独立 VM 的 `f09-smoke-unsubscribe-probe.exs` 仅临时导出已编译 smoke 的私有断言，
模拟观察队列中已收到 delta；旧 BEAM 复现漏报，新 BEAM 拒绝且仍接受空队列。
该故障 probe 不启动或修改游戏世界；脚本及红/绿日志在
`../Voxim/Saved/EngineeringAudit/20260919/f09-smoke-unsubscribe-*`。

旧 ChunkProcess 的场与迁移调用仍活跃。消费者通过具名 `storage_snapshot/1` 获取不可变 Storage，
不穿透 `debug_state` 或让跨模块闭包读取私有状态；这些旧接口不是 Voxim canonical owner。
