# DataService 体素边界

本目录拥有体素持久化侧的守卫逻辑。

`DataService.Voxel.WriteTokenStore` 是服务端权威体素协议中“写入围栏”的第一版实现。
写入围栏指 DataService 本地保存的当前可写租约令牌，WorldServer 会为每个区域发布一份。
DataService 用这份令牌校验区块写入，因此迁移之后，旧 Scene 进程即使还活着也不能继续写。

当前存储是 PostgreSQL durable 实现。API 保持比较并交换语义：更大的 `token_version`
会替换旧令牌，完全相同的重复发布保持幂等，过期令牌会被拒绝。

`DataService.Voxel.ChunkSnapshotStore` 拥有 canonical 区块快照表。它按逻辑场景和区块坐标
保存快照元数据与二进制载荷，但只有 `WriteTokenStore.validate_write/2` 接受写入者之后才会
保存。Scene 进程提供写入意图，令牌存储拥有写入许可判断，快照存储拥有持久化状态，并通过
`snapshot/1` 暴露给 CLI 和调试面检查。

区块写入按 `{logical_scene_id, chunk_coord}` 做版本围栏。更大的 `chunk_version` 会替换旧快照；
更小版本会以 `:stale_chunk_version` 拒绝；相同版本只有在已保存的 `chunk_hash` 和 `data`
完全一致时才返回 `:unchanged`。

`ChunkSnapshotStore.coverage/4` 是 world-pack 验证使用的只读聚合入口。它按显式
inclusive chunk bounds 统计某 logical scene 的 total / in-bounds / out-of-bounds chunk
数量和已持久化边界，不会调用 WorldGen、不会写入缺失 snapshot，也不作为 runtime 兜底。

`ChunkSnapshotStore` 的 canonical 事务只维护完整 XYZ chunk truth，不解析也不写入
`lod_projection_cells`。`LodHeightmapStore` / `VoxelLodHeightmapCell` 是已归档 XZ
heightmap 的离线迁移产物；它们缺失、损坏或写入失败都不得拒绝或回滚 canonical 写入。

**Phase 3-bis：`DataService.Voxel.ChunkPendingTransactionStore`** 走
`voxel_chunk_pending_transactions` 新表（复合主键
`(logical_scene_id, coord_x, coord_y, coord_z)`），承载 Scene 端
`ChunkProcess.pending_fence` 的持久化形态：`prepare_transaction` 同步 INSERT、
`commit/abort_transaction` 同步 DELETE、`init/1` 启动 LOAD（按 lease 一致性
校验，孤儿 fence 自动 DELETE + observe）。`fence_payload` 是归一化 intent
batch 的 `:erlang.term_to_binary/1` blob，反序列化用 `[:safe]` 模式。

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
