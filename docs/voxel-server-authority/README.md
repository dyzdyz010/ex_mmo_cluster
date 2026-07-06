# 体素服务器权威化 — 实施跟踪

本目录用于跟踪"体素全面服务器权威化"长期工作的计划与执行进度。每个阶段(Phase)对应一份独立的计划文件,文件内含进度日志,完成后归档。

## 起点参考

- **体素 baseline 与流送边界决策（2026-06-29)**:[`docs/voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md`](./2026-06-29-voxel-baseline-streaming-boundary.md) —— 确定性 WorldGen + 设计师 delta D + hash 凭证 H；存储/流送/计算三边界；从全量物化路线迁移到 delta 边界。当前最高层 baseline 形态决策。
- **体素同步 · 版本 · 滑动窗口 · 渲染设计（2026-06-29，v2 评审加固)**:[`docs/voxel-server-authority/2026-06-29-voxel-sync-window-and-render-design.md`](./2026-06-29-voxel-sync-window-and-render-design.md) —— baseline 边界决策的下游 HOW 设计稿。W-1~W-13:chunk=算法基底⊕offset、版本正交两层（chunk_version⊥H）、客户端三态渲染（窗口内体素/窗外 terrain mip+proxy/远景）、远景 LOD 订阅面、content_version 运行时维护、WorldGen 2.5D 内容维度锁定、浮点 bit-exact 规范、动态层边界。已过 5 视角对抗评审。
- **体素生成 / 流送 / Voxia 加载渲染实施计划（2026-06-30)**:[`docs/voxel-server-authority/2026-06-30-voxel-generation-streaming-client-plan.md`](./2026-06-30-voxel-generation-streaming-client-plan.md) —— 把 baseline 边界决策与同步窗口设计拆成 Phase 0-8 执行序列，补 H、H gate、canonical、D/P、checkpoint、LOD projection 等名词解释与验收矩阵。
- **WorldGen v1 确定性地形生成设计（2026-06-30)**:[`docs/voxel-server-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md`](./2026-06-30-worldgen-v1-deterministic-terrain-design.md) —— Phase 1 算法输入。拍板 v1 采用 2.5D 高度场 + 材料分层 + 稀疏矿脉 replacement；天然洞穴、水体、遗迹等复杂结构先由 genesis D-delta 冻结进 baseline。
- **Voxia VHI 新关卡实验计划（2026-06-30)**:[`docs/voxel-server-authority/2026-06-30-voxia-vhi-experiment-plan.md`](./2026-06-30-voxia-vhi-experiment-plan.md) —— 在保留旧 `L_WorldGenPreview` 与 heightmap LOD 的前提下，新建 `L_WorldGenVhiPreview` 和 `-VoxiaVhiPreview`，用 Voxel Hierarchical Impostor 试验窗口外三维 visual proxy。
- **Voxia SVO 远景预览设计（2026-06-30)**:[`docs/voxel-server-authority/2026-06-30-voxia-svo-preview-design.md`](./2026-06-30-voxia-svo-preview-design.md) —— 在独立 `L_WorldGenSvoPreview` 关卡中验证 Sparse Voxel Octree macro-cell mesh proxy，目标是窗口边缘连续、约 8km 远景和 120 FPS 预算。
- **Voxia 远景公共组件抽取 + VHI 2.5D baseline 定位（2026-06-30)**:[`docs/voxel-server-authority/2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md`](./2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md) —— 把 VHI/SVO 逐行重复的编排（coverage 规划 / 异步生命周期 / 分帧上传）抽成 `FarField/` 三个正交公共组件（3D-ready），明确 VHI=廉价 2.5D 地表 baseline、3D（浮空岛/洞穴）归 SVO，3D 源切换作下个里程碑。抽编排不抽算法。
- **Voxia 体素管理管线生产路线（2026-07-05)**:[`docs/voxel-server-authority/2026-07-05-voxia-voxel-lod-production-route.md`](./2026-07-05-voxia-voxel-lod-production-route.md) —— 在 SVO 数据管理与滑动窗口加载策略已确定的前提下，拍板 L0 近景 `3x3x3 tiles`、L1-L3 SVO leaf-surface mesh artifact 默认生产渲染、L4 raymarch-only 可选超远景 profile；VHI 冻结为 2.5D 过渡 baseline。
- **GPT-5.5 LOD2/LOD3 外部方案对抗评审（2026-07-06)**:[`docs/voxel-server-authority/2026-07-06-gpt55-lod23-proposal-review.md`](./2026-07-06-gpt55-lod23-proposal-review.md) —— 对 `docs/design/` 下两份外部 GPT-5.5 远景方案的评审：数据源裁决（维持 source pages 主线，客户端 WorldGen 重启需五条件）、16 条采纳矩阵与净增量 TOP-5、UE 5.8 能力边界实证（Nanite 运行时构建 API 级不可行 / WP HLOD 输入为空集 / DynamicMesh StaticDraw 白送杠杆）、LOD 预算数学。
- **Voxia LOD 分层与各层技术选型设计（2026-07-06，v2.5，主体已拍板)**:[`docs/voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md) —— 07-05 路线的下游细化：L0-L4+天空分带（7/14/28/56m 环 + 3.5m collar）、每层技术选型与理由、source page payload=7m occupancy+material mip（any-solid/众数规约算子）、分带失效契约（含流式重派生定位与换轨触发条件）、seam/垂直/tier 契约、三列里程碑（A 客户端渲染正确 → B 接口冻结+fixture 消费 → C 服务端接入）。经 1 轮对抗评审修订。**已拍板**：数据源=投影路线终态 + L4 defer 化（v2.4）、T-2 L2.5 四环 7/14/28/56m（v2.5）；其余 T- 项随里程碑推进逐项确认。
- **体素数据源终态裁决（2026-07-06 拍板)**:[`2026-07-06-projection-route-final-decision.md`](./2026-07-06-projection-route-final-decision.md) —— **投影路线为终态**(客户端 snapshot-only:近窗 1m + 远区 7m);同构路线(客户端 WorldGen ⊕ overlay)降格为特定负载画像下的定向优化选项(处女地定向加法);客户端 WorldGen 永久定位 preview/fixture 源;五维度裁决依据(带宽三折扣/内容演化/信息不对称/一致性面/不可逆性)。
- **体素数据链路术语表（2026-07-06 拍板)**:[`glossary.md`](./glossary.md) —— base / delta / truth / snapshot 四词统一口径:客户端 snapshot-only(近窗 1m + 远区 7m 双分辨率),`base ⊕ delta` 是服务端生产配方;含远区修改回流回路与三条既有裁决索引。数据链路口径与 6-30 名词解释表冲突时以本表为准。
- **架构对齐迁移主线（2026-06-14 起,当前最高层索引)**:[`docs/voxel-server-authority/2026-06-14-architecture-triage-and-alignment.md`](./2026-06-14-architecture-triage-and-alignment.md) —— 对照冻结规范 v2.0.2 的分诊、四项拍板、规范反哺修订、梯队迁移顺序。本目录原有 Phase 1–8 工作被纳入该主线统筹。
- 冻结规范(权威):[`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`](../HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md)（已含 v2.0.2 反哺修订）
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
| 3 | prefab v2 事务化(World/Scene transaction coordinator) | 已完成 | [`phase-3-prefab-v2-transactions.md`](./phase-3-prefab-v2-transactions.md) |
| 3-bis | fence persistence + auto-resume commit(crash safety 闭环) | 已完成 | [`phase-3-bis-fence-and-resume.md`](./phase-3-bis-fence-and-resume.md) |
| 4 | object provenance、局部破坏与整体销毁 | 已完成 | [`phase-4-object-provenance.md`](./phase-4-object-provenance.md) |
| 4-bis | ObjectStateDelta 推送链路 + 客户端碎屑粒子消费 | 已完成 | [`phase-4-bis-object-state-delta-push.md`](./phase-4-bis-object-state-delta-push.md) |
| A2 | 阶段 A 子 1:尺寸真实化(角色 1.7m / 跑速 6 m/s / apex 1.2m) | 已完成 | [`phase-A2-real-world-scale.md`](./phase-A2-real-world-scale.md) |
| A1 | 阶段 A 子 2:客户端可玩 demo 必须线(prefab micro / 防覆盖 / 线框预览 / 跳跃同步 / 破坏技能) | 已完成 | [`phase-A1-playable-client-experience.md`](./phase-A1-playable-client-experience.md) |
| A4 | 阶段 A 子 4:跨 region prefab 多 participant 事务 + 跨节点 damage / 0x6C owner-driven fan-out(主体) | 已完成 | [`phase-A4-cross-region-prefab.md`](./phase-A4-cross-region-prefab.md) |
| A4-bis-cluster | A4 子阶段:真正的多 scene_node 分布式部署(BeaconServer term key 升级 + RegionRouting + lease 按 scene_node 分配 + 双 BEAM e2e) | 决策稿就位 | [`phase-A4-cross-region-prefab.md`](./phase-A4-cross-region-prefab.md)(文末专段) |
| 5 | 属性目录 + 温湿度基础模拟 | 已完成 | [`2026-05-13-phase5-backlog-and-subphase-decomposition.md`](../plans/2026-05-13-phase5-backlog-and-subphase-decomposition.md) |
| 6 | 局部场最小目标(FieldLayer + 电场 + 温度场 + FieldDebugOverlay) | 已完成 | [`2026-05-13-体素局部场最小目标-索引.md`](../2026-05-13-体素局部场最小目标-索引.md) |
| 7 | 局部场传播 Kernel 架构目标(FieldKernel + FieldRuntime) | 进行中（7.A 已完成；7.D1 SetTemperature/Cool 已完成；7.D2 温度 source 最小闭环已完成；7.D3 温度 FieldEffect 写回最小闭环已完成；7.E 第一批材料物性已完成；7.B ConductionPathKernel core/runtime/web 入口已完成；prefab 接入所有局部场的 projection 设计已就位；后续推进以 2026-05-16 roadmap 与 2026-05-19 prefab projection 设计为准） | [`2026-05-14-phase7-field-kernel-architecture.md`](../plans/2026-05-14-phase7-field-kernel-architecture.md) / [`2026-05-16-phase7-local-field-runtime-roadmap.md`](../plans/2026-05-16-phase7-local-field-runtime-roadmap.md) / [`2026-05-19-prefab-field-participant-projection.md`](../plans/2026-05-19-prefab-field-participant-projection.md) |
| 8 | 物理现象系统(燃烧 / 结冰 / 结构完整度 / 碳化 / 腐蚀 / 相变) | 设计目标稿 | [`2026-05-16-phase8-physical-phenomenon-system-architecture.md`](../plans/2026-05-16-phase8-physical-phenomenon-system-architecture.md) |
| Baseline/streaming delta migration | 体素生成、流送、Voxia 加载渲染从全量物化过渡到确定性 WorldGen + D/P + H gate | 实施计划就位 | [`2026-06-30-voxel-generation-streaming-client-plan.md`](./2026-06-30-voxel-generation-streaming-client-plan.md) |
| WorldGen v1 | 确定性地形算法：2.5D 高度场 + 材料分层 + 稀疏矿脉 replacement；洞穴/水体走 D-delta | 设计目标稿 | [`2026-06-30-worldgen-v1-deterministic-terrain-design.md`](./2026-06-30-worldgen-v1-deterministic-terrain-design.md) |
| Voxia VHI preview | 新关卡试验 Voxel Hierarchical Impostor；旧 WorldGen preview / heightmap LOD 保留 | 实验实现中 | [`2026-06-30-voxia-vhi-experiment-plan.md`](./2026-06-30-voxia-vhi-experiment-plan.md) |
| Voxia SVO preview | 新关卡试验 Sparse Voxel Octree macro-cell mesh proxy；目标为无缝、8km 远景、120 FPS 预算 | 设计目标稿 | [`2026-06-30-voxia-svo-preview-design.md`](./2026-06-30-voxia-svo-preview-design.md) |
| Voxia FarField 公共组件 + VHI baseline | 抽 coverage 规划 / 异步生命周期 / 分帧上传三组件（3D-ready）；VHI 定位廉价 2.5D baseline、3D 归 SVO | 进行中（D-10 SVO 转主力 / VHI 冻结已记录；2026-07-01 已落地 SVO patch grid + 分帧上传，8km real RHI 上传后 FPS 样本约 104-115；`FVoxiaFarFieldCoveragePlanner::PlanFull`、`FVoxiaFarFieldBuildPipeline`、`FVoxiaFarFieldPatchUploader`、`FVoxiaFarFieldMeshComponentDesc` 已被 VHI/SVO 远景路径共用；SVO builder-side macro-cell artifact/cache/reuse 已落地，移动 CLI smoke 复用率 `0.958`；SVO confirmed-store source boundary、coverage preflight 和 WorldGen-preview 小范围 preload 预算门禁已落地，8km 超预算时硬拒；2026-07-05 已接 `source_pages` manifest gate、持久化 macro-cell artifact cache、默认 RuntimeMesh / `UDynamicMeshComponent` renderer、保留型 `svo_source_pages_fixture`、严格 `until_svo_source_pages_uploaded` / `until_svo_source_pages_suppressed` 和 `run_svo_source_pages_fixture_smoke.js` runner，并有 source_pages real-RHI 上传、截图审计、3x3x3 多页 fixture、3x3x3 真实 RHI RuntimeMesh 上传、可复用 runner、相邻 tile retained-package 移动证据和 focus suppression 证据。服务端生产权威源调度、launcher/offline 端到端和长期性能待定） | [`2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md`](./2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md) |

| VLOD-A1 | 体素 LOD 里程碑 A 步 1:切默认分级 + 显式 tier 契约 + L2.5 第三环(四环 7/14/28/56m,quads −64%) | 未开始 | [`phase-vlod-a1-explicit-tiering.md`](./phase-vlod-a1-explicit-tiering.md) |

状态取值:`未开始` / `进行中` / `已完成` / `已搁置`。状态变更时同步更新本表与对应阶段文件的 `进度日志`。

Phase 6 已落地；Phase 7.A `FieldKernel` kernel-first 迁移已完成；Phase 7.D1 已把
`F` / `Heat` / `Cool` / `voxel_temp` 动作接到服务端：先写 voxel `temperature` 属性，再由
`FieldRuntime` 从 voxel truth 检测异常并创建/复用局部场；web_client 会在 set-temperature 成功后
自动打开 Field overlay。Phase 7.D2 已为温度路径补上 `FieldSource` runtime 事实、
source lifecycle observability，以及回到环境阈值内时的 0x74 region cleanup。Phase 7.D3
已补上温度 `FieldEffect` 最小写回边界：worker 交付 non-observe effects，`ChunkProcess`
作为 chunk authority 应用 `write_voxel_attribute(:temperature)` 或明确 reject unsupported effect。
Phase 7.E 第一批材料物性（电导/击穿强度等）已落地；Phase 7.B 已把
`ConductionPathKernel` 接入 `FieldRuntime.ensure_conduction_path/1`、`/ingame/voxel/conduct`
和 web CLI `voxel_conduct`，成功请求会自动打开 Field overlay；Phase 7.F 前置第一片已让
electric conduction 也走 owner-aware `FieldSource`，HTTP/runtime 可携带 `source_mode`、
`ttl_ticks` 和 `energy_budget_joules`，其中 ttl 会约束当前 conduction region lifetime；
ttl 到期会释放 source 并通过既有 0x74 destroy payload 让客户端看到 field 消失；导电预检失败
会写 `voxel_conduction_path_rejected` observe，保留预算耗尽等更细失败原因和 source/target
定位字段；`PowerSource` v1 已让导电请求可声明 DC / AC / pulse、voltage、current limit 和
frequency，HTTP 与 web CLI 均可透传并在 summary 中回显。默认物理来源已收敛到
`material_id=6` 的 `power_block`：普通 iron 只做导线，未显式传 owner/power 参数时不能凭空供电。
electric-to-thermal 第一片已接入：导电路径会把 source voltage 和 load current 估算成焦耳热
FieldEffect，由 `ChunkProcess` 写回 voxel 温度 truth；HTTP/Web CLI 可透传 `load_current_amps`
和 `energy_budget_joules`，过载负载会以 `current_limit_exceeded` 拒绝。当前仍不做完整电路仿真、
持续能量扣减或材料熔断破坏。浏览器 GUI 已有第一版热烟可视化：导电 accepted 后，
`power_draw.estimated_tick_energy_joules` 会注册为 Field Overlay 热烟源，后续 electric field
snapshot 按热量比例生成灰色上升烟粒子；方块本体不因这条电热链路染色，CLI `field_overlay`
会返回每个 region 的 `smoke` 粒子数。
自动电路 current overlay 以 `CircuitComponentAnalysis` 的闭合 source-load 谓词作为 runtime
准入条件：只有 graph 2-core 中同时包含 power source 与 load 时才创建/保留 current field；
开路 source-load 会返回 `no_closed_circuit`，断环会释放对应 region/source，而不是保留空
topology watcher。
后续路线图以
[`2026-05-16-phase7-local-field-runtime-roadmap.md`](../plans/2026-05-16-phase7-local-field-runtime-roadmap.md)
为准；prefab 接入所有局部场的架构边界以
[`2026-05-19-prefab-field-participant-projection.md`](../plans/2026-05-19-prefab-field-participant-projection.md)
为准，电场只是首条验证路径，不应把 prefab 写成电场专用特判。下一步关注 source owner 存活/预算消耗、跨 chunk/AOI 预算与 Phase 8 effect 边界。Phase 8
物理现象系统已落设计目标稿，但不应由导电 kernel 直接实现伤害、击穿破坏或 object/combat 结算。

## 跟踪约定

- **一阶段一文件**:每个阶段开始前先建 `phase-<id>-<slug>.md`,内含目标、范围、文件清单、改动点、测试矩阵、验收标准、进度日志。
- **进度日志按时间倒序追加**:每次推进、卡点、决策都补一行 `YYYY-MM-DD: ...`。
- **不要把行为变更与 README 索引耦合**:索引只反映阶段状态,具体决策与变更证据写在阶段文件里。
- **完成后不删除文件**:状态改为 `已完成`,留作后续阶段查证依据。
