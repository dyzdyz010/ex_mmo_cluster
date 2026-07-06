# 原始文档归类索引

> 本文件把原始文档归类为证据源。它不是当前状态本身；当前状态见 [README.md](README.md) 和各模块文档。

## 分类规则

```mermaid
flowchart TD
  Root["docs/ 与 clients/*/docs"]
  Spec["规范 / 协议 / 项目概览"]
  Phase["阶段计划 / 进度日志"]
  Incident["问题复盘 / 修复记录"]
  Current["当前唯一事实"]

  Root --> Spec
  Root --> Phase
  Root --> Incident
  Spec --> Current
  Phase --> Current
  Incident --> Current
```

- **规范类**：冻结架构、协议规范、项目概览，提供长期约束。
- **阶段类**：Phase、roadmap、implementation plan，提供能力落地顺序和状态证据。
- **复盘类**：bug 根因、修复记录、handoff，提供“为什么现在这样”的证据。
- **当前事实类**：`docs/current_status/`，提供此刻唯一答案。

## 核心证据源

| 分类 | 文档 | 当前用途 |
| --- | --- | --- |
| 冻结规范 | [`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`](../HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md) | 最高层架构约束和合规判据 |
| 项目概览 | [`docs/2026-04-10-项目概览.md`](../2026-04-10-项目概览.md) | Umbrella 应用、项目定位、早期服务划分 |
| 协议 | [`docs/2026-04-10-线协议规范.md`](../2026-04-10-线协议规范.md) | 自定义二进制协议的长期参考 |
| 可观测性 | [`docs/2026-04-12-cli-observability-debugging.md`](../2026-04-12-cli-observability-debugging.md) | CLI / 日志优先的调试纪律 |
| 体素权威主索引 | [`docs/voxel-server-authority/README.md`](../voxel-server-authority/README.md) | Phase 1-8 状态索引 |
| 生产级体素世界 | [`docs/2026-06-25-voxel-world-production-architecture.md`](../2026-06-25-voxel-world-production-architecture.md) | region/world/streaming 目标架构与 tile 口径 |
| 正交设计原则 | [`docs/2026-06-27-架构设计指导思想-系统正交.md`](../2026-06-27-架构设计指导思想-系统正交.md) | 系统正交、自维护不变量、bug 诊断判据 |
| 体素唯一事实源 | [`docs/2026-06-28-权威体素唯一事实源-噪声降为migration.md`](../2026-06-28-权威体素唯一事实源-噪声降为migration.md) | WorldGen 噪声降级为 migration 的地基决策 |
| 体素/远景整合 | [`docs/2026-06-28-体素世界与远景渲染-当前真相(整合).md`](../2026-06-28-体素世界与远景渲染-当前真相(整合).md) | 近场/远景/LOD/skirt/远程交互当前整合草稿 |
| Voxia streaming | [`clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md`](../../clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md) | UE 客户端近场窗口跟随、debug overlay、stdio CLI、server route repair |
| 远景 LOD 根因 | [`clients/Voxia/docs/2026-06-28-远景LOD-heightmap-设计与拼接缝隙根因.md`](../../clients/Voxia/docs/2026-06-28-远景LOD-heightmap-设计与拼接缝隙根因.md) | heightmap LOD 和拼接缝隙根因；取数源部分已被唯一事实源取代 |
| baseline 边界决策 | [`docs/voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md`](../voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md) | 确定性 WorldGen + committed delta + hash 凭证；存储/流送/计算三边界；垂直分层 + 范围声明 |
| baseline / streaming 实施计划 | [`docs/voxel-server-authority/2026-06-30-voxel-generation-streaming-client-plan.md`](../voxel-server-authority/2026-06-30-voxel-generation-streaming-client-plan.md) | 体素生成、流送、Voxia 本地加载与渲染迁移的 Phase 0-8 执行序列；含 H、H gate、canonical 等名词解释 |
| WorldGen v1 地形算法 | [`docs/voxel-server-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md`](../voxel-server-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md) | Phase 1 确定性地形算法输入；2.5D 高度场 + 材料分层 + 稀疏矿脉 replacement；洞穴/水体走 genesis D-delta |
| Voxia VHI 实验 | [`docs/voxel-server-authority/2026-06-30-voxia-vhi-experiment-plan.md`](../voxel-server-authority/2026-06-30-voxia-vhi-experiment-plan.md) | 新关卡试验 Voxel Hierarchical Impostor；旧 WorldGen preview 与 heightmap LOD 保留 |
| Voxia SVO 预览设计 | [`docs/voxel-server-authority/2026-06-30-voxia-svo-preview-design.md`](../voxel-server-authority/2026-06-30-voxia-svo-preview-design.md) | 新关卡试验 3D occupancy Sparse Voxel Octree leaf surface；目标为窗口边缘连续、约 8km 远景和 120 FPS 预算 |
| Voxia 近场窗口内核与 SVO 路线 | [`docs/voxel-server-authority/2026-06-30-voxia-near-window-kernel-and-svo-roadmap.md`](../voxel-server-authority/2026-06-30-voxia-near-window-kernel-and-svo-roadmap.md) | 按系统正交剥离 `3x3x3 tile` 近场窗口契约，并记录后续 subsystem / renderer / SVO page 化升级目标 |
| 体素 LOD 生产路线 | [`docs/voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md`](../voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md) | 拍板 L0 近景 + L1-L3 SVO mesh 默认生产渲染 + L4 raymarch 可选；VHI 冻结为 2.5D 过渡 baseline |
| LOD 外部方案评审 | [`docs/voxel-server-authority/2026-07-06-gpt55-lod23-proposal-review.md`](../voxel-server-authority/2026-07-06-gpt55-lod23-proposal-review.md) | GPT-5.5 远景方案对抗评审：数据源裁决、16 条采纳矩阵、UE 5.8 能力边界实证、LOD 预算数学 |
| LOD 分层与技术选型 | [`docs/voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md`](../voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md) | v2.5 主体已拍板：四环 7/14/28/56m + collar、每层选型、page payload/失效契约、三列里程碑（A/B/C） |
| 数据源终态裁决 | [`docs/voxel-server-authority/2026-07-06-projection-route-final-decision.md`](../voxel-server-authority/2026-07-06-projection-route-final-decision.md) | 投影路线为终态；同构路线降格为定向优化选项；客户端 WorldGen 永久 preview/fixture 定位 |
| 体素数据链路术语表 | [`docs/voxel-server-authority/glossary.md`](../voxel-server-authority/glossary.md) | base / delta / overlay / truth / snapshot 统一口径；客户端 snapshot-only 推论；远区修改回流回路 |
| Field roadmap | [`docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md`](../plans/2026-05-16-phase7-local-field-runtime-roadmap.md) | Phase 7+ 局部场当前推进基准 |
| Field kernel | [`docs/plans/2026-05-14-phase7-field-kernel-architecture.md`](../plans/2026-05-14-phase7-field-kernel-architecture.md) | FieldKernel / FieldRegion / FieldLayer / FieldEffect 架构背景 |

## 按功能归档视图

### 服务端控制面

- [`docs/2026-06-25-voxel-world-production-architecture.md`](../2026-06-25-voxel-world-production-architecture.md)
- [`apps/world_server/lib/world_server/voxel/README.md`](../../apps/world_server/lib/world_server/voxel/README.md)
- [`docs/voxel-server-authority/phase-A4-cross-region-prefab.md`](../voxel-server-authority/phase-A4-cross-region-prefab.md)
- [`docs/voxel-server-authority/_session-handoff.md`](../voxel-server-authority/_session-handoff.md)

### 体素权威与存储

- [`docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`](../2026-04-29-server-authoritative-voxel-data-protocol-design.md)
- [`docs/voxel-server-authority/phase-1a-refined-cell-domain.md`](../voxel-server-authority/phase-1a-refined-cell-domain.md)
- [`docs/voxel-server-authority/phase-1b-typed-edit-intent.md`](../voxel-server-authority/phase-1b-typed-edit-intent.md)
- [`docs/voxel-server-authority/phase-1c-refined-mutation.md`](../voxel-server-authority/phase-1c-refined-mutation.md)
- [`docs/voxel-server-authority/phase-1d-canonical-persistence.md`](../voxel-server-authority/phase-1d-canonical-persistence.md)
- [`docs/2026-06-28-权威体素唯一事实源-噪声降为migration.md`](../2026-06-28-权威体素唯一事实源-噪声降为migration.md)
- [`docs/voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md`](../voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md)
- [`docs/voxel-server-authority/2026-06-30-voxel-generation-streaming-client-plan.md`](../voxel-server-authority/2026-06-30-voxel-generation-streaming-client-plan.md)
- [`docs/voxel-server-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md`](../voxel-server-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md)
- [`docs/voxel-server-authority/2026-07-06-projection-route-final-decision.md`](../voxel-server-authority/2026-07-06-projection-route-final-decision.md)
- [`docs/voxel-server-authority/glossary.md`](../voxel-server-authority/glossary.md)

### 体素事务、Prefab、Object

- [`docs/voxel-server-authority/phase-3-prefab-v2-transactions.md`](../voxel-server-authority/phase-3-prefab-v2-transactions.md)
- [`docs/voxel-server-authority/phase-3-bis-fence-and-resume.md`](../voxel-server-authority/phase-3-bis-fence-and-resume.md)
- [`docs/voxel-server-authority/phase-4-object-provenance.md`](../voxel-server-authority/phase-4-object-provenance.md)
- [`docs/voxel-server-authority/phase-4-bis-object-state-delta-push.md`](../voxel-server-authority/phase-4-bis-object-state-delta-push.md)
- [`docs/voxel-server-authority/phase-A4-cross-region-prefab.md`](../voxel-server-authority/phase-A4-cross-region-prefab.md)

### 局部场与涌现

- [`docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md`](../plans/2026-05-16-phase7-local-field-runtime-roadmap.md)
- [`docs/plans/2026-05-14-phase7-field-kernel-architecture.md`](../plans/2026-05-14-phase7-field-kernel-architecture.md)
- [`docs/plans/2026-05-19-prefab-field-participant-projection.md`](../plans/2026-05-19-prefab-field-participant-projection.md)
- [`docs/voxel-server-authority/2026-06-14-emergence-reaction-layer.md`](../voxel-server-authority/2026-06-14-emergence-reaction-layer.md)
- [`docs/voxel-server-authority/2026-06-16-orthogonal-systems-architecture.md`](../voxel-server-authority/2026-06-16-orthogonal-systems-architecture.md)
- [`docs/voxel-server-authority/2026-06-17-S4-chemistry-oxidation-system.md`](../voxel-server-authority/2026-06-17-S4-chemistry-oxidation-system.md)
- [`docs/2026-06-21-emergent-optics-thermal-incandescence.md`](../2026-06-21-emergent-optics-thermal-incandescence.md)
- [`docs/2026-06-23-light-as-orthogonal-system.md`](../2026-06-23-light-as-orthogonal-system.md)
- [`docs/2026-06-23-mechanical-stress-structural-collapse.md`](../2026-06-23-mechanical-stress-structural-collapse.md)
- [`docs/2026-06-24-c4b-deep-semiconductor.md`](../2026-06-24-c4b-deep-semiconductor.md)

### 建设 / Prefab / Surface

- [`docs/voxel-server-authority/phase-3-prefab-v2-transactions.md`](../voxel-server-authority/phase-3-prefab-v2-transactions.md)
- [`docs/voxel-server-authority/phase-4-object-provenance.md`](../voxel-server-authority/phase-4-object-provenance.md)
- [`docs/voxel-server-authority/phase-A4-cross-region-prefab.md`](../voxel-server-authority/phase-A4-cross-region-prefab.md)
- [`docs/voxel-server-authority/2026-06-17-unit-morphology-and-surface-element-layer.md`](../voxel-server-authority/2026-06-17-unit-morphology-and-surface-element-layer.md)
- [`docs/2026-06-23-construction-system-fixed-component-list.md`](../2026-06-23-construction-system-fixed-component-list.md)

### 客户端与渲染

- [`clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md`](../../clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md)
- [`clients/Voxia/docs/2026-06-28-远景LOD-heightmap-设计与拼接缝隙根因.md`](../../clients/Voxia/docs/2026-06-28-远景LOD-heightmap-设计与拼接缝隙根因.md)
- [`clients/Voxia/docs/2026-06-26-voxel-perf-optimization-directive.md`](../../clients/Voxia/docs/2026-06-26-voxel-perf-optimization-directive.md)
- [`docs/voxel-server-authority/2026-06-30-voxia-vhi-experiment-plan.md`](../voxel-server-authority/2026-06-30-voxia-vhi-experiment-plan.md)
- [`docs/voxel-server-authority/2026-06-30-voxia-svo-preview-design.md`](../voxel-server-authority/2026-06-30-voxia-svo-preview-design.md)
- [`docs/2026-06-15-bevy-client-mainline-architecture.md`](../2026-06-15-bevy-client-mainline-architecture.md)
- [`docs/2026-04-25-bevy-client-web-parity-voxel-migration.md`](../2026-04-25-bevy-client-web-parity-voxel-migration.md)
- [`docs/voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md`](../voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md)
- [`docs/voxel-server-authority/2026-07-06-gpt55-lod23-proposal-review.md`](../voxel-server-authority/2026-07-06-gpt55-lod23-proposal-review.md)
- [`docs/voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md`](../voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md)

### 已明确被后续文档取代的结论

| 旧结论 | 当前结论 | 替代证据 |
| --- | --- | --- |
| 远景 heightmap 可长期运行时重跑噪声作为事实源 | 噪声只能是一次性 migration；远景 LOD 应派生自权威体素 store | [`2026-06-28-权威体素唯一事实源-噪声降为migration.md`](../2026-06-28-权威体素唯一事实源-噪声降为migration.md) |
| 运行时 snapshot/resync 可作为本地基线缺失兜底 | 本地基线校验失败必须拒绝入场，不允许 snapshot 兜底 | [`AGENTS.md`](../../AGENTS.md) §3、[`2026-06-25-voxel-world-production-architecture.md`](../2026-06-25-voxel-world-production-architecture.md) §3.2.0 |
| 移动导致挖放失效 | 根因判据应按订阅覆盖与活性正交分析；移动常是红鲱鱼 | [`2026-06-27-架构设计指导思想-系统正交.md`](../2026-06-27-架构设计指导思想-系统正交.md) |
| 27 tile 可按 27 chunk 估算 | 生产口径中 1 tile = `7×7×7` chunks；27 tiles = `3×3×3` tiles | [`2026-06-25-voxel-world-production-architecture.md`](../2026-06-25-voxel-world-production-architecture.md) §3.2.0 |
| `state_flags` 承载 burning/frozen/wet/charred 外观 | 客户端外观应为 material/tag/field 的纯函数，`state_flags` 不作为通用涌现外观位 | [`clients/Voxia/docs/2026-06-27-voxia-emergence-render-design.md`](../../clients/Voxia/docs/2026-06-27-voxia-emergence-render-design.md) |
| 客户端长期应本地重算 confirmed baseline（seed+maps+D+H，跨端 bit-exact） | 投影路线为终态：客户端 snapshot-only（近窗 1m + 远区 7m 投影），配方不跨 wire；同构路线降格为定向优化选项 | [`docs/voxel-server-authority/2026-07-06-projection-route-final-decision.md`](../voxel-server-authority/2026-07-06-projection-route-final-decision.md) |
| 远景 2.5D heightmap / VHI 是生产终态形态 | VHI 冻结为 2.5D 过渡 baseline；生产远景 = L1-L3 SVO leaf-surface mesh（source pages 驱动），分带 7/14/28/56m + collar，L4 raymarch defer | [`docs/voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md`](../voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md)、[`2026-07-06-voxia-lod-layering-and-technology-design.md`](../voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md) |
