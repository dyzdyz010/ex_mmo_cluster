# 10-active · 活跃工作

**正在执行、下一步就做、或让路待恢复**的决策稿与阶段计划。要推进某条主线，先读这里对应子系统的最新决策稿与 resume 指针。

**收录标准**：工作未收口（进行中 / 计划中 / 暂停待恢复），且未被推翻。收口后移入 `20-archive/`；被推翻则移入 `90-obsolete/`。

> **迁移期例外（2026-07-21）**：本层暂留少量 `completed` / `completed-history` / `historical-superseded`
> 执行稿，作为仍在推进的 Voxia 六阶段与 Online/B/C 上位主线的直接证据。它们不表示任务仍在实施；
> 当前状态以每篇 header、`docs/00-current-truth/` 与本索引说明为准，待上位主线归档清扫时一并迁入
> `20-archive/`。

> 体素主线阶段总览见 [`cross-cutting/voxel-server-authority-phase-overview.md`](cross-cutting/voxel-server-authority-phase-overview.md)。

> 上层文档地图见 [`../README.md`](../README.md)。本层共 **46** 篇（不含本索引，按子系统分组）。

## 索引

### cross-cutting

- [`_session-handoff.md`](cross-cutting/_session-handoff.md)
- [`2026-04-14-框架底座与业务解耦架构方案.md`](cross-cutting/2026-04-14-框架底座与业务解耦架构方案.md)
- [`2026-04-14-文档完善执行计划.md`](cross-cutting/2026-04-14-文档完善执行计划.md)
- [`2026-04-15-游戏内容主流程框架化方案.md`](cross-cutting/2026-04-15-游戏内容主流程框架化方案.md)
- [`2026-06-23-loop-and-zone-scale.md`](cross-cutting/2026-06-23-loop-and-zone-scale.md)
- [`2026-06-26-genesis-initiative-direction.md`](cross-cutting/2026-06-26-genesis-initiative-direction.md)
- [`2026-07-14-voxia-client-offline-mock-closure-design.md`](cross-cutting/2026-07-14-voxia-client-offline-mock-closure-design.md) — Voxia 网络无关客户端功能六阶段总纲；阶段 2 已完成，阶段 3 设计就绪但先等待 Far LOD 材质语义修复
- [`2026-07-14-web-bevy-client-archive-policy.md`](cross-cutting/2026-07-14-web-bevy-client-archive-policy.md) — Web / Bevy 逻辑归档策略
- [`2026-07-14-web-bevy-client-archive-implementation-plan.md`](cross-cutting/2026-07-14-web-bevy-client-archive-implementation-plan.md) — 归档客户端默认路径关闭计划
- [`2026-07-18-voxia-industrial-code-review-and-remediation-design.md`](cross-cutting/2026-07-18-voxia-industrial-code-review-and-remediation-design.md) — Voxia R0–R6 无行为变化工业治理总纲
- [`2026-07-18-voxia-r0-contract-gates-implementation-plan.md`](cross-cutting/2026-07-18-voxia-r0-contract-gates-implementation-plan.md) — R0 合同与结构门禁执行稿
- [`2026-07-18-voxia-r1-runtime-snapshot-presenter-implementation-plan.md`](cross-cutting/2026-07-18-voxia-r1-runtime-snapshot-presenter-implementation-plan.md) — R1 统一根 snapshot/presenter 执行稿
- [`2026-07-18-voxia-r2-cli-router-handlers-implementation-plan.md`](cross-cutting/2026-07-18-voxia-r2-cli-router-handlers-implementation-plan.md) — R2 CLI 目录路由与领域 handler 执行稿
- [`2026-07-18-voxia-r3-json-runtime-config-implementation-plan.md`](cross-cutting/2026-07-18-voxia-r3-json-runtime-config-implementation-plan.md) — R3 JSON 与冻结运行时配置执行稿
- [`2026-07-18-voxia-r4-world-actor-role-separation-implementation-plan.md`](cross-cutting/2026-07-18-voxia-r4-world-actor-role-separation-implementation-plan.md) — R4 WorldActor 角色与 legacy probe 分离执行稿
- [`2026-07-18-voxia-r5-transport-facade-componentization-implementation-plan.md`](cross-cutting/2026-07-18-voxia-r5-transport-facade-componentization-implementation-plan.md) — R5 Transport façade 组件化执行稿
- [`2026-07-19-voxia-r6-pawn-controller-and-doc-closeout-implementation-plan.md`](cross-cutting/2026-07-19-voxia-r6-pawn-controller-and-doc-closeout-implementation-plan.md) — R6 Pawn controller 与文档收口执行稿
- [`2026-07-21-voxia-phase2-phase3-world-occupancy-and-prefab-runtime-design.md`](cross-cutting/2026-07-21-voxia-phase2-phase3-world-occupancy-and-prefab-runtime-design.md) — 阶段 2/3 世界占用总设计；阶段 2 已完成、阶段 3 后续
- [`2026-07-21-voxia-phase2-macro-voxel-interaction-implementation-plan.md`](cross-cutting/2026-07-21-voxia-phase2-macro-voxel-interaction-implementation-plan.md) — 已完成并终审的阶段 2 普通宏格交互执行稿
- [`2026-07-21-voxia-phase3-prefab-world-runtime-implementation-plan.md`](cross-cutting/2026-07-21-voxia-phase3-prefab-world-runtime-implementation-plan.md) — 下一阶段 Prefab 世界 runtime 实施计划
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

- [`2026-07-12-pure-3d-voxel-shell-migration.md`](voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md) — 唯一现役体素窗口 / 远景壳上位主线；A8/A10 的跨 LOD 外露材质语义重新打开，Online provider 与 B/C 未开始
- [`2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md`](voxel-far-field/2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md) — A10 客户端执行证据；唯一根、source identity、本地 request provider、增量链、full oracle、三轴 route 与 presentation transaction 已通过，不代表 live LOD material id 已通过
- [`2026-07-23-far-lod-surface-material-semantic-repair.md`](voxel-far-field/2026-07-23-far-lod-surface-material-semantic-repair.md) — 当前客户端阻断项；记录粗 LOD 中心采样漏掉薄表层的证据、canonical reducer 边界、观察面、测试矩阵与下一会话顺序
- [`2026-07-14-a10-uncommitted-code-audit.md`](voxel-far-field/2026-07-14-a10-uncommitted-code-audit.md) — 跨机合并前的 A10 代码审计与 S1b-1 边界证据
- [`2026-07-18-voxia-authority-window-streaming-overdue-design.md`](voxel-far-field/2026-07-18-voxia-authority-window-streaming-overdue-design.md) — 阶段 1 权威窗口后台流送与超期恢复设计
- [`2026-07-18-voxia-authority-window-streaming-overdue-implementation-plan.md`](voxel-far-field/2026-07-18-voxia-authority-window-streaming-overdue-implementation-plan.md) — 权威窗口后台流送执行稿
- [`2026-07-21-voxia-far-render-governance-design.md`](voxel-far-field/2026-07-21-voxia-far-render-governance-design.md) — 已完成的 RG0–RG6 远景渲染治理设计与 closeout
- [`2026-07-21-voxia-far-render-governance-implementation-plan.md`](voxel-far-field/2026-07-21-voxia-far-render-governance-implementation-plan.md) — RG0–RG6 远景渲染治理执行证据

旧 XZ tile column、VHI/heightmap、finite-Y、近远交接与 VLOD 阶段稿已移入 [`../20-archive/voxel-far-field/`](../20-archive/voxel-far-field/)；只保留历史证据，不得作为当前设计。
