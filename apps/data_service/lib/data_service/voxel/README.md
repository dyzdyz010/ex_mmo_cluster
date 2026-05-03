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
