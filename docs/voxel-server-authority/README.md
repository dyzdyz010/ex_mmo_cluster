# 体素服务器权威化 — 实施跟踪

本目录用于跟踪"体素全面服务器权威化"长期工作的计划与执行进度。每个阶段(Phase)对应一份独立的计划文件,文件内含进度日志,完成后归档。

## 起点参考

- 架构现状与缺口分析:[`docs/2026-05-07-体素服务器权威化架构进度检查.md`](../2026-05-07-体素服务器权威化架构进度检查.md)
- 协议规范:[`docs/2026-04-10-线协议规范.md`](../2026-04-10-线协议规范.md)
- 服务端权威体素数据协议设计:[`docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`](../2026-04-29-server-authoritative-voxel-data-protocol-design.md)
- 联调状态:[`docs/2026-05-06-服务端权威体素联调状态.md`](../2026-05-06-服务端权威体素联调状态.md)

## 阶段总览

将原文档的 Phase 1 拆分为四个更小可交付的切片,Phase 2 起按原文档命名沿用。

| 阶段 | 范围 | 状态 | 计划文件 |
| --- | --- | --- | --- |
| 1a | RefinedCellData typed domain (read-only wire) | 已完成 | [`phase-1a-refined-cell-domain.md`](./phase-1a-refined-cell-domain.md) |
| 1b | typed `VoxelEditIntent` (decode-only) + `VoxelImpactIntent` 进入 deprecation | 已完成 | [`phase-1b-typed-edit-intent.md`](./phase-1b-typed-edit-intent.md) |
| 1c | Scene refined mutation API + `CellRefined` delta | 已完成 | [`phase-1c-refined-mutation.md`](./phase-1c-refined-mutation.md) |
| 1d | DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | [`phase-1d-canonical-persistence.md`](./phase-1d-canonical-persistence.md) |
| 2 | (原文档 Phase 2)refined micro edit 端到端贯通 | 已完成(被 1c 吸收) | [`phase-2-micro-edit-roundtrip.md`](./phase-2-micro-edit-roundtrip.md) |
| 3 | prefab v2 事务化(World/Scene transaction coordinator) | 未开始 | — |
| 4 | object provenance 与局部破坏 | 未开始 | — |
| 5 | 属性目录 + 温湿度基础模拟 | 未开始 | — |

状态取值:`未开始` / `进行中` / `已完成` / `已搁置`。状态变更时同步更新本表与对应阶段文件的 `进度日志`。

## 跟踪约定

- **一阶段一文件**:每个阶段开始前先建 `phase-<id>-<slug>.md`,内含目标、范围、文件清单、改动点、测试矩阵、验收标准、进度日志。
- **进度日志按时间倒序追加**:每次推进、卡点、决策都补一行 `YYYY-MM-DD: ...`。
- **不要把行为变更与 README 索引耦合**:索引只反映阶段状态,具体决策与变更证据写在阶段文件里。
- **完成后不删除文件**:状态改为 `已完成`,留作后续阶段查证依据。
