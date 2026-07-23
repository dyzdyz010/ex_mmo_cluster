# 体素服务器权威化 — 实施跟踪

本目录用于跟踪"体素全面服务器权威化"长期工作的计划与执行进度。每个阶段(Phase)对应一份独立的计划文件,文件内含进度日志,完成后归档。

> **完整 XYZ 空间契约与 2026-07-23 当前状态**：完整 XYZ 是体素窗口、远景壳、page/cell
> identity、coverage、LOD、cache、prefetch、handoff 与预算的唯一权威事实。默认近场
> `3×3×3 tiles = 27 tiles = 9261 chunks`；单轴跨越一整个 tile 时，进入/退出各为
> `3×3×1 = 9 tiles = 3087 chunks`，保留为 `18 tiles = 6174 chunks`。XZ tile column、有限 Y
> 呈现带和固定 `Tile.Y=0` 只保留在归档证据中。Pure3D far 已进入唯一生产根，阶段 1
> lifecycle/ownership、阶段 2 与 A8/A10 跨 LOD 外露材质语义均已完成。Online confirmed
> provider 与阶段 3 Prefab 尚未接入。

## 起点参考

- **体素 baseline 与流送边界决策（2026-06-29)**:[`docs/30-reference/protocol/2026-06-29-voxel-baseline-streaming-boundary.md`](../../30-reference/protocol/2026-06-29-voxel-baseline-streaming-boundary.md) —— 确定性 WorldGen + 设计师 delta D + hash 凭证 H；存储/流送/计算三边界；从全量物化路线迁移到 delta 边界。当前最高层 baseline 形态决策。
- **旧体素同步 · 版本 · 滑动窗口 · 渲染设计（2026-06-29，已归档)**:[`docs/20-archive/voxel-authority/2026-06-29-voxel-sync-window-and-render-design.md`](../../20-archive/voxel-authority/2026-06-29-voxel-sync-window-and-render-design.md) —— 历史 HOW 证据；版本正交、content_version 与动态层边界仍可参考，但 XZ column、有限 Y 和旧窗口预算已经失效。
- **旧体素生成 / 流送 / Voxia 加载渲染实施计划（2026-06-30，已归档)**:[`docs/20-archive/voxel-authority/2026-06-30-voxel-generation-streaming-client-plan.md`](../../20-archive/voxel-authority/2026-06-30-voxel-generation-streaming-client-plan.md) —— 历史 Phase 0-8 执行证据；H、H gate、canonical 等术语仍可查证，空间契约以纯 3D 主线为准。
- **WorldGen v1 确定性地形生成设计（2026-06-30，已归档)**:[`docs/20-archive/voxel-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md`](../../20-archive/voxel-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md) —— 旧 2.5D 算法稿只保留为迁移证据，不再是目标契约；当前目标是 `chunk_xyz -> canonical 3D chunk`，地表只是三维密度算子的一种内容结果。
- **里程碑 A 扩展：完整 3D 体素立方壳与客户端流送（2026-07-12，唯一现役上位主线)**:[`2026-07-12-pure-3d-voxel-shell-migration.md`](../voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md) —— 唯一根、source identity、H-gated local provider、Pure3D far 增量链、full oracle、三轴 route、confirmed presentation transaction、shared renderer 材质合同与 live LOD material id 语义均已实跑收口；见 [`Far LOD 外露表面材质语义修复`](../voxel-far-field/2026-07-23-far-lod-surface-material-semantic-repair.md)。Online authority/provider、阶段 3 与 B/C 均未开始。
- **Voxia SVO 远景预览设计（2026-06-30，已归档)**:[`docs/20-archive/voxel-far-field/2026-06-30-voxia-svo-preview-design.md`](../../20-archive/voxel-far-field/2026-06-30-voxia-svo-preview-design.md) —— 历史 occupancy preview 与性能目标证据；不定义当前 shell/page/live 契约。
- **Voxia 远景公共组件抽取 + VHI 2.5D baseline 定位（2026-06-30，已归档)**:[`docs/20-archive/voxel-far-field/2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md`](../../20-archive/voxel-far-field/2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md) —— 历史组件抽取与 2.5D baseline 证据；不得作为当前 coverage 或内容模型。
- **Voxia 体素管理管线历史生产路线（2026-07-05，已归档)**:[`docs/20-archive/voxel-far-field/2026-07-05-voxia-voxel-lod-production-route.md`](../../20-archive/voxel-far-field/2026-07-05-voxia-voxel-lod-production-route.md) —— 历史 L0-L4 路线与预算证据；其中 XZ/column 与 raymarch 候选口径已被当前纯 3D、mesh-only 作战主线取代。
- **GPT-5.5 LOD2/LOD3 外部方案对抗评审（2026-07-06)**:[`docs/20-archive/voxel-far-field/2026-07-06-gpt55-lod23-proposal-review.md`](../../20-archive/voxel-far-field/2026-07-06-gpt55-lod23-proposal-review.md) —— 对 `docs/design/` 下两份外部 GPT-5.5 远景方案的评审：数据源裁决（维持 source pages 主线，客户端 WorldGen 重启需五条件）、16 条采纳矩阵与净增量 TOP-5、UE 5.8 能力边界实证（Nanite 运行时构建 API 级不可行 / WP HLOD 输入为空集 / DynamicMesh StaticDraw 白送杠杆）、LOD 预算数学。
- **Voxia LOD 分层与各层技术选型设计（2026-07-06，已归档)**:[`docs/20-archive/voxel-far-field/2026-07-06-voxia-lod-layering-and-technology-design.md`](../../20-archive/voxel-far-field/2026-07-06-voxia-lod-layering-and-technology-design.md) —— 历史分层、选型与预算证据；当前空间、page 和切流契约只看纯 3D 作战主线。
- **体素数据源终态裁决（2026-07-06 拍板)**:[`2026-07-06-projection-route-final-decision.md`](../../30-reference/contracts/2026-07-06-projection-route-final-decision.md) —— **投影路线为终态**(客户端 snapshot-only:近窗 1m + 远区 7m);同构路线(客户端 WorldGen ⊕ overlay)降格为特定负载画像下的定向优化选项(处女地定向加法);客户端 WorldGen 永久定位 preview/fixture 源;五维度裁决依据(带宽三折扣/内容演化/信息不对称/一致性面/不可逆性)。
- **体素数据链路术语表（2026-07-06 拍板)**:[`glossary.md`](../../30-reference/protocol/glossary.md) —— base / delta / truth / snapshot 四词统一口径:客户端 snapshot-only(近窗 1m + 远区 7m 双分辨率),`base ⊕ delta` 是服务端生产配方;含远区修改回流回路与三条既有裁决索引。数据链路口径与 6-30 名词解释表冲突时以本表为准。
- **架构对齐迁移主线（2026-06-14 起,当前最高层索引)**:[`docs/20-archive/voxel-authority/2026-06-14-architecture-triage-and-alignment.md`](../../20-archive/voxel-authority/2026-06-14-architecture-triage-and-alignment.md) —— 对照冻结规范 v2.0.2 的分诊、四项拍板、规范反哺修订、梯队迁移顺序。本目录原有 Phase 1–8 工作被纳入该主线统筹。
- 冻结规范(权威):[`docs/30-reference/overview/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`](../../30-reference/overview/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md)（已含 v2.0.2 反哺修订）
- 架构现状与缺口分析:[`docs/20-archive/voxel-authority/2026-05-07-体素服务器权威化架构进度检查.md`](../../20-archive/voxel-authority/2026-05-07-体素服务器权威化架构进度检查.md)
- 协议规范:[`docs/30-reference/protocol/2026-04-10-线协议规范.md`](../../30-reference/protocol/2026-04-10-线协议规范.md)
- 服务端权威体素数据协议设计:[`docs/30-reference/protocol/2026-04-29-server-authoritative-voxel-data-protocol-design.md`](../../30-reference/protocol/2026-04-29-server-authoritative-voxel-data-protocol-design.md)
- 联调状态:[`docs/20-archive/voxel-authority/2026-05-06-服务端权威体素联调状态.md`](../../20-archive/voxel-authority/2026-05-06-服务端权威体素联调状态.md)

## 阶段总览

将原文档的 Phase 1 拆分为四个更小可交付的切片,Phase 2 起按原文档命名沿用。

| 阶段 | 范围 | 状态 | 计划文件 |
| --- | --- | --- | --- |
| 1a | RefinedCellData typed domain (read-only wire) | 已完成 | [`phase-1a-refined-cell-domain.md`](../../20-archive/voxel-authority/phase-1a-refined-cell-domain.md) |
| 1b | typed `VoxelEditIntent` (decode-only) + `VoxelImpactIntent` 进入 deprecation | 已完成 | [`phase-1b-typed-edit-intent.md`](../../20-archive/voxel-authority/phase-1b-typed-edit-intent.md) |
| 1c | Scene refined mutation API + `CellRefined` delta | 已完成 | [`phase-1c-refined-mutation.md`](../../20-archive/voxel-authority/phase-1c-refined-mutation.md) |
| 1d | DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | [`phase-1d-canonical-persistence.md`](../../20-archive/voxel-authority/phase-1d-canonical-persistence.md) |
| 2 | (原文档 Phase 2)refined micro edit 端到端贯通 | 已完成(被 1c 吸收) | [`phase-2-micro-edit-roundtrip.md`](../../20-archive/voxel-authority/phase-2-micro-edit-roundtrip.md) |
| 3 | prefab v2 事务化(World/Scene transaction coordinator) | 已完成 | [`phase-3-prefab-v2-transactions.md`](../../20-archive/voxel-authority/phase-3-prefab-v2-transactions.md) |
| 3-bis | fence persistence + auto-resume commit(crash safety 闭环) | 已完成 | [`phase-3-bis-fence-and-resume.md`](../../20-archive/voxel-authority/phase-3-bis-fence-and-resume.md) |
| 4 | object provenance、局部破坏与整体销毁 | 已完成 | [`phase-4-object-provenance.md`](../../20-archive/voxel-authority/phase-4-object-provenance.md) |
| 4-bis | ObjectStateDelta 推送链路 + 客户端碎屑粒子消费 | 服务端 `ObjectStateDelta` 推送已完成；归档 Web slice 的碎屑粒子消费当时已完成，仅作历史证据，不代表 Voxia 完成 | [`phase-4-bis-object-state-delta-push.md`](../../20-archive/voxel-authority/phase-4-bis-object-state-delta-push.md) |
| A2 | 阶段 A 子 1:尺寸真实化(角色 1.7m / 跑速 6 m/s / apex 1.2m) | 已完成 | [`phase-A2-real-world-scale.md`](../../20-archive/movement-sync/phase-A2-real-world-scale.md) |
| A1 | 阶段 A 子 2:客户端可玩 demo 必须线(prefab micro / 防覆盖 / 线框预览 / 跳跃同步 / 破坏技能) | 服务端 prefab / movement / damage 支撑当时已完成；归档 Web 可玩 demo slice 当时已完成，仅作历史证据，不代表 Voxia 完成 | [`phase-A1-playable-client-experience.md`](../../20-archive/client/phase-A1-playable-client-experience.md) |
| A4 | 阶段 A 子 4:跨 region prefab 多 participant 事务 + 跨节点 damage / 0x6C owner-driven fan-out(主体) | 已完成 | [`phase-A4-cross-region-prefab.md`](../../20-archive/voxel-authority/phase-A4-cross-region-prefab.md) |
| A4-bis-cluster | A4 子阶段:真正的多 scene_node 分布式部署(BeaconServer term key 升级 + RegionRouting + lease 按 scene_node 分配 + 双 BEAM e2e) | 决策稿就位 | [`phase-A4-cross-region-prefab.md`](../../20-archive/voxel-authority/phase-A4-cross-region-prefab.md)(文末专段) |
| 5 | 属性目录 + 温湿度基础模拟 | 已完成 | [`2026-05-13-phase5-backlog-and-subphase-decomposition.md`](../../20-archive/field-emergence/2026-05-13-phase5-backlog-and-subphase-decomposition.md) |
| 6 | 局部场最小目标(FieldLayer + 电场 + 温度场 + FieldDebugOverlay) | 服务端 `FieldLayer`、电场与温度场已完成；归档 Web `FieldDebugOverlay` slice 当时已完成，仅作历史证据，不代表 Voxia 完成 | [`2026-05-13-体素局部场最小目标-索引.md`](../../90-obsolete/field-emergence/2026-05-13-体素局部场最小目标-索引.md) |
| 7 | 局部场传播 Kernel 架构目标(FieldKernel + FieldRuntime) | 进行中（7.A 已完成；7.D1 SetTemperature/Cool 已完成；7.D2 温度 source 最小闭环已完成；7.D3 温度 FieldEffect 写回最小闭环已完成；7.E 第一批材料物性已完成；7.B ConductionPathKernel core/runtime 已完成；归档 Web 入口曾完成，只作历史实现证据，Voxia 等价交互未落地项属于后续客户端阶段 5，不重新打开已完成的扩展 A/A10；prefab 接入所有局部场的 projection 设计已就位；后续推进以 2026-05-16 roadmap 与 2026-05-19 prefab projection 设计为准） | [`2026-05-14-phase7-field-kernel-architecture.md`](../field-emergence/2026-05-14-phase7-field-kernel-architecture.md) / [`2026-05-16-phase7-local-field-runtime-roadmap.md`](../field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md) / [`2026-05-19-prefab-field-participant-projection.md`](../field-emergence/2026-05-19-prefab-field-participant-projection.md) |
| 8 | 物理现象系统(燃烧 / 结冰 / 结构完整度 / 碳化 / 腐蚀 / 相变) | 设计目标稿 | [`2026-05-16-phase8-physical-phenomenon-system-architecture.md`](../field-emergence/2026-05-16-phase8-physical-phenomenon-system-architecture.md) |
| Baseline/streaming delta migration（历史） | 体素生成、流送、Voxia 加载渲染从全量物化过渡到确定性 WorldGen + D/P + H gate | 已归档；术语和 H gate 证据保留，旧窗口形状失效 | [`2026-06-30-voxel-generation-streaming-client-plan.md`](../../20-archive/voxel-authority/2026-06-30-voxel-generation-streaming-client-plan.md) |
| Voxia 扩展里程碑 A | 客户端完整 XYZ near/far LOD、provider-neutral 数据流、原子 presentation 与流送性能 | **客户端 A8/A10 已完成**：27 Tile XYZ window、唯一根、source identity、request/residency/cancel/DAG/stable patch、三轴巡航、confirmed presentation 与 VXP5 精确外露面材质语义均通过；阶段 3、Online/B/C 后置 | [`上位计划`](../voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md) / [`材质语义修复`](../voxel-far-field/2026-07-23-far-lod-surface-material-semantic-repair.md) |
| WorldGen v1 旧稿（历史） | 旧 2.5D 高度场算法输入 | **已被纯 3D canonical chunk 契约取代；仅保留历史输入** | [`2026-06-30-worldgen-v1-deterministic-terrain-design.md`](../../20-archive/voxel-authority/2026-06-30-worldgen-v1-deterministic-terrain-design.md) |
| Voxia SVO preview（历史） | 旧 Sparse Voxel Octree macro-cell mesh proxy 与性能探索 | 已归档；仅保留证据，不定义当前 shell/page/live 契约 | [`2026-06-30-voxia-svo-preview-design.md`](../../20-archive/voxel-far-field/2026-06-30-voxia-svo-preview-design.md) |
| Voxia FarField 公共组件 + VHI baseline（历史） | 旧 coverage / 2.5D VHI / SVO 管线的组件与性能证据 | 已归档；可以复用正交组件和证据，但不得复活 XZ column、有限 Y 或 VHI 内容模型 | [`2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md`](../../20-archive/voxel-far-field/2026-06-30-voxia-farfield-common-components-and-vhi-baseline.md) |

| VLOD-A1 | 显式 tier + 四环 7/14/28/56m | 已完成；旧 device-removal 阻塞已由 A3.0 归因反转，不再挂在 A1 | [`phase-vlod-a1-explicit-tiering.md`](../../20-archive/voxel-far-field/phase-vlod-a1-explicit-tiering.md) |
| VLOD-A2 | 分组件 `UDynamicMeshComponent + StaticDraw`、组件剔除与 bulk-hide | 已完成；该阶段消除了结构性全量替换风险，但不是 device-removal 根因 | [`phase-vlod-a2-partitioned-staticdraw.md`](../../20-archive/voxel-far-field/phase-vlod-a2-partitioned-staticdraw.md) |
| VLOD-A3 | 体素 LOD 里程碑 A 步 3(诊断线):A3.0 诊断先行——原以为 per-cell merge 减 overdraw 可兑现 device-removal 根治 | **已结项/改判(2026-07-07,§9 Closure)**:A3.0 诊断满且价值兑现——证伪「overdraw=device-removal」(r16=0.49M 与 r72=1.39M 同崩)、定位真崩溃(raymarch probe×proxy-mesh 跨队列时序竞态)并**修复=raymarch 默认关(`clients/Voxia@1fc93d2`,采纳为生产终态)**;merge 与崩溃正交、**迁出至 A3b**;唯一未闭合=精确指令不可观测(Heisenbug+硬约束,封存非债) | [`phase-vlod-a3-per-cell-greedy-merge.md`](../../20-archive/voxel-far-field/phase-vlod-a3-per-cell-greedy-merge.md) |
| VLOD-A3b | 体素 LOD 里程碑 A 步 3(merge):远景 per-cell masked greedy merge(限 cell 内、视觉等价、tier 契约不变)——纯几何/带宽/内存优化 | **已完成(2026-07-07,Step 0-6)**:生产场景 quad 1.39M→593k(−57.3%)、契约/seam 不变;`Voxia` 全 36 测绿、真实 RHI 4 跑存活 0 device-removal;裁决保留 merge(FPS 中性——实测 FPS=像素-bound、Lumen 主导,非失败)。＋ **Lit-default**(远景消色差、Unlit 降 alt);渲染管线研究 + A/B/C 实测(剔除已证/Lumen ~2-4ms 量化)沉淀 | [`phase-vlod-a3b-per-cell-greedy-merge.md`](../../20-archive/voxel-far-field/phase-vlod-a3b-per-cell-greedy-merge.md) |
| VLOD-A4/A5 | coverage seam、互补 fade、3.5m collar、紧凑顶点、cache LRU/容量与原始 A 验收 | 已完成并归档；它只收口原 A1-A5，当前里程碑 A 已扩展到 A10 | [`phase-vlod-a4-seam-fade-collar.md`](../../20-archive/voxel-far-field/phase-vlod-a4-seam-fade-collar.md) |
| Voxia A6/A7 | near/far 流送 hot path、XYZ handoff、retirement lease、垂直活性与联合性能 | 已完成并归档 | [`phase-far-temporal-stability-and-seamless-streaming.md`](../../20-archive/voxel-far-field/phase-far-temporal-stability-and-seamless-streaming.md) / [`2026-07-11-near-far-presentation-handoff.md`](../../20-archive/voxel-far-field/2026-07-11-near-far-presentation-handoff.md) |
| Voxia B/C | B=生产投影契约与 fixture oracle；C=服务端 pages/dirty/分发 | **均未开始**；当前不得从 A10 跳转 | [`2026-07-06-voxia-lod-layering-and-technology-design.md`](../../20-archive/voxel-far-field/2026-07-06-voxia-lod-layering-and-technology-design.md) |

状态取值:`未开始` / `进行中` / `已完成` / `已搁置`。状态变更时同步更新本表与对应阶段文件的 `进度日志`。

Phase 6 已落地；Phase 7.A `FieldKernel` kernel-first 迁移已完成；Phase 7.D1 已把
`F` / `Heat` / `Cool` / `voxel_temp` 动作接到服务端：先写 voxel `temperature` 属性，再由
`FieldRuntime` 从 voxel truth 检测异常并创建/复用局部场；归档 `web_client` 曾在 set-temperature
成功后自动打开 Field overlay，这只作为历史实现证据。Voxia 等价入口未落地项属于后续客户端阶段 5，
不得以 Web 完成替代，也不重新打开扩展 A/A10。Phase 7.D2 已为温度路径补上 `FieldSource` runtime 事实、
source lifecycle observability，以及回到环境阈值内时的 0x74 region cleanup。Phase 7.D3
已补上温度 `FieldEffect` 最小写回边界：worker 交付 non-observe effects，`ChunkProcess`
作为 chunk authority 应用 `write_voxel_attribute(:temperature)` 或明确 reject unsupported effect。
Phase 7.E 第一批材料物性（电导/击穿强度等）已落地；Phase 7.B 已把
`ConductionPathKernel` 接入 `FieldRuntime.ensure_conduction_path/1` 和 HTTP
`/ingame/voxel/conduct`。归档 Web CLI `voxel_conduct` 曾在成功请求后自动打开 Field overlay，
这只作为历史实现证据；Voxia 等价导电交互与 overlay 未落地项属于后续客户端阶段 5，
不得以 Web 完成替代，也不重新打开扩展 A/A10。Phase 7.F 前置第一片已让
electric conduction 也走 owner-aware `FieldSource`，HTTP/runtime 可携带 `source_mode`、
`ttl_ticks` 和 `energy_budget_joules`，其中 ttl 会约束当前 conduction region lifetime；
ttl 到期会释放 source 并通过既有 0x74 destroy payload 让客户端看到 field 消失；导电预检失败
会写 `voxel_conduction_path_rejected` observe，保留预算耗尽等更细失败原因和 source/target
定位字段；`PowerSource` v1 已让导电请求可声明 DC / AC / pulse、voltage、current limit 和
frequency；HTTP 透传与 summary 回显仍是服务端事实。归档 Web CLI 曾消费同一入口，只作历史
实现证据；Voxia 等价 PowerSource 参数交互未落地项属于后续客户端阶段 5，不重新打开扩展 A/A10。
默认物理来源已收敛到
`material_id=6` 的 `power_block`：普通 iron 只做导线，未显式传 owner/power 参数时不能凭空供电。
electric-to-thermal 第一片已接入：导电路径会把 source voltage 和 load current 估算成焦耳热
FieldEffect，由 `ChunkProcess` 写回 voxel 温度 truth；HTTP 可透传 `load_current_amps`
和 `energy_budget_joules`，过载负载会以 `current_limit_exceeded` 拒绝。归档 Web CLI 曾透传这两个
参数，只作历史实现证据；Voxia 等价参数交互未落地项属于后续客户端阶段 5，不重新打开扩展 A/A10。
当前仍不做完整电路仿真、持续能量扣减或材料熔断破坏。归档浏览器 GUI 曾有第一版热烟可视化：导电 accepted 后，
`power_draw.estimated_tick_energy_joules` 会注册为 Field Overlay 热烟源，后续 electric field
snapshot 按热量比例生成灰色上升烟粒子，方块本体不因这条电热链路染色；归档 Web CLI
`field_overlay` 曾返回每个 region 的 `smoke` 粒子数。以上只作为历史客户端实现证据；Voxia 等价
热烟表现与 overlay CLI 未落地项属于后续客户端阶段 5，不得以 Web 完成替代，也不重新打开扩展 A/A10。
自动电路 current overlay 以 `CircuitComponentAnalysis` 的闭合 source-load 谓词作为 runtime
准入条件：只有 graph 2-core 中同时包含 power source 与 load 时才创建/保留 current field；
开路 source-load 会返回 `no_closed_circuit`，断环会释放对应 region/source，而不是保留空
topology watcher。
后续路线图以
[`2026-05-16-phase7-local-field-runtime-roadmap.md`](../field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md)
为准；prefab 接入所有局部场的架构边界以
[`2026-05-19-prefab-field-participant-projection.md`](../field-emergence/2026-05-19-prefab-field-participant-projection.md)
为准，电场只是首条验证路径，不应把 prefab 写成电场专用特判。下一步关注 source owner 存活/预算消耗、跨 chunk/AOI 预算与 Phase 8 effect 边界。Phase 8
物理现象系统已落设计目标稿，但不应由导电 kernel 直接实现伤害、击穿破坏或 object/combat 结算。

## 跟踪约定

- **一阶段一文件**:每个阶段开始前先建 `phase-<id>-<slug>.md`,内含目标、范围、文件清单、改动点、测试矩阵、验收标准、进度日志。
- **进度日志按时间倒序追加**:每次推进、卡点、决策都补一行 `YYYY-MM-DD: ...`。
- **不要把行为变更与 README 索引耦合**:索引只反映阶段状态,具体决策与变更证据写在阶段文件里。
- **完成后不删除文件**:状态改为 `已完成`,留作后续阶段查证依据。
