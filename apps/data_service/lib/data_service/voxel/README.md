# DataService 体素边界

`DataService.Voxel.OverlayLogStore` 是 Voxim region 世界的权威 overlay 日志表（`voxel_overlay_log`）：
`VoxelRegion.World` 的事务按条目追加成行、启动时按 `(seq, ordinal)` 重放、压实时在一个数据库事务里替换成检查点，
按 `content_version` 隔离。行格式见 `VoxelRegion.OverlayLog`。

旧 chunk 链路的快照、写入令牌、租约目录、事务协调、命令日志与 outbox 存储已于 2026-09-30 删除；
它们的迁移文件与已建表保留在数据库迁移历史中，未执行删表。
