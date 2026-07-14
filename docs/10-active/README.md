# 10-active · 活跃工作

**正在执行、下一步就做、或让路待恢复**的决策稿与阶段计划。要推进某条主线，先读这里对应子系统的最新决策稿与 resume 指针。

**收录标准**：工作未收口（进行中 / 计划中 / 暂停待恢复），且未被推翻。收口后移入 `20-archive/`；被推翻则移入 `90-obsolete/`。

> 体素主线阶段总览见 [`cross-cutting/voxel-server-authority-phase-overview.md`](cross-cutting/voxel-server-authority-phase-overview.md)。

> 上层文档地图见 [`../README.md`](../README.md)。本层共 **28** 篇（不含本索引，按子系统分组）。

## 索引

### cross-cutting

- [`_session-handoff.md`](cross-cutting/_session-handoff.md)
- [`2026-04-14-框架底座与业务解耦架构方案.md`](cross-cutting/2026-04-14-框架底座与业务解耦架构方案.md)
- [`2026-04-14-文档完善执行计划.md`](cross-cutting/2026-04-14-文档完善执行计划.md)
- [`2026-04-15-游戏内容主流程框架化方案.md`](cross-cutting/2026-04-15-游戏内容主流程框架化方案.md)
- [`2026-06-23-loop-and-zone-scale.md`](cross-cutting/2026-06-23-loop-and-zone-scale.md)
- [`2026-06-26-genesis-initiative-direction.md`](cross-cutting/2026-06-26-genesis-initiative-direction.md)
- [`2026-07-14-voxia-client-offline-mock-closure-design.md`](cross-cutting/2026-07-14-voxia-client-offline-mock-closure-design.md) — Voxia 网络无关客户端功能六阶段总纲；当前只展开阶段 1“世界渲染与场景生命周期”
- [`2026-07-14-web-bevy-client-archive-policy.md`](cross-cutting/2026-07-14-web-bevy-client-archive-policy.md) — Web / Bevy 逻辑归档策略
- [`2026-07-14-web-bevy-client-archive-implementation-plan.md`](cross-cutting/2026-07-14-web-bevy-client-archive-implementation-plan.md) — 归档客户端默认路径关闭计划
- [`voxel-server-authority-phase-overview.md`](cross-cutting/voxel-server-authority-phase-overview.md)

### field-emergence

- [`2026-05-14-phase7-field-kernel-architecture.md`](field-emergence/2026-05-14-phase7-field-kernel-architecture.md)
- [`2026-05-16-phase7-local-field-runtime-roadmap.md`](field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md)
- [`2026-05-16-phase8-physical-phenomenon-system-architecture.md`](field-emergence/2026-05-16-phase8-physical-phenomenon-system-architecture.md)
- [`2026-05-19-prefab-field-participant-projection.md`](field-emergence/2026-05-19-prefab-field-participant-projection.md)

### infra

- [`2026-04-07-增量迁移计划.md`](infra/2026-04-07-增量迁移计划.md)
- [`2026-04-10-传输协议现状与后续规划.md`](infra/2026-04-10-传输协议现状与后续规划.md)
- [`2026-04-10-gate_server协议补全计划.md`](infra/2026-04-10-gate_server协议补全计划.md)
- [`2026-07-08-docs-restructure-design.md`](infra/2026-07-08-docs-restructure-design.md)

### movement-sync

- [`2026-04-13-移动同步-vNext-后续缺口清单.md`](movement-sync/2026-04-13-移动同步-vNext-后续缺口清单.md)
- [`2026-04-20-移动同步-路线C-实施计划.md`](movement-sync/2026-04-20-移动同步-路线C-实施计划.md)
- [`2026-04-20-移动同步扩展设计.md`](movement-sync/2026-04-20-移动同步扩展设计.md)
- [`2026-05-24-server-authoritative-voxel-collision-plan.md`](movement-sync/2026-05-24-server-authoritative-voxel-collision-plan.md)

### voxel-authority

- [`2026-06-17-unit-morphology-and-surface-element-layer.md`](voxel-authority/2026-06-17-unit-morphology-and-surface-element-layer.md)
- [`2026-06-27-订阅活性根因-连接驱动正交修复设计.md`](voxel-authority/2026-06-27-订阅活性根因-连接驱动正交修复设计.md)
- [`2026-06-28-权威体素唯一事实源-噪声降为migration.md`](voxel-authority/2026-06-28-权威体素唯一事实源-噪声降为migration.md)
旧 baseline/streaming 与 WorldGen v1 计划已移入 [`../20-archive/voxel-authority/`](../20-archive/voxel-authority/)；其中 XZ/2.5D 窗口形状不再是当前契约。

### voxel-far-field

- [`2026-07-12-pure-3d-voxel-shell-migration.md`](voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md) — 唯一现役体素窗口 / 远景壳上位主线；扩展后的里程碑 A 进行中，B/C 未开始
- [`2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md`](voxel-far-field/2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md) — A10 当前主攻；唯一根、S1b-1 根级 source identity、本地 request provider 与 Pure3D far 的 diff/residency/cancel/shared-artifact/parallel-surface/stable-patch 链已落地，继续统一 near/far transaction、补 S1b-1 automation、反向依赖/full oracle、离群帧与完整 route
- [`2026-07-14-a10-uncommitted-code-audit.md`](voxel-far-field/2026-07-14-a10-uncommitted-code-audit.md) — 跨机合并前的 A10 代码审计与 S1b-1 边界证据

旧 XZ tile column、VHI/heightmap、finite-Y、近远交接与 VLOD 阶段稿已移入 [`../20-archive/voxel-far-field/`](../20-archive/voxel-far-field/)；只保留历史证据，不得作为当前设计。
