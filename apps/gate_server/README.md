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
