# world_server

正式文档已迁移到 `docs/` 目录。

- [2026-04-10-应用说明](docs/2026-04-10-应用说明.md)

## 运行时边界

`WorldServer.WorldSup` 当前启动：

- `WorldServer.Voxel.MapLedger`
- `WorldServer.Voxel.TransactionCoordinator`

`MapLedger` 拥有体素区域分配、租约签发、向 DataService 发布写入令牌、区块路由，以及
按租约计算事务参与者的职责。它还保存迁移计划，按“预热、切换、完成”的阶段推进地块
拥有者变更；迁移预热切片是按区块坐标轴和宽度拆出的连续区块范围，用来让目标 Scene
分批加载交接数据，避免一次性迁移整个区域。

`TransactionCoordinator` 记录准备确认以及提交 / 放弃决策。WorldServer 仍然不保存完整
区块真相，也不执行逐帧体素规则；SceneServer 仍然是已租约区域的热执行拥有者。

## CLI 观测验收

World 侧体素权威可以不经过 GUI 直接验收：

```bash
mix world_server.voxel_observe --logical-scene-id 1
```

默认情况下，该任务会重写 `.demo/observe/world-voxel-authority-<logical_scene_id>.log`。
可以用 `--observe-dir <dir>` 或 `--observe-log <path>` 改写结构化日志位置。

这条验收流会发布区域租约、路由区块、生成全部迁移预热切片（迁移前目标 Scene 分批加载的
区块范围）、读取迁移交接载荷、切换到新的 Scene 实例，并记录旧写入令牌和当前写入令牌在
WorldServer 与 DataService 两侧的校验结果。World 只有在全部预热切片已经规划后，才允许把
迁移标记为已预热。
