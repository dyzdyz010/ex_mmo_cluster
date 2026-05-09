# Phase A4 — 跨 region prefab 多 participant 事务

**起草日期**:2026-05-10。**状态**:决策稿(等用户确认 D1-D6 后开始实施)。

A2 + A1 + A1-1b 修完后用户问"跨 region 摆放能实现吗?backlog 里是不是有前置依赖?"。结论:**没有真前置阻塞**。下层组件(`TransactionCoordinator` / `TransactionExecutor` / `BuildTransactionApplier`)都已是 multi-participant ready,只是 `gate_server` 的 `0x67` dispatch 切片故意写死成 single-participant(原 Phase 3 D6 决定)。本阶段把它打通。

A3(多客户端联调)和本阶段独立,顺序无强约束。

## 阶段目标

- **能力**:`0x67 PrefabPlaceIntent` 在 prefab 跨多个 region/lease 时也能成功落地,而不是在 Scene `BuildTransactionApplier.prepare` 里因为 lease mismatch 整体 reject。
- **2PC 完整性**:任意 participant prepare 失败 → 全部 abort,不留半提交;任意 participant commit 失败 → 已 commit 的 chunks 不变(2PC 不能回滚已 commit,但可以观测/告警),Phase 3-bis recovery watcher 接管 `:prepared` 状态。
- **诱因**:Phase A1 hotfix 让 mid-macro 锚有可能让 prefab 自然跨 chunk;chunk 边界恰好是 region 边界时,会触发 cross-region 路径。本阶段把这条路径变可用而不是 reject。

## 不在范围

- **per-region coordinator / coordinator HA**:仍然是单全局 coordinator,Phase 6 留。
- **超大 prefab(覆盖多于 ~4 chunks)**:本阶段不做 prefab geometry 生成层面限制。如果 v3 prefab 真的能跨 8+ chunks,网络扇出风险大,触发 e2e 测试再加 cap。
- **wire 协议升级**:不动。`0x67` 输入不变,`0x68 VoxelIntentResult` reason 沿用现有 atom 风格。
- **prefab v3 多 macro mask**:`BlueprintCatalog` 仍单 macro mask(8³ slots),mid-macro 锚仍最多扩到 8 macros / 4 chunks(2³)。
- **客户端跨 region 预览提示**:线框预览不知道(也不需要知道)是否跨 region;只在服务端 reject 时 HUD flash 提示用户(D3 决定)。
- **Recovery watcher resume 路径完善 multi-participant**:本阶段如果 recovery watcher 已经能正确处理 multi-participant `:prepared` 重发(Phase 3-bis-5 的 resume 逻辑应该自然支持,因为 `intents_by_participant` 已经在 BuildTransaction 持久化),只 verify;如果有 gap,**留 backlog**,本阶段不修。
- **跨 region object provenance / damage cascade**:Phase 4 的 ObjectRegistry 已支持 cross-chunk cascade(4-bis 0x6C broadcast 通过 ChunkDirectory fan-out),本阶段不动 cascade 算法,只确保 owner 选取规则不破坏 cascade 触达。

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

### D2. scene_objects fan-out 策略(单 owner)

**现状**:Phase 4 起 prefab transaction 可能在 `BuildTransaction.scene_objects` 中携带新建的 scene_objects(给 prefab 实例分配 object_id);commit 后 `register_scene_objects_after_commit/3` 把它们 upsert 到 scene-side `ObjectRegistry`。当前**单 scene_node** 路径只在那一个 node 上 register。

跨 region 时,一个 scene_object 的 `covered_chunks` 可能跨多个 region。问题:每个 region 都有自己的 `ObjectRegistry`(scene-local),要不要每个都 register?

**推荐方案**(D2.A):**单 owner participant**。

- 每个 scene_object 选**第一个 covered chunk(按 `chunk_coord` ascending 排序)所在的 region** 作为 owner participant
- 只在 owner participant 的 scene_node 上的 `ObjectRegistry` register
- 读侧:damage 路由(`Storage.lookup_owner_at` → `ObjectRegistry.accumulate_damage`)走该 chunk 所在 scene_node 的 `ObjectRegistry`。如果 damage 命中的 chunk 不在 object owner 的 region,需要跨 region lookup(详见 sub-decision)
- 0x6C cascade broadcast 仍走 `ChunkProcess.push_object_state_delta_payload` per-chunk fan-out,**不依赖 ObjectRegistry 物理位置**(Phase 4-bis-4 的 broadcast 路径走 ChunkDirectory.lookup_chunk_pid),所以 cross-chunk cascade 已支持

**被否方案**:
- D2.B fan-out register 到所有 covered participants(双副本)。**否**:destroy_object 时多副本一致性难(一个 region destroy 了怎么 propagate),容错复杂度大于收益。
- D2.C ObjectRegistry 改成 World-side 全局。**否**:架构大改,本阶段范围爆炸。

**Sub-decision D2.1**:跨 region damage 路由?

`SceneServer.Combat.VoxelDamageRouter.dispatch_damage` 当前单 scene_node 内 lookup_owner_at + ObjectRegistry。跨 region 时:
- 客户端 attack target_position 落在 chunk C(in region B);chunk C 的 micro layer owner_object_id 指向 object O
- O 的 owner participant 是 region A(因为 O 的第一个 covered chunk 在 region A)
- damage 要发到 region A 的 `ObjectRegistry`

**推荐**:
- `VoxelDamageRouter` 通过 `Storage.lookup_owner_at` 拿到 `object_id` 后,**通过 `BeaconServer.Client.lookup` 找 object 所在 region 的 `ObjectRegistry`**(怎么找:object_id → owner_region 的映射要么持久化在 `voxel_scene_objects` 表里,要么通过 broadcast 探测)
- **简化**:在 `voxel_scene_objects` 表新加 `owner_region_id` + `owner_lease_id` 字段(持久化 owner participant);damage 路由先 SELECT 一行拿 owner,再 RPC 到 owner 的 scene_node `ObjectRegistry`
- **本阶段最小动作**:只做 register 部分(D2.A),damage 跨 region lookup **留 sub-backlog A4-bis**(不跨 region 的 prefab 不受影响;跨 region 的 prefab damage 路径暂时只在 owner region 内的 chunks 工作,owner 区外的 chunks 上 damage 落空 — 用户实测 demo 几乎不会遇到)

**接受的代价**:跨 region prefab 的非-owner chunks 上 damage 暂时落空(目标 cells 仍会被 break,只是不触发 part_destroyed cascade)。这是已知 trade-off,记 handoff backlog。

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
- `voxel_scene_objects` 表加两列 `owner_region_id` + `owner_lease_id`(为 D2.1 的 damage 跨 region lookup 后续做铺垫,本阶段写入但不查询)。

**推荐:采纳 D6.A**。

## 风险

1. **`BuildTransaction` 持久化字段又演进**:加 `owner_region_id` / `owner_lease_id` 到 `voxel_scene_objects`,但 `BuildTransaction.scene_objects` 字段(in-memory)语义没变。`cc3a31d` 的 stale-snapshot catchall 仍然只兜底 transaction 主体的 plain-map shape;`scene_objects` 列表如果旧 blob 反序列化出 plain map,`register_scene_objects` 会 raise。**缓解**:在 `BuildTransactionApplier.register_scene_objects/2` 入口加 `is_struct(obj, SceneObject)` 校验,plain map 直接 emit observe + skip(不 raise),让 commit 不被这个非关键步骤阻塞。
2. **跨 region object damage 路由 sub-backlog**:D2.1 决定本阶段只做 register,跨 region damage 落空。**用户路演 demo 通常不会触发**(prefab 落地后立即破坏的概率低,且 mid-macro 跨 region 罕见),但要写进 handoff 让下个会话知道。
3. **`:pg` group 命名空间在测试 fixture 里冲突**:`ChunkDirectory` 用 `:pg` 分发 broadcast。两个 named directory 共享同一 `:pg` group 会让 RegionA 收到 RegionB 的消息。**缓解**:`MultiRegionFixture` 给每个 directory 一个独立 `:pg_group_name`(已有 opt)或注入 mock dispatcher。
4. **跨 region prepare 超时**:`per_participant_timeout_ms = 5000` 仍然每 participant 独立(并行 `Task.async_stream`),延迟不累加。但**transaction_timeout_ms = 30000** 是 ceiling,跨 region 对它挤压更大。本阶段保持现值,测试时 verify 能在 30s 内跑完;真实生产(跨地理 region)再调。
5. **`MultiRegionFixture` 跟现有 `chunk_process_test` per-instance 模式重复造轮子**:实施时 verify 能否复用 existing helper(`SceneServer.Voxel.TestHelpers.start_chunk_directory_instance/2` 之类),不能再新建。
6. **`unique_prefab_transaction_id`(`prefab-#{request_id}-#{unique}`)在多 participant 下仍唯一**:已 monotonic + 进程级 unique_integer,无需改。

## 步骤分解

每步独立 commit,Elixir 改前 `mix format`,改 web 端跑 `cd clients/web_client && npx tsc --noEmit && npx vitest run`。**不 push**。

| Step | 范围 | 验证 | 估时 |
|---|---|---|---|
| **A4-1** | `TransactionExecutor.execute` 接受 `:scene_opts_by_participant` map(替换原 `:scene_opts`,无双路径);`run_prepare`/`run_commit`/`run_abort`/`register_scene_objects_after_commit` 取 per-participant opts;executor 单测加 multi-participant case | scene_server / world_server 单测全绿 | 0.5 天 |
| **A4-2** | Gate `build_prefab_plan` per-chunk `route_voxel_chunk` + 按 `{region_id, lease_id}` 分组成 participants;`coordinator_begin_transaction` 构造 multi-participant `attrs.participants`;`executor_execute` 喂 `scene_opts_by_participant` map(ws + tcp 镜像);gate 单测 multi-participant + fail-fast | gate_server 测试全绿,e2e 单 region 路径不破坏 | 0.5 天 |
| **A4-3** | `BuildTransactionApplier.register_scene_objects/2` 按 owner_region_id 分组,只 upsert 自 region;`voxel_scene_objects` schema + migration 加 `owner_region_id` / `owner_lease_id` 列;`SceneObjectStore` 写入新字段 | data_service / scene_server 测试全绿 | 0.5 天 |
| **A4-4** | `MultiRegionFixture` test helper(单 BEAM 双 named ChunkDirectory + 独立 :pg group + mock_route_voxel_chunk);跨 region prefab e2e test(prefab 锚跨两 chunks 各属一 region,gate 0x67 → 双 region prepare/commit → storage 都被写 + scene_objects 在 owner region 注册) | 新 e2e test 绿 + 现有测试不破坏 | 0.5-1 天 |
| **A4-5** | Recovery watcher resume 路径 verify multi-participant `:prepared` 重发(应该自然支持,但 verify);如有 gap 修;新增 multi-participant resume 单测 | world_server recovery 测试 + multi-participant resume 单测全绿 | 0.3 天 |
| **A4-final** | 决策稿状态改"已完成";同步 `_session-handoff.md`(阶段表 + backlog "跨 region damage 路由" 入 sub-backlog A4-bis)+ scene_server voxel README + world_server voxel README | git status 干净 | 0.2 天 |

总估时:**2-3 天**。

## 验收标准

- 现有测试矩阵不破坏(scene 378 / gate 191 / world 72 1 预存 / data_service 71 / web 260 / cargo 39)
- 新增测试:
  - executor multi-participant 单测(A4-1):prepare 并行调用 2 个不同 chunk_directory,scene_opts_by_participant 正确分发
  - gate `build_prefab_plan` 多 region(A4-2):2 个 chunks 路由到不同 region → 2 个 participant entries
  - gate fail-fast(A4-2):任一 chunk 路由失败 → 整个 prefab reject 并 reason `:no_route_for_chunk`
  - register_scene_objects fan-out(A4-3):scene_objects 按 owner_region_id 分组,跨 region 时只 upsert 自 region
  - 跨 region prefab e2e(A4-4):锚跨 chunk 边界 + 两 chunks 在不同 region → 整 prefab 落地,两 region 的 storage 都被写,scene_objects 在 owner region 注册
- 手动 demo:
  - 单 region prefab 流畅放(回归)
  - 跨 chunk 单 region prefab 流畅放(回归 A1 hotfix 路径)
  - 跨 region prefab(配置 multi-region scene fixture)流畅放,客户端线框预览和服务端落地一致

## 进度日志

- 2026-05-10:决策稿起草。等用户拍 D1-D6 后开始实施。

## 已知 sub-backlog(本阶段不做)

- **A4-bis 跨 region object damage 路由**(D2.1 决定):跨 region prefab 非-owner chunks 上的 damage 暂时落空(目标 cell 仍 break,但 part_destroyed cascade 不触发)。修法:`VoxelDamageRouter.dispatch_damage` 拿到 object_id 后通过 `voxel_scene_objects.owner_region_id` 跨 region RPC 到 owner 的 ObjectRegistry。1 天工作量。
- **`MultiRegionFixture` 跟 chunk_process_test 现有 per-instance 模式整合**(D4 风险 5):如果 A4-4 实施时发现可以复用 existing helper,去掉重复。
- **跨 region prepare 超时压测**:本阶段保持 `transaction_timeout_ms = 30000`。真实生产场景(地理跨 region,> 100ms RPC)需要观测 + 调参,留 Phase 6 HA 范围。
