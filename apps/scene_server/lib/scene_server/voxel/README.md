# SceneServer 体素运行时

本目录拥有 Scene 侧热体素执行状态。热体素状态指当前租约内、需要被快速读写的区块内存状态。

`SceneServer.Voxel.RegionRuntime` 是第一层区域运行时。它记录本地租约，缓存邻区租约元数据，
并在接受跨边界规则传播之前校验 `BoundaryVoxelEvent` 字段。跨边界事件如果带着旧租约，
会在影响热状态之前被拒绝。

`SceneServer.Voxel.ChunkProcess` 拥有一个已租约区块的热状态。它通过
`SceneServer.Voxel.Codec` 生成大端序快照载荷，并写入
`DataService.Voxel.ChunkSnapshotStore`。DataService 在接受快照前会重新校验当前写入令牌。
迁移预热时，它也可以从已持久化快照加载热状态；这个加载路径不反写 DataService，只用于
让目标 Scene 在 World 切换前准备好区块内存。

`ChunkProcess.apply_intent/2` 是 World 已授权体素意图在 Scene 侧的最小写入路径。当前支持的
第一个操作是在一个区块内宏单元写入普通实体块。进程先计算候选快照，再带着租约请求
DataService 持久化；只有持久化通过后，才提交新的热状态并向订阅者推送快照回退消息。
快照回退消息指还没有实现紧凑 `ChunkDelta` 前，先用完整快照通知订阅者。缺失、过期、
越界或陈旧的租约都不会改变热区块。

`ChunkProcess.subscribe/3` 是第一版订阅接口。订阅者会立即拿到当前快照，并在本地区块变化后
收到完整快照回退推送。这个行为刻意保守，等紧凑 `ChunkDelta` 线格式实现后再替换为增量。

`SceneServer.Voxel.ChunkDirectory` 把 `{logical_scene_id, chunk_coord}` 解析到热区块进程，
并在 `SceneServer.VoxelChunkSup` 下按需启动缺失区块。Gate 只有在 World 已经路由区块并提供
当前租约之后，才会用它执行只读的 `ChunkSubscribe -> ChunkSnapshot` 路径。面向 World / Gate
的代码也可以用 `ChunkDirectory.apply_intent/2` 把已带租约的写入意图路由到拥有者区块，
但调用者本身不拥有区块真相。

`ChunkDirectory.prewarm_handoff/2` 消费 World 生成的迁移交接载荷。它按预热切片读取
DataService 中已有的区块快照，加载到目标 Scene 的热区块进程；没有快照的区块会以空区块
启动并应用新租约。预热切片指迁移前分批加载的半开区块范围。

`MigrationPrewarm.prewarm_slices/2` 是 Scene 侧迁移预热适配器。它逐切片调用
`ChunkDirectory.prewarm_handoff/2`，并返回可提交给 World `mark_slice_prewarmed/3` 的 ACK
数据；它不改变 World 迁移状态，也不保存迁移计划。
`MigrationPrewarm.final_catchup_slices/2` 是切换前最终追平适配器。它先要求源
`ChunkDirectory` 对切片内已经热启动的旧 owner 区块执行 `persist`，再让目标
`ChunkDirectory` 重新执行预热读取最新 DataService 快照，并返回可提交给 World
`mark_slice_final_caught_up/3` 的 ACK。Scene 仍不决定 cutover，只报告自己已准备到哪一版。

`ChunkProcess` 内还保留一个**事务围栏 (`pending_fence`)**：
`prepare_transaction/4` 接收一份**意图清单 (intents 列表)**，全部归一化 + 通过 batch
scope/precondition 校验后整体存为 fence，并在期间拒绝其它 ad-hoc `apply_intent/2`；
`commit_transaction/2` 走 `apply_normalized_intents/2` 把 fence 内所有 intent 一次性
应用到 chunk storage（chunk-local 原子：任一 intent 应用失败就整 chunk 回滚到 prepare
前 storage），然后清掉 fence；`abort_transaction/2` 直接清 fence、不写入。同
`transaction_id` 的二次 prepare 是幂等的，其他事务来抢同一区块会立即拿到
`:chunk_already_fenced`。这一对 API 只面向上层 `BuildTransactionApplier`，不暴露给
Gate/玩家路径。

**Phase 3-bis：fence 持久化** —— `prepare_transaction/4` 在归一化后**同步写入**
`DataService.Voxel.ChunkPendingTransactionStore`（新表 `voxel_chunk_pending_transactions`，
按 `(logical_scene_id, coord_x, coord_y, coord_z)` 复合主键）；
DB INSERT 失败时 fence 不被接受，prepare 回 `:fence_persist_failed`。
`commit_transaction/2` / `abort_transaction/2` 同步 DELETE 该行。`init/1` 启动时按
`(logical_scene_id, chunk_coord)` 查表：若行存在且 `owner_*` 与当前 lease 完全匹配，
fence 被装回 `state.pending_fence`；不匹配（lease 已换 epoch / 转给别的 Scene 实例）
则视为孤儿，DELETE + emit `voxel_chunk_pending_transaction_orphaned`。`fence_payload`
是归一化 intent batch 的 `:erlang.term_to_binary/1` blob，反序列化用 `[:safe]` 模式。
节点重启 + lease 不变时,Watcher 重发 commit dispatch 能在新 ChunkProcess 上直接走通。

`SceneServer.Voxel.BuildTransactionApplier` 是把上面三个原语聚合成 World 视角下
participant 级 prepare/commit/abort 的薄适配器：

- `prepare/4` 接收 `intents_by_chunk :: %{chunk_coord => [intent_attrs, ...]}`，按
  participant 的 `affected_chunks` 顺序对每个 chunk 调
  `ChunkDirectory.prepare_transaction/3`，遇到第一处失败就把已经 prepared 的 chunk
  全部 `abort_transaction/3` 滚回，使一个 participant 要么完全 prepared、要么完全没占。
- `commit/3` 对每个 chunk 调 `commit_transaction/3`，逐块应用预存的整批 intents。
- `abort/3` 幂等释放每个 chunk 的 fence；可以在 prepare 部分失败后安全调用。

权威边界如下：

- WorldServer 拥有区域分配，并决定哪个 Scene 实例可以写。
- SceneServer 只拥有当前已租约区域的热执行状态。
- DataService 只有在写入令牌匹配当前 World 租约时，才持久化区块真相。

`SceneServer.Voxel.BlueprintCatalog` 是 v1 写死的预制蓝图目录。它把 `blueprint_id`
映射到固定的宏单元偏移列表 + 单一材质 id，并强制 `blueprint_version` 必须为 1。当前
v1 catalog 内容：

| id | name                | 形状                            | material_id |
|----|---------------------|---------------------------------|-------------|
| 1  | builtin_pillar_3    | 沿 y 轴 3 个垂直方块            | 1           |
| 2  | builtin_floor_3x3   | y=0 平面 3×3 共 9 个方块        | 2           |
| 3  | builtin_cube_2x2x2  | 2×2×2 共 8 个方块               | 3           |

`SceneServer.Voxel.PrefabRaster.rasterize/4` 是把蓝图 + 锚点光栅化为
`(chunk_coord, local_macro, NormalBlockData)` 写入单元的纯函数。它先把
`anchor_world_micro` 用 `floor_div` 转成 world-macro 锚点，再加上每个 cell 偏移，
最后通过 `Types.chunk_and_local_macro!/1` 解出宏块所属的 chunk + 本地坐标。所有
cell 共用同一份 `NormalBlockData.new(material_id, health: 100)`。`group_by_chunk/1`
方便按 chunk 聚合统计。当前 v1 不支持非 0 旋转、亚网格预制、跨蓝图版本协商；这些
都在 v2 实现。

Gate 上的 `0x67 PrefabPlaceIntent` 真实路径（Phase 3 起）：先通过 `BlueprintCatalog` +
`PrefabRaster` 拿到 cell 列表，按 `chunk_coord` 分组成
`%{chunk_coord => [intent_attrs, ...]}` 一份 intents-by-chunk 计划；通过 World 的
`MapLedger.route_chunk_with_lease` 解出第一个 chunk 的 lease 与 scene_node，并把同一
lease 复用到 prefab 跨过的全部 chunk（Phase 3 D6：第一刀只支持单 region 单 lease 多
chunk）。然后 Gate 远程调 `WorldServer.Voxel.TransactionCoordinator.begin_transaction/3`
建立事务，并在 Gate 进程内同步运行 `WorldServer.Voxel.TransactionExecutor.execute/4`
驱动 `BuildTransactionApplier` 跨节点对 `{ChunkDirectory, scene_node}` 走 prepare /
commit / abort 三相。**任一 chunk 的 prepare 失败或 commit 时 batch apply 失败都会回滚
全部 fence**：客户端要么收到 `VoxelIntentResult{Accepted, max_chunk_version}`（全部生效），
要么收到 `VoxelIntentResult{Rejected, reason}` 且 chunk 状态全部回到 prepare 前。**v1
的 cell-by-cell + 部分写不回滚行为已被替换**。

后续切片会在同一子树下补充紧凑区块增量、跨 region 多 participant 事务、per-region
coordinator 切片，以及更完整的迁移回滚。
