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

权威边界如下：

- WorldServer 拥有区域分配，并决定哪个 Scene 实例可以写。
- SceneServer 只拥有当前已租约区域的热执行状态。
- DataService 只有在写入令牌匹配当前 World 租约时，才持久化区块真相。

后续切片会在同一子树下补充紧凑区块增量、`BuildTransaction` 应用，以及更完整的迁移预热
确认与回滚。
