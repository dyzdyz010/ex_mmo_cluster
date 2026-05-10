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
`(chunk_coord, local_macro, micro_slot, layer_attrs)` 写入单元的纯函数。
**Phase A1 hotfix(2026-05-09)起按 world-micro 精度落地**：每个 occupied
slot 把 `(slot_x, slot_y, slot_z)` 加到 `anchor_world_micro` 后，再
`floor_div / floor_mod` 拆出该 cell 的 `(chunk_coord, local_macro, micro_slot)`。
这样 macro-aligned 锚点是退化情形（单 macro / 单 chunk），mid-macro 锚点会
让 prefab 自然跨 2~8 个 macros / 1~4 个 chunks，与客户端 boundary-snap
线框预览像素级一致。所有 cell 共用同一份 `layer_attrs = %{material_id, health: 100}`。
`group_by_chunk/1` 方便按 chunk 聚合做 per-chunk 事务参与方分发。当前 v2 不支持
非 0 旋转、跨 region 多 lease 事务（gate dispatch 仍是 single-lease，跨 region
prefab 在 backlog）。

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

**Phase 4：object provenance + part-health 破坏闭环** ——
`MicroLayer.owner_object_id` / `owner_part_id` 已在 Phase 1c 落地；Phase 4
让真实 prefab 写入时填实这两字段，并补齐反向索引与破坏链路：

- `Storage.refresh_chunk_object_refs/1`：整 chunk 重算策略——从 layer truth
  推导 cell 级 `ObjectCoverRef[]` + chunk 级 `ChunkObjectRef[]`（含
  AABB + xxHash64 cover_hash）。`apply_normalized_intent` /
  `apply_normalized_intents` / `destroy_part` 三处自动触发。
- `Storage.lookup_owner_at/3`：反向查 `(macro, slot) → {object_id, part_id} | nil`，
  damage attribution 路径用。
- `SceneServer.Voxel.PartState`：`%{part_id, health, state_flags}`，带
  damaged / destroyed 位 + `apply_damage` / `mark_damaged` / `mark_destroyed`
  helper。Phase 4 health 初始值 = part 占用的 micro 数 × ratio（默认 1.0，
  Phase 5 引入 `PartDefinition.default_health_ratio` 协议字段后改 per-part）。
- `SceneServer.Voxel.ObjectRegistry`：per-scene GenServer，持
  `SceneObjectInstance` 内存真相 + 同步落 `voxel_scene_objects`。API：
  `lookup_object/3`、`list_objects_in_chunk/3`、`upsert_object/2`、
  `apply_chunk_cover_change/5`、`accumulate_damage/6`、`destroy_part/5`、
  `destroy_object/4`、`load_scene/2`（lazy）、`snapshot/1`、`reset/1`（test）。
  `accumulate_damage` 同步 cascade 到 `destroy_part`（health <= 0）→
  `destroy_object`（所有 part destroyed）。
- `ChunkProcess` damage attribution：每次 commit 前用
  `Storage.lookup_owner_at` 收集 `{(oid, pid) => damage_count}`，
  commit 后 `Task.start` 异步 dispatch 到 `ObjectRegistry.accumulate_damage`，
  打破 ChunkProcess → ObjectRegistry → ChunkDirectory →
  ChunkProcess.destroy_part 同步 deadlock。
- `ChunkProcess.destroy_part/2` / `cleanup_object_refs/2`：server-internal
  cleanup，不走 lease 校验但仍用当前 lease 持久化。`destroy_part` 扫所有
  refined cells 找 owner=X、part=Y 的 layer，逐 micro slot 调
  `Storage.clear_micro_block`，然后 refresh + bump version + persist。
- `BuildTransactionApplier.register_scene_objects/2`：World executor
  `commit_decision` 后，scene_caller 把 `transaction.scene_objects`（每条
  含已分配的 `object_id` + 初始 `part_states`）upsert 到 ObjectRegistry。
  失败 emit `voxel_scene_object_register_failed` 非阻塞。

破坏路径全链路 emit observe：`voxel_part_damaged` /
`voxel_part_destroyed` / `voxel_object_destroyed` /
`voxel_chunk_destroy_part`，Phase 5+ 下游钩子（掉落物 / 任务系统 /
资源回收）挂在这些 observe 上即可。

**Phase 4-bis：0x6C `ObjectStateDelta` 推送链路** —— 把 Phase 4 D11 deferred
的"ObjectRegistry 状态变化 → 客户端"实际推送通道接完：

- `Codec.encode_voxel_object_state_delta_payload/1` /
  `decode_voxel_object_state_delta_payload/1`：协议 §9 `ObjectStateDelta`
  wire encode / decode。`attribute_patch_count` / `tag_patch_count` 字段
  Phase 4-bis 固定 0，decoder 透传非零值给 forward compat。Phase 4 期 codec
  最初放在 `gate_server/codec.ex`，Phase 4-bis 迁到 scene 端（与 chunk_delta
  / chunk_snapshot / chunk_invalidate 同位）；gate codec 改 binary
  pass-through。
- `PartState.flag_part_destroyed` = 0x04（与 `flag_damaged` 0x01 /
  `flag_destroyed` 0x02 配合，对齐 protocol §9 三段 state_flags 语义）。
- `ChunkDirectory.lookup_chunk_pid/3`：read-only，不 lazy-start，**只**返回
  已注册且 alive 的 ChunkProcess pid。给 ObjectRegistry dispatch 路径用。
- `ChunkProcess.push_object_state_delta_payload/2`：GenServer.cast 公共 API，
  接收已 encoded binary payload，handle_cast 调
  `fan_out_object_state_delta_payload`（私有）→
  `Enum.each(state.subscribers, send/2)` 镜像 `push_chunk_delta` 模式。
  Subscriber 收 `{:voxel_object_state_delta_payload, payload}`，gate
  ws/tcp_connection 同模式 forward 到 socket。
- `ObjectRegistry` 在 `emit_damage` / `emit_part_destroyed` /
  `emit_object_destroyed` 之后**同步**调 `dispatch_object_state_delta/3`：
  encode 一次 binary → 对每个 covered_chunk lookup_chunk_pid → cast push。
  失败（chunk 未启 / cast :exit）静默 try/catch + observe
  `voxel_object_state_delta_dispatch_failed`，不阻塞主路径。
  `run_destroy_object` 内 bump `instance.object_version` 保证 cascade 路径
  (part_destroyed → destroyed) 两条 0x6C 版本号严格单调（D5 客户端按
  version 单调去重）。`init_opts` 加 `:chunk_directory`（默认 module-named
  singleton；tests 注入 `FakeChunkDirectory`）。
- 4 个新 observe key：`voxel_object_state_delta_dispatch`（broadcast 起点）、
  `voxel_object_state_delta_push`（fan-out 到单 subscriber）、
  `voxel_object_state_delta_dispatch_failed`（lookup miss / cast :exit）、
  gate 端 `tcp_voxel_object_state_delta_forwarded` /
  `ws_voxel_object_state_delta_forwarded`。

state_flags 语义（D5）：每条 0x6C 表达**这次事件**触发的 flag（damaged /
part_destroyed / destroyed 三选一），**不**带累计 mask。客户端按
`object_version` 单调递增去重（D3）。

客户端消费形态（D6）：web_client 的 `OnlineVoxelWorldAdapter` 持
`ClearedSlotCache` + `DebrisSimulation`，consumer 去重通过后调
`handleObjectStateDeltaForDebris`：cache.take 命中 spawn 粒子；miss → 入
retry queue 100ms 后重试；仍空降级到 affected_chunks 中心点（档 A 兜底）。
`DebrisRenderer`（InstancedMesh 棕色立方体粒子）通过
`RenderOrchestrator` duck typing 接 scene。HUD destroyed flag 时显示
`object #N destroyed (M debris)` 提示 3.5s。

**已知 deferral**（Phase 5 接入 wire-form-as-truth 后落地）：
`ClearedSlotCache` 数据结构 + 100ms retry pipeline 已 wired 完整，但
`onlineVoxelWorldAdapter.applyDelta` 之前的 cache hook 未接（FRefinedCellData
还不携带 ownerObjectId 字段）。production 路径目前全走
`affected_chunks_fallback`（粒子在 chunk 中心点散开）。Phase 5 把
ownerObjectId 字段引入 FRefinedCellData 后，加一行 cache hook 即可升级到
精确档 B（沿被清空的 micro slot 散布）。

**Phase A4 新增**(跨 region prefab + 跨节点 damage / 0x6C 路由):

- `SceneServer.Voxel.ObjectOwnerLookup`(Phase A4-4):per-scene ETS-backed
  owner cache。hot path 直读 `:ets.lookup({scene_id, object_id})`,miss 走
  `GenServer.call({:resolve, ...})` SELECT `voxel_scene_objects`。冷启动
  miss 退化为 `%{owner_key => obj.covered_chunks}`(degenerate split,所有
  chunks 归 owner region;A4-bis-cluster 加 `MapLedger.region_for_chunk` 后
  退役该兜底)。`register/3` 由 `BuildTransactionApplier.register_scene_objects`
  在 commit 后调,写入准确的 `covered_chunks_by_region`(由 World 端
  `TransactionExecutor` 从 `transaction.participants.affected_chunks` 反向
  推算并 inflate 到 obj 上)。`evict/3` 在 `ObjectRegistry.destroy_object`
  路径调用。
- `ObjectRegistry.dispatch_object_state_delta/3`(Phase A4-4):按
  `covered_chunks_by_region` 分桶,每个 `(region_id, lease_id)` 桶通过
  `:region_routing_fn` opt 解析到 chunk_directory_target(默认 `nil` 即所有
  桶都走 `state.chunk_directory`,生产单 scene_node 退化为本地 fan-out)。
  `chunk_directory_target` 形态既可以是 local atom(如 `ChunkDirectory.RegionA`)
  也可以是 `{Mod, scene_node}` tuple(GenServer.call 天然支持跨节点);
  跨节点 lookup / cast 失败 catch :exit + emit
  `voxel_object_state_delta_dispatch_failed` observe(fire-and-forget,
  object_version 单调保 client dedup)。
- `SceneServer.Combat.VoxelDamageRouter.try_apply_damage`(Phase A4-4):拿到
  `(object_id, part_id)` 后调 `ObjectOwnerLookup.fetch_owner` →
  `:scene_node_resolver_fn` 解析 owner scene_node →
  `GenServer.call({Mod, scene_node}, {:accumulate_damage, ...}, 200)` 透明
  跨节点 GenServer 协议(**非** `:rpc.call`,语义等价但不需新增
  `accumulate_damage_remote/4` API)。失败 catch :exit + emit
  `voxel_damage_cross_region_failed`,成功 emit `voxel_damage_routed_cross_region`。
  Owner cache miss 退到本地 legacy 路径,保持 A1-5 单 region 兼容性。
- `ObjectRegistry` + `ObjectOwnerLookup` 挂入 `VoxelSup` **生产监督树**
  (Phase A4-4 顺手补 Phase 4 起一直未挂的 ObjectRegistry;之前 register
  路径在生产环境 :noproc exit,只在测试中通过 `start_supervised!` 启动)。
- 跨节点 default resolver 的真路由(`RegionRouting.resolve_scene_node` /
  `resolve_chunk_directory`)在 **A4-bis-cluster** 阶段落地(决策稿就位:
  `docs/voxel-server-authority/phase-A4-cross-region-prefab.md` 文末专段)。
  A4 主体留 `:scene_node_resolver_fn` / `:region_routing_fn` opt 注入,生产
  default 退化为本节点;真分布式部署时 caller 注入 RegionRouting fn。

后续切片会在同一子树下补充紧凑区块增量、A4-bis-cluster 真多 scene_node
部署、per-region coordinator 切片,以及更完整的迁移回滚。
