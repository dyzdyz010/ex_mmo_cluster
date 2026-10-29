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

## 测试世界清理

`OverlayLogStore.reset/1` 清空全部测试世界；`reset_world/2` 仅清指定 `content_version`，
两者共用日志、页段、全局行、安全前缀和身份定位五表清单。定位记录在运行时仍只增不删；
这里退休的是整个测试世界，必须删除旧定位，否则同世界／同身份重新创建时 `ON CONFLICT DO NOTHING` 会保留旧 home。
迁移文件仅澄清此生命周期差别，没有新增或修改数据库结构。

依据 [PostgreSQL DELETE 官方语义](https://www.postgresql.org/docs/16/sql-delete.html)：带世界谓词只删除匹配行，
不带谓词删除全表；沿用既有清理入口，不增加生产路径或改变运行时身份删除规则。

最小集成验证：在本次 VM 独占的新测试库内，经 `PageStore.publish/write` 建立两世界的实例／附件定位、
页、全局行、发布前缀、日志后缀及未发布定位；通过公开清理入口判定目标清空、另一世界逐项保留、同身份可指向新 home。
覆盖负 XYZ 与最高位为 1 的 u64 世界号，不启动 World、Gate 或客户端，不证明真实玩家链路或迁移恢复性能。

命令（本 app，配置隔离 PG 后）：`MIX_ENV=test mix test --no-start test/data_service/voxel/overlay_log_store_test.exs`。
`MmoTest.Database` 默认生成 VM 独占库并在结束时删库；不要传已有业务库的 `MMO_TEST_DB_NAME`。
2026-10-27 证据：`.demo/observe/m2b-hardening-20261027/`，改前两个定位清空断言失败（3/5），改后 5/5；
隔离容器 `voxim-pg-paging1024:26810`，未写其基准库，测试库已删除，容器已停止。
