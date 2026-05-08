# Voxel server authority — 会话间衔接备忘

**Last updated**:2026-05-08,Phase 4 全程落地后。

下个会话开始时,先读这份(landing pad),再按需读 phase-X-*.md / 设计文档。

## 已落地阶段(2026-05-08 收盘)

| 阶段 | 状态 | 关键 commit |
| --- | --- | --- |
| 1a Refined cell domain (read-only wire) | 已完成 | `872e439` |
| 1b typed VoxelEditIntent (decode-only) + VoxelImpactIntent deprecation | 已完成 | `872e439` |
| 1c Scene refined mutation API + CellRefined delta + 客户端解锁 | 已完成 | `c99d6fd` (1c-1/2/3) → `508ce1e` (1c-4) → `a02817a` (1c-5) → `07bee6b` (1c-6) |
| 1d DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | `36b8ad7` |
| 2 refined micro edit 端到端贯通 | 已完成(被 1c 吸收) | `314ad8a` (stub + README) |
| 3 prefab v2 事务化(World/Scene transaction coordinator) | 已完成 | `a053c82` (决策稿) → `3fc9966` (3-1) → `6973843` (3-2) → `bd74e01` (3-3a) → `e91c38f` (3-3b) → `b93a10d` (3-4) → `86d9186` (3-5) |
| 3-bis fence persistence + auto-resume commit(crash safety 闭环) | 已完成 | `5e3b1e7` (决策稿) → `5cadbdf` (3-bis-1) → `f6602b0` (3-bis-2) → `d767c29` (3-bis-3) → `9db8c1d` (3-bis-4) → `d01b3d6` (3-bis-5) → `c7ef222` (3-bis-6) |
| 4 object provenance + part-health 破坏闭环(含整体销毁) | 已完成 | `067085f` (决策稿) → `df1ba93` (4-1) → `95a3330` (4-2) → `f61351c` (4-3) → `686d3cd` (4-4) → `53e4e7d` (4-5) → `330d528` (4-6) → `d800996` (4-7) → `0a5b428` (4-8) → `5352040` (4-9) → 本会话 (4-10) |

测试规模(2026-05-08 末态,Phase 4 收尾):

- data_service: 71 tests (+18 SceneObjectStore)
- scene_server: 330 tests (+53 across StorageObjectRefs / ObjectRegistry / ChunkProcessObjectProvenance / ObjectLifecycleIntegration)
- gate_server: 188 tests (+7 ObjectStateDelta wire codec)
- world_server: 72 tests (+12 TransactionCoordinatorObjectAlloc)
- web_client: 216 vitest, tsc clean (+6 objectStateDelta)

预存失败:`apps/world_server/test/world_server/voxel/authority_observe_test.exs:35`
Windows path 大小写,不动(memory 已记)。

未 push(用户没说 push 就别 push)。本地 master 领先 origin 35 commits。

## 已知预存失败(本环境)

- `apps/world_server/test/world_server/voxel/authority_observe_test.exs:35` Windows path 大小写比对。**不要尝试修**(本会话也没碰过 world_server)。

## 下一步候选(按 README 顺序)

按 `docs/voxel-server-authority/README.md` 阶段表:

| 阶段 | 状态 | 范围 |
| --- | --- | --- |
| 5 | 未开始 | 属性目录 + 温湿度基础模拟 |

**Phase 4 后剩余的 backlog**(若用户优先继续巩固 Phase 4 系):

- **0x6C ObjectStateDelta 服务端→Gate 订阅者实际推送链路**(Phase 4-8 仅落 wire codec + 测试,实际通过 Gate 连接的订阅者推送 deferred 到 Phase 4.5 / Phase 5):需要 `ChunkProcess.push_object_state_delta_payload` + `ChunkDirectory.broadcast_object_state_delta` + ObjectRegistry destroy 路径里调一次。
- **跨 region 多 participant 事务**(Phase 3-bis 后续):BuildTransaction 已支持 multi-participant,Gate 的 prefab dispatch 还只构造 single-participant。需要先有跨 region prefab 的语义设计文档。
- **Per-region coordinator**(Phase 6 留):当前单全局 coordinator 是潜在 SPOF。
- **紧凑 ChunkDelta**(取代 commit 时的 snapshot fan-out):commit 时把 batch 内每个 intent 编成 ChunkDelta op 推送,不必走整 chunk snapshot。
- **跨进程 e2e harness**(Phase 2 决策稿 park 的 backlog):gate ↔ scene ↔ data_service ↔ web_client 全链路 e2e 自动化。
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
  - `0x6C ObjectStateDelta` wire codec encode/decode + web_client decoder stub(实际 Gate 推送链路 deferred)。
- 客户端在线模式:storage.refinedCells 仍然是 `FRefinedCellData[]`(lossy 自 wire);Phase 1c-5 决策 5 RFC 备注了"未来改 wire-form-as-truth"。

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
| Postgres 持久化(1d 后) | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` |
| **Postgres scene_objects(Phase 4)** | `apps/data_service/lib/data_service/voxel/scene_object_store.ex`、`apps/data_service/lib/data_service/schema/voxel_scene_object.ex`、`apps/data_service/priv/repo/migrations/20260508000002_create_voxel_scene_objects.exs` |
| Gate 协议 codec | `apps/gate_server/lib/gate_server/codec.ex` |
| Gate ws/tcp dispatch | `apps/gate_server/lib/gate_server/worker/{ws,tcp}_connection.ex` |
| World map ledger | `apps/world_server/lib/world_server/voxel/map_ledger.ex` |
| **World transaction(Phase 4 加 scene_objects)** | `apps/world_server/lib/world_server/voxel/build_transaction.ex`、`apps/world_server/lib/world_server/voxel/transaction_coordinator.ex`、`apps/world_server/lib/world_server/voxel/transaction_executor.ex` |
| Web client 在线 adapter | `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts` |
| Web client wire decoder | `clients/web_client/src/infrastructure/net/refinedCellWire.ts`、`voxelEditIntent.ts`、`voxelProtocol.ts`、**`objectStateDelta.ts`(Phase 4)** |

## 这次会话产出(2026-05-08,Phase 4)

11 个 commit,本地 master 未 push:

```
本会话 docs(voxel): finalize Phase 4 (apps READMEs + plan progress log + handoff)
5352040 voxel: web_client objectStateDelta decoder stub (Phase 4-9)
0a5b428 voxel: 0x6C ObjectStateDelta wire codec (Phase 4-8)
d800996 voxel: end-to-end object lifecycle integration test (Phase 4-7)
330d528 voxel: damage / destroy_part / destroy_object closure (Phase 4-6)
53e4e7d voxel: ChunkProcess refresh + ObjectRegistry register on commit (Phase 4-5)
686d3cd voxel: BuildTransaction.scene_objects + coordinator object_id alloc (Phase 4-4)
f61351c voxel: ObjectRegistry GenServer + PartState struct (Phase 4-3)
95a3330 voxel: Storage.refresh_chunk_object_refs + lookup_owner_at (Phase 4-2)
df1ba93 voxel: voxel_scene_objects schema + SceneObjectStore (Phase 4-1)
067085f docs(voxel): land Phase 4 plan (object provenance + part-health destruction)
```

加上之前会话已经在 master 上的所有 Phase 1a → 3-bis commits(完整列表见上一个会话的 handoff)。
