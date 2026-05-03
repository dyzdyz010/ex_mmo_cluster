# WorldServer 体素边界

本目录拥有 World 侧体素控制面。控制面指决定“谁拥有区域、谁能写、请求要路由到哪里”的
低频权威逻辑，不保存完整区块内容，也不执行逐帧体素规则。

- `MapLedger` 拥有区域分配、租约签发、路由查询、Gate / Scene 当前租约查询，以及事务参与者规划。
- `RegionAssignment` 是可持久化的区域拥有者记录。
- `SceneLease` 是发给某个 Scene 实例的热写入授权；租约过期或纪元不匹配时，Scene 不能写。
- `LeaseWriteToken` 是从租约派生出的 DataService 写入围栏；DataService 用它拒绝旧拥有者写入。
- `MigrationPlan` 是 World 拥有的分阶段区域迁移交接状态机。它记录源 / 目标 Scene 引用、
  新旧租约、受影响区块范围、预热切片和当前迁移阶段。目标 Scene 预热时读取交接载荷；
  World 只在切换阶段改变路由并发布新的写入令牌。
- `TransactionParticipant` 和 `BuildTransaction` 描述可恢复的跨区域工作。
- `TransactionCoordinator` 拥有 World 侧内存版 `BuildTransaction` 状态机。它记录参与者准备确认，
  并为每个 `transaction_id + decision_version` 记录唯一提交 / 放弃决策，不直接调用 Scene。
- `BoundaryVoxelEvent` 记录 Scene 到 Scene 规则传播必须携带的租约字段。
- `AuthorityObserve` 是 `mix world_server.voxel_observe` 使用的非 GUI 验收运行器。它启动或复用真实
  ledger / token-store 进程，发布租约、路由区块、开始分阶段迁移、规划预热切片、读取交接载荷、
  标记预热、切换、完成迁移，并把写入令牌校验结果写入结构化日志，供 CLI 和测试检查。

`route_chunk_with_lease/3` 是 Gate 向 Scene 请求区块快照前使用的控制面交接函数。它让客户端路径
先对齐 World 权威，同时仍然把完整区块真相留在 Scene。

`begin_migration/4`, `plan_next_migration_slice/2`, `migration_handoff/2`,
`mark_prewarmed/2`, `cutover_migration/2` 和 `complete_migration/2` 是可观测迁移 API。
`migration_handoff/2` 返回给目标 Scene 的交接载荷，不改变 World 状态；载荷包含
`migration_id`、逻辑场景和区域 id、当前迁移阶段、源 / 目标 Scene 引用、旧租约、待切换的
新租约、写入令牌版本、受影响区块边界、已规划的预热切片、下一切片索引和总切片数。
`mark_prewarmed/2` 只在全部预热切片已经规划后成功；目标 Scene 仍要通过自己的预热适配器
读取 DataService 快照并准备热区块，World 不直接搬运区块内容。
`migrate_region/4` 保持旧调用方兼容，但内部走同一条“建计划、预热、切换、完成”路径，并保留
已完成的迁移快照用于观察。

WorldServer 不保存完整区块真相，也不运行高频体素规则。它只决定拥有者，并发布写入围栏，
防止迁移后的旧 Scene 进程继续写入。
