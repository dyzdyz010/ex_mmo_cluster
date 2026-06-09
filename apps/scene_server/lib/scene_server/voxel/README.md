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

## 进程身份注册化与重启 hydrate（阶段3.1 / S1）

**谁是 `{logical_scene_id, chunk_coord}` 的权威**这一进程身份，唯一真相源是
`SceneServer.Voxel.ChunkRegistry`（`Registry` `:unique`，挂在 `VoxelSup` 下，
早于 `VoxelChunkSup` / `ChunkDirectory` 启动）。状态所有权边界：

- **ChunkProcess 拥有** voxel 真相（`storage`）、lease、订阅者、异步持久化、
  field worker、事务 fence。via-tuple（`ChunkRegistry.via/3`）写进 child_spec
  的 `start` 参数，监督树重启天然去重——同 key 第二次 `start_child` 得到
  `{:error, {:already_started, pid}}`，绝不会出现两个权威进程。
- **ChunkDirectory 是无状态 facade**：不再持有进程表，所有 lookup/路由都经
  注册表解析（删掉了旧的 `state.chunks` 并行真相源）。facade 崩溃重启不会产
  生第二个权威：权威进程独立挂在 `VoxelChunkSup` 下，由注册表裁决单主。
- **ChunkSnapshotStore 是崩溃恢复的权威存储**。

**init hydrate 不变式**：进程（崩溃恢复 / 监督树重建）启动时——

1. 携有效 lease → 无条件 `ChunkSnapshotStore.get_snapshot/2`：
   - `:loaded` 从持久化恢复；`:never_persisted`（`:snapshot_not_found`）是合法
     全新 chunk，空 storage 是正确初值；
   - hydrate 失败（DB 不可达 / payload 损坏）→ 进 `:degraded` 态，**不**用空
     storage 静默服务（避免崩溃恢复静默丢数据）。已删除旧的 `Storage.empty`
     默认兜底。
2. 无 lease → `:unauthorized` 态，不读权威存储、不持 lease、不 schedule 模拟
   tick，等 World 下发 lease（`apply_lease/2`）后才 hydrate 并转 `:authorized`。

`mode`（`:authorized` / `:unauthorized` / `:degraded`）与 `hydrate_status` 经
`debug_state/1` 暴露供 CLI/测试断言。`restart: :transient` + `VoxelChunkSup`
显式 `max_restarts/max_seconds`：单 coord 反复崩溃（如 hydrate 永久失败）耗尽
预算后整棵 chunk 子树重启，`ChunkProcess.terminate/2` 已上报
`voxel_chunk_terminated` observe（并给订阅者推 ChunkInvalidate 触发 re-subscribe），
facade 的 `voxel_chunk_directory_chunk_down` 供 World 裁决该 coord 不可用。

## 空闲驱逐 + 按需 tick（阶段2.4 / voxel-storage-4）

在阶段3 的 `:transient` + `terminate` + 注册化身份之上，解决“chunk 进程永不
回收 + 永久 10Hz 空转 timer → 进程数与常驻 Storage 随玩家探索无界增长”。

- **按需 tick**：模拟 tick 不再无条件每 100ms 重排。`ChunkProcess` 仅在
  `(已授权 + 有 simulator + dirty_bounds 非空 + lease 未失效)` 时 arm 一个 tick
  （`maybe_arm_simulation_tick/1`，`tick_armed?` 去重）；写入路径
  （`apply_intent` / `commit` / `put_solid_block` / field effect 等）产生 dirty
  时显式补 arm。tick 跑完清 dirty 后回到**零 timer 空闲态**。`tick_skipped`
  observe 降级为采样聚合（`@tick_skip_sample_n`），不再空转刷日志。
- **唯一常驻低频 timer**：lease 心跳 + prepared fence TTL + 空闲驱逐静默检查
  共用一个 `lifecycle_check_interval_ms`（默认 1s）节拍，**不是** 10Hz。
- **驱逐显式状态机**：`ChunkProcess` 维护 `last_activity_ms`（订阅 / 授权写 /
  lease 应用 / 事务 / field region 都刷新它）。`idle_evict_candidate?/1` 判定空
  闲（无订阅 + 无 field region + 无 pending fence / commit / async persist + 非
  在跑模拟 + lease 失效或未持有 + 静默窗口已过）时，向 `ChunkDirectory` facade
  `cast {:request_evict, key, self()}`。
- **退场所有权归 facade（规避驱逐-ensure TOCTOU）**：`ChunkProcess` **不自停**。
  `ChunkDirectory.handle_cast({:request_evict, ...})` 在 facade 单点串行 mailbox
  里（与 `ensure_chunk` / `subscribe` 同 lane）复核：经注册表确认请求方仍是该
  key 的权威，再同步 `ChunkProcess.confirm_evict/1` 让 chunk 在自身 mailbox 里
  重评空闲并**先 persist 再** `VoxelChunkSup.terminate_chunk/2`
  （`DynamicSupervisor.terminate_child`，`:transient` 计划内终止不重启，注册项
  随 `:DOWN` 由 Registry 摘除）。复核窗口内 chunk 又变活跃（刚来的订阅 / 写 /
  lease）→ `confirm_evict` 回 `{:cancel, _}`，facade 取消驱逐、进程复用。
- **驱逐前 persist 的权威性**：`confirm_evict` 持有效 token 时真正落库
  （`{:ok, :persisted}`）；token 已过期 / 区域 token 不在视为 `authority_lapsed`
  放行驱逐（权威写路径是 durable-on-reply，最后一次有效写早已 durable）；DB 瞬时
  故障 → `{:cancel, {:persist_failed, _}}` 不丢状态、下一节拍重试。被驱逐的 chunk
  下次 `ensure_chunk` 冷启并经阶段3 路径从持久化 hydrate。

## 体素数据结构 + normalize 收口（阶段2.5 / voxel-storage-6）

解决“每改一格全量 `normalize!`（4096 header ×10+ 趟）+ `refresh_chunk_object_refs`
全扫（O(headers × `Enum.at`)）+ 两次全量 snapshot encode；canonical 用 List 做 4096
元素随机写（O(n)）”这一热路径根因。

**内存表示与线序/hash 序解耦（最高风险约束）** —— `Storage.macro_headers` /
`refined_cells` 这两个**公共字段始终是 canonical 有序 list**（macro_index 升序 /
payload_index 升序），它们是 codec wire layout 与 `chunk_hash` 字节序的**唯一真相
投影**。`Codec.encode_*` / `encode_chunk_truth_payload` / `chunk_hash` 永远只遍历
这两个 list（顺序不变、字节不变），因此换底层加速结构对 wire/hash **零字节漂移**
（32 个 golden fixture + web_client parity + 3 条 pinned chunk_hash baseline 全部
逐字节保持）。`storage_accel_test.exs` 用“强制无 accel 路径 vs accel 路径逐字节
对照”守门。

- **`accel` 私有派生加速索引**（不进 wire / 不进 hash）：`headers_array` 是定长
  4096 的 Erlang `:array`（macro_index 随机读 O(1)），`refined_by_payload` 是
  `payload_index => RefinedCellData` 的 map（refined cell 随机读 O(1)）。二者
  **永远从 canonical list 派生**，`normalize!` / `trust_transform!` / `ensure_accel`
  出口构建/刷新；同内容 storage 的 accel 确定相等，故 storage 结构 `==` 语义不变。
  `Storage.fetch_macro_header/2` / `fetch_refined_cell/2` 是 O(1) accessor，热路径
  （`ChunkProcess` 的 `macro_header_at_fast` / `refined_cell_at_fast` / 碰撞查询）
  全部改走它们，消除原 `Enum.at` O(n) 与碰撞查询每次 `List.to_tuple` 的 O(n) 重建。
- **边界 normalize 与内部 trusted transform 分离**：`normalize!`（全量校验 +
  canonical 排序，O(4096 + pools)）**只在边界**发生一次——decode / 外部注入 /
  `new` / 公共写 API 入口。内部受信局部变更走 `trust_transform!/2`：mutator 以
  已归一化子结构局部改写 list 并报告触碰的 macro_index，本函数只合并 dirty +
  增量重建 accel，**不重扫 4096 header**。
- **object_refs 增量化绑定 `DirtyMacroBounds`**：`refresh_chunk_object_refs_incremental/1`
  只重算 dirty AABB 内 refined macro 的 `cell.object_refs`，再重聚合 chunk-level
  `ChunkObjectRef[]`（内层 payload→cell 查找用 accel map 的 O(1) 替代旧 O(n)
  `Enum.at`）。`ChunkProcess` 的 `apply_intent` 单意图 / batch apply 路径改用增量
  refresh（单格改动 = 1 个 dirty macro，不再触发 4096 趟）；它与全量
  `refresh_chunk_object_refs/1` 在 dirty 集覆盖全部变更时**结构等价**（Storage 写
  API 已保证每次改动 mark dirty）。事务 commit 的 durable barrier 路径
  （`commit_prepared_intents/3`）保守保留**全量** refresh 作为正确性锚点。
  增量 refresh **不消费/清空** `dirty_bounds`——它与阶段2.4 的按需 tick 共享同一份
  dirty（tick 在 `execute_simulation_tick` 后才 `clear_dirty_bounds`）。
- **热路径砍掉一次全量 encode**：单意图原本对同一 storage 全量 encode 两次（reply
  payload `request_id=intent.request_id`；persist payload `request_id=0`），body
  （sections + chunk_hash，占载荷绝大部分）完全相同。`encode_snapshot_payloads_dual/2`
  只 encode 一次，再纯字节拼接 8 字节 `request_id` 头得到两份**逐字节等价**载荷
  （ChunkSnapshot wire 首字段即 `request_id::u64`，splice 零漂移）。全量 encode /
  full `chunk_hash` 现仅在**真正需要**时发生（snapshot 首帧 / persist / 周期）。

**chunk_hash 仍是“全量 over canonical 序”而非真滚动增量** —— xxHash64 over 完整
canonical 载荷不可在不改变 hash 值的前提下做可组合的滚动增量；为严守“`chunk_hash`
字节序绝不漂移”，本阶段不改 hash 算法，只把**何时计算**收敛到按需（hot path 产 delta
+ bump version，不每格算 hash）。这是经评估后对“滚动增量”一项的安全落地口径。

## 目录串行咽喉 → Registry 直达 + chunk DB 异步（阶段5.2 / voxel-storage-1）

解决“落方块写 / 碰撞查询 / 事务等热路径都经 `ChunkDirectory` 这个**单一 GenServer
串行 mailbox** 路由（head-of-line block），即便阶段3 已把目录无状态化，热路径仍
`GenServer.call` 经它两跳同步”这一 S2/S3 根因。三个机制：

- **热路径 Registry 直达**：`ChunkDirectory.apply_intent_direct/2` /
  `apply_intents_direct/2` / `prepare_transaction_direct/3` / `commit_transaction_direct/3`
  / `abort_transaction_direct/3` 先经 `ChunkRegistry.lookup` 拿到已注册的**活** chunk
  pid（`Process.alive?` 过滤死 pid，保持阶段3 语义），**直达 `ChunkProcess`**——不经
  facade GenServer.call 串行。未注册 / 死 pid 时回退 facade 的 `ensure_*`（串行 lane
  冷启 + apply lease），冷启动仍严格串行、不破坏阶段3 单主与 2.4 驱逐复核。目录只保留
  `ensure / 驱逐 / 订阅 / 迁移持久化` 这类需串行的**生命周期**操作走 mailbox。
  `BuildTransactionApplier` 的 prepare/commit/abort 已改走直达。
- **collision_query 读写分离（ETS 只读 occupancy 快照）**：`SceneServer.Voxel.ChunkOccupancyTable`
  是 per-chunk 的 `:public` ETS 表（`read_concurrency: true`）。`ChunkProcess` 是**唯一
  写者**：`init` 建表并发布首帧，每次授权写收尾（`post_write_lifecycle/1`，覆盖
  apply_intent/intents、commit、put_solid_block、field effect、temperature/heat 等所有
  写路径）**原子替换**（一次 `:ets.insert`，O(1)）当前 storage 的 occupancy 投影
  （带 `chunk_version`）。`ChunkDirectory.collision_query/3` 经
  `ChunkOccupancyTable.read_snapshot/2` **直读这张表**、在**读者自己进程**里跑纯函数
  `query/2` 解析命中——**完全不触达任何进程 mailbox**：读不阻塞写、写不阻塞读（读写
  数据结构层分离）。chunk 未 hot（无发布快照）时回退经 facade `ensure_chunk` 的直达
  慢路，首帧后即纯 ETS 直读。`terminate` 删表；`:public` 无 heir 表在 owner 退出时也
  由 ETS 自动回收，故被驱逐 / 崩溃的 chunk 不残留陈旧快照（读到 `:not_published` →
  回退 ensure，重启后新权威重建表并重新发布）。命中解析逻辑与 `ChunkProcess` 内的
  `collision_query_hits` **逐位等价**（同 solid/refined 判定、同 occupancy bit 读法），
  故 ETS 直读与权威 storage 直查结果一致。
- **chunk DB 异步化 + 背压（有界 write-behind pool）**：`SceneServer.Voxel.ChunkPersistPool`
  是全 scene 共享的有界 poolboy worker pool（挂在 `VoxelSup` 下、`ChunkDirectory` 之前
  启动）。`ChunkProcess` 的 async persist Task 在真正写 DB **之前**经
  `ChunkPersistPool.transaction/1` checkout 一个 worker——**并发 persist 写数被池大小 +
  overflow 钳死**，对 Postgres 连接池形成可控背压（高速写在 Task 层排队等 worker，而非
  无界派生 Task 冲击 DB）。池满时 checkout 阻塞**Task 自身**（不是 chunk mailbox——chunk
  早已把 persist 派进 unlinked Task，继续处理后续消息）；checkout 超时返回
  `{:error, :persist_pool_timeout}`，由 persist Task 当作一次 persist 失败（commit
  durable-ack 据此 reply error + 保留 fence，与 DB 写失败同构，不丢正确性）。池未启动
  （测试 / 极早窗口）时 `transaction/1` 就地执行（降级，无背压但功能不依赖池）。

**兼容性红线（与阶段3/4/2.4 的关系）**：直达仍经 `ChunkRegistry`（同节点单主唯一权威），
不产生第二权威；阶段4 的 2PC durable barrier 由 `ChunkProcess` 内部承载（commit durable
join + pending_commit_acks），事务直达只是少一跳路由、语义不变；阶段2.4 驱逐把“注册项
摘除 + terminate”收口在 facade 串行 lane，直达前的 `Process.alive?` + 注册表 lookup 保证
**绝不**直达正在被驱逐 / 已死的 chunk（命中死 pid 即回退 ensure，由串行 lane 冷启新权威）。
DB 背压复用阶段4.5 的统一 enqueue + async persist join 点（pending_commit_acks /
`:async_snapshot_persist_finished` / Task :DOWN reply error），只是在 join 点之前插入 pool
checkout，不改 durable 闭环。

`ChunkProcess.apply_intent/2` 是 World 已授权体素意图在 Scene 侧的最小写入路径。单意图
路径仍以持久化通过作为提交条件，然后向订阅者推送对应 `ChunkDelta`；无法表达为
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
增量更新。订阅默认保持 legacy raw tuple；调用方可用 `delivery_format: :envelope`
逐订阅 opt-in，让 chunk `ChunkSnapshot` / `ChunkDelta` / `ChunkInvalidate` 包进
`{:voxel_delivery_envelope, envelope}`。Envelope 从当前 chunk lease 读取
`lease_id` / `owner_epoch` 等权威元数据，并使用订阅自己的 `tier`；订阅者状态不镜像 lease
真相。Field / object fan-out 仍保持 raw tuple，等待独立 envelope 迁移。

`SceneServer.Voxel.ChunkDirectory` 是把 `{logical_scene_id, chunk_coord}` 路由到
权威区块进程的**无状态 facade**：它经 `ChunkRegistry.lookup/3` 解析 pid，未注册
时在 `SceneServer.VoxelChunkSup` 下按需启动缺失区块（via-tuple 注册保证去重，并发
启动撞 `{:error, {:already_started, pid}}` 时复用既有 pid）。它**不缓存 pid**，仅
monitor 自己启动过的 chunk 用于发 `voxel_chunk_directory_chunk_down` 事件；路由正确
性完全依赖注册表。Gate 只有在 World 已经路由区块并提供当前租约之后，才会用它执行
只读的 `ChunkSubscribe -> ChunkSnapshot` 路径。面向 World / Gate 的代码也可以用
`ChunkDirectory.apply_intent/2` 把已带租约的写入意图路由到拥有者区块，但调用者本身
不拥有区块真相。

阶段5.2 起，热路径不再经 facade 串行 mailbox：写 / 事务用 `*_direct` 版（Registry
直达活 pid），碰撞读 `collision_query/3` 走 `ChunkOccupancyTable` 的 ETS 只读快照
（见上一节）。facade GenServer 只承载 `ensure / 驱逐 / 订阅 / 迁移持久化` 这类生命周期
串行操作。`apply_intent/2` / `apply_intents/2` / `prepare/commit/abort_transaction`
的 facade 版仍在，作为直达的冷启动回退与既有调用方的兼容入口。

`ChunkDirectory.prewarm_handoff/2` 消费 World 生成的迁移交接载荷。它按预热切片读取
DataService 中已有的区块快照，加载到目标 Scene 的热区块进程；没有快照的区块会以空区块
启动并应用新租约。预热切片指迁移前分批加载的半开区块范围。

`MigrationPrewarm.prewarm_slices/2` 是 Scene 侧迁移预热适配器。它逐切片调用
`ChunkDirectory.prewarm_handoff/2`，并返回可提交给 World `mark_slice_prewarmed/3` 的 ACK
数据；它不改变 World 迁移状态，也不保存迁移计划。
`MigrationPrewarm.final_catchup_slices/2` 是切换前最终追平适配器。它先要求源
`ChunkDirectory` 对切片内已经热启动的旧 owner 区块执行 `persist`，再让目标
`ChunkDirectory` 重新执行预热读取最新 DataService 快照，并返回可提交给 World
`mark_slice_final_caught_up/3` 的 ACK。若源端任意热区块因为旧租约、写入令牌缺失或持久化错误而
无法落盘，最终追平返回错误，不会生成 World 可接受的 ACK。Scene 仍不决定 cutover，只报告自己已
准备到哪一版。

`ChunkProcess` 内还保留一个**事务围栏 (`pending_fence`)**：
`prepare_transaction/4` 接收一份**意图清单 (intents 列表)**，全部归一化 + 通过 batch
scope/precondition 校验后整体存为 fence，并在期间拒绝其它 ad-hoc `apply_intent/2`；
`commit_transaction/2` 把 fence 内所有 intent build 成 candidate storage 并持久化
（见下方 **commit durable join**），durable-ack 后才 swap hot=candidate + 清 fence；
`abort_transaction/2` 直接清 fence、不写入。同 `transaction_id` 的二次 prepare 是幂等
的，其他事务来抢同一区块会立即拿到 `:chunk_already_fenced`。这一对 API 只面向上层
`BuildTransactionApplier`，不暴露给 Gate/玩家路径。

**阶段4 (4.5) commit durable join（统一 2PC 契约 #3）** —— `commit_transaction/2`
不再同步 apply + 立即清 fence + 立即 reply，而是收口到一个 durable barrier：

1. `commit_prepared_intents/3` 把 fence intents build 成 candidate storage（带新
   version），enqueue async snapshot persist 拿到 `persist_ref`。**此刻 hot
   `state.storage` 不推进**（candidate 只活在 pending_commit_ack 里），fence 不删、
   pending_fence 不清，caller 的 `GenServer.call` 暂不 reply（`{:noreply}`）。
2. 单 / 批 intent 的持久化统一走同一条 `enqueue_snapshot_persist` + 同一个 join 点
   `:async_snapshot_persist_finished`（消除 sync/async 分叉）；async persist 是
   **unlinked Task + monitor**，不与 chunk 共命运。
3. persist 成功回 join 点后，再做契约 #3④ 屏障校验：独立读回 DB，确认
   `db chunk_version >= 本次 commit version`，确认通过才 **swap hot=candidate +
   删 fence + reply `{:ok, durable-ack}`**（durable-ack 携带 `durable?: true` 与
   `durable_chunk_version`，供 World 做全-participant barrier）。
4. persist 失败 / 屏障未达 / Task `:DOWN` → **hot 保持 commit 前版本 + 保留 fence +
   reply `{:error, :persist_failed}`**（绝不挂起 caller）。决定不可逆：coordinator
   只能重投递 commit；重投递时 `commit_prepared_intents/3` 以未变的 pre-commit
   storage 为基重新 build 出同一 candidate，天然幂等，DB 版本围栏保证不回退。
   无变更（`changed_count == 0`）的 commit 没有 persist 等待点，本身即 durable，
   同步删 fence + reply。

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

**阶段4 (2.2) prepared fence TTL 兜底（统一 2PC 契约 #4）** —— prepared fence 带一个
`deadline_ms`（来自 `prepare_transaction/4` 的 `:fence_deadline_ms` opt，基于
coordinator deadline；缺省时用 `fenced_at_ms + 默认 TTL` 兜底）。ChunkProcess 周期
（`@fence_ttl_check_interval_ms`）检查 in-memory fence 是否过期，过期且没有 in-flight
commit（pending_commit_acks 里无该事务）时**主动作废孤儿 fence**：DELETE DB 行 +
清 pending_fence + emit `voxel_chunk_pending_transaction_ttl_expired`。这是
coordinator/driver 整体死亡的兜底；**主路径仍是 World reaper 显式 abort**。DB fence
行不持久化 deadline（持久化层 schema 不扩列），Scene 重启后从 `fenced_at_ms` 保守
重建 deadline。已进入 commit durable 等待的 fence 不会被 TTL 作废（决定已记录，
正在重投递持久化，契约 #2 决定不可逆）。

`SceneServer.Voxel.BuildTransactionApplier` 是把上面三个原语聚合成 World 视角下
participant 级 prepare/commit/abort 的薄适配器：

- `prepare/4` 接收 `intents_by_chunk :: %{chunk_coord => [intent_attrs, ...]}`，按
  participant 的 `affected_chunks` 顺序对每个 chunk 调
  `ChunkDirectory.prepare_transaction/3`，遇到第一处失败就把已经 prepared 的 chunk
  全部 `abort_transaction/3` 滚回，使一个 participant 要么完全 prepared、要么完全没占。
  `opts[:fence_deadline_ms]`（coordinator deadline）透传给每个 chunk 的 fence 作为
  TTL（阶段4 2.2）。
- `commit/3` 对每个 chunk 调 `commit_transaction/3`，逐块应用预存的整批 intents，
  并把每块的 durable 确认（`summary.durable?`）聚合成返回值的 `durable?`（全 chunk
  durable 才 true），供 World coordinator 做**全-participant durable barrier**
  （阶段4 4.5；统一 2PC 契约 #3）。
- `abort/3` 幂等释放每个 chunk 的 fence；可以在 prepare 部分失败后安全调用。

权威边界如下：

- WorldServer 拥有区域分配，并决定哪个 Scene 实例可以写。
- SceneServer 只拥有当前已租约区域的热执行状态。
- DataService 只有在写入令牌匹配当前 World 租约时，才持久化区块真相。

`SceneServer.Voxel.BlueprintCatalog` 是服务端权威预制蓝图目录。Phase A1 起它使用
v2 micro-mask：`blueprint_id` 映射到单 macro 内的 refined micro occupancy + 单一材质
id，并强制 `blueprint_version` 必须为 2。当前 v2 catalog 内容：

| id | name                | 形状                            | material_id |
|----|---------------------|---------------------------------|-------------|
| 1  | builtin_sphere      | 8³ micro 球体                   | 4           |
| 2  | builtin_cylinder    | z 轴圆柱                        | 2           |
| 3  | builtin_stairs      | y ≤ x 阶梯                      | 3           |
| 4  | builtin_conductor_wire_x | 2×2 导线贯穿 x 轴          | 5           |
| 5  | builtin_conductor_junction_xz | x/z 平面接线节点      | 5           |
| 6  | builtin_power_terminal_x | 2×2 电源端子贯穿 x 轴     | 6           |
| 7  | builtin_load_terminal_x  | 2×2 负载端子贯穿 x 轴     | 7           |

`SceneServer.Voxel.PrefabRaster.rasterize/4` / `/5` 是把蓝图 + 锚点光栅化为
`(chunk_coord, local_macro, micro_slot, layer_attrs)` 写入单元的纯函数。
**Phase A1 hotfix(2026-05-09)起按 world-micro 精度落地**：每个 occupied
slot 把 `(slot_x, slot_y, slot_z)` 加到 `anchor_world_micro` 后，再
`floor_div / floor_mod` 拆出该 cell 的 `(chunk_coord, local_macro, micro_slot)`。
这样 macro-aligned 锚点是退化情形（单 macro / 单 chunk），mid-macro 锚点会
让 prefab 自然跨 2~8 个 macros / 1~4 个 chunks，与客户端 boundary-snap
线框预览像素级一致。所有 cell 共用同一份 `layer_attrs`；几何测试和
terrain-like caller 仍可只带 `%{material_id, health: 100}`，真实 prefab
placement 必须通过 `/5` 填入同一个 `owner_object_id / owner_part_id`，让
chunk snapshot、ObjectCoverRef 和前端 overlay 都能从 layer truth 反查
prefab/object 归属。
`group_by_chunk/1` 方便按 chunk 聚合做 per-chunk 事务参与方分发。当前 v2 支持
`0..3` yaw quarter-turn 旋转，服务端 rasterize 与网页端 `EVoxelRotation` 使用同一套
local 8x8 micro footprint 坐标变换；跨 region / 多 lease 由 Gate + World 按 Scene-owner participant
分发，Scene 侧仍只接收自己负责的 chunk intents。

Gate 上的 `0x67 PrefabPlaceIntent` 真实路径：先从
`voxel_scene_object_id_seq` 预分配 `object_id`，再通过 `BlueprintCatalog` +
`PrefabRaster.rasterize/5` 拿到带 owner provenance 的 cell 列表，按 `chunk_coord` 分组成
`%{chunk_coord => [intent_attrs, ...]}` 一份 intents-by-chunk 计划；通过 World 的
`MapLedger.route_chunks_with_leases/3` 一次解出所有 touched chunks 的 assignment +
lease。Gate 要求每个 assignment 都有 `assigned_scene_node`,然后按具体
`{ChunkDirectory, scene_node}` 分组成 Scene-owner participants。单 chunk 和同 Scene
owner 多 chunk 走 Gate/Scene 本地 fast path，并在 commit 后调用
`BuildTransactionApplier.register_scene_objects/2` 注册同一个 scene_object；真正 split-owner 的计划才远程调
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
- `ChunkDirectory.lookup_chunk_pid/3`：read-only，不 lazy-start，经
  `ChunkRegistry.lookup/3` 返回已注册的权威 ChunkProcess pid（pid 死亡由
  `Registry` 自身 monitor 自动摘除，因此返回的恒为 alive pid 或 `:not_started`）。
  给 ObjectRegistry dispatch 路径用。
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

- **C-1** 顺序数字 id：attribute 1..24 / tag 1..8
- **C-2** fixed32 Q16.16 按表范围
- **C-3** default 绝对值（temperature default=20.0 °C 等）
- **C-4** seed 文件 .exs Elixir 字面量格式
- **C-5** GenServer + private ETS（唯一 writer，避免 race）
- **C-6** OTP supervision 启动时 `init/1` 加载
- **C-7** `Storage.put_attribute_for_cell(storage, macro_index, name, value)` 高层 API
- **C-8** 8 个第一批 tag

**Attribute catalog v5**（24 条）：

| id | name | unit | merge_rule | dynamic | default |
|----|------|------|------------|---------|---------|
| 1 | `temperature` | `°C` | add_delta | true | 20.0 |
| 2 | `humidity` | `%` | add_delta | true | 50.0 |
| 3 | `moisture` | `kg/m³` | add_delta | true | 0.0 |
| 4 | `density` | `kg/m³` | material_default | false | 1.0 |
| 5 | `thermal_conductivity` | `W/(m·K)` | material_default | false | 0.1 |
| 6 | `specific_heat_capacity` | `J/(kg·K)` | material_default | false | 1000.0 |
| 7 | `ignition_temperature` | `°C` | material_default | false | 5000.0 |
| 8 | `melting_point` | `°C` | material_default | false | 5000.0 |
| 9 | `freezing_point` | `°C` | material_default | false | absolute-zero sentinel |
| 10 | `boiling_point` | `°C` | material_default | false | 5000.0 |
| 11 | `electric_conductivity` | `MS/m` | override | true | 0.0 |
| 12 | `dielectric_strength` | `MV/m` | material_default | false | 3.0 |
| 13 | `fuel_mass` | `kg/m³` | override | true | 0.0 |
| 14 | `oxygen` | `%` | override | true | 100.0 |
| 15 | `combustion_stage` | `stage` | override | true | 0 idle |
| 16 | `combustion_progress` | `%` | override | true | 0.0 |
| 17 | `smoke_density` | `%` | override | true | 0.0 |
| 18 | `carbonization` | `%` | override | true | 0.0 |
| 19 | `structural_integrity` | `%` | override | true | 100.0 |
| 20 | `phase_state` | `phase` | override | true | 0 stable |
| 21 | `corrosion_resistance` | `%` | material_default | false | 100.0 |
| 22 | `chemical_concentration` | `%` | override | true | 0.0 |
| 23 | `corrosion` | `%` | override | true | 0.0 |
| 24 | `surface_state` | `surface` | override | true | 0 clean |

所有 attribute 用 fixed32 Q16.16；range 与 default 的 raw int32 编码见
`priv/catalogs/attribute_catalog_v1.exs`。
`material_default` 的 catalog default 是无材质/未知材质回退值；已接入的 material-specific
覆盖包括 dirt、stone、wood、ice、iron、power_block，分别提供 density、thermal_conductivity、
specific_heat_capacity、温度阈值（ignition/melting/freezing/boiling）和电属性
（electric_conductivity / dielectric_strength）。`latent_heat` 暂未进入 catalog；
等相变能量结算有明确 source/effect 读写链路后再追加。
v3 追加的燃烧属性是运行态 truth：燃料、氧气、阶段、烟、炭化和结构完整度都由
phenomenon effect 写回单个 voxel，不作为材料默认值。新增材料 id 8/9 分别是 ash 与
charcoal；wood 燃尽先进入 charcoal，charcoal 可继续燃烧成 ash，ash 默认不可燃。
v4 追加 `phase_state`：0 stable、1 frozen、2 boiling、3 vapor。当前 Phase 8.C
先把含水相变作为运行态 truth，冻结/沸腾由 phenomenon effect 写回；材料本体熔化、
凝固和潜热结算继续保留到后续相变规则。
v5 追加腐蚀首片属性：`corrosion_resistance` 是材料默认属性，
`chemical_concentration`、`corrosion` 和 `surface_state` 是运行态 truth；
`electric_conductivity` 仍保留材料默认基线，但允许 corrosion effect 写入动态覆盖值，
让金属受蚀后能影响后续电场/电路判断。

**Tag catalog v1**（8 条）：`flammable` / `conductive` / `wet` / `frozen` /
`burning` / `magical` / `structural` / `transparent`（id 1..8）。

**`SceneServer.Voxel.AttributeCatalog`** / **`SceneServer.Voxel.TagCatalog`** —
GenServer + private ETS（`:protected` + `:named_table` + `read_concurrency: true`）。
public API：

```elixir
{:ok, %AttributeDefinition{}} = AttributeCatalog.lookup_by_id(1)
{:ok, 2, %AttributeDefinition{}} = AttributeCatalog.lookup_by_name("humidity")
%AttributeCatalogSnapshot{} = AttributeCatalog.current_snapshot()
5 = AttributeCatalog.catalog_version()
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

### TemperatureField 算法

**`SceneServer.Voxel.Field.TemperatureField`** —— 稀疏 7-stencil 温度扩散：

- Source lifecycle、impulse source 消耗、persistent source 重写、FieldLayer 写回仍由 Elixir
  持有，避免 native 拥有 authority 或运行时状态。
- 热扩散候选格的数值计算默认走 Field 层统一 native backend
  `SceneServer.Voxel.Field.NativeBackend.diffuse_temperature/9`；输入 DTO 由
  `NativeBackend.TemperatureDiffusionInput` 冻结为当前 sparse deltas、candidate indices、
  AABB 和热属性表，再进入薄 Rustler binding
  `SceneServer.Native.FieldKernel.diffuse_temperature/8`。
- `temperature_backend: :elixir` 保留为等价参考和回滚开关。

### ElectricField 算法

**`SceneServer.Voxel.Field.ElectricField`** —— BFS/Dijkstra 从 source_points 向 AABB 传播电势：

- Runtime ownership：source 过滤、AABB layer 清空、FieldLayer 写回仍在 Elixir；纯传播计算默认
  走 `SceneServer.Voxel.Field.NativeBackend.propagate_electric_potential/5`。
- 可达性：只沿 `ParticipantProjection` 证明的导电材料/微格接触传播；空格、低导电材料、
  refined cell 内不连通的 face contact 都不会被当成电势传播路径。
- 路径代价：使用 `electric_conductivity`、`dielectric_strength` 与当前 `ionization`
  计算 step cost；不再使用旧的 density fallback。
- Native DTO 只编码当前 region AABB 内的导电投影条目，避免局部 field tick 因整块
  projection fan-out 放大 Rustler 调用成本。
- Ionization（电离度）：`|potential| ≥ 50.0` 时每 tick +5，否则每 tick -1，固定范围 0..255
- 出 AABB 的邻居忽略（不传播到区域外）
- `electric_backend: :elixir` 保留为等价参考和回滚开关。该电势传播与
  `ConductionPathKernel` 共享 material/face-contact 可达性事实，但一个输出全场 potential，
  一个输出 source 到 target 的单条导电通道。

`tick(region, storage) :: {:ok, region}` 是每 tick 入口：重算 potential + ionization FieldLayer，
写回 region。

### ConductionPathKernel 算法

**`SceneServer.Voxel.Field.Kernels.ConductionPathKernel`** —— Phase 7.B 的材料属性驱动电通道 kernel：

- 输入：`source_points` 中的 `:electric_potential` source，以及 kernel opts 里的
  `target_macro_index` / `target_local_macro`。
- 搜索：chunk-local AABB 内 bounded Dijkstra；frontier 默认上限 512，同成本路径按
  macro index 稳定排序，保证同一输入得到 deterministic channel。路径搜索默认走 Field
  层统一 native backend `SceneServer.Voxel.Field.NativeBackend`；业务 kernel 只传
  `ParticipantProjection`、`FieldLayer` 和 fallback，Rustler DTO 由
  `NativeBackend.ConductionPathInput` 负责编码。`SceneServer.Native.FieldKernel` 只是薄
  Rustler binding。`path_backend: :elixir` 保留为等价参考和回滚开关，authority、layer
  写入、Joule heat effect 和 observe 仍在 Elixir 侧执行。DTO 编码按当前 region AABB
  裁剪投影条目，避免小区域路径搜索携带整块导电图。其他纯计算 kernel 也应接入这个 Field
  native backend boundary，而不是各自新建独立 native ownership。
- 权威预检：`FieldRuntime.ensure_conduction_path/1` 在创建 FieldRegion 前读取 source chunk
  的当前 `Storage`，用同一套 channel 搜索确认 source/target 和中间路径都是材料上可导电的
  occupied cell；空 cell、挖掉后的 cell、低导电地面会以
  `source_not_conductive` / `target_not_conductive` / `no_conductive_path` 拒绝。普通 iron
  只表示导线；未显式传入 device/object/magic owner 或 power 参数时，source 必须是
  material_id=6 的 `power_block`，否则以 `source_not_powered` 拒绝，避免“凭空电源”。
  失败时会写 `voxel_conduction_path_rejected` observe：对外错误码保持兼容，日志额外保留
  `raw_reason`、更细的 `reject_reason`（如 `:search_budget_exhausted`）以及
  scene/chunk/source/target 定位字段，方便 CLI 直接判断失败原因。
- 路径代价：通过 `Storage.effective_attribute_at_normalized/3` 读取
  `electric_conductivity` / `dielectric_strength`；高电导率降低 resistance cost，
  dielectric strength 参与 breakdown cost。当前 material-gated 通道要求
  `electric_conductivity >= 1.0`，所以 dirt 的微弱漏导不会被当成导线；既有 ionization
  仍只影响已允许材料路径内的后续通道成本。
- 输出：刷新 region 内 `:electric_potential` / `:ionization` layer，source 到 target
  电势按路径长度衰减；当 `PowerSource` 开启热耦合时，会为路径上的导电 cell 生成
  `write_voxel_attribute(:temperature, heat_energy_joules)` effect，由 `ChunkProcess`
  作为 chunk authority 写回温度 truth。kernel 仍不直接改 voxel/object truth。
- 协议：仍复用 0x73/0x74 的 electric/ionization layer，不扩主 wire。
- Source lifecycle：`FieldRuntime.ensure_conduction_path/1` 会把导电请求正规化为
  `FieldSource(source_kind: :electric)`；source key 纳入 owner identity。物理电源块默认使用
  `{:electric, {:power_block, source_index}, source_index, target_index}`，显式
  device/object/magic owner 可通过 `owner_ref` 区分。同一 owner/source/target 会复用
  region；`ttl_ticks` 会覆盖本次 region 的 `max_ticks`，`energy_budget_joules` 先作为
  source policy/observe 摘要保留，实际消耗留给后续 lifecycle/effect slice。worker 自然到期
  时会释放 active source，并写出 `source_action: :expired` 的 lifecycle observe；客户端
  仍通过 0x74 destroy payload 看到 field 消失。
- PowerSource v1：electric `FieldSource` 会附带
  `SceneServer.Voxel.Field.PowerSource`，记录供电模式和供电上限：
  `output_mode: :dc | :ac | :pulse`、`voltage`、`current_limit_amps`、`load_current_amps`、
  `frequency_hz`、`energy_budget_joules`。这不是完整电路仿真；AC 当前不模拟相位，budget
  当前只做首 tick 预算门槛，不做持续扣减。若声明的负载电流超过电源限流，runtime 会在
  创建 region 前以 `current_limit_exceeded` 拒绝，并写结构化 observe。`power_block`
  默认声明 DC 120V、20A、20_000J 的 supply policy；这个 policy 已进入 summary/observe，
  并驱动导电路径的焦耳热 effect。

### ElectricDischargeKernel 算法

**`SceneServer.Voxel.Field.Kernels.ElectricDischargeKernel`** —— 电场介质击穿与瞬时放电 kernel：

- 定位：它不是“雷击技能”实现，而是 `source_kind: :electric` 的另一种物理传播模式。
  `ConductionPathKernel` 只允许既有导电材料形成通道；`ElectricDischargeKernel` 在 source
  potential 足够高时允许空 cell / 低导电介质被击穿并形成 ionized channel。
- 输入：复用 `FieldRuntime.ensure_conduction_path/1` 的 source/target、AABB、`PowerSource`
  和 `FieldSource` 生命周期；调用方通过 `conduction_mode: :discharge` 选择该模式。HTTP
  可传 `conduction_mode=discharge`，web CLI 暴露 `voxel_discharge ...`。
- 权威预检：创建 FieldRegion 前读取 source chunk 的当前 `Storage`，按同一套 discharge
  path search 判断是否能形成通道。低电势不能穿过完整 dielectric medium，会以
  `no_discharge_path` 拒绝并释放 source；高电势会读取 `electric_conductivity`、
  `dielectric_strength` 和已有 `ionization`，计算有效击穿阈值。
- 输出：刷新 `:electric_potential` / `:ionization` layer。电势沿通道衰减，通道 cell 写入
  高 ionization；热耦合仍走标准 `write_voxel_attribute(:temperature, heat_energy_joules)`
  FieldEffect，由 `ChunkProcess` 作为 chunk authority 写回 voxel truth。kernel 不直接写
  object/combat/damage。
- 架构边界：`FieldSource` 只描述电源与传播模式，`FieldRuntime` 只做权威预检和 region
  lifecycle，具体“导体导通”或“介质击穿”由 kernel 负责。后续雷击、线圈击穿、陷阱放电应复用
  这条电物理链路，而不是新增专用 lightning handler。

当前切片已接入 dev/runtime 入口和 browser overlay 验收；还没有 Phase 8 damage / ignite /
breakdown / 熔断破坏结算。

### TemperatureField 算法

**`SceneServer.Voxel.Field.TemperatureField`** —— 稀疏 3D 7-stencil 显式扩散 + source_points：

- 扩散系数：`α = min((thermal_conductivity / (density × specific_heat_capacity)) × dt / cell_size², 0.5)`；
  默认 `dt = 0.1s`、`cell_size = 1m`。`thermal_conductivity` / `density` /
  `specific_heat_capacity` 从 `Storage.effective_attribute_at/3` 读取。
- 已接入的 material-specific 默认物性：dirt、stone、wood、ice、iron、power_block；未知材质才回退到
  attribute catalog 的无材质默认值。未带 `FieldSource` 的底层 anomaly builder 仍保留
  真实时间尺度 (`diffusion_time_scale = 1.0`) 和 `1m` macro voxel。
- `SetTemperature` / browser Heat 入口会先写权威 voxel 温度属性，再用 normalized
  `FieldSource` 创建局部 observe/gameplay profile
  (`diffusion_time_scale = 20000.0`, `ambient_loss_per_second = 0.08`)；这个 profile
  只决定局部 FieldRegion 在用户可观察时间内如何显示/演化，不改变 chunk 上的温度 truth。
- 状态：只保存相对 `env_temp = 20°C` 的 float delta；未保存 cell 即环境温度
- 计算范围：当前异常 cell、热源 cell 及其 6-邻居 halo；无热源区域不会被背景温度写满
- 损耗：默认物理路径不使用调试期固定 `β` 回冷；交互 profile 可显式启用环境耗散。
  热量还会通过邻接扩散与有限 AABB 边界向环境流出。
  温度层 threshold 为 0.0001°C，低于 threshold 的 cell 自动退出 layer
- 出 AABB 的邻居视为 delta 0（即环境温度）
- `source_mode: :impulse` 只注入一次，适合 `F` / browser Heat 这类技能热量输入；显式
  `source_mode: :persistent` 会在扩散后重新写入，适合火把、炉子、设备等持续热源。

`tick(region, storage) :: {:ok, region}` 是每 tick 入口。

### Field 物理常量单一来源(防漂移)

**真相源:`native/field_kernel/src/field_constants.rs`** —— 电导/电势/介质击穿/温度扩散的
共享物理权重常量(`RESISTANCE_WEIGHT`、`BREAKDOWN_WEIGHT`、`IONIZATION_*`、
`CONDUCTIVE_COST_WEIGHT`、`TEMPERATURE_ALPHA_MAX`、`DEFAULT_*_RAW`、`EPSILON` 等)以前在
Rust 四个 kernel(`conduction_path` / `discharge_path` / `electric_potential` /
`temperature_diffusion`)与 Elixir 四个模块(`ElectricField` /
`Kernels.ConductionPathKernel` / `Kernels.ElectricDischargeKernel` / `TemperatureField`)
各写一份,人工同步极易漂移——一旦 `.ex` fallback 与 `.rs` native 用了不同权重,同一条
施法请求在两条路径上会算出不同的场结果。

现在两侧都从这一份 `.rs` 文件取数:

- **Rust 侧**:`field_constants.rs` 经 `lib.rs` 的 `mod field_constants;` 引入,四个 kernel
  直接 `use crate::field_constants::*`,不再各自 `const`。FACE_* 等纯网格编码常量没有
  Elixir 副本,不进真相源,保留在各文件本地。
- **Elixir 侧**:`SceneServer.Voxel.Field.Constants` 在**编译期**用正则解析
  `field_constants.rs` 的 `pub const NAME: TYPE = VALUE;` 行,把每个常量烘焙成模块函数
  (如 `Constants.resistance_weight/0`);各 kernel 的 `@xxx` 模块属性改为
  `Constants.xxx()`。选择编译期从 `.rs` 烘焙、而非运行期从 NIF 读,是因为 Elixir
  fallback 恰恰在 NIF 不可用时运行,运行期从 NIF 取常量会自相矛盾;编译期烘焙让 fallback
  完全自包含且与 native 数值逐位一致。`@external_resource` 确保 `.rs` 变化时 `Constants`
  重新编译。`NativeBackend.TemperatureDiffusionInput` / `DischargePathInput` /
  `ParticipantProjection` 里同源的 `DEFAULT_*_RAW` / `FIXED32_SCALE` 也改为从 `Constants` 取。
- **门禁**:`field_constants_parity_test.exs` 断言 `Constants` 解析值与权威物理数值逐一
  一致、常量集合无遗漏/多余、且直接对照 `.rs` 源文本——任何人误改 `.rs` 数字都会报红。
  Rust 侧 `cargo test` 覆盖 kernel 行为,确认常量收口后数值不变。

维护纪律:改物理行为时**只**改 `field_constants.rs` 的数值(两侧编译期自动同步),并同步
parity 测试的期望表;不要在任何 `.ex`/`.rs` kernel 里重新硬编码这些权重。

### FieldRuntime 异常入口

**`SceneServer.Voxel.Field.FieldRuntime`** —— 把异常 voxel 属性转成局部场的服务端入口：

- `build_temperature_anomaly/1` 是纯函数：接收 world-macro voxel、`Storage`、radius、max_ticks，
  从 voxel 的 effective `temperature` 属性读取异常量，再计算 chunk/local macro、
  source macro_index、初始 AABB 和物性驱动的 kernel-first region attrs；
- `ensure_set_temperature/1` / `ensure_temperature_anomaly/1` 调用
  `ChunkDirectory.ensure_chunk/1`，HTTP/World 入口必须先经
  `MapLedger.route_chunk_with_lease/3` 找到 source chunk owner 并把当前 lease 透传到
  Scene；Scene 侧只消费该 lease 后写目标 chunk。随后通过
  `ChunkProcess.write_temperature_attribute/2` 把 set-temperature action 的目标温度（Heat alias 默认 800°C）
  写入选中 solid voxel 的 `temperature` attribute，并在 summary 中按
  `density × specific_heat_capacity × volume` 回算所需热量，再由
  `build_temperature_anomaly/1` 检测异常并调用
  `ChunkProcess.ensure_field_region/2` 创建或复用 `TemperatureDiffusionKernel` region；
- `ChunkProcess.ensure_field_region/2` 使用 caller 提供的 `source_key` 做 active source
  去重；同一 chunk 内同一 `{temperature, macro_index}` 活跃 region 会替换为最新
  source_points。`SetTemperature` / browser Heat 默认创建 `:impulse` source，完成一次热扰动后
  由扩散、AABB 边界和环境耗散自然消散；持续热源需要调用方显式传 `source_mode: :persistent`，
  不会重复堆叠 FieldRegion；
- 目标温度与环境基线 `20°C` 的差值低于 `1°C` 时不创建 region；若同一
  `source_key` 已有活跃 region，则通过 `release_field_region_source/3` 走 0x74
  destroy fanout 并释放 source，保持常态属性零成本；
- web_client 的 `F` 键、HUD `Heat` / `Cool` 按钮和 CLI
  `voxel_temp <x> <y> <z> <target_temperature_celsius> [max_ticks]` 通过
  `/ingame/voxel/set_temperature` 提交“设置 voxel 目标温度”的意图；`voxel_heat` /
  `voxel_cool` 与 `/ingame/voxel/dev_heat_voxel` 保留为 alias。客户端仍只消费自动下发的
  0x73/0x74；set-temperature 成功后 web_client 自动打开 Field overlay，并提供
  `field_overlay [on|off]` CLI 诊断。
- `ensure_conduction_path/1` 现在与 temperature path 共用 `FieldSource` source/region
  生命周期入口：HTTP/runtime 可传 `source_mode`、`owner_ref`、`ttl_ticks`、
  `output_mode`、`voltage`、`current_limit_amps`、`load_current_amps`、`frequency_hz`、
  `energy_budget_joules`，summary 会回显 normalized source、`power_source` 和
  `power_draw`。未显式传 owner/power 参数时，
  source cell 必须是 `power_block`；导线材料只负责导通，不负责发电。kernel 仍只演化
  electric/ionization field，并通过标准 FieldEffect 把路径焦耳热交给 chunk authority 写回
  温度 truth；ttl 到期会走 worker expiry -> source lifecycle cleanup -> 0x74 fanout，避免一次
  导电来源永久残留在 chunk runtime。导电预检失败和电源过载失败都会写结构化 observe，搜索预算
  耗尽、电流超限等内部原因不会被外部兼容错误码吞掉。
- 自动电路不再把“source 与 load 在同一导电连通分量”当作有效回路。`CircuitComponentAnalysis`
  先把 solid / refined / prefab 的导电面投影成 segment graph，再取 graph 2-core 作为闭合环路
  核心；这个闭合 source-load 谓词是自动电路的 runtime 准入条件，也是
  `CircuitCurrentKernel` 的写入条件。开路 source-load 路径会以 `:no_closed_circuit`
  释放或拒绝，不分配空 FieldRegion；断开闭环上的任意导体后，`ChunkProcess`
  会销毁自动 current region/source 并走 0x74 fanout，浏览器 overlay 应移除该 current region。
- Phase 7.D3 起，`FieldTickWorker` 不再静默丢弃 non-observe kernel effects：
  observe effect 仍由 worker 写结构化日志，`write_voxel_attribute(:temperature)` 等
  truth effect 统一交给 chunk authority。Phase 8 combustion 第一片在这个边界上追加
  `write_voxel_attribute` 普通属性写入、`transform_voxel_material` 和 `clear_voxel_cell`：
  温度场只传播热，`SceneServer.Voxel.Phenomenon.Combustion` 判断材料是否点燃、消耗多少
  fuel / oxygen、进入 burning / smoldering / extinguished 哪个阶段，以及最终变成 charcoal、
  ash 或清空格子。燃烧产生的持续热源以“本 tick 消耗燃料 × material
  `combustion_heat_j_per_kg` × 释放效率 / voxel 热容”换算为 source temperature，再被材料
  明火/阴燃热源上限裁剪；该 source 以 `source_kind: :combustion` 写回同一个 FieldRegion
  的 temperature source_points，下一 tick 继续参与温度传播。进入 burning / smoldering
  后还会用稳定 `{:combustion_instance, logical_scene_id, chunk_coord, macro_index}`
  source_key 创建或刷新同 chunk 自持 FieldRegion，让触发它的外部 heat impulse 到期后，
  火焰仍能继续按 fuel / oxygen / stage 消耗并产热。
  边界上的燃烧热源不会直接写相邻 chunk；`CombustionKernel` 会产出
  `ensure_field_region` effect，源 chunk 通过 `ChunkDirectory` 把它交给目标 chunk，
  目标 chunk 再创建自己的 temperature/combustion region 并按同一材料规则判断是否点燃；
  remote handoff 不继承 source chunk lease，目标 FieldRegion 在目标 chunk authority
  上捕获目标 chunk 当前 lease。
  低氧高温路径不会创建自持 heat source；它先增加 carbonization / structural_integrity
  损耗，木材越过材料碳化阈值后通过同一 authority 边界转为 charcoal。
  truth effect 通过 `ChunkProcess.apply_field_effects/3` 交回 chunk authority；
  当前支持温度/普通 attribute 写回、材料转化和清空格子；未知 action 仍以
  `voxel_field_effect_rejected` 明确拒绝。Phase 8.D 的结构损伤现在通过共享
  `StructuralIntegrity` effect 边界写回：燃烧、低氧碳化和冻结都不各自发明
  failure threshold 语义，而是在 `structural_integrity` 跌破材料阈值时统一产生
  `voxel_structural_collapse_candidate` 和 `apply_structural_damage` effect。
  `ChunkProcess` 作为 authority 读取该 macro 内实际 owner micro-slot 覆盖，按
  `(object_id, part_id)` 聚合 damage，并复用 `ObjectRegistry.accumulate_damage`
  进入 prefab/object part-health 账本；field kernel 和 phenomenon 仍不直接修改
  object truth。当前还没有结构稳定性重算、裂纹传播或 debris 生成。
- 浏览器/开发 CLI 现在有只读燃烧真值入口：
  `voxel_combustion <x> <y> <z>` 通过 `/ingame/voxel/combustion_probe`
  路由到目标 chunk 的 scene owner，返回材料、是否可燃、燃烧阶段、fuel / oxygen、
  smoke、carbonization、structural_integrity 和材料残留策略。该入口只读，不创建
  FieldRegion，也不替代 `ChunkProcess` authority；它用于验证高温燃烧扩散的材料状态，
  不要求用户从 overlay 颜色或截图间接推断。
- `mix scene_server.natural_phenomenon_observe --scenario spread --coord 0,0,0`
  提供多材料火场的 CLI 验收面：命令会放置 source wood、dry grass、cloth 和 stone，
  以及一个低氧 wood 分支，走正式 `set_temperature` 温度入口，再用只读 combustion
  probe 汇总 `spread_ignited_count`、`spread_residue_count`、`spread_inert_count`
  以及每格 `initial->current:stage:outcome`。默认验收会看到 dry grass 清空、
  cloth 变 ash、低氧 wood 变 charcoal，stone 保持 inert。该场景只调已有可燃材料的
  热释放/燃速以便几 tick 内完成验收，不会让 stone 等无 combustion profile 的材料
  变成可燃物。
- 腐蚀也有同类只读真值入口：
  浏览器 CLI `voxel_corrosion <x> <y> <z>` 通过 `/ingame/voxel/corrosion_probe`
  路由到目标 chunk 的 scene owner，返回材料、是否可腐蚀、surface_state、moisture、
  chemical_concentration、corrosion、corrosion_resistance、electric_conductivity、
  structural_integrity 和 active `corrosion` instance。该入口只读，不执行腐蚀规则，
  不创建 FieldRegion，也不替代 `ChunkProcess` authority。
- 相变也有同类只读真值入口：
  浏览器 CLI `voxel_phase <x> <y> <z>` 通过 `/ingame/voxel/phase_change_probe`
  路由到目标 chunk 的 scene owner，返回材料、`phase_state`（stable / frozen /
  boiling / vapor）、temperature、moisture、structural_integrity、contained-water
  阈值以及 active `phase_change` instance。
  该入口用于验证冻结、沸腾和水汽释放后的持久 voxel truth；它不执行相变规则，
  不创建 FieldRegion，也不替代温度/湿度场 tick。
- 对象物理状态也有只读验收入口：
  浏览器 CLI `voxel_object <object_id> <x> <y> <z>` 通过
  `/ingame/voxel/object_probe` 按给定世界坐标路由到 scene owner，再读取该 scene
  的 `ObjectRegistry`，返回对象版本、覆盖 chunk、对象 flags、每个 part 的 health /
  damaged / destroyed 状态，以及 damaged/destroyed part 计数。该入口用于验证燃烧、
  低氧碳化或冻结造成的结构损伤是否已经进入 prefab/object part-health 账本；它只读，
  不执行结构稳定性重算，不创建 FieldRegion，也不绕过对象 authority。

当前切片已经把“SetTemperature/Cool -> 写入 voxel 温度属性 -> 服务端发现温度异常 -> 创建/复用
局部 FieldRegion -> impulse 热扰动可扩散并消散 -> kernel tick -> 温度 effect 可回写 voxel truth -> 客户端 overlay 可显示 -> 回到环境温度时销毁 region/source”
串通。electric conduction 已具备 owner-aware source key、ttl lifetime 和 budget policy
摘要，导体路径与介质击穿路径都能把电场通道转换为温度 truth 的焦耳热写回；燃烧热源已能在共享
`ChunkDirectory` 权威路径下跨 chunk face 续租邻居 temperature region 并点燃目标材料。尚未完成的部分是从
持久 voxel truth 扫描/订阅异常属性、owner 存活探测、budget 持续扣减、跨节点/AOI lifecycle，
以及结构稳定性、debris 和战斗结算闭环。

### FieldCodec

**`SceneServer.Voxel.Field.FieldCodec`** —— 0x73 / 0x74 wire codec：

**0x73 FieldRegionSnapshot wire layout（opcode 字节包含在内）**：
```
opcode:          u8   = 0x73
logical_scene_id: u64  big-endian
cx/cy/cz:        i32 × 3  big-endian
region_id:       u64  big-endian
tick_count:      u32  big-endian
field_mask:      u8   (0x01=temperature / 0x02=electric_potential / 0x04=ionization / 0x08=electric_current)
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

**`SceneServer.Voxel.Field.FieldTickWorker`** —— per-region GenServer，每区域首帧立即执行，随后独立 10 Hz 调度：

- `init/1`：监控 ChunkProcess（`Process.monitor(chunk_pid)`）；立即投递第一个 tick，让一次性放电 /
  加热这类短寿命场域不额外等待 100ms 调度周期
- `handle_info(:tick)`：
  1. `GenServer.call(chunk_pid, :debug_state, 200)` 取 storage 快照，并在 `KernelContext`
     中规范化一次
  2. 按 `region.kernels` 逐个运行 FieldKernel，更新 region；kernel 热路径使用已规范化
     storage / context API，禁止在每个 cell 的属性读取里重复整块 `Storage.normalize!/1`
  3. `FieldCodec.encode_snapshot_payload` 编码
  4. `ChunkProcess.push_field_snapshot_payload` cast 给 ChunkProcess，让服务端已算出的首帧场域先进入
     subscriber fan-out；non-observe truth effects 随后交回 ChunkProcess authority 批量应用
  5. emit observe events：`voxel_field_tick_completed` / `voxel_field_snapshot_dispatched`
  6. 若未到 `max_ticks`，`Process.send_after(self(), :tick, @tick_interval_ms)` 调度下一 tick
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
