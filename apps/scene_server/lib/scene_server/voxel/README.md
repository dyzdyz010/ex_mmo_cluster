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

`ChunkProcess.apply_intent/2` 是 World 已授权体素意图在 Scene 侧的最小写入路径。单意图
路径仍以持久化通过作为提交条件，然后向订阅者推送对应 `ChunkDelta`；无法表达为
delta 的操作才回退为完整 `ChunkSnapshot`。缺失、过期、越界或陈旧的租约都不会改变
热区块。若单意图持久化时 DataService 返回 `:stale_chunk_version`，这表示当前热
`ChunkProcess` 落后于持久层，而不是默认等同于玩家操作冲突；进程会从
DataService 重载 canonical snapshot，向订阅者推送恢复快照，然后基于重载后的
chunk version 对该 intent 重试一次。显式 `expected_chunk_version` /
`expected_cell_hash` 仍在重载后按乐观并发语义校验，真正不匹配时才作为 stale intent
返回。

`ChunkProcess.apply_intents/2` / `commit_transaction/2` 是 prefab 和跨 chunk 事务的热路径。
它们先更新本进程内的权威 storage，再向订阅者 fan-out 一条按最终 macro 合并后的
`ChunkDelta`，而不是完整 chunk snapshot。完整 snapshot 持久化被拆到后台 task：热路径只
等待 DataService 写令牌校验通过，PG row lock / 大 binary 写入属于冷路径。后台任务会 emit
`voxel_chunk_async_persist_queued`、`voxel_chunk_async_persist_finished` 或
`voxel_chunk_async_persist_down`；`ChunkProcess.flush_persistence/2` 是 CLI / 测试同步点，用于
在需要检查 PG 最终状态时等待当前 chunk 的后台持久化完成。

`ChunkProcess.subscribe/3` 是订阅接口。订阅者会立即拿到当前完整 `ChunkSnapshot`，用于
初始同步 / 重连 / 版本缺口修复；后续正常编辑和 prefab commit 默认通过 `ChunkDelta`
增量更新。

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
非 0 旋转；跨 region / 多 lease 由 Gate + World 按 Scene-owner participant
分发，Scene 侧仍只接收自己负责的 chunk intents。

Gate 上的 `0x67 PrefabPlaceIntent` 真实路径：先通过 `BlueprintCatalog` +
`PrefabRaster` 拿到 cell 列表，按 `chunk_coord` 分组成
`%{chunk_coord => [intent_attrs, ...]}` 一份 intents-by-chunk 计划；通过 World 的
`MapLedger.route_chunks_with_leases/3` 一次解出所有 touched chunks 的 assignment +
lease。Gate 要求每个 assignment 都有 `assigned_scene_node`,然后按具体
`{ChunkDirectory, scene_node}` 分组成 Scene-owner participants。单 chunk 和同 Scene
owner 多 chunk 走 Gate/Scene 本地 fast path；真正 split-owner 的计划才远程调
`WorldServer.Voxel.TransactionCoordinator.begin_transaction/3` 并同步运行
`WorldServer.Voxel.TransactionExecutor.execute/4`。participant 必须携带
`participant_key`、`assigned_scene_node` 和每个 affected chunk 的 `chunk_owners`;
缺失时 World/Gate 直接拒绝,不回退到 lease-only 或 owner-ref 推导。**任一 chunk 的 prepare 失败或
commit 时 batch apply 失败都会回滚全部 fence**：客户端要么收到
`VoxelIntentResult{Accepted, max_chunk_version}`（全部生效），要么收到
`VoxelIntentResult{Rejected, reason}` 且 chunk 状态全部回到 prepare 前。**v1 的
cell-by-cell + 部分写不回滚行为已被替换**。

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

## Hot Path Note: Scene-Local Prefab

Gate routes single-chunk prefab placements directly to
`ChunkDirectory.apply_intents/2` with `reject_occupied: true`. Scene still owns
the hot chunk state and emits `voxel_intents_applied` / `voxel_intent_rejected`,
while Gate emits `*_prefab_single_chunk_fast_path_*` observe events. This keeps
chunk-local all-or-reject semantics but avoids the World two-phase fence write
that was visible as a 1-3s right-click delay.

Gate also keeps same-owner multi-chunk prefabs Scene-local: if every participant
resolves to the same `{ChunkDirectory, scene_node}`, Gate runs
`BuildTransactionApplier.prepare/4` + `commit/3` directly through
`GateServer.Voxel.PrefabLocalTransaction` and emits
`*_prefab_same_owner_fast_path_*`. Split-owner prefabs still use
`TransactionCoordinator` + `BuildTransactionApplier`.

`ChunkProcess.apply_intents/2` also batches micro prefab writes by touched macro
cell. Boundary-snapped prefabs commonly span several macro cells inside one
chunk; those are now applied as one `Storage.put_micro_blocks/4` call per macro
instead of one normalized storage rewrite per micro slot.

## Phase 1.2: AttributeSet typed domain (2026-05-13)

`SceneServer.Voxel.AttributeSet` / `SceneServer.Voxel.AttributeEntry` 把
`Storage.attribute_sets` 从 `[term()]` 升级为 typed value bag。每个 chunk 的
`attribute_sets` 池是 chunk-local 复用表，`NormalBlockData` / `MicroLayer` 通过
`attribute_set_ref: u32`（1-indexed，`0 = null`）引用其中一条。

**`AttributeEntry`** —— 单条 `(key_id, value_type, value)`。`value_type` tagged
union：

| tag  | 类型     | wire 大小 | 范围                              |
|------|----------|-----------|-----------------------------------|
| 0x01 | i16      | 2 B       | -32768..32767                     |
| 0x02 | u16      | 2 B       | 0..65535                          |
| 0x03 | fixed32  | 4 B       | Q16.16 定点，约 -32768.0..32767.999 |
| 0x04 | enum8    | 1 B       | 0..255                            |
| 0x05 | bitset32 | 4 B       | 0..0xFFFF_FFFF                    |

`key_id` 在 Phase 1.2 是 chunk-local（Phase 5 `AttributeCatalog` 会升级为全局
命名空间 + name / unit / merge_rule 元数据，pool 字段保持兼容）。

**`AttributeSet`** —— 一条 entries 列表，`normalize!/1` 自动按 `key_id` 升序，
拒绝重复 key、未知 value_type、value 超范围、空集（empty 用 ref=0 表达）。
`byte_canonical_key/1` 返回 wire 字节序，作为 pool 内排序键。

**`Storage.intern_attribute_set(storage, set)`** —— 把 set 加入池，返回
`{storage, ref}`。返回的 ref 是**排序后**的稳定 1-indexed 索引；调用方不应
基于 `length(attribute_sets)` 自挑 ref，因为 `Storage.normalize!` 按 byte-wise
canonical 排序整池。结构等价集合（含乱序输入）re-intern 时返回原 ref，池不增长。

**Wire layout (section 0x04)** —— 一旦发出即冻结：

```
set_count: u32
sets[set_count] {
  entry_count: u16
  entries[entry_count] {
    key_id:     u32
    value_type: u8
    value:      <1|2|4 bytes by tag>
  }
}
```

空池字节序 = `<<0u32>>`，与 Phase 1 前的 `encode_empty_pool_for_*` 输出**byte 等价**，
所以 `chunk_hash` 在 `attribute_sets = []` 时保持稳定（D-8b：未 bump
`schema_version`，3 个 pinned baseline `0x0980_DF98_C2DA_1FFC` /
`0x7B46_B0F3_33B6_3489` / `0x7491_619E_9791_DFB9` byte-stable 已回归验证）。

设计与决策点：`docs/plans/2026-05-13-phase1-attribute-set-typed-domain.md`
（D-1..D-8 全部推荐方案）。Phase 1.3 `TagSet` 走同一节奏独立 commit。

## Phase 1.3: TagSet typed domain (2026-05-13)

`SceneServer.Voxel.TagSet` 把 `Storage.tag_sets` 从 `[term()]` 升级为
typed set-membership pool。每个 chunk 的 `tag_sets` 池是 chunk-local 复用表，
`NormalBlockData` / `MicroLayer` 通过 `tag_set_ref: u32`（1-indexed，
`0 = null`）引用其中一条。

与 Phase 1.2 `AttributeSet` 对称：1-indexed ref、chunk-local id、canonical
byte-wise pool 排序、`Storage.intern_tag_set/2` API、空池字节等价
（`chunk_hash` 在 `tag_sets = []` 时仍 byte-stable，未 bump
`schema_version`，3 个 pinned baseline 同样未变）。

**`TagSet`** —— 一条 `tag_ids: [u32]` 列表（**纯 set membership，不携带 value**；
要 `(key, value)` 走 `AttributeSet`）。`normalize!/1` 自动升序、拒绝重复 id、
拒绝 u32 范围外的值、拒绝空集（empty 用 ref=0 表达）。
`byte_canonical_key/1` 返回 wire 字节序，作为 pool 内排序键。

`tag_id` 在 Phase 1.3 是 chunk-local 扁平 u32（**无 namespace**，T-1 决策）；
Phase 5 `TagCatalog` 升级时再引入 namespace / merge_rule / name 元数据。

**`Storage.intern_tag_set(storage, set)`** —— 把 set 加入池，返回
`{storage, tag_set_ref}`。返回的 ref 是**排序后**的稳定 1-indexed 索引；
结构等价集合（含乱序 `tag_ids` 输入）re-intern 时返回原 ref，池不增长。

**Wire layout (section 0x05)** —— 一旦发出即冻结：

```
set_count: u32                    (T-4)
sets[set_count] {
  tag_count: u16                  (T-3)
  tag_ids[tag_count]: u32         (T-1 升序无重复)
}
```

每条 TagSet wire byte 数 = `2 + 4 × tag_count`，远小于 AttributeSet（不带 value）。

设计与决策点：`docs/plans/2026-05-13-phase1-tag-set-typed-domain.md`
（T-1..T-4 全部推荐方案）。Phase 1.4 `CatalogPatch` 走同一节奏独立 commit。

## Phase 1.4: CatalogPatch envelope (2026-05-13)

`SceneServer.Voxel.CatalogPatch` 是 attribute / tag catalog 的增量变更 wire 通道
（opcode **`0x71`**），作为 Phase 5 `AttributeCatalogSnapshot` (`0x6E`) /
`TagCatalogSnapshot` (`0x6D`) 全量快照之外的 incremental delta 载体。

Phase 1.4 只实装 **envelope encode / decode**：payload 字节保持 raw binary，
Phase 5 引入 `AttributeDefinition` / `TagDefinition` 时再解释 op payload 内容。

opcode 槽位说明：设计草案推荐 `0x6F`，与生产现有 `VoxelDebugProbe` 冲突，
用户 2026-05-13 改判 `0x71`；voxel 保留段相应扩展到 `0x60..0x7F`。

**Wire layout (opcode 0x71, 一旦发出即冻结)**：

```
CatalogPatch
  schema_kind: u8           # 0x01 attribute / 0x02 tag / 0x03..0xFF reserved
  base_version: u64         # catalog 基线版本
  new_version: u64          # catalog 新版本（必须 >= base_version）
  op_count: u16
  ops[op_count] {
    op_kind: u8             # 0x01 add / 0x02 remove / 0x03 update / 0x04..0xFF reserved
    entry_id: u32           # attribute_id / tag_id
    payload_len: u16        # forward-compat: 让 decoder skip unknown op_kind
    payload: bytes(payload_len)
  }
```

Envelope = 1 + 8 + 8 + 2 = 19 bytes；每条 op header = 1 + 4 + 2 = 7 bytes。

**Forward-compat 规则**：

- 未知 `op_kind`（0x04..0xFF）：decoder **保留** raw payload，`op_kind` 数值
  原样回填；re-encode 是 byte-identical pass-through，中间路由节点不需要
  schema 升级即可转发未来 catalog op。
- 未知 `schema_kind`：decoder 硬错误（`{:error, :unknown_schema_kind}` /
  `decode_for_wire!/1` raise）。schema_kind 是 envelope-level dispatch tag，
  未知值意味着协议演进，必须 bump opcode 或更高层处理，不能静默吞掉。
- `base_version > new_version`：normalize / encode / decode 都拒绝
  （catalog version 必须单调）。

**Ops 顺序语义**：CatalogPatch ops 是**顺序应用**（不 canonicalize），与
`AttributeSet` / `TagSet` 池的 byte-wise canonical 排序明确不同。

**Phase 1.4 边界**（与 Phase 5 区分）：
- 本 commit 只动 scene 侧 envelope；**不**集成 gate codec / 客户端 decoder。
- payload 内容 Phase 5 落地 `AttributeDefinition` / `TagDefinition` 时再解释。
- op 形态保持 `%{op_kind, entry_id, payload}` map（P-3 推荐方案）；Phase 5
  升级为 typed `CatalogPatchOp` struct。
- envelope **不**含 `transaction_id` / `actor_id` 等 provenance metadata
  （P-2 推荐最小化方案）。

设计与决策点：`docs/plans/2026-05-13-phase1-catalog-patch-minimum.md`
（P-1..P-3 全部推荐方案，opcode 实际值由 0x6F 改 0x71）。

## Phase 1.6a: server-side snapshot/delta golden fixtures (2026-05-13)

Phase 1 验收口径"snapshot/delta golden fixtures，覆盖 macro/refined/environment/
attribute/tag refs"服务端侧落地。fixtures 是 cross-language wire 真相源：
Phase 1.6b 客户端 TS decoder（独立 commit）会消费同一批 `.golden`。

**fixtures 目录**：`apps/scene_server/priv/fixtures/voxel/`

每条 fixture 由两个文件构成：

- `<name>.golden` —— 纯二进制 payload（无 opcode 前缀），与
  `Codec.encode_*_payload` / `CatalogPatch.encode_for_wire` 输出字节一致。
- `<name>.yaml` —— 元数据：`name / kind / wire_size / chunk_hash`（snapshot 类）
  / `description`。

**fixture 清单（17 条 + chunk_invalidate × 4 + object_state_delta × 3 = 22 条）**：

| 类别 | 数量 | 内容 |
|------|------|------|
| snapshot | 8 | empty / macro_only / refined / environment / attribute_pool / tag_pool / object_refs / full |
| delta | 4 | cell_solid (kind=1) / cell_empty (kind=0) / cell_refined (kind=2) / multi_op |
| chunk_invalidate | 4 | 一个 reason byte 一条（unspecified / migration_cutover / region_removed / catalog_changed） |
| object_state_delta | 3 | 一个 state_flags 一条（damaged / part_destroyed / destroyed，D5 单事件语义） |
| catalog_patch | 3 | attribute_add (0x01/0x01) / tag_remove (0x02/0x02) / forward_compat_skip (含 op_kind=0xFE) |

**生成脚本**：`apps/scene_server/priv/scripts/gen_voxel_golden_fixtures.exs`，
deterministic（在干净 tree 上重跑必须 byte-identical 输出）。

**验证脚本**：`apps/scene_server/test/scene_server/voxel/golden_fixture_test.exs`
（32 tests）：每条 fixture 做 decode → re-encode 字节等值；snapshot 类额外校
验 `Codec.chunk_hash(storage)` 与 `.yaml` 中 `chunk_hash` 字段相等；还保留一条
"3 个 pinned chunk_hash baseline byte-stable" 回归断言。

## Phase 1.6b: web_client TS decoder + roundtrip (2026-05-13)

Phase 1 最后一条验收口径——**TS decoder roundtrip + 服务端/客户端 hash 一致**——
落在 `clients/web_client/` 侧。Phase 1.6a 22 条 `.golden` 现在是 cross-language
wire 真相源，被同时消费：

- 服务端：`scene_server/test/scene_server/voxel/golden_fixture_test.exs`
- 客户端：`clients/web_client/src/infrastructure/net/voxelProtocol.test.ts`
  + `clients/web_client/src/voxel/{attributeSet,tagSet,catalogPatch}.test.ts`

**新增 TS decoder**（web_client）：

- `clients/web_client/src/voxel/attributeSet.ts` —— Section 0x04 pool。
  Q16.16 既保留 `raw`（int32，用于 byte-stable hash 重算 / 比对）也提供
  `asFloat`（`raw / 65536`，renderer 直接消费）。未知 `value_type` 硬错误。
- `clients/web_client/src/voxel/tagSet.ts` —— Section 0x05 pool，严格升序+
  无重复检查（drift detector）。
- `clients/web_client/src/voxel/catalogPatch.ts` —— opcode 0x71 envelope。
  未知 `op_kind` 0x04..0xFF preserved 为 raw payload，re-encode byte-identical
  pass-through。未知 `schema_kind` 硬错误。
- `clients/web_client/src/infrastructure/net/voxelProtocol.ts` —— snapshot
  decode 现在产出 typed `attributeSets` / `tagSets` / `objectRefs`（之前
  `ensureEmptyPool` / `ensureObjectRefsSection` 只做长度校验，Phase 1.6b 上升
  到完整字段解码）。`decodeVoxelServerMessage` 追加 `case 0x71: CatalogPatch`
  dispatch 路径，新增 `VoxelCatalogPatchMessage`。
- `clients/web_client/src/voxel/wireToRefinedCell.ts` —— 不再丢弃
  `attributeSetRef` / `tagSetRef` / `ownerObjectId`。在结果上额外产出
  `attributeSetRefsBySlot: Uint32Array` / `tagSetRefsBySlot: Uint32Array` /
  `ownerObjectIdsBySlot: BigUint64Array`（G-3 推荐）。`FRefinedCellData` 在
  `storage/types.ts` 中扩展三条 optional 字段，保留对 offline 路径与现有
  构造点的向后兼容。

**chunk_hash 一致性验证**：服务端 `.yaml` 中 `chunk_hash` 字段与客户端从
snapshot payload byte offset 40 读出的 u64 直接比较；不在客户端重算（TS 端
目前没有 canonical encoder，且服务端 decoder 已在 fixture 生成时校验过
`encoded_chunk_hash` 与 `computed_chunk_hash` 相等）。

**测试**：vitest 343/343（299 baseline + 44 new）。Phase 1.6a 3 个 pinned
chunk_hash baseline 未触（服务端代码本 commit 完全没动）。

## Phase 5.A: AttributeCatalogSnapshot (2026-05-13)

`SceneServer.Voxel.AttributeCatalogSnapshot` + `SceneServer.Voxel.AttributeDefinition`
是 attribute catalog 的**全量快照** wire 通道（opcode `0x6E`），作为客户端冷启动 /
重连 / catalog 大幅变更时的"基线"通道。增量更新仍走 Phase 1.4 `CatalogPatch`
envelope（opcode `0x71`，`schema_kind=0x01` attribute）。

Phase 1.2 chunk-local `AttributeEntry.key_id` 在 Phase 5.A 之后**语义升级**为
本模块的 `AttributeDefinition.id`（catalog 全局 id）；wire 字段不变（仍 u32）。

**`AttributeDefinition`** —— catalog 内单条定义，字段集与协议规范 §"0x6E
AttributeCatalogSnapshot payload" 完全一致：

| 字段 | wire 类型 | 校验 |
|------|-----------|------|
| `id` | u32 | 全局 attribute_id |
| `name` | u16 length-prefixed UTF-8 | 非空 |
| `unit` | u16 length-prefixed UTF-8 | 允许为空（unitless attribute，如 boolean / enum） |
| `value_type` | u8 | 0x01..0x05，与 Phase 1.2 `AttributeEntry` 完全一致 |
| `default_value` / `min_value` / `max_value` | bytes(N) | N 按 `value_type` 字节长度（2/2/4/1/4） |
| `merge_rule` | u8 | 0x01 override / 0x02 add_delta / 0x03 max / 0x04 min / 0x05 material_default |
| `dynamic` | u8 | 0 / 1（运行时可变 hint） |

`normalize!/1` 强制 `min_value <= default_value <= max_value`，并对 `name` /
`unit` 做严格 UTF-8 校验。未知 `value_type` / `merge_rule` 在 normalize / decode
两端都 raise（**不**走 forward-compat skip；catalog 演进必须 bump opcode 或
通过 CatalogPatch 协调）。

**`AttributeCatalogSnapshot`** —— `%{catalog_version: u64, definitions: [...]}`。
`normalize!/1` 自动按 `id` 升序、拒绝重复 id。`encode_for_wire/1` 顺手再 sort
一遍，保 wire 字节序唯一。

**Wire layout (opcode 0x6E, payload only, 一旦发出即冻结)**：

```text
catalog_version: u64
definition_count: u32
definitions[definition_count] {
  id:            u32
  name_len:      u16, name: bytes(name_len)        # UTF-8 非空
  unit_len:      u16, unit: bytes(unit_len)        # UTF-8 允许为空
  value_type:    u8
  default_value: bytes(N), min_value: bytes(N), max_value: bytes(N)
  merge_rule:    u8
  dynamic:       u8
}
```

字节量估算：空 catalog = `<<0u64, 0u32>>` 共 12 字节；单 `AttributeDefinition`
约 31 字节（`name="temperature"` + `unit="°C"`）。

**Phase 5.A 边界**（与 Phase 5.B-F 区分）：
- 本 commit 仅 wire typed module + Elixir codec；**不**集成 gate outbound
  dispatch、**不**实现 catalog 持久化（DataService schema）、**不**注入
  第一批 typed attribute（temperature / humidity / density / 等）—— 这些归
  Phase 5.C / 5.D。
- 客户端 TS decoder（`clients/web_client/src/voxel/`）也推到 Phase 5.C / 5.D
  真正下发 catalog 时一并落地。
- `TagCatalogSnapshot`（opcode `0x6D`）由 Phase 5.B 走同一节奏独立 commit。

设计与决策点：`docs/plans/2026-05-13-phase5a-attribute-catalog-snapshot.md`
（A-1..A-6 全部推荐方案，用户 2026-05-13 approve）。Phase 1.6a 3 个 pinned
`chunk_hash` baseline 未触（服务端 storage / codec chunk_hash 路径本 commit
完全没动），441 voxel tests + 45 new tests = 486 全绿。

## Phase 5.B: TagCatalogSnapshot (2026-05-13)

`SceneServer.Voxel.TagCatalogSnapshot` + `SceneServer.Voxel.TagDefinition`
是 tag catalog 的**全量快照** wire 通道（opcode `0x6D`），与 Phase 5.A
`AttributeCatalogSnapshot` (opcode `0x6E`) 对称但更简单：tag 只携带
`id + name`，无 `value_type / default / min / max / merge_rule / dynamic`
（Phase 1.3 T-2 决策"不携带 value"——要 value 走 `AttributeSet` /
`AttributeCatalog`）。增量更新仍走 Phase 1.4 `CatalogPatch` envelope
（opcode `0x71`，`schema_kind=0x02` tag）。

Phase 1.3 chunk-local `TagSet.tag_ids` 中的每个 u32 元素在 Phase 5.B 之后
**语义升级**为本模块的 `TagDefinition.id`（catalog 全局 id）；wire 字段不变
（仍 u32）。

**`TagDefinition`** —— catalog 内单条定义：

| 字段 | wire 类型 | 校验 |
|------|-----------|------|
| `id` | u32 | 全局 tag_id |
| `name` | u16 length-prefixed UTF-8 | 非空 |

`normalize!/1` 强制 `name` 严格 UTF-8 校验、非空、`id` 在 u32 范围。

**`TagCatalogSnapshot`** —— `%{catalog_version: u64, definitions: [...]}`。
`normalize!/1` 自动按 `id` 升序、拒绝重复 id。`encode_for_wire/1` 顺手再 sort
一遍，保 wire 字节序唯一。

**Wire layout (opcode 0x6D, payload only, 一旦发出即冻结)**：

```text
catalog_version: u64
definition_count: u32
definitions[definition_count] {
  id:       u32
  name_len: u16
  name:     bytes(name_len)        # UTF-8 非空
}
```

字节量估算：空 catalog = `<<0u64, 0u32>>` 共 12 字节；每条 `TagDefinition`
wire 字节数 = `4 + 2 + name_byte_len`，例如 `name="flammable"`(9B) → 15 B/definition。

**设计决策**（与 Phase 1.3 T-1..T-4 + Phase 5.A A-1..A-2 一致，无新决策点）：
- T-1 扁平 u32 id，无 namespace
- T-2 不携带 value
- A-1 全局 scope
- A-2 UTF-8 + u16 length prefix
- definition_count u32 / catalog_version u64 monotonic

**Phase 5.B 边界**（与 Phase 5.C-F 区分）：
- 本 commit 仅 wire typed module + Elixir codec；**不**集成 gate outbound
  dispatch、**不**实现 catalog 持久化（DataService schema）、**不**注入
  第一批 typed tag（flammable / conductive / 等）—— 这些归 Phase 5.C。
- 客户端 TS decoder（`clients/web_client/src/voxel/`）也推到 Phase 5.C
  真正下发 catalog 时一并落地。

Phase 1.6a 3 个 pinned `chunk_hash` baseline 未触（服务端 storage / codec
chunk_hash 路径本 commit 完全没动），486 voxel tests + 34 new tests = 520 全绿。

## Phase 5.C: first batch catalog seed + in-memory runtime (2026-05-13)

把 Phase 5.A / 5.B 的 catalog wire 类型从"空壳"升级为"含第一批真实定义" + 内存
runtime + Storage 高层写入 API。catalog 持久化（DataService schema）推到 Phase
5.C.2，当前每次启动从 `priv/catalogs/` 加载。

设计草案 `docs/plans/2026-05-13-phase5c-first-batch-catalog-seed.md`
C-1..C-8 全部推荐方案（用户 2026-05-13 approve）：

- **C-1** 顺序数字 id：attribute 1..5 / tag 1..8
- **C-2** fixed32 Q16.16 按表范围
- **C-3** default 绝对值（temperature default=20.0 °C 等）
- **C-4** seed 文件 .exs Elixir 字面量格式
- **C-5** GenServer + private ETS（唯一 writer，避免 race）
- **C-6** OTP supervision 启动时 `init/1` 加载
- **C-7** `Storage.put_attribute_for_cell(storage, macro_index, name, value)` 高层 API
- **C-8** 8 个第一批 tag

**Attribute catalog v1**（6 条）：

| id | name | unit | merge_rule | dynamic | default |
|----|------|------|------------|---------|---------|
| 1 | `temperature` | `°C` | add_delta | true | 20.0 |
| 2 | `humidity` | `%` | add_delta | true | 50.0 |
| 3 | `moisture` | `kg/m³` | add_delta | true | 0.0 |
| 4 | `density` | `kg/m³` | material_default | false | 1.0 |
| 5 | `thermal_conductivity` | `W/(m·K)` | material_default | false | 0.1 |
| 6 | `specific_heat_capacity` | `J/(kg·K)` | material_default | false | 1000.0 |

所有 attribute 用 fixed32 Q16.16；range 与 default 的 raw int32 编码见
`priv/catalogs/attribute_catalog_v1.exs`。
`material_default` 的 catalog default 是无材质/未知材质回退值；已接入的 material-specific
覆盖包括 dirt、stone、wood、ice、iron，分别提供 density、thermal_conductivity、
specific_heat_capacity。

**Tag catalog v1**（8 条）：`flammable` / `conductive` / `wet` / `frozen` /
`burning` / `magical` / `structural` / `transparent`（id 1..8）。

**`SceneServer.Voxel.AttributeCatalog`** / **`SceneServer.Voxel.TagCatalog`** —
GenServer + private ETS（`:protected` + `:named_table` + `read_concurrency: true`）。
public API：

```elixir
{:ok, %AttributeDefinition{}} = AttributeCatalog.lookup_by_id(1)
{:ok, 2, %AttributeDefinition{}} = AttributeCatalog.lookup_by_name("humidity")
%AttributeCatalogSnapshot{} = AttributeCatalog.current_snapshot()
1 = AttributeCatalog.catalog_version()
```

lookup_by_id / lookup_by_name 默认走模块名 singleton（`__MODULE__`）的固定
表名，旁路 GenServer 直读 ETS；alternate 注册名 / pid 注册（测试 ad-hoc）会
派生表名 / 经一次 `GenServer.call` 拿到表 atom，行为一致。

**`Storage.put_attribute_for_cell(storage, macro_index_or_coord, attr_name, value)`** —
按 attribute name 写入到 cell 的 attribute_set（NormalBlockData.attribute_set_ref）。
路径：

1. `AttributeCatalog.lookup_by_name(name)` → 拿 id + value_type + min/max
   （catalog miss raise）
2. 校验 value 在 `[min_value, max_value]`（超范围 raise）
3. cell 必须 `:solid` mode（**Phase 5.C 选项 1**：caller 必须先
   `put_solid_block`；`:empty` / `:refined` 都 raise。Phase 5.D 接 cell mode
   自动转换 + refined per-MicroLayer attribute 路径）
4. 读 `block.attribute_set_ref`：0 → 构造单 entry 新 set；非零 → 取出 pool
   既有 set，**用 key_id 替换** matching entry（override 语义），其余保留
5. `intern_attribute_set/2` 拿新 ref（结构等价复用旧 ref）
6. 更新 block.attribute_set_ref 写回

`merge_rule` 字段从 catalog 取出但本 commit **不**消费——五层 effective
value 解析在 Phase 5.D 落地。本 API 始终走"在 attribute_set 内 override 同
key_id 的 entry"语义，与 wire-level AttributeSet 唯一 key_id 约束保持一致。

**监督树挂入**：`SceneServer.VoxelSup` children 列表第一/二位（在
RegionRuntime / VoxelChunkSup / ChunkDirectory 之前），确保 ChunkProcess 或
任何下游 worker 启动前 catalog 已就绪。

**测试**：520 voxel baseline + 40 new tests = 560 全绿。Phase 1.6a 3 个 pinned
`chunk_hash` baseline 未触（put_attribute_for_cell 改动 normal_blocks /
attribute_sets 池，但 chunk_hash 在不调用该 API 时 byte-stable；golden_fixture +
codec tests 完整跑通）。

**Phase 5.C 边界**（与 Phase 5.C.2 / 5.D / 5.E 区分）：

- Catalog 跨进程重启持久化 → Phase 5.C.2（DataService schema）
- 五层 merge_rule 实施（material default / normal block override / refined
  micro override / object-part / environment summary）→ Phase 5.D
- Refined cell 的 per-MicroLayer attribute_set 路径 → Phase 5.D
- 模拟器 / 规则帧（dirty cell 扩散、`EnvironmentUpdated` delta）→ Phase 5.E / 5.F
- 客户端 catalog 消费（web_client TS decoder for opcode `0x6E` / `0x6D` +
  UI）→ Phase 5.D / 5.E 真正下发 catalog 时一并落地

## Phase 5.D: five-tier merge_rule + effective_attribute_at API (2026-05-13)

把"按 cell 解析 effective attribute value"路径接通：下游 simulator
(Phase 5.E / 5.F) 与 FieldLayer (Phase 6) 通过单一 API 拿到应用所有覆盖后的最终值。
本 commit 仅实施 4 层（L1/L2/L3/L5）；L4 object-part 推到 Phase 5.D.2 或更晚。

设计草案 `docs/plans/2026-05-13-phase5d-five-tier-merge-rule.md`
D-1..D-5 全部推荐方案（用户 2026-05-13 approve）：

- **D-1** override 优先级 **L3 > L2 > L1 > L5**（micro > macro override > material default > environment）
- **D-2** add_delta L1 base + L2/L3/L5 delta 累加
- **D-3** `temperature_delta` / `moisture_delta` 字段 + attribute_set 双路径 sum 累加（向后兼容）
- **D-4** Phase 5.D 暂不接 L4 object-part（推到 5.D.2 或更晚）
- **D-5** API macro 粒度

**四层数据源**：

| 层级 | 来源 | 粒度 |
|---|---|---|
| L1 material_default | material-specific default（缺失时回退 `AttributeDefinition.default_value`） | macro/refined cell material |
| L2 normal_block_override | `NormalBlockData.{temperature,moisture}_delta` 字段 + `NormalBlockData.attribute_set_ref` 指向的 AttributeSet | macro cell（仅 :solid mode） |
| L3 refined_micro_override | `MicroLayer.attribute_set_ref` 指向的 AttributeSet（多 layer 聚合） | refined micro layer |
| L4 object_part | 未实施 | — |
| L5 environment_summary | `MacroEnvironmentSummary.current_{temperature,moisture}`（仅 temperature / moisture 适用） | macro cell 粗粒度 |

**merge_rule 实施（4 层版本）**：

| merge_rule | 实施 |
|---|---|
| `override` (0x01) | L3 > L2 > L1 > L5（取最高 priority 层有值的，否则次高，最后 default） |
| `add_delta` (0x02) | L1 + (L2.delta ?? 0) + (L3.delta_sum ?? 0) + (L5.delta ?? 0) |
| `max` (0x03) | max([L1, L2, L3, L5] 中所有有值的层) |
| `min` (0x04) | min([L1, L2, L3, L5] 中所有有值的层) |
| `material_default` (0x05) | 仅 L1 material-specific default（忽略其他层） |

**L3 refined cell 多 layer 处理（草案 §7）**：

- `add_delta`：sum 所有 layer 中该 attribute 的 delta（与 L1+L3 path 物理直观一致）
- `max` / `min`：取所有 layer 中该 attribute 的极值
- `override`：取 canonical 序的 first layer with attribute（**不**累加）
- `material_default`：忽略 L3

**L2 D-3 (a1) 路径**：当 `NormalBlockData.temperature_delta` / `moisture_delta`
字段非 0 **且** `attribute_set` 中同 attribute 的 entry 也有 delta 时，**两者
sum 累加**。其他 attribute 仅走 `attribute_set` 路径（没有 typed 字段）。

**L5 字段语义**：当前 `MacroEnvironmentSummary.current_temperature` /
`current_moisture` 是 i16 raw delta（向 catalog default 上累加）。L5 仅
temperature / moisture 适用；其它 attribute L5 永远 `:not_found`。本 commit
不改 `MacroEnvironmentSummary` 模块，仅读字段。

**边界**：

- effective_value 超出 `[min_value, max_value]` → **clip 到边界**（草案 §7
  风险段当前推荐策略）
- 未知 `attr_name` / `attr_id` → raise `ArgumentError`
- 不合法 `macro_index_or_coord` → raise

**API**：

```elixir
Storage.effective_attribute_at(storage, macro_index_or_coord, attr_name_or_id, opts \\ [])
# opts:
#   :catalog — AttributeCatalog server name / pid（默认模块名 singleton）
```

返回 raw int value（按 value_type 解释；i16 / u16 / fixed32 / enum8 / bitset32 都返回 raw int）。

**测试**：560 voxel baseline + 24 new effective_attribute_test.exs = 584 全绿。
Phase 1.6a 3 个 pinned `chunk_hash` baseline 未触（本 commit 只动 storage.ex
增加 effective_attribute_at + 私有 merge helpers，不动 chunk_hash / wire codec /
任何 wire 模块；golden_fixture_test.exs 32 tests 全部通过）。

**Phase 5.D 边界**（与 Phase 5.D.2 / 5.E / 5.F 区分）：

- L4 object-part attribute（`PartState` 扩展 / 独立 ObjectPartAttribute table）→ Phase 5.D.2 或更晚
- Micro slot 粒度 effective API → Phase 5.D.2 或 Phase 6 真正需要时
- 模拟器写入 `MacroEnvironmentSummary.current_temperature` → Phase 5.E / 5.F
- temperature diffusion / `EnvironmentUpdated` delta 下发 → Phase 5.F
- 客户端消费 effective value（web_client） → Phase 5.F 真正下发时一并落地

## Phase 5.E: scene simulation tick infrastructure

为 Phase 5.F 温湿度 simulator 与 Phase 6 FieldLayer tick 提供 **per-chunk
低频规则帧调度地基**。本阶段框架就绪，**不注任何具体 simulator**。

实施依据 `docs/plans/2026-05-13-phase5e-simulation-tick-infrastructure.md`
E-1..E-6 全部推荐方案（用户 2026-05-13 approve）：

- **E-1 per-chunk tick scheduler**：`SimulationTick` state 嵌入 `ChunkProcess`
  state；每个 chunk 独立一个 100ms 计时器。
- **E-2 tick interval**：固定 100ms（10 Hz）。
- **E-3 dirty tracking**：macro cell 粒度 `DirtyMacroBounds` + 4 个 reason
  flag bit。
  - `0x01 attribute_write`：cell payload / attribute_set 改动（Storage 内部
    自动 mark；put_solid_block / put_micro_block(s) / clear_micro_block /
    clear_macro_cell / put_attribute_for_cell 全部路径覆盖）。
  - `0x02 chunk_sub_change`：订阅集合变更（**首次订阅不打标**，订阅者拿 full
    snapshot；订阅状态后续变更才打标。Phase 5.E 暂未在 ChunkProcess 路径
    自动写入此 bit，simulator 侧也未消费；预留给 Phase 5.F / Phase 6 上层
    主动 mark）。
  - `0x04 cross_chunk_boundary`：邻 chunk 边界事件渗透（E-4 pull 模式：simulator
    通过 `env.neighbor_lookup` 主动读邻区，1 tick 滞后可接受；上层用
    `Storage.mark_macro_dirty/3` 显式写入此 bit）。
  - `0x08 catalog_changed`：AttributeCatalog / TagCatalog runtime 版本变化。
- **E-4 cross-chunk boundary 拉模式**：simulator 在 `env.neighbor_lookup`
  里主动查邻 chunk；本 commit 默认未配置（`nil`），框架就绪。
- **E-5 deterministic output_hash**：`SimulationTick.output_hash/4` 输入
  `(input_chunk_hash, dirty_bounds_truth, tick_seq, simulator_ids)`，
  xxHash64。同输入 → 同输出，回归验证用。
- **E-6 配置文件硬编码 simulator 注册**：`config :scene_server,
  :voxel_simulators, [...]`。Phase 5.E 默认 `[]`。

### 调度路径

```
ChunkProcess.init
  → SimulationTick.new(simulators)
  → schedule_simulation_tick (100ms)

ChunkProcess.handle_info(:simulation_tick, state)
  1. lease_stale?  → emit voxel_simulation_tick_skipped reason: :lease_stale
  2. no simulators → emit voxel_simulation_tick_skipped reason: :no_simulators
  3. dirty empty   → emit voxel_simulation_tick_skipped reason: :no_dirty
  4. emit voxel_simulation_tick_started
  5. SimulationTick.run_tick → 依次 simulator.tick/3
     - 单 simulator 失败 → emit voxel_simulation_simulator_failed
       （**失败不阻塞其它 simulator**；保留旧 sim state）
  6. Storage.clear_dirty_bounds（**Phase 5.E 简化策略：失败也无条件清 dirty**，
     重试机会 = 下个 tick 自然累积新 dirty。Phase 5.F 可按 simulator 失败
     reason 决定是否保留）
  7. SimulationTick.output_hash(...) 计算 + 缓存 last_output_hash
  8. emit voxel_simulation_tick_completed
  9. schedule_simulation_tick (next 100ms)
```

### Simulator behaviour

`SceneServer.Voxel.Simulator`：

- `simulator_id() :: atom()` —— 稳定 id，影响 `output_hash`。
- `tick(state, dirty_bounds, env) :: {:ok, new_state, %{cells_updated, env_delta}} | {:error, atom()}`

`env` map：`chunk_coord` / `logical_scene_id` / `lease_token` / `storage`
（**只读快照**） / `neighbor_lookup`（pull 模式邻区查询函数或 `nil`）。

`env_delta` 字段 Phase 5.E **暂未定义具体 schema**；Phase 5.F 温湿度
simulator 用它带回 `environment_summaries` 写回意图。本 commit
ChunkProcess 仅累计 `cells_updated`，**不应用 env_delta**（直到 Phase 5.F
确定 schema）。

### Observe events

- `voxel_simulation_tick_started`
- `voxel_simulation_tick_completed`
- `voxel_simulation_tick_skipped`（reason: `:lease_stale` / `:no_simulators` / `:no_dirty`）
- `voxel_simulation_simulator_failed`
- （Phase 5.F 可追加 `voxel_simulation_boundary_read` 等）

### 边界

- 本 commit **不**接任何具体 simulator（Phase 5.F 工作）。
- chunk_hash 不受 `dirty_bounds` 影响（已有约束，`codec.ex` § encode_chunk_truth_payload）。
- 3 个 pinned `chunk_hash` baseline 保持 byte-stable。
- subscriber 首次订阅不打 `0x02 chunk_sub_change` dirty bit。

### 测试

`apps/scene_server/test/scene_server/voxel/simulation_tick_test.exs` 19 tests
覆盖：

1. SimulationTick state helpers（new / any_simulator? / simulator_ids）
2. DirtyMacroBounds helpers（empty? / add_macro / clear / reason_set?）
3. Storage mutation 自动 mark dirty
4. output_hash 决定性（同输入同输出 / 不同 dirty / 不同 tick_seq / 不同 simulator_ids 产生不同 hash）
5. ChunkProcess 调度器（默认空 simulators / no_dirty skip / dirty+simulator 触发 tick + dirty 清空 + tick_seq 递增 / lease_stale skip / 单 simulator 失败隔离 / 跨 chunk output_hash 决定性）

584 voxel baseline + 19 new = **603 tests 0 failures**；3 pinned chunk_hash baseline byte-stable。

---

## Phase 5.F：温度 / 湿度 diffusion simulator + `EnvironmentUpdated` delta (opcode 0x72)

Phase 5 的最后一站，"能读 + 能算 + 能下发"闭环。落地后 Phase 1-5 全 done，
Phase 6 FieldLayer 可开工。

### DiffusionSimulator

`SceneServer.Voxel.DiffusionSimulator` 实现 `Simulator` behaviour，参数化
`attribute_name` (`"temperature"` / `"moisture"`)、`alpha`、`dt`，单一模块支持
温度 / 湿度（草案 F-2 推荐方案）。

算法：标准 3D 7-stencil 显式扩散（草案 F-1 macro 粒度推荐方案）：

```text
T'(x,y,z) = T(x,y,z) + α × dt × (
  T(x-1,y,z) + T(x+1,y,z) +
  T(x,y-1,z) + T(x,y+1,z) +
  T(x,y,z-1) + T(x,y,z+1) -
  6 × T(x,y,z)
)
```

实施细节：

- **粒度**：macro 粒度（16³ = 4096 cells/chunk）。
- **值域**：复用 `MacroEnvironmentSummary.current_temperature /
  current_moisture` i16 raw delta（相对 catalog default）；simulator 直接在
  i16 域做扩散；Phase 5.D `effective_attribute_at` 在外侧把 L1 base + L5
  delta sum 起来。
- **α / dt**：从 simulator config 取（默认 temperature α=0.05，moisture
  α=0.02，dt=0.1）。Phase 5.F **不**接 catalog `thermal_conductivity` 动态
  查询（草案 §2.1：v1 α 从配置；v2 可改 per-cell α from effective attribute）。
- **边界**：拉模式邻 chunk + Neumann fallback（草案 F-3 推荐）。`env.neighbor_lookup`
  为 `nil` 或邻 chunk 不可读时退化为绝热（邻居视为同温 → 贡献 0）。
- **稳定性**：Courant 条件 α × dt × 6 < 1。temperature: 0.05 × 0.1 × 6 = 0.03；
  moisture: 0.02 × 0.1 × 6 = 0.012。均远小于 1，数值稳定。

`tick/3`（behaviour 入口）从 `state` / `env[:diffusion_config]` 中解析 simulator
config，默认回退到温度 default 实例。多实例同模块场景下，调用方（ChunkProcess）
应通过 `SimulationTick` 初始化 state 注入 config（Phase 5.F.runtime 接通）。

`tick/4`（显式 config 版本）是纯函数，方便单测。

### EnvironmentUpdated wire payload (opcode 0x72)

`Codec.encode_environment_updated_payload/1` /
`Codec.decode_environment_updated_payload!/1` 实现 0x72 wire payload，完整定义
见 `docs/2026-04-10-线协议规范.md` §0x72 段。Wire 一旦发出即冻结。

### ChunkProcess 集成

`execute_simulation_tick` 在 `SimulationTick.run_tick` 返回后，对每个非空
`env_delta` 调用 `maybe_fan_out_environment_updated_payload/5`：

- 当 `ops != []` 且本 chunk 有 subscribers 时编码 0x72 payload + `send/2` 给每个
  subscriber，并 emit `voxel_environment_updated_push`。
- 空 ops / 无 subscribers 时 emit `voxel_environment_updated_skipped`。
- Phase 5.F 本 commit **不修改** `storage.environment_summaries` 的 canonical
  truth —— 仅推 wire delta。`base_chunk_version = new_chunk_version =
  storage.chunk_version`。`storage.environment_summaries` 的实际写回 + 自动
  chunk_version bump 推到 Phase 5.F.runtime（避免影响 chunk_hash baseline +
  现有 chunk_version 语义）。

### 注册策略

`config :scene_server, :voxel_simulators` 保持 Phase 5.E 同款 `[]`（草案 §"step 6
注意"硬纪律：本 commit 优先保证 603 baseline 不回归）。Phase 5.F.runtime 在确认
ChunkProcess + 多实例 config 注入路径稳定后，再正式注册 temperature + moisture
两个 DiffusionSimulator 实例。

### Forward-compat 纪律

- `field_mask` 只接受 `0x01` / `0x02` / `0x03`；其它 bit 位 decoder / encoder
  都硬错误（与 `0x71 CatalogPatch` envelope 同款"未知 schema_kind 硬错误"）。
- `field_mask = 0` 视为非法。
- `source_hash` 是 simulator 输入 hash 的低 32 位（macro_index + cur + 6
  neighbors + α + dt + attribute_name），同输入 → 同 hash，可幂等回放。

### 测试

- `apps/scene_server/test/scene_server/voxel/diffusion_simulator_test.exs`
  覆盖 simulator_id 派生 / 单热源 + 6 邻居热量守恒 / 稳态 / 绝热边界 /
  deterministic / source_hash 区分 / moisture 实例。
- `apps/scene_server/test/scene_server/voxel/environment_updated_codec_test.exs`
  覆盖空 / 单 temperature / 单 moisture / 双字段 / 多 updates roundtrip / 字节级
  golden / forward-compat field_mask 拒绝。

603 voxel baseline + 17 new = **620 tests 0 failures**；3 pinned chunk_hash
baseline byte-stable。Phase 1-5 全 done。

---

## Phase 6：FieldLayer + 电场 / 温度场 tick + FieldDebugOverlay (2026-05-13, commit c0d8681)

Phase 6 实现"局部场域最小可行"：AABB 区域内稀疏场值、10 Hz 独立 tick、0x73/0x74 wire
下发、web_client 调试叠加层。落地后 Phase 1-6 全收口。2026-05-14 起温度层改为
环境基线 + float 异常 delta：只有偏离环境温度的 macro cell 进入 layer/overlay。

设计草案 `docs/plans/2026-05-13-phase6-field-layer-minimum.md`，G-1..G-8 全部推荐方案。

### FieldLayer + FieldRegion 数据结构

**`SceneServer.Voxel.Field.FieldLayer`** —— 稀疏 delta map，逻辑宽度固定 4096 cells：

```elixir
defstruct values: %{}, baseline: 0.0, threshold: 0.0001, quantization: :float
```

API：`new/0`、`new/1`、`get(layer, macro_index) :: number`、
`get_delta(layer, macro_index) :: number`、`put(layer, macro_index, value) :: layer`、
`put_delta(layer, macro_index, delta) :: layer`、
`active_cells(layer, aabb, epsilon) :: [{macro_index, value}]`（只返回偏离 baseline 的格）。

temperature layer 由 `FieldRegion` 创建为 `baseline: 20, quantization: :float, threshold: 0.1`。
未保存的格子读作 20°C；写入 20°C 或损耗后绝对 delta < 0.1 的格子会从 layer 删除。电场 /
电离仍用默认 baseline 0.0 + float delta，保持既有小数势能语义。

**`SceneServer.Voxel.Field.FieldRegion`** —— 持有一组 FieldLayer 的 AABB 区域：

```elixir
defstruct [
  :region_id, :chunk_coord, :aabb, :field_types, :source_points,
  tick_count: 0, max_ticks: nil, lease_token: nil, kernels: [], layers: %{}
]
```

API：`new/1`（从 opts 构造，`kernels` 必填且非空，`field_types` 从 kernel 派生）、`increment_tick/1`、
`tick_limit_reached?/1`、`in_aabb?/2`（macro_index 是否落在 AABB 内）、
`put_layer/3` / `get_layer/2`、`aabb_cell_count/1`（AABB 内格子总数，上限 4096）。

### ElectricField 算法

**`SceneServer.Voxel.Field.ElectricField`** —— BFS/Dijkstra 从 source_points 向 AABB 传播电势：

- 数据结构：`:gb_sets` 做 max-heap（用 `{-potential, idx}` 取反，`:gb_sets.smallest` 即最大势）
- 路径代价：`1.0 / max(density_raw / 65536.0, 0.001) × @decay_factor(0.1)`
  （高密度格阻碍传播；density 通过 `Storage.effective_attribute_at` 读取，fallback default 65536）
- Ionization（电离度）：`|potential| ≥ 50.0` 时每 tick +5，否则每 tick -1，固定范围 0..255
- 出 AABB 的邻居忽略（不传播到区域外）

`tick(region, storage) :: {:ok, region}` 是每 tick 入口：重算 potential + ionization FieldLayer，
写回 region。

### TemperatureField 算法

**`SceneServer.Voxel.Field.TemperatureField`** —— 稀疏 3D 7-stencil 显式扩散 + source_points：

- 扩散系数：`α = min((thermal_conductivity / (density × specific_heat_capacity)) × dt / cell_size², 0.5)`；
  默认 `dt = 0.1s`、`cell_size = 1m`。`thermal_conductivity` / `density` /
  `specific_heat_capacity` 从 `Storage.effective_attribute_at/3` 读取。
- 已接入的 material-specific 默认物性：dirt、stone、wood、ice、iron；未知材质才回退到
  attribute catalog 的无材质默认值。`FieldRuntime` 默认使用真实时间尺度
  (`diffusion_time_scale = 1.0`) 和 `1m` macro voxel，不再用交互倍率压缩热扩散时间。
- kernel 仍保留 `diffusion_time_scale` / `ambient_loss_per_second` 选项，供后续明确的非物理玩法
  profile 使用；生产 Heat 入口不启用这些调试期加速/耗散参数。
- 状态：只保存相对 `env_temp = 20°C` 的 float delta；未保存 cell 即环境温度
- 计算范围：当前异常 cell、热源 cell 及其 6-邻居 halo；无热源区域不会被背景温度写满
- 损耗：默认物理路径不使用调试期固定 `β` 回冷；交互 profile 可显式启用环境耗散。
  热量还会通过邻接扩散与有限 AABB 边界向环境流出。
  温度层 threshold 为 0.0001°C，低于 threshold 的 cell 自动退出 layer
- 出 AABB 的邻居视为 delta 0（即环境温度）
- `source_mode: :impulse` 只注入一次，适合技能热量输入；默认 persistent source 在扩散后重新写入，保持持续热源强度

`tick(region, storage) :: {:ok, region}` 是每 tick 入口。

### FieldRuntime 异常入口

**`SceneServer.Voxel.Field.FieldRuntime`** —— 把异常 voxel 属性转成局部场的服务端入口：

- `build_temperature_anomaly/1` 是纯函数：接收 world-macro voxel、`Storage`、radius、max_ticks，
  从 voxel 的 effective `temperature` 属性读取异常量，再计算 chunk/local macro、
  source macro_index、初始 AABB 和物性驱动的 kernel-first region attrs；
- `ensure_temperature_anomaly/1` 调用 `ChunkDirectory.ensure_chunk/1`，先通过
  `ChunkProcess.write_temperature_attribute/2` 把 heat action 的目标温度（默认 800°C）
  写入选中 solid voxel 的 `temperature` attribute，并在 summary 中按
  `density × specific_heat_capacity × volume` 回算所需热量，再由
  `build_temperature_anomaly/1` 检测异常并调用
  `ChunkProcess.ensure_field_region/2` 创建或复用 `TemperatureDiffusionKernel` region；
- `ChunkProcess.ensure_field_region/2` 使用 caller 提供的 `source_key` 做 active source
  去重；同一 chunk 内同一 `{temperature, macro_index}` 活跃 region 会接收新的 impulse source，
  不会重复堆叠 FieldRegion；
- 目标温度与环境基线 `20°C` 的差值低于 `1°C` 时不创建 region，保持常态属性零成本；
- web_client 的 `F` 键、HUD `Heat` 按钮和 CLI `voxel_heat <x> <y> <z> [target_temperature_celsius] [max_ticks]` 通过
  `/ingame/voxel/dev_heat_voxel` 提交“加热 voxel”的意图，客户端仍只消费自动下发的
  0x73/0x74；Heat 成功后 web_client 自动打开 Field overlay，并提供
  `field_overlay [on|off]` CLI 诊断。

当前切片已经把“Heat -> 写入 voxel 温度属性 -> 服务端发现温度异常 -> 创建局部 FieldRegion -> kernel tick ->
客户端 overlay 可显示”串通。尚未完成的部分是从持久 voxel truth 扫描/订阅异常属性、异常低于阈值后的
自动销毁、以及 kernel effect 写回 voxel/object truth。

### FieldCodec

**`SceneServer.Voxel.Field.FieldCodec`** —— 0x73 / 0x74 wire codec：

**0x73 FieldRegionSnapshot wire layout（opcode 字节包含在内）**：
```
opcode:          u8   = 0x73
logical_scene_id: u64  big-endian
cx/cy/cz:        i32 × 3  big-endian
region_id:       u64  big-endian
tick_count:      u32  big-endian
field_mask:      u8   (0x01=temperature / 0x02=electric_potential / 0x04=ionization)
cell_count:      u16  big-endian
macro_indices[]: u16  big-endian × cell_count
temperature[]:   f32  little-endian × cell_count  (若 field_mask & 0x01)
electric[]:      f32  little-endian × cell_count  (若 field_mask & 0x02)
ionization[]:    u8 × cell_count                  (若 field_mask & 0x04)
```

`cell_count` 是所有 field active cell 的并集。temperature 的 active cell 指
`abs(integer_delta_from_20C) >= 1` 的格子；wire 上仍发送绝对温度值（f32 little-endian），
用于保持 web_client 既有 decoder/overlay 兼容。

**0x74 FieldRegionDestroyed wire layout（opcode 字节包含在内）**：
```
opcode:          u8   = 0x74
logical_scene_id: u64  big-endian
cx/cy/cz:        i32 × 3  big-endian
region_id:       u64  big-endian
destroy_reason:  u8   (0x00=expired / 0x01=lease_revoked / 0x02=explicit / 0x03=chunk_crash)
```

总 30 字节固定大小。

API：`encode_snapshot_payload(region, logical_scene_id)`、
`decode_snapshot_payload!(binary)`、
`encode_destroyed_payload(region_id, chunk_coord, logical_scene_id, destroy_reason)`。

### FieldTickWorker + FieldTickSupervisor

**`SceneServer.Voxel.Field.FieldTickWorker`** —— per-region GenServer，每区域独立 10 Hz 调度：

- `init/1`：监控 ChunkProcess（`Process.monitor(chunk_pid)`）；调度第一个 tick
- `handle_info(:tick)`：
  1. `GenServer.call(chunk_pid, :debug_state, 200)` 取 storage 快照，并在 `KernelContext`
     中规范化一次
  2. 按 `region.kernels` 逐个运行 FieldKernel，更新 region；kernel 热路径使用已规范化
     storage / context API，禁止在每个 cell 的属性读取里重复整块 `Storage.normalize!/1`
  3. `FieldCodec.encode_snapshot_payload` 编码
  4. `ChunkProcess.push_field_snapshot_payload` cast 给 ChunkProcess
  5. emit observe events：`voxel_field_tick_completed` / `voxel_field_snapshot_dispatched`
  6. `Process.send_after(self(), :tick, @tick_interval_ms)` 调度下一 tick
- `handle_info({:DOWN, ...})`：chunk 进程死亡 → `{:stop, :normal, state}`，
  emit `voxel_field_region_destroyed`

**`SceneServer.Voxel.Field.FieldTickSupervisor`** —— `DynamicSupervisor`：

- 注册名 `name: __MODULE__`，挂在 `SceneServer.VoxelSup` children 列表（在 ChunkDirectory 前）
- `start_worker(opts)` 以 `restart: :temporary` 启动 FieldTickWorker
  （崩溃区域不自动重建，由上层 ChunkProcess 决策是否重建）

### ChunkProcess 集成

`ChunkProcess` state 新增 `field_regions: %{}` + `field_region_monitors: %{}`：

- **`create_field_region(chunk_pid, region_opts)`**：cast，启动 FieldTickWorker 并监控
- **`destroy_field_region(chunk_pid, region_id)`**：cast，`GenServer.stop` worker +
  fan-out 0x74 payload
- **`push_field_snapshot_payload(chunk_pid, payload)`**：cast，把编码后 payload fan-out 给所有
  subscribers（`send(pid, {:voxel_field_region_snapshot_payload, payload})`）
- **`push_field_region_destroyed_payload(chunk_pid, payload)`**：cast，同 fan-out 模式
- **Lease 变更检测**：`lease_changed?/2` 检测到变更时调 `stop_all_field_workers(state, :lease_revoked)`，
  对每个活跃区域 fan-out 0x74 payload 给订阅者

### Gate forward 路径

`apps/gate_server/lib/gate_server/worker/tcp_connection.ex` 新增两条 `handle_info`：

```elixir
def handle_info({:voxel_field_region_snapshot_payload, payload}, %{socket: socket} = state)
def handle_info({:voxel_field_region_destroyed_payload, payload}, %{socket: socket} = state)
```

两者均直接调 `send_frame(socket, payload)` 转发（payload 已含 opcode 字节）。

### web_client FieldDebugOverlay

**`clients/web_client/src/voxel/field/fieldProtocol.ts`** —— 0x73/0x74 decoder：

- `decodeFieldRegionSnapshot(buf: ArrayBuffer): FFieldRegionSnapshot | null`
- `decodeFieldRegionDestroyed(buf: ArrayBuffer): FFieldRegionDestroyed | null`
- f32 用 `DataView.getFloat32(offset, true)`（little-endian）；u64 = hi × 0x1_0000_0000 + lo
- `FieldMask`：`{Temperature: 0x01, ElectricPotential: 0x02, Ionization: 0x04}`
- `DestroyReason`：`{Expired: 0x00, LeaseRevoked: 0x01, Explicit: 0x02, ChunkCrash: 0x03}`

**`clients/web_client/src/voxel/field/fieldDebugOverlay.ts`** —— Three.js 调试叠加层：

- `FieldDebugOverlay` 类，`rootGroup: Group` 挂到 scene 根
- `Map<number, FieldRegionOverlay>` 管理活跃区域（每区域含温度 / 电势 InstancedMesh + AABB LineSegments）
- 温度色彩：`COLD_COLOR(0.05, 0.1, 1.0)` → `HOT_COLOR(1, 0.1, 0.05)`，t = (temp−20)/80 clamp [0,1]
- 电势色彩：`LOW_ELEC_COLOR(0,0,0)` → `HIGH_ELEC_COLOR(1,1,0)`，t = |potential|/100 clamp [0,1]
- F8 热键切换可见性（`§5.5 硬约束：隐藏默认，dev hotkey only`）
- `macroIndexToCoord`：x = idx & 0xf，y = (idx >> 4) & 0xf，z = (idx >> 8) & 0xf

**`clients/web_client/src/voxel/field/fieldProtocol.test.ts`** —— 9 条 vitest 测试：
4 个 snapshot（temperature-only / 三字段 / 截断 null / 零格）+ 5 个 destroyed（4 个 reason × it.each + 截断 null）。

**opcodes.ts 追加**：`EnvironmentUpdated: 0x72`、`FieldRegionSnapshot: 0x73`、`FieldRegionDestroyed: 0x74`

**voxelProtocol.ts 追加**：case `0x73` / `0x74` dispatch + `VoxelFieldRegionSnapshotMessage` /
`VoxelFieldRegionDestroyedMessage` 接口 + `VoxelServerMessage` union 扩展。

### 测试

- 服务端：6 个新测试文件（`field_layer_test / field_region_test / electric_field_test /
  temperature_field_test / field_codec_test / field_integration_test`），共 36 新测试 →
  **656 总 0 failures**；3 个 pinned chunk_hash baseline 字节稳定。
- web_client：9 个新 vitest → **352 总 0 failures**。

**Phase 1-6 全 done**。
