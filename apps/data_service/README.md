# data_service

正式文档已迁移到 `docs/` 目录。

- [2026-04-10-应用说明](docs/2026-04-10-应用说明.md)

## 体素持久化栅栏

`DataService.Application` 启动：

- `DataService.Voxel.WriteTokenStore`
- `DataService.Voxel.ChunkSnapshotStore`

`WriteTokenStore` 保存每个体素区域当前由 World 发放的写入令牌，并通过
`lease_id + owner_scene_instance_ref + owner_epoch` 校验区块写入。这里的
写入令牌就是“当前谁可以写这个区域”的围栏数据，旧 Scene 持有的过期令牌会被拒绝。

`ChunkSnapshotStore` 在这道围栏之后保存区块快照载荷的第一版内存实现。后续替换为
PostgreSQL 表时，Scene 写入仍然必须先通过同一组令牌字段校验，迁移期间的旧拥有者
不能覆盖新拥有者的数据。
