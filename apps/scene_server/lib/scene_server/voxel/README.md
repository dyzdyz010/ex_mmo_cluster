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
