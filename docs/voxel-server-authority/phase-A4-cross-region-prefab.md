# Phase A4 — 跨 region prefab 多 participant 事务

**起草日期**:2026-05-10。**状态**:决策稿(等用户确认 D1-D6 后开始实施)。

A2 + A1 + A1-1b 修完后用户问"跨 region 摆放能实现吗?backlog 里是不是有前置依赖?"。结论:**没有真前置阻塞**。下层组件(`TransactionCoordinator` / `TransactionExecutor` / `BuildTransactionApplier`)都已是 multi-participant ready,只是 `gate_server` 的 `0x67` dispatch 切片故意写死成 single-participant(原 Phase 3 D6 决定)。本阶段把它打通。

A3(多客户端联调)和本阶段独立,顺序无强约束。

## 阶段目标

跨 region prefab **整条用户体验**(摆放 + 破坏 + 广播)端到端可用,不是只摆放成功而破坏链路碎掉。

具体三条:

1. **摆放**:`0x67 PrefabPlaceIntent` 在 prefab 跨多个 region/lease 时落地成功,不再在 `BuildTransactionApplier.prepare` 里因 lease mismatch 整体 reject。任意 participant prepare 失败 → 全部 abort 不留半提交。
2. **破坏路由**:玩家攻击跨 region prefab 的**任何一个 chunk**(不论是否是 object owner region),都能正确触发 `ObjectRegistry.accumulate_damage` → cascade(damage / part_destroyed / object_destroyed)。
3. **广播触达**:0x6C `ObjectStateDelta` 推送到 prefab 覆盖的**所有 chunks 的订阅客户端**,跨 region 不漏帧;玩家在两 region 各自看到自己附近 chunk 的破坏视效。

**2PC 完整性**:任意 participant prepare 失败 → 全部 abort,不留半提交;任意 participant commit 失败 → 已 commit 的 chunks 不变(2PC 不能回滚已 commit,但可以观测/告警),Phase 3-bis recovery watcher 接管 `:prepared` 状态。

**诱因**:Phase A1 hotfix 让 mid-macro 锚有可能让 prefab 自然跨 chunk;chunk 边界恰好是 region 边界时,会触发 cross-region 路径。**摆放 + 破坏 + 广播**三条都要打通才算"跨 region prefab 可用",只做摆放是半成品。

## 不在范围

- **per-region coordinator / coordinator HA**:仍然是单全局 coordinator,Phase 6 留。
- **超大 prefab(覆盖多于 ~4 chunks)**:本阶段不做 prefab geometry 生成层面限制。如果 v3 prefab 真的能跨 8+ chunks,网络扇出风险大,触发 e2e 测试再加 cap。
- **wire 协议升级**:不动。`0x67` 输入不变,`0x68 VoxelIntentResult` reason 沿用现有 atom 风格。
- **prefab v3 多 macro mask**:`BlueprintCatalog` 仍单 macro mask(8³ slots),mid-macro 锚仍最多扩到 8 macros / 4 chunks(2³)。
- **客户端跨 region 预览提示**:线框预览不知道(也不需要知道)是否跨 region;只在服务端 reject 时 HUD flash 提示用户(D3 决定)。
- **Recovery watcher resume 路径完善 multi-participant**:本阶段如果 recovery watcher 已经能正确处理 multi-participant `:prepared` 重发(Phase 3-bis-5 的 resume 逻辑应该自然支持,因为 `intents_by_participant` 已经在 BuildTransaction 持久化),只 verify;如果有 gap,**留 backlog**,本阶段不修。
- **damage 跨 scene_node RPC 失败时的重试 / 死信**:跨 region damage RPC 失败(网络抖动 / 远端 ObjectRegistry crash)时只 emit observe + drop,不重试。生产环境 HA 范围,Phase 6 留。
- **0x6C 跨 region 广播的去重 / 严格顺序**:跨 region fan-out 时不同 region 客户端可能不同时收到广播,object_version 单调保 dedup,但严格 wall-clock 同序留 Phase 5+。

## 决策项

### D1. TransactionExecutor 的 scene_opts 改成 per-participant

**现状**:
- `TransactionExecutor.execute(coordinator, transaction, intents_by_participant, opts)` 接受单一 `:scene_opts` 关键字
- `scene_opts: [chunk_directory: {ChunkDirectory, scene_node}]` 是**一份 opts 喂所有 participants**
- 多 region 时每个 participant 在不同 scene_node 上,需要不同的 `chunk_directory` tuple

**目标**:executor 能给每个 participant 用各自的 scene_opts。

**推荐方案**(D1.A):**新增 `:scene_opts_by_participant` opts,旧 `:scene_opts` 废弃**(全新未上线纪律,不留双路径)。

```elixir
TransactionExecutor.execute(
  coordinator,
  transaction,
  intents_by_participant,
  scene_opts_by_participant: %{
    {region_a_id, lease_a_id} => [chunk_directory: {ChunkDirectory, scene_node_a}, logical_scene_id: ...],
    {region_b_id, lease_b_id} => [chunk_directory: {ChunkDirectory, scene_node_b}, logical_scene_id: ...]
  },
  per_participant_timeout_ms: 5_000,
  ...
)
```

`run_prepare` / `run_commit` / `run_abort` 内部按 `participant -> {region_id, lease_id}` key 取 per-participant opts。
`logical_scene_id` 仍 by transaction 注入,不需要 caller 在每份 opts 里写。

**被否方案**:
- D1.B `scene_opts_resolver: (participant -> opts)` callback。**否**:executor 调用方传 closure,coordinator 持久化 transaction 时 closure 跑了一半 server 重启就丢,recovery watcher resume 时无法重建 closure。
- D1.C 在 `participant` struct 加 `scene_node` 字段。**否**:`participant` 是 `BuildTransaction` 的持久化 wire/persist 一部分,scene_node 是动态信息(lease 漂移会换 scene_node),不该污染持久化字段。
- D1.D 维持单 `scene_opts` + 新加 `chunk_directory_resolver: (participant -> {Mod, node})` 单独参数。**否**:其他 scene_opts(observe context、未来加的 per-region 配置)同样需要 per-participant,一次到位更干净。

**推荐:采纳 D1.A**。Caller(gate)本来就是按 participant 分组的,构造 map 是自然事;recovery 时 watcher 通过 `transaction.participants` + 当前 lease lookup 重建 map,这条路径走 `:scene_opts_resolver` opt(callback,因为 watcher init 必须重新解 lease;watcher 不参与持久化,closure 安全)。

> **Sub-decision D1.1**:Recovery watcher 的 resume 路径走 callback 还是 map?
>
> Watcher init 时刚加载 transaction(含 participants),lease 是 dynamic 状态(可能换 scene_node 了),map 必须现解。**推荐:watcher 用 callback,executor 用 map**。两者签名都支持 `:scene_opts_resolver` 作为 fallback,但 executor 优先用 map(显式更好序列化测试)。

### D2. scene_objects 注册:单 owner participant + 持久化 owner 元数据

**现状**:Phase 4 起 prefab transaction 可能在 `BuildTransaction.scene_objects` 中携带新建的 scene_objects(给 prefab 实例分配 object_id);commit 后 `register_scene_objects_after_commit/3` 把它们 upsert 到 scene-side `ObjectRegistry`。当前**单 scene_node** 路径只在那一个 node 上 register。

跨 region 时,一个 scene_object 的 `covered_chunks` 可能跨多个 region。问题:每个 region 都有自己的 `ObjectRegistry`(scene-local),要不要每个都 register?

**推荐方案**(D2.A):**单 owner participant + 持久化 owner 元数据**。

- 每个 scene_object 选**第一个 covered chunk(按 `chunk_coord` ascending 排序)所在的 region** 作为 owner participant
- 只在 owner participant 的 scene_node 上的 `ObjectRegistry` register(权威态单点,destroy/damage 不会双副本不一致)
- `voxel_scene_objects` 表新加 `owner_region_id` + `owner_lease_id` 列;commit 时按 owner participant 写入(D6 决定字典序选取规则)
- 读侧 D7 决定:damage 路由 / 0x6C 广播在跨 region 时通过 owner 元数据 RPC 到正确 scene_node

**被否方案**:
- D2.B fan-out register 到所有 covered participants(双副本)。**否**:destroy_object 时多副本一致性难(一个 region destroy 了怎么 propagate),容错复杂度大于收益。
- D2.C ObjectRegistry 改成 World-side 全局。**否**:架构大改,本阶段范围爆炸。
- D2.D 单 owner 但 damage / 广播跨 region 落空(本阶段只做 register)。**否**:用户明确指出"跨 region 摆放 = 半成品破坏"违背阶段目标。修法见 D7。

### D3. 失败时 wire reason 格式

**现状**:`unwrap_prepare_reason({:prepare_failed, _coord, inner})` 取 inner reason 给客户端,`logical_scene_id`/`region_id` 等不进 wire reason(放 observe log)。

**目标**:多 participant 时哪个 participant 失败 / 为什么失败,wire 上对客户端友好,observe log 详记便于运维。

**推荐方案**(D3.A):

- **wire reason**:取**第一个失败 participant 的 inner reason**(沿用 `unwrap_prepare_reason`),client UI 直接 flash 那个 atom("该位置已有方块" 等)。
- **observe log**:`build_prefab_plan` 阶段记录 participant 总数 / 各 region_id;`finalize_prefab_outcome` 记录每个 participant 的 prepare/commit 结果(成功/失败/原因)。新增 observe key `ws_voxel_prefab_multi_region_dispatched`(participant 数 ≥ 2 时 emit)和 `ws_voxel_prefab_multi_region_aborted`(任意 participant prepare 失败时 emit,带所有 participant 状态)。

**被否方案**:
- D3.B 包装成 `{:cross_region_prepare_failed, [{participant_key, reason}, ...]}` 透传到 client。**否**:wire 上嵌套 atom/tuple 对 client 不友好,UI 显示要解嵌套。
- D3.C 取最严重的(按 priority 排)。**否**:reason 没有标准 priority,排序逻辑维护成本大于收益。

**推荐:采纳 D3.A**。

### D4. 测试 e2e harness — 同 BEAM 双 ChunkDirectory

**现状**:
- `scene_server` test_helper 起单一 `Application`,`ChunkDirectory` / `ObjectRegistry` 都是 module-named singleton
- chunk_process_test.exs 已经支持 per-test instance(用 `:name` opt 注入 module)
- 但 `BuildTransactionApplier.prepare/4` 默认调 `ChunkDirectory`(module-named),要 override 通过 `opts[:chunk_directory]`

**目标**:跨 region prefab e2e 测试要能在单 BEAM 内启动两个 region 各自的 `ChunkDirectory` + `ObjectRegistry`,gate `build_prefab_plan` 路由到不同 directory,executor 并行 prepare/commit。

**推荐方案**(D4.A):

- 新建 helper `WorldServer.Voxel.MultiRegionFixture`(在 `test/support/`):
  - `start/1` 起两个 named instances:`{ChunkDirectory.RegionA, scene_node_a_pid}` / `{ChunkDirectory.RegionB, scene_node_b_pid}`(scene_node 在测试里就是当前 BEAM,但 directory module 用不同 name)
  - 每个 instance 有自己的 `:pg` group(默认 group 加 region 后缀)
  - 配套 `mock_route_voxel_chunk(scene_id, chunk_coord)`:把 chunk_coord ∈ region A bounds 的路由到 RegionA,反之 RegionB
- gate `route_voxel_chunk` 在 test 模式下走 `Application.get_env(:gate_server, :route_voxel_chunk_fn)`(已有此模式),test 注入 `MultiRegionFixture.mock_route_voxel_chunk/2`
- 一条 e2e test:
  - 起 fixture
  - prefab 锚点跨两 chunks 各属一 region
  - 调 gate 0x67 dispatch
  - 验证 RegionA 和 RegionB 的 chunk_directory 都收到 prepare/commit
  - 验证两 chunks 的 storage 都被写

**被否方案**:
- D4.B 用 `:peer` 起两个 BEAM 节点,每节点 `WorldSup` 起 SceneServer。**否**:跨节点测启动慢(秒级),CI 噪声大;我们核心测的是 gate 路由 + executor 多 participant 调度,不需要真实跨节点 RPC。
- D4.C 不写 e2e,只 mock 测 gate `build_prefab_plan` + executor `prepare_results` 两端。**否**:multi-participant transaction 真的能贯通 commit_decision 和 register_scene_objects 没 e2e 验证,下次回归无报警。

**推荐:采纳 D4.A**。

### D5. Gate per-chunk 路由失败时的处理

**现状**:`build_prefab_plan` 只 route 第一个 chunk,失败直接 reject。

**目标**:per-chunk 路由,任一 chunk 路由失败的处理。

**推荐方案**(D5.A):**Fail-fast,任一 chunk 的 `route_voxel_chunk` 返回 `{:error, _}` → 整个 prefab reject `:no_route_for_chunk`。理由**:transaction 语义就是 all-or-nothing,部分能路由的子集没意义。如果某 chunk 当前不在任何 region(罕见,通常是 World ledger 临时空)用户重试即可。

**被否**:**继续路由可路由的部分**。**否**:违反 transaction all-or-nothing。

**推荐:采纳 D5.A**。

### D6. Scene_objects owner participant 选取规则

**现状**:Phase 4 决策稿没明确 multi-region 时 scene_object 的 owner 选取规则(因为当时是 single-region)。

**推荐方案**(D6.A):
- 每个 scene_object 的 `covered_chunks` 里挑**字典序(`{x, y, z}` ascending)第一个 chunk 所在的 region** 作为 owner participant。
- 编码进 `BuildTransactionApplier.register_scene_objects/2`:之前是直接 upsert ObjectRegistry,现在先按 owner_region_id 分组,只 upsert 自己 region 的 objects。
- `voxel_scene_objects` 表加两列 `owner_region_id` + `owner_lease_id`,本阶段**写入并查询**(D7 用)。

**推荐:采纳 D6.A**。

### D7. 跨 region damage 路由 + 0x6C 广播投递

**现状**:
- `SceneServer.Combat.VoxelDamageRouter.dispatch_damage` 在拿到 `Storage.lookup_owner_at` 返回的 `{object_id, ...}` 后,直接调本地 `ObjectRegistry.accumulate_damage`。跨 region 时,玩家攻击的 chunk 在 region B,但 object owner 在 region A,**本地 ObjectRegistry 找不到该 object → damage 落空**。
- `ObjectRegistry` cascade(part_destroyed / object_destroyed) 后调用 `ChunkProcess.push_object_state_delta_payload(delta)`,内部 `ChunkDirectory.lookup_chunk_pid` 按 `delta.affected_chunks` 找 chunk_pid 推送。跨 region 时,affected_chunks 中的非-owner-region chunks 不在本地 ChunkDirectory 里,**那些 chunks 的订阅客户端收不到 0x6C 广播**。

**目标**:跨 region 时 damage 路由命中正确的 owner ObjectRegistry,cascade 广播触达所有 covered chunks 的订阅客户端。

**推荐方案**(D7.A):**owner 元数据 + per-hop scene_node lookup**。

1. **新模块 `SceneServer.Voxel.ObjectOwnerLookup`**(per-scene cache):
   - API:`fetch_owner(scene_id, object_id) :: {:ok, %{owner_region_id, owner_lease_id, scene_node}} | {:error, :not_found}`
   - 冷启动从 `voxel_scene_objects` SELECT;hot path 命中 ETS / GenServer state
   - `register_scene_objects_after_commit` 完成后写入 cache(避免 commit 后 SELECT race)
   - `ObjectRegistry.destroy_object` 后 evict
   - scene_node 通过 `BeaconServer.Client.lookup({:voxel_region_scene_node, region_id, lease_id})` 解析(已有 region/lease → scene_node 映射,Phase 1c 起就用)

2. **`VoxelDamageRouter.dispatch_damage` 改造**:
   - `Storage.lookup_owner_at` → `object_id`
   - `ObjectOwnerLookup.fetch_owner` → `{owner_region_id, scene_node}`
   - 本地 → `ObjectRegistry.accumulate_damage(...)` 原路径
   - 跨节点 → `:rpc.call(scene_node, ObjectRegistry, :accumulate_damage_remote, [...], 200)`,失败 emit `voxel_damage_cross_region_failed` observe + drop(不重试,不破坏 damage 主路径)
   - 新 observe:`voxel_damage_routed_cross_region`(成功)/ `voxel_damage_cross_region_failed`(rpc fail)

3. **0x6C 跨 region 广播**:**owner-driven fan-out**(对齐 owner 单点权威语义)
   - `ObjectRegistry.emit_object_state_delta`(在 owner scene_node 上)按 `delta.affected_chunks` 分组:本地 chunks 走原 `ChunkDirectory.push_object_state_delta_payload`;远端 chunks 走 `BeaconServer.Client.lookup({:voxel_region_chunk_directory, region_id})` 找远端 ChunkDirectory pid,`GenServer.cast({ChunkDirectory, scene_node}, {:push_object_state_delta_payload, delta_subset})`
   - 远端 ChunkDirectory 收到 cast → 本地 fan-out 给本 region 内的 chunks(原 4-bis 路径)
   - 跨 region cast 失败 → emit `voxel_object_state_delta_cross_region_dropped` + drop(fire-and-forget,object_version 单调保 client dedup,后续广播会让 client 状态收敛)
   - **affected_chunks 按 region 分组**:`ChunkDirectory` 持有自己 region 的 chunk_coord set,owner 端通过 `voxel_scene_objects.covered_chunks` + 每个 chunk 的 region 解析(冷启动时不知 region → 一次性 SELECT covered chunks 各自的 owner region;cache in ObjectOwnerLookup)

**被否方案**:
- D7.B 通过 World-side 全局 ObjectRegistry 中转 damage / 广播。**否**:架构大改,World 不该承担 hot path 路由(coordinator 只管 transaction account-keeping)。
- D7.C ChunkDirectory.lookup_chunk_pid 直接跨 region 透明查(每次 lookup miss → BeaconServer)。**否**:hot path 在 lookup_chunk_pid,加 BeaconServer 调用拖慢同 region 的 99% 路径;owner-driven fan-out 只在跨 region 时付代价。
- D7.D 把 owner 元数据缓存进 `MicroLayer` 的 owner 信息里(`owner_object_id` 旁边再放 `owner_region_id`)。**否**:micro layer 已经是 wire/persist 关键路径,加字段会让 chunk_hash / wire 编码扩张;ObjectOwnerLookup 一层 SELECT cache 的代价更小。

**推荐:采纳 D7.A**。owner-driven fan-out 是关键设计 — 单点权威 + per-hop 解析,既保证 hot path 不退化,也对齐 ObjectRegistry "object owner 是单点权威"语义。

## 风险

1. **`BuildTransaction` 持久化字段又演进**:加 `owner_region_id` / `owner_lease_id` 到 `voxel_scene_objects`,但 `BuildTransaction.scene_objects` 字段(in-memory)语义没变。`cc3a31d` 的 stale-snapshot catchall 仍然只兜底 transaction 主体的 plain-map shape;`scene_objects` 列表如果旧 blob 反序列化出 plain map,`register_scene_objects` 会 raise。**缓解**:在 `BuildTransactionApplier.register_scene_objects/2` 入口加 `is_struct(obj, SceneObject)` 校验,plain map 直接 emit observe + skip(不 raise),让 commit 不被这个非关键步骤阻塞。
2. **`ObjectOwnerLookup` 冷启动 SELECT 风暴**:server 重启后 lookup cache 空,首批 damage 都触发 SELECT。`voxel_scene_objects` 表行数若大(prefab 累积),冷启动期 damage 路径变慢。**缓解**:cache miss SELECT 加 `FOR SHARE` 锁避免重复请求;打开 metric 看冷启动期 95p latency。如果实测有问题,加 `OnDemandPreload`(server boot 时异步预热 cache)— 留 sub-backlog 不在主路径。
3. **跨节点 RPC 失败处理(damage / 0x6C)**:`:rpc.call` 200ms 超时 / 远端 ObjectRegistry crash 时本阶段是 fire-and-forget(emit observe + drop)。意味着**网络抖动期间客户端可能漏帧 / 漏 damage**,但 object_version 单调让后续广播帮 client 状态收敛。**缓解**:加 metric `voxel_damage_cross_region_failed_rate` 和 `voxel_object_state_delta_cross_region_dropped_rate`,超阈值告警;真重试 / 死信队列留 Phase 6 HA。
4. **0x6C 跨 region 广播的 affected_chunks per-region 分组**:owner-driven fan-out 要把 `delta.affected_chunks` 拆成 per-region 子集。owner 端必须知道每个 chunk 在哪个 region,这要么走 `voxel_scene_objects.covered_chunks` + per-chunk SELECT(慢),要么把 per-chunk owner_region 也 cache 在 ObjectOwnerLookup 里(命中率高但内存大)。**推荐 cache 整 covered_chunks 元组**(每个 object 通常只跨 2-4 chunks,内存可控);prefab register 时一次性写入,evict 时随 destroy_object 整体清。
5. **`:pg` group 命名空间在测试 fixture 里冲突**:`ChunkDirectory` 用 `:pg` 分发 broadcast。两个 named directory 共享同一 `:pg` group 会让 RegionA 收到 RegionB 的消息。**缓解**:`MultiRegionFixture` 给每个 directory 一个独立 `:pg_group_name`(已有 opt)或注入 mock dispatcher。
6. **跨 region prepare 超时**:`per_participant_timeout_ms = 5000` 仍然每 participant 独立(并行 `Task.async_stream`),延迟不累加。但 **`transaction_timeout_ms = 30000`** 是 ceiling,跨 region 对它挤压更大。本阶段保持现值,测试时 verify 能在 30s 内跑完;真实生产(跨地理 region)再调。
7. **`MultiRegionFixture` 跟现有 `chunk_process_test` per-instance 模式重复造轮子**:实施时 verify 能否复用 existing helper(`SceneServer.Voxel.TestHelpers.start_chunk_directory_instance/2` 之类),不能再新建。
8. **`unique_prefab_transaction_id`(`prefab-#{request_id}-#{unique}`)在多 participant 下仍唯一**:已 monotonic + 进程级 unique_integer,无需改。

## 步骤分解

每步独立 commit,Elixir 改前 `mix format`,改 web 端跑 `cd clients/web_client && npx tsc --noEmit && npx vitest run`。**不 push**。

| Step | 范围 | 验证 | 估时 |
|---|---|---|---|
| **A4-1** | `TransactionExecutor.execute` 接受 `:scene_opts_by_participant` map(替换原 `:scene_opts`,无双路径);`run_prepare`/`run_commit`/`run_abort`/`register_scene_objects_after_commit` 取 per-participant opts;executor 单测加 multi-participant case | scene_server / world_server 单测全绿 | 0.5 天 |
| **A4-2** | Gate `build_prefab_plan` per-chunk `route_voxel_chunk` + 按 `{region_id, lease_id}` 分组成 participants;`coordinator_begin_transaction` 构造 multi-participant `attrs.participants`;`executor_execute` 喂 `scene_opts_by_participant` map(ws + tcp 镜像);gate 单测 multi-participant + fail-fast | gate_server 测试全绿,e2e 单 region 路径不破坏 | 0.5 天 |
| **A4-3** | `voxel_scene_objects` schema + migration 加 `owner_region_id` / `owner_lease_id` + `covered_chunks_by_region` 列;`SceneObjectStore` 写入新字段;`BuildTransactionApplier.register_scene_objects/2` 按 owner_region_id 分组,只 upsert 自 region | data_service / scene_server 测试全绿 | 0.5 天 |
| **A4-4** | `SceneServer.Voxel.ObjectOwnerLookup` per-scene cache(冷启动 SELECT,register_after_commit 写入,destroy_object evict);`VoxelDamageRouter.dispatch_damage` 跨 region RPC(本地 → 原路径,跨节点 → `:rpc.call(scene_node, ObjectRegistry, :accumulate_damage_remote, ...)` 200ms 超时 + observe);`ObjectRegistry.emit_object_state_delta` 0x6C 广播按 covered_chunks_by_region 分桶 owner-driven fan-out(本 region 走原 ChunkDirectory,远 region 走 `BeaconServer.Client.lookup` + cast);新增 metric / observe key | 单测 + 跨节点 RPC mock test 绿 | 1 天 |
| **A4-5** | `MultiRegionFixture` test helper(单 BEAM 双 named ChunkDirectory + 独立 :pg group + mock_route_voxel_chunk);跨 region prefab placement e2e(锚跨两 chunks 各属一 region,gate 0x67 → 双 region prepare/commit → storage 都被写 + scene_objects 在 owner region 注册);**跨 region damage cascade e2e**(玩家攻击非 owner region 的 chunk → owner ObjectRegistry 命中 → part_destroyed cascade → 两 region 客户端都收到 0x6C → debris/HUD flash 正常) | 两条 e2e 都绿 + 现有测试不破坏 | 1 天 |
| **A4-6** | Recovery watcher resume 路径 verify multi-participant `:prepared` 重发(应该自然支持,但 verify);如有 gap 修;新增 multi-participant resume 单测 | world_server recovery 测试 + multi-participant resume 单测全绿 | 0.3 天 |
| **A4-final** | 决策稿状态改"已完成";同步 `_session-handoff.md`(阶段表 + 跨 region damage 现已闭环不再列 backlog)+ scene_server voxel README + world_server voxel README | git status 干净 | 0.2 天 |

总估时:**3-4 天**。

## 验收标准

- 现有测试矩阵不破坏(scene 378 / gate 191 / world 72 1 预存 / data_service 71 / web 260 / cargo 39)
- 新增测试:
  - executor multi-participant 单测(A4-1):prepare 并行调用 2 个不同 chunk_directory,scene_opts_by_participant 正确分发
  - gate `build_prefab_plan` 多 region(A4-2):2 个 chunks 路由到不同 region → 2 个 participant entries
  - gate fail-fast(A4-2):任一 chunk 路由失败 → 整个 prefab reject 并 reason `:no_route_for_chunk`
  - register_scene_objects fan-out(A4-3):scene_objects 按 owner_region_id 分组,跨 region 时只 upsert 自 region
  - `ObjectOwnerLookup` 单测(A4-4):cache 命中/miss/evict;register_after_commit 写入;destroy 后 evict
  - `VoxelDamageRouter` 跨节点 RPC 单测(A4-4):本地路径 + 跨节点路径(mock `:rpc.call`)+ rpc 失败时 emit observe 不破坏主路径
  - `ObjectRegistry.emit_object_state_delta` per-region 分桶单测(A4-4):本 region chunks 走本地 ChunkDirectory,跨 region chunks 走远端 cast
  - 跨 region prefab placement e2e(A4-5):锚跨 chunk 边界 + 两 chunks 在不同 region → 整 prefab 落地,两 region 的 storage 都被写,scene_objects 在 owner region 注册
  - **跨 region damage cascade e2e(A4-5)**:跨 region prefab 落地后,玩家攻击**非 owner region** 的 chunk → owner ObjectRegistry 命中 accumulate_damage → part_destroyed cascade → 两 region 各自的客户端 ws 都收到 0x6C → debris simulation 接收
- 手动 demo:
  - 单 region prefab 流畅放(回归)
  - 跨 chunk 单 region prefab 流畅放(回归 A1 hotfix 路径)
  - 跨 region prefab(配置 multi-region scene fixture)流畅放,客户端线框预览和服务端落地一致
  - **跨 region prefab 破坏端到端**:拿 prefab 跨 region 边界放下 → 用技能打 owner 区外的 chunk → 客户端看到 debris 飞溅 + part_destroyed flash(不再因为跨 region 半成品丢失视效)

## 进度日志

- 2026-05-10:决策稿起草。等用户拍 D1-D6 后开始实施。
- 2026-05-10:用户指出"只做摆放、damage 跨 region 落空 = 半成品",同意把原 A4-bis 折回主范围。新增 D7(跨 region damage 路由 + 0x6C 广播 owner-driven fan-out),`voxel_scene_objects` 加 `owner_region_id` / `owner_lease_id` / `covered_chunks_by_region`,新模块 `SceneServer.Voxel.ObjectOwnerLookup`,`VoxelDamageRouter` 走 `:rpc.call`,`ObjectRegistry.emit_object_state_delta` 分桶 owner-driven fan-out。Step 列表加 A4-4(owner lookup + damage RPC + 广播分桶),A4-5 e2e 加跨 region cascade case。总估时 2-3 天 → 3-4 天。

## 已知 sub-backlog(本阶段不做)

- **`MultiRegionFixture` 跟 chunk_process_test 现有 per-instance 模式整合**(D4 风险 7):如果 A4-5 实施时发现可以复用 existing helper,去掉重复。
- **跨 region prepare 超时压测**:本阶段保持 `transaction_timeout_ms = 30000`。真实生产场景(地理跨 region,> 100ms RPC)需要观测 + 调参,留 Phase 6 HA 范围。
- **跨节点 damage RPC 重试 / 死信**:本阶段失败 fire-and-forget。生产环境网络抖动期间可能漏 damage / 漏 0x6C,object_version 单调让 client 状态最终收敛,但短窗口 UX 不一致。Phase 6 HA 范围。
- **`ObjectOwnerLookup` boot 期 SELECT 风暴预热**:风险 2 提到。本阶段实测 acceptable 就不做;如果冷启动期 95p latency 抖动明显,加异步 OnDemandPreload。
