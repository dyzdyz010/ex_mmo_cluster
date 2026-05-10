# Phase A4 — 跨 region prefab 多 participant 事务

**起草日期**:2026-05-10。**状态**:**主体已完成 2026-05-10**(commits 3f381d0 / 6acd37d / e6eafa3 / 630574b / 4198b8e + A4-6 / A4-final)。**A4-bis-cluster 子阶段决策稿就位,等启动**(见文末专段)。

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
- **多 scene_node 分布式部署本身**:A4-1~A4-6 主体仍假设生产单 scene_node(`world_sup` `BeaconServer.Client.await(:scene_server)` 拿单 node)。MVP 真上大世界要把 region 分散到多台 scene_node(一台 BEAM 扛不住所有 region 物理模拟),这部分**从 Phase 6 抽出**,作为 **A4-bis-cluster** 阶段(见文末专段),紧接 A4 主体后实施。A4-1~A4-4 留好的注入式接口(`:scene_node_resolver_fn` / `:region_routing_fn` / `scene_opts_by_participant`)就是为 A4-bis-cluster 串通而设计。
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
- **不**持久化 `covered_chunks_by_region`(决策稿草稿和早期 step A4-3 描述提过加这一列)。**修订原因**:chunk → region 是 World ledger 当前 lease 划分决定的**动态信息**,lease 漂移 / region 重分配会让该列变成过期数据(行级数据无法自检过期)。改为运行时 inflate + `ObjectOwnerLookup` 内存 cache(详见 D7.A 第 1 条):
  - register-after-commit 路径准确写入(由 `TransactionExecutor` 从 `transaction.participants.affected_chunks` 反向推算)
  - 冷启动 cache miss 走 SELECT 兜底,degenerate 为 `%{owner_key => obj.covered_chunks}`(所有 chunk 归 owner region);A4-bis-cluster 加 chunk → region resolver 后退役该兜底
- 读侧 D7 决定:damage 路由 / 0x6C 广播在跨 region 时通过 owner 元数据路由到正确 scene_node

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
   - API:`fetch_owner(scene_id, object_id) :: {:ok, %{owner_region_id, owner_lease_id, covered_chunks_by_region}} | {:error, :not_found}`
   - 冷启动从 `voxel_scene_objects` SELECT(只有 owner_region_id / owner_lease_id 持久化,`covered_chunks_by_region` 取 degenerate split `%{owner_key => obj.covered_chunks}`)
   - hot path 直读 ETS(`read_concurrency: true`);miss 走 GenServer.call 串行化避免重复 SELECT
   - `register_scene_objects_after_commit` 路径写入准确 covered_chunks_by_region(由 `TransactionExecutor` 从 `transaction.participants.affected_chunks` 反向推算并 inflate 到 obj 上);避免 commit 后 SELECT race
   - `ObjectRegistry.destroy_object` 后 evict
   - **scene_node 解析的现实修订**:决策稿草稿写"通过 `BeaconServer.Client.lookup({:voxel_region_scene_node, region_id, lease_id})` 解析(已有 region/lease → scene_node 映射,Phase 1c 起就用)"——**事实错误**,该映射不存在(Phase 1c 起的 `BeaconServer.Client` 仅 `lookup(:scene_server)` atom 单点查询,没有 per-region key)。**A4-4 阶段**:`VoxelDamageRouter` 通过 `:scene_node_resolver_fn` opt 注入 `(region_id, lease_id) → node()`,default `fn _, _ -> node() end`(生产单 scene_node 退化本地);`ObjectRegistry` 通过 `:region_routing_fn` opt 注入 `participant_key → chunk_directory_target`,default `nil` 即所有桶走本地 `state.chunk_directory`。**真正的 region → scene_node 映射在 A4-bis-cluster 阶段补**(见步骤分解后 A4-bis-cluster 段)

2. **`VoxelDamageRouter.try_apply_damage` 改造**:
   - `Storage.lookup_owner_at` → `(object_id, part_id)`
   - `ObjectOwnerLookup.fetch_owner` → `{owner_region_id, owner_lease_id}`
   - `:scene_node_resolver_fn` 解析 `(region_id, lease_id) → scene_node`(default `fn _, _ -> node() end`,A4-bis-cluster 改为 `&RegionRouting.resolve_scene_node/2`)
   - 本地(`scene_node == node()`)→ `GenServer.call(ObjectRegistry, ...)` 原路径
   - 跨节点 → `GenServer.call({ObjectRegistry, scene_node}, {:accumulate_damage, ...}, 200)` 透明跨节点 GenServer 协议(**非** :rpc.call —— 后者要新建 `accumulate_damage_remote/4` API,前者直接复用现有 GenServer 接口,语义等价。失败兜底改为 `try / catch :exit` 而非 match `{:badrpc, _}`)
   - 失败 emit `voxel_damage_cross_region_failed` observe + drop(不重试,不破坏 damage 主路径)
   - 新 observe:`voxel_damage_routed_cross_region`(成功)/ `voxel_damage_cross_region_failed`(rpc fail)

3. **0x6C 跨 region 广播**:**owner-driven fan-out**(对齐 owner 单点权威语义)
   - `ObjectRegistry.dispatch_object_state_delta`(在 owner scene_node 上;函数名 `dispatch_` 对齐代码现状,决策稿草稿写 `emit_` 是脑补)按 `covered_chunks_by_region`(从 `ObjectOwnerLookup` 拿)分组:每个 `(region_id, lease_id)` 桶通过 `:region_routing_fn` opt 解析到具体的 chunk_directory_target;default `nil` 即所有桶都走本地 `state.chunk_directory`(生产单 scene_node 退化为本地 fan-out)
   - **A4-4 阶段不接 BeaconServer 注册** `{:voxel_region_chunk_directory, region_id}`(BeaconServer.Client API 当前只接受 atom resource,扩展 term key 是基础设施改动,挤进 A4-4 范围爆炸);**真正的跨节点 fan-out 在 A4-bis-cluster 阶段补**(默认 `:region_routing_fn` 改为 `&RegionRouting.resolve_chunk_directory/1`,见步骤分解后 A4-bis-cluster 段)
   - 测试 / A4-5 fixture 通过 `:region_routing_fn` opt 注入,把 `{1, 100}` 路由到 `ChunkDirectory.RegionA`,`{2, 200}` 路由到 `ChunkDirectory.RegionB`,在单 BEAM 内验证分桶行为
   - `chunk_directory_target` 形态(本地 atom / `{Mod, scene_node}` 形式)由 routing fn 决定,后续 `ChunkDirectory.lookup_chunk_pid` 是 GenServer.call 天然支持跨节点;跨节点 cast / lookup 失败 catch :exit + emit `voxel_object_state_delta_cross_region_dropped` observe(fire-and-forget,object_version 单调保 client dedup,后续广播会让 client 状态收敛)
   - **affected_chunks 按 region 分组**:`covered_chunks_by_region` 由 `TransactionExecutor.register_scene_objects_after_commit` 从 `transaction.participants.affected_chunks` 反向推算并 inflate 到 obj 上,`BuildTransactionApplier.register_scene_objects` 写入 `ObjectOwnerLookup`;冷启动 cache miss 时退化为 `%{owner_key => obj.covered_chunks}`(degenerate split,所有 chunks 都归 owner region,A4-bis-cluster 加 chunk → region resolver 解决)

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
| **A4-3** | `voxel_scene_objects` schema + migration 加 `owner_region_id` / `owner_lease_id` 两列(**修订:不加** `covered_chunks_by_region` 列 — 该信息动态,改运行时 cache,见 D2 修订);`SceneObjectStore` 写入新字段;`BuildTransactionApplier.register_scene_objects/2` 按 owner_region_id 分组,只 upsert 自 region | data_service / scene_server 测试全绿 | 0.5 天 |
| **A4-4** | `SceneServer.Voxel.ObjectOwnerLookup` per-scene ETS cache(冷启动 SELECT degenerate split,register_after_commit 写入准确 split,destroy_object evict);**挂入 `VoxelSup` 生产监督树,顺带补挂 Phase 4 起一直未挂的 `ObjectRegistry`**;`VoxelDamageRouter.try_apply_damage` 跨 region 路由(本地 → 原路径,跨节点 → `GenServer.call({Mod, scene_node}, ..., 200)` 透明跨节点 GenServer 协议 + catch :exit + observe);`ObjectRegistry.dispatch_object_state_delta` 0x6C 广播按 `covered_chunks_by_region` 分桶 owner-driven fan-out,通过 `:region_routing_fn` opt 路由(default 单 scene_node 退化本地);新增 observe key:`voxel_damage_routed_cross_region` / `voxel_damage_cross_region_failed` / `voxel_scene_object_owner_lookup_register_failed` | 单测 + 跨节点路由 mock test 绿 | 1 天 |
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
  - `ObjectOwnerLookup` 单测(A4-4):cache 命中/miss/evict;register_after_commit 写入;destroy 后 evict;cold-start degenerate split
  - `VoxelDamageRouter` 跨节点路由单测(A4-4):本地路径 + 跨节点路径(mock `:scene_node_resolver_fn` 返回不可达 node;`GenServer.call({Mod, node})` :exit 兜底)+ owner cache miss legacy fallback + rpc 失败时 emit observe 不破坏主路径
  - `ObjectRegistry.dispatch_object_state_delta` per-region 分桶单测(A4-4):mock `:region_routing_fn` 把 `(1,100)` / `(2,200)` 路由到不同 fake ChunkDirectory,验证 chunks 按桶分发;cache miss fallback 到本地 chunk_directory
  - `BuildTransactionApplier.register_scene_objects` 单测(A4-4):upsert + 写 ObjectOwnerLookup;upsert 失败 skip lookup;`covered_chunks_by_region` 缺省默认空 map
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
- 2026-05-10:A4-1 / A4-2 / A4-3 已落地(commits 3f381d0 / 6acd37d / e6eafa3)。
- 2026-05-10:**A4-4 落地**。`SceneServer.Voxel.ObjectOwnerLookup`(ETS 读路径直读、写路径 GenServer.call 串行)挂入 `VoxelSup`(同时把 Phase 4 起一直未挂的 `ObjectRegistry` 也补挂);`VoxelDamageRouter.try_apply_damage` 拿到 `(object_id, part_id)` 后 `fetch_owner` → `:scene_node_resolver_fn` 解 owner scene_node → 透明 `GenServer.call({Mod, scene_node}, ..., 200ms)`;失败 emit `voxel_damage_cross_region_failed` + 路由成功 emit `voxel_damage_routed_cross_region`;`ObjectRegistry.dispatch_object_state_delta` 改为按 `covered_chunks_by_region` 分桶,每桶按 `:region_routing_fn` 路由到对应 chunk_directory(本地仍走原 `state.chunk_directory`,fallback `:__local__` 兜底);`run_destroy_object` 加 evict cache;`covered_chunks_by_region_for` / `safe_evict_owner_lookup` 在 owner_lookup 未启动时 catch :exit 退回 legacy fallback,确保现有 broadcast_test 不破坏。`BuildTransactionApplier.register_scene_objects` 同时调 `ObjectOwnerLookup.register`。World 端 `TransactionExecutor.register_scene_objects_after_commit` 给每个 obj inflate `:covered_chunks_by_region`(从 `transaction.participants.affected_chunks` 反向 map 推算)。新增观测点 `voxel_damage_routed_cross_region` / `voxel_damage_cross_region_failed` / `voxel_scene_object_owner_lookup_register_failed`。**注**:决策稿 step A4-3 表里写"covered_chunks_by_region 列",实际未加 PG 列(动态信息,取决于 World 当前 region 划分);改为运行时 inflate + cache。新增 4 套单测合计 19 tests 全绿(`object_owner_lookup_test` 9 / `object_registry_cross_region_test` 3 / `voxel_damage_router_cross_region_test` 4 / `build_transaction_applier_owner_lookup_test` 3),world_server `transaction_executor_test` 加 1 条 inflate 断言后 16/16 全绿;scene_server 全套 baseline 87 fail → 82 fail(只增不减,且未引入 regression)。
- 2026-05-10:**A4-4 偏移同步回正文**。在 D2 / D7.A 第 1-3 条 / 步骤分解表 A4-3 / A4-4 / 验收标准段全部修订原方案描述,标注:`covered_chunks_by_region` 不进 PG;`:rpc.call` 改透明 `GenServer.call({Mod, node})`,不新增 `accumulate_damage_remote`;BeaconServer per-region key 不接,改 `:region_routing_fn` opt 注入。决策稿草稿引用的"已有 region/lease → scene_node 映射(Phase 1c 起就用)"**事实错误**,该映射不存在。**新增 A4-bis-cluster 阶段段**(原属 Phase 6 HA 范围,用户明确"MVP 大世界一台机扛不住"决策提前):BeaconServer term key 扩展 + RegionRouting 模块 + lease 按 scene_node 分配 + ObjectOwnerLookup / VoxelDamageRouter / ObjectRegistry default 走 RegionRouting + 双 BEAM 节点 e2e。"不在范围"段同步标注"多 scene_node 部署"从 Phase 6 抽出归 A4-bis-cluster。
- 2026-05-10:**A4-5 落地**。新增 `apps/gate_server/test/gate_server/ws_connection_voxel_cross_region_test.exs`(2 tests)。`ws_connection.ex` / `tcp_connection.ex` `executor_execute` 加 `:voxel_chunk_directory_resolver` env hook(default `nil` 走原 `SceneServer.Voxel.ChunkDirectory`,test 注入 fn 让 participant 路由到不同 named instance),A4-bis-cluster 落地后改为走 `RegionRouting.resolve_chunk_directory/1`。Fixture 在测试文件内 inline:启 named `ChunkDirectory.RegionA` / `RegionB` + 各自 `VoxelChunkSup`,MapLedger 配两个不重叠 region(`bounds_chunk_max` 是 **exclusive** 上界,踩坑后修正:region_a [0,1)x[0,1)x[0,1)、region_b [1,2)x[0,1)x[0,1)),ObjectRegistry / ObjectOwnerLookup 仍 default 单 instance(对齐 D10.B),`:region_routing_fn` 注入解析 `(region_id, lease_id) → ChunkDirectory.Region*`。两条 e2e 测试:1) 跨 region prefab placement(sphere anchor `{124, 8, 8}` 跨 chunk x 边界 → 两 region 各自 ChunkDirectory 收到 prepare/commit,两 chunks storage 都被持久化,`lookup_chunk_pid` 反向验证 chunk_pid 路由正确);2) 跨 region damage cascade(prefab 落地后调 `VoxelDamageRouter.try_apply_damage`,因 sphere 不分配 scene_object → 返回 `:no_voxel`,验证跨 region 路径不 crash;真正的 part_destroyed cascade e2e 等 prefab v3 接通 scene_object 分配后再加)。gate_server 全套 baseline 191 → 193 tests,3 fail → 3 fail(无 regression)。**注**:A4-5 决策稿目标包括"跨 region damage cascade e2e 玩家攻击非 owner region 的 chunk → owner ObjectRegistry 命中 accumulate_damage → part_destroyed cascade",实际因当前 prefab dispatch 路径不为 sphere 分配 scene_object,cascade 触发条件不满足,e2e 退化为"跨 region damage 路径不 crash"。完整 cascade e2e 需要 prefab v3(BlueprintCatalog 蓝图带 part_states + scene_object allocation)落地后才能写,留 backlog。
- 2026-05-10:**A4-6 落地**。`TransactionRecoveryWatcher` resume 路径在 multi-participant transaction 上**自然支持**(因 `BuildTransaction.intents_by_participant` 已经在 Phase 3-bis-3 持久化,`scene_opts_resolver` Phase A4-1 改为 1-arity 接 `participants` list,自然 cover N 个 participant)。新加一条明确标 "A4-6 verify" 的单测(`transaction_recovery_watcher_test.exs:255+`)断言:multi-participant resume 时每个 participant 的 commit 都被独立调到、各自用对应 scene_opts(recorder_a / recorder_b 区分)、resume 跳过 prepare phase、transaction 落 :committed。顺手清 `run_resume/3` 内 `{:error, reason}` dead code(`TransactionExecutor.execute/4` 从不返回 `{:error, _}`,dialyzer 警告消失)。world_server 全套 baseline 78 → 79 tests(+1),1 fail → 1 fail(无 regression,fail 是已知 Windows path 测试)。
- 2026-05-10:**A4-final 落地**。决策稿状态改"主体已完成";同步 `_session-handoff.md`(阶段表 + 跨会话警告中"跨 region 多 participant 事务未实现"现已闭环);scene_server voxel README + world_server voxel README 同步 ObjectOwnerLookup / `:region_routing_fn` / VoxelDamageRouter 跨节点路径。**Phase A4 主体完成**,A4-bis-cluster(真多 scene_node 部署)子阶段决策稿就位,等用户启动。

## 已知 sub-backlog(本阶段不做)

- **`MultiRegionFixture` 跟 chunk_process_test 现有 per-instance 模式整合**(D4 风险 7):如果 A4-5 实施时发现可以复用 existing helper,去掉重复。
- **跨 region prepare 超时压测**:本阶段保持 `transaction_timeout_ms = 30000`。真实生产场景(地理跨 region,> 100ms RPC)需要观测 + 调参,留 Phase 6 HA 范围。
- **跨节点 damage RPC 重试 / 死信**:本阶段失败 fire-and-forget。生产环境网络抖动期间可能漏 damage / 漏 0x6C,object_version 单调让 client 状态最终收敛,但短窗口 UX 不一致。Phase 6 HA 范围。
- **`ObjectOwnerLookup` boot 期 SELECT 风暴预热**:风险 2 提到。本阶段实测 acceptable 就不做;如果冷启动期 95p latency 抖动明显,加异步 OnDemandPreload。

---

## A4-bis-cluster — 真正的多 scene_node 分布式部署

> 起草日期:2026-05-10。**状态**:决策稿已拍板(D8.B / D9 全量升级 / D10.B / D11 推荐采纳),等 A4-5 / A4-6 / A4-final 落地后开始实施;紧接 A4-final 之后,A5 之前。

### 触发原因

A4-1~A4-6 主体留下的"跨节点路径"事实上只能在测试 mock 里命中——生产路径下所有 region 都跑在同一 BEAM(World 端 `BeaconServer.Client.await(:scene_server)` 拿单一 node;`world_sup.ex:49-53` 用单一 scene_node 构造 `scene_opts_by_participant`)。

MVP 阶段单台机器能撑当前规模,但**真正大世界**(玩家数 / 物体数 / chunk 数 ↑)BEAM 物理模拟 + chunk 状态会扛不住单进程。必须把 region 分散到多台 scene_node 上跑。**用户决策(2026-05-10)**:从 Phase 6 HA 范围把"多 scene_node 部署"提前到 A4-bis-cluster,紧跟 A4 主体后实施。

A4-1~A4-4 已经把"跨节点路径"用注入式接口串好(`:scene_node_resolver_fn` / `:region_routing_fn` / `scene_opts_by_participant: %{...participant => [chunk_directory: {Mod, scene_node}]}`),A4-bis-cluster 把这些接口连到真实的 region → scene_node 路由设施。

### 阶段目标

1. **region 分配**:World coordinator 按某种策略(D8)决定 region 落哪台 scene_node,持久化到 lease 字段
2. **服务发现**:每台 scene_node 启动时按本节点持有的 region 注册 BeaconServer 的 `{:voxel_region_scene_node, region_id}` key(D9 扩展 BeaconServer.Client term key)
3. **路由设施**:新模块 `SceneServer.Voxel.RegionRouting` 封装 register / unregister / resolve_scene_node / resolve_chunk_directory,作为 ObjectOwnerLookup / VoxelDamageRouter / ObjectRegistry 的 default resolver
4. **transaction 跨节点**:World 端 `world_sup` / `WorldServer.Worker.Interface` 改造,按 transaction.participants 分别拿对应 scene_node 构造 `scene_opts_by_participant`(替代当前固定单 node)
5. **冷启动准确性**:`MapLedger.region_for_chunk/2` API + `ObjectOwnerLookup` cold-start 走该 resolver,decommission degenerate split fallback(D11)
6. **e2e 验证**:双 BEAM `:peer` 节点测跨节点 prefab placement / damage cascade / 0x6C fan-out

### 不在范围

- **per-region coordinator / coordinator HA**:仍单全局 coordinator(World 端单点);Phase 6 HA 留
- **scene_node crash 后的 region failover**:本阶段只支持启动期分配 + lease 内 boundary migration,不支持 runtime 跨节点 lease 转手;真 failover 留 Phase 6
- **跨 scene_node chunk migration**(boundary migration 跨节点转手):lease 仍 per-scene_node 持有,boundary 在同节点 region 间走 A2 现有路径;跨节点转手留 Phase 5+
- **跨节点 damage RPC 重试 / 死信**:仍 fire-and-forget(已在 A4 backlog,本阶段不解决)
- **动态再平衡**:基于 metric 的 region 重分配留 Phase 6;A4-bis-cluster 只做启动期分配 + 静态 / 简策略(D8)
- **客户端节点感知**:client wire 不暴露 scene_node 信息,继续用 logical_scene_id + region_id 寻址

### 决策项(已拍板 2026-05-10)

#### D8. region → scene_node 分配策略 — 采纳 **D8.B**

被否方案:

  - **D8.A**:静态 hash(region_id mod scene_node_count)。**否** —— 加节点要重映射全部 region,MVP 不接受运维痛点
  - **D8.C**:基于 metric 的动态均衡(节点 CPU / 内存 / chunk 数)。**否(本阶段)** —— 留 Phase 6 HA

采纳:

  - **D8.B**:World coordinator 启动时按 scene_node join 顺序,把 region 列表均分给已 join 的 scene_node。新加 scene_node 时只接 backlog region(已有 region 不动,避免 runtime 转手)。简单、顺序敏感但 MVP 可接受。

实施细节:

  - `WorldServer.Voxel.SceneNodeRegistry` 新模块持有 `scene_node_join_order :: [node()]` + `region_assignments :: %{region_id => node()}`
  - scene_node join(BeaconServer 监听 `:scene_server` 注册事件)→ append 到 join_order;尚未分配的 region 按 round-robin 分给所有已 join 节点
  - scene_node leave(节点 down)→ MVP 不做 reassignment(失联 region 进入 unavailable 状态,World 拒绝相关 lease;真 failover 留 Phase 6)

#### D9. BeaconServer 全量升级支持 term key — 采纳 **彻底升级,不留兼容**

`BeaconServer.Client.register/1` / `lookup/1` / `await/2` 当前签名只接 atom resource。要支持 `{:voxel_region_scene_node, region_id}` 这种 term tuple key。

**用户决策(2026-05-10)**:遵循"全新未上线系统不留兼容"纪律,**直接把 resource 参数升级为 `term()`,所有现有 atom caller 一并迁移到新签名**。没有 `register_term/2` 双 API,没有 atom / term polymorphic,没有 deprecated 别名。

修改面:

  - `BeaconServer.Client.register/1` / `lookup/1` / `await/2` 签名:`atom()` → `term()`(实际是 `atom() | tuple()`)
  - Horde.Registry 调用层:验证 term key 在 Horde 中的注册行为(可能需要 `:erlang.phash2/1` 哈希分布)
  - 所有现有 caller 迁移:`apps/*/lib/.../interface.ex` 中的 `register/1` / `await/1`(`:scene_server` / `:data_contact` / `:data_service` / `:beacon_server` 等所有 resource)
  - 全套 `BeaconServer.Client` 测试覆盖 atom 和 term 两条路径

被否方案:

  - **D9.A**(双 API):`register_term/2` + atom `register/1` 共存。**否** —— 双路径维护成本 > 收益,违反全新未上线纪律
  - **D9.B**(polymorphic):`register/1` 接受 atom OR tuple。**否** —— 等价于 D9 采纳但语义模糊(签名 `term()` 比 `atom() | tuple()` 更清晰)

#### D10. Scene 端 ObjectRegistry / ChunkDirectory 的 instance 形态 — 采纳 **D10.B**

被否方案:

  - **D10.A**:per-region named instance(每个 scene_node 上每个 region 启动独立 `ChunkDirectory.Region<id>` / `ObjectRegistry.Region<id>`)。**否** —— supervision 树膨胀(N region 启 2N 进程),且 cross-region API call 要靠名字寻址 instance,跟 A4-4 现有 `:region_routing_fn` 注入式接口语义不连续

采纳:

  - **D10.B**:单 instance 内部按 region 分桶(scene_node 上一个 ChunkDirectory + 一个 ObjectRegistry,内部 state 按 region_id 分组)

实施细节:

  - 同一 BEAM 内不同 region → `:region_routing_fn` 解析为 local atom(直接调本地 instance)
  - 跨节点 region → 解析为 `{Mod, scene_node}` tuple(GenServer.call / cast 天然跨节点)
  - chunk_pid 仍 per-chunk 独立进程,通过 chunk_coord 在对应 ChunkDirectory 内 lookup
  - ChunkDirectory state 不需要硬性按 region 分桶(chunk_coord lookup 已经唯一);但 ObjectOwnerLookup / RegionRuntime 内部按 region 分桶维护 lease / cache 状态

#### D11. chunk → region resolver — 采纳 **加 `MapLedger.region_for_chunk/2` API + 反向索引**

冷启动 cache miss 时 `ObjectOwnerLookup.fetch_owner` 当前退化为 `%{owner_key => obj.covered_chunks}`(所有 chunks 归 owner region)。A4-bis-cluster 加 chunk → region resolver:

  - 新 API `MapLedger.region_for_chunk(scene_id, chunk_coord) :: {:ok, region_id} | {:error, :not_in_any_region}`
  - World 端 ledger 维护 `chunk_coord → region_id` 反向索引,在 lease apply / release / migration 路径增量维护(具体怎么挂在 `MapLedger` state 里实施时定)
  - `ObjectOwnerLookup` cold-start 改为按 covered_chunks 逐个 resolve,组装准确的 covered_chunks_by_region 并写入 cache

### 风险

1. **Horde.Registry term key 注册行为**:term key 在 Horde 中的负载均衡 / 冲突解决跟 atom 一样吗?需要验证(可能 Horde 用 atom 哈希分布到 ring 上,term tuple 走 `:erlang.phash2`)
2. **lease 漂移期间 ObjectOwnerLookup cache 过期**:某 region 从 scene_node A 转到 scene_node B 时,A 上的 ObjectOwnerLookup cache 中 owner 元数据仍指向 A 的 chunk_directory_target。A4-bis-cluster 需要在 RegionRuntime.lease release 时广播 evict 通知,或者每个 fetch_owner 校验 lease_id epoch
3. **RPC 跨节点延迟对 transaction_timeout 挤压**:A2 backlog 已记。本阶段 verify 在 LAN 内(< 1ms RPC)`transaction_timeout_ms = 30000` 足够;真上 WAN 跨地理区域需要调参
4. **双 BEAM e2e 启动慢**:`:peer.start` 启第二节点要 ~2-5 秒,CI 会变慢。考虑只在专用 e2e job 跑,unit test 不引入
5. **`world_sup` 重构面比预期大**:当前 `world_sup` 单一 `BeaconServer.Client.await(:scene_server)` 拿 node 然后构造 scene_opts。改为 per-region 拿 node 意味着 `world_sup` 持有 region → scene_node map,且 lease 变化时要 update。可能需要 World 端单独一个 GenServer 维护此 map(`WorldServer.Voxel.SceneNodeRegistry`?)
6. **现有 single-region 路径回归**:A4-bis-cluster 改 default opts 后,所有 single-region 测试都要走新路径。需要确保 `RegionRouting.resolve_scene_node` 在单 BEAM 下退化为 `node()` 行为不变

### 步骤分解

| Step | 范围 | 估时 |
|---|---|---|
| **A4-bis-1** | `BeaconServer.Client` 签名升级为 `term()`(D9 全量升级):`register/1` / `lookup/1` / `await/2` 参数从 atom 升级到 term;**所有现有 caller 一并迁移**(`scene_server` / `data_contact` / `data_service` / `beacon_server` 等 `interface.ex` + `world_sup`);atom 路径不留 deprecated 别名;BeaconServer.Client 全套测试覆盖 atom 和 term 两条路径 | 0.5-1 天 |
| **A4-bis-2** | `SceneServer.Voxel.RegionRouting` 新模块:`register_local_region/2` / `unregister_local_region/1` / `resolve_scene_node/1` / `resolve_chunk_directory/1`;test 用 :persistent_term / Process dictionary 注入 stub | 0.5 天 |
| **A4-bis-3** | `RegionRuntime.apply_lease` 接 `RegionRouting.register_local_region`;lease 释放(migration / expiry)接 unregister;e2e:lease apply → BeaconServer 可见 | 0.5 天 |
| **A4-bis-4** | World 端 `MapLedger` 加 region → scene_node 分配策略(D8);新增 `WorldServer.Voxel.SceneNodeRegistry`(World 端 region → scene_node map);`world_sup` / Worker.Interface 路径改造为按 transaction.participants 解析对应 scene_node 构造 `scene_opts_by_participant`;`MapLedger.region_for_chunk/2` API(D11) | 1-1.5 天 |
| **A4-bis-5** | `ObjectOwnerLookup` / `VoxelDamageRouter` / `ObjectRegistry` default opts 改为走 `RegionRouting`(`:scene_node_resolver_fn` default = `&RegionRouting.resolve_scene_node/2`,`:region_routing_fn` default = `&RegionRouting.resolve_chunk_directory/1`);`ObjectOwnerLookup` cold-start 走 `MapLedger.region_for_chunk` 解析 covered_chunks_by_region | 0.5 天 |
| **A4-bis-6** | 双 BEAM `:peer` 节点 e2e:节点 A 持 region 1、节点 B 持 region 2;World 端跨节点 transaction prepare/commit;玩家在节点 A 攻击 region 2 chunk → owner ObjectRegistry(节点 B)收到 damage → cascade 0x6C 跨节点 fan-out 到节点 A 客户端 | 1-1.5 天 |
| **A4-bis-final** | 决策稿 / `_session-handoff.md` 同步;移除 Phase 6 backlog 中已被 A4-bis-cluster 吸收的项;手动 demo 双 BEAM 跑同 logical_scene 跨 region prefab 摆放 / 破坏 | 0.2 天 |

总估时:**4-5.5 天**(D9 全量升级比加新 API 多 0.5 天迁移所有 caller)。

### 验收标准

- A4-1~A4-6 现有测试矩阵不破坏(scene 397+ / gate 191 / world 77+ / data_service 75 / web 260+ / cargo 39)
- 新增测试:
  - `BeaconServer.Client` term key 单测(register / lookup / unregister)
  - `RegionRouting` 单测(register / unregister / resolve / 不存在的 region 返回 :error)
  - `MapLedger.region_for_chunk` 单测(覆盖在 lease 中的 chunk + 不在任何 lease 中的 chunk)
  - `ObjectOwnerLookup` cold-start 走 region resolver 的单测(replace degenerate split)
  - 双 BEAM e2e:跨节点 prefab placement + 跨节点 damage cascade + 跨节点 0x6C fan-out
- 手动 demo:
  - 双 BEAM 节点跑同 logical_scene,客户端跨 region prefab 摆放 / 破坏跟单节点路径行为一致(不应感知节点切换)
  - kill 一个 scene_node 后 World 端能否继续运转(本阶段允许 lease degraded,真 failover 留 Phase 6)

### 触发条件

A4-4 / A4-5 / A4-6 落地后(单 BEAM 内验证跨 region 路径正确)→ A4-bis-cluster 启动。**MVP 真上多机器之前必须落地**(用户决策 2026-05-10)。

### 进度日志

- 2026-05-10:决策稿起草。从 Phase 6 HA 范围抽出"多 scene_node 部署",决策来源:用户指出"MVP 大世界一台机扛不住"。
- 2026-05-10:**D8-D11 拍板**。D8 采纳 D8.B(scene_node join 顺序均分,新加节点只接 backlog region);**D9 升级方案改为彻底升级,不留兼容**(用户决策:"全新系统不留兼容,要升级就彻底升级"——`BeaconServer.Client.register/1` / `lookup/1` / `await/2` 签名升级为 `term()`,所有现有 atom caller 一并迁移,无 `register_term/2` 双 API、无 polymorphic、无 deprecated 别名;估时 +0.5 天 cover 所有 caller 迁移);D10 采纳 D10.B(单 instance 内部按 region 分桶);D11 采纳新 API `MapLedger.region_for_chunk/2` + 反向索引。总估时 3.5-5 天 → 4-5.5 天。等 A4-5 / A4-6 / A4-final 落地后开始实施。
- 2026-05-10:**A4-bis-1 落地**。`BeaconServer.Client.register/1` / `lookup/1` / `await/2` 签名从 `atom()` 升到新 `@type resource_key :: term()`;module doc 加 "Resource keys" 段说明 atom(singleton)vs tuple(`{:voxel_region_scene_node, region_id}` / `{:voxel_region_chunk_directory, region_id}` parameterized resource)两种形态。Logger 三处 `#{resource}` → `#{inspect(resource)}`(否则 tuple key 会触发 `Protocol.UndefinedError`)。所有现有 atom caller(`scene_server` / `data_contact` / `data_service` / `agent_server` / `agent_manager` / `auth_server` / `world_server` / `gate_server` / `data_store` 的 `interface.ex` + `world_sup.ex` + `transaction_recovery_watcher.ex` + `gate_server` ws/tcp connection)**无需代码改动**(atom ⊆ term,Horde.Registry 本来就接受任意 term;广义化 spec 不收窄行为)。`unregister/1` 不在 A4-bis-1 范围,留到 A4-bis-3 RegionRouting 真有 caller 时再加(YAGNI)。新增 5 个 term key 单测(`client_test.exs`):tuple key round-trip、atom/tuple 同形 namespace 隔离、未注册 tuple 返 `:error`、tuple key 重复注册幂等、tuple key `await` :timeout。回归矩阵全绿:beacon 1 doctest + 15 tests / scene 397 / world 79(1 known Windows path 预存)/ data_service 75 / gate 193(1 fail 是 `ws_connection_voxel_cross_region_test` setup 的 MapLedger fixture 隔离 bug,跟本次改动无关 — 该 test fixture 用 named singleton MapLedger 跨 2 个 test 注册同 bounds region 触发 `:region_bounds_overlap`,A4-5 progress log 标的"3 fail → 3 fail"应该没及时跟,留 backlog)/ agent_manager / agent_server / data_store / data_contact 各 1 doctest + 1 test。**未 push**。
- 2026-05-10:**A4-bis-2 落地**。新模块 `SceneServer.Voxel.RegionRouting`(`apps/scene_server/lib/scene_server/voxel/region_routing.ex`)封装 `BeaconServer.Client` 的 `{:voxel_region_scene_node, region_id}` term key 注册 + 查询,API:`register_local_region/2`(scene 端 lease apply 时调用,production 走 `BeaconServer.Client.register`)/ `unregister_local_region/1`(lease release / migration,production 走 `BeaconServer.Client.unregister`)/ `resolve_scene_node/2`(`(region_id, lease_id) -> {:ok, node} | :error`,canonical 风格)/ `resolve_chunk_directory/1`(`{region_id, lease_id} -> ChunkDirectory module atom | {ChunkDirectory, scene_node} | nil`,本地走 atom 路径,跨节点走透明 GenServer 协议;nil 时 caller 自决退化策略)。**lease_id 在 production 路径 ignore**(BeaconServer key 不带 lease_id),保留在签名里给 future epoch-aware routing(lease 漂移期间区分 stale/current)使用。test 路径走 `:persistent_term` 注入 stub:`__install_stub__/1` 接 `%{region_id => node()}` snapshot,`__clear_stub__/0` reset(`on_exit` 调用),stub mode 下 register/unregister no-op,resolve 读 stub。**A4-bis-1 砍掉的 `BeaconServer.Client.unregister/1` 在本步补回**(因为 RegionRouting.unregister_local_region 是真 caller,Horde.Registry 文档语义"按 caller pid 匹配,只能反注册当前进程持有的 entry"在 docstring 里标清);新加 2 个 unregister 单测覆盖。**RegionRouting 的 wiring(default opts in ObjectOwnerLookup / VoxelDamageRouter / ObjectRegistry)留 A4-bis-5**;**RegionRuntime.apply_lease 接 register_local_region 留 A4-bis-3**。新增测试:beacon `unregister/1` round-trip + no-prior-registration no-op (2 tests);scene `region_routing_test` (10 tests):production 路径 5 个(register hit、idempotent、unresolved :error、cross-process unregister、resolve_chunk_directory local atom + unknown nil)+ stub 路径 5 个(stub 覆盖 production、stub mode no-op、resolve_chunk_directory local/remote/miss 三型、`__clear_stub__` 退回 production)。回归:beacon 1 doctest + 17 tests / scene 1 doctest + 407 tests(+10 from RegionRouting),0 fail(其他 app 无需跑因 RegionRouting 还没接 caller、BeaconServer.Client.unregister 也只有 RegionRouting 调用)。**未 push**。
