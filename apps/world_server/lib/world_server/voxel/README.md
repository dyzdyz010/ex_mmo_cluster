# WorldServer 体素边界

本目录拥有 World 侧体素控制面。控制面指决定“谁拥有区域、谁能写、请求要路由到哪里”的
低频权威逻辑，不保存完整区块内容，也不执行逐帧体素规则。

- `MapLedger` 拥有区域分配、租约签发、路由查询、Gate / Scene 当前租约查询，以及事务参与者规划。
  传 `persistence_path: <file>` 启动时，每次 state 突变都会原子写入该文件
  （`<path>.tmp` → `rename`），下次启动时自动 `binary_to_term/2` 还原 assignments、
  leases、chunk_summaries、migrations。文件路径未给则保持纯内存行为，外层 supervisor /
  application 可决定是否启用。这一版只支持单节点本地文件；多节点 / Postgres 持久化是
  后续切片（保留同一接口边界即可平滑替换）。
  另外可传 `scene_invalidator: fn attrs -> result end`（1-arity 函数），`attrs` 形如
  `%{logical_scene_id, chunk_coord, reason}`。在 `cutover_migration/2` 成功之后，ledger 会
  在 `affected_chunk_min .. affected_chunk_max`（半开）内的每一个 chunk_coord 上调用一次
  invalidator，`reason` 固定为 `0x01`（`:migration_cutover`）。默认 `nil` 表示不触发任何
  Scene 侧失效广播；invalidator 异常或返回 `{:error, _}` 不会回滚切换，只会在 observe
  日志里记录（事件 `voxel_migration_cutover_invalidate_emitted` /
  `voxel_migration_cutover_invalidate_failed`）。这样让 World 控制面保持不直接耦合
  `scene_server`，由 `AuthorityObserve` 等上层 runner 注入实际 `ChunkDirectory.invalidate_chunk/2`。
- `RegionAssignment` 是可持久化的区域拥有者记录。
- `SceneLease` 是发给某个 Scene 实例的热写入授权；租约过期或纪元不匹配时，Scene 不能写。
- `LeaseWriteToken` 是从租约派生出的 DataService 写入围栏；DataService 用它拒绝旧拥有者写入。
- `MigrationPlan` 是 World 拥有的分阶段区域迁移交接状态机。它记录源 / 目标 Scene 引用、
  新旧租约、受影响区块范围、预热切片和当前迁移阶段。目标 Scene 预热时读取交接载荷；
  World 只在切换阶段改变路由并发布新的写入令牌。
- `TransactionParticipant` 和 `BuildTransaction` 描述可恢复的跨区域工作。
- `TransactionCoordinator` 拥有 World 侧 `BuildTransaction` 状态机。它记录参与者准备确认，
  并为每个 `transaction_id + decision_version` 记录唯一提交 / 放弃决策。调用方负责把
  prepare/commit/abort 真的送到 Scene；coordinator 本身不做 RPC，只承担状态机和幂等账本。
  **持久化（Phase 3-1 起）**：通过启动选项 `:persist_fn` / `:load_fn` 注入；生产路径在
  `WorldSup` 里注入 `DataService.Voxel.TransactionCoordinatorStore`，每次 state 变更后单行
  upsert 写 `voxel_transaction_coordinator_snapshots` 表，节点重启时 `init/1` 自动加载。
  无文件持久化路径（Phase 3-1 后已移除），测试场景下不传 `:persist_fn` / `:load_fn` 即可
  纯内存运行。
- `TransactionExecutor` 是驱动 `TransactionCoordinator` 的并行 dispatcher。它对 participants
  用 `Task.async_stream` 同时调 Scene 侧 `BuildTransactionApplier.prepare/4`、把每个返回的
  `:prepared` / `:failed` 转成 `prepare_ack`，然后按 coordinator 的最终状态再并行调
  `commit/3` 或 `abort/3`，最后回写 `commit_decision` 或 `abort_decision`。每个 participant
  有 `:per_participant_timeout_ms`（prepare 默认 5_000ms，commit / abort 可单独配
  `:commit_timeout_ms` / `:abort_timeout_ms`），整个 executor pass 还有
  `:transaction_timeout_ms`（默认 30_000ms）的整体期限。超时、`{:exit, _}` 或 `{:error, _}` 一律
  作为 `:failed` ack 上报，结构化失败原因（`:timeout` / `:transaction_timeout` /
  `{:participant_crashed, _}`）记入 `prepare_results`。executor 对 scene caller 的返回值用
  `try/rescue/catch` 包了一层，单个 participant 抛异常 / `exit` 不会拖垮 executor 进程。
  对已经决定的事务做 replay 时短路返回，不重复触发 Scene 侧动作。executor 在 Phase 3 由 Gate
  进程同步驱动（Gate 拿 `{TransactionCoordinator, world_node}` ref，跨节点 prepare/commit
  ack；scene call 通过 `chunk_directory: {ChunkDirectory, scene_node}` opt 跨节点路由），
  Gate 0x67 dispatch 等执行结果直接成包回客户端。
- `TransactionRecoveryWatcher` 是 Phase 3-2 加入的一次性恢复扫描器，与
  `TransactionCoordinator` 一起被 `WorldSup` 启动。它在 init 时读取 coordinator 当前
  snapshot，对 `:preparing` / `:aborting` 状态的 in-flight 事务自动调 `abort_decision/3`
  滚回；对 `:prepared` 状态的事务保持挂着并 emit `voxel_transaction_recovery_pending_commit`
  observe 事件提示运维（auto-resume commit 需要 intents_by_participant 持久化，留 Phase
  3-bis）；对 `:committed` / `:aborted` 状态跳过。所有动作幂等，watcher 自身被 supervisor
  restart 时重放扫描也无副作用。
- `BoundaryVoxelEvent` 记录 Scene 到 Scene 规则传播必须携带的租约字段。
- `AuthorityObserve` 是 `mix world_server.voxel_observe` 使用的非 GUI 验收运行器。它启动或复用真实
  ledger / token-store 进程，发布租约、路由区块、开始分阶段迁移、规划预热切片、读取交接载荷、
  标记预热、切换、完成迁移，并把写入令牌校验结果写入结构化日志，供 CLI 和测试检查。
  额外可选项：`:scene_invalidator` 直接传 1-arity 函数；`:scene_chunk_directory` 传一个
  `SceneServer.Voxel.ChunkDirectory` 的 pid/name，runner 会用 `scene_directory_invalidator/1`
  构造一个调用 `ChunkDirectory.invalidate_chunk/2` 的 invalidator 注入到内部启动的
  ledger。两者只在 runner 自己创建 ledger 时生效；调用方自带 `:ledger` 时由调用方决定。
- `DevSeed` 是本地网页 / CLI 冒烟使用的幂等入口。它只准备默认区域、租约和 DataService 写入令牌，
  不保存区块真相，也不绕过 Scene；浏览器随后仍要通过 Gate 订阅和提交 intent。已有区域再次 seed
  时会续发开发租约，并通过 Scene 的批量 intent 路径一次性准备 y=0 的 16×16 起始地面，避免网页
  长时间运行或刷新后出现“能订阅旧快照、但写入被租约过期拒绝”的假健康状态。

`route_chunk_with_lease/3` 是 Gate 向 Scene 请求区块快照前使用的控制面交接函数。它让客户端路径
先对齐 World 权威，同时仍然把完整区块真相留在 Scene。

`begin_migration/4`, `plan_next_migration_slice/2`, `migration_handoff/2`,
`mark_slice_prewarmed/3`, `mark_prewarmed/2`, `mark_slice_final_caught_up/3`,
`cutover_migration/2` 和 `complete_migration/2` 是可观测迁移 API。
`migration_handoff/2` 返回给目标 Scene 的交接载荷，不改变 World 状态；载荷包含
`migration_id`、逻辑场景和区域 id、当前迁移阶段、源 / 目标 Scene 引用、旧租约、待切换的
新租约、写入令牌版本、受影响区块边界、已规划的预热切片、下一切片索引和总切片数。
`mark_prewarmed/2` 只在全部预热切片已经规划、并通过 `mark_slice_prewarmed/3` 收到目标 Scene
逐切片 ACK 后成功；目标 Scene 仍要通过自己的预热适配器读取 DataService 快照并准备热区块，
World 不直接搬运区块内容。
`cutover_migration/2` 还要求每个切片都通过 `mark_slice_final_caught_up/3` 提交最终追平 ACK；
最终追平指源 Scene 已把切换前最后一版热区块写入 DataService，目标 Scene 已重新加载这些
最新快照。这样预热完成到租约切换之间的写入不会只留在旧 owner 内存里。
`migrate_region/4` 保持旧调用方兼容，但内部走同一条“建计划、预热、切换、完成”路径，并保留
已完成的迁移快照用于观察。

WorldServer 不保存完整区块真相，也不运行高频体素规则。它只决定拥有者，并发布写入围栏，
防止迁移后的旧 Scene 进程继续写入。
