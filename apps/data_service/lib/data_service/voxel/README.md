# DataService 体素边界

本目录拥有体素持久化侧的守卫逻辑。

`DataService.Voxel.WriteTokenStore` 是服务端权威体素协议中“写入围栏”的第一版实现。
写入围栏指 DataService 本地保存的当前可写租约令牌，WorldServer 会为每个区域发布一份。
DataService 用这份令牌校验区块写入，因此迁移之后，旧 Scene 进程即使还活着也不能继续写。

当前存储是进程内内存实现。API 刻意对齐后续 PostgreSQL 版比较并交换语义：更大的
`token_version` 会替换旧令牌，完全相同的重复发布保持幂等，过期令牌会被拒绝。

`DataService.Voxel.ChunkSnapshotStore` 拥有第一版内存区块快照表。它按逻辑场景和区块坐标
保存快照元数据与二进制载荷，但只有 `WriteTokenStore.validate_write/2` 接受写入者之后才会
保存。Scene 进程提供写入意图，令牌存储拥有写入许可判断，快照存储拥有持久化状态，并通过
`snapshot/1` 暴露给 CLI 和调试面检查。

区块写入按 `{logical_scene_id, chunk_coord}` 做版本围栏。更大的 `chunk_version` 会替换旧快照；
更小版本会以 `:stale_chunk_version` 拒绝；相同版本只有在已保存的 `chunk_hash` 和 `data`
完全一致时才返回 `:unchanged`。

**Phase 3-bis：`DataService.Voxel.ChunkPendingTransactionStore`** 走
`voxel_chunk_pending_transactions` 新表（复合主键
`(logical_scene_id, coord_x, coord_y, coord_z)`），承载 Scene 端
`ChunkProcess.pending_fence` 的持久化形态：`prepare_transaction` 同步 INSERT、
`commit/abort_transaction` 同步 DELETE、`init/1` 启动 LOAD（按 lease 一致性
校验，孤儿 fence 自动 DELETE + observe）。`fence_payload` 是归一化 intent
batch 的 `:erlang.term_to_binary/1` blob，反序列化用 `[:safe]` 模式。

**Phase 3 / S1：`DataService.Voxel.SceneNodeRegistryStore`** 走
`voxel_scene_node_registry_snapshots` 单行 snapshot 表，是
`WorldServer.Voxel.SceneNodeRegistry` 的**权威**持久化后端（进程身份注册化，
cluster-discovery-4）。它和 `MapLedgerStore` 共用同一套单行 term-blob facility
（固定 `id`、`payload` 为 `:erlang.term_to_binary/1`、upsert 写、`[:safe]` 读、
单行替换语义）。

**阶段4 / world-2pc-4：`DataService.Voxel.TransactionCoordinatorStore`** 升级为
**行级增量持久化**,走 `voxel_transaction_coordinator_rows` 新表(主键
`transaction_id`,`:erlang.term_to_binary/1` 编码),取代旧的单行全量
`voxel_transaction_coordinator_snapshots`(由 `20260605000001` 迁移 drop,无迁移债):

- `persist_rows/3` 只 upsert **变更过的事务行** + 删除被裁剪的行(一个
  `insert_all` + 一个 `delete_all`),写代价随单回合变更量而非历史总量;终态
  事务被协调者裁出活跃集后,行收敛成只带决策归档的轻量历史行(`transaction` /
  `begin_fingerprint` 为 nil)。
- `load_state/1` 扫全表把每行重建回协调者四张 map
  (`transactions` / `begin_fingerprints` / `decisions` / `decision_index`),
  形状与旧单行 snapshot 完全一致,协调者 `init` 无需感知存储切换。
- `persist_rows_fn/1`(2-arity)/ `load_fn/1` 绑定 `repo` 注入协调者启动选项;
  坏行用 `[:safe]` 解码失败时跳过 + `Logger.warning`,不让单行损坏拖垮整体
  hydrate(对齐 SceneNodeRegistryStore 的"坏行不静默当权威、也不 crash"纪律)。

- 接受 key：`join_order`（`node()` 列表）、`region_assignments`
  （`%{region_id => node()}`）、`round_robin_cursor`（非负整数）。其它形状一律
  以 `{:error, _}` 拒绝（空表 → `{:ok, %{}}` 是正常的全新部署路径，
  损坏行 → `{:error, reason}`，绝不静默当成空）。
- region 归属是 World 侧的真相源（落库这一行，不是注册表进程的内存）；
  `SceneNodeRegistry` 内存态是从这一行 hydrate 出来的派生缓存，scene_node /
  注册表崩溃重启不会丢 region 归属。
- `persist_fn/1` / `load_fn/1` 绑定 `repo` 给 `SceneNodeRegistry` 的启动选项注入，
  `WorldSup` 走 `DataService.Repo`。

**Phase 4：`DataService.Voxel.SceneObjectStore`** 走 `voxel_scene_objects`
新表 + `voxel_scene_object_id_seq` 全局 sequence：

- `next_object_id/1` 从 sequence 取下一个 `object_id`（World coordinator 在
  `begin_transaction` 路径同步申请，失败回 `:sequence_unavailable`）。
- `put_object/2` 是幂等 upsert（按 `object_id` 主键替换全字段）。
- `get_object/2` / `delete_object/2` / `list_in_scene/2` / `reset/1`(test)。
- `covered_chunks` 与 `part_states` 都是 `:erlang.term_to_binary/1` blob，
  对齐 fence_payload 风格不上 wire 不跨语言。`anchor_world_micro_x/y/z` 是
  i64 世界坐标，可负，**不加** `>= 0` CHECK；其它 bigint 字段都加非负约束。
- 用作 `SceneServer.Voxel.ObjectRegistry` 的 LOAD 后端，World coordinator
  `BuildTransaction.scene_objects` 字段也通过它分配 ID。
