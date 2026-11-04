# data_service

PostgreSQL / Ecto 持久化应用，提供账号与角色数据、体素日志与页表等公共存储边界。

## 当前运行时

`DataService.Application` 启动：

- `DataService.Repo`
- `DataService.DispatcherSup`
- `DataService.UidGenerator`

## 体素持久化

当前 SQL 存储由 `DataService.Voxel.OverlayLogStore` 与 `DataService.Voxel.PageStore` 提供；
`VoxelRegion.World` 拥有体素权威提交。存储契约、旧 chunk 链路退出边界与测试世界清理见
[DataService 体素边界](lib/data_service/voxel/README.md)。

## 历史参考

- [2026-04-10-应用说明](docs/2026-04-10-应用说明.md)（历史设计，不作为当前运行时事实）
