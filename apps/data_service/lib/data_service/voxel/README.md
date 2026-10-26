# DataService 体素边界

`DataService.Voxel.OverlayLogStore` 是 Voxim region 世界的权威 overlay 日志表（`voxel_overlay_log`）：
`VoxelRegion.World` 的事务按条目追加成行、启动时按 `(seq, ordinal)` 重放、压实时在一个数据库事务里替换成检查点，
按 `content_version` 隔离。行格式见 `VoxelRegion.OverlayLog`。

旧 chunk 链路的快照、写入令牌、租约目录、事务协调、命令日志与 outbox 存储已于 2026-09-30 删除；
它们的迁移文件与已建表保留在数据库迁移历史中，未执行删表。

`DataService.Voxel.PageStore` 是页表（M2a：`voxel_page_segment` / `voxel_world_globals` / `voxel_safe_prefix`，连续写回与安全前缀）
与 M2b 的按需装页读取：`load_head/3`（启动只读前缀、全局行、日志后缀与活动索引）、`read_pages/4`（按页键读当前前缀下的可见段，
L1–L5 的 structure / 树冠片段按 `(level, L0 页)` 行键随 L0 页或粗层页读出）、`locate/3`（身份定位表 `voxel_identity_locator`：
实例 / 有主附件 id → 根实例与根 home 页，只插入，随切点批次与页段同一事务写入）、`page_keys/2`（维护入口装全部页）。
段内容与归属只由 `VoxelRegion.World.Pages` 解释。设计稿：`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2b-on-demand-pages.md`。
