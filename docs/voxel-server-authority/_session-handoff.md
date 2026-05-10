# Voxel server authority — 会话间衔接备忘

**Last updated**:2026-05-10,**A4-bis-1 落地后**(BeaconServer.Client term key 全量升级 — `register`/`lookup`/`await` 签名 `atom()` → `term()`,所有 caller 无需改动,基础设施第一步就绪)。Phase A4 主体已闭环;A4-bis-cluster 进行中。

下个会话开始时,先读这份(landing pad),再按需读 phase-X-*.md / 设计文档。

## 已落地阶段(2026-05-09 收盘)

| 阶段 | 状态 | 关键 commit |
| --- | --- | --- |
| 1a Refined cell domain (read-only wire) | 已完成 | `872e439` |
| 1b typed VoxelEditIntent (decode-only) + VoxelImpactIntent deprecation | 已完成 | `872e439` |
| 1c Scene refined mutation API + CellRefined delta + 客户端解锁 | 已完成 | `c99d6fd` (1c-1/2/3) → `508ce1e` (1c-4) → `a02817a` (1c-5) → `07bee6b` (1c-6) |
| 1d DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | `36b8ad7` |
| 2 refined micro edit 端到端贯通 | 已完成(被 1c 吸收) | `314ad8a` (stub + README) |
| 3 prefab v2 事务化(World/Scene transaction coordinator) | 已完成 | `a053c82` (决策稿) → `3fc9966` (3-1) → `6973843` (3-2) → `bd74e01` (3-3a) → `e91c38f` (3-3b) → `b93a10d` (3-4) → `86d9186` (3-5) |
| 3-bis fence persistence + auto-resume commit(crash safety 闭环) | 已完成 | `5e3b1e7` (决策稿) → `5cadbdf` (3-bis-1) → `f6602b0` (3-bis-2) → `d767c29` (3-bis-3) → `9db8c1d` (3-bis-4) → `d01b3d6` (3-bis-5) → `c7ef222` (3-bis-6) |
| 4 object provenance + part-health 破坏闭环(含整体销毁) | 已完成 | `067085f` (决策稿) → `df1ba93` (4-1) → `95a3330` (4-2) → `f61351c` (4-3) → `686d3cd` (4-4) → `53e4e7d` (4-5) → `330d528` (4-6) → `d800996` (4-7) → `0a5b428` (4-8) → `5352040` (4-9) → `b10e197` (4-10) |
| 4-bis ObjectStateDelta 推送链路 + 客户端碎屑粒子消费 | 已完成 | `ed16fef` (决策稿) → `0d9df62` (4-bis-1) → `3b96714` (4-bis-2) → `77f690d` (4-bis-3) → `2cb2373` (4-bis-4) → `3ca3f6e` (4-bis-5) → `a5b4eca` (4-bis-6) → `1ed8fd8` (4-bis-7) → `1e34841` (4-bis-8) → `bc89cea` (4-bis-9) → `d37598a` (4-bis-10) → `c78e04f` (4-bis-11) → `1f6cc13` (4-bis-12) → `f9906b1` (4-bis-13 docs 收尾) |
| A2 阶段 A 子 1:尺寸真实化(角色 1.7m / 跑速 6 m/s / apex 1.2m) | 已完成 | `6144408` (决策稿) → `aec8a98` (A2-1) → `05cebdf` (A2-2) → `ef5d524` (A2-3) → `03690c0` (A2-4) → `630d257` (A2-5) → `fb69661` (A2-6) → `730e6e7` (A2-final) |
| A1 阶段 A 子 2:客户端可玩 demo 必须线(prefab micro / 防覆盖 / 线框预览 / 跳跃同步 / 破坏技能) | 已完成 | `edbfbda` (决策稿) → `0275899` (A1-1 prefab catalog v2) → `d399f7c` (A1-1 progress) → `a4616e9` (A1-1 sphere e2e smoke) → `14c90a9` (A1-2 prefab 防覆盖) → `b2fe630` (A1-3 preview regression) → `b692ab1` (A1-4 ack ground_z wire) → `133bb85` (A1-4 jump arc smoke) → `7932fe2` (A1-5 voxel damage router) → `6d261d7` (A1-final) |
| A2 hotfix:client `DEFAULT_MOVEMENT_PROFILE` 同步 server max_speed=600 等 | 已完成 | `58a7a9e` |
| A1-1b Storage.put_micro_blocks/4 batch API(prefab 卡死性能优化,1.5s → 46ms,33×) | 已完成 | `0e3434c` |
| Server 启动 hotfix:TransactionRecoveryWatcher 接 plain-map stale snapshot | 已完成 | `cc3a31d` |
| Prefab 摆放精度 hotfix:server 按 world-micro 精度落 prefab + online adapter 走 boundary-snap micro 锚 | 已完成 | `a7a5bc9` (server raster) → `20f6a8a` (online adapter) |
| **A4 跨 region prefab 多 participant 事务 + 跨节点 damage / 0x6C 路由(主体)** | 已完成 | `f49c0b9` (决策稿) → `22312e0` (D7 折回) → `3f381d0` (A4-1) → `6acd37d` (A4-2) → `e6eafa3` (A4-3) → `630574b` (A4-4) → `13ef21a` (偏移同步) → `4ab6c83` (D8-D11 拍板) → `4198b8e` (A4-5) → `e3a5c01` (A4-6 + A4-final) |
| A4-bis-cluster A4-bis-1:`BeaconServer.Client` term key 全量升级 | 已完成 | 本会话 |

测试规模(2026-05-10,prefab 微精度 hotfix 收尾):

- data_service: 71 tests
- scene_server: **378 tests** (+3 from prefab micro hotfix:mid-macro 跨
  macro / 跨 chunk / group_by_chunk 多桶 case;原 floor-divided +
  negative-anchor 用例改写)
- scene_server :smoke: 5 tests
- gate_server: 191 tests
- world_server: 72 tests (1 预存失败 Windows path,不动)
- web_client: **260 vitest** (+2 placePrefabBoundarySnap online 用例)
- movement_core cargo: 39 tests

预存失败:`apps/world_server/test/world_server/voxel/authority_observe_test.exs:35`
Windows path 大小写,不动(memory 已记)。

未 push(用户没说 push 就别 push)。本地 master 领先 origin **72 commits**
(Phase 4 末 35 + Phase 4-bis 14 + Phase A2 8 + Phase A1 9 + A2 hotfix 1 +
A1-1b 1 + watcher hotfix 1 + handoff docs 1 + prefab micro hotfix 2)。

## 已知预存失败(本环境)

- `apps/world_server/test/world_server/voxel/authority_observe_test.exs:35` Windows path 大小写比对。**不要尝试修**(本会话也没碰过 world_server)。

## 下一步候选(按 README 顺序)

按 `docs/voxel-server-authority/README.md` 阶段表:

| 阶段 | 状态 | 范围 |
| --- | --- | --- |
| A4-bis-cluster | 进行中(A4-bis-1 ✓ → 5 step 待办) | 真正的多 scene_node 分布式部署。剩余步骤:**A4-bis-2** SceneServer.Voxel.RegionRouting 新模块(`register_local_region` / `unregister_local_region` / `resolve_scene_node` / `resolve_chunk_directory`,test stub 通过 `:persistent_term` 注入);**A4-bis-3** RegionRuntime.apply_lease/release 接 RegionRouting register/unregister;**A4-bis-4** World 端 `MapLedger` region → scene_node 分配(D8.B join-order)+ `WorldServer.Voxel.SceneNodeRegistry` + `world_sup` / Worker.Interface 改造按 participant 解析对应 scene_node + `MapLedger.region_for_chunk/2`;**A4-bis-5** ObjectOwnerLookup / VoxelDamageRouter / ObjectRegistry default opts 改为走 RegionRouting + cold-start 走 region resolver;**A4-bis-6** 双 BEAM `:peer` 节点 e2e;**A4-bis-final** 决策稿/handoff 同步。决策来源:用户"MVP 大世界一台机扛不住",从 Phase 6 HA 提前。剩余估时 3.5-5 天。文档:`phase-A4-cross-region-prefab.md` 文末 A4-bis-cluster 段 |
| A3 | 未开始 | 阶段 A 子 3:多客户端同世界联调(本地多 tab / 多机 + chunk 订阅一致性 + 移动同步 + 破坏可见性) |
| 5 | 未开始 | 属性目录 + 温湿度基础模拟 |
| 测试隔离 | 未开始 | test_helper 加 setup TRUNCATE `voxel_transaction_coordinator_snapshots` / `voxel_chunk_pending_transactions`,避免跨 mix test stale snapshot 让 transaction 路径走 replay-skip |
| BuildTransaction snapshot 字段演进 | 待评估 | A1-1b 这次发现 stale snapshot binary_to_term 出 plain map 而不是 struct,让 watcher 启动 crash。已加 catchall fix,但根因(Phase 3-bis-3 加 intents_by_participant / Phase 4 加 scene_objects 后旧 blob 的 struct 形态变了)需要正经评估是否需要 schema_version 化 |

**阶段 A 进度**:A2 + A1 + A1-1b 全部完成 2026-05-09。剩 A3(多客户端联调)
+ Phase 5(属性目录)。A2 + A1 + A1-1b 已经把"路演 demo 必须线"全部打通:
角色 1.7m / 跑速 6 m/s / 跳跃 apex 1.2m / sphere/cylinder/stairs 形状 / prefab
防覆盖 / 线框预览 / 跳跃同步(ack ground_z wire 端到端)/ 破坏技能 / **prefab
placement < 100ms 不再卡死**。

**用户实测验证状态**:
- A1-1b 修完后 user 报 server 重启 OK,但发现客户端线框预览(micro 精度)和
  服务端实际摆放(macro 对齐)不符 — 服务端按方框位摆,丢了 micro offset。
  Prefab micro-precision hotfix 已落(`a7a5bc9` server raster + `20f6a8a`
  online adapter):server `prefab_raster` 按 world-micro 精度 per-cell 拆
  (chunk, local_macro, slot),online adapter 走 boundary-snap 出 micro 锚发
  `0x67`。**下个会话开始前先确认 user fresh demo:prefab 实际落地是否和
  线框严格一致**。如果还有偏差,可能是 wireframe 几何 vs server raster slot
  decode 顺序细节(应该不会,两端都用 `slot = x + y*8 + z*64`),或者 boundary
  snap 选锚算法选了不同候选(可在 client 端 emit `world:prefab-boundary-snap-committed`
  比对 anchorMicroCoord 与 server `voxel_chunk_transaction_committed` log 里的
  intent 起点)。

**Phase 4-bis 后剩余的 backlog**(若用户优先继续巩固 4-bis 系):

- **0x6C ChunkDelta apply 前 cache hook**(Phase 4-bis-10 deferred 到 Phase 5):
  ClearedSlotCache + DebrisSimulation pipeline 已 wired,但 cache 实际无写入,
  production 路径全走 affected_chunks_fallback(粒子在 chunk 中心点散开,
  不是沿 micro slot 散布)。Phase 5 把 owner_object_id 接进 FRefinedCellData
  之后,新增一行 cache hook(applyDelta CellRefined / CellEmpty op 之前
  diff layer.ownerObjectId)即可升级到精确档 B。
- **DebrisRenderer per-instance 颜色微抖**:Phase 4-bis-12 用单一 base 棕色;
  per-instance instanceColor 通道留待 Phase 5。
- **HUD destroyed 升级**:目前一行字 3.5s。Phase 5+ 可加屏幕红闪 / 音效 /
  destroyed object 中心爆炸 emoji。
- ~~**跨 region 多 participant 事务**(Phase 3-bis 后续)~~:**已在 Phase A4 主体闭环**(A4-1 ~ A4-final 落地 2026-05-10):BuildTransaction multi-participant + Gate per-chunk routing + 跨节点 damage RPC + 0x6C owner-driven fan-out。生产路径仍单 scene_node;真分布式部署在 A4-bis-cluster 决策稿就位。
- **Per-region coordinator**(Phase 6 留):当前单全局 coordinator 是潜在 SPOF。
- **紧凑 ChunkDelta**(取代 commit 时的 snapshot fan-out):commit 时把 batch
  内每个 intent 编成 ChunkDelta op 推送,不必走整 chunk snapshot。
- **跨进程 e2e harness**(Phase 2 决策稿 park 的 backlog):gate ↔ scene ↔
  data_service ↔ web_client 全链路 e2e 自动化。
- **fence 超时 sweeper**:`fenced_at_ms` 字段已写入,但目前没自动清理"卡死"fence。

**Phase 5 属性目录 + 温湿度基础模拟**(README 顺序下一阶段):

- 还没建决策稿。需要先和用户对齐:`AttributeCatalogSnapshot` / `TagCatalogSnapshot` 协议、温湿度计算、`PartDefinition.default_health_ratio` 字段(Phase 4 留的 1.0 ratio 旋钮)。
- 新决策稿位置:`docs/voxel-server-authority/phase-5-attributes-and-environment.md`(待建)。
- Phase 5 同时是 Phase 4 留下的若干悬挂物的"完成场":整体销毁的下游钩子(掉落物 / 任务系统 / 资源回收 / 客户端 0x6C 消费 / 结构完整性 / 塌陷规则)都是 Phase 5+ 范围。

## 工作流约定(跨会话)

参考 memory:`feedback_decision_stub_workflow.md` + `feedback_no_backcompat_unreleased.md`。简版:

1. **决策稿先行**:每 phase 在 `docs/voxel-server-authority/phase-<id>-<slug>.md` 写决策稿,列决策项(每项给推荐值)、不在范围、风险、step 列表。决策稿入仓后才动代码。
2. **逐 step commit**:每 step 单独 commit。Elixir 文件改前 `mix format`;web 端 `npx tsc --noEmit && npx vitest run`。
3. **进度日志**:每 step 完成后在决策稿 `## 进度日志` 追加一行。同步 `README.md` 阶段表。
4. **不 push**:用户没说 push 就只 commit。
5. **全新系统不留兼容**:架构重写默认按"未上线第一版"姿势,不留 wrapper / 双路径 / deprecated alias。

## 关键运行时约定(避免下次重新发现)

### Postgres / Repo

- `apps/data_service/test/test_helper.exs` 启动 `DataService.Repo` + 跑 `priv/repo/migrations`。
- **Phase 1d 后**:`apps/scene_server/test/test_helper.exs` 与 `apps/gate_server/test/test_helper.exs` 也启动 Repo + migrations(因为 ChunkSnapshotStore 走 Repo)。
- **assert_receive_timeout 调到 1000ms**(scene/gate test_helper),容忍 Postgres INSERT 延迟。
- 持久化测试要 `async: false` + `setup do Repo.delete_all(...); WriteTokenStore.reset(WriteTokenStore); :ok end`。

### Windows 测试

- `mix` 用 `cmd //c "mix ..."`(via Bash 工具)或 `mix ...`(via PowerShell 工具)。
- vitest 必须 `cd clients/web_client/`,从 umbrella 根跑会丢 globals。
- `cmd /c` 在 PowerShell 工具里 cwd 跨调用持久;Bash 工具不持久。
- `mix` 报 dependency 问题就从 umbrella 根跑(`mix test apps/<app>/test`),不从 `apps/<app>/` 子目录跑。
- `mix cmd --app` 也不行(config 加载缺 :database)。
- **vitest 不接受 `--reporter=basic`**;直接 `npx vitest run` 即可。

### 体素架构现状

- ChunkSnapshotStore 是 stateless module,直走 `DataService.Repo`(Phase 1d)。
- ChunkPendingTransactionStore 是 stateless module,新表 `voxel_chunk_pending_transactions`(Phase 3-bis-1)。
- **SceneObjectStore**(Phase 4-1):新表 `voxel_scene_objects` + `voxel_scene_object_id_seq` 全局 sequence。`covered_chunks` / `part_states` 用 `term_to_binary` 编码 server-side blob(对齐 fence_payload 风格)。
- WriteTokenStore 仍是 GenServer(in-memory);Phase 1d 加了 `reset/1` test hatch。
- ChunkProcess 是每个 chunk 一个 GenServer,持有 hot truth + lease;`pending_fence.intents` 是 list(Phase 3-3a),fence 同步持久化进 voxel_chunk_pending_transactions(Phase 3-bis-2),init 时按 lease 一致性校验 reload。**Phase 4 起 commit 后自动调 `Storage.refresh_chunk_object_refs/1` 维护 ChunkObjectRef[] 摘要**;**apply 路径异步 dispatch damage 到 ObjectRegistry**(Task.start 避免 deadlock);**新增 `destroy_part/2` + `cleanup_object_refs/2` server-internal API**(走当前 lease 持久化,不走 lease validate)。
- ChunkDirectory 注册 chunk 到 ChunkProcess pid,负责 apply_intent 路由 + handoff prewarm + transaction prepare/commit/abort 路由(Phase 3-bis-2 起 attrs 透传 `:decision_version`);**Phase 4 加 destroy_part / cleanup_object_refs 路由**。
- TransactionCoordinator 持久化走 Postgres(`voxel_transaction_coordinator_snapshots` 单行 snapshot,Phase 3-1);**`BuildTransaction.intents_by_participant` 字段随之持久化**(Phase 3-bis-3);**Phase 4 加 `BuildTransaction.scene_objects` 字段 + `:next_object_id_fn` init opt(默认绑 SceneObjectStore.next_object_id)+ replay 路径跳过 allocation 避免 sequence 浪费**。
- TransactionExecutor 加 `:prepared` fast-path(Phase 3-bis-4);**Phase 4 加 `register_scene_objects_after_commit`**(commit_decision 之后 scene_caller.register_scene_objects/2,失败非阻塞)。
- TransactionRecoveryWatcher 对 `:prepared` 通过 `:scene_opts_resolver` 自动重发 commit dispatch(Phase 3-bis-5)。
- 0x67 PrefabPlaceIntent dispatch 切到 World 事务路径(Phase 3-3b)。
- **Phase 4 新增**:
  - `MicroLayer.owner_object_id` / `owner_part_id` 在 prefab 路径填实(intents 已支持,Phase 4 让 World 端把 BuildTransaction.scene_objects 填实)。
  - `Storage.refresh_chunk_object_refs/1`:整 chunk 重算 cell 级 + chunk 级 object refs,xxHash64 cover_hash。
  - `Storage.lookup_owner_at/3`:反向查 (macro, slot) → {oid, pid} | nil。
  - `SceneServer.Voxel.PartState`:新 struct,health/state_flags + 位常量。
  - `SceneServer.Voxel.ObjectRegistry`:per-scene GenServer(默认 module-named singleton,tests 注 `:name` 起独立实例),accumulate_damage / destroy_part / destroy_object 同步 cascade 链路。
  - `BuildTransactionApplier.register_scene_objects/2`:scene-side 把 transaction.scene_objects upsert 到 ObjectRegistry。
  - `0x6C ObjectStateDelta` wire codec encode/decode + web_client decoder stub(实际 Gate 推送链路 deferred 到 4-bis)。
- **Phase A4 新增**(跨 region prefab 事务 + 跨节点 damage / 0x6C 路由):
  - `voxel_scene_objects` schema 加 `owner_region_id` / `owner_lease_id`(字典序首
    covered_chunk 所在 region 是 owner;**不**持久化 `covered_chunks_by_region`
    —— 该信息动态,改运行时 inflate)
  - `WorldServer.Voxel.TransactionExecutor`:`:scene_opts_by_participant` map
    替换 `:scene_opts`(per-participant);`register_scene_objects_after_commit`
    给每个 obj inflate `:covered_chunks_by_region`(从 `transaction.participants
    .affected_chunks` 反向推算)
  - Gate `build_prefab_plan` per-chunk routing + 按 `(region_id, lease_id)` 分组
    成 multi-participant;任一 chunk 路由失败 fail-fast `:no_route_for_chunk`
  - `SceneServer.Voxel.ObjectOwnerLookup`:per-scene ETS cache,hot path 直读
    `:ets.lookup`,miss 走 GenServer.call SELECT;register-after-commit 写入
    准确 split,destroy_object 时 evict
  - `VoxelDamageRouter`:owner_lookup → `:scene_node_resolver_fn` 解析 owner
    scene_node → 透明 `GenServer.call({Mod, scene_node}, ..., 200ms)` 跨节点
    GenServer 协议;失败 emit `voxel_damage_cross_region_failed`,成功 emit
    `voxel_damage_routed_cross_region`
  - `ObjectRegistry.dispatch_object_state_delta`:按 `covered_chunks_by_region`
    分桶,每桶通过 `:region_routing_fn` opt 解析到 chunk_directory_target
    (default `nil` 退化为本地 `state.chunk_directory`)
  - `ObjectRegistry` + `ObjectOwnerLookup` **挂入 `VoxelSup` 生产监督树**(顺手
    补 Phase 4 起一直未挂的 ObjectRegistry)
  - Gate `executor_execute` 加 `:voxel_chunk_directory_resolver` env hook
    (default `SceneServer.Voxel.ChunkDirectory`,test 注入 fn 让 participant
    路由到不同 named instance,A4-bis-cluster 后改为走 RegionRouting)
  - `TransactionRecoveryWatcher.scene_opts_resolver` 改 1-arity 接 participants
    (multi-participant resume 自然支持,因 intents_by_participant Phase 3-bis-3
    起就持久化)
  - 决策稿草稿引用的"已有 region/lease → scene_node 映射"**事实错误**(`BeaconServer
    .Client.lookup` 当前只支持 atom resource);跨节点路径在 A4 阶段是注入式
    接口,真路由在 A4-bis-cluster 落地
- **Phase 4-bis 新增**:
  - `0x6C` codec 主战场迁到 `scene_server/voxel/codec.ex`(对齐 chunk_delta /
    chunk_snapshot / chunk_invalidate);gate codec 改 binary pass-through。
  - `PartState.flag_part_destroyed = 0x04`(完成 D5 三段 state_flags 对齐
    protocol §9)。
  - `ChunkDirectory.lookup_chunk_pid/3`:read-only,**不**lazy-start。
  - `ChunkProcess.push_object_state_delta_payload/2`(GenServer.cast)+
    `fan_out_object_state_delta_payload/2` private(镜像 push_chunk_delta)+
    observe key `voxel_object_state_delta_push`。
  - `ObjectRegistry` 在 emit_damage / emit_part_destroyed / emit_object_destroyed
    之后**同步** dispatch 0x6C broadcast(D4)。`run_destroy_object` 内 bump
    object_version 保 cascade 路径版本号单调。`:chunk_directory` init opt 注入。
  - 4 个新 observe key:`voxel_object_state_delta_dispatch` /
    `voxel_object_state_delta_push` / `voxel_object_state_delta_dispatch_failed` /
    `tcp_voxel_object_state_delta_forwarded` + `ws_voxel_object_state_delta_forwarded`。
  - gate `WsConnection` / `TcpConnection` `handle_info({:voxel_object_state_delta_payload, payload}, ...)`
    forward to socket(同 chunk_delta forward 模式)。
  - **web_client**:
    - `ObjectStateDeltaConsumer`(per-object_id `last_seen_version` 去重
      + `onDelta` / `onDuplicate` 钩子)
    - `ClearedSlotCache`(per-object slots Map + TTL 2s sweep + 单 object 上限
      256;**production cache hook 推到 Phase 5**,目前数据结构 + pipeline
      已就位但 ChunkDelta apply 前 hook 未接,因为 FRefinedCellData 不含
      ownerObjectId)
    - `DebrisSimulation`(纯数据状态机,半球面随机 + 重力 + lifetime + 全局
      上限 500)
    - `DebrisRenderer`(InstancedMesh 包装,棕色 0.05m × MacroWorldSize 立方体)
    - `OnlineVoxelWorldAdapter` 持有 cache + sim,onFrame 顺序
      tickDebris → drainVoxelMessages → processObjectStateDeltaRetryQueue;
      consumer onDelta 钩子调 handleObjectStateDeltaForDebris(cache.take →
      spawn / 100ms retry / affected_chunks_fallback);emit
      `world:object-state-delta` event
    - `RenderOrchestrator` 通过 duck typing 在构造时检测
      `world.getDebrisSimulation`,实例化 DebrisRenderer 并挂到 rootGroup;
      onFrame 调 syncFromSimulation
    - `HudView` 订阅 `world:object-state-delta` event,destroyed flag 时
      `showFlash("object #N destroyed (M debris)")` 3.5s
- 客户端在线模式:storage.refinedCells 仍然是 `FRefinedCellData[]`(lossy 自 wire);Phase 1c-5 决策 5 RFC 备注了"未来改 wire-form-as-truth"。
  **特别注意**(Phase 4-bis):由于 FRefinedCellData 不携带 ownerObjectId,
  ClearedSlotCache 的 ChunkDelta apply 前 hook 还没接,debris 粒子目前
  全走 affected_chunks_fallback(chunk 中心点散开)。Phase 5 接 owner 进
  FRefinedCellData 后可升级到精确档 B(沿 micro slot 散布)。

### 前端策略冻结(2026-04-26)

- 唯一在迭代的客户端是 `clients/web_client`(memory `client_focus.md` 2026-05-07 起;CLAUDE.md 旧条目作废)。
- `clients/bevy_client` 已冻结。

## 关键文件锚点

| 用途 | 路径 |
| --- | --- |
| 阶段总表 | `docs/voxel-server-authority/README.md` |
| 协议设计参考(权威) | `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` |
| 线协议规范 | `docs/2026-04-10-线协议规范.md` |
| 体素 chunk 进程 | `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` |
| 体素 chunk 目录 | `apps/scene_server/lib/scene_server/voxel/chunk_directory.ex` |
| Codec / chunk_hash | `apps/scene_server/lib/scene_server/voxel/codec.ex` |
| Storage(canonical truth) | `apps/scene_server/lib/scene_server/voxel/storage.ex` |
| **Object provenance(Phase 4)** | `apps/scene_server/lib/scene_server/voxel/object_registry.ex`、`apps/scene_server/lib/scene_server/voxel/part_state.ex` |
| **Owner lookup cache + 跨节点 damage 路由(Phase A4)** | `apps/scene_server/lib/scene_server/voxel/object_owner_lookup.ex`、`apps/scene_server/lib/scene_server/combat/voxel_damage_router.ex` |
| Postgres 持久化(1d 后) | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` |
| **Postgres scene_objects(Phase 4)** | `apps/data_service/lib/data_service/voxel/scene_object_store.ex`、`apps/data_service/lib/data_service/schema/voxel_scene_object.ex`、`apps/data_service/priv/repo/migrations/20260508000002_create_voxel_scene_objects.exs` |
| Gate 协议 codec | `apps/gate_server/lib/gate_server/codec.ex` |
| Gate ws/tcp dispatch | `apps/gate_server/lib/gate_server/worker/{ws,tcp}_connection.ex` |
| World map ledger | `apps/world_server/lib/world_server/voxel/map_ledger.ex` |
| **World transaction(Phase 4 加 scene_objects)** | `apps/world_server/lib/world_server/voxel/build_transaction.ex`、`apps/world_server/lib/world_server/voxel/transaction_coordinator.ex`、`apps/world_server/lib/world_server/voxel/transaction_executor.ex` |
| Web client 在线 adapter | `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts` |
| Web client wire decoder | `clients/web_client/src/infrastructure/net/refinedCellWire.ts`、`voxelEditIntent.ts`、`voxelProtocol.ts`、`objectStateDelta.ts`(Phase 4)、**`objectStateDeltaConsumer.ts`(Phase 4-bis)** |
| **Web client 碎屑粒子(Phase 4-bis)** | `clients/web_client/src/voxel/clearedSlotCache.ts`、`debrisEffect.ts`(simulation)、`debrisRenderer.ts`(InstancedMesh) |
| **Web client HUD(Phase 4-bis 起订阅 world:object-state-delta)** | `clients/web_client/src/presentation/hud/hudView.ts` |

## 这次会话产出(2026-05-09,Phase A2 + A1 + 性能优化 + hotfix)

A2 8 个 + A1 10 个 + A2 hotfix 1 + A1-1b 1 + watcher hotfix 1 = **21 个 commit**,
本地 master 未 push:

性能优化 + hotfix(后段加的):
```
cc3a31d   voxel(hotfix): TransactionRecoveryWatcher 接 plain-map stale snapshot
0e3434c   voxel(A1-1b): Storage batch micro_block API(prefab 卡死性能优化)
58a7a9e   voxel(A2 hotfix): 同步 client DEFAULT_MOVEMENT_PROFILE 到 A2 新值
```

A2(尺寸真实化):
```
730e6e7   docs(voxel): finalize Phase A2 (status + README + handoff)
fb69661   voxel(A2-6): magic number sweep
630d257   voxel(A2-5): scene_ops capsule 单位修正(米 → cm)
03690c0   voxel(A2-4): movement_core unit test 跟随新 profile + 注释 sweep
ef5d524   voxel(A2-3): movement profile 默认值调到现实人体数值
05cebdf   voxel(A2-2): camera 参数适配 1.7m 角色
aec8a98   voxel(A2-1): AvatarConstants + avatar mesh / ring 调到 1.7m 角色
6144408   docs(voxel): land Phase A2 plan (real-world scale)
```

A1(客户端可玩 demo 必须线):
```
本会话    docs(voxel): finalize Phase A1 (status + README + handoff)
7932fe2   voxel(A1-5): 破坏技能 → voxel damage 路由(combat 接 ObjectRegistry)
133bb85   voxel(A1-4): jump arc e2e smoke (ground_z 锁定 + apex 验证)
b692ab1   voxel(A1-4): movement ack 加 ground_z(jump arc 同步基础)
b2fe630   voxel(A1-3): prefab preview 沿 micro mask(回归测试)
14c90a9   voxel(A1-2): prefab 防覆盖(prepare-stage occupancy reject)
a4616e9   voxel(A1-1): e2e smoke (sphere prefab → 280 slots, mask pixel-perfect)
d399f7c   docs(voxel): A1-1 进度日志 + 性能 backlog(A1-1b)
0275899   voxel(A1-1): prefab catalog v2 (sphere/cylinder/stairs micro mask)
edbfbda   docs(voxel): land Phase A1 plan (playable client experience, merged)
```

A2 + A1 的核心收益:

- **角色尺寸**:1.2m → 1.7m(`AvatarConstants` 集中常量)
- **跑速**:2.2 m/s → 6 m/s(`max_speed` 600,UE CMC 对齐)
- **跳跃**:wire 端到端 ack.ground_z 锁定 launch z + apex 96cm 实测
- **scene_ops capsule** 米单位 latent bug 修了
- **prefab catalog**:v1 macro list → v2 micro mask(sphere/cylinder/stairs),
  服务端 BlueprintCatalog 跟客户端 prefab/definitions.ts 像素级对齐 + 持久化
  e2e smoke 验证
- **prefab 防覆盖**:prepare 阶段 occupancy reject,fence 未写入 → zero-cost
  cleanup,wire reason unwrap 成裸 atom,客户端 HUD flash 提示
- **prefab 线框预览**:沿 micro mask 描边,A1-1 切 hotbar 后自动正确,加
  regression test 立成契约
- **破坏技能**:CombatExecutor.resolve_cast 之后 PlayerCharacter 并行 dispatch
  voxel damage(actor / voxel 双轨),target_position → ChunkSnapshotStore →
  Storage.lookup_owner_at → ObjectRegistry.accumulate_damage,自动 fan-out 0x6C
  ObjectStateDelta(Phase 4-bis 链路)+ 客户端碎屑粒子

后段三个 hotfix:

1. **A2 hotfix**(`58a7a9e`):用户实测发现移动延迟严重 — 根因是 A2 commit
   `ef5d524` 改了 server `MovementProfile.default/0` 但**漏改 client
   `clients/web_client/src/domain/movement/profile.ts` `DEFAULT_MOVEMENT_PROFILE`**。
   Client predict 用旧 220 cm/s,server 真实 600 cm/s,每个 ack 触发 reconcile
   把 client 向前 snap ~38cm,体感 = 100ms 延迟。修法:client profile.ts
   整套跟 server 同步;profile.test.ts 断言更新(本来名字就是"matches the
   authoritative SceneServer movement defaults",讽刺地 A2 时漏跑这个测试)。
   **教训**:任何 movement profile 改动都必须同步 3 处:profile.ex /
   profile.rs / profile.ts。

2. **A1-1b**(`0e3434c`):用户实测发现"右键放 prefab 整服务器卡死,移动也
   被阻塞 1.5-2s"。根因不是网络/wire,是 Elixir 端 algorithmic O(N²)。
   旧路径每次 `Storage.put_micro_block` 调 `normalize!(storage)`(整 4096
   macro_headers list rebuild)+ List.replace_at(O(N)),sphere 280 slots 跑
   ~1.5s。期间 ws_connection / chunk_process GenServer 邮箱被锁,同玩家所有
   movement input ack 等 prefab 完成才发,体感"整服务器卡死"。修法:加
   `Storage.put_micro_blocks/4` 一次性接 N 个 (slot, layer_attrs),按 attribute
   signature 分组合并 → 1 次 normalize + 1 次 List.replace_at。算法 O(N²) →
   O(N + macro_count)。`ChunkProcess.build_intents_storage` 加
   `detect_micro_block_batch/1` fast-path 检测 single-macro micro batch 走
   batch API,否则 fallback 到旧逐 intent reduce 路径。**实测 1.5s → 46ms
   (33×)**,7 个新 unit test 验证 batch 跟 N×sequential 像素级等价。
   **不需要 Rust NIF**(这是 algorithmic fix 不是常数优化,Rust 也写不出
   O(1) normalize)。

3. **Watcher hotfix**(`cc3a31d`):用户重启 server 时 crash —
   `TransactionRecoveryWatcher.handle_transaction/3` 收到 plain map(不是
   `%BuildTransaction{}` struct)的 stale snapshot 时 FunctionClauseError,
   watcher init 失败 → WorldSup 起不来 → world_server.Application crash →
   整 umbrella shutdown。根因:Phase 3-bis-3 / Phase 4 给 BuildTransaction
   defstruct 加了 `intents_by_participant` / `scene_objects` 字段,旧 stale
   blob 反序列化字段不全 fallback 成 plain map,所有 struct-pattern clause
   miss。修法:加 `not is_struct(stale, BuildTransaction)` catchall clause,
   plain map 直接 `abort_decision` + emit `voxel_transaction_recovery_stale_*`
   observe event。Backlog:**BuildTransaction snapshot schema_version 化**
   是更彻底的修法。

backlog:
- ~~**A1-1b** Storage.put_micro_blocks/4 batch API(已完成 `0e3434c`)~~
- **测试隔离**:test_helper 加 setup TRUNCATE 几张 voxel 表(本会话多次踩到
  stale snapshot 让 transaction 走 replay-skip 路径让 e2e smoke 失败假象,
  得 fresh DB 才能 verify)
- **BuildTransaction snapshot schema_version 化**:防止下次再加字段时 stale
  blob 又 plain map(catchall hotfix 是 band-aid)
- **A3** 多客户端联调

A2 之前的所有 Phase 1a → 4-bis commits(完整列表见上一个会话的 handoff)。

## ⚠️ 跨会话恢复优先动作

下个会话开始,**先确认这三条**:

1. **用户能否成功重启 server**(watcher catchall hotfix `cc3a31d` 后通常能起;
   如果 crash,可能是更深层 stale shape — 已知 `cc3a31d` catchall 只匹配带
   `transaction_id` key 的 plain map,但仍有可能见到只带 `state + decision_version`
   两个 key 的 stale,触发 FunctionClauseError → world_server 起不来 → umbrella
   shutdown)。临时修法:`cmd /c mix run --no-start scripts/truncate_voxel_tables.exs`
   清表(scripts 目录已有,untracked)。根治候选:**TransactionCoordinator
   `validate_persisted_payload` 拒绝任何 inner transactions value 不是
   `%BuildTransaction{}` 的 stale payload,让 coordinator 启动空状态而不是
   把 plain-map stale 喂给 watcher**(handoff backlog,与 BuildTransaction
   schema_version 化是同一根因)。

2. **用户重启后能否流畅放 prefab + 摆放位置和线框预览像素级一致**:
   - 流畅性靠 A1-1b batch API(33×)
   - 精度靠 prefab micro-precision hotfix(`a7a5bc9` + `20f6a8a`)
   - 如果摆放位置和线框还有偏差:对比 client `world:prefab-boundary-snap-committed`
     event 里的 `anchorMicroCoord` vs server `voxel_chunk_transaction_committed`
     log 里 intent 起点(macro+slot 还原成 world micro 应该完全相等)

3. **~~多 chunk prefab 跨 region 警告~~**:**Phase A4 主体已闭环**(2026-05-10)。
   mid-macro 锚把 prefab 摆在 chunk 边界附近跨两 chunks 时,gate `build_prefab_plan`
   会按 `(region_id, lease_id)` 分组成 multi-participant,World coordinator
   begin_transaction 持 N 个 participant,executor 走 multi-participant prepare
   + commit 路径,任一 prepare 失败 fail-fast abort。Storage 在两 chunk 都被
   写,scene_objects 在 owner participant(字典序首 chunk 所在 region)的
   ObjectRegistry 注册。生产仍单 scene_node(所有 region 跑同一 BEAM),真
   分布式部署在 A4-bis-cluster 阶段。

如果以上都 OK,可以推进:
- **A4-bis-cluster**(真多 scene_node 部署,MVP 必需。**A4-bis-1 已完成本会话**:`BeaconServer.Client.register/lookup/await` 签名升级为 `term()`,所有 caller 无代码改动直接兼容;新增 5 个 term key 单测全绿。剩 A4-bis-2~6 + A4-bis-final,3.5-5 天)
- **A3** 多客户端联调
- **Phase 5** 属性目录 + 温湿度

## ⚠️ A4-bis 期间已知非 regression 失败

- `apps/gate_server/test/gate_server/ws_connection_voxel_cross_region_test.exs` 第二个 test 在 `__ex_unit_setup_0/1` 注册 region_b 时偶现 `:region_bounds_overlap`。根因:`MapLedger` fixture 用 `ensure_started!` 走全局 named singleton,跨 2 个 test 的 setup 重复注册同 bounds region(region_id 是 `System.unique_integer/1` 唯一,但 bounds_chunk_min/max 是同一对常量),`validate_region_bounds_available` reject。**与 BeaconServer.Client term key 升级无关**。修法候选:fixture `on_exit` 清理 MapLedger 注册,或每 test 用不同 bounds(连同 anchor 偏移)。A4-5 progress log 标的"3 fail → 3 fail"应该是当时 CI 漏拍此 fail。**留 A4-bis 期间 backlog**,本会话不动以免 scope creep。
