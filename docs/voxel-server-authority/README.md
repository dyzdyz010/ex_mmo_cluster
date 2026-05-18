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
| 7 | 局部场传播 Kernel 架构目标(FieldKernel + FieldRuntime) | 进行中（7.A 已完成；7.D1 SetTemperature/Cool 已完成；7.D2 温度 source 最小闭环已完成；7.D3 温度 FieldEffect 写回最小闭环已完成；7.E 第一批材料物性已完成；7.B ConductionPathKernel core/runtime/web 入口已完成；后续推进以 2026-05-16 roadmap 为准） | [`2026-05-14-phase7-field-kernel-architecture.md`](../plans/2026-05-14-phase7-field-kernel-architecture.md) / [`2026-05-16-phase7-local-field-runtime-roadmap.md`](../plans/2026-05-16-phase7-local-field-runtime-roadmap.md) |
| 8 | 物理现象系统(燃烧 / 结冰 / 结构完整度 / 碳化 / 腐蚀 / 相变) | 设计目标稿 | [`2026-05-16-phase8-physical-phenomenon-system-architecture.md`](../plans/2026-05-16-phase8-physical-phenomenon-system-architecture.md) |

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
和 web CLI `voxel_conduct`，成功请求会自动打开 Field overlay。后续路线图以
[`2026-05-16-phase7-local-field-runtime-roadmap.md`](../plans/2026-05-16-phase7-local-field-runtime-roadmap.md)
为准：下一步关注 generic source lifecycle、跨 chunk/AOI 预算与 Phase 8 effect 边界。Phase 8
物理现象系统已落设计目标稿，但不应由导电 kernel 直接实现伤害、击穿破坏或 object/combat 结算。

## 跟踪约定

- **一阶段一文件**:每个阶段开始前先建 `phase-<id>-<slug>.md`,内含目标、范围、文件清单、改动点、测试矩阵、验收标准、进度日志。
- **进度日志按时间倒序追加**:每次推进、卡点、决策都补一行 `YYYY-MM-DD: ...`。
- **不要把行为变更与 README 索引耦合**:索引只反映阶段状态,具体决策与变更证据写在阶段文件里。
- **完成后不删除文件**:状态改为 `已完成`,留作后续阶段查证依据。
