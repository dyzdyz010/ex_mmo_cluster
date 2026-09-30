# world_server

2026-09-19 测试边界整改：`test/world_server/movement` 验证当前 Voxim 的 World 路由、
跨 Scene 移交与双节点邻区编排；这些测试调用 World API，故从 Scene app 迁入。
`test/support/movement_fixture.exs` 每个用例复制参数到独立临时目录，使用当前 kernel 创建
新世界，不修改发布 manifest、不共享日志、不手工拼 BEAM 路径。
单 app 运行用 `elixir --sname world_tests -S mix test --no-start`；需要命名节点的用例明确检查此条件。
普通路由及纯值测试不启动数据库，持久化测试才调用共享 `MmoTest.Database.start!`。

正式文档已迁移到 `docs/` 目录。

- [2026-04-10-应用说明](docs/2026-04-10-应用说明.md)

## 运行时边界

`WorldServer.Movement` 按 `:movement_routes` 把 scene_id 解析到 Scene 与 canonical `VoxelRegion.World`，并在控制面连接相邻 Scene。
配置了拓扑文件（`VOXIM_TOPOLOGY` → `:world_server, :topology`）时，`WorldServer.Application` 启动 `WorldServer.Topology`：
按文件在本节点起本地 Scene（可经本地 Replica）、用 `:peer` 在本机起 Scene 节点，写路由、连接相邻 Scene，全部就绪后应用才启动完毕，
Auth / Gate 因运行时依赖排在其后。拓扑格式与部署见仓库根 `deploy/README.md`；测试 `test/world_server/topology_test.exs`。
旧的区域租约、跨 chunk 事务协调与 world pack 链路（MapLedger、TransactionCoordinator 等）已于 2026-09-30 随旧客户端删除。
